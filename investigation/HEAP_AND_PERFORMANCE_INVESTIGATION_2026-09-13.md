# Heap and performance investigation — 2026-09-13

## Verified this pass

- Reinstalled game is on `E:\SteamLibrary`, not the old `F:` path; its SHA256
  is the supported Build 35924 hash. Repository is now on Desktop.
- The user-authorized per-image `FrontEndHeapDebugOptions` DWORD is 8.
  Read-only inspection of the live default heap now also verified signature
  `0xddeeddee` (Segment Heap). The byte-identical renamed baseline executable,
  with no matching IFEO override, verified `0xffeeffee` (NT Heap).
- The preceding Steam launch exited normally at 02:06:55 according to stdout.
  No TransportFever2 process remains at the end of this pass.
- Original saves and active mod selection were not edited. The previous pass
  backed up settings and changed the window mode to WINDOWED, 1920x1040.

## Gameplay-neutral change

`performance_runtime.lua` now retains its last 128 measured durations in a
local ring rather than shifting the array on each overflow. Percentile refresh
copies/sorts once for both p50 and p95, rather than twice. Sampling frequency,
failure handling, return values, exported schema and refresh cadence are unchanged.
The ring cursor is process-local, independent of persisted measured-call counts.

Tests: faithful Lua core suite **164/164** passing (including the benchmark lifecycle). New regression compares
72 percentile refreshes across 8,192 calls, multiple wraps and resets, and checks
resuming persisted counters into an empty local history. Sorting happens once
per refresh. This is an operation-count improvement, **not a measured FPS gain**.

## Standalone sampler

`tools/sample_process_performance.ps1` accepts ProcessId, OutputPath, Label,
DurationSeconds and IntervalMilliseconds. It needs neither our mod nor a
multiplayer fixture and never drives the UI, injects a hook, changes speed,
changes registry settings, saves, or terminates the target.

It records raw CPU/private-memory/working-set/handle/thread samples, exact
executable and process start time. CPU utilization is labelled both per-core
and per-machine. Output uses create-new semantics; incomplete captures retain
evidence and throw. FPS and simulation throughput are explicitly null.

Verified with a sampler self-test (not a game measurement), refusal to overwrite
existing evidence, and a short-lived helper exiting mid-capture. Reports are in
`runtime/heap-test-20260913/`. Several populated-world benchmark runs completed;
see the evidence and limitations below.

## Live-test limitation and inspected alternatives

The available desktop-control skill requires a node_repl runtime that is not
exposed in this task. Existing live-UI harnesses ultimately use physical input;
they are not a headless substitute. No user action or additional save is being
requested as a workaround.

The earlier conclusion that scripted loading could not work was too broad.
The game's shipped `res/scripts/autotest/test.lua` uses `--script` and
`app.loadGame` from an update callback. Live tests established that this API
takes the save identifier **without `.sav`**. Extension-bearing names returned
false; the bare stem loaded a populated world, ran and exited normally.

`tools/native_save_benchmark.lua` and `tools/run_native_save_benchmark.ps1`
implement that route without mouse/keyboard input. They fence reentrant load
requests, require an exact binary hash, emit run-specific evidence, and close
only their owned process. This is native scripted testing, **not physical UI
acceptance or multiplayer validation**. Later live readback verified speed 1
after accepting callable native factory objects, not just Lua functions.

Fresh generation is different: `app.startGame` from the callback reproduced
`UI::CComponent::Render: !m_childMutex` in `fresh-native-1`. That experimental
branch was removed from the reusable runner. Do not infer that working load
means working fresh-world generation.

## Live measurements and save protection

- `NT-controlled-1`: normal exit; load requested at 10 s, world ready about
  62 s (roughly 52 s load).
- `Segment-controlled-1`: normal exit; load requested at 10 s, world ready
  43 s (roughly 33 s load).
- Earlier OS samples peaked near 10.05 GiB private bytes on NT versus
  9.54 GiB on Segment, but sampled phases and durations differed.
- These are **exploratory observations, not a causal performance percentage**:
  cache warming, executable-name-dependent driver profiles and uncontrolled
  speed readback confound comparison. Callback counts are not FPS.
- Intel-signed PresentMon 2.5.1 could not start ETW recording without additional
  privilege. No FPS result is claimed and no security permissions were changed.
- Only a separately named copy of `New Game.sav` was loaded. Original SHA256
  remained `FD27DBD8DF07AA79C6C810E68E8D3D924389A809F5794A5E5C9A475DFE2AA1DA`.
  The user subsequently requested a separate world for further tests.
