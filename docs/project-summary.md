# Ocean Migration Project Summary

## Project identity

- **Project name:** Ocean Migration
- **Factorio mod internal name:** `ocean-migration`
- **Author:** Honor
- **Current version:** `0.3.3`
- **Repository:** `https://github.com/HonorCodes/ocean-migrator`
- **Primary target:** Factorio 2.0
- **Fallback build:** Factorio 1.1-compatible package also exists locally, but the GitHub repo is intended to contain the 2.0 code only.

Ocean Migration is a lightweight Factorio mod intended to solve a specific gameplay issue: when a player spawns on an island, kills all nearby enemies, and becomes permanently isolated from biter pressure because enemies cannot naturally cross deep ocean, the world can become too safe and static. The mod gives enemies a way to re-establish nests across ocean gaps without requiring full pathfinding or invasive changes to enemy behavior.

## Core intent

The mod should allow biters to "migrate" across deep/unpassable water and create new nests on valid land across the ocean.

The intended behavior is not simply "spawn more biters randomly." It should feel like enemy expansion pressure has found a way across the ocean.

The design goal is:

- Preserve island starts as playable.
- Let biters eventually return after sufficient evolution/progression.
- Avoid changing vanilla terrain or enemy behavior more than necessary.
- Stay compatible with large modpacks.
- Avoid expensive UPS-heavy logic.
- Work with modded biter nests, including Rampant.
- Avoid spawning enemies inside Factorissimo or other non-planet/interior surfaces.
- Avoid placing nests directly on water unless the experimental island-building option is enabled.

## Gameplay concept

The mod maintains a migration budget, conceptually similar to "points" the enemy faction can spend.

Enemies earn migration points over time based on evolution/progression, with a scaling setting exposed to the player. When enough points are available, the mod samples existing enemy nests and tries to find a valid ocean crossing from that source nest to a landfall destination.

If a valid crossing is found, the mod creates a new enemy nest at the destination and spends points from the migration budget.

The result is that enemies can slowly reappear across oceans, especially once the game has reached a meaningful evolution level.

## Current high-level behavior

Ocean Migration periodically attempts migration on eligible planet surfaces.

For each attempt, it generally:

1. Finds enemy unit-spawner entities near connected players.
2. Samples candidate source nests.
3. Scans outward from those nests using lightweight ray-based checks.
4. Looks for a path that crosses deep/unpassable water.
5. Requires the crossing to satisfy a minimum migration distance.
6. Finds valid generated land on the far side.
7. Creates a new enemy spawner at the destination.
8. Deducts migration points unless the admin force command is used.

It does not run full pathfinding, flood-fill continents, or global map analysis. This is intentional for UPS safety.

## Current version behavior: 0.4.0

Version `0.4.0` replaces the ray-based ocean scan with a pollution-directed, pathfinder-driven migration algorithm.

Instead of scanning outward from random nests along angular rays, the mod first identifies the surface's highest-pollution chunk as the migration target. This grounds the algorithm in the actual game state: enemies should be drawn toward where the player's factory produces the most pollution, not toward a geometrically arbitrary direction.

Candidate source nests are gathered across the whole surface and sorted by their distance to the pollution chunk. For each candidate, the mod asks Factorio's native pathfinder whether the nest can reach a player wall or gate, and whether it can reach the pollution chunk directly. A nest qualifies as "marooned" — and therefore a valid migration source — only when it fails both of those reachability checks. This replaces the old static max-crossing-distance cap with a semantically correct test: the nest is genuinely isolated from the player's base by impassable water.

Beachhead placement follows from the identified source. Rather than depositing the new nest at an arbitrary landfall point, the mod finds the coastal shore nearest to the marooned source island and validates the placement with a round-trip pathfinder check before spawning. The result is a landing site that is topographically near the source and confirmed reachable from player territory.

Admin commands have been updated to match the new algorithm. `/omb-force` now runs the full pollution-directed selection and reports its result via an async reply sequence that includes GPS links for source and destination. `/omb-status` shows in-flight attempt state. `/omb-reset` clears state as before. A new `/omb-diagnose` command is read-only and prints the algorithm's current view of the surface: pollution target chunk, candidate nest list with reachability results, wall count, current budget, and in-flight attempt state.

For the full design rationale and algorithm details, see [`docs/specs/2026-04-22-pollution-directed-migration-design.md`](./docs/specs/2026-04-22-pollution-directed-migration-design.md).

## Important distinction: loaded vs generated chunks

The mod does not require biters to be "loaded" in the sense of being active on-screen, visible live on the map, or inside radar coverage.

What matters is whether the chunks exist/generated.

If the source nest and destination path are in generated chunks, the mod can inspect them even if they are not currently active. If the scan crosses never-generated black map area, the mod will not invent unknown terrain. In that case, migration may fail until the area is generated by exploration, radar, charting, or normal map generation.

