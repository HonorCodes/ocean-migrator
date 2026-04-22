local TICKS_PER_MINUTE = 60 * 60
local CHECK_INTERVAL = 60 * 60
local WALL_BUCKET_SIZE = 256
local PATH_RETRY_MAX = 3
local PATH_RETRY_GAP_TICKS = 30
local PATH_RADIUS = 8
local PATH_BOUNDING_BOX = { { -0.4, -0.4 }, { 0.4, 0.4 } }
local ATTEMPT_ORPHAN_TICKS = 600
local DIRECTIONS = {
  { x = 1, y = 0 },
  { x = -1, y = 0 },
  { x = 0, y = 1 },
  { x = 0, y = -1 },
  { x = 0.70710678, y = 0.70710678 },
  { x = 0.70710678, y = -0.70710678 },
  { x = -0.70710678, y = 0.70710678 },
  { x = -0.70710678, y = -0.70710678 }
}

local function ensure_storage()
  storage.omb = storage.omb or {}
  storage.omb.surfaces = storage.omb.surfaces or {}
  storage.omb.pending_paths = storage.omb.pending_paths or {}
end

local function surface_state(surface)
  ensure_storage()
  local index = surface.index
  storage.omb.surfaces[index] = storage.omb.surfaces[index] or {
    beachheads = 0,
    next_tick = 0,
    budget = 0,
    last_budget_tick = game and game.tick or 0,
    attempt = nil,
  }
  local state = storage.omb.surfaces[index]
  state.budget = state.budget or 0
  state.last_budget_tick = state.last_budget_tick or (game and game.tick or 0)
  state.attempt = state.attempt  -- leaves nil untouched; explicit for readers
  return state
end

local function setting(name)
  return settings.global[name].value
end

local function valid_player(player)
  return player and player.valid and player.connected and player.character and player.surface and player.force
end

local function factorissimo_surface(surface)
  if not surface or not surface.valid then
    return false
  end

  if remote.interfaces and remote.interfaces.factorissimo and remote.interfaces.factorissimo.is_factorissimo_surface then
    local ok, result = pcall(remote.call, "factorissimo", "is_factorissimo_surface", surface)
    if ok and result then
      return true
    end
  end

  local name = surface.name or ""
  return name:match("%-factory%-floor$") ~= nil
    or name:match("^%d+%-factory%-floor$") ~= nil
    or name == "space-factory-floor"
    or name == "se-spaceship-factory-floor"
end

local function known_non_planet_surface(surface)
  local name = surface.name or ""
  return name == "beltlayer"
    or name == "pipelayer"
    or name == "aai-signals"
    or name:match("^se%-orbit") ~= nil
    or name:match("^se%-asteroid") ~= nil
end

local function eligible_surface(surface)
  if not surface or not surface.valid then
    return false
  end

  if factorissimo_surface(surface) or known_non_planet_surface(surface) then
    return false
  end

  if surface.platform ~= nil then
    return false
  end

  if surface.planet == nil and surface.name ~= "nauvis" then
    return false
  end

  return true
end

local function distance_sq(a, b)
  local dx = a.x - b.x
  local dy = a.y - b.y
  return dx * dx + dy * dy
end

local function debug_print(surface, reason)
  if setting("omb-debug") then
    game.print({ "ocean-migration-beachheads.debug-skip", reason, surface.name })
  end
end

local function get_evolution(enemy, surface)
  if enemy.get_evolution_factor then
    return enemy.get_evolution_factor(surface)
  end
  return enemy.evolution_factor or 0
end

local function migration_cost(landfall)
  local base = setting("omb-budget-base-cost")
  local water_cost = math.ceil((landfall.crossed or 0) / 100) * setting("omb-budget-water-cost-per-100")
  local nest_cost = setting("omb-nests-per-beachhead") * setting("omb-budget-cost-per-nest")
  return base + water_cost + nest_cost
end

local function update_budget(surface, state, event_tick, evolution)
  local max_budget = setting("omb-budget-max")
  if max_budget <= 0 then
    state.budget = 0
    state.last_budget_tick = event_tick
    return
  end

  local last_tick = state.last_budget_tick or event_tick
  local elapsed = math.max(0, event_tick - last_tick)
  if elapsed <= 0 then
    return
  end

  local minutes = elapsed / TICKS_PER_MINUTE
  local gain = minutes * setting("omb-budget-gain-per-minute") * setting("omb-budget-scaling") * evolution
  state.budget = math.min(max_budget, (state.budget or 0) + gain)
  state.last_budget_tick = event_tick

  if setting("omb-debug") and gain > 0 then
    game.print({ "ocean-migration-beachheads.debug-budget", string.format("+%.1f", gain), surface.name, math.floor(state.budget), max_budget, string.format("%.3f", evolution) })
  end
end

