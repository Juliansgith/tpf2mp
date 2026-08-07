# Station schedule integration and barrier-load audit

Date: 2026-08-06 (Europe/Amsterdam)

Implementation: prototype `0.22.0-alpha`, state schema `22`, checkpoint format `3`

Superseded for physical train control on 2026-08-07. A registered one-train
service exposed a 364.2-game-second post-arrival hold and then hit the active
round timeout. The slot codec remains supported for archived evidence, but new
physical station rounds use prompt all-peer release. See
[PROMPT_STATION_RELEASE_POLICY_2026-08-07.md](PROMPT_STATION_RELEASE_POLICY_2026-08-07.md).

## Review verdict

The four review findings were correct. The first two were architectural bugs,
the third was an unmeasured scaling risk, and the fourth strengthens the
agents-off case without making that overhaul a prerequisite for this repair.

1. Native `TRANSPORT_VEHICLE.userStopped` cannot be lifecycle authority while
   a peer-local station hold deliberately changes it before the other peer
   arrives. The lifecycle view now digests the canonical manual-stop request
   in vehicle binding metadata. The native actuator bit remains visible in a
   non-digested diagnostic projection together with `barrierManaged`.
2. There is now one authored departure policy. `departureSchedule` derives a
   registered service's period and deterministic per-stop phase;
   `departureSlots` is its pure query view; the station barrier reports that
   policy and the host reserves the concrete slot that both native trains must
   obey. An ordinary line has no authored timetable and reports an explicit
   disabled policy, so it receives only the barrier's short network guard.
3. A station round does not open physical proposal or checkpoint consensus,
   but it is still linear network work: two arrival reports, one ordered
   release, ordinary commit acknowledgements, and two release reports. That
   cost is now explicit and measurable.
4. Agents-off would make the native agent allocation mismatch less important
   and make these station anchors more central. It remains a separate overhaul;
   this slice neither claims native loads are authoritative nor waits for that
   pivot to fix the current lifecycle and scheduler defects.

## Schedule and release contract

The barrier has two explicit modes. A registered, enabled demand service
supplies its authored headway, journey, and stop count. Its schema-2
`vehicle_sync` report contains an enabled schema-1 policy—period and phase,
but no peer-chosen slot. An ordinary line that has not been registered to the
competitive model reports `{ schemaVersion = 1, enabled = false }`. Both peers
must report the identical enabled or disabled policy for the same canonical
vehicle/round/stop or the session faults before a release can be committed.

After both holds arrive, an enabled policy makes the host choose the first
strictly future slot beyond the safe clock baseline and the previous
reservation for that line and stop. The ordered `vehicle.sync_release` adds the
slot index and exact scheduled game time. Scheduled releases are never marked
`releaseWhilePaused`; a user pause therefore keeps the train held until shared
simulation time reaches its slot after resume. With a disabled policy, the host
orders release at the projected all-peer clock plus its bounded network guard;
there is no slot reservation or invented headway. A later successful
`line.register` naturally enables the demand model's schedule at the next
station round.

The reservation is persisted in `world.vehicleSync.scheduleReservations` and
included in checkpoint convergence. State schema 22 and vehicle-sync state
schema 2 make this new digest surface explicit. Checkpoint format remains 3:
the verifier accepts both its historical vehicle-sync schema 1 and the new
schema 2, so archived evidence remains readable. Old schema-1 audit reports and
release actions also normalize to an explicit disabled schedule during replay.

All schedule integers are bounded below the largest exactly representable
binary64 integer. Lua and Python both verify `phase + slot * period` exactly;
malformed, inconsistent, pause-safe, or overflowed scheduled releases fail
closed.

## Lifecycle convergence

The native `userStopped` bit moved out of the digested lifecycle record. The
replacement `requestedStopped` value is the ordered `vehicle.stop` intent
already stored in canonical metadata. Lifecycle schema is now 2 and the full
mobility projection is schema 4. Stop index remains in route-phase authority,
so peers reaching different stations are still detectable.

This removes the accidental constraint that lifecycle comparison must remain
warning-only. Promoting persistent lifecycle divergence to a fault is now
architecturally possible, although this change does not itself alter that
policy.

## Load, retention, and observability

Completed vehicle-round trackers are removed immediately. Recovery remains
possible from the ordered release commit, per-vehicle last-round cursor, and
audit log. Host status now exposes:

