# Live station barrier and GUI performance, 2026-08-10

Prototype: `0.37.0-alpha`
State schema: `30`
Native hook: `0.17.0`
Game profile: exact Windows x64 Build 35924

## Control run

The populated localhost session
`perf-017-skeleton-20260810-2217` remained running on its originally installed
build while the corrections below were made in the source tree. It is therefore
an uncontaminated control, not evidence for the corrected build.

At the approximately 30-minute sample:

- both peers remained connected and responsive;
- the session was unfaulted and had completed 51 checkpoint boundaries;
- two vehicles were tracked;
- 30 station-release rounds completed with no release fault;
- mean wall-clock release latency was `37.488 s`, with a maximum of `38.797 s`;
- every held-to-released round advanced its target by exactly 144 game-time
  units; and
- corresponding vehicle arrivals differed by roughly 0 to 0.8 game-time units,
  with no correction or synchronization fault.

This distinguishes a healthy rendezvous with a bad release guard from actual
vehicle drift. The copies reached the same stop closely and waited correctly;
the guard itself imposed almost all of the visible dwell.

Running clock health was also stale: `progressRateRatio` and `gameTimeSkew`
were null even though both worlds were advancing. The companion therefore had
insufficient fresh telemetry for adaptive clock decisions during ordinary
running play.

A later read-only sample, about 46 minutes after launch, remained unfaulted and
responsive with 64 complete checkpoints and 53 releases. Mean release latency
was then `39.613 s`, maximum `44.141 s`, with one ordinary release order in
flight and zero vehicle-sync faults. This confirms that the control's long
dwell was persistent rather than a startup transient.

## Extended live analysis

The pair was inspected again without sending a command or changing either
process. At 23:38 local time, approximately 81 minutes after launch, both games
and companions remained responsive and connected. The host had 93 complete
checkpoints, no checkpoint/proposal/operation consensus pending, 99 completed
vehicle releases, two ordinary current stop rounds in flight, and zero vehicle
faults. Its game-outbox reader was one message behind the writer; the client was
at the exact tail. There was no queue accumulation or session error.

An independent replay of a closed audit snapshot reported:

- 208 commits and 116 controls;
- all 208 commit states converged, with zero missing peer digests;
- 22/22 physical proposals complete and 9/9 physical operations complete;
- 85/85 checkpoint barriers complete, with 170 matching peer checkpoints;
- 2,321 telemetry records and 943 event records; and
- zero rejected, faulted, or pending consensus lane.

Independent latest-checkpoint reports for player 1 and player 2 both verified
the model replay and agreed exactly on:

| Projection | Digest |
|---|---|
| Model | `cb3ca92b` |
| Canonical registry | `cf684b93` |
| Core | `acc8f17c` |
| Finance | `b3313f79` |
| Native structure | `409bb72b` |

The peer-local checkpoint envelope digests differ as expected because they bind
peer identity; their convergence key and every authoritative projection agree.
This is positive evidence against canonical, financial, town, line, vehicle,
and structural drift over the populated run.

### Vehicle timing distribution

A file-level pairing of both peers' first held and first released reports found
93 complete corresponding rounds and one current incomplete round at that
snapshot:

| Measure | Result |
|---|---:|
| Full hold latency, mean / median | `45.037 s` / `43.198 s` |
| Full hold latency, p95 / maximum | `57.134 s` / `61.547 s` |
| Station-arrival game-time skew, mean / p95 / maximum | `0.2` / `1.0` / `2.8` units |
| Station-arrival wall-time gap, mean / p95 / maximum | `4.939 s` / `11.310 s` / `12.663 s` |
| First 20 / last 20 round mean | `37.048 s` / `56.145 s` |