local function chunk_position(pos)
  return { x = math.floor(pos.x / 32), y = math.floor(pos.y / 32) }
end

local function find_highest_pollution_chunk(surface)
  local best_pos = nil
  local best_value = 0

  for chunk in surface.get_chunks() do
    local center = { x = chunk.x * 32 + 16, y = chunk.y * 32 + 16 }
    local pollution = surface.get_pollution(center)
    if pollution and pollution > best_value then
      best_value = pollution
      best_pos = center
    end
  end

  if best_value <= 0 then
    return nil
  end

  return { position = best_pos, value = best_value }
end

local function is_generated(surface, pos)
  return surface.is_chunk_generated(chunk_position(pos))
end

local function is_water_tile(surface, pos)
  if not is_generated(surface, pos) then
    return false
  end

  local tile = surface.get_tile(pos.x, pos.y)
  if not tile or not tile.valid then
    return false
  end

  return tile.collides_with("ground_tile")
end

local function tile_collides_with_any(tile, layers)
  for _, layer in ipairs(layers) do
    local ok, result = pcall(function()
      return tile.collides_with(layer)
    end)

    if ok and result then
      return true
    end
  end

  return false
end

local function is_deep_water_tile(surface, pos)
  if not is_water_tile(surface, pos) then
    return false
  end

  local tile = surface.get_tile(pos.x, pos.y)
  if not tile or not tile.valid then
    return false
  end

  if tile_collides_with_any(tile, { "player", "player-layer" }) then
    return true
  end

  local name = tile.name or ""
  return name:match("deep") ~= nil and name:match("shallow") == nil
end

local function is_land_tile(surface, pos)
  if not is_generated(surface, pos) then
    return false
  end

  return not is_water_tile(surface, pos)
end

local function tile_exists(name)
  if name == "auto" then
    return true
  end

  if prototypes and prototypes.tile then
    return prototypes.tile[name] ~= nil
  end

  return true
end

local function choose_landfall_tile(surface, center, configured_tile)
  if configured_tile ~= "auto" and tile_exists(configured_tile) then
    return configured_tile
  end

  local best = nil
  local best_distance = nil

  for radius = 1, 32 do
    for x = -radius, radius do
      for y = -radius, radius do
        if math.abs(x) == radius or math.abs(y) == radius then
          local pos = { x = center.x + x, y = center.y + y }
          if is_land_tile(surface, pos) then
            local tile = surface.get_tile(pos.x, pos.y)
            if tile and tile.valid and tile_exists(tile.name) then
              local d = x * x + y * y
              if not best_distance or d < best_distance then
                best_distance = d
                best = tile.name
              end
            end
          end
        end
      end
    end

    if best then
      return best
    end
  end

  if tile_exists("landfill") then
    return "landfill"
  end

  return "grass-1"
end

local function away_from_players(surface, pos, min_distance)
  if min_distance <= 0 then
    return true
  end

  local min_distance_sq = min_distance * min_distance
  for _, player in pairs(game.connected_players) do
    if valid_player(player) and player.surface == surface then
      if distance_sq(pos, player.position) < min_distance_sq then
        return false
      end
    end
  end

  return true
end

local function far_enough_from_source(source, destination, min_distance)
  if min_distance <= 0 then
    return true
  end

  return distance_sq(source, destination) >= (min_distance * min_distance)
end

local function prototype_is_unit_spawner(proto)
  if not proto then
    return false
  end

  local ok, result = pcall(function() return proto.type end)
  if ok and result == "unit-spawner" then
    return true
  end

  return false
end

