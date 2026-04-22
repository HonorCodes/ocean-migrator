# Ocean Migration — To-Do

Open and potential issues to investigate. Keep entries to one sentence each.

- [x] `/omb-force` migration still fails in live testing on some island-to-mainland cases, so the ocean-crossing scanner needs further debugging around generated chunks, ray coverage, candidate source selection, and modded terrain/spawner interactions. (CLOSED in 0.4.0)
- [x] Add a command or debug output that reports exactly which condition blocked a migration attempt (no source, ungenerated chunk, no deep water, min-distance, max-distance, no landfall). (CLOSED in 0.4.0 — `/omb-force`'s async reply sequence and `/omb-diagnose` together cover this.)
- [ ] Consider exposing scan angle and sample density as settings so players can trade UPS for better coverage on island-heavy maps. (Partially obsoleted by fixed 5-ray fan; revisit if UPS concerns arise.)
- [x] Fix candidate-sampling bias: on dense mainland biter maps the 24 nearest-to-pollution spawners crowd out water-isolated islands. (CLOSED in 0.4.1 — `gather_sorted_candidates` now chunk-diversifies, and `start_attempt` applies the cap with guaranteed-near + stratified-far sampling.)
- [ ] Evaluate gradually scaling max crossing distance with evolution so very large oceans eventually become crossable without hand-tuning settings. (Obsolete: pathfinder now decides range intrinsically — no static distance cap to scale.)
- [x] Add a `/omb-budget` (or similar) status command that prints the current migration budget, cooldowns, and effective settings for quick diagnosis. (CLOSED in 0.4.0 — `/omb-diagnose` covers this plus more.)
