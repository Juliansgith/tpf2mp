# Seven performance avenues — 2026-09-13

## Scope and evidence standard

This is a follow-up investigation, not a declaration that every possible engine
optimization or workload is exhausted. Runtime evidence lives under
`runtime/performance-avenues-20260913/`. All game tests use the disposable archived
53 MB fixture, not the user's personal world. Scripted loading is not physical UI
acceptance; the two-instance test is hardware contention, not multiplayer sync.

## Coverage ledger

| Avenue | Work completed | Remaining qualification |
| --- | --- | --- |
| Frame time / CPU stacks | WPR CPU trace attempted; denied with `0xc5585011`. Process/thread CPU and GPU counters collected. Separate intrusive instruction-residency sampler ran successfully. | Actual present/frame times and full CPU call stacks remain unavailable. RIP sampling is not a substitute for either. |
| Construction preview | Audited native capture gate, GUI caching and diagnostic throttling; identified 21 `VirtualQuery`-backed field reads per edge. Isolated query microbenchmark completed. | No live moving-tool/build stress or complete decoder latency measurement in this pass. |
| Busy simulation | Paused/1x/4x/paused/camera/1x native sequence tested with speed readback. Parallel destination-selection code identified in Ghidra. | Fixture is small; no dense population, large fleet or maximum-throughput qualification. Existing archives inspected were also small. |
| Synchronization / waits | Per-thread CPU and wait-state snapshots, three hot threads sampled separately. Audited capture lock scope and async bridge I/O lock boundaries. | No measured mutex ownership/blocked-duration attribution; snapshot waits do not prove lock contention. |
| Mod overhead / two instances | Same-fixture callback ablation and one/two/one-instance test completed. | Callback ablation leaves resource modifiers active. No active companion/hook/economy/network overhead comparison. |
| Rendering / UI | Camera-change phase, GPU engine counters, sampled native renderer functions, OpenGL experiment. | Camera moves once per second, not smooth movement; no vehicle-window or construction-panel interaction acceptance. |
| Allocations | Decompiled sampled renderer routines with temporary vectors/free paths; prior CRT/default-heap findings retained. Readability-query microbenchmark isolates a separate syscall cost. | No allocation-event stacks, allocation-rate attribution or validated allocator replacement. |

## Native scaling and callback ablation

Each phase lasts 20 seconds; summaries discard the first two seconds. Both runs
read back speed 0/1/4 as requested and advance simulation time at 0/1/4 accordingly.
CPU is percent of **one** logical core: 200% means two cores' worth, not 200% of
the whole workstation.

| Phase | Full game-script CPU | Inert game-script CPU |
| --- | ---: | ---: |
| Paused | 188.9% | 203.9% |
| Speed 1 | 214.1% | 210.2% |
| Speed 4 | 219.2% | 217.0% |
| Paused repeat | 197.5% | 202.6% |
| Camera changes | 174.2% | 173.0% |
| Speed 1 after camera | 215.4% | 223.7% |

The experimental ablation replaced only the **test-installed copy** of
`res/config/game_script/tpf2_mp.lua` with inert callbacks, then restored it in
`finally`. No source gameplay code or saved state was modified by the ablation.
The source mod resource loader remained active, and the normal run was not a
connected initialized match. Consequently this cannot establish total MP overhead.
There was no large callback-related saving in this workload. Most measured CPU
remained while paused. That supports investigating rendering/GUI/background work,
not a claim that agents are cheap on large worlds.

The camera phase increased private memory by roughly 0.25 GiB in both runs.
This is compatible with view-dependent resource loading, **not proof of a leak**.
Twelve GPU 3D-engine counter samples in the first run averaged 32.1%, maximum
33.2%. This short interval does not establish GPU headroom in every view.

## One / two / one instance

The primary ran for 180 seconds. A second independently loaded copy joined for
60 seconds and exited. Markers use separate files so a shared game stdout file
cannot silently mix process evidence. All owned processes exited normally.

| Primary interval | Seconds sampled | One-core CPU | Simulation/wall rate |
| --- | ---: | ---: | ---: |
| Alone before second launch | 54.8 | 208.0% | 1.0 |
| Both worlds loaded | 52.8 | 200.7% | 1.0 |
| Alone after second exits | 23.3 | 204.5% | 1.0 |

No simulation-throughput collapse reproduced on this fixture. Lower CPU does not
mean higher FPS: foreground/render throttling can change work submitted. These
results cannot dismiss the user's heavy-build or dense-network stutters.

## Native instruction sampling and Ghidra correlation

The separate diagnostic selected three threads by one-second CPU deltas, then
sampled 100 instruction pointers per thread. It briefly suspends one selected
thread at a time and resumes it in `finally`, never writes registers/memory, and
is deliberately excluded from comparison timings. The hottest thread used
0.984 CPU seconds during selection. Its 100 instruction-residency samples were:
44 game, 32 ntdll, 14 NVIDIA driver, 5 win32u, 5 other runtime libraries.
The two other selected threads each had 96/100 samples in ntdll; this is compatible
with workers waiting between jobs, not proof of a lock defect.

Sampled game ranges were correlated to Ghidra function bodies and retained
assertion strings. Examples:

