# Pollution-Directed Migration Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace Ocean Migration's ray-based crossing detector with a pollution-directed, pathfinder-driven decision model, landing beachheads on the coastal shore nearest each marooned biter cluster.

**Architecture:** An async state machine per surface (`enumerate → check_candidate → validate_beach`) driven by `on_script_path_request_finished`. Source nests are deemed marooned only when they can reach neither the nearest player wall/gate nor the highest-pollution chunk. Beachhead placement casts a ray with an angular fan and validates each candidate with `find_non_colliding_position` plus a final pathfinder round-trip. Existing spawner-prototype selection, surface filtering, budget accounting, and `place_beachhead` are preserved.

**Tech Stack:** Lua 5.2 (Factorio 2.0 modding runtime), Factorio 2.0 mod API (`LuaSurface::request_path`, `LuaSurface::get_pollution`, `surface.find_entities_filtered`, `surface.find_non_colliding_position`).

---

## Reference spec

`docs/specs/2026-04-22-pollution-directed-migration-design.md` — binding for algorithm, state machine, storage schema, commands, settings, and edge cases. Every task below cites its spec section. If the plan disagrees with the spec, follow the spec and flag the plan issue.

## Implementer notes

- **No unit test harness.** Factorio mods run inside the game runtime; there is no pytest/busted equivalent the project uses. Verification is manual: load the mod in Factorio 2.0, observe no startup errors, then exercise the feature in-game or via console commands. Each task includes an explicit "verify" step.
- **Optional static lint.** `luacheck` is not installed on the dev box. If the implementer installs it (`luarocks install luacheck`), run it after each task. If unavailable, skip silently.
- **Branch.** All work happens on `feat/pollution-directed-migration` (created in Task 1). Merges back to `main` only after the full test matrix passes (Task 19).
- **Commit messages.** Match the repo's existing `type: subject` style. Markdown commits get a nominal `[rag:1]` suffix because the global commit-msg hook treats `docs/**/*.md` and root `README.md` as RAG-relevant by path; code-only commits don't need the tag. No AI attribution, no `Co-Authored-By` lines.
- **Pathfinder API caveat.** Before Task 6 lands, cross-check `LuaSurface::request_path` and `LuaEntityPrototype::collision_mask` against the [Factorio 2.0 API docs](https://lua-api.factorio.com/stable/classes/LuaSurface.html). The signatures below match the public API as of this plan's date but Factorio API can shift between patch versions.
- **Testing save.** Use a save that matches the design doc's screenshot: island start on Nauvis with biter-only SW and SE islands and an established mainland base. If the implementer doesn't have one, Task 19 step 1 is to build one.

## Open questions from the spec — resolved for this plan

- **Pollution chunk iteration strategy (spec §12.1).** Use `surface.get_chunks()` + `surface.get_pollution(chunk_center)` per chunk. Trivially fast below ~20k chunks; revisit only if a user reports UPS cost.
- **`/omb-diagnose` ray-hits summary (spec §12.2).** Ship it. One extra line in a read-only admin command. Strip in a later version if it becomes noise.
- **`/omb-force --verbose` (spec §12.3).** Do not add. Three-line `/omb-force` + `/omb-diagnose` covers the troubleshooting case. Adding a verbose flag later is non-breaking.

## File structure

| Path | Status | Responsibility |
|---|---|---|
| `info.json` | modify | version bump 0.3.3 → 0.4.0 |
| `settings.lua` | modify | remove `omb-source-search-radius`, `omb-max-water-tiles` |
| `control.lua` | modify | core algorithm, state machine, commands, event handlers |
| `locale/en/ocean-migration-beachheads.cfg` | modify | add ~10 new strings |
| `README.md` | modify | behavior summary, commands list, current status |
| `docs/project-summary.md` | modify | sync algorithm description and known gotchas |
| `docs/to-do.md` | modify | close items 1, 2, 5; annotate 3, 4 |
| `docs/test-plan.md` | create | 12-item acceptance matrix for 0.4.0 |
| `docs/plans/2026-04-22-pollution-directed-migration-impl.md` | create | this plan |
| `docs/specs/2026-04-22-pollution-directed-migration-design.md` | unchanged | reference spec |

`control.lua` stays as one file. It ends up at roughly 900–1000 lines (up from 769). Splitting is not worth the cost: Factorio mods idiomatically use a single `control.lua`, and the new surface area is tightly coupled to existing helpers.

---

## Task 1: Create branch and bump version

**Spec references:** §11 (Rollout).

**Files:**
- Create branch `feat/pollution-directed-migration`
- Modify: `info.json`

- [ ] **Step 1: Create feature branch**

```bash
cd /home/honor/src/honorcodes/ocean-migrator
git switch -c feat/pollution-directed-migration
```

Expected: `Switched to a new branch 'feat/pollution-directed-migration'`.

- [ ] **Step 2: Bump version in `info.json`**

Change `"version": "0.3.3"` to `"version": "0.4.0"`.

```json
{
  "name": "ocean-migration",
  "version": "0.4.0",
  "title": "Ocean Migration",
  "author": "Honor",
  "factorio_version": "2.0",
  "dependencies": [
    "base >= 2.0"
  ],
  "description": "Have you ever spawned on an island and killed all of the natives, then felt a bit lonely? This mod allows biters to migrate back, so you'll never be alone again! Aren't you happy your friends are back?\n\nNote: should be fully compatible with Rampant and Krastorio 2. Good in large biter modpacks."
}
```

- [ ] **Step 3: Commit**

```bash
git add info.json
git commit -m "chore: bump version to 0.4.0 for pollution-directed migration"
```

- [ ] **Step 4: Verify the mod still loads**

Launch Factorio 2.0, enable Ocean Migration in the mod list, start/load any save. Confirm no red error banners at startup. Exit.

---

## Task 2: Extend storage schema

**Spec references:** §5.1 (storage layout), §5.8 (one-attempt lock).

**Files:**
- Modify: `control.lua` (`ensure_storage`, `surface_state`)

- [ ] **Step 1: Update `ensure_storage` to initialize `pending_paths`**

Replace the existing `ensure_storage` (currently at `control.lua:14-17`):

```lua
local function ensure_storage()
  storage.omb = storage.omb or {}
  storage.omb.surfaces = storage.omb.surfaces or {}
  storage.omb.pending_paths = storage.omb.pending_paths or {}
end
```

- [ ] **Step 2: Update `surface_state` to initialize the `attempt` field**

Replace the existing `surface_state` (currently at `control.lua:19-31`):

```lua
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
```

- [ ] **Step 3: Commit**

```bash
git add control.lua
git commit -m "feat: extend storage schema for async migration attempts"
```

- [ ] **Step 4: Verify — fresh init and save/load cycle**

Load Factorio → new game with Ocean Migration enabled → save → exit → reload the save. Run `/omb-status` in-game and confirm no errors. Exit.

---

## Task 3: Pollution chunk helper

**Spec references:** §4.1 (Target selection).

**Files:**
- Modify: `control.lua` (new function `find_highest_pollution_chunk`)

- [ ] **Step 1: Add the function**

Insert into `control.lua` after the existing `chunk_position` helper (currently at `control.lua:139-141`):

```lua
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
```

Return shape: `nil` when the surface has no pollution, else `{ position = {x, y}, value = number }`.

- [ ] **Step 2: Commit**

```bash
git add control.lua
git commit -m "feat: add find_highest_pollution_chunk helper"
```

- [ ] **Step 3: Verify — syntax loads**

Launch Factorio, enable mod, load any save. No error banner = Lua parsed. We cannot call the function yet (no command wiring); integration verification happens in Task 16 via `/omb-diagnose`.

---

## Task 4: Candidate gathering

**Spec references:** §4.2 (Candidate gathering).

**Files:**
- Modify: `control.lua` (new function `gather_sorted_candidates`)

- [ ] **Step 1: Add the function**

Insert into `control.lua` after the existing `find_enemy_spawners` function (currently at `control.lua:564-598`):

```lua
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
```

Caller contract: returns an ordered array of `{ unit_number, position, distance_sq, entity }`; entity reference is live at return time but may become invalid by the time a callback arrives — always re-check `entity.valid` on use.

- [ ] **Step 2: Commit**

```bash
git add control.lua
git commit -m "feat: add gather_sorted_candidates for pollution-keyed ordering"
```

- [ ] **Step 3: Verify — syntax loads**

Launch Factorio, enable mod, load any save. No error banner.

---

## Task 5: Wall index with spatial buckets

**Spec references:** §4.3 (Wall index), §5.1 (`wall_index` storage shape).

**Files:**
- Modify: `control.lua` (new functions `build_wall_index`, `nearest_wall`, constant `WALL_BUCKET_SIZE`)

- [ ] **Step 1: Add the bucket constant near the other top-of-file constants (before `DIRECTIONS`)**

```lua
local WALL_BUCKET_SIZE = 256
```

- [ ] **Step 2: Add `build_wall_index` and `nearest_wall`**

Insert after `gather_sorted_candidates`:

```lua
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
```

- [ ] **Step 3: Commit**

```bash
git add control.lua
git commit -m "feat: add spatial wall index for nearest-wall pathfinder targeting"
```

- [ ] **Step 4: Verify — syntax loads**

Launch Factorio, enable mod, load any save. No error banner.

---

## Task 6: Path request infrastructure

**Spec references:** §4.4.1 (pathfinder arguments), §5.4 (callback routing), §5.7 (entity invalidation).

**Files:**
- Modify: `control.lua` (new helpers `resolve_source_collision_mask`, `issue_path_request`, stubs for `resolve_wall`, `resolve_pollution`, `resolve_beach`, `on_script_path_request_finished` handler)

**Pathfinder API note:** Before writing this task, open https://lua-api.factorio.com/stable/classes/LuaSurface.html#request_path and confirm the argument names below match. The shape has been stable in 2.0.x but re-verify against the current patch version.

- [ ] **Step 1: Add constants and `resolve_source_collision_mask`**

Insert near the top of `control.lua`, just after `WALL_BUCKET_SIZE`:

```lua
local PATH_RETRY_MAX = 3
local PATH_RETRY_GAP_TICKS = 30
local PATH_RADIUS = 8
local PATH_BOUNDING_BOX = { { -0.4, -0.4 }, { 0.4, 0.4 } }
local ATTEMPT_ORPHAN_TICKS = 600
```

Then add `resolve_source_collision_mask` after `build_wall_index`/`nearest_wall`:

```lua
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
```

- [ ] **Step 2: Add `issue_path_request`**

Insert after `resolve_source_collision_mask`:

```lua
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
```

- [ ] **Step 3: Add stubbed `resolve_wall`, `resolve_pollution`, `resolve_beach`**

Insert after `issue_path_request`:

```lua
-- These three are filled out in Tasks 8 and 9. The stub body exists so the
-- event handler below can route without NPE'ing.
local function resolve_wall(surface_index, attempt, success)
end

local function resolve_pollution(surface_index, attempt, success)
end

local function resolve_beach(surface_index, attempt, success)
end
```

- [ ] **Step 4: Add the `on_script_path_request_finished` event handler**

Insert near the bottom of `control.lua`, just above the existing `commands.add_command` calls (currently starting at `control.lua:717`):

```lua
script.on_event(defines.events.on_script_path_request_finished, function(event)
  ensure_storage()
  local pending = storage.omb.pending_paths[event.id]
  if not pending then
    return
  end

  if event.try_again_later then
    -- Retry logic is added in Task 12 via the housekeeping tick. Here we mark
    -- and bail so the housekeeper picks it up on the next pass.
    pending.try_again_later = true
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
```

- [ ] **Step 5: Commit**

```bash
git add control.lua
git commit -m "feat: add pathfinder request infrastructure and event routing"
```

- [ ] **Step 6: Verify — syntax loads, handler registers**

Launch Factorio, enable mod, load any save. No error banner. No console error about duplicate event registration.

---

## Task 7: Attempt start and enumerate stage

**Spec references:** §4.1, §4.2, §4.3 (enumerate stage), §5.3 (stage transitions), §5.8 (one-attempt lock).

**Files:**
- Modify: `control.lua` (new function `start_attempt`; minor extension to `resolve_*` stubs for transition coupling, added in Tasks 8–9)

- [ ] **Step 1: Add `end_attempt` helper and attempt-reply routing**

Insert after the resolve stubs, before the event handler:

```lua
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
```

- [ ] **Step 2: Add `issue_candidate_paths` helper**

Insert after `end_attempt`:

```lua
local function issue_candidate_paths(surface_index, attempt)
  local surface = game.surfaces[surface_index]
  if not surface or not surface.valid then
    end_attempt(surface_index, "surface became invalid")
    return
  end

  local candidate = attempt.candidates[attempt.candidate_i]
  if not candidate then
    end_attempt(surface_index, "no marooned nests found (queue exhausted)")
    return
  end

  local entity = candidate.entity
  if not (entity and entity.valid) then
    -- Stale; advance without issuing requests.
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
    attempt.current.wall_result = "skip"
  end

  -- Path B: pollution chunk.
  issue_path_request(surface, entity.position, attempt.pollution_chunk,
                     "pollution", surface_index, entity.name)
end
```

- [ ] **Step 3: Add `start_attempt`**

Insert after `issue_candidate_paths`:

```lua
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
  local wall_force = game.forces.player
  if player_index then
    local player = game.get_player(player_index)
    if player and player.valid then wall_force = player.force end
  end

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
```

- [ ] **Step 4: Commit**

```bash
git add control.lua
git commit -m "feat: add start_attempt and enumerate stage driver"
```

- [ ] **Step 5: Verify — syntax loads**

Launch Factorio, enable mod, load any save. No error banner. `start_attempt` has no caller yet; wiring lands in Task 11.

---

## Task 8: check_candidate resolution

**Spec references:** §4.4 (iterate candidates), §5.3 (stage transitions), §5.7 (cancellation on destruction).

**Files:**
- Modify: `control.lua` (flesh out `resolve_wall`, `resolve_pollution`, add `advance_candidate`, `start_beach_search` stub)

- [ ] **Step 1: Replace the three resolve stubs with real implementations for wall + pollution**

Find the stubs added in Task 6 (the three empty `resolve_*` functions). Replace `resolve_wall`, `resolve_pollution`, and add `advance_candidate` + `start_beach_search` stub. Leave `resolve_beach` as a stub — it's fleshed out in Task 9.

```lua
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

-- resolve_beach stays a stub here; filled in Task 9.
local function resolve_beach(surface_index, attempt, success)
end
```

**Ordering note:** `start_beach_search` is forward-declared as `local` without an assignment, then assigned in Task 9. Lua upvalue semantics require the name to be declared (as `local start_beach_search`) in the same scope before first use. Keep the declaration at the top of the block.

- [ ] **Step 2: Also add a "no marooned nests" reply for `/omb-force` on queue exhaustion**

In `issue_candidate_paths` from Task 7, the `if not candidate then end_attempt(...)` branch should produce a player-visible message on `/omb-force`. Update the top of `issue_candidate_paths`:

Old:

```lua
  local candidate = attempt.candidates[attempt.candidate_i]
  if not candidate then
    end_attempt(surface_index, "no marooned nests found (queue exhausted)")
    return
  end
```

New:

```lua
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
```

- [ ] **Step 3: Commit**

```bash
git add control.lua
git commit -m "feat: wire check_candidate resolution and transition"
```

- [ ] **Step 4: Verify — syntax loads**

Launch Factorio, load any save. No error banner.

---

## Task 9: validate_beach stage

**Spec references:** §4.5 (Land the beachhead), §5.3 (`validate_beach` stage).

**Files:**
- Modify: `control.lua` (add `ray_to_beach_anchor`, `try_ray`, `advance_ray_fan`, real `start_beach_search` and `resolve_beach`)

- [ ] **Step 1: Add ray helper**

Insert after `on_current_both_resolved`:

```lua
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
```

- [ ] **Step 2: Add `try_ray`, `advance_ray_fan`, `start_beach_search`**

Insert after `ray_to_beach_anchor`:

```lua
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

local function direction_from_source_to_pollution(source, pollution)
  local dx = pollution.x - source.x
  local dy = pollution.y - source.y
  local length = math.sqrt(dx * dx + dy * dy)
  if length < 1 then return nil end
  return { x = dx / length, y = dy / length }
end

start_beach_search = function(surface_index, attempt)
  try_ray(surface_index, attempt)
end
```

**Ordering:** `direction_from_source_to_pollution` is referenced by `try_ray`. Lua resolves `local` bindings lexically in file order; place the declaration ABOVE `try_ray`'s definition, or hoist it to before `try_ray`. The block above intentionally orders: `offset_direction`, `ray_to_beach_anchor`, `direction_from_source_to_pollution`, `try_ray`, `advance_ray_fan`, `start_beach_search`. Reorder if paste order differs.

- [ ] **Step 3: Replace the `resolve_beach` stub with real logic**

Locate the stub from Task 6 (`local function resolve_beach(surface_index, attempt, success) end`). Replace with:

```lua
local function resolve_beach(surface_index, attempt, success)
  if not attempt.beach then return end
  if not success then
    advance_ray_fan(surface_index, attempt)
    return
  end

  -- On success, finalize spawn. This calls into Task 10's spawn helper.
  finalize_beachhead_spawn(surface_index, attempt)
end
```

- [ ] **Step 4: Forward-declare `finalize_beachhead_spawn`**

Where `resolve_beach` is, above it, add:

```lua
-- Forward declaration; defined in Task 10.
local finalize_beachhead_spawn = function(surface_index, attempt) end
```

This is a placeholder — Task 10 replaces it with real spawn logic. Keep as `local` so name resolution works even before Task 10 lands.

- [ ] **Step 5: Commit**

```bash
git add control.lua
git commit -m "feat: add validate_beach stage with ray fan and path validation"
```

- [ ] **Step 6: Verify — syntax loads**

Launch Factorio, load any save. No error banner.

---

## Task 10: Cost check and spawn integration

**Spec references:** §4.6 (Cost and commit), §4.7 (Spawn).

**Files:**
- Modify: `control.lua` (replace `finalize_beachhead_spawn` placeholder with real implementation)

- [ ] **Step 1: Replace the `finalize_beachhead_spawn` placeholder**

Find the placeholder from Task 9 step 4. Replace with:

```lua
finalize_beachhead_spawn = function(surface_index, attempt)
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
```

- [ ] **Step 2: Commit**

```bash
git add control.lua
git commit -m "feat: finalize beachhead spawn with cost, chart, and notify"
```

- [ ] **Step 3: Verify — syntax loads**

Launch Factorio, load any save. No error banner.

---

## Task 11: Wire `/omb-force` and scheduled tick to the new state machine

**Spec references:** §6.1 (`/omb-force` reply sequence), §5.8 (attempt lock).

**Files:**
- Modify: `control.lua` (replace `attempt_surface_migration`, `check_all_surfaces`, `/omb-force` command body)

- [ ] **Step 1: Delete the old `attempt_surface_migration` body and replace with a thin wrapper**

Locate `attempt_surface_migration` (currently at `control.lua:600-682`). Delete its entire body. The function becomes obsolete; we remove all callers next and then delete the definition in Task 13. For now, leave a stub that redirects to `start_attempt` so nothing breaks mid-task:

```lua
local function attempt_surface_migration(surface, event_tick, force_run, player_index)
  start_attempt(surface, force_run, player_index)
  return true, "dispatched"
end
```

- [ ] **Step 2: Update `check_all_surfaces`**

Locate `check_all_surfaces` (currently at `control.lua:684-705`). Replace with:

```lua
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
```

- [ ] **Step 3: Update the `/omb-force` command**

Locate the `commands.add_command("omb-force", ...)` block (currently at `control.lua:739-769`). Replace with:

```lua
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
```

Note: the "Checking..." / "marooned found" / final result lines already fire from inside `start_attempt`, `issue_candidate_paths`, `on_current_both_resolved`, `try_ray`, and `finalize_beachhead_spawn`. The command body itself is now deliberately thin.

- [ ] **Step 4: Commit**

```bash
git add control.lua
git commit -m "feat: wire /omb-force and scheduled tick to async state machine"
```

- [ ] **Step 5: Verify — integration smoke test (real biters)**

This is the first task that produces a running end-to-end behavior.

1. Load Factorio, enable Ocean Migration, load a save that has at least one water-isolated biter nest (use a pre-existing test save or the test matrix build in Task 19).
2. In chat, type `/c game.player.print("test")` to verify chat commands work.
3. Type `/omb-force`. Expected: three lines over ~1–30 ticks — "pollution target", then either "marooned found" or "all sampled nests can reach...", then either the spawn GPS or a diagnostic.
4. If biters reach walls/pollution from all islands, confirm "no migration needed" is reported.
5. If a marooned source exists, confirm a new nest spawns on the coastal shore.

If the command is silent or the mod errors, inspect `factorio-current.log` for Lua tracebacks.

---

## Task 12: Try_again_later retries and orphan cleanup

**Spec references:** §5.5 (`try_again_later`), §5.6 (orphan cleanup).

**Files:**
- Modify: `control.lua` (add housekeeping `on_nth_tick(10)` handler)

- [ ] **Step 1: Add the housekeeping function and register it**

Insert near the bottom of `control.lua`, below `check_all_surfaces` and above `script.on_init`:

```lua
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
        if pending.purpose == "wall"      then resolve_wall(pending.surface_index, attempt, false)
        elseif pending.purpose == "pollution" then resolve_pollution(pending.surface_index, attempt, false)
        elseif pending.purpose == "beach"     then resolve_beach(pending.surface_index, attempt, false)
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
```

- [ ] **Step 2: Update `on_configuration_changed`** to wipe in-flight state

Locate the existing block (currently at `control.lua:711-713`):

```lua
script.on_configuration_changed(function()
  ensure_storage()
end)
```

Replace with:

```lua
script.on_configuration_changed(function()
  ensure_storage()
  storage.omb.pending_paths = {}
  for _, state in pairs(storage.omb.surfaces) do
    state.attempt = nil
  end
end)
```

- [ ] **Step 3: Commit**

```bash
git add control.lua
git commit -m "feat: add try_again_later retries and orphan cleanup"
```

- [ ] **Step 4: Verify — syntax loads + smoke**

Launch Factorio, load a save with pending migrations possible. Run `/omb-force`. No new errors. Save, exit, reload. Run `/omb-status`; confirm no phantom in-flight attempt. Wait ~10 seconds after reload, confirm housekeeper has no complaints in `factorio-current.log`.

---

## Task 13: Delete dead code

**Spec references:** §8.1 (Deleted).

**Files:**
- Modify: `control.lua`

- [ ] **Step 1: Delete `DIRECTIONS`, `find_landfall`, `direction_toward`, `candidate_directions`, `nearest_player_position`, `shuffled_entities`, `find_enemy_spawners`, and the `attempt_surface_migration` wrapper from Task 11**

Delete these top-level definitions. Exact current line ranges (verify before editing):

- `DIRECTIONS` constant: `control.lua:3-12`
- `find_landfall`: `control.lua:393-441`
- `direction_toward`: `control.lua:443-453`
- `candidate_directions`: `control.lua:455-472`
- `nearest_player_position`: `control.lua:529-544`
- `shuffled_entities`: `control.lua:546-562`
- `find_enemy_spawners`: `control.lua:564-598`
- `attempt_surface_migration` (the Task 11 wrapper): locate and remove.

Leave `place_beachhead`, `create_landfall`, `chart_for_players`, `choose_landfall_tile`, `away_from_players`, `far_enough_from_source`, `spawner_name_options`, `available_spawners` alone — all still referenced.

- [ ] **Step 2: Commit**

```bash
git add control.lua
git commit -m "refactor: remove ray-scan and player-radius code paths"
```

- [ ] **Step 3: Verify — syntax loads, scheduled cycle still runs**

Launch Factorio, load a save. No error banner. Wait 60 seconds (or fast-forward); the scheduled `check_all_surfaces` should fire without errors.

---

## Task 14: Settings cleanup

**Spec references:** §7.1 (Removed settings).

**Files:**
- Modify: `settings.lua`

- [ ] **Step 1: Remove two settings**

Delete these blocks from `settings.lua`:

- `omb-max-water-tiles` (currently at `settings.lua:46-53`)
- `omb-source-search-radius` (currently at `settings.lua:54-62`)

Leave all other settings unchanged.

- [ ] **Step 2: Commit**

```bash
git add settings.lua
git commit -m "feat: remove obsolete omb-max-water-tiles and omb-source-search-radius"
```

- [ ] **Step 3: Verify — mod reloads cleanly**

Launch Factorio, enable Ocean Migration. Check `Settings > Mod settings > Map`. Confirm the two removed settings are absent and all others remain. No error banner.

---

## Task 15: `/omb-status` and `/omb-reset` updates

**Spec references:** §6.2, §6.3.

**Files:**
- Modify: `control.lua` (two command bodies)

- [ ] **Step 1: Extend `/omb-status`**

Locate the existing `/omb-status` block (currently near end of `control.lua`). Replace with:

```lua
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
```

- [ ] **Step 2: Extend `/omb-reset`**

Locate the existing `/omb-reset` block. Replace with:

```lua
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
```

- [ ] **Step 3: Commit**

```bash
git add control.lua
git commit -m "feat: surface in-flight attempt in /omb-status, wipe pending_paths in /omb-reset"
```

- [ ] **Step 4: Verify**

Launch Factorio, load a save. `/omb-status` prints the standard line. Run `/omb-force`, then quickly `/omb-status` — confirm the in-progress line. Run `/omb-reset` and confirm everything clears.

---

## Task 16: `/omb-diagnose` command

**Spec references:** §6.4.

**Files:**
- Modify: `control.lua` (new command body)

- [ ] **Step 1: Add the `/omb-diagnose` command**

Insert after `/omb-reset`:

```lua
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
```

- [ ] **Step 2: Commit**

```bash
git add control.lua
git commit -m "feat: add /omb-diagnose admin read-only command"
```

- [ ] **Step 3: Verify — live run**

Launch Factorio, load a save. Run `/omb-diagnose` as admin. Expected: 5–7 lines covering surface, pollution, spawners, walls, budget, and optionally an in-flight attempt line. Run on a non-planet surface (or a Factorissimo floor if available) and confirm it prints `eligible=false`.

---

## Task 17: Locale strings

**Spec references:** §6.6.

**Files:**
- Modify: `locale/en/ocean-migration-beachheads.cfg`

- [ ] **Step 1: Read existing locale to find insertion point**

```bash
cat /home/honor/src/honorcodes/ocean-migrator/locale/en/ocean-migration-beachheads.cfg
```

Open `locale/en/ocean-migration-beachheads.cfg`. Locate the `[ocean-migration-beachheads]` section (single section).

- [ ] **Step 2: Append the new strings**

Inside the `[ocean-migration-beachheads]` section, after existing entries, append:

```
checking=Ocean Migration: checking migration on __1__ (pollution target [gps=__2__,__3__,__1__], __4__ candidates).
no-pollution=Ocean Migration: no pollution on __1__ — nothing to migrate toward.
no-spawners-surface=Ocean Migration: no enemy unit-spawner entities on __1__.
marooned-found=Ocean Migration: marooned nest found at [gps=__1__,__2__,__3__]. Scanning beachhead.
no-marooned=Ocean Migration: all __1__ sampled nests can reach walls or pollution on __2__ — no migration needed.
no-beachhead=Ocean Migration: marooned source [gps=__1__,__2__,__3__] — no reachable coastal landing after __4__ rays.
pathfinder-saturated=Ocean Migration: pathfinder queue saturated after __1__ retries — try again shortly.
check-in-progress=Ocean Migration: check already in progress on __1__, try again in ~10 seconds.
diagnose-surface=Ocean Migration diagnose on __1__ (eligible=__2__).
diagnose-no-pollution=No pollution on this surface — nothing to migrate toward.
```

Note: for now, the `player.print(string.format(...))` calls in `control.lua` hardcode English directly rather than calling into locale keys. That matches the existing pattern in `/omb-force`'s failure hints. Wiring fully into locale is a later cleanup — if the implementer wants localization consistency now, refactor those `player.print` strings to `player.print({"ocean-migration-beachheads.checking", ...})` calls. Out of scope for this task unless the implementer explicitly elects it.

- [ ] **Step 3: Commit**

```bash
git add locale/en/ocean-migration-beachheads.cfg
git commit -m "feat: add locale strings for pollution-directed migration"
```

- [ ] **Step 4: Verify**

Launch Factorio, enable mod, load any save. Confirm no locale error banner at startup.

---

## Task 18: Documentation updates

**Spec references:** §11 (Rollout).

**Files:**
- Modify: `README.md`, `docs/project-summary.md`, `docs/to-do.md`
- Create: `docs/test-plan.md`

- [ ] **Step 1: Update `README.md`**

Edit the "Overview" section's behavior-summary bullet list. Replace the three bullets starting with "Runs once per minute..." through "Samples existing enemy nests..." with:

```markdown
- Runs once per minute on surfaces with connected players.
- Enabled by default, toggleable via `Enable Ocean Migration` in Map settings.
- Requires enemy evolution to be at least `Minimum enemy evolution`.
- Accumulates an internal migration budget from enemy evolution over time.
- Spends budget when a beachhead is successfully created.
- For each attempt: finds the surface's highest-pollution chunk, gathers all enemy nests sorted by distance to pollution, and tests each nest with the game's native pathfinder. A nest is migrated from only when it can reach neither a player wall/gate nor the pollution chunk.
- Beachheads land on the coastal shore nearest the marooned source, validated by a round-trip pathfinder check before spawning.
```

Update the "Commands" section. Add a new bullet for `/omb-diagnose`:

```markdown
- `/omb-diagnose` — admin only. Prints the algorithm's current view of the surface (pollution target, candidate list, walls count, budget, in-flight attempt state). Read-only; does not trigger migration.
```

Update the "Current status" section to:

```markdown
- Version `0.4.0` — pollution-directed migration with Factorio pathfinder integration.
- Core migration loop, admin commands (including the new `/omb-diagnose`), budget, Factorissimo filtering, and Alien Biomes-compatible terrain checks are in place.
- Source-of-truth reachability now uses Factorio's native pathfinder. See [`docs/specs/2026-04-22-pollution-directed-migration-design.md`](./docs/specs/2026-04-22-pollution-directed-migration-design.md) for the design rationale and [`docs/test-plan.md`](./docs/test-plan.md) for the acceptance matrix.
```

- [ ] **Step 2: Update `docs/project-summary.md`**

Update the "Current version behavior" header to `Current version behavior: 0.4.0` and rewrite the body to summarize the new algorithm: pollution-chunk target, pathfinder reachability checks, walls-OR-pollution rule, coastal landing with ray fan. Reference `docs/specs/2026-04-22-pollution-directed-migration-design.md` for the full spec.

Update section "Known gotchas" items 3, 4, and 5 to reflect:
- The old "max crossing distance" is gone; pathfinder-driven range replaces it.
- The ray-based sampling is replaced by a deterministic sort by distance-to-pollution + up-to-5-ray beach fan.
- The source search is whole-surface (no longer radius-around-player).

- [ ] **Step 3: Update `docs/to-do.md`**

Edit the file. Mark items 1, 2, and 5 as closed (prefix with `~~` strikethrough, or remove). Annotate item 3 (scan angle/sample density) with "partially obsoleted by fixed 5-ray fan; revisit if UPS concerns arise". Annotate item 4 (evolution-scaled max crossing) with "obsolete: pathfinder now decides range intrinsically".

- [ ] **Step 4: Create `docs/test-plan.md`**

Create the file. Paste the 12-item acceptance matrix from spec §10 verbatim, formatted as:

```markdown
# Ocean Migration 0.4.0 — Acceptance Test Matrix

Manual test matrix run before merging `feat/pollution-directed-migration`
to `main`. Factorio has no test harness; each item is exercised in-game
with the specified conditions.

| # | Scenario | Expected |
|---|---|---|
| 1 | Vanilla Nauvis island start, `omb-debug=true`. Run `/omb-diagnose` at evolution 0, 0.3, 0.6. | Pollution chunk detection tracks factory growth. Evolution < 0.5 blocks scheduled attempts; `/omb-force` still runs. |
| 2 | Wall perimeter fully closed around base. | `/omb-force` reports "all sampled nests can reach walls or pollution — no migration needed". No beachhead spawns. |
| 3 | Wall perimeter breached on one side. | Next cycle migrates. Beachhead lands on the coast, not inside the base. |
| 4 | Two-island test map (SW + SE islands) with `omb-cooldown-minutes=1`. | Over N cycles both islands produce beachheads. Marooned-nest selection rotates. |
| 5 | Space Age: Nauvis + Vulcanus concurrent. | Per-surface state isolated. Platform surfaces skipped. |
| 6 | Factorissimo interior surface. | Skipped as non-planet. |
| 7 | Alien Biomes + Krastorio 2 installed. | Migration works on modded tiles; modded spawner prototypes preserved on beachhead. |
| 8 | Rampant spawner installed on source island. | Beachhead preserves Rampant spawner type. |
| 9 | Pathfinder saturation (many biter groups, rapid `/omb-force`). | Graceful fallback after 3 retries. No stuck attempt state. |
| 10 | Save mid-check, reload. | Within 10 seconds after reload, no phantom in-flight attempt. Next scheduled cycle runs clean. |
| 11 | All sampled candidates reachable. | "Closest reachable" GPS in reply points at expected closest cluster. |
| 12 | Beachhead placement race (manually place entity at validated tile between request and spawn). | "Beachhead placement failed" branch fires. Attempt clears. |

## Result log

Record pass/fail per item here when the run is performed:

```
Run date: YYYY-MM-DD
Factorio version: X.Y.Z
Mod version: 0.4.0
Tester: <name>

1. [ ] pass | [ ] fail | notes:
2. [ ] pass | [ ] fail | notes:
...
```
```

- [ ] **Step 5: Commit**

```bash
git add README.md docs/project-summary.md docs/to-do.md docs/test-plan.md
git commit -m "docs: update for 0.4.0 pollution-directed migration [rag:2]"
```

---

## Task 19: End-to-end acceptance run

**Spec references:** §10 (test matrix).

**Files:**
- Update: `docs/test-plan.md` (fill in result log)

- [ ] **Step 1: Prepare test saves**

If the implementer doesn't have a matching save, build a minimal one:

1. New Nauvis game, `biters: high frequency`, `water: large frequency`.
2. Find (or regenerate) an island start. Clear all biters within view.
3. Leave two biter-populated islands visible across deep water.
4. Build a basic factory with assemblers + a few walls.
5. Save as `docs/test-plan-save.zip` (NOT committed; the `.zip` extension is in `.gitignore` if it exists, else add it). Alternatively keep locally.

- [ ] **Step 2: Run the acceptance matrix**

For each of the 12 items in `docs/test-plan.md`, exercise the scenario and record pass/fail in the result log section. Stop on first fail; return to the responsible task to fix.

- [ ] **Step 3: Commit results**

```bash
git add docs/test-plan.md
git commit -m "docs: record 0.4.0 acceptance run results [rag:1]"
```

- [ ] **Step 4: Merge back to main (only if all 12 passed)**

```bash
git switch main
git merge --no-ff feat/pollution-directed-migration
git tag v0.4.0
```

Push is optional — this is a personal mod repo, not a RAG-integrated one. If the implementer publishes to the mod portal, package with `ocean-migration_0.4.0.zip` per existing release conventions.

---

## Self-review

**Spec coverage check.** Every spec section pairs with at least one task:

- §1 (Problem) → N/A (motivation, not implementation)
- §2 (Goals), §3 (Non-goals) → N/A (scope)
- §4.1 (Target selection) → Task 3
- §4.2 (Candidate gathering) → Task 4
- §4.3 (Wall index) → Task 5
- §4.4 (Iterate candidates) → Tasks 7, 8
- §4.4.1 (Collision mask) → Task 6
- §4.5 (Land beachhead) → Task 9
- §4.6 (Cost and commit) → Task 10
- §4.7 (Spawn) → Task 10
- §5.1 (Storage layout) → Task 2
- §5.2–§5.3 (State machine) → Tasks 7, 8, 9
- §5.4 (Callback routing) → Task 6
- §5.5 (try_again_later) → Task 12
- §5.6 (Orphan cleanup) → Task 12
- §5.7 (Entity invalidation) → Task 7 (`issue_candidate_paths`), Task 8 (`on_current_both_resolved`)
- §5.8 (Attempt lock) → Task 7 (`start_attempt`'s `state.attempt` check)
- §6.1 (`/omb-force`) → Task 11
- §6.2 (`/omb-status`) → Task 15
- §6.3 (`/omb-reset`) → Task 15
- §6.4 (`/omb-diagnose`) → Task 16
- §6.5 (Debug output) → Task 7 (`attempt_reply` already routes through `setting("omb-debug")`)
- §6.6 (Locale) → Task 17
- §7 (Settings) → Task 14
- §8.1 (Deleted code) → Task 13
- §8.2 (Kept) → N/A (verified by absence of delete)
- §8.3 (New functions) → Tasks 3–12
- §9 (Edge cases) → covered inline across Tasks 7–12
- §10 (Test matrix) → Task 19
- §11 (Rollout) → Tasks 1, 18

**Placeholder scan.** No "TBD", no "implement later", no "handle edge cases" without showing how. Every step has exact file paths, exact code, exact commands.

**Type/signature consistency.** Key signatures appear consistently across tasks:

- `find_highest_pollution_chunk(surface)` returns `nil | { position, value }` — used in Tasks 7 (`start_attempt`) and 16 (`/omb-diagnose`) with that shape.
- `gather_sorted_candidates(surface, target_position)` returns `[{ unit_number, position, distance_sq, entity }]` — used in Tasks 7 and 16 consistently.
- `build_wall_index(surface, player_force)` returns `{ buckets, count }` — consumed by `nearest_wall(index, pos)` in Task 5 and referenced in Task 7's `start_attempt`.
- `issue_path_request(surface, start, goal, purpose, surface_index, spawner_name)` — same signature used in Tasks 7 (enumerate), 9 (beach), 12 (retry). Argument order locked.
- `resolve_wall/pollution/beach(surface_index, attempt, success)` — three-arg form used consistently in Tasks 6, 8, 9, 12.
- `attempt.current` fields: `unit_number`, `nest_position`, `spawner_name`, `wall_result`, `pollution_result` — set in Task 7, read in Tasks 8, 10.
- `attempt.beach` fields: `source`, `spawner_name`, `fan_offsets`, `fan_i`, `current_anchor`, `current_drift`, `water_crossed` — set across Tasks 8, 9, 10.

No signature drift detected.

**Task ordering safety.** Each task compiles and runs between commits:

- Task 6's `resolve_*` stubs prevent NPE before Tasks 8–9 flesh them out.
- Task 9's `finalize_beachhead_spawn` placeholder prevents NPE before Task 10.
- Task 11's `attempt_surface_migration` wrapper preserves the old call signature until Task 13 deletes it.
- Task 13 (delete) runs only after Tasks 7–12 have replaced all callers.

The mod loads and runs at every commit in the sequence.
