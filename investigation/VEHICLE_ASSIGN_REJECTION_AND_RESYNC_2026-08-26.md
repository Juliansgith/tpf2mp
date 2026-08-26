# Vehicle assignment rejection and in-place resync

Date: 2026-08-26  
Observed release: `0.41.1-alpha`, state schema `32`.  
Implementation state: schema `33`.

## Incident

Relay session `mp-fe1ea5e41d54b1d1` remained physically aligned while the
authority layer faulted. The player created a line, bought four trains, and
assigned all four in one vanilla UI burst. All four purchases completed on
both peers. The first ordered `vehicle.assign` (`...:player1:163`) was then
rejected by `SetVehicleLine` on both games with the same native error and the
same authored-core/result evidence. The vehicles stayed in the depot and
unassigned. The following three captures entered the bounded deferred FIFO.

The old operation-consensus policy treated every failed native operation as
`peer-native-operation-failed`. That was too broad: this result was an
identical no-op rejection, not evidence that the worlds had diverged. The
fault latch then correctly blocked all later work, making an intact world look
unrecoverable.

## Prevention

`vehicle.assign` now captures a native before-state immediately before issuing
the command and an after-state when the command reports failure. The witness
contains the canonical vehicle and its line, stop index, user-stopped flag, and
sell-on-arrival flag. A rejection remains healthy only if:

- every required peer accepted the ordered operation into the same authored
  core;
- every required peer reports failure, the same native error, and the same
  physical result;
- no peer reports outputs or a finance mutation;
- every peer's before/after witness is byte-for-byte equivalent through the
  signed completion result; and
- the completion core equals the all-peer ordered acknowledgement core.

The host then records `network.operation_outcome` with
`success=false`, `recoverable=true`, and `native-operation-rejected`. Both Lua
runtimes independently verify their own witness. The operation increments the
new `rejected` count and opens a normal all-peer checkpoint before the deferred
FIFO continues. Mixed results, changed native state, missing witnesses,
different cores/errors, failed queue acknowledgements, output residue, and
finance residue still fault the session.

This means a four-train click burst serializes as four independently proven
operations. A train whose path is not yet natively usable may remain
unassigned, but that click no longer destroys the match and the next queued
assignment is still evaluated.

## Recover / Resync Session

The existing `Recover / Resync Session` control now handles this operation
class as well as late proposal timeouts. It is deliberately not a blind
state-copy button.

For an already faulted assignment, the host will expose `READY` only when the
fault is one supported `vehicle.assign` rejection, both peers supplied the
same empty failed completion, all ordered acknowledgements succeeded at the
same core, no later non-clock work exists, and both games freshly attest that
they are paused, have empty queues, have no pending consensus work or origin
residue, and still bind the vehicle to the authored line. The recovery action
is ordered, both games re-evaluate it, and a fresh structural/core/world-
manifest checkpoint must converge before the exact fault changes from
`faulted` to `rejected`. The session stays paused after recovery so the player
chooses when to resume.

If any condition is ambiguous, the panel continues to say restore required.
General divergent-world repair still uses the verified paired-save restore
path; silently choosing one peer as authoritative would risk duplicating or
deleting native entities.

## Automated proof

- Host integration proves an identical unchanged rejection checkpoints rather
  than faults, while missing or changed witnesses fail closed.
- A four-assignment burst proves all four outcomes and all four checkpoints
  serialize without FIFO loss or livelock.
- Recovery integration reconstructs a legacy `peer-native-operation-failed`,
  requalifies it, converges a new checkpoint, and leaves no live audit fault.
- Lua runtime tests cover before/after projection, changed-line refusal,
  recoverable consensus consumption, and legacy in-place recovery.
- Cross-language audit/replay reports operation complete/rejected/faulted/
  pending separately and verifies the recovery chain.

## Live check

Use a fresh build containing state schema 33. Buy four vehicles in one depot,
select all four, and assign them to a line once. If native pathing rejects a
vehicle, the panel should increment operation `rejected`, remain healthy, and
continue draining the captures. Correct the route and assign the still-
unassigned vehicles again. Separately, a deliberately faulted supported
assignment should show `READY` only after both games are safely paused; press
`Recover / Resync Session`, wait for `RECOVERED - safely paused`, then resume.
