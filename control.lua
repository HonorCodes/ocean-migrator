local TICKS_PER_MINUTE = 60 * 60
local CHECK_INTERVAL = 60 * 60
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
end

local function surface_state(surface)
  ensure_storage()
  local index = surface.index
  storage.omb.surfaces[index] = storage.omb.surfaces[index] or {
    beachheads = 0,
    next_tick = 0,
    budget = 0,
    last_budget_tick = game and game.tick or 0
  }
  storage.omb.surfaces[index].budget = storage.omb.surfaces[index].budget or 0
  storage.omb.surfaces[index].last_budget_tick = storage.omb.surfaces[index].last_budget_tick or (game and game.tick or 0)
  return storage.omb.surfaces[index]
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

local function available_spawners()
  local names = {}

  if not prototypes or not prototypes.entity or prototypes.entity["biter-spawner"] then
    names[#names + 1] = "biter-spawner"
  end

  if not prototypes or not prototypes.entity or prototypes.entity["spitter-spawner"] then
    names[#names + 1] = "spitter-spawner"
  end

  if setting("omb-use-water-spitters") and prototypes and prototypes.entity and prototypes.entity["water-biter-spawner"] then
    names[#names + 1] = "water-biter-spawner"
  end

  return names
end

local function choose_spawner(names)
  if #names == 1 then
    return names[1]
  end

  return names[math.random(#names)]
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

  for distance = step, max_water, step do
    local pos = {
      x = source.x + direction.x * distance,
      y = source.y + direction.y * distance
    }

    if not is_generated(surface, pos) then
      return nil
    end

    if is_water_tile(surface, pos) then
      water_start = water_start or distance
      saw_water = true
      water_distance = distance - water_start + step
    elseif saw_water then
      if water_distance >= min_water then
        return {
          x = pos.x,
          y = pos.y,
          crossed = water_distance
        }
      else
        return nil
      end
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

  create_landfall(surface, landfall, landfall_radius, tile_name)

  for _ = 1, nest_count do
    local name = choose_spawner(spawner_names)
    local radius = math.max(landfall_radius + 8, 16)
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
      end
    end
  end

  return placed
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

  for _, player in pairs(game.connected_players) do
    if valid_player(player) and player.surface == surface then
      local entities = surface.find_entities_filtered({
        position = player.position,
        radius = radius,
        force = "enemy",
        type = "unit-spawner"
      })

      for _, entity in ipairs(entities) do
        if entity.valid and not seen[entity.unit_number] then
          seen[entity.unit_number] = true
          found[#found + 1] = entity
        end
      end
    end
  end

  return found
end

local function attempt_surface_migration(surface, event_tick)
  local state = surface_state(surface)
  local enemy = game.forces.enemy
  if not enemy then
    return
  end

  local evolution = get_evolution(enemy, surface)
  update_budget(surface, state, event_tick, evolution)

  if state.next_tick and event_tick < state.next_tick then
    debug_print(surface, "cooldown")
    return
  end

  if state.beachheads >= setting("omb-max-beachheads-per-surface") then
    debug_print(surface, "surface cap")
    return
  end

  if evolution < setting("omb-min-evolution") then
    debug_print(surface, "evolution threshold")
    return
  end

  local spawner_names = available_spawners()
  if #spawner_names == 0 then
    debug_print(surface, "no spawner prototypes")
    return
  end

  local spawners = find_enemy_spawners(surface)
  if #spawners == 0 then
    debug_print(surface, "no nearby enemy spawners")
    return
  end

  local sampled = shuffled_entities(spawners, setting("omb-max-samples-per-attempt"))
  local min_water = setting("omb-min-water-tiles")
  local max_water = setting("omb-max-water-tiles")
  local step = setting("omb-scan-step")
  local min_player_distance = setting("omb-min-distance-from-player")

  for _, spawner in ipairs(sampled) do
    if spawner.valid then
      local target = nearest_player_position(surface, spawner.position)
      if target then
        for _, direction in ipairs(candidate_directions(spawner.position, target)) do
          local landfall = find_landfall(surface, spawner.position, direction, min_water, max_water, step)
          if landfall and away_from_players(surface, landfall, min_player_distance) then
            local cost = migration_cost(landfall)
            if (state.budget or 0) < cost then
              debug_print(surface, "budget " .. math.floor(state.budget or 0) .. "/" .. cost)
              return
            end

            local placed = place_beachhead(surface, landfall, spawner_names)
            if placed > 0 then
              state.budget = math.max(0, (state.budget or 0) - cost)
              state.beachheads = state.beachheads + 1
              state.next_tick = event_tick + setting("omb-cooldown-minutes") * TICKS_PER_MINUTE
              chart_for_players(surface, landfall)

              if setting("omb-notify") then
                game.print({ "ocean-migration-beachheads.beachhead-created", surface.name, math.floor(landfall.x), math.floor(landfall.y), cost, math.floor(landfall.crossed or 0) })
              end

              return
            end
          end
        end
      end
    end
  end
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
        game.print({ "ocean-migration-beachheads.debug-skip", "non-planet surface", player.surface.name })
      end
    end
  end

  for _, surface in pairs(surfaces) do
    if surface.valid then
      attempt_surface_migration(surface, event.tick)
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
