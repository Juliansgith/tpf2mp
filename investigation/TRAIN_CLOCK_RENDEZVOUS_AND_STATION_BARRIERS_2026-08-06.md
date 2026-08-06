# Shared-clock rendezvous and canonical train station barriers

Date: 2026-08-06 (Europe/Amsterdam)

Implementation at live proof: prototype `0.21.2`, state schema `21`, checkpoint format `3`

Superseding hardening: prototype `0.22.0-alpha`, state schema `22` integrates
the demand departure schedule, normalizes barrier-managed lifecycle state,
and adds load telemetry/pruning. See
`STATION_SCHEDULE_INTEGRATION_AND_BARRIER_LOAD_2026-08-06.md`. The live receipt
below remains evidence for the earlier unscheduled barrier and is not silently
relabelled as proof of the new scheduled path.

Live status: railway purchase, assignment, peer visibility, and movement are
human-observed on two Build 35924 processes. Session
`train-station-fresh-clock-20260806-0630` additionally proves shared-clock v2
and four complete station barriers in a populated two-process localhost run.

## Triggering observation

The stock UI successfully bought a train on Player 1, replicated it into the
Player 2 depot, assigned it to the canonical line, and showed it moving in both
worlds. The Player 2 rendering was already slightly ahead. Pressing Escape on
Player 1 then paused that native world immediately enough for Player 2 to move
substantially farther ahead before it received the shared pause.

That is not merely cosmetic. Different arrival times alter loading, revenue,
platform occupation, and later player choices. There is no established safe
Build 35924 command for writing a vehicle's exact position, so metre-by-metre
teleport lockstep is not an honest design target.

The implemented invariant is instead:

> Both games approach host-chosen simulation-time barriers under one shared
> speed policy, and every canonical assigned train is held at each station
> until both native copies report the same vehicle, line, stop, and leg round.

Mid-leg rendering may differ briefly. Every completed station round re-anchors
the service before either copy may start its next leg.

## The six clock safeguards

1. **Host-owned speed:** vanilla Pause and speeds 1-4 remain suppressed by the
   exact tag-0 gate and become ordered requests. Each applied speed has a
   strictly increasing generation.
2. **Future-time barriers:** a change while running becomes
   `clock.rendezvous`, not an immediate local pause. The host projects fresh
   peer heartbeats to one host-monotonic instant, chooses a target far enough
   ahead for delivery, and both games pause only when their own game time
   reaches it.
3. **Catch-up before release:** both peers report the target and their actual
   stopped time. An overshoot mismatch starts a speed-1 correction round; the
   leading peer immediately re-pauses while the lagging peer advances. Three
   unsuccessful corrections or an excessive span fault closed.
4. **Slowest-peer governor:** heartbeat age, ordered-command backlog, observed
   native speed, engine rate, and absolute projected game-time skew feed the
   adaptive cap. Severe loss pauses; healthy recovery raises effective speed
   one step at a time. Raw heartbeat times are never compared as if staggered
   network packets were simultaneous.
5. **Physical-operation pause:** canonical line and vehicle actions request a
   shared pause first, including optimistic origin-applied captures. The local
   check considers both authoritative and actually observed native speed. The
   existing FIFO retains the action until the clock barrier clears, so the peer
   replay occurs at a stopped boundary.
6. **Durable fail-closed control:** command rejection, timeout, unknown rounds,
   different stop indices, premature departure, or a missing local canonical
   mapping emits an ordered `network.sync_fault` and an emergency shared pause.
   Audit restoration finishes an all-reached clock barrier, emits an all-held
   vehicle release that was interrupted before commit, and preserves negative
   clock/vehicle acknowledgements rather than silently reopening play.

Paused worlds now emit a wall-clock-throttled health heartbeat through the GUI
snapshot wake path. This fixes the previous trap where a world paused for more
than six seconds had no fresh time sample and therefore could not safely
resume.

## Canonical station-leg protocol

`vehicle_sync_runtime.lua` manages every canonical railway vehicle whose
binding has an assigned canonical `lineCid`.

1. It reads the supported `TRANSPORT_VEHICLE` component. State `2` is the
   established at-terminal state; `stopIndex` identifies the line stop.
2. On the first new terminal arrival it one-shot-authorizes native command tag
   8 and applies `setUserStopped(vehicle, true)`.
3. Only a successful native hold emits a `vehicle_sync` report with
   canonical vehicle/line identity, sequential round, stop index, game time,
   and engine tick.
4. The host waits for the complete fixed peer roster. Vehicle, line, round, and
   stop must match exactly.
5. While running, the host chooses a release time beyond both arrival reports
   and the freshly projected current clocks. While globally paused it marks the
   release as pause-safe. It then orders one `vehicle.sync_release` commit.
6. Each game persists that authorized round in `world.vehicleSync`, waits until
   its local clock reaches the release time, and applies
   `setUserStopped(vehicle, false)`. A deliberate user stop is retained.
7. Both peers report release. The next observed departure arms the following
   station round.

The live-proven build used report schema 1. State schema 22 emits report schema
2 with an explicit departure policy and host-reserved slot; its live gate is
still owed. Retries may update diagnostic time/tick fields but cannot change canonical
vehicle, line, round, stop, or state. A repeated held/released report cannot
emit or count a second release. A release order is sequential and idempotent.

