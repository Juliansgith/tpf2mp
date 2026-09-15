# TPF2MP 0.45.2-alpha

A redesigned, stable World Lobby with the complete native map generator exposed
before either multiplayer game launches.

## Changes

- Rebuilt the World Lobby around clear Map, Gameplay and Mods sections. Removed
  developer-facing filler, the oversized raw settings box and ambiguous status
  copy.
- Added the native generator's climate, map size, aspect ratio, starting year,
  environment, vehicle set, town-name set, town density, initial industry
  density, industry growth target and native difficulty controls.
- Added every climate-specific terrain control: temperate hilliness, water and
  forest; dry canyon, mesa, ridge, water and forest; tropical hilliness,
  mainland, forest and islands.
- Native previews now use the selected generator, terrain parameters and exact
  game dimensions for all map formats from 1:1 through 1:5. Fixed the native
  preview worker's square-only safety bound, which rejected valid long maps.
- Lobby polling no longer disables or repaints controls. Passive presence and
  preview updates run without dropping clicks, resetting the host's draft or
  replacing a valid state with a transient "not synced" message.
- Readiness is tied to the locally downloaded preview for the current revision;
  changing generation settings clears stale readiness.
- The relay validates the expanded world-settings schema, including strict
  terrain field sets and bounds.

## How to use

Update both PCs to `0.45.2-alpha`. Create or join a relay room, open **WORLD
LOBBY**, select the map and gameplay settings, then generate the preview. Both
players review the same native map and press **READY**; Player 1 starts the
match. Changing settings or regenerating requires both players to ready again.

## Verification and limits

- Native preview generation passed for temperate, dry and tropical climates,
  including a Large tropical 1:4 map. The final generated save reported the
  expected 28 by 112 native dimensions, resources, parameters and year.
- Host and join lobby smoke tests verify stable controls across background
  polling and ensure every climate slider remains visible.
- The full repository gate passed: 164 Lua checks, 2,560 construction-layout
  cases, 426 Python tests, native CTest 3/3, signature verification, packaging
  boundaries and launcher tests. The relay suite passed 52 tests.
- This remains an experimental two-player release for Windows Build 35924.
  Generation uses the installed game engine and Steam; it is not a standalone
  headless generator. Existing construction, transport and persistence limits
  remain, so back up saves and report failures with the support/session ID.

Gameplay state, checkpoint and operation schemas are unchanged. Both players
must run the same TPF2MP release and matching mod set.
