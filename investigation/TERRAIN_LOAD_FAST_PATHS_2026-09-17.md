# Terrain load fast paths ported from tpf2-bigmap (2026-09-17)

Scope: evaluate the performance work in silver2127's `tpf2-bigmap` plugin
(commit `4f0de6f`, release 0.4.0, MIT) against TPF2MP, port the part that is
safe for a two-process lockstep prototype, and measure it in the game.
Outcome: four bit-identical replacements of stock terrain routines (alignment,
bicubic refinement, tile min/max plus block copy, and material-index
selection) are now part of the native hook, on by default, proved against the
pinned executable's original machine code, and measured on a generated
56 × 56-tile world: they remove about 4.4 of the 15.8 worker-seconds those
routines cost per warm load. Wall-clock load time on this 24-thread machine
did not move at the benchmark's one-second resolution.

## What tpf2-bigmap contains

The plugin targets the same Steam Build 35924 executable (SHA-256
`782b904a…85175c`, identical to TPF2MP's pin) through a separate plugin host
that its sibling project `tpf2-multiplayer` installs. Its performance work
falls into four groups:

| Group | Items | Evidence in its own docs |
|---|---|---|
| Load time, code | bicubic refinement (`0x3ac6c0`), tile min/max scan + height block copy (`0x33cec1`, `0x30a540`), terrain alignment (`0x3b3470`), material-index selection (`0x315f20`) | offline comparisons against the original machine code; "No in-game measurement yet" for every one of them |
| Load time, system | Windows Segment Heap through an IFEO registry value | 57 × 57 km map: load ~960 s to ~65 s, 545 CPU-s of free-list walk to 0 (measured once) |
| Memory | lossless terrain-tile and material-index pagers, instance-list shrink, copy-on-write tile sharing | 256² save ~18 GB to 10.5 GB working set (measured); COW sharing measured as useless and shipped off |
| Generation | placement attempt budget (200 to 50), Lua terrain-buffer reuse, world-entry timers, octree depth, map-size ladder | "not a measured 4x speedup"; buffer reuse "has not run in the game" |

Its own rule for every item is "separate cfg switch (default off), byte-verified
hook sites with fallback to the original, an offline test that executes the
original machine code and compares complete outputs, and an in-game load-time
measurement before enabling by default".

## What was ported and why

Ported: the four load-path replacements that are bit-identical by
construction and by test. They are pure functions of their inputs, so two
peers may run different settings without diverging, and nothing they touch
enters a digest.

- `align`: `terrain_alignment_util::CalculateHeightMod`. Six per-call heap
  allocations filled one word at a time become one pooled buffer reset with
  two `memset`s; the stock rasteriser still draws every triangle; the final
  blend skips all-zero-weight samples eight at a time and evaluates the rest
  four lanes wide with the same IEEE single-precision operations in the same
  grouping.
- `refine`: `sub_terrain_util::InternBicubicRefine`. The 20 per-cell
  divisions become per-call constants and the two constant Hermite matrix
  products are inlined, dropping only terms multiplied by exactly 0.0 or 1.0.
- `minmax`: the inlined `CalcMinMaxHeight` scan inside terrain publication
  becomes a 69-byte in-place patch that calls an SSE2 unsigned min/max with the
  stock register contract, and the uint16 height block copy becomes a per-row
  `memcpy` for disjoint spans.
- `material`: the `MaterialIndexManager` pixel selection visited pixel-major
  instead of once per batch of eight layers, keeping the nine-layer overlap,
  overlay and mask precedence, the 0xe9 sentinel, the fallback material and
  the scalar interpolation order.

Not ported, with the reason:

- Segment Heap: already investigated here
  (`HEAP_AND_PERFORMANCE_INVESTIGATION_2026-09-13.md`, ~150 MiB and no load
  change on the archived fixture). The bigmap measurement is real but was
  taken on a 57 km map; TPF2MP's lobby generates stock sizes. The IFEO value
  is machine-wide and needs elevation, which the per-user installer does not
  have. Worth a documented manual step for large-map players, not automation.
- Terrain and material pagers, instance shrink: memory features with
  placeholder-backed sections, a vectored exception handler and engine
  allocator ownership. Correct only with exact lifetime control that bigmap
  itself reworked twice; the loads below peak at 5.4 GiB private, so the
  saving buys nothing at stock sizes and the risk is real.
- Placement attempt budget, Lua buffer reuse, octree depth, map-size ladder,
  density levels: change generated worlds or need matching settings on every
  peer. Generation happens once on the lobby host, so lockstep is not at
  risk, but they alter placement and are unmeasured or untested in game.

## How it sits in TPF2MP

- `native/include/tpf2mp/native_terrain_fast.hpp`,
  `native/src/native_terrain_fast.cpp` and `native/src/native_material_fast.cpp`
  (hook support library): the implementations, the pinned byte regions
  (prologues, whole function bodies, constants and the two predicate vtables,
  copied unchanged from bigmap), request parsing and the installers, behind a
  plain-C `Host` seam (module base, guarded byte compare, hook, patch) so the
  same installer runs in the game, in CTest against a fake host, and in the
  Python proofs against the mapped executable.
- `native/src/native_terrain_fast_hooks.cpp` (hook DLL): the live services.
  Hooks go through MinHook and are enabled immediately, so a failure stays
  confined to that fast path. The in-place scan patch suspends every other
  thread, refuses if any of them is executing inside the 69 bytes, writes,
  flushes the instruction cache and resumes.
- `hook_dll.cpp` gained one line: the module installs after the visitor
  hooks. `HookFlags` carries the result and the status JSON reports it as
  `hooks.terrainFast` (`requested`, `align`, `refine`, `minMaxScan`,
  `blockCopy`, `material`, `timing`, `error`, and with timing on the
  per-routine `calls` and `seconds`).
- Default on. `TPF2MP_NATIVE_TERRAIN_FAST` in the game process's environment
  overrides: `off` or `stock` restores the stock code; a comma-separated
  subset of `align`, `refine`, `minmax`, `material` selects paths; `timing`
  wraps every hooked routine (fast or, under `stock`, the original) with
  QueryPerformanceCounter accounting; an unknown token fails closed with the
  reason recorded. The launcher and injector pass the environment through.
- Hook version stays `0.20.0`: every Lua and PowerShell contract is
  unchanged, matching the 0.44.3 precedent of a behaviour-preserving native
  optimisation.
- `tools/run_native_save_benchmark.ps1 -NativeHookDll` launches the
  benchmark through the injector and keeps the hook's status JSON as
  evidence; `tools/summarize_terrain_fast_benchmark.py` tabulates a series.
- `tools/check_source_boundaries.ps1` budgets the new sources; `hook_dll.cpp`
  stays at 1,349 of 1,350 lines after reflowing one array.
- Attribution: `docs/THIRD_PARTY_NOTICES.md`,
  `native/third_party/tpf2-bigmap/` (upstream license and file mapping), and
  packaged releases ship `licenses/tpf2-bigmap-MIT.txt`.

## Proof of bit-identity

Upstream's own tests, run unchanged on this machine against the installed
`E:\SteamLibrary\...\TransportFever2.exe` and a locally built `tpf2_bigmap.dll`,
passed first: 1,374 alignment comparisons, 4,315 refinement comparisons,
62,634 min/max register comparisons plus 3,011 block copies, and 156
material-index comparisons, all identical.

Ported to TPF2MP:

1. CTest `pinned_profile_usage` (`native/tests/native_terrain_fast_tests.cpp`,
   no game needed): request parsing including the default policy; the
   installer against a fake host (an empty request touches nothing; a full
   request verifies every pinned region, hooks exactly the entry points and
   patches the scan once; a mismatch, a hook failure, a failed scan patch, a
   missing module base and an unparseable request each refuse only what they
   must; `stock,timing` hooks all four routines as pass-through timers without
   reporting any fast path active); the SSE2 scan and block copy against
   scalar references; the refinement and the alignment blend against scalar
   transcriptions of the stock operation order (40 alignment rounds up to
   257 × 257 through a stub rasteriser); the material selection's region
   writes, fallback material and every geometry fallback.
2. `tests/native_terrain_fast/` (`align_proof.py`, `refine_proof.py`,
   `minmax_proof.py`, `material_proof.py`, ports of the upstream scripts):
   the stock routines execute as original machine code inside the Python
   process beside the hook DLL's exported implementations. Against the DLL
   built from this tree: alignment 1,374 comparisons over 12,868,596 block
   samples, three rounding modes, 16 threads sharing the scratch pool;
   refinement 4,315 comparisons over 159,270,080 samples; min/max 62,634
   register-harness comparisons plus 3,011 block copies; material 156
   comparisons; every result buffer and guard word identical, every fallback
   forwarded untouched, every installer refusal exercised.
   `tests/test_native_terrain_fast_proof.py` runs them under the gate when
   `TPF2MP_GAME_EXECUTABLE` is set, and `tools/build_native_hook.ps1` runs
   them through `tools/verify_native_terrain_fast.ps1` (skippable with
   `-SkipTerrainFastProof`).

## In-game measurement

Method: `tools/run_native_save_benchmark.ps1 -NativeHookDll` on the generated
56 × 56-tile lobby world `autosave_tpf2mp_worldgen_lab_b82855b4…_2000-01-05`
(40.7 MB, loaded from the Steam save directory, never saved), Ryzen 9 5900X
(12 cores, 24 threads), Vulkan, alternating arms so cache state is shared,
`-Seconds 20`. Load seconds are the whole-second difference between the
`load-request` and `world-ready` markers. Routine seconds are the summed wall
clock inside each hooked routine across all thread-pool workers, from the hook
status; the stock scan is inline code and cannot be timed, so its stock
column is blank. Evidence: `runtime/terrain-fast-bench-20260917/`.

| Run | Request | Load s | align s | refine s | copy s | scan s | material s |
|---|---|---|---|---|---|---|---|
| smoke (cold) | stock,timing | 30 | 7.538 | 2.917 | 0.556 | | |
| stock-1 | stock,timing | 14 | 7.047 | 2.930 | 0.571 | | |
| stock-2 | stock,timing | 15 | 7.093 | 2.966 | 0.589 | | |
| stock-3 | stock,timing | 14 | 7.069 | 2.964 | 0.572 | | |
| fast-1 | timing | 14 | 5.124 | 1.054 | 0.508 | 0.041 | |
| fast-2 | timing | 14 | 5.122 | 1.050 | 0.512 | 0.039 | |
| fast-3 | timing | 14 | 5.086 | 1.040 | 0.524 | 0.042 | |
| stockm-1 | stock,timing | 15 | 7.302 | 2.985 | 0.589 | | 5.277 |
| stockm-2 | stock,timing | 14 | 7.107 | 2.980 | 0.571 | | 5.148 |
| fastm-1 | all,material,timing | 14 | 5.229 | 1.065 | 0.534 | 0.045 | 4.701 |
| fastm-2 | all,material,timing | 14 | 5.191 | 1.053 | 0.535 | 0.044 | 4.654 |

Per warm load: 101,183 to 101,228 alignment and refinement calls, 554,070 to
554,195 block copies, 6,402 scans, 50,176 material calls. Warm means:

| Routine | Stock s | Fast s | Saving |
|---|---|---|---|
| alignment | 7.07 | 5.11 | 1.96 (1.38x; the untouched rasteriser dominates on this densely covered world) |
| refinement | 2.95 | 1.05 | 1.90 (2.8x) |
| block copy | 0.58 | 0.51 | 0.07 (first-touch pages bound it) |
| scan | inline | 0.04 | |
| material | 5.21 | 4.68 | 0.53 (1.11x) |

About 4.4 worker-seconds of the 15.8 the five routines cost per warm load
are gone, but every warm load still reads 14 or 15 s at the marker
resolution in both arms: the terrain phase runs on the engine's thread pool
(24 workers here), so the saving is spread thin, and other load work sits on
the critical path. On fewer cores or larger maps the same saving is a larger
share of wall time. Peak private memory was 5.39 to 5.44 GiB in every run.
Every run reached `world-ready` and exited normally with all requested paths
reported active and no refusal.

## What was not proved

- No wall-clock gain was demonstrated at this map size on this CPU; the
  measured gain is worker time. A one-second marker resolution cannot see a
  saving of a few hundred milliseconds; a finer load timer would need a
  high-resolution clock in the benchmark script or a stock timing line, and
  the game's stdout carries none for save loads.
- World entry after lobby generation was not timed separately; the material
  routine is hot there per bigmap's profile, and it is the same code.
- Nothing here changes what the two peers compute, but the pooled alignment
  scratch retains about 0.8 MB per concurrent worker for the life of the
  process, and sticky MXCSR status flags may be set by lanes the stock code
  would skip; nothing in the game reads them.
- The upstream steal-length assertion has no equivalent because MinHook
  measures the prologue itself; the capstone audit of whole instructions and
  the absence of RIP-relative operands still runs in the proofs.
- The gate's Python now needs numpy, capstone and pefile for the proof step
  of `build_native_hook.ps1`; the offline gate itself does not.

## Next

1. Where the remaining alignment time goes is the stock rasteriser
   (`0x2375420`/`0x23754b0`), 5.1 of the 15.8 worker-seconds; a bit-identical
   replacement would need the float rasterisation reverse-engineered and
   proved the same way, and the world-entry road-connection stage bigmap
   measured at 127 s of a 230 s new-world entry has no safe change identified.
2. A populated two-process run with both hook statuses showing the five
   flags true, as part of the next transport UI qualification.
3. The Segment Heap as a documented manual step for players who generate
   large worlds.