- reports, pending and peak-pending rounds;
- completed/pruned rounds;
- scheduled versus unscheduled releases;
- active line-stop reservations;
- average and maximum wall-clock round latency.

The automated burst test submits 50 distinct trains at one line/stop before
allowing the second peer to arrive. It observes 50 pending rounds, 50 unique
monotonically increasing slots, 50 completed releases, one retained line-stop
reservation, zero remaining round trackers, and no session fault. This is an
in-process authority/load invariant, not a claim about real LAN throughput.

## Refactoring boundary

The implementation did not raise the repository's source-size budgets.
`vehicle_barrier.py` now owns host-side station rounds, slot reservation,
faulting, pruning, and telemetry. `synchronization.py` remains the shared-clock
coordinator. On the game side, `vehicle_sync_state.lua` owns strict schedule
normalization and the convergence projection, while
`vehicle_sync_runtime.lua` owns native hold/release execution.

## Evidence and remaining gate

Automated coverage includes lifecycle insensitivity to barrier-managed native
holds, schedule policy/slot parity, scheduled release timing while paused,
checkpoint schema-1 compatibility and schema-2 binding, malformed schedule
rejection, peer policy mismatch, restart behavior, and the 50-train burst.

Populated live evidence is
`runtime/localhost-live/train-scheduled-state22-20260806-1010`. Two exact
Build 35924 processes loaded the same populated save and ran its real NOHAB plus
two-BC4 train through the new scheduled path. The run records:

- identical final core `7324c7c3`, model `98f01295`, structure `2ec4851b`, and
  mobility `8e8590e7` digests;
- two completed and immediately pruned rounds, three scheduled release commits,
  zero unscheduled releases, zero faults, and a peak of one pending round;
- one later `release-ordered` round intentionally left pending when the final
  shared pause froze simulation time before its slot;
- two active line-stop reservations, 10 arrival reports, 14.57 seconds average
  and 22.08 seconds maximum wall-clock round latency;
- 22/22 audit commits/convergences, 2/0/0 physical proposals, 3/0/0 checkpoint
  barriers, and no unresolved digest comparison.

The final mobility samples also prove why lifecycle normalization matters: both
peers converged while native `userStopped` was true under barrier control and
canonical `requestedStopped` remained false.

### Human pause and slow-peer result

`runtime/localhost-live/ownership-human-state22-20260806-103252` reloaded the
same populated save after the native ownership-projection repair. The human
check confirmed that Company 1's stations, depot, line, and train were again
owned and visible in the stock managers. At speed 3, Player 2 was then delayed
substantially; Player 1 reached the station first, waited, and both copies
departed together after Player 2 arrived. Final host status recorded 39
completed scheduled rounds, zero faults, and a peak of one pending round. Its
evidence bundle has a valid 136-commit audit with no unresolved peer digest.

That run also exposed a gameplay defect: the old unregistered-line fallback
invented a 60-second headway and a 30-second terminal offset. The real shuttle
arrived near 45 seconds later, repeatedly missed the synthetic phase, and was
held for roughly another 44 simulation seconds. Average full-round latency was
13.03 seconds of wall time and the maximum was 33.63 seconds. This was schedule
wait, not peer-rendezvous cost.

### Prompt ordinary-line result

`runtime/localhost-live/train-prompt-barrier-state22-20260806-105918` proves
the corrected ordinary path in two exact Build 35924 processes. Its real
three-part train completed four rounds with zero scheduled and four unscheduled
release commits, zero pending rounds, zero faults, and a peak of one pending
round. Average full-round latency fell to 1.86 seconds and the maximum to 2.38
seconds. Both peers finished at core `fba1630d`, model `98f01295`, structure
`15189409`, and mobility `8e5d90e6`. The independent audit verifies 15/15
commit convergences, 2/0/0 physical proposals, and 3/0/0 checkpoint barriers.

Still owed live:

1. latency, signaling behavior, and peak-pending telemetry from a real
   multi-train service;
2. a human line registered to an actual competitive market using its authored
   schedule rather than the historical fallback proof;
3. two-computer latency and disconnect/reconnect behavior;
4. the agents-off decision and, if adopted, replacement of independent native
   passenger/cargo presentation with canonical demand allocation.