- An old disposable recipe fixture survived under
  `runtime/localhost-live/localhost-ui-20260906-035517-10a5a8/starting-save/`.
  Its SHA256 `47fbd37409d999392301a884ef3caa6297c682c58cdfda604b1f89ce79f0f5e3`
  matches `content/live-ui/station-free.json`. It requires the official legacy
  vehicle pack and TPF2MP. The legacy pack was present; the current development
  mod was installed to load the separate fixture, without changing the user's
  save or its selected mods.
- `archived-fixture-segment-1` and `archived-fixture-segment-2` both loaded and
  exited normally. The fixture exists only in the Steam save directory, proving
  no duplicate in the game installation root is required. The second run waited
  for the script interface rather than just the in-game GUI. Both remained at
  speed 0: speed control was unavailable in this script context. These are
  load/idle tests, not running-simulation or multiplayer acceptance tests.
- Full offline gate reruns uncovered environment assumptions: tests expect
  Windows PowerShell, its temporary paths must stay within legacy path limits,
  and development companion subprocesses require Python on PATH even when the
  gate itself has an explicit interpreter. A cleanup exception previously
  obscured the originating failure; cleanup now warns without replacing it.
- With Windows PowerShell, a short temporary root and the verified Python venv
  on PATH, the full gate **passed**: 164 Lua tests, 393 Python tests, and the
  1,024-event cross-language replay. Evidence: `full-gate-configured.txt`.

## Controlled archived-world follow-up

Native command factories are sometimes callable tables/userdata. The benchmark's
function-only type check incorrectly labelled speed control unavailable. Accepting
the callable factory and waiting for script readiness fixed this; a mock regression
now covers the exact combination. `archived-fixture-segment-3`, `NT-1`, `NT-2`,
and `segment-4` all read back speed 1 and exited normally, in that order.

| Measurement | NT runs 1 / 2 | Segment runs 3 / 4 |
| --- | --- | --- |
| Load seconds | 14 / 15 | 15 / 15 |
| Peak private GiB | 5.643 / 5.622 | 5.489 / 5.461 |
| Sim seconds per wall second | 0.987 / 0.987 | 0.987 / 0.993 |

These short, small-map tests demonstrate successful normal-speed operation, not
maximum simulation throughput. Startup speed transition contributes to values
slightly below 1. Warm-load performance is effectively equal in this sample.
Peak private-memory difference is roughly 150–160 MiB, not a dramatic saving.

CPU results are **not comparable as a heap efficiency result**: the NT repeat
used 78.5% of one core versus 186% for the Segment repeat, but callback rates
differed substantially (about 60 vs 160–190 per second). Both used the same
Vulkan GPU and saved VSync setting; renamed-executable driver behaviour and
foreground/render scheduling remain uncontrolled. Callback rate is not an FPS
measurement. Do not market the registry flag as a proven FPS multiplier.

The repeat markers include Unix timestamps so future CPU samples can be aligned
to the actual in-world interval. `runtime/heap-test-20260913/summarize_runs.py`
recomputes these summaries from the raw reports.

## Cleanup

All benchmark game processes exited. Temporary staged saves, the two probe Lua
files, the byte-identical renamed executable and the temporarily installed mod
were moved into `runtime/heap-test-20260913/staged-files-after-tests/`, not deleted.
The normal game save browser and prior absent-mod installation state were restored.
The original `New Game.sav` hash was checked again and is unchanged. DWORD 8 remains
enabled; windowed mode remains as requested. No release or commit was made.

## Remaining empirical work

Use a disposable archived fixture for subsequent tests, with
identical mods, camera, speed and graphics. Repeat baseline/enabled runs in
alternating order, distinguishing cache-warm loading from first loading.
Record load wall time, CPU and memory; use frame-time instrumentation for FPS,
and native game-time telemetry for simulation throughput. Confirm the actual
heap type before attributing a result to Segment Heap. Leave DWORD 8 enabled
after any explicitly controlled baseline comparison.

Further candidates require profiling, not blind changes: allocator CPU during
loading, agent destination/path recalculation, GUI/preview reconstruction and
durable bridge I/O. The existing skeleton policy sets destination recomputation
probability to 0.25 and changes population capacities; using it on a vanilla
save would change gameplay and is not a neutral heap benchmark. Do not claim
that this probability directly translates into 75% less CPU.