- RVA `0x24c16d0`: `BillboardTechnique::BindSpecialSSBO` (3 samples in its unwind range).
- RVA `0x25ce2c0`: Vulkan descriptor-binding/streaming-texture-related code (3).
- RVA `0x24a2fa0`: `DynamicModelRenderer::Render` (2).

These low individual counts identify concrete profiling leads, not ranked CPU
percentages for functions. The billboard routine includes temporary-vector/free
paths, but their allocation cost has not been isolated. See `sampled-functions/`.

The native context definitions and suspension requirements were checked against
[Microsoft's CONTEXT documentation](https://learn.microsoft.com/en-us/windows/win32/api/winnt/ns-winnt-context)
and [GetThreadContext](https://learn.microsoft.com/en-us/windows/win32/api/processthreadsapi/nf-processthreadsapi-getthreadcontext).
The broader Ghidra pass completed analysis in 1,359 seconds, exported 47 selected
functions, and saved its database. It emitted RTTI/data-layout errors, so this is
not a clean semantic audit. Retained symbols now explicitly identify parallel
`destination_util::GetRandomTargets` jobs and HUD-icon worker jobs; the generic
exporter's `simulation-workers` category also contains UI jobs and must not be
read as a precise subsystem classification.

## Renderer backend / pacing control

OpenGL was confirmed in native stdout (NVIDIA OpenGL 3.2), not merely requested
in settings. All quality settings and the fixture were retained. The OpenGL
scaling run completed all phases; normal and 4x simulation kept their rates.

| Normal-speed interval | One-core CPU | Console callbacks/second |
| --- | ---: | ---: |
| Vulkan, saved VSync true | 214.1% | 164.6 |
| OpenGL, VSync true | 117.5% | 60.0 |
| OpenGL, VSync false, separate steady control | 174.3% | 107.1 |

These are callback rates, **not measured presentations/FPS**. The control shows
that pacing changes CPU demand without changing simulation progress, and is a
reason not to attribute the entire OpenGL CPU difference to faster engine code.
There is no recommendation to switch all users' renderer backend from these
short tests. The original Vulkan/VSync settings were restored byte-for-byte;
the current settings and backup SHA256 both read
`83fb68055ffd6702a9a6b4dfc68ce03e1662a28b8602a12e3ca00fcc51488043`.

## Construction and memory-readability work

`ReadEdges` first validates vector storage and then calls `ReadAt` for 21 scalar
fields per edge. Each read validates its memory range with `VirtualQuery`.
Factory capture decoding holds an exclusive capture lock. Large proposals can
therefore incur both query work and a longer lock hold, but no live lock wait was
measured here. The factory gate requires enabled capture plus nonzero correlation;
it is not unconditionally decoding every native call.

The C# microbenchmark includes P/Invoke overhead and deliberately does **not**
claim complete C++ decoder timings. The corrected run hoists structure-size work
out of the timed loop. For 1,024 records, median query-loop time was 14.0 ms with
21 checks/record versus 0.668 ms with one. For 8,192 it was 374 versus 17.7 ms.
Allocation layout strongly affected runs; do not extrapolate these numbers to
actual station latency. A one-check replacement has not been proved safe: memory
lifetime, page boundaries and captured-value integrity must be preserved.

Existing preview optimizations were confirmed, not implemented anew: compact
native gate status, lightweight construction transform retention, click-time
rebasing and throttled detailed diagnostics. The async bridge performs actual
file I/O outside its queue lock; a lock-free rewrite is not justified by this audit.

## Diagnostic correctness finding

The older `sample_live_runtime_performance.ps1` labels console `update` callback
rates as FPS. Its source counter increments in `multiplayer_menu_bootstrap.lua`'s
`update`, not at a verified presentation boundary. Treat those legacy numbers as
callback rates. New reports explicitly set `fpsMeasured=false` and do not rely on
those fields. No gameplay change was made as part of this finding.

## Tests and remaining work

The benchmark lifecycle mock now covers all six phases and camera API calls.
Four summary tests cover aligned windows, missing phases, rejected speed readback
and absent process samples. Script syntax and the separate sampler were checked;
the latter also completed the live diagnostic. No full offline gate was run
alongside the live games. No production binary patch or gameplay change was made.

The highest-value remaining work is a representative dense-world and live-preview
capture with present timings and full stacks. This report explicitly leaves
those rows partially qualified rather than treating unavailable measurements as
passes.

## Final verification and cleanup

Seven owned game launches completed and exited. Temporary fixture files and the
test-only mod installation were moved to `staged-after-tests/`, not deleted. The
prior absent-mod installation state was restored. No game or Ghidra Java process
remained at cleanup. Original executable SHA256 is still
`782b904a8f7bbdac1f7a18528f1a5c778691e5aa3087c37c351bf6912585175c`;
personal `New Game.sav` is still
`fd27dbd8df07aa79c6c810e68e8d3d924389a809f5794a5e5c9a475dfe2aa1da`.
Vulkan/VSync settings were restored to the byte-identical backup. The existing
user-authorized heap registry setting was not changed.

Final focused verification: benchmark Lua lifecycle/six-phase test passed;
4 scaling-summary tests and 5 binary-variant safety tests passed; both new/updated
PowerShell benchmark scripts parsed; `git diff --check` passed. These do not
replace a full multiplayer regression run. Nothing was committed or released.
