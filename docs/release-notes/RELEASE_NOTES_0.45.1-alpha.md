# TPF2MP 0.45.1-alpha

Native map previews in the World Lobby, plus a fix for its window opening hidden.

## Changes

- Generate a whole-map preview using the game's native terrain renderer, with
  town and industry markers. This is not an in-world screenshot and does not
  create a playable world or save just to show the preview.
- Both players see the same verified preview. Regenerate chooses a new seed;
  regeneration or changed settings clears both players' Ready votes.
- Start Match creates the final world and verifies its native terrain/landmark
  digest against the accepted preview before advertising its save for transfer.
- The launcher opens the interactive World Lobby normally instead of applying
  the hidden-window setting used for background workers.
- Matching relay update adds authenticated, size-bounded preview delivery.
  Existing-save hosting and older non-preview lobby flows remain supported.

## How to use

Update both PCs. Create/prepare a relay room, open **WORLD LOBBY**, choose
new-world settings, then **GENERATE**. Review the map or **REGENERATE**. Both
players press **VERIFY MODS / READY**, then the host presses **START MATCH**.

## Verification and limits

- Local native preview/regenerate/final-save flow passed. Both roles downloaded
  identical previews, regeneration cleared readiness, and the accepted native
  digest matched the final world generation. The worker exited cleanly.
- Small, Medium and Large preview cases passed; a changed seed changed terrain.
- 424 companion Python tests (one existing skip), 49 relay tests, native CTest
  3/3, and PowerShell 5.1 dialog/image smoke tests passed before packaging.
- The new preview path has not been qualified through a complete two-PC visual
  click-through. Prior generation/transfer/direct-load testing is documented
  separately; this release does not claim to revalidate every gameplay case.
- Generation still requires Steam and the installed Windows Build 35924 engine.
  It is not a standalone or headless generator. Preview town names are not yet
  assigned by the engine, so markers show locations rather than names.
- Existing construction, transport and save/load limitations remain. Back up
  saves, close sessions before updating, and report bugs in **#bugs-logs** with
  the support/session ID.

Gameplay state and checkpoint schemas are unchanged.