This is a major gotcha when testing with `/omb-force`.

## Deep ocean requirement

The mod is specifically meant to help enemies cross water that they normally cannot traverse.

It should not count a tiny shallow-water hop or coastline-adjacent move as a valid migration. The scan requires at least one deep/unpassable water tile between the source and destination.

The logic uses collision properties and heuristics rather than only vanilla tile names, so it should remain compatible with Alien Biomes and other tile mods.

## Minimum migration distance

There is a setting for minimum migration distance measured in chunks.

The default is **3 chunks**, meaning about 96 tiles.

This was added because tile-based distances were too granular and could allow undesirable behavior like a nest spawning almost directly across a small shore gap. Chunks are also easier for players to reason about and align better with Factorio map generation concepts.

This setting helps prevent "same island coastline" migrations.

## Admin command

The mod includes an admin command:

```text
/omb-force
```

This force-runs a migration attempt.

The command bypasses:

- migration budget
- cooldown
- evolution threshold
- surface migration cap

But it still requires:

- a valid enemy source spawner
- a valid generated terrain path
- a crossing that includes deep/unpassable water
- the configured minimum migration distance
- a valid land destination

The command output includes GPS links for both:

- the sampled source nest
- the new migrated nest

This is important for debugging because the player needs to verify whether the sampled nest and destination make sense.

Failure messages now distinguish between cases like:

- no nearby enemy spawners
- no valid ocean crossing found

## Rampant and modded biter compatibility

The mod is intended to work with Rampant and large biter modpacks.

The implementation should not rely on hardcoded vanilla spawner names like only `biter-spawner` or `spitter-spawner`.

Instead, enemy migration sources should be based on Factorio's `unit-spawner` entity type on the enemy force.

The migrated nest should preserve the source spawner's prototype name when possible. This means if the sampled source nest is a Rampant/modded spawner, the new migrated nest should be the same modded spawner type rather than being converted into a vanilla spawner.

Current behavior in 0.3.3:

- `find_enemy_spawners` uses `type = "unit-spawner"`.
- Spawner validity is checked using prototype type.
- The source spawner name is preserved when creating the new nest.
- Vanilla names are only fallback options if needed.
- There are no brittle Rampant-specific branches.

## Alien Biomes compatibility

Ocean Migration should be compatible with Alien Biomes.

The mod should not assume that valid land has vanilla tile names like `grass-1`, `dirt-7`, etc.

Instead, land/water/deep-water classification should be based primarily on collision behavior, with name heuristics only where appropriate. The current design avoids a vanilla-only land allowlist.

The island-building tile setting has an `auto` mode, which is the default. This is intended to avoid hardcoding a terrain tile that might not exist or might be inappropriate in an Alien Biomes world.

## Factorissimo compatibility

Factorissimo creates interior factory surfaces, such as factory-floor surfaces, that should not be treated as normal planets.

Ocean Migration should not attempt to migrate biters inside those surfaces.

The mod includes filtering for Factorissimo/non-planet surfaces using checks such as:

- Factorissimo remote interface when available
- known Factorissimo surface-name patterns
- non-planet/platform checks in Factorio 2.0
- known non-natural surfaces

This avoids spawning nests inside factory interiors or other invalid surfaces.

## Experimental island building

There is an experimental setting:

```text
EXPERIMENTAL: Biters can build islands
```

This should be disabled by default.

When disabled, biters migrate only to valid land.

When enabled, the mod may allow limited island/landfall tile placement behavior, but this should remain gated and cautious because terrain modification is more invasive and more likely to conflict with other mods.

This feature exists as an option, not the core behavior.

## Settings philosophy

The mod should be enabled by default when installed. The assumption is that players installing Ocean Migration want the behavior active.

Settings that are potentially noisy, risky, or experimental should be disabled by default.

Known intended defaults:

- Main migration behavior: enabled by default.
- Debug messages: disabled by default.
- Experimental island building: disabled by default.
- Minimum evolution threshold: `0.50`.
- Minimum migration distance: `3` chunks.
- Island tile mode: `auto`.
- Point scaling: exposed as a player-adjustable map setting.

## Debug setting

There is a debug checkbox setting, inspired by Rampant's style.

It should be disabled by default.

When enabled, it can print useful migration/debug messages so players can understand why migrations are or are not occurring.

When disabled, the mod should avoid chat spam.

## Migration points and scaling

The mod uses its own migration budget rather than directly spending Factorio's global evolution factor as a currency.

Evolution/progression influences how quickly the budget accumulates and when migrations are allowed. A map setting exposes basic point scaling so players can make migration pressure stronger or weaker.

The exact balance should remain tunable because different modpacks can have very different enemy densities, evolution rates, and ocean sizes.