local function available_spawners()
  local names = {}
  local seen = {}

  local function add(name)
    if name and not seen[name] then
      seen[name] = true
      names[#names + 1] = name
    end
  end

  if prototypes and prototypes.entity then
    if prototypes.entity["biter-spawner"] then
      add("biter-spawner")
    end
    if prototypes.entity["spitter-spawner"] then
      add("spitter-spawner")
    end
    if setting("omb-use-water-spitters") and prototypes.entity["water-biter-spawner"] then
      add("water-biter-spawner")
    end
  else
    add("biter-spawner")
    add("spitter-spawner")
  end

  return names
end

local function is_valid_spawner_name(name)
  if not name then
    return false
  end
  if not prototypes or not prototypes.entity then
    return true
  end
  return prototype_is_unit_spawner(prototypes.entity[name])
end

local function choose_spawner(names)
  if #names == 1 then
    return names[1]
  end

  return names[math.random(#names)]
end

local function spawner_name_options(source_spawner, fallback_names)
  local names = {}
  local seen = {}

  if source_spawner and source_spawner.valid and source_spawner.name and is_valid_spawner_name(source_spawner.name) then
    names[#names + 1] = source_spawner.name
    seen[source_spawner.name] = true
  end

  for _, name in ipairs(fallback_names) do
    if not seen[name] and is_valid_spawner_name(name) then
      names[#names + 1] = name
      seen[name] = true
    end
  end

  if #names == 0 then
    for _, name in ipairs(fallback_names) do
      if not seen[name] then
        names[#names + 1] = name
        seen[name] = true
      end
    end
  end

  return names
end

local function create_landfall(surface, center, radius, tile_name)
  if radius <= 0 then
    return
  end

  local resolved_tile_name = choose_landfall_tile(surface, center, tile_name)
  local tiles = {}
  local r2 = radius * radius
  local cx = math.floor(center.x)
  local cy = math.floor(center.y)

  for x = -radius, radius do
    for y = -radius, radius do
      if (x * x + y * y) <= r2 then
        local pos = { x = cx + x, y = cy + y }
        if is_generated(surface, pos) then
          tiles[#tiles + 1] = { name = resolved_tile_name, position = pos }
        end
      end
    end
  end

  if #tiles > 0 then
    pcall(function()
      surface.set_tiles(tiles, true, "abort_on_collision", false, true)
    end)
  end
end

local function find_landfall(surface, source, direction, min_water, max_water, step)
  local saw_water = false
  local water_start = nil
  local water_distance = 0
  local crossed_deep_water = false

  for distance = step, max_water, step do
    local pos = {
      x = source.x + direction.x * distance,
      y = source.y + direction.y * distance
    }

    if not is_generated(surface, pos) then
      if saw_water and water_distance >= min_water and crossed_deep_water then
        local last_pos = {
          x = source.x + direction.x * (distance - step),
          y = source.y + direction.y * (distance - step)
        }
        return {
          x = last_pos.x,
          y = last_pos.y,
          crossed = water_distance
        }
      end
      return nil
    end

    if is_water_tile(surface, pos) then
      water_start = water_start or distance
      saw_water = true
      water_distance = distance - water_start + step
      crossed_deep_water = crossed_deep_water or is_deep_water_tile(surface, pos)
    elseif saw_water then
      if water_distance >= min_water and crossed_deep_water then
        return {
          x = pos.x,
          y = pos.y,
          crossed = water_distance
        }
      end
      saw_water = false
      water_start = nil
      water_distance = 0
      crossed_deep_water = false
    end
  end

  return nil
end

local function direction_toward(source, target)
  local dx = target.x - source.x
  local dy = target.y - source.y
  local length = math.sqrt(dx * dx + dy * dy)

  if length < 1 then
    return nil
  end

  return { x = dx / length, y = dy / length }
end

local function candidate_directions(source, target)
  local result = {}
  local primary = direction_toward(source, target)

  if primary then
    result[#result + 1] = primary
    result[#result + 1] = { x = primary.x * 0.9659258 - primary.y * 0.2588190, y = primary.x * 0.2588190 + primary.y * 0.9659258 }
    result[#result + 1] = { x = primary.x * 0.9659258 + primary.y * 0.2588190, y = -primary.x * 0.2588190 + primary.y * 0.9659258 }
    result[#result + 1] = { x = primary.x * 0.8660254 - primary.y * 0.5, y = primary.x * 0.5 + primary.y * 0.8660254 }
    result[#result + 1] = { x = primary.x * 0.8660254 + primary.y * 0.5, y = -primary.x * 0.5 + primary.y * 0.8660254 }
  end

  for _, direction in ipairs(DIRECTIONS) do
    result[#result + 1] = direction
  end

  return result
end

local function place_beachhead(surface, landfall, spawner_names)
  local nest_count = setting("omb-nests-per-beachhead")
  local landfall_radius = setting("omb-build-islands") and setting("omb-landfall-radius") or 0
  local tile_name = setting("omb-landfall-tile")
  local placed = 0
  local first_position = nil

  create_landfall(surface, landfall, landfall_radius, tile_name)

  for _ = 1, nest_count do
    local radius = math.max(landfall_radius + 8, 16)
    local start_index = math.random(#spawner_names)

    for offset = 0, #spawner_names - 1 do
      local name = spawner_names[((start_index + offset - 1) % #spawner_names) + 1]
      local pos = surface.find_non_colliding_position(name, landfall, radius, 1, true)

      if pos and surface.can_place_entity({ name = name, position = pos, force = "enemy" }) then
        local entity = surface.create_entity({
          name = name,
          position = pos,
          force = "enemy",
          raise_built = true,
          move_stuck_players = true
        })

        if entity and entity.valid then
          placed = placed + 1
          first_position = first_position or entity.position
          break
        end
      end
    end
  end

  return placed, first_position
end

local function chart_for_players(surface, pos)
  if not setting("omb-chart-beachheads") then
    return
  end

  local area = {
    { pos.x - 64, pos.y - 64 },
    { pos.x + 64, pos.y + 64 }
  }

  for _, force in pairs(game.forces) do
    if force.name ~= "enemy" and force.name ~= "neutral" then
      force.chart(surface, area)
    end
  end
end

local function nearest_player_position(surface, source)
  local best = nil
  local best_distance = nil

  for _, player in pairs(game.connected_players) do
    if valid_player(player) and player.surface == surface then
      local d = distance_sq(source, player.position)
      if not best_distance or d < best_distance then
        best_distance = d
        best = player.position
      end
    end
  end

  return best
end

local function shuffled_entities(entities, limit)
  local count = #entities
  local result = {}
  local used = {}

  limit = math.min(limit, count)
  for _ = 1, limit do
    local index
    repeat
      index = math.random(count)
    until not used[index]
    used[index] = true
    result[#result + 1] = entities[index]
  end

  return result
end

local function find_enemy_spawners(surface)
  local radius = setting("omb-source-search-radius")
  local found = {}
  local seen = {}

  local function gather_from(position)
    local ok, entities = pcall(function()
      return surface.find_entities_filtered({
        position = position,
        radius = radius,
        force = "enemy",
        type = "unit-spawner"
      })
    end)

    if not ok or not entities then
      return
    end

    for _, entity in ipairs(entities) do
      if entity.valid and entity.unit_number and not seen[entity.unit_number] then
        seen[entity.unit_number] = true
        found[#found + 1] = entity
      end
    end
  end

  for _, player in pairs(game.connected_players) do
    if valid_player(player) and player.surface == surface then
      gather_from(player.position)
    end
  end

  return found
end

local function gather_sorted_candidates(surface, target_position)
  local entities = surface.find_entities_filtered({
    force = "enemy",
    type = "unit-spawner",
  })

  local scored = {}
  for _, entity in ipairs(entities) do
    if entity.valid and entity.unit_number then
      scored[#scored + 1] = {
        unit_number = entity.unit_number,
        position = entity.position,
        distance_sq = distance_sq(entity.position, target_position),
        entity = entity,
      }
    end
  end

  table.sort(scored, function(a, b)
    return a.distance_sq < b.distance_sq
  end)

  return scored
end

local function wall_bucket_key(x, y)
  return math.floor(x / WALL_BUCKET_SIZE) .. ":" .. math.floor(y / WALL_BUCKET_SIZE)
end

local function build_wall_index(surface, player_force)
  local entities = surface.find_entities_filtered({
    force = player_force,
    type = { "wall", "gate" },
  })

  local index = { buckets = {}, count = 0 }
  for _, entity in ipairs(entities) do
    if entity.valid then
      local pos = entity.position
      local key = wall_bucket_key(pos.x, pos.y)
      index.buckets[key] = index.buckets[key] or {}
      index.buckets[key][#index.buckets[key] + 1] = { x = pos.x, y = pos.y }
      index.count = index.count + 1
    end
  end

  return index
end

local function nearest_wall(index, pos)
  if not index or index.count == 0 then
    return nil
  end

  local bx = math.floor(pos.x / WALL_BUCKET_SIZE)
  local by = math.floor(pos.y / WALL_BUCKET_SIZE)
  local best = nil
  local best_d = nil

  for dx = -1, 1 do
    for dy = -1, 1 do
      local key = (bx + dx) .. ":" .. (by + dy)
      local bucket = index.buckets[key]
      if bucket then
        for _, wall_pos in ipairs(bucket) do
          local d = distance_sq(pos, wall_pos)
          if not best_d or d < best_d then
            best_d = d
            best = wall_pos
          end
        end
      end
    end
  end

  -- If nothing was in the 9 neighboring buckets, widen the search once to the
  -- full index. This happens on very sparse wall layouts; accept O(index.count)
  -- for the rare case.
  if not best then
    for _, bucket in pairs(index.buckets) do
      for _, wall_pos in ipairs(bucket) do
        local d = distance_sq(pos, wall_pos)
        if not best_d or d < best_d then
          best_d = d
          best = wall_pos
        end
      end
    end
  end

  return best
end

local function resolve_source_collision_mask(spawner_name)
  local proto = spawner_name and prototypes.entity[spawner_name]
  if proto and proto.collision_mask then
    return proto.collision_mask
  end

  local fallback = prototypes.entity["biter-spawner"]
  if fallback and fallback.collision_mask then
    return fallback.collision_mask
  end

  return { layers = { ["player-layer"] = true, ["water-tile"] = true } }
end

local function issue_path_request(surface, start, goal, purpose, surface_index, spawner_name)
  local mask = resolve_source_collision_mask(spawner_name)

  local request_id = surface.request_path({
    bounding_box = PATH_BOUNDING_BOX,
    collision_mask = mask,
    start = start,
    goal = goal,
    force = game.forces.enemy,
    radius = PATH_RADIUS,
    pathfind_flags = {
      allow_destroy_friendly_entities = false,
      cache = true,
      low_priority = true,
      prefer_straight_paths = false,
    },
  })

  if not request_id then
    return nil
  end

  storage.omb.pending_paths[request_id] = {
    surface_index = surface_index,
    purpose = purpose,
    issued_tick = game.tick,
    retries = 0,
    start = { x = start.x, y = start.y },
    goal = { x = goal.x, y = goal.y },
    spawner_name = spawner_name,
  }

  return request_id
end

-- ---------------------------------------------------------------------------
-- Task 8: check_candidate resolution helpers
-- ---------------------------------------------------------------------------

local function advance_candidate(surface_index, attempt)
  attempt.current = nil
  attempt.candidate_i = attempt.candidate_i + 1
  issue_candidate_paths(surface_index, attempt)
end

-- Forward declaration; defined in Task 9.
local start_beach_search

local function on_current_both_resolved(surface_index, attempt)
  local current = attempt.current
  if not current then return end

  local candidate_entity = game.get_entity_by_unit_number(current.unit_number)
  if not (candidate_entity and candidate_entity.valid) then
    advance_candidate(surface_index, attempt)
    return
  end

  local reachable = (current.wall_result == "success") or
                    (current.pollution_result == "success")

  if reachable then
    advance_candidate(surface_index, attempt)
    return
  end

  -- Both failed → marooned.
  if attempt.force_run and attempt.player_index then
    local player = game.get_player(attempt.player_index)
    if player and player.valid then
      player.print(string.format(
        "Ocean Migration: marooned nest found [gps=%d,%d,%s]. Scanning beachhead.",
        math.floor(current.nest_position.x),
        math.floor(current.nest_position.y),
        game.surfaces[surface_index].name))
    end
  end

  attempt.stage = "validate_beach"
  attempt.beach = {
    source = { x = current.nest_position.x, y = current.nest_position.y },
    spawner_name = current.spawner_name,
    fan_offsets = { 0, 15, -15, 30, -30 },
    fan_i = 1,
  }
  start_beach_search(surface_index, attempt)
end

local function offset_direction(base_dir, degrees)
  local rad = math.rad(degrees)
  local c = math.cos(rad)
  local s = math.sin(rad)
  return {
    x = base_dir.x * c - base_dir.y * s,
    y = base_dir.x * s + base_dir.y * c,
  }
end

-- Walks from `source` toward `direction` in steps of `step`, counting water
-- tiles crossed. Returns { anchor = {x,y}, water_crossed = int } on the first
-- land tile past `min_water` water tiles, or nil if the ray exits generated
-- chunks, exceeds max distance, or never crosses enough water.
local function ray_to_beach_anchor(surface, source, direction, min_water, step, max_distance)
  local water_crossed = 0
  local distance = step
  while distance <= max_distance do
    local pos = {
      x = source.x + direction.x * distance,
      y = source.y + direction.y * distance,
    }

    if not is_generated(surface, pos) then
      return nil
    end

    if is_water_tile(surface, pos) then
      water_crossed = water_crossed + step
    else
      if water_crossed >= min_water then
        return { anchor = pos, water_crossed = water_crossed }
      end
      -- Land reached too early (we haven't crossed enough water) — keep walking.
    end

    distance = distance + step
  end

  return nil
end

local function direction_from_source_to_pollution(source, pollution)
  local dx = pollution.x - source.x
  local dy = pollution.y - source.y
  local length = math.sqrt(dx * dx + dy * dy)
  if length < 1 then return nil end
  return { x = dx / length, y = dy / length }
end

local function try_ray(surface_index, attempt)
  local surface = game.surfaces[surface_index]
  if not (surface and surface.valid) then
    end_attempt(surface_index, "surface became invalid")
    return
  end

  local beach = attempt.beach
  local offset = beach.fan_offsets[beach.fan_i]
  if not offset then
    -- Fan exhausted.
    if attempt.force_run and attempt.player_index then
      local player = game.get_player(attempt.player_index)
      if player and player.valid then
        player.print(string.format(
          "Ocean Migration: marooned source [gps=%d,%d,%s] — no reachable coastal landing after %d rays.",
          math.floor(beach.source.x),
          math.floor(beach.source.y),
          surface.name,
          #beach.fan_offsets))
      end
    end
    end_attempt(surface_index, "no beachhead after full fan")
    return
  end

  local base_dir = direction_from_source_to_pollution(beach.source, attempt.pollution_chunk)
  if not base_dir then
    -- Source and pollution overlap; should not happen, but handle gracefully.
    end_attempt(surface_index, "source overlaps pollution target")
    return
  end

  local direction = offset_direction(base_dir, offset)
  local anchor_hit = ray_to_beach_anchor(
    surface, beach.source, direction,
    setting("omb-min-water-tiles"),
    setting("omb-scan-step"),
    1024)

  if not anchor_hit then
    beach.fan_i = beach.fan_i + 1
    try_ray(surface_index, attempt)
    return
  end

  local drifted = surface.find_non_colliding_position(
    beach.spawner_name, anchor_hit.anchor, 16, 1, true)

  if not drifted then
    beach.fan_i = beach.fan_i + 1
    try_ray(surface_index, attempt)
    return
  end

  local drift_distance_sq = distance_sq(drifted, anchor_hit.anchor)
  if drift_distance_sq > (24 * 24) then
    beach.fan_i = beach.fan_i + 1
    try_ray(surface_index, attempt)
    return
  end

  -- Check the min-migration-distance guard too, otherwise we can drop a
  -- beachhead on a short hop across a river that the pathfinder grudgingly
  -- accepts but the player would find spammy.
  local min_migration_distance = setting("omb-min-migration-chunks") * 32
  if not far_enough_from_source(beach.source, drifted, min_migration_distance) then
    beach.fan_i = beach.fan_i + 1
    try_ray(surface_index, attempt)
    return
  end

  -- Don't drop beachheads directly on a connected player either.
  local min_player_distance = setting("omb-min-distance-from-player")
  if not away_from_players(surface, drifted, min_player_distance) then
    beach.fan_i = beach.fan_i + 1
    try_ray(surface_index, attempt)
    return
  end

  beach.current_anchor = anchor_hit.anchor
  beach.current_drift = drifted
  beach.water_crossed = anchor_hit.water_crossed

  issue_path_request(surface, drifted, attempt.pollution_chunk,
                     "beach", surface_index, beach.spawner_name)
end

local function advance_ray_fan(surface_index, attempt)
  attempt.beach.fan_i = attempt.beach.fan_i + 1
  try_ray(surface_index, attempt)
end

start_beach_search = function(surface_index, attempt)
  try_ray(surface_index, attempt)
end

local function resolve_wall(surface_index, attempt, success)
  if not attempt.current then return end
  attempt.current.wall_result = success and "success" or "fail"
  if attempt.current.pollution_result ~= "pending" then
    on_current_both_resolved(surface_index, attempt)
  end
end

local function resolve_pollution(surface_index, attempt, success)
  if not attempt.current then return end
  attempt.current.pollution_result = success and "success" or "fail"
  if attempt.current.wall_result ~= "pending" then
    on_current_both_resolved(surface_index, attempt)
  end
end

-- Forward declaration; defined in Task 10.
local finalize_beachhead_spawn = function(surface_index, attempt)
  local surface = game.surfaces[surface_index]
  if not (surface and surface.valid) then
    end_attempt(surface_index, "surface became invalid")
    return
  end

  local beach = attempt.beach
  local state = storage.omb.surfaces[surface_index]

  local landfall = {
    x = beach.current_drift.x,
    y = beach.current_drift.y,
    crossed = beach.water_crossed,
  }

  local cost = migration_cost(landfall)

  if not attempt.force_run and (state.budget or 0) < cost then
    end_attempt(surface_index, string.format(
      "insufficient budget %d/%d", math.floor(state.budget or 0), cost))
    return
  end

  local source_entity = game.get_entity_by_unit_number(attempt.current.unit_number)
  local fallback_names = available_spawners()
  local spawner_names = spawner_name_options(source_entity, fallback_names)

  local placed, placed_position = place_beachhead(surface, landfall, spawner_names)

  if placed <= 0 then
    -- Rare race with chunk modification. Try the next ray.
    advance_ray_fan(surface_index, attempt)
    return
  end

  if not attempt.force_run then
    state.budget = math.max(0, (state.budget or 0) - cost)
    state.next_tick = game.tick + setting("omb-cooldown-minutes") * TICKS_PER_MINUTE
  end
  state.beachheads = state.beachheads + 1

  chart_for_players(surface, landfall)

  if setting("omb-notify") then
    local notify_position = placed_position or landfall
    game.print({
      "ocean-migration-beachheads.beachhead-created",
      surface.name,
      math.floor(notify_position.x),
      math.floor(notify_position.y),
      attempt.force_run and 0 or cost,
      math.floor(landfall.crossed or 0),
    })
  end

  if attempt.force_run and attempt.player_index then
    local player = game.get_player(attempt.player_index)
    if player and player.valid then
      player.print(string.format(
        "Ocean Migration forced a beachhead. Source nest: [gps=%d,%d,%s]. New nest: [gps=%d,%d,%s]. Water tiles crossed: %d.",
        math.floor(beach.source.x),
        math.floor(beach.source.y),
        surface.name,
        math.floor((placed_position or landfall).x),
        math.floor((placed_position or landfall).y),
        surface.name,
        math.floor(landfall.crossed or 0)))
    end
  end

  surface_state(surface).attempt = nil
end

-- resolve_beach stays a stub here; filled in Task 9.
local function resolve_beach(surface_index, attempt, success)
  if not attempt.beach then return end
  if not success then
    advance_ray_fan(surface_index, attempt)
    return
  end

  -- On success, finalize spawn. This calls into Task 10's spawn helper.
  finalize_beachhead_spawn(surface_index, attempt)
end

-- ---------------------------------------------------------------------------
-- Task 7: enumerate-stage driver
-- ---------------------------------------------------------------------------

local function attempt_reply(attempt, message)
  if attempt.player_index then
    local player = game.get_player(attempt.player_index)
    if player and player.valid then
      player.print(message)
    end
  elseif setting("omb-debug") then
    game.print(message)
  end
end

local function end_attempt(surface_index, reason, extra)
  local surface_state_entry = storage.omb.surfaces[surface_index]
  if not surface_state_entry then return end
  local attempt = surface_state_entry.attempt
  if not attempt then return end

  if attempt.force_run or setting("omb-debug") then
    attempt_reply(attempt, "Ocean Migration: " .. reason)
  end

  surface_state_entry.attempt = nil
end

local function issue_candidate_paths(surface_index, attempt)
  local surface = game.surfaces[surface_index]
  if not surface or not surface.valid then
    end_attempt(surface_index, "surface became invalid")
    return
  end

  local candidate = attempt.candidates[attempt.candidate_i]
  if not candidate then
    if attempt.force_run and attempt.player_index then
      local player = game.get_player(attempt.player_index)
      if player and player.valid then
        local closest = attempt.candidates[1]
        if closest then
          player.print(string.format(
            "Ocean Migration: all %d sampled nests can reach walls or pollution — no migration needed. Closest: [gps=%d,%d,%s]",
            #attempt.candidates,
            math.floor(closest.position.x),
            math.floor(closest.position.y),
            game.surfaces[surface_index].name))
        end
      end
    end
    end_attempt(surface_index, "no marooned nests (queue exhausted)")
    return
  end

  local entity = candidate.entity
  if not (entity and entity.valid) then
    -- Stale entity; advance without issuing requests.
    attempt.candidate_i = attempt.candidate_i + 1
    issue_candidate_paths(surface_index, attempt)
    return
  end

  attempt.current = {
    unit_number = candidate.unit_number,
    nest_position = { x = entity.position.x, y = entity.position.y },
    spawner_name = entity.name,
    wall_result = "pending",
    pollution_result = "pending",
  }

  -- Path A: nearest wall, if any.
  local wall_pos = nearest_wall(attempt.wall_index, entity.position)
  if wall_pos then
    issue_path_request(surface, entity.position, wall_pos, "wall",
                       surface_index, entity.name)
  else
    -- No walls on this surface; treat as if the wall path failed.
    -- Task 8's on_current_both_resolved treats "skip" identically to "fail":
    -- only the pollution path decides marooned-ness when there are no walls.
    attempt.current.wall_result = "skip"
  end

  -- Path B: pollution chunk.
  issue_path_request(surface, entity.position, attempt.pollution_chunk,
                     "pollution", surface_index, entity.name)
end

local function start_attempt(surface, force_run, player_index)
  local state = surface_state(surface)

  if state.attempt then
    if player_index then
      local player = game.get_player(player_index)
      if player and player.valid then
        player.print("Ocean Migration: check already in progress on " ..
                     surface.name .. ", try again in ~10 seconds.")
      end
    end
    return
  end

  -- Existing gates that apply in non-force mode. /omb-force bypasses them.
  local enemy = game.forces.enemy
  if not enemy then
    return
  end

  local evolution = get_evolution(enemy, surface)
  update_budget(surface, state, game.tick, evolution)

  if not force_run then
    if state.next_tick and game.tick < state.next_tick then return end
    if state.beachheads >= setting("omb-max-beachheads-per-surface") then return end
    if evolution < setting("omb-min-evolution") then return end
  end

  local pollution_hit = find_highest_pollution_chunk(surface)
  if not pollution_hit then
    if force_run and player_index then
      local player = game.get_player(player_index)
      if player and player.valid then
        player.print("Ocean Migration: no pollution on " .. surface.name ..
                     " yet — nothing to migrate toward.")
      end
    end
    return
  end

  local candidates = gather_sorted_candidates(surface, pollution_hit.position)
  if #candidates == 0 then
    if force_run and player_index then
      local player = game.get_player(player_index)
      if player and player.valid then
        player.print("Ocean Migration: no enemy unit-spawner entities on " ..
                     surface.name .. ".")
      end
    end
    return
  end

  local max_samples = setting("omb-max-samples-per-attempt")
  if #candidates > max_samples then
    for i = max_samples + 1, #candidates do candidates[i] = nil end
  end

  -- Pick a player force to scan walls for. For /omb-force, use the invoking
  -- player's force; otherwise default to `player` (the standard vanilla force).
  -- Multi-force edge cases are acknowledged in §9 Edge Cases; we default to
  -- vanilla here and do not iterate all player forces.
  local wall_force = game.forces.player
  if player_index then
    local player = game.get_player(player_index)
    if player and player.valid then wall_force = player.force end
  end

  -- IMPORTANT: state.attempt must be assigned BEFORE calling
  -- issue_candidate_paths, which reads attempt.candidate_i and writes
  -- attempt.current.
  state.attempt = {
    stage = "check_candidate",
    force_run = force_run,
    player_index = player_index,
    started_tick = game.tick,
    pollution_chunk = pollution_hit.position,
    pollution_value = pollution_hit.value,
    candidates = candidates,
    candidate_i = 1,
    wall_index = build_wall_index(surface, wall_force),
    current = nil,
    beach = nil,
  }

  if force_run and player_index then
    local player = game.get_player(player_index)
    if player and player.valid then
      player.print(string.format(
        "Ocean Migration: pollution target [gps=%d,%d,%s]. Testing %d nearest nests.",
        math.floor(pollution_hit.position.x),
        math.floor(pollution_hit.position.y),
        surface.name,
        #candidates))
    end
  end

  issue_candidate_paths(surface.index, state.attempt)
end

local function attempt_surface_migration(surface, event_tick, force_run, player_index)
  start_attempt(surface, force_run, player_index)
  return true, "dispatched"
end

local function check_all_surfaces(event)
  if not setting("omb-enabled") then
    return
  end

  local surfaces = {}
  for _, player in pairs(game.connected_players) do
    if valid_player(player) then
      if eligible_surface(player.surface) then
        surfaces[player.surface.index] = player.surface
      elseif setting("omb-debug") then
        game.print({
          "ocean-migration-beachheads.debug-skip",
          "non-planet surface",
          player.surface.name,
        })
      end
    end
  end

  for _, surface in pairs(surfaces) do
    if surface.valid then
      start_attempt(surface, false, nil)
    end
  end
end

script.on_init(function()
  ensure_storage()
end)

script.on_configuration_changed(function()
  ensure_storage()
end)

script.on_nth_tick(CHECK_INTERVAL, check_all_surfaces)

script.on_event(defines.events.on_script_path_request_finished, function(event)
  ensure_storage()
  local pending = storage.omb.pending_paths[event.id]
  if not pending then
    return
  end

  if event.try_again_later then
    -- Retry logic is added in Task 12 via the housekeeping tick. Here we mark
    -- and bail so the housekeeper picks it up on the next pass. Reset
    -- issued_tick so the 30-tick gap measures from "now", not from the
    -- original (long-ago) request time.
    pending.try_again_later = true
    pending.issued_tick = game.tick
    return
  end

  storage.omb.pending_paths[event.id] = nil

  local surface_state_entry = storage.omb.surfaces[pending.surface_index]
  local attempt = surface_state_entry and surface_state_entry.attempt
  if not attempt then
    return
  end

  local success = (event.path ~= nil)
  if pending.purpose == "wall" then
    resolve_wall(pending.surface_index, attempt, success)
  elseif pending.purpose == "pollution" then
    resolve_pollution(pending.surface_index, attempt, success)
  elseif pending.purpose == "beach" then
    resolve_beach(pending.surface_index, attempt, success)
  end
end)

commands.add_command("omb-reset", "Reset Ocean Migration counters.", function(command)
  local player = command.player_index and game.get_player(command.player_index) or nil
  if player and not player.admin then
    player.print("Only admins can use /omb-reset.")
    return
  end

  storage.omb = { surfaces = {} }
  game.print({ "ocean-migration-beachheads.beachheads-reset" })
end)

commands.add_command("omb-status", "Show Ocean Migration status for the current surface.", function(command)
  local player = command.player_index and game.get_player(command.player_index) or nil
  if not player then
    return
  end

  local state = surface_state(player.surface)
  local remaining = math.max(0, (state.next_tick or 0) - game.tick)
  player.print({ "ocean-migration-beachheads.status", state.beachheads or 0, player.surface.name, math.floor(state.budget or 0), setting("omb-budget-max"), math.ceil(remaining / TICKS_PER_MINUTE) })
end)

commands.add_command(
  "omb-force",
  "Admin only. Force one Ocean Migration attempt on your current surface, ignoring budget, cooldown, evolution, and surface cap.",
  function(command)
    local player = command.player_index and game.get_player(command.player_index) or nil
    if not player then
      return
    end

    if not player.admin then
      player.print("Only admins can use /omb-force.")
      return
    end

    if not eligible_surface(player.surface) then
      player.print("Ocean Migration cannot run on this non-planet surface.")
      return
    end

    start_attempt(player.surface, true, command.player_index)
  end)
