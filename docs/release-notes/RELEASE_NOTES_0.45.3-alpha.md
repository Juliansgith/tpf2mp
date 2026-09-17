# TPF2MP 0.45.3-alpha

Bit-identical terrain fast paths in the native hook, on by default. This
remains an experimental two-player testing release.

## Changes

- Four stock terrain routines that dominate the terrain phase of a save or
  world load are replaced by implementations that produce the same bytes for
  every input: terrain alignment (`CalculateHeightMod`), bicubic height
  refinement (`InternBicubicRefine`), the tile min/max scan with the height
  block copy, and the material-index pixel selection. They are ports of
  silver2127's tpf2-bigmap plugin (MIT; see the third-party notices).
- Every patch site is byte-verified (prologues, whole function bodies,
  constants and vtables) before anything is hooked. A mismatch, an unknown
  request or a hook failure leaves that path off and records the reason under
  `hooks.terrainFast` in the native status; the rest of the hook arms normally.
- `TPF2MP_NATIVE_TERRAIN_FAST` in the game process's environment overrides
  the default: `off` restores stock code, a comma-separated subset of
  `align`, `refine`, `minmax`, `material` selects paths, and `timing`
  publishes per-routine call counts and seconds in the status JSON.
- `tools\run_native_save_benchmark.ps1 -NativeHookDll` runs the input-free
  save benchmark through the injector and keeps the hook status as evidence;
  `tools\summarize_terrain_fast_benchmark.py` tabulates a series.

## Verification and limits

- Because the outputs are identical, the two peers may run different settings
  without diverging, and nothing here enters a checkpoint digest. Protocol,
  state schema and native hook versions are unchanged.
- The proof runs the original machine code beside the replacements: 1,374
  alignment comparisons over 12.9 million samples, 4,315 refinement
  comparisons over 159 million samples, 62,634 min/max register comparisons
  plus 3,011 block copies, and 156 material-index comparisons, all identical.
  `tools\build_native_hook.ps1` now runs that proof against the installed
  executable (`-SkipTerrainFastProof` to skip; it needs numpy, capstone and
  pefile in the gate's Python).
- Measured in game on a generated 56x56-tile world (Ryzen 9 5900X, 24
  threads): the four routines drop from about 15.8 to 11.4 worker-seconds per
  warm load. Wall-clock load stayed at 14 to 15 seconds in every run at the
  benchmark's one-second resolution, because the terrain phase is spread over
  the engine's thread pool; the saving is CPU work, larger in share on fewer
  cores or bigger maps. See
  [the investigation](../../investigation/TERRAIN_LOAD_FAST_PATHS_2026-09-17.md).
- Full automated gate passed: 164 core Lua tests, 431 Python tests and the
  1,024-event cross-language replay; native CTest, the pinned-executable
  profile test and the injector verify passed.
- No new live two-player construction or transport qualification accompanies
  this patch. Earlier construction/transport coverage gaps, the intermittent
  native Load Game stall and the lobby's two-computer path remain as in the
  [0.45.2 notes](RELEASE_NOTES_0.45.2-alpha.md).

## Update

Back up your saves, close active sessions and update both players to
**0.45.3-alpha** before starting a new session. Windows x64, Build 35924 and two
trusted players remain required. Protocol/state schema versions are unchanged.
Report bugs in #bugs-logs with the session support ID and what you were doing.
