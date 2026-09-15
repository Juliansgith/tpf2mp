# Native world lobby

Available in 0.45.2-alpha with the matching relay lobby backend.
Both players must update before starting a lobby match.
Older Host/Join + Launch and recovery flows remain available unchanged.

## Native map preview

The lobby separates **Generate / Regenerate** from **Start Match**.
New-world settings first run a preview-only native worker. It calls the game's
MapPreviewComp terrain renderer on the generated map, exporting its whole-map
pixels and native town/industry positions. This is not an in-world camera view
or a screenshot. No CGameUI/playable world or save is created for a preview.
Town names are not assigned at this native generation boundary; markers show
locations (white towns, orange industries), not invented names.

Both peers download the same authenticated, bounded image. Ready requires the
current preview digest. Changing settings or regenerating clears both Ready
votes, including a regeneration with the same seed. After both accept, Start
generates the playable world, verifies the native terrain/landmark digest
against the accepted preview, then uses the existing save/transfer/load flow.
The generator still uses the installed engine in a disposable process; this is
not a standalone reimplementation of terrain generation or a headless SDK.

Preview protocol/UI changes require 0.45.2-alpha and the matching relay
deployment. Existing-save hosting and the previous non-preview protocol remain
supported.

Test the preview, repeat-generation determinism, both peer downloads, and final
save binding using `tests/lobby_native_live.py --preview --prepare-only` with
the ordinary game/mod/configuration/output arguments. Omit `--prepare-only` to
also exercise relay save transfer and the two direct-loaded worlds.

## Player flow

1. Host creates a relay room and privately shares its join code.
2. Player 2 prepares that code. Both open **WORLD LOBBY** in the launcher.
3. Host chooses new-world settings/mods, or selects an existing save.
4. For a new world, host presses **GENERATE PREVIEW** and both review the
   native map. **NEW SEED** chooses a seed and generates another preview.
5. Both press **READY**. Missing/different content blocks Ready;
   changing the configuration clears both players' readiness.
6. Host presses **START MATCH** once. For a new map the engine generates a
   disposable world, saves it and exits automatically. The verified complete
   bundle transfers through the relay and both games load it directly.

No manual main-menu navigation, new-game setup, save naming, shutdown, transfer
or Load Game selection is required. This is **native engine generation**, not a
standalone terrain generator: a windowed game runs during generation. A menu or
loading screen can appear while the engine starts. It is not headless; Steam
and the supported executable are still required.

## New-world settings

- Seed, starting year 1850–2050, Small/Medium/Large and native 1:1–1:5 formats.
- Temperate, dry and tropical native generators with their actual parameter
  sets: hilliness/water/forest; canyon/mesa/ridge/water/forest; or
  hilliness/mainland/forest/islands.
- Town density, initial industry density and industry growth target.
- Environment, vehicle region, native town-name list and native difficulty.
- TPF2MP economy, native crowd policy and experimental physical town growth.
- Ordered built-in/local mods, with fresh content verification on both peers.

The lobby exposes the complete built-in Free Game generator surface used by
this project. Arbitrary third-party generator parameters and arbitrary per-mod
option pages are not exposed yet.
Workshop entries with unknown native major versions are **existing-save only**:
the launcher must not guess a version from a Workshop ID.

Existing saves supply their native active-mod table, including Workshop
versions. The world is transferred, not generated independently from a seed.

## Safety and verification

- Authenticated role-bound lobby, CAS revisions, configuration digest, expiring
  presence, host-only Start, immutable settings after Start, bounded requests.
- Ready rehashes load-bearing installed content. Receiving the save does not
  install missing mods. Native namespace and load order are preserved.
- Per-role launch lock and completion receipt prevent duplicate jobs.
- Background presence and preview-download polling never disables editable
  controls; a user action made during passive polling is queued rather than
  discarded. The last valid lobby state remains visible during a retry.
- Separate generator DLL, exact Build 35924 check, narrow data-only request:
  no arbitrary Lua, callbacks, native addresses or parameter names.
- Generation is scheduled at the empty SDL event-poll boundary on the menu
  thread, outside active rendering. Qualified native copy/ownership contracts
  preserve owning strings, maps and vectors.
- Only a uniquely named generated world can be autosaved. Generation never
  loads/overwrites an existing personal save. Preferences and environment
  overrides are restored; timeout/error closes the owned game. The current
  worker temporarily selects windowed mode and restores the original setting;
  no other game may be running when generation starts.
- Save-ready requires clean exit, exact request hash, native parameter and
  resource observations, exact size/format dimensions, saved economy, matching mods, completed
  native save, validated metadata and preview. Terrain/agent/town settings are
  checked at native configuration handoff; this is not a separate spatial
  terrain or population census.
- Receiver independently verifies configuration/content and save identity
  before ordinary manifest checks, authority gates and initialization.
- Direct load calls app.loadGame with the pinned save basename and a re-entry
  fence. It does not synthesize clicks or bypass checkpoint consensus.

## Implementation and failure handling

The asynchronous dialog is tools/multiplayer_lobby.ps1; Start runs
tools/start_lobby_match.ps1. Native generation uses run_native_worldgen_lab.ps1,
native_worldgen_lab.lua and tpf2mp_worldgen_lab.dll (historical research names).
Standard native builds and release packages include the isolated worker.
companion/tpf2mp/world_generation.py validates requests and output evidence.

Host failures publish bounded failure codes to the room. Detailed local logs
stay in its world-generation-* directory. Failed generation cannot advertise a
usable save. An already completed launch is not silently retried: return to its
game or stop it and create a new room.

## Checks

The offline gate includes test_lobby.py, test_world_generation.py, host/join
dialog smoke, Windows Python runtime identity and direct-load Lua tests.
Native CTest verifies rejection of unsupported processes.
tests/lobby_loopback.py checks the real HTTP protocol without launching games.

Opt-in live test:

    python tests/lobby_native_live.py --game <exe> --mod <tpf2_mp_1> --configuration <world-and-mods.json> --output <new-evidence-directory>

Requires the companion and local relay/aiohttp packages and PowerShell 5.1.
It uses an ephemeral local relay, the real host generation worker, authenticated
WebSocket bundle transfer, two direct-loaded games and a shared checkpoint;
then cleans up both games and session processes.

The live harness uses the host worker's PrepareOnly acceptance seam, handing
the verified save to one harness-owned autosave guard covering both local games.
Normal two-PC launches each own their own guard. This is not a two-computer
network qualification or a visual/click test of the WinForms dialog.

Evidence: investigation/LOBBY_NATIVE_ACCEPTANCE_2026-09-15.md.
