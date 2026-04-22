# Ocean Migration

A lightweight Factorio 2.0 mod that lets enemy nests re-establish across deep ocean, so island starts don't stay permanently safe after the local biters are wiped out.

Have you ever spawned on an island and killed all of the natives, then felt a bit lonely? This mod allows biters to migrate back, so you'll never be alone again.

- **Author:** Honor
- **Version:** `0.3.3`
- **Factorio version:** 2.0 (a 1.1 fallback package exists locally)
- **License:** MIT (see [`LICENSE`](./LICENSE))
- **Full technical/project context:** [`docs/project-summary.md`](./docs/project-summary.md)
- **Open issues / to-do:** [`docs/to-do.md`](./docs/to-do.md)

## Overview

Ocean Migration is a runtime companion mod. It does not modify enemy behavior, terrain generation, recipes, technology, or other prototypes. Instead, it periodically checks for valid high-evolution ocean migration opportunities and creates an enemy landfall on the far side of deep water.

Behavior summary:

- Runs once per minute on surfaces with connected players.
- Enabled by default, toggleable via `Enable Ocean Migration` in Map settings.
- Requires enemy evolution to be at least `Minimum enemy evolution`.
- Accumulates an internal migration budget from enemy evolution over time.
- Spends budget when a beachhead is successfully created.
- For each attempt: finds the surface's highest-pollution chunk, gathers all enemy nests sorted by distance to pollution, and tests each nest with the game's native pathfinder. A nest is migrated from only when it can reach neither a player wall/gate nor the pollution chunk.
- Beachheads land on the coastal shore nearest the marooned source, validated by a round-trip pathfinder check before spawning.

## Key features

- **Island-map friendly.** Lets biters re-appear across oceans once evolution is high enough, instead of leaving you permanently isolated.
- **UPS-safe.** No global pathfinding, no continent flood-fills — just sampled source nests and ray-based scans.
- **Modded-spawner aware.** Finds sources by `unit-spawner` type and preserves the source prototype when creating the migrated nest, so Rampant and other modded nests are supported.
- **Alien Biomes compatible.** Land, water, and deep-water classification is collision-based, not vanilla tile-name based.
- **Factorissimo aware.** Skips factory-floor / non-planet / interior helper surfaces.
- **Self-contained budget.** Does not reduce Factorio's global evolution factor; uses its own configurable migration points system.
- **Resilient ocean scan (0.3.3).** Scans keep going past small ponds, shallow shoreline inlets, and tiny islands until they hit real deep-ocean crossings or run out of range.

## Install and use

1. Copy the mod into your Factorio `mods/` directory, or install the packaged zip (`ocean-migration_0.3.3.zip`).
2. Launch Factorio 2.0 and enable **Ocean Migration** in the mod list.
3. Load an existing save or start a new one — no prototype changes, so it is safe to add mid-playthrough.
4. Optional: adjust Map settings under *Settings > Mod settings > Map* to tune cadence, evolution threshold, and budget scaling.

## Suggested settings

- Minimum enemy evolution: `0.50` to `0.90`
- Minimum water crossing distance: `64` or higher
- Minimum migration distance, chunks: `3` by default (96 tiles); raise it for longer island-to-mainland migrations
- Maximum water crossing distance: `512` or higher for ocean maps
- Migration cooldown: `30` to `90` minutes
- Migration budget scaling: `1.0`, or higher for more frequent migrations
- Nests per beachhead: `2` to `4`
- EXPERIMENTAL: Biters can build islands — disabled by default
- Experimental island radius: `6` to `10` if island-building is enabled
- Experimental island tile: `auto` for Alien Biomes compatibility

## Commands

- `/omb-status` — shows the current surface's beachhead count, cooldown, and migration budget.
- `/omb-reset` — resets counters and cooldowns. Admin only.
- `/omb-force` — force-runs one migration attempt on your current surface. Admin only. Bypasses budget, cooldown, evolution threshold, and surface cap, but still requires a valid enemy nest, a deep/unpassable water crossing, the configured minimum migration distance, and a legal beachhead location. On success, it prints GPS links for both the sampled source nest and the new nest.
- `/omb-diagnose` — admin only. Prints the algorithm's current view of the surface (pollution target, candidate list, walls count, budget, in-flight attempt state). Read-only; does not trigger migration.

## Migration budget

Ocean Migration uses its own internal budget instead of spending Factorio's global evolution factor:

- Budget gained per minute = `Migration budget gain per minute * Migration budget scaling * current enemy evolution`.
- Migration cost = `Base migration cost + water distance cost + nest cost`.
- Water distance cost = `ceil(water tiles crossed / 100) * Water distance cost per 100 tiles`.
- Nest cost = `Nests per beachhead * Cost per nest`.

With defaults, a 300-tile crossing with 2 nests costs `1000 + 3*250 + 2*300 = 2350` budget.

Set `Migration budget scaling` above `1.0` to make ocean migration happen more often without editing the detailed cost settings.

## Debugging

Enable `Debug messages` in Map settings to print budget gain, skipped migrations, and placement failure reasons. It is disabled by default to avoid chat spam in large modpacks.

## Compatibility notes

- Safe to add to an existing save. All settings are runtime/map settings — no prototype changes.
- The mod only scans **generated** chunks. It will not invent terrain in never-generated areas; migration there may fail until the area is charted.
- Works with Rampant, Krastorio 2, Alien Biomes, Factorissimo, and large biter modpacks.
- Source nests are found by `unit-spawner` type on the enemy force, so modded spawners work without hardcoded names.
- The migrated nest tries to reuse the source spawner's prototype first, then falls back to available vanilla / water-spitter spawners if needed.
- Factorissimo factory-floor surfaces and common non-planet helper surfaces are skipped.
- Land/water detection uses tile collision layers, not tile names, so Alien Biomes terrain is supported.
- The active scan only runs on surfaces with connected players, which is safer for Space Exploration, Space Age, and Factorissimo-style setups.
- Experimental island tile defaults to `auto`, which copies nearby shore terrain instead of forcing vanilla grass.
- Landfall tile placement is disabled by default behind `EXPERIMENTAL: Biters can build islands`. When enabled, placement uses Factorio's `abort_on_collision` behavior and is wrapped defensively.

## Current status

- Version `0.4.0` — pollution-directed migration with Factorio pathfinder integration.
- Core migration loop, admin commands (including the new `/omb-diagnose`), budget, Factorissimo filtering, and Alien Biomes-compatible terrain checks are in place.
- Source-of-truth reachability now uses Factorio's native pathfinder. See [`docs/specs/2026-04-22-pollution-directed-migration-design.md`](./docs/specs/2026-04-22-pollution-directed-migration-design.md) for the design rationale and [`docs/test-plan.md`](./docs/test-plan.md) for the acceptance matrix.

## More information

For the full design rationale, gameplay concept, known gotchas, and future-improvement notes, see [`docs/project-summary.md`](./docs/project-summary.md).
