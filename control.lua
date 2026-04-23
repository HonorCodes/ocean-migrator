local TICKS_PER_MINUTE = 60 * 60
local CHECK_INTERVAL = 60 * 60
local WALL_BUCKET_SIZE = 256
local PATH_RETRY_MAX = 3
local PATH_RETRY_GAP_TICKS = 30
local PATH_RADIUS = 8
local PATH_BOUNDING_BOX = { { -0.4, -0.4 }, { 0.4, 0.4 } }
local ATTEMPT_ORPHAN_TICKS = 600

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

  if tile_collides_with_any(tile, { "player", "water_tile" }) then
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

  -- Enumerate every unit-spawner prototype so modded variants (Rampant,
  -- K2, etc.) are eligible alongside vanilla. Previously this was hard-coded
  -- to biter-spawner/spitter-spawner/water-biter-spawner, which meant
  -- beachheads on modded maps spawned vanilla nests even when the source
  -- cluster was a modded variant. `omb-use-water-spitters` still gates the
  -- vanilla water-biter-spawner; modded water variants are left to the mod
  -- that registered them.
  local skip_water_biter = not setting("omb-use-water-spitters")

  if prototypes and prototypes.entity then
    for name, proto in pairs(prototypes.entity) do
      local ok, kind = pcall(function() return proto.type end)
      if ok and kind == "unit-spawner"
         and not (skip_water_biter and name == "water-biter-spawner") then
        add(name)
      end
    end
  end

  if #names == 0 then
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

local function place_beachhead(surface, landfall, spawner_names)
  local nest_count = setting("omb-nests-per-beachhead")
  local landfall_radius = setting("omb-build-islands") and setting("omb-landfall-radius") or 0
  local tile_name = setting("omb-landfall-tile")
  local placed = 0
  local first_position = nil

  create_landfall(surface, landfall, landfall_radius, tile_name)

  for _ = 1, nest_count do
    -- Keep the nest cluster tight on the shoreline. The base case
    -- (no experimental island-building) is a 6-tile radius — just
    -- enough for a second/third spawner to sit next to the first
    -- without overlap. Users who enable island-building opt into a
    -- larger landfall_radius and get a proportional spawn area.
    local radius = math.max(landfall_radius + 2, 6)
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