## Persistence and convergence

State schema 21 adds the authoritative per-vehicle release table and persisted
peer-local release-report receipts. Checkpoint format 3 adds a strict
`vehicleSynchronization` projection and digest to the core and convergence
key. Machine-local vehicle IDs, transient phases, native coordinates, and
diagnostic ticks remain excluded.

The projection records:

- canonical vehicle, line, and optional company;
- last authorized station round;
- canonical stop index;
- ordered release game time;
- whether release was valid while the global clock was paused.

Checkpoint formats 1 and 2 remain readable for old evidence and recovery
archives. New network consensus requires format 3 so it cannot accidentally
approve a boundary that omitted train-release state.

## Automated evidence

`tools/run_tests.ps1` passes after this change. New adversarial coverage
includes:

- future pause without early local stopping;
- target overshoot and catch-up correction;
- sub-tolerance paused skew (the former unreachable-target deadlock);
- staggered heartbeat projection versus genuine absolute skew;
- authoritative-pause/native-running mismatch correction;
- paused heartbeat throttling;
- line/vehicle pause prerequisites, including optimistic captures;
- first/next terminal rounds, delayed release, and premature departure;
- both-peer station readiness and idempotent held/released retries;
- stop mismatch and native release rejection faults;
- host restart between both arrivals and release commit;
- host restart after negative clock or vehicle acknowledgement;
- strict protocol and checkpoint-format-3 validation.

The implementation also corrected defects found by these tests: an armed
release could previously be consumed without executing, a fresh fault could
inherit the retry delay of its last held report, a paused sub-tolerance offset
could wait forever, and a single negative clock acknowledgement waited for the
other peer before pausing.

## Populated live evidence

The unattended acceptance session
`runtime/localhost-live/train-station-fresh-clock-20260806-0630` loaded the same
byte-pinned populated save in two exact Build 35924 processes. The save already
contained one canonical line and a real three-part NOHAB + two-BC4 train.

The loader first paused each restored native world and froze its calendar. It
then waited for validated native authority on both Lua states, both paused
clock heartbeats, match initialization, and checkpoint consensus before the
host resumed speed 2. This matters: an earlier negative run let the first
process advance while the second loaded and correctly faulted when the two
copies reached different stops. The accepted run removes that load-order race
instead of concealing it.

The real train completed four host-ordered releases:

- round 1, stop 1, release game time `1097.2`;
- round 2, stop 0, release game time `1146.6221294362097`;
- round 3, stop 1, release game time `1195.0`;
- round 4, stop 0, release game time `1241.2`, safely completed while the
  shared clock was paused.

Host status ended with one tracked vehicle, four releases, zero pending
rounds, zero vehicle faults, no session fault, and final clock skew `0`. Both
ordered mobility samples converged in full, lifecycle, and route phase. The
worlds finished at identical core `1fea40f9`, model `98f01295`, structure
`e1488bff`, and mobility `6fca8ed2`. Audit replay reports 15 commits, 5 controls,
15 convergence outcomes, 2/0/0 physical proposals, 3/0/0 checkpoint barriers,
and no unresolved peer digests. The harness restored shared settings, removed
all temporary load/injection files, and terminated only its two games and two
companions.

## Explicit limits

- This does not write native coordinates or force identical animation frames.
- A train first becomes re-anchored when both copies reach the same next
  terminal. If they report different stops, the session faults instead of
  guessing which world is right.
- Returning a divergent train to its depot and relaunching it automatically is
  still unavailable because the full send-to-depot/unassign lifecycle is not
  yet a proven canonical command family.
- Native passenger/cargo agents and per-vehicle loads remain independently
  simulated. The station barrier bounds when the next leg begins; it does not
  make native agent allocation authoritative.
- A disconnected peer's local train should hold at its next station, but the
  long-disconnect/reconnect behavior still needs live proof.
- Localhost automated operation is live-proven; human two-computer latency,
  deliberate slow-peer recovery, and long disconnect/reconnect remain open.

## Remaining live acceptance

The automated populated localhost gate above is now required regression
coverage. The next human test should use two physical computers and exercise
the interaction paths automation cannot judge:

1. Leave both worlds paused. On Player 1 build two stations, track, and depot;
   create a two-stop line; buy one train; assign it through the stock UI.
2. Confirm one canonical train exists on both peers and the overlay says
   `Train station sync: managed 1` on each.
3. Request Speed 1 from Player 1. Let the train complete at least four station
   arrivals. Host `releases` must increment, `pending` must return to zero after
   each round, and all fault counters must remain zero.
4. While it is mid-leg, press Escape on Player 1. Confirm both games enter a
   clock rendezvous and stop at nearly the same game time. Leave them paused
   for at least fifteen seconds, then resume from Player 2; this specifically
   proves the paused-heartbeat repair.
5. Repeat one pause/resume at speed 3 and watch the next two station releases.
   Brief mid-leg visual separation is acceptable; different stop indices,
   premature departure, duplicate trains, or a nonzero fault count are not.
6. Export research, snapshots, and checkpoints on both peers, then collect the
   host audit and native statuses before closing the lab.
