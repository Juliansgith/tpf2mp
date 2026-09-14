# Native decompilation and render-worker experiment — 2026-09-13

## Scope and provenance

This is actual Ghidra decompilation, not just string searching. It is **not** a
complete semantic audit or a reconstruction of the original source project.
The installed executable was never edited. All analysis uses a byte-identical
copy of Build 35924, SHA256
`782b904a8f7bbdac1f7a18528f1a5c778691e5aa3087c37c351bf6912585175c`.

Ghidra 12.1.3 and Temurin JDK 21 were downloaded from their official release
endpoints and checked against their published SHA256 values. Ghidra archive:
`93a5d11a9ad510622acaaf908c556a7b9b764d338e78a7567f3689bf5081fd54`;
JDK archive: `f9d6e191ab098c0d416e7d588a24420a8621cd2f4720dab2459b8b7b2d2d8b4e`.
Sources: [Ghidra release](https://github.com/NationalSecurityAgency/ghidra/releases/tag/Ghidra_12.1.3_build),
[headless analysis documentation](https://github.com/NationalSecurityAgency/ghidra/blob/Ghidra_12.1.3_build/Ghidra/RuntimeScripts/support/analyzeHeadlessREADME.md).

Local evidence is under `runtime/native-performance-20260913/`. It includes
the input copy, Ghidra projects, console/analysis logs, candidate references,
decompiled C-like pseudocode, the experimental executable and live reports.
Do not distribute the game executable or treat inferred pseudocode as original,
rebuildable source. These artifacts remain ignored by Git.

## Coverage and limitations

- The PE has 138,070 unwind entries; these are not a count of reviewed functions.
- Broad auto-analysis reached the explicit 900-second limit and saved partial
  results. The saved database reports 182,702 discovered functions, including
  analyzer-generated boundaries. This is not proof all boundaries are correct.
- Six initial ranges and seven thread-pool caller ranges decompiled successfully
  in a separate targeted database. The broad database exported 16 selected
  functions, with overlap. A timeout exit code of zero was **not** treated as
  complete analysis; the log explicitly reports the timeout.
- No matching PDB was available. Strings, RTTI, unwind metadata, imports and
  instruction references supply the evidence. Some automatic analysis emitted
  invalid-address/pcode warnings; names and types must not be trusted blindly.

## Verified code paths

Addresses below are RVAs for the pinned build, not portable hooks.

| RVA / evidence | Observed implementation | Consequence |
| --- | --- | --- |
| `0x2381ef0`, `ThreadPool.cpp` constructor assertion | Worker count comes from argument 3 and must exceed zero | There is no universal hardcoded single-worker pool |
| `0x327eb0`, RenderDataManager constructor | Worker pool uses `max(1, hardware_concurrency / 2)` | Current 24-logical-CPU workstation requests 12 workers |
| `0x2382b20`, Save Pool initializer | Also uses half hardware concurrency, minimum one | Saves already have native parallel workers |
| `0x2382810`, Main/Sim Launcher initializers | Each launcher pool requests one worker | Launcher serialization is not proof all simulation work is single-threaded |
| `0x40fdb0`, ConstructionBuilder | Requests one worker | Blindly increasing this risks concurrent preview/state races |
| `0x4453b0`, StreetBuilderPool | Requests one worker | Same caution |
| `0x474e00`, TrackModifierPool | Requests one worker | Same caution |
| `0xa9af20`, SimPersonSystem::Update-associated assertion | This small routine checks an argument, returns or asserts | It is not the person-processing loop; profiling only the name would mislead |
| `0x133c30`, configuration reader | Reads the destination-recomputation setting into configuration offset `0x9a8` | Confirms native configuration binding, not its runtime cost or exact scheduling semantics |
| `0x2706cc0` | Calls `GetProcessHeap` then `HeapAlloc` | Confirms one real default-heap allocation path; does not prove all allocations use it |
| `0x9d2cf0`, CommandList::Swap | Destroys prior entries then swaps buffer pointers | Native command processing itself includes lifecycle/cleanup work |

The hardware-concurrency import was confirmed through the thunk at `0x2bf6314`
to `MSVCP140.dll!_Thrd_hardware_concurrency`, not inferred solely from a symbol name.
Other paths import CRT malloc/calloc/realloc/aligned allocation. Replacing the
allocator wholesale has not been established as safe or beneficial.

Native construction pools being serial does **not** explain the multiplayer-only
slowdown by itself: vanilla uses the same pools. Extra proposals, preview rebuilds,
validation and synchronization still require measurement.

## Research-only executable variant

`tools/create_native_render_worker_variant.py` changes only the renderer-worker
division instruction at RVA `0x32804d`, file offset `0x32744d`: `d1 f8` becomes
`90 90`. This removes division by two while retaining the minimum-one clamp.
It does not alter simulation, construction, street, track or save pool counts.

The tool requires the exact stock hash and bytes, creates a separately named
output using exclusive creation, and refuses the primary executable filename.
Five unit tests cover those conditions and preservation of all other bytes.
Experimental output SHA256:
`87dfdf1f73486dd28ef5ac599666bc5247a58f2e49d619624ef090210438bba6`.

This is a binary patch experiment, **not** a source rebuild. Production hook and
launcher hash gates remain unchanged and reject it. Only the diagnostic benchmark
accepts an explicitly supplied experimental hash, for a `TransportFever2_perf_lab*`
filename. No patch was installed into `TransportFever2.exe` or released.

## Measurement design

Use the archived, independently hash-pinned small world, never `New Game.sav`.
Run stock and modified bytes under the **same** temporary executable basename,
same save, same settings, normal speed, windowed, without Ghidra running.
Order: baseline 1, full-workers 1, full-workers 2, baseline 2.

`summarize_render_runs.py` compares OS process samples from native-ready +5 to
+35 seconds using Unix timestamps in the native markers. Both game time and
speed readback are checked. FPS is not measured. The saved VSync setting and
roughly 60 update callbacks/second limit extrapolation to an uncapped workload.

`sample_native_threads.py` reads thread CPU times without suspension or injection.
The game exposes no usable thread descriptions through GetThreadDescription in
these runs, so thread CPU cannot be attributed to named pools. Baseline 1 had
101 threads and full-workers 1 had 112; other background threads can vary.
One later thread sample outlived its game, and must be discarded; the sampler
now marks/fails an empty matching-thread capture rather than calling it a zero-CPU
success. The complete process-level benchmark evidence remains valid.

## Completed A/B/B/A result

All four runs loaded the same archived fixture and exited cleanly. Measurements
are the native-ready +5 to +35 second window, not startup averages.

| Run | Load seconds | Process CPU, % of one core | Mean private GiB | Simulation/wall rate |
| --- | --- | --- | --- | --- |
| Stock 1 | 16 | 89.39 | 5.275 | 1.0 |
| Full render workers 1 | 14 | 72.97 | 5.293 | 1.0 |
| Full render workers 2 | 14 | 82.85 | 5.298 | 1.0 |
| Stock 2 | 15 | 79.91 | 5.280 | 1.0 |

The CPU difference reverses across the repeats. There is no consistent benefit
established here, and no FPS measurement. Do not ship this patch as an optimization.
The temporary executable, fixture and test-only installed mod were moved into
`runtime/native-performance-20260913/staged-files-after-tests/`. No games remain
running. The primary executable retains its original SHA256; the personal
`New Game.sav` remains
`fd27dbd8df07aa79c6c810e68e8d3d924389a809f5794a5e5c9a475dfe2aa1da`.

### Additional static finding

The renderer-associated routine at RVA `0x332ce0` has a conditional queue-draining
loop bounded by `clamp(hardware_concurrency / 4, 2, 4)`. This is a per-pass work
limit, **not another pool-constructor worker count**. The exact queue payload has
not been identified. This is a concrete reason not to assume worker count alone
controls renderer throughput, but it is not a measured bottleneck or a safe patch
target yet. See `broad-export/function_140332ce0.c`.

Targeted decompilation of the allocation wrapper at RVA `0x2bf3a80` also completed.
Its two import thunks were then checked against the PE import table:
`0x142bf67bd` resolves to CRT `malloc`, and `0x142bf68a1` to `_callnewh`.
It retries allocation via the new-handler on failure. Thus this frequently called
wrapper is not evidence of a separate custom game heap; attribution of its runtime
cost still requires sampling rather than counting call sites.

## Remaining qualification

### Agent-event investigation

Four further bounded routines successfully decompiled into `agent-event-targets/`:
`NoteSimEntityIdleChanged` (`0xa8e170`), `NoteAtBuildingPersonsLeave` (`0xa93610`),
`NoteLineChanged` (`0xa94da0`), and a `FindPathLines`-associated routine (`0x971ba0`).
These are substantially larger than the 47-byte Update assertion stub. This
redirects profiling toward event processing rather than blindly throttling the
Update symbol. Sizes alone are not evidence of execution frequency or heat.

The line-change and building-departure pseudocode includes 624-element random
state initialization (the `0x270` loop). Retained signatures also name a Boost
Mersenne Twister engine. Reusing random state or skipping these event handlers
would require sequence-equivalence proof: such changes cannot be described as
gameplay-neutral merely because they reduce work. Ghidra emitted a type-propagation
warning on the line-change function; exact container types remain provisional.

A second broad automatic-analysis pass subsequently completed in 1,359 seconds
within its 1,800-second analysis limit, exported 47 selected functions and saved
the project. It emitted RTTI/data-layout errors: completion does not make every
inferred boundary trustworthy. See `continued-analysis-console.txt` and the
[follow-up investigation](PERFORMANCE_AVENUES_2026-09-13.md) for profiling results
and the additional parallel destination-selection evidence.

### Unmeasured workloads

Uncapped frame times, busy train networks, moving-camera/preview workloads,
two-peer synchronization under this patch, pathfinding cost distribution,
cross-machine benefit, and absence of long-run races are not qualified by a
small idle-map run. No performance patch should ship based on these tests alone.