A simple player-facing explanation is:

```text
Enemies earn migration points over time as evolution rises. Points are spent to create ocean-crossing beachhead nests. Increase point scaling for more frequent migrations, or lower it for slower pressure.

Example: at higher evolution, enemies earn points faster; once enough points are saved, they spend them to establish a nest across deep water.
```

## Lightweight design constraints

The mod should stay lightweight.

Avoid:

- full pathfinding across continents
- flood-filling all landmasses
- scanning huge areas every tick
- global surface-wide nest analysis
- modifying other mods' prototypes unnecessarily
- storing excessive per-entity state
- frequent debug printing when disabled

Prefer:

- sampled candidate nests
- ray-based directional scans
- configurable max samples per attempt
- generated-chunk checks
- early exits where valid
- settings for cadence and scaling

This is important because the target environment may be a large heavily modded game with Rampant, Krastorio 2, Alien Biomes, Factorissimo, and other performance-sensitive mods.

## Compatibility goals

Ocean Migration should aim to be compatible with:

- Factorio 2.0
- Factorio 1.1 fallback package
- Rampant
- Krastorio 2
- Alien Biomes
- Factorissimo
- large biter modpacks
- modded `unit-spawner` prototypes
- modded terrain tiles
- island-heavy maps

It should not require optional dependencies for mods unless there is a real integration need. Earlier optional dependencies for water spitters and other unrelated mods were removed because Ocean Migration does not have special interactions with them.

## What the mod does not do

Ocean Migration does not:

- make individual biter units swim across oceans
- alter Rampant's internal enemy logic directly
- require Rampant
- require Water Biters / Water Spitters
- force existing saves to regenerate enemy bases
- spawn nests in Factorissimo interiors
- use global pathfinding
- guarantee migration into never-generated chunks
- create islands unless the experimental setting is enabled
- override every modded terrain rule

## Known gotchas

The most important gotchas for future work:

1. **Generated chunks matter.** If the ocean/mainland path is not generated, the scan may fail even if the player expects migration there.

2. **Minimum distance can block nearby spawns.** Default is 3 chunks. This is intentional to prevent same-shoreline hops.

3. **Max crossing distance is no longer a static cap.** The pathfinder-driven reachability check replaces the old static max-crossing-distance limit. Whether a nest can reach player walls or the pollution chunk is now determined by Factorio's native pathfinder, which naturally handles large oceans based on actual passability rather than a tile-count threshold.

4. **Source search is now whole-surface.** The 0.4.0 algorithm gathers candidate nests across the entire surface, not within a radius around connected players. `/omb-force` will report no candidates only if there are genuinely no enemy unit-spawners on the surface at all.

5. **Ray-based coastal scanning is still approximate.** The 5-ray angular fan used to find the coastal landing near the source island is intentionally lightweight. Each ray now ends with a real pathfinder check before a beachhead is confirmed, so a ray miss does not produce a false positive, but valid landing sites may still be missed if none of the five angles align well with available coast.

6. **Modded spawner prototypes must be valid `unit-spawner`s.** Rampant-style nests should work, but exotic mods that use unusual entity types may not.

7. **Terrain classification must remain collision-based.** Do not replace Alien Biomes-compatible logic with vanilla tile-name lists.

8. **Do not remove Factorissimo filtering.** Interior factory surfaces can look like surfaces with players and entities, but they are not valid migration targets.

9. **Do not make debug default-on.** Large modpacks can already be noisy.

10. **Do not add hard optional dependencies unless truly needed.** The mod should be broadly compatible without declaring unnecessary relationships.

## Current repository state

The latest code was pushed to GitHub `main`.

Latest pushed commit:

```text
252eabf
```

Commit message:

```text
ocean-migration 0.3.3: resilient ocean scan, modded spawner support
```

The repository contains the Factorio 2.0 version.

Local packaged builds also included:

```text
ocean-migration_0.3.3.zip
ocean-migration-f11_0.3.3.zip
```

## Suggested future improvements

Potential future improvements, if needed:

- Add more detailed debug output explaining which condition blocked migration.
- Add a command to print current migration budget and settings.
- Add a command to test from a selected/source nest specifically.
- Add better visualization/debug markers for sampled source rays.
- Add optional setting for scan angle/sample density.
- Add safer handling for extremely large oceans by gradually increasing scan range with evolution.
- Add mod portal documentation explaining generated chunks vs active/loaded chunks.
- Add automated tests or static validation for settings/prototype compatibility if a Factorio test harness is introduced.

## One-sentence summary

Ocean Migration is a lightweight Factorio mod that lets enemy nests re-establish across deep ocean by spending a configurable migration budget, preserving modded spawner types and avoiding invalid surfaces, so island maps can regain biter pressure without expensive pathfinding or invasive enemy-behavior changes.
