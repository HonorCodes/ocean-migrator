# Ocean Migration

Adds a high-evolution enemy beachhead mechanic for existing Factorio saves.

Have you ever spawned on an island and killed all of the natives, then felt a bit lonely? This mod allows biters to migrate back, so you'll never be alone again! Aren't you happy your friends are back?

Note: should be fully compatible with Rampant and Krastorio 2. Good in large biter modpacks.

This is a runtime companion mod, not a Rampant Fixed patch. It does not modify Rampant internals. Instead, it periodically checks for valid high-evolution ocean migration opportunities and creates an enemy landfall on the far side of deep water.

## How it works

- Runs once per minute.
- Enabled by default, but can be disabled with `Enable Ocean Migration` in Map settings.
- Requires enemy evolution to be at least `Minimum enemy evolution`.
- Accumulates an internal migration budget from enemy evolution over time.
- Spends budget when a beachhead is successfully created.
- Searches for enemy nests near connected players.
- Scans from those nests toward the nearest player and nearby angles.
- If the scan crosses at least `Minimum water crossing distance`, includes at least one deep/unpassable water tile, and finds generated land beyond it, the mod creates a small landfall patch and places enemy nests.

## Suggested settings

- Minimum enemy evolution: `0.50` to `0.90`
- Minimum water crossing distance: `64` or higher
- Minimum migration distance, chunks: `3` by default, equal to 96 tiles; raise it if you want longer island-to-mainland migrations
- Maximum water crossing distance: `512` or higher for ocean maps
- Migration cooldown: `30` to `90` minutes
- Migration budget scaling: `1.0`, or higher for more frequent migrations
- Nests per beachhead: `2` to `4`
- EXPERIMENTAL: Biters can build islands: disabled by default
- Experimental island radius: `6` to `10` if island-building is enabled
- Experimental island tile: `auto` for Alien Biomes compatibility

## Commands

- `/omb-status` shows the current surface's beachhead count and cooldown.
- `/omb-status` also shows the current migration budget.
- `/omb-reset` resets counters and cooldowns. Admin only.
- `/omb-force` force-runs one migration attempt on your current surface. Admin only. Ignores budget, cooldown, evolution threshold, and surface cap, but still requires a valid enemy nest, deep/unpassable water crossing, and legal beachhead location. On success, it prints both the sampled source nest and new nest GPS links.

## Migration budget

Ocean Migration does not reduce Factorio's global evolution factor. Instead, it uses an internal budget that is safer for large modpacks:

- Budget gained per minute = `Migration budget gain per minute * Migration budget scaling * current enemy evolution`.
- Migration cost = `Base migration cost + water distance cost + nest cost`.
- Water distance cost = `ceil(water tiles crossed / 100) * Water distance cost per 100 tiles`.
- Nest cost = `Nests per beachhead * Cost per nest`.

With defaults, a 300-tile crossing with 2 nests costs `1000 + 3*250 + 2*300 = 2350` budget.

Set `Migration budget scaling` above `1.0` to make ocean migration happen more often without editing the detailed cost settings.

## Debugging

Enable `Debug messages` in Map settings to print budget gain, skipped migrations, and placement failure reasons. It is disabled by default.

## Compatibility notes

- Add to an existing save. It is enabled by default and can be disabled under Settings > Mod settings > Map.
- The mod only scans generated chunks. It will not silently generate far-away oceans.
- If `water_spitters` is active and the `water-biter-spawner` prototype exists, it can include that nest type.
- If a migration starts from a modded enemy spawner, Ocean Migration tries to create that same spawner type at the beachhead first, then falls back to available vanilla/water-spitter spawners.
- If Rampant Fixed is active, it should see the new enemy nests through normal script-raised build events and/or subsequent scanning, but this mod intentionally does not call Rampant's private internals.
- Landfall tile placement is disabled by default through the `EXPERIMENTAL: Biters can build islands` checkbox. If enabled, it uses Factorio's `abort_on_collision` behavior and is wrapped defensively, so it should not delete modded entities, resources, machines, or hidden support entities to make room.
- All settings are runtime-global. Loading the mod does not change prototypes, recipes, technology, enemies, surfaces, or map generation.
- The active scan only runs on surfaces that currently have connected players, which is safer for Space Exploration, Space Age, Factorissimo-style surfaces, and large modpacks.
- Factorissimo factory-floor surfaces and common non-planet helper surfaces are skipped.
- Land/water detection uses tile collision layers, not tile names, so Alien Biomes terrain names are supported.
- Experimental island tile defaults to `auto`, which copies nearby shore terrain instead of forcing vanilla grass.
