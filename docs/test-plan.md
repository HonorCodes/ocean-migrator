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
3. [ ] pass | [ ] fail | notes:
4. [ ] pass | [ ] fail | notes:
5. [ ] pass | [ ] fail | notes:
6. [ ] pass | [ ] fail | notes:
7. [ ] pass | [ ] fail | notes:
8. [ ] pass | [ ] fail | notes:
9. [ ] pass | [ ] fail | notes:
10. [ ] pass | [ ] fail | notes:
11. [ ] pass | [ ] fail | notes:
12. [ ] pass | [ ] fail | notes:
```
