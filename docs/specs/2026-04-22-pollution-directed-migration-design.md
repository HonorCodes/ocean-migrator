# Pollution-Directed Migration — Design Spec

- **Target version:** 0.4.0
- **Status:** Approved design, ready for implementation plan
- **Date:** 2026-04-22
- **Author:** Honor
- **Scope:** Replaces the core migration decision algorithm in `control.lua`. Settings are trimmed; the budget formula, surface filtering, spawner-prototype selection, and beachhead placement subsystems are kept.

## 1. Problem

Version 0.3.3 fails to migrate biters in maps where the intent is clearly satisfiable. On the test map, `/omb-force` consistently prints:

```
Ocean Migration force-run failed: no valid ocean crossing found
```

even though two island-to-mainland ocean crossings are visually obvious.

### 1.1 Current algorithm, summarized

`attempt_surface_migration` in `control.lua` (v0.3.3):

1. Gathers enemy `unit-spawner` entities within `omb-source-search-radius` (1536 tiles) of each connected player.
2. Shuffles them, samples up to `omb-max-samples-per-attempt` (24).
3. For each sampled spawner:
   - Computes direction from spawner toward the **nearest player**.
   - Casts rays at that direction, ±15°, ±30°, and eight cardinal/diagonal directions.
   - For each ray, walks outward looking for a `land → deep water → land` segment.
   - On the first hit, calls `place_beachhead` at the landfall tile.

### 1.2 Why it fails

1. **Target is wrong.** "Nearest player" is not "where the factory is". A player walking to the far side of their base shifts every aim vector toward the wrong heading. On a spread-out base the rays systematically miss the pollution core.
2. **Source search is radius-limited to connected players.** Biter nests on an island farther than 1536 tiles from the player character are never sampled, even if they're the obvious migration origin. On the screenshot, the SW island is near the limit; the SE island is roughly in range, but the rays aim wrong once sampled.
3. **Ray geometry is approximate.** A straight land→water→land pattern is fragile to coastline curvature, small islets, and narrow channels. 0.3.3 added resilience against short water segments, but the underlying model still misses valid paths at the wrong angle.
4. **No reachability distinction.** The algorithm never asks "can these biters already walk to the factory?" It will happily spawn an ocean beachhead even when the source island is already path-connected to the player's base, and it cannot tell "blocked by water" from "blocked by the player's walls" from "blocked by terrain".
5. **Silent failure.** "No valid ocean crossing found" lumps together all failure modes, giving no actionable hint to the player.

### 1.3 The test map

Two biter islands (SW and SE), one dominant mainland, pollution epicenter on the south-central-to-SE mainland. Both islands have clear deep-water gaps to the mainland under 500 tiles wide. The intended outcome: both islands eventually send beachheads to their nearest mainland shore over many migration cycles.

## 2. Goals

- Water-isolated biter clusters get beachheads on the mainland over time.
- Biters who can already siege the player's walls or walk to the factory are left alone — they're already in the game.
- Beachheads land on the **coastal shore nearest the source island**, not inland. A "coastal" tile is a land tile adjacent to water with a spawner-sized, non-colliding footprint.
- Preserve modded spawner prototypes (Rampant, K2 nests, etc.).
- Keep existing compatibility: Alien Biomes (collision-based tile classification), Factorissimo (interior surfaces skipped), Space Age (per-surface state, platform surfaces skipped).
- Stay lightweight: one scheduled attempt per surface per minute; no global loops; bounded async pathfinder work.
- Multi-island maps: over multiple cycles, every water-isolated cluster contributes a beachhead. No "winner-takes-all" where only the island closest to pollution ever migrates.
- Actionable failure output: `/omb-force` and the new `/omb-diagnose` report *why* migration isn't happening.

## 3. Non-goals

- Biters swimming, flying, or otherwise traversing water mid-unit. Unit behavior is unchanged.
- Global flood-fill or continent connectivity analysis.
- Prototype-level changes (no new entities, items, or recipes).
- A parallel collision model. Factorio's pathfinder is the source of truth for "can a biter walk here". We call it, we don't reimplement it.
- Perfect forensic classification of every blocker. The algorithm only distinguishes "source nest can reach at least one base asset" vs "source nest is marooned". That is sufficient.
- Mid-crossing visual effects. The beachhead appears at the destination tile; no travel animation.

