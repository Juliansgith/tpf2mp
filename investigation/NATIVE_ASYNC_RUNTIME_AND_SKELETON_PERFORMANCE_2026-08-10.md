# Native async runtime and skeleton performance, 2026-08-10

Prototype: `0.37.0-alpha`
State schema: `30`
Native hook: `0.17.0`
Game profile: exact Windows x64 Build 35924

## Why this slice exists

A populated two-process localhost run showed a persistent host/client frame-rate
asymmetry even after the earlier wallet, manifest, and GUI scan reductions. On
the Ryzen 9 5900X / RTX 4090 lab machine, both game processes were primarily
limited by one main simulation thread. The host was not GPU-bound, memory-bound,
or short of available cores. The remaining mod hot path still performed file
system work, maintenance probes, and diagnostic projection from the game Lua
thread at engine-update cadence.

This slice removes that avoidable work. It does not claim to make Transport
Fever 2's native simulation multicore. Re-threading engine-owned entity access,
commands, pathing, or GUI objects would violate thread-affinity assumptions and
is outside the supported exact-build boundary.

## Implemented runtime changes

### Native asynchronous bridge

Hook `0.17.0` exposes a process-owned asynchronous transport:

- Lua still signs and JSON-encodes every protocol envelope.
- The game thread enqueues the resulting opaque bytes in memory and takes
  already-read inbound bytes from memory.
- The existing native worker publishes numbered `game_outbox` files and polls
  the exact `game_inbox` successor outside the simulation thread.
- Sequence numbers, immutable numbered files, checksums, companion semantics,
  and durable replay evidence are unchanged.
- A process reload reconfigures the native transport even when the save contains
  a serialized `active` flag from an earlier process.
- If the exact hook is unavailable, the previous synchronous Lua file path
  remains available at its compatibility cadence.

The transport fails closed. Its hard limits are 4,096 queued messages, 64 MiB
of queued data, and 8 MiB per message. The bridge root must be a child of the
process `%TEMP%\tpf2mp_bridge` directory. It refuses sequence gaps and existing
outbox targets rather than overwriting evidence. Failed writes remain queued
and retry after 100 ms. Inbox polling and publishing use bounded batches of 32.

The hook status file is now coalesced to at most four writes per second. Command
observation counters remain in memory between status publications.

### Engine pump scheduling

`network_pump_runtime.lua` now owns engine-side network maintenance. Authority
work keeps its required cadence; stable or empty diagnostic work does not:

| Work | Runtime cadence |
|---|---:|
| Native in-memory bridge ingress | every network update |
| Shared clock and economy clock | every network update |
| Deferred ordered work | every network update |
| Vehicle synchronization with registered vehicles | every network update |
| Vehicle synchronization with no vehicles | every 30 updates |
| Content/freight maintenance while unresolved | every 15 updates |
| Content/freight maintenance after READY/fault | every 300 updates |
| Clock-health emission | every 15 updates; paused heartbeats keep their wall-time policy |
| Native bridge diagnostic readback | every 60 updates |

The no-hook compatibility path intentionally defaults to exact one-update file
polling. A larger fallback stride is an explicit developer setting, not a
silent behavior change.

`performance_runtime.lua` measures each scheduled task with the hook's native
monotonic clock (`QueryPerformanceCounter`) and retains a bounded 128-sample
window. Calls, failures, total/last/maximum/average time, p50, p95, scheduler
runs, skips, and stride are exported in public/research snapshots. The
Multiplayer panel also exposes the current native queue and the bridge/vehicle
p95 timings, so a future slow run can be attributed without another blind
profile.

Routine native-observation telemetry now sends a digest plus a bounded shape
summary. Complete proposal/event shapes remain in the bounded local research
records. GUI public capture uses counts and retained-tail metadata instead of
copying the full diagnostic histories, and stock toolbar projection skips
native GUI writes when its formatted value has not changed.

## Exact skeleton crowd policy

The default `skeleton` mode now means exactly one native capacity slot for every
otherwise populated town building. The old divide-by-64 rule could leave ten
or more native people in a large building, which defeated the stated policy on
dense modern maps.

Skeleton retains 25% destination recomputation so the small decorative crowd
can move through streets, stations, and vehicles. `empty` also uses the
Build-35924-safe capacity floor of one, but disables destination recomputation;
literal zero remains unsupported because this game build fatally asserts while
generating a town. `vanilla` remains available for players who explicitly
prefer the full native crowd.

Native people are presentation only. Canonical town size, passenger demand,
queues, loads, completed-trip revenue, scoring, and growth continue to use the
authored model and building-count inputs. The capacity ceiling is included in
the match-content fingerprint, so peers cannot silently run different crowd
policies. Construction resource modifiers are applied during world generation
or load; a running old world is not mutated in place.

## Localhost process policy

The localhost launcher now defaults to a `Balanced` development profile:

- the two game processes receive disjoint processor-affinity sets;
- on the 12-core/24-thread Ryzen lab machine, player 1 receives `0x000fff` and
  player 2 receives `0xfff000`, keeping each main thread and its helpers on a
  separate six-core CCD;
- other SMT machines use alternating complete sibling pairs;
- both games retain normal process priority;
- the temporary test settings use VSync and 1920x1040 windows, laid out side by
  side after both worlds load;
- the original settings file is still restored byte-for-byte by the harness.

`-LocalhostPerformanceProfile Native` disables affinity, VSync/window overrides,
and layout changes for comparison or troubleshooting. Affinity is a localhost
lab optimization only; normal one-game-per-computer Host/Join sessions do not
need it.

## Verification

- Native x64 Release build: passed in an isolated build directory.
- Native CTest: 2/2 passed, including FIFO limits, TEMP-root containment,
  immutable output, inbound sequence identity, and status counters.
- Lua suite: 131/131 passed, including native and no-hook bridge paths,
  scheduler cadence, skeleton capacity, load migration, and GUI projection.
- Full `tools/run_tests.ps1`: passed, including game-script integration,
  company mapping, hot-seat, GUI/native capture, companion protocol/consensus,
  cross-language economy/freight checks, and the 1,024-event replay.
- Replay result: 1,024 events verified; final model digest `c9fe205f`.
- Source-boundary ratchet: passed.

The source currently passes every offline gate. The game pair used for the
baseline profile predated this hook and is not performance evidence for it.
The next fresh two-process launch is the live acceptance gate: compare
same-camera running FPS,
`performance.tasks` p95 values, queue depth/rejections, clock progress, and
station-barrier behavior. No FPS multiplier is claimed before that run.

## Remaining engine limits

- Native simulation, pathfinding, rendering submission, and entity APIs remain
  controlled by Build 35924 and are largely main-thread-bound.
- Running two fully rendered instances still performs two complete native
  simulations. Window resolution, camera complexity, vehicle count, and vanilla
  graphics settings therefore still matter.
- The skeleton policy materially reduces person simulation, but it does not
  remove vehicles, cargo presentation, path searches, or construction geometry.
- Any future native worker may process only immutable copied data. Engine
  pointers, Lua states, entity views, GUI objects, and commands stay on their
  owning threads.