The small game-time skew is the important synchronization result: train copies
did not progressively separate in simulation time. The increasing wall-time
latency combines one peer reaching the same game-time stop later in real time
with the old build adding its 144-unit guard only after both reports arrive.
Held retries can move the final target another 12-unit step, which explains
observed first-arrival-to-target deltas from 144 through 192. Fresh running
heartbeats are needed so the governor can detect the slower wall-time peer and
step down when appropriate; the corrected short guard then begins only after
the ordinary all-peer arrival condition.

### Economy and passenger conservation

At the epoch-57 checkpoint, the one passenger service had generated 1,533
authored passengers. They conserved exactly as 1,477 alighted + 34 aboard + 22
waiting. It had boarded 1,511 in total, with no discarded passengers. Both
20-seat trains were represented in the authored ledger.

Company 1 had accumulated `$19,998,580.00` gross revenue and `$1,259,179.20`
operating cost, for `$18,739,400.80` authored operating profit. Its canonical
balance was `$63,098,862`, consistent with the `$50m` start, that profit, and
approximately `$5.64m` of capital purchases. Idle Company 2 remained exactly at
`$50,000,000`, demonstrating financial isolation.

The long old-build station guard was already suppressing delivered throughput:
one representative five-minute settlement requested 28 passengers, delivered
20, queued four, and recorded four units of capacity overflow despite 280
nominal line seats per interval. Shortening the guard should therefore improve
both feel and realized economy, not merely animation.

Both canonical towns reached size 207, seven model-growth units above their
starting size. Two authorized native town-development commands occurred on
each process, and the town structural projection remained identical. Industry
production also advanced deterministically, but this run has no freight line,
so it is not cargo-delivery evidence.

### Runtime load and native authority

A simultaneous ten-second process sample measured both game processes at
approximately 73% of one logical CPU each, with 2.4 GiB working sets. GUI frame
counters advanced at approximately 56.9 FPS for player 1 and 48.0 FPS for
player 2. The two games were therefore not showing the earlier persistent 4x
host/client performance split at this sample. Companion processes used about
27% and 35% of one logical CPU; the host retained 141 MiB and the client 23 MiB.

Both exact-build native hooks remained active at version `0.17.0` with no last
error, invalid command layout, unknown tag, pending overwrite, or tag mismatch.
On the origin, 22 BuildProposal calls and six consequential commands were
intentionally suppressed for canonical capture; all corresponding authorized
replays completed on both worlds. Symmetric `SetUserStopped` traffic confirms
that the two station barriers were actuating both train copies rather than only
masking the host.

## Root causes

### Native speed was treated as a tick-frequency index

The companion receives Build 35924's `getGameSpeed()` value, from 0 through 4.
The release fallback incorrectly treated that value as a tick-frequency index
and converted it with `12 * 2^(speed - 1)`, producing 96 game-time units per
wall second at speed 4. In the control, `getGameTime()` advanced at about four
units per wall second at that value; the native value was already on the scale
needed by the release and projection arithmetic.

Consequently, a requested 1.5-second guard became 144 game-time units and took
about 36 wall seconds at speed 4. The corrected guard is 6 game-time units at
that speed.

### Heartbeat cadence had a phase-lock hole

The network pump invoked clock work on one cadence while `emitHealth()` imposed
an independent `tick % 15 == 0` test. If their phases did not intersect, a
running world could emit no health indefinitely. A dedicated heartbeat module
now emits at most once per wall second while running, every two seconds while
paused, and immediately for an explicit rendezvous. The pump remains the sole
engine-update scheduler.

### Stock presentation inspected unrelated construction ghosts

The stock-window adapter recursively collected numeric fields from every native
GUI event before deciding whether the event was relevant. A modular station
preview can contain hundreds of nodes and edges, so moving the ghost caused a
large irrelevant traversal on every event/frame. Irrelevant builder and
proposal-preview events are now rejected before payload traversal.

The remaining stock-presentation refresh paths were also doing more work than
the visible data warranted. Repeated relevant native events are now coalesced,
native window scans are less frequent, public snapshot presentation is sampled
at a three-second cadence, and the large diagnostic panel is constructed lazily
when the Multiplayer HUD entry is opened.