## 4. Algorithm

One attempt per surface, scheduled every 60 s or triggered via `/omb-force`. Only one attempt per surface is in flight at a time.

### 4.1 Step 1 — Target selection

Iterate generated chunks on the surface via `surface.get_chunks()`. For each chunk `{x=cx, y=cy}`, compute the chunk-center tile position `{x = cx * 32 + 16, y = cy * 32 + 16}` and query `surface.get_pollution(center)`. Track the chunk whose center returns the highest value; its center becomes the `pollution_chunk` for this attempt. Cache for the attempt duration.

- If the maximum pollution value is `0`, skip this surface. There is nothing to migrate toward yet.
- Skip Factorissimo surfaces, platform surfaces, and known non-planet surfaces (existing `eligible_surface` filter, unchanged).

### 4.2 Step 2 — Candidate gathering

`surface.find_entities_filtered{force="enemy", type="unit-spawner"}` over the whole surface (no radius constraint).

Sort the results by squared distance to the pollution chunk center, ascending. This list is the candidate queue.

- If the list is empty, end the attempt with reason "no enemy unit-spawner entities on this surface".

### 4.3 Step 3 — Wall index

`surface.find_entities_filtered{force=<player_force>, type={"wall","gate"}}` over the surface.

Spatially bucket the results into a coarse grid (e.g., 256-tile cells) keyed by `(bucket_x, bucket_y)`. `nearest_wall(pos)` then only scans the 9 cells surrounding `pos`'s bucket.

- If no walls or gates exist, the wall check in step 4 is skipped entirely — only the pollution path decides whether a candidate is marooned.
- The player force is derived from the invoking player for `/omb-force`, or from `game.forces.player` for scheduled runs. Surfaces with multiple player forces iterate each.

### 4.4 Step 4 — Iterate candidates

For each candidate in sorted order (capped at `omb-max-samples-per-attempt`, default 24):

1. **Path A (walls):** if the wall index is non-empty, issue `surface.request_path` from the candidate's position to the nearest wall/gate's position. Collision mask: see 4.4.1.
2. **Path B (pollution):** issue `surface.request_path` from the candidate's position to the pollution chunk center. Collision mask: see 4.4.1.

Both requests run in parallel. When both callbacks have resolved:

- If *either* Path A or Path B succeeds, the candidate is **not marooned** — biters from this nest are already in the game. Advance to the next candidate.
- If *both* fail (or Path A is skipped because no walls exist and Path B fails), the candidate is **marooned**. Stop iterating. This candidate's position becomes the source for step 5.

If the candidate queue exhausts without finding a marooned nest, end the attempt with reason "all sampled nests can reach walls or pollution — no migration needed".

#### 4.4.1 Pathfinder collision mask

`surface.request_path` takes an explicit `collision_mask` (layer list), `bounding_box`, and other fields. For every path issued in this mod (wall, pollution, beach validation), we use the source nest's own prototype data:

- `collision_mask` = `prototypes.entity[source_spawner.name].collision_mask` — the same mask the biters spawned from that nest would use. This guarantees the path respects modded biter collision (Rampant, K2, water-biters, etc.).
- `bounding_box` = a modest fixed box (e.g. `{{-0.4, -0.4}, {0.4, 0.4}}`) representing a single biter unit, not the spawner. The spawner's collision is for placement, not pathfinding.
- `pathfinder_flags = {allow_destroy_friendly_entities = false, cache = true, low_priority = true}`. Low priority keeps our requests behind in-game biter AI in the pathfinder queue.
- `radius` = 8 (tiles). Path is considered found if it reaches within 8 tiles of the goal; avoids failure on goals that happen to sit on a thin obstacle.

If the source spawner's prototype is unavailable or lacks a collision mask (exotic mods), fall back to `prototypes.entity["biter-spawner"]`'s mask, then to a hardcoded default of `{"player-layer","water-tile"}`.

### 4.5 Step 5 — Land the beachhead

From the marooned source nest's position:

