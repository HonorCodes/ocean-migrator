# Ocean Migration — To-Do

Open and potential issues to investigate. Keep entries to one sentence each.

- [ ] `/omb-force` migration still fails in live testing on some island-to-mainland cases, so the ocean-crossing scanner needs further debugging around generated chunks, ray coverage, candidate source selection, and modded terrain/spawner interactions.
- [ ] Add a command or debug output that reports exactly which condition blocked a migration attempt (no source, ungenerated chunk, no deep water, min-distance, max-distance, no landfall).
- [ ] Consider exposing scan angle and sample density as settings so players can trade UPS for better coverage on island-heavy maps.
- [ ] Evaluate gradually scaling max crossing distance with evolution so very large oceans eventually become crossable without hand-tuning settings.
- [ ] Add a `/omb-budget` (or similar) status command that prints the current migration budget, cooldowns, and effective settings for quick diagnosis.
