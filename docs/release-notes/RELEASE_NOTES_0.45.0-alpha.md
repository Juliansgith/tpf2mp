# TPF2MP 0.45.0-alpha

World Lobby: create a new multiplayer world without manually creating, naming,
saving and closing a single-player game first.

## New workflow

1. Host creates a relay room and privately shares the join code.
2. Player 2 prepares the code. Both open **WORLD LOBBY**.
3. Host chooses new-world settings and mods, or an existing save.
4. Both press **VERIFY MODS / READY**, then the host presses **START MATCH**.
5. Native generation, saving, verified relay transfer and direct loading run
   automatically. No manual Load Game selection is needed.

Choose seed, year, Small/Medium/Large, terrain, town/industry density, TPF2MP
economy and agent policy. Missing or different mod content blocks readiness;
settings cannot change after Start. The host generates one world and transfers
it, rather than relying on independent seeded generation matching.

The engine still runs in a window during generation; startup/loading screens
can appear. This is not headless generation. Preferences are restored and
personal saves are not used for new-world generation.

## Verification and limits

- Two complete local-relay native generation/transfer/direct-load runs passed,
  covering Small and Large worlds and shared initialization checkpoints.
- Full offline gate passed: 421 Python tests plus Lua/PowerShell checks and
  the 1,024-event cross-language replay. Relay suite: 43 tests. Native CTest: 3/3.
- Fixed initial generator settings: temperate, square, no water, normal forest,
  all vehicle regions, English names and native Easy difficulty. TPF2MP economy
  difficulty is separate. Unknown Workshop major versions require an existing
  save; arbitrary per-mod generation parameters are not exposed.
- The full visual/click flow and two-computer lobby path remain unqualified.
  Earlier construction, transport and recovery coverage gaps remain; this
  release does not change gameplay capture or claim they are all fixed.
- Both players need 0.45.0-alpha and the updated relay. Existing Host/Join
  launch and recovery paths remain available. State/protocol schemas unchanged.

Back up saves and close active sessions before updating. Windows x64, Build
35924 and two trusted players are still required. Report bugs in **#bugs-logs**
with the support/session ID and what you were doing.

See [World Lobby details](../LOBBY_DEVELOPMENT.md).