local function gather_sorted_candidates(surface, target_position)
  local entities = surface.find_entities_filtered({
    force = "enemy",
    type = "unit-spawner",
  })

  -- Chunk-diversify: one representative per 32x32 chunk. Within a chunk,
  -- keep the spawner nearest to the target (ties broken by lowest
  -- unit_number for determinism). This prevents a dense mainland biter
  -- cluster from crowding out distant water-isolated clusters when the
  -- sample cap is applied in start_attempt.
  local chunks = {}
  for _, entity in ipairs(entities) do
    if entity.valid and entity.unit_number then
      local cp = chunk_position(entity.position)
      local key = cp.x .. ":" .. cp.y
      local dsq = distance_sq(entity.position, target_position)
      local existing = chunks[key]
      if not existing
         or dsq < existing.distance_sq
         or (dsq == existing.distance_sq and entity.unit_number < existing.unit_number) then
        chunks[key] = {
          unit_number = entity.unit_number,
          position = entity.position,
          distance_sq = dsq,
          entity = entity,
        }
      end
    end
  end

  local scored = {}
  for _, rep in pairs(chunks) do
    scored[#scored + 1] = rep
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

  return { layers = { ["player"] = true, ["water_tile"] = true } }
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
-- Forward declarations. These functions are assigned below; several
-- callers upstream (advance_candidate, try_ray, finalize_beachhead_spawn)
-- close over these names, so they must be in scope before those closures
-- are compiled.
-- ---------------------------------------------------------------------------

local end_attempt
local issue_candidate_paths
local start_beach_search

local function advance_candidate(surface_index, attempt)
  attempt.current = nil
  attempt.candidate_i = attempt.candidate_i + 1
  issue_candidate_paths(surface_index, attempt)
end

local function on_current_both_resolved(surface_index, attempt)
  local current = attempt.current
  if not current then return end

  -- Use the stored LuaEntity reference instead of game.get_entity_by_unit_number.
  -- The 2.0 API silently returns nil for unit-spawner prototypes because they
  -- lack the get-by-unit-number flag, which made 0.4.3/0.4.4 treat every
  -- candidate as entity=nil and silently advance without checking reachability.
  -- Stored LuaEntity references remain valid across ticks and across save/load;
  -- .valid flips to false only if the engine has destroyed the entity.
  local candidate_entity = current.entity
  local entity_status
  if not candidate_entity then
    entity_status = "missing"
  elseif not candidate_entity.valid then
    entity_status = "invalid"
  else
    entity_status = "ok"
  end

  if setting("omb-debug") and attempt.force_run and attempt.player_index then
    local player = game.get_player(attempt.player_index)
    if player and player.valid then
      local wall_info
      if current.wall_target then
        wall_info = string.format("wall→[%d,%d]=%s",
          math.floor(current.wall_target.x),
          math.floor(current.wall_target.y),
          current.wall_result or "?")
      else
        wall_info = "wall=skip(no-walls)"
      end
      player.print(string.format(
        "OMB debug [%d/%d] %s u#%d @[%d,%d] entity=%s %s pollution=%s",
        attempt.candidate_i or 0,
        #(attempt.candidates or {}),
        current.spawner_name or "?",
        current.unit_number or 0,
        math.floor(current.nest_position and current.nest_position.x or 0),
        math.floor(current.nest_position and current.nest_position.y or 0),
        entity_status,
        wall_info,
        current.pollution_result or "?"))
    end
  end

  if entity_status ~= "ok" then
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
-- chunks, exceeds max distance, or never crosses enough water. If `trace`
-- is a table, each completed water segment is appended as {w=int, rejected=bool}
-- so callers can emit a debug summary even when a landing succeeds.
local function ray_to_beach_anchor(surface, source, direction, min_water, step, max_distance, trace)
  -- The ray lands on the first land tile past a single continuous water
  -- segment of at least `min_water` tiles. Previously this tracked the total
  -- water crossed along the whole ray, which on maps with inland lakes would
  -- walk past the first mainland coast and accumulate lake tiles until the
  -- total threshold was met — dropping the beachhead deep inland.
  local water_crossed = 0
  local segment_water = 0
  local distance = step
  while distance <= max_distance do
    local pos = {
      x = source.x + direction.x * distance,
      y = source.y + direction.y * distance,
    }

    if not is_generated(surface, pos) then
      if trace and segment_water > 0 then
        trace[#trace + 1] = { w = segment_water, rejected = true, ungenerated = true }
      end
      return nil
    end

    if is_water_tile(surface, pos) then
      water_crossed = water_crossed + step
      segment_water = segment_water + step
    else
      if segment_water >= min_water then
        if trace then
          trace[#trace + 1] = { w = segment_water, rejected = false }
        end
        return { anchor = pos, water_crossed = water_crossed }
      end
      -- Land reached after a too-narrow crossing (river, puddle). Reset the
      -- segment counter and keep walking toward the pollution direction.
      if trace and segment_water > 0 then
        trace[#trace + 1] = { w = segment_water, rejected = true }
      end
      segment_water = 0
    end

    distance = distance + step
  end

  if trace and segment_water > 0 then
    trace[#trace + 1] = { w = segment_water, rejected = true, maxdist = true }
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
  local debug_on = setting("omb-debug") and attempt.force_run and attempt.player_index
  local trace = debug_on and {} or nil
  local min_water = setting("omb-min-water-tiles")
  local scan_step = setting("omb-scan-step")
  local anchor_hit = ray_to_beach_anchor(
    surface, beach.source, direction,
    min_water,
    scan_step,
    1024, trace)

  if debug_on then
    local player = game.get_player(attempt.player_index)
    if player and player.valid then
      local parts = {}
      for i, seg in ipairs(trace) do
        local marker
        if seg.ungenerated then
          marker = "ungen"
        elseif seg.maxdist then
          marker = "maxdist"
        elseif seg.rejected then
          marker = "skip"
        else
          marker = "LAND"
        end
        parts[i] = string.format("%d(%s)", seg.w, marker)
      end
      local outcome
      if anchor_hit then
        outcome = string.format("landed @[%d,%d] total=%d",
          math.floor(anchor_hit.anchor.x),
          math.floor(anchor_hit.anchor.y),
          anchor_hit.water_crossed)
      else
        outcome = "no landing"
      end
      player.print(string.format(
        "OMB ray [fan %+d°] min=%d step=%d segments: %s → %s",
        offset, min_water, scan_step,
        (#parts > 0) and table.concat(parts, " ") or "none",
        outcome))
    end
  end

  if not anchor_hit then
    beach.fan_i = beach.fan_i + 1
    try_ray(surface_index, attempt)
    return
  end

  -- Find the spawner's collision center as close to the shoreline anchor
  -- as possible. Radius 6 is just enough to clear a 5x5 spawner footprint
  -- off the water. The drift cap below (8 tiles) then rejects rays whose
  -- nearest valid spot is further inland than a typical spawner half-width +
  -- slack — keeping beachheads on the shoreline instead of walking them in.
  local drifted = surface.find_non_colliding_position(
    beach.spawner_name, anchor_hit.anchor, 6, 1, true)

  if not drifted then
    beach.fan_i = beach.fan_i + 1
    try_ray(surface_index, attempt)
    return
  end

  local drift_distance_sq = distance_sq(drifted, anchor_hit.anchor)
  local drift_distance = math.sqrt(drift_distance_sq)

  if setting("omb-debug") and attempt.force_run and attempt.player_index then
    local player = game.get_player(attempt.player_index)
    if player and player.valid then
      player.print(string.format(
        "OMB drift: anchor @[%d,%d] → spawner @[%d,%d] (%.1f tiles inland)",
        math.floor(anchor_hit.anchor.x), math.floor(anchor_hit.anchor.y),
        math.floor(drifted.x), math.floor(drifted.y),
        drift_distance))
    end
  end

  if drift_distance_sq > (8 * 8) then
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

  local source_entity = attempt.current.entity
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

end_attempt = function(surface_index, reason, extra)
  local surface_state_entry = storage.omb.surfaces[surface_index]
  if not surface_state_entry then return end
  local attempt = surface_state_entry.attempt
  if not attempt then return end

  if attempt.force_run or setting("omb-debug") then
    attempt_reply(attempt, "Ocean Migration: " .. reason)
  end

  surface_state_entry.attempt = nil
end

issue_candidate_paths = function(surface_index, attempt)
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

  -- Store the LuaEntity reference directly. game.get_entity_by_unit_number
  -- silently returns nil for unit-spawner prototypes in Factorio 2.0 because
  -- they lack the get-by-unit-number prototype flag (confirmed against the
  -- 2.0.76 Runtime Docs). Stored references remain valid until the entity is
  -- destroyed and are the canonical way to carry an entity across ticks.
  attempt.current = {
    unit_number = candidate.unit_number,
    entity = entity,
    nest_position = { x = entity.position.x, y = entity.position.y },
    spawner_name = entity.name,
    wall_result = "pending",
    pollution_result = "pending",
    wall_target = nil,
  }

  -- Path A: nearest wall, if any.
  local wall_pos = nearest_wall(attempt.wall_index, entity.position)
  if wall_pos then
    attempt.current.wall_target = { x = wall_pos.x, y = wall_pos.y }
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

  -- Apply the sample cap with a guaranteed-near + stratified-far split
  -- rather than a plain nearest-N truncation. Guarantees the sample spans
  -- the full distance range to pollution, so water-isolated clusters far
  -- from the factory aren't silently dropped when the mainland is dense.
  -- The stratified branch uses an endpoint-inclusive stride so the very
  -- farthest chunk-rep is always in the sample (handles the case where an
  -- isolated island sits at the extreme far end of the sorted list with
  -- no mainland beyond it).
  local max_samples = setting("omb-max-samples-per-attempt")
  if #candidates > max_samples then
    local guaranteed = math.max(1, math.floor(max_samples / 3))
    if guaranteed > max_samples then
      guaranteed = max_samples
    end
    local remaining = max_samples - guaranteed

    local sampled = {}
    for i = 1, guaranteed do
      sampled[i] = candidates[i]
    end

    if remaining > 0 then
      local pool_start = guaranteed + 1
      local pool_end = #candidates
      local pool_size = pool_end - pool_start + 1
      if pool_size > 0 then
        if pool_size <= remaining then
          for i = 1, pool_size do
            sampled[guaranteed + i] = candidates[pool_start + i - 1]
          end
        elseif remaining == 1 then
          sampled[guaranteed + 1] = candidates[pool_end]
        else
          -- Endpoint-inclusive: divide the span (pool_size - 1) across
          -- (remaining - 1) steps so i=1 hits pool_start and i=remaining
          -- hits pool_end. The +0.5 rounds to the nearest integer index
          -- instead of always flooring.
          local span = pool_size - 1
          local stride = span / (remaining - 1)
          for i = 1, remaining do
            local idx = pool_start + math.floor((i - 1) * stride + 0.5)
            if idx > pool_end then idx = pool_end end
            sampled[guaranteed + i] = candidates[idx]
          end
        end
      end
    end

    candidates = sampled
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

local function housekeep(event)
  ensure_storage()
  local now = event.tick

  -- Reissue paths that came back with try_again_later.
  local to_reissue = {}
  for id, pending in pairs(storage.omb.pending_paths) do
    if pending.try_again_later and
       (now - pending.issued_tick) >= PATH_RETRY_GAP_TICKS then
      to_reissue[#to_reissue + 1] = { id = id, pending = pending }
    end
  end

  for _, item in ipairs(to_reissue) do
    storage.omb.pending_paths[item.id] = nil
    local pending = item.pending
    if pending.retries < PATH_RETRY_MAX then
      local surface = game.surfaces[pending.surface_index]
      if surface and surface.valid then
        local new_id = surface.request_path({
          bounding_box = PATH_BOUNDING_BOX,
          collision_mask = resolve_source_collision_mask(pending.spawner_name),
          start = pending.start,
          goal = pending.goal,
          force = game.forces.enemy,
          radius = PATH_RADIUS,
          pathfind_flags = {
            allow_destroy_friendly_entities = false,
            cache = true,
            low_priority = true,
            prefer_straight_paths = false,
          },
        })

        if new_id then
          storage.omb.pending_paths[new_id] = {
            surface_index = pending.surface_index,
            purpose = pending.purpose,
            issued_tick = now,
            retries = pending.retries + 1,
            start = pending.start,
            goal = pending.goal,
            spawner_name = pending.spawner_name,
          }
        end
      end
    else
      -- Retry budget exhausted; treat as hard failure.
      local surface_state_entry = storage.omb.surfaces[pending.surface_index]
      local attempt = surface_state_entry and surface_state_entry.attempt
      if attempt then
        if pending.purpose == "wall" then
          resolve_wall(pending.surface_index, attempt, false)
        elseif pending.purpose == "pollution" then
          resolve_pollution(pending.surface_index, attempt, false)
        elseif pending.purpose == "beach" then
          resolve_beach(pending.surface_index, attempt, false)
        end
      end
    end
  end

  -- Orphan cleanup: any attempt older than ATTEMPT_ORPHAN_TICKS is cleared.
  for surface_index, state in pairs(storage.omb.surfaces) do
    if state.attempt and (now - state.attempt.started_tick) > ATTEMPT_ORPHAN_TICKS then
      if setting("omb-debug") then
        game.print(
          "Ocean Migration: clearing orphan attempt on surface " ..
          tostring(surface_index) ..
          " after " .. tostring(now - state.attempt.started_tick) .. " ticks.")
      end
      state.attempt = nil
    end
  end

  -- Sweep pending_paths entries whose attempt is gone.
  for id, pending in pairs(storage.omb.pending_paths) do
    local state = storage.omb.surfaces[pending.surface_index]
    if not (state and state.attempt) then
      storage.omb.pending_paths[id] = nil
    end
  end
end

script.on_nth_tick(10, housekeep)

script.on_init(function()
  ensure_storage()
end)

script.on_configuration_changed(function()
  ensure_storage()
  storage.omb.pending_paths = {}
  for _, state in pairs(storage.omb.surfaces) do
    state.attempt = nil
  end

  -- Migration: on saves made before 0.4.8, omb-scan-step defaulted to 16 and
  -- omb-min-water-tiles defaulted to 64. Both are too coarse and cause the
  -- ray to miss narrow straits or drift the landing tens of tiles inland.
  -- If either setting is still at its pre-0.4.8 default, lower it to the
  -- new default so the user benefits immediately without hunting settings.
  -- We only touch settings that match the EXACT old default; any hand-tuned
  -- value (8, 12, 32, …) is left alone — the assumption that someone who
  -- set it to 16 is a user who never changed it, is fair.
  if settings.global["omb-scan-step"] and
     settings.global["omb-scan-step"].value == 16 then
    settings.global["omb-scan-step"] = { value = 4 }
    game.print(
      "Ocean Migration: omb-scan-step auto-lowered from 16 to 4 for accurate " ..
      "shoreline detection on updated save. See Mod Settings → Runtime → " ..
      "Ocean Migration to change it back if you want.")
  end
  if settings.global["omb-min-water-tiles"] and
     settings.global["omb-min-water-tiles"].value == 64 then
    settings.global["omb-min-water-tiles"] = { value = 8 }
    game.print(
      "Ocean Migration: omb-min-water-tiles auto-lowered from 64 to 8 so " ..
      "narrower straits count as ocean crossings. See Mod Settings if you " ..
      "want a stricter threshold.")
  end
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

commands.add_command(
  "omb-reset",
  "Reset Ocean Migration counters.",
  function(command)
    local player = command.player_index and game.get_player(command.player_index) or nil
    if player and not player.admin then
      player.print("Only admins can use /omb-reset.")
      return
    end

    storage.omb = { surfaces = {}, pending_paths = {} }
    game.print({ "ocean-migration-beachheads.beachheads-reset" })
  end)

commands.add_command(
  "omb-diagnose",
  "Admin only. Prints the Ocean Migration algorithm's view of the current surface. Read-only.",
  function(command)
    local player = command.player_index and game.get_player(command.player_index) or nil
    if not player then return end
    if not player.admin then
      player.print("Only admins can use /omb-diagnose.")
      return
    end

    local surface = player.surface
    local lines = {}

    -- Surface eligibility.
    lines[#lines + 1] = string.format("Surface: %s (eligible=%s)",
      surface.name, tostring(eligible_surface(surface)))

    -- Pollution.
    local pollution = find_highest_pollution_chunk(surface)
    if pollution then
      lines[#lines + 1] = string.format(
        "Highest-pollution chunk: [gps=%d,%d,%s] value=%.0f",
        math.floor(pollution.position.x),
        math.floor(pollution.position.y),
        surface.name,
        pollution.value)
    else
      lines[#lines + 1] = "No pollution on this surface — nothing to migrate toward."
    end

    -- Candidate preview.
    if pollution then
      local candidates = gather_sorted_candidates(surface, pollution.position)
      lines[#lines + 1] = string.format(
        "Enemy unit-spawners on surface: %d. Sorted by distance to pollution.",
        #candidates)

      local closest = candidates[1]
      if closest and closest.entity and closest.entity.valid then
        local d = math.sqrt(closest.distance_sq)
        lines[#lines + 1] = string.format(
          "Nearest-to-pollution spawner: %s [gps=%d,%d,%s] dist=%.0f tiles",
          closest.entity.name,
          math.floor(closest.position.x),
          math.floor(closest.position.y),
          surface.name,
          d)

        -- Straight-line ray summary (geometry only, no pathfinder).
        local dir = { x = pollution.position.x - closest.position.x,
                      y = pollution.position.y - closest.position.y }
        local length = math.sqrt(dir.x * dir.x + dir.y * dir.y)
        if length > 0 then
          dir.x = dir.x / length
          dir.y = dir.y / length
        end
        local step = setting("omb-scan-step")
        local water_count = 0
        local land_hit = nil
        for distance = step, math.min(length, 1024), step do
          local p = {
            x = closest.position.x + dir.x * distance,
            y = closest.position.y + dir.y * distance,
          }
          if not is_generated(surface, p) then break end
          if is_water_tile(surface, p) then
            water_count = water_count + step
          elseif water_count > 0 then
            land_hit = p
            break
          end
        end
        if land_hit then
          lines[#lines + 1] = string.format(
            "Ray summary: crosses ~%d water tiles, hits land at [gps=%d,%d,%s]",
            water_count,
            math.floor(land_hit.x),
            math.floor(land_hit.y),
            surface.name)
        else
          lines[#lines + 1] = string.format(
            "Ray summary: %d water tiles crossed, no land hit within range",
            water_count)
        end
      end
    end

    -- Walls.
    local wall_count = 0
    for _, entity in ipairs(surface.find_entities_filtered({
      force = player.force, type = { "wall", "gate" } })) do
      if entity.valid then wall_count = wall_count + 1 end
    end
    lines[#lines + 1] = string.format("Player-force walls/gates on surface: %d",
                                      wall_count)

    -- Budget, cooldown, evolution.
    local state = surface_state(surface)
    local remaining = math.max(0, (state.next_tick or 0) - game.tick)
    local enemy = game.forces.enemy
    local evolution = enemy and get_evolution(enemy, surface) or 0
    lines[#lines + 1] = string.format(
      "Budget: %d/%d. Cooldown: %d min remaining. Evolution: %.3f.",
      math.floor(state.budget or 0),
      setting("omb-budget-max"),
      math.ceil(remaining / TICKS_PER_MINUTE),
      evolution)

    if state.attempt then
      lines[#lines + 1] = string.format(
        "In-flight attempt: stage=%s, age=%d ticks, candidate_i=%d/%d",
        state.attempt.stage,
        game.tick - state.attempt.started_tick,
        state.attempt.candidate_i or 0,
        #(state.attempt.candidates or {}))
    end

    for _, line in ipairs(lines) do
      player.print(line)
    end
  end)

commands.add_command(
  "omb-status",
  "Show Ocean Migration status for the current surface.",
  function(command)
    local player = command.player_index and game.get_player(command.player_index) or nil
    if not player then return end

    local state = surface_state(player.surface)
    local remaining = math.max(0, (state.next_tick or 0) - game.tick)
    player.print({
      "ocean-migration-beachheads.status",
      state.beachheads or 0,
      player.surface.name,
      math.floor(state.budget or 0),
      setting("omb-budget-max"),
      math.ceil(remaining / TICKS_PER_MINUTE),
    })

    if state.attempt then
      player.print(string.format(
        "Migration check in progress (stage: %s, started tick %d, age %d ticks).",
        state.attempt.stage,
        state.attempt.started_tick,
        game.tick - state.attempt.started_tick))
    end
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
