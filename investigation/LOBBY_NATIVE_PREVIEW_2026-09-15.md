# Native lobby map preview — 2026-09-15

## Outcome

Implemented in source, not released/installed or deployed to production relay.
Generate/Regenerate now renders the native generation map before CGameUI/world
creation. No in-world camera positioning or screenshot capture remains in the
preview path. It uses the Build 35924 MapPreviewComp terrain renderer, exports
the native texture with its valid UV bounds and native town/industry positions,
and composes a bounded lobby image. White markers are towns; orange markers are
industries. Names are empty at this native generation boundary, so none are
invented. The WinForms wrapper/marker styling is ours, the terrain pixels are
the game's own renderer output.

Host generates without requiring the peer to launch the game. Both receive
identical authenticated image bytes. Ready is tied to the preview/configuration
revision. Regeneration clears both Ready votes even with an unchanged seed.
Start creates the playable world, verifies its pre-world terrain/marker digest
against the accepted preview, saves, and hands off to existing transfer/load.
This still requires an installed Steam/game engine process; it is not a portable
standalone terrain generator. Preview-only workers request a hidden window.

## Native boundaries

Exact executable SHA validation remains mandatory. Isolated generator DLL only:

- Observe climate rep at RVA 0x36c2c0 and generation resource provider from the
  qualified generation closure.
- Intercept StartNew at 0x677d00 only within our scoped generation: terrain data
  exists, playable world does not yet exist.
- Native off-screen MapPreviewComp ctor 0x63a190 / allocation 0x498, native font
  source used by its original caller, renderer 0x63ca90.
- Renderer creates a power-of-two RGBA texture; export the actual UV footprint,
  clamped to the allocated texture for exact power-of-two maps.
- Native deleting destructor 0x63b780 is called through an RAII owner on both
  success and C++ error paths, before continuing generation.
- Preview-only exits without calling the original StartNew. Normal accepted
  generation exports the same evidence and then continues its ordinary path.

## Evidence and checks

- `runtime/lobby-native-preview-flow-04/report.json`: PASS. Real ephemeral local
  relay, real companion commands and PowerShell 5.1 host worker. Small mountainous
  1850 world; two independent preview generations with equal native digests,
  distinct review digests, both peers download byte-identical BMPs, votes reset,
  both accept, final native generation/save agrees with accepted preview, clean
  engine exit. `--preview --prepare-only` deliberately stopped before launching
  the two multiplayer games; no claim of a new two-PC or WinForms click test.
- Native digest across both previews and final accepted map:
  `99b916072dbb3defe89437b17c287a70d0bc2c3a6c9b8f7d04334e02f8630677`.
- `runtime/map-preview-native-05`: Medium hilly native renderer/markers PASS.
- `runtime/map-preview-native-large-06`: Large flat native renderer PASS,
  no save created. Pixel conversion also passed on Windows PowerShell 5.1.
- `runtime/map-preview-native-other-seed-07`: Small mountainous seed 931582
  differs from accepted 931581. RGBA SHA-256 respectively
  `c5c247f5e1c3774af6b4cdc1617d422d0082dae380a0b97790d7b1e6feba53d3`
  versus `16d9543a99b52d622d89db002cac8ac5850440577f0b21a58b4276c7c4679a3a`.
- Companion suite: 424 tests, OK (one existing skip).
- Relay suite: 49 passed, including preview format/bounds/hash rejection,
  role restrictions, stale generation/vote rejection, Ready invalidation.
- Native CTest: 3/3; compile-time extent checks cover Small/Medium/Large.
- PS5 host/join dialog smoke verifies undownloaded images cannot be accepted,
  reviewed previews enable Ready, and native pixel/marker export succeeds.
- PowerShell parser and git whitespace checks passed.

## Issues found during implementation

The discarded camera experiment could not show a whole map due to zoom limits.
It was removed rather than presented as a native map preview.

Early native export included an extra border sample on exact power-of-two
maps. Bounds now match the native texture sampler and have compile-time cases.
PowerShell 5.1's JSON array behavior initially nested marker arrays; corrected
and covered by the PS5 export test.

First final-generation run left an off-screen component alive at shutdown,
triggering `CComponent::NumInstances() == 0`. The native destructor/RAII fix
passed the complete subsequent final-generation run with normal shutdown.

World Lobby was launched using the background worker's Hidden window style.
It now requests Normal only for that explicitly interactive dialog. Other
workers remain hidden. Syntax/control smoke passed; actual window visibility
still needs an interactive check in the next installed release.

## Remaining release gates / limits

No production deployment, release, or install performed for this feature.
Client and relay must be updated together. Native overview currently uses a
fixed 512x288 transport image with aspect-preserving map bounds. No pan/zoom or
extra water/climate/generator controls added. Existing-save and legacy start
flows remain supported. Protected personal saves were not loaded or overwritten.
All disposable game processes were closed after qualification.