1. **Cast ray** toward the pollution chunk at angle offset `fan_offsets[i]`, where the fan is `[0°, +15°, −15°, +30°, −30°]` (5 offsets). Initial `i = 1`.
2. **Find beach anchor.** Walk the ray in steps of `omb-scan-step` (default 16 tiles). Track water tiles crossed. The first land tile past at least `omb-min-water-tiles` (default 64) water tiles is the beach anchor.
   - If the ray exits generated chunks before finding an anchor, or exceeds the pathfinder's effective range, try the next fan offset.
3. **Choose spawner prototype.** Prefer the source nest's own `name` (preserves modded spawners). Fall back to the surface's `available_spawners()` list in current order.
4. **Find non-colliding position.** `surface.find_non_colliding_position(spawner_name, beach_anchor, drift_radius=16, precision=1, force_to_tile_center=true)`.
   - If nil, try the next fan offset.
   - If the returned position is more than 24 tiles from `beach_anchor`, reject (we've drifted onto a different landmass or pocket). Try the next fan offset.
5. **Validate path.** Issue `surface.request_path` from the drifted position to the pollution chunk center. Default biter collision mask.
   - On success, proceed to step 6.
   - On failure, advance `i` and retry step 1.
6. **Fan exhausted.** If all 5 offsets fail, end the attempt with reason "marooned source at [gps] — no reachable coastal landing after full angular fan".

### 4.6 Step 6 — Cost and commit

Compute cost via the existing `migration_cost` formula:

```
cost = omb-budget-base-cost
     + ceil(water_tiles_crossed / 100) * omb-budget-water-cost-per-100
     + omb-nests-per-beachhead * omb-budget-cost-per-nest
```

`water_tiles_crossed` is the count accumulated along the chosen ray during step 5.2.

- Scheduled runs: if `state.budget < cost`, end the attempt with reason "insufficient budget".
- Forced runs: bypass the cost check; do not spend budget.

### 4.7 Step 7 — Spawn

Call the existing `place_beachhead(surface, {x, y, crossed}, spawner_name_options(...))`. This reuses the current mod's nest placement loop: N nests per beachhead (default 2), each placed via `find_non_colliding_position` around the first placement, preserving the source spawner prototype where possible.

On success:

- Decrement `state.budget` by cost (scheduled runs only).
- Increment `state.beachheads`.
- Set `state.next_tick = event_tick + omb-cooldown-minutes * 60 * 60` (scheduled runs only).
- `chart_for_players(surface, {beachhead_position})`.
- If `omb-notify`, `game.print` the existing beachhead-created message.
- `/omb-force` prints the GPS-linked result to the invoking player.

On failure (all N nests failed to place), end the attempt with reason "beachhead placement failed at validated position" — very rare, indicates a race with chunk modification mid-attempt.

## 5. State machine and storage

### 5.1 Storage layout

Additions beneath the existing `storage.omb`:

```lua
storage.omb.surfaces[surface_index] = {
  -- existing fields
  beachheads, next_tick, budget, last_budget_tick,

  -- new
  attempt = nil or {
    stage            = "enumerate" | "check_candidate" | "validate_beach",
    force_run        = bool,
    player_index     = nil or int,   -- /omb-force reply routing
    started_tick     = int,           -- for orphan cleanup
    pollution_chunk  = {x, y},        -- cached for this attempt
    pollution_value  = number,
    candidates       = [unit_number, ...],  -- sorted closest-to-pollution
    candidate_i      = int,
    wall_index       = { [bucket_key] = [{x,y},...] } or nil,
    current          = nil or {
      unit_number     = int,
      nest_position   = {x, y},       -- cached in case entity becomes invalid
      wall_result     = "pending" | "success" | "fail" | "skip",
      pollution_result= "pending" | "success" | "fail",
    },
    beach            = nil or {
      source          = {x, y},
      fan_offsets     = [0, 15, -15, 30, -30],
      fan_i           = int,
      current_anchor  = {x, y} or nil,
      current_drift   = {x, y} or nil,
      water_crossed   = int,
      spawner_name    = string,
    },
  },
}

storage.omb.pending_paths[request_id] = {
  surface_index = int,
  purpose       = "wall" | "pollution" | "beach",
  issued_tick   = int,
  retries       = int,  -- for try_again_later
}
```

### 5.2 Stage transitions

```
                         (sync, one tick)
                    .------------------------.
                    |                        |
  idle ---[trigger]-|-> enumerate ----> check_candidate <---.
                    |                       |   ^           |
                    |                       |   | advance_candidate
                    |                       v   |           |
                    |                 (both legs back)     |
                    |                       |               |
                    |                       v               |
                    |                 validate_beach -------'  (next ray)
                    |                       |
                    |                       v
                    '------- spawn, back to idle
```

### 5.3 Stages in detail

- **enumerate** (synchronous, completes in a single tick): compute pollution chunk (4.1), gather candidates (4.2), build wall index (4.3). Early-exit on "no pollution" or "no candidates". Transition to `check_candidate` with `candidate_i = 1`.
- **check_candidate** (async): issue wall path + pollution path in parallel for `candidates[candidate_i]`. On each callback, fill the matching result. When both are resolved:
  - If either succeeded → `candidate_i++`. If `candidate_i` exceeds the cap or the list, end with "no marooned nests". Otherwise issue a fresh wall + pollution pair for the next candidate.
  - If both failed → transition to `validate_beach`. `beach.source = current.nest_position`.
- **validate_beach** (async): cast ray at `fan_offsets[fan_i]`, find anchor (sync), find non-colliding position (sync), check drift (sync), issue validation path request. On callback:
  - Success → sync path for step 6 (cost) + step 7 (spawn); end attempt.
  - Failure → `fan_i++`. If exhausted, end with "no reachable coastal landing".

### 5.4 Path callback routing

```lua
script.on_event(defines.events.on_script_path_request_finished, function(event)
  local pending = storage.omb.pending_paths[event.id]
  if not pending then return end
  storage.omb.pending_paths[event.id] = nil

  local surface_state = storage.omb.surfaces[pending.surface_index]
  local attempt = surface_state and surface_state.attempt
  if not attempt then return end

  if event.try_again_later then
    reissue_with_backoff(event.id, pending, attempt)
    return
  end

  local success = (event.path ~= nil)
  if pending.purpose == "wall"       then resolve_wall(attempt, success)
  elseif pending.purpose == "pollution" then resolve_pollution(attempt, success)
  elseif pending.purpose == "beach"     then resolve_beach(attempt, success)
  end
end)
```

Each `resolve_*` handler performs the state transition and, where appropriate, issues the next path request or falls through to synchronous completion.

### 5.5 `try_again_later` retries

When a callback fires with `try_again_later == true`, the pathfinder queue is saturated. Reissue the same request after a 30-tick gap, tracked by an `on_nth_tick(10)` housekeeping pass that scans `pending_paths` and reissues any whose `issued_tick + 30 <= game.tick`. Cap retries at 3 per request; after 3 failures, treat as a hard path failure.

### 5.6 Orphan cleanup

Path request IDs do not survive save/load. Two protections:

- `on_configuration_changed` clears all `attempt` and `pending_paths` state.
- On the `on_nth_tick(10)` housekeeping pass, any `attempt` whose `started_tick` is more than **600 ticks** (10 seconds) old is cleared. This catches live saves reloaded without a config change.

### 5.7 Cancellation on entity destruction

At each callback, validate the current candidate (`storage.omb...current.nest_position` combined with `game.get_entity_by_unit_number(current.unit_number)`). If the entity is no longer valid, treat both path results as "skip" and advance to the next candidate immediately.

### 5.8 One-attempt-per-surface lock

`/omb-force` or a scheduled tick only starts a new attempt if `surface_state.attempt == nil`. Otherwise:

- Scheduled tick: silent skip (existing cadence already assumes surfaces can be busy).
- `/omb-force`: reply "migration check already in progress on this surface, try again in ~10 seconds".

## 6. Commands and debug output

### 6.1 `/omb-force` (admin, async)

Replies go to the invoking player only (not `game.print`), with the following sequence:

1. **Immediate**, on accept: `"Ocean Migration: pollution target [gps=X,Y,<surface>]. Testing N nearest nests."` Early-exit messages (no pollution, no spawners, attempt already in flight) replace this line.
2. **On marooned-source decision** (typically 2–30 ticks later): `"Marooned nest found: [gps=...]. Scanning beachhead."` or `"All <N> sampled nests can reach walls or pollution — no migration needed. Closest reachable: [gps=...]"`.
3. **On final resolve**: existing success format, *or* `"Marooned source [gps=...] had no reachable coastal landing after 5 rays (possible causes: ungenerated chunks, cliffs, oversized ocean)."`, *or* `"Pathfinder queue saturated after 3 retries — try again shortly."`.

### 6.2 `/omb-status`

Unchanged for the common case. Appends one line when an attempt is in flight: `"Migration check in progress (stage: <stage>, started tick <n>)"`.

### 6.3 `/omb-reset` (admin)

In addition to the existing `storage.omb = { surfaces = {} }`, also clear `storage.omb.pending_paths`. Useful after a crash-save or mod update.

### 6.4 `/omb-diagnose` (admin, new, synchronous, zero path requests)

Reports the algorithm's current view of the invoking player's surface. Issues no path requests and does not start an attempt. Fields:

- Surface eligibility result (planet / platform / Factorissimo).
- Highest-pollution chunk position and pollution value. If `0`, "no pollution — nothing to migrate toward".
- Nearest-to-pollution enemy spawner: name, position, squared distance, and a one-line geometry summary of the ray from spawner to pollution (`"ray crosses ~N water tiles, hits land at [x,y]"`).
- Player-force wall/gate count on the surface.
- Surface budget, cooldown remaining, evolution factor.
- Any in-flight attempt's stage and age in ticks.

### 6.5 Debug output (`omb-debug`)

Unchanged in UX — disabled by default. When enabled, each scheduled attempt prints one summary line (budget gain, final outcome, reason). Per-candidate and per-ray trace lives only in `/omb-force`'s reply, to keep scheduled runs quiet in large modpacks.

### 6.6 Locale

Add ~10 strings under the existing `ocean-migration-beachheads` category:

- `checking`, `pollution-target`, `no-pollution`, `no-spawners-surface`, `marooned-found`, `no-marooned`, `no-beachhead`, `pathfinder-saturated`, `check-in-progress`, `diagnose-*` (several).

## 7. Settings

### 7.1 Removed

| Setting | Reason |
|---|---|
| `omb-source-search-radius` | Candidates are now whole-surface, keyed on distance to pollution. |
| `omb-max-water-tiles` | The pathfinder intrinsically decides "too far" by returning no path; a static cap silently blocks legitimate crossings. |

`on_configuration_changed` does not need to migrate these — 0.3.3 reads them live from `settings.global` and never caches in `storage`.

### 7.2 Repurposed (same key, revised meaning)

| Setting | Was | Becomes |
|---|---|---|
| `omb-min-water-tiles` (default 64) | Minimum water tiles in the scan's water segment. | Minimum water tiles traversed along the chosen ray before the beach anchor. Same "don't count a puddle as a migration" guardrail, now against the ray's running water count. |
| `omb-scan-step` (default 16) | Ray step for land→water→land detection. | Ray step for beach anchor walking. |
| `omb-min-distance-from-player` (default 128) | Distance from any connected player. | Unchanged mechanically; its semantic is now "keep beachheads out of the player's face", not "away from the aim target". |

### 7.3 Kept unchanged

`omb-enabled`, `omb-min-evolution`, `omb-cooldown-minutes`, `omb-min-migration-chunks`, `omb-max-samples-per-attempt`, `omb-nests-per-beachhead`, `omb-max-beachheads-per-surface`, `omb-build-islands`, `omb-landfall-radius`, `omb-budget-scaling`, `omb-landfall-tile`, `omb-use-water-spitters`, `omb-chart-beachheads`, `omb-notify`, `omb-debug`, `omb-budget-max`, `omb-budget-gain-per-minute`, `omb-budget-base-cost`, `omb-budget-water-cost-per-100`, `omb-budget-cost-per-nest`.

### 7.4 New

None. Pathfinder retry count (3) and retry gap (30 ticks) are constants — keeping them tunable would expose internal implementation detail and enlarge the settings surface.

### 7.5 Budget formula

Unchanged:

```
cost = base + ceil(water_crossed / 100) * water_cost_per_100
     + nests_per_beachhead * cost_per_nest
```

With defaults and a 250-tile crossing, 2 nests: `1000 + 3 * 250 + 2 * 300 = 2350`. Matches current tuning. Players who already adjusted `omb-budget-scaling` see identical pressure.

## 8. Code deltas

### 8.1 Deleted from `control.lua`

- `find_landfall` — ray-scan land→water→land machinery.
- `candidate_directions` — primary + ±15° + ±30° + cardinal/diagonal heuristic.
- `direction_toward` — inlined into beach fan setup.
- `nearest_player_position` — replaced by `find_highest_pollution_chunk`.
- `shuffled_entities` — replaced by sort-by-pollution-distance.
- The player-radius branch of `find_enemy_spawners` (the whole function becomes `gather_sorted_candidates`).
- The body of `attempt_surface_migration` (replaced by the state-machine driver).

### 8.2 Kept, unchanged

- `ensure_storage`, `surface_state`, `setting`.
- `valid_player`, `factorissimo_surface`, `known_non_planet_surface`, `eligible_surface`.
- `distance_sq`, `debug_print`, `get_evolution`, `update_budget`, `migration_cost`.
- `chunk_position`, `is_generated`, `is_water_tile`, `tile_collides_with_any`, `is_deep_water_tile`, `is_land_tile` — now only used for beach anchor detection and water-tile counting along the chosen ray.
- `tile_exists`, `choose_landfall_tile`, `create_landfall` — experimental island building is unchanged.
- `away_from_players`, `far_enough_from_source` — placement constraints.
- `prototype_is_unit_spawner`, `available_spawners`, `is_valid_spawner_name`, `choose_spawner`, `spawner_name_options` — spawner selection.
- `place_beachhead` — nest placement loop.
- `chart_for_players`.

### 8.3 New

- `find_highest_pollution_chunk(surface)` — iterates generated chunks, returns `{x, y, value}` of the highest-pollution chunk center.
- `gather_sorted_candidates(surface, target)` — whole-surface `find_entities_filtered`, sorted by distance-squared to `target`.
- `build_wall_index(surface, player_force)` — whole-surface `find_entities_filtered` for walls and gates, spatial-bucketed.
- `nearest_wall(index, pos)` — scans the 9-cell neighborhood of `pos`'s bucket.
- `issue_path_request(surface, start, goal, purpose, attempt)` — wraps `surface.request_path`, populates `pending_paths`.
- `resolve_wall(attempt, success)`, `resolve_pollution(attempt, success)`, `resolve_beach(attempt, success)` — callback handlers.
- `advance_candidate(attempt)`, `start_beach_search(attempt)`, `advance_ray_fan(attempt)` — stage transition helpers.
- `try_ray(attempt, fan_offset)` — casts ray, finds anchor, runs `find_non_colliding_position`, issues beach path.
- `on_script_path_request_finished` event handler.
- `on_nth_tick(10)` housekeeping pass (try_again_later reissue + orphan timeout).
- `/omb-diagnose` command body.
- Updated bodies for `/omb-force`, `/omb-status`, `/omb-reset`.

### 8.4 Expected size

- `control.lua`: 769 → approximately 900–1000 lines.
- `settings.lua`: shrinks by ~16 lines (two removed settings).
- `locale/en/ocean-migration-beachheads.cfg`: grows by ~10 strings.

## 9. Edge cases

| Situation | Handling |
|---|---|
| Pollution = 0 everywhere on surface | Skip at enumerate. `/omb-force` prints "no pollution on this surface yet". |
| No unit-spawners on surface | Skip at enumerate. Existing reason string. |
| No player walls/gates | Path A is skipped per-candidate; Path B alone decides. |
| `try_again_later` from pathfinder | Retry up to 3× at 30-tick gap. After 3, treat as hard failure. |
| Source nest destroyed mid-request | `game.get_entity_by_unit_number` returns nil or invalid at callback time; treat as "skip" and advance. |
| Beach ray crosses ungenerated chunks | Ray aborts without finding anchor; advance fan. |
| Save/load mid-attempt | `on_configuration_changed` clears state; otherwise orphan timeout at 600 ticks cleans up. |
| Biter prototype with exotic collision mask | Pathfinder uses the prototype's own mask — no special-casing. |
| New surface appears (new planet, Factorissimo unload) | `surface_state` lazy-inits on first tick, unchanged. |
| Player disconnects mid-attempt | Attempt still resolves; beachhead notification still prints via `game.print` if `omb-notify`. |
| Multiple player forces on one surface | Build wall index once per player force, union the buckets. Path A uses the nearest wall across all forces. |
| Attempt started on scheduled tick while `/omb-force` was about to run | `/omb-force` replies "check already in progress" — no conflict. |

## 10. Test matrix

No Factorio test harness exists. These go into `docs/test-plan.md` (new file) as the 0.4.0 acceptance checklist.

1. **Vanilla Nauvis island start, `omb-debug=true`**: `/omb-diagnose` at evolution 0 / 0.3 / 0.6. Confirm pollution-chunk detection tracks growth of the factory, and that evolution < 0.5 blocks scheduled attempts but `/omb-force` still runs.
2. **Wall perimeter closed around base**: `/omb-force` reports "all sampled nests can reach walls or pollution — no migration needed". No beachhead spawns.
3. **Wall breached on one side**: migration resumes on the next cycle. Beachhead lands on the shore, not inside the base.
4. **Two-island test map (matches the screenshot)**: over N cycles with `omb-cooldown-minutes=1` for testing, both SW and SE islands produce beachheads. Confirm the marooned-nest selection rotates.
5. **Space Age: Nauvis + Vulcanus concurrent**: per-surface state isolated. Pollution on Nauvis does not trigger a migration attempt on Vulcanus and vice versa. Platform surfaces skipped.
6. **Factorissimo**: factory-floor surface with many entities and "players" is skipped.
7. **Alien Biomes + Krastorio 2**: migration works on custom biome tiles; modded spawner prototypes are preserved.
8. **Rampant**: source spawner type preserved on the beachhead.
9. **Pathfinder saturation**: many biter groups active + `/omb-force` fires in rapid succession. Expect graceful fallback after 3 retries. No stuck `attempt` state.
10. **Save mid-check, reload**: `/omb-status` after reload shows no phantom in-flight attempt within 10 seconds; next scheduled cycle runs clean.
11. **All sampled candidates reachable (no marooned nests)**: confirm the "closest reachable" GPS in the reply points at the expected closest biter cluster.
12. **Beachhead placement race**: artificially place an entity at the validated beach tile between request and spawn (manual command). Confirm the "beachhead placement failed" branch fires without leaving `attempt` stuck.

## 11. Rollout

- Version bump `0.3.3 → 0.4.0` in `info.json`.
- `on_configuration_changed` clears any residual 0.3.x state for the new attempt fields (strictly, 0.3.x never wrote them; this is defense against test builds).
- Removed settings (`omb-source-search-radius`, `omb-max-water-tiles`) disappear from the mod-settings UI; existing saves that had them tuned lose those tunings silently. No migration prompt is surfaced; the removed keys weren't cached in `storage`.
- README: update the "Behavior summary" and "Current status" sections. Add `/omb-diagnose` to the commands list.
- `docs/project-summary.md`: update sections 5, 6, 8, and the "Known gotchas" list to reflect the new algorithm.
- `docs/to-do.md`: close items 1 (island-to-mainland failure), 2 (actionable failure reporting), and 5 (status command via `/omb-diagnose`). Item 3 (scan angle/density settings) becomes partially moot — the fan is fixed — but keep as a future consideration. Item 4 (evolution-scaled max crossing) is obsoleted by pathfinder-driven range.

## 12. Open questions deferred to implementation

- Exact chunk iteration strategy for `find_highest_pollution_chunk`. `surface.get_chunks()` iterates all generated chunks; for large maps this is 10k+ chunks. Option: iterate `surface.pollution_statistics` if available, or sample a sparse grid if pollution scanning ever becomes a measured bottleneck. Benchmark in step 1 of the plan.
- Whether `/omb-diagnose`'s ray-hits summary (a quick straight-line geometry check without pathfinding) is worth the ~200 tile lookups. Option: omit if it's perceived as noise; keep if players find it useful.
- Whether to expose a per-attempt "verbose trace" subcommand like `/omb-force --verbose`. Current plan: `/omb-diagnose` covers the read-only side, `/omb-force` already gives 3 lines; additional verbosity can come later without protocol changes.

These are for the implementation plan to resolve, not the design.