## Implemented correction

- `AdaptiveClockGovernor.nominal_game_rate()` is the shared 0..4 ordinal-to-rate
  contract used by progress checks, projected game time, and station guards.
- Station release guard distance is bounded and uses that actual rate.
- `network_clock_heartbeat.lua` owns wall-time heartbeat coalescing and forced
  rendezvous health.
- GUI stock presentation filters irrelevant events before recursive payload
  inspection and coalesces event storms.
- Selected-entity authoritative presentation refreshes every three seconds;
  idle snapshots and native window scans use longer bounded cadences.
- The hidden full diagnostics window no longer exists until requested.

No vehicle-sync polling stride was weakened. Release/arrival authority still
runs at its required cadence, and no native engine pointer or GUI object was
moved off its owning thread.

## Verification

- Lua suite: 132/132 passed.
- GUI regressions cover relevant-event coalescing and rejection of large,
  irrelevant station preview payloads.
- Runtime regressions cover heartbeat emission on non-divisible ticks,
  same-second coalescing, next-second emission, and public projection cadence.
- Python companion suite: 153/153 passed, including corrected speed-rate and
  release-target arithmetic.
- Full `tools/run_tests.ps1`: passed, including source boundaries, Lua syntax,
  PowerShell syntax, native tests, installer rollback, recovery, cross-language
  economy/freight parity, and the 1,024-event deterministic replay.
- Final replay digest: `c9fe205f`.

## Next live acceptance

The next match must be a fresh build after the control games are closed. Check:

1. the same two-train line releases in roughly transport latency plus the real
   1.5-second guard, rather than about 37.5 seconds;
2. running status obtains non-null, fresh rate/skew telemetry;
3. station-preview camera movement no longer incurs the stock-adapter traversal;
4. opening a train window does not continuously rescale/rebuild the panel; and
5. both peers remain synchronized through a deliberate long Escape pause and a
   subsequent speed-3/4 run.

Native rendering and vehicle interpolation remain engine-owned. Two fully
rendered worlds on one PC can still expose base-game main-thread limits, but the
known mod-authored station-preview, panel-refresh, heartbeat, and release-guard
costs have been removed without relaxing consensus.

## Recovery preparation failure found after the soak

The first automatic restore-point attempt at preparation sequence 389 exposed
a circular wait in the old coordinator. It ordered the shared pause before
checking station rounds. At the acknowledged pause, one round was already
`release-ordered` for a future game-time target with `releaseWhilePaused=false`
and a second was `waiting-arrivals`. Game time could no longer reach either
condition, while readiness correctly refused to checkpoint with two pending
rounds. Both games remained responsive, canonical state stayed unfaulted, and
no save receipt or restore plan was falsely produced.

Preparation now has an explicit `draining` phase. Fresh schema-3 health must
prove that both local intent queues consumed the current tip, and all durable
work must finish before the pause is ordered. If a prior build is replayed in
the pause-first state, or a train reaches a stop during the pause transition,
the host internally resumes at the captured prior speed (speed 1 when the user
was already paused), drains the station rounds, and retries the shared pause.
New player intents remain fenced throughout. Connection races retain the
workflow and retry instead of marking a false failure.

Five focused companion regressions cover drain-before-pause, recovery from an
already-paused scheduled release, a vehicle arrival racing the pause, player
intent fencing, and audit-replay reconstruction of the exact old deadlock.
The complete repository suite passes after extracting the clock/drain proof
into `anchor_prepare_drain.py` to retain the source-size boundary.

This retry design is deadlock-free for the current sparse fleet but does not
claim a bounded-time pause for an arbitrarily dense fleet whose station rounds
never have a global empty interval. A future explicit game-side quiesce
attestation can turn that liveness assumption into a hard bound; READY remains
fail-closed until then.
