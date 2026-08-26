# Physical proposal / vehicle-release serialization — 2026-08-26

## Live finding

Relay session `mp-fd4866ceb405d303` faulted at approximately 14:37:50
Europe/Amsterdam with `physical-result-digest-mismatch`. Transport remained
paired, neither companion reconnected, and both native proposals reported
success. The fault was therefore inside authored ordering rather than the TLS
relay or native proposal replay.

Player 1's commit 274 replaced one `standard/town_medium_new.lua` edge with
four road edges and two nodes for $9,499. While its native result was settling,
the host ordered train `vehicle.sync_release` commit 275.

The two native update loops observed those actions in opposite completion
orders:

- Player 1 applied the vehicle release before `proposal.finalise`; its final
  core digest was `d0665665`.
- Player 2 finalized the proposal first at `6e2456dc`, then applied the same
  vehicle release and reached `d0665665`.

The authored states therefore converged after both ordered actions, but each
proposal completion included a whole-core snapshot taken at a different
intermediate point. Consensus correctly rejected the unequal completion views,
but the inequality was a serialization race rather than unequal road output.

## Correctness rule

A core-mutating host control may not cross an unresolved physical proposal,
operation, or its checkpoint boundary. Proposal completions and the checkpoint
that authenticates them must observe one serial authored-state position on
every peer.

Clock pause/rendezvous controls remain available during a long physical
operation because safety and disconnect fencing must not wait. Station releases
are the affected host-generated core mutation: they advance synchronized
vehicle rounds and may also update passenger, cargo, and economy presentation.

## Implementation

`VehicleStationBarrier` now keeps a ready departure in `waiting-authority`
while any of the following is true:

- proposal preparation is awaiting peer acknowledgement;
- a physical proposal or operation is awaiting completions;
- the resulting checkpoint is awaiting peer convergence;
- reconnect replay is active; or
- the session is faulted.

The ordinary host maintenance pass retries the ready release. Once the complete
physical outcome and checkpoint outcome are durably ordered, the release gets
the next sequence number and is applied after that boundary on both games.
Restart replay uses the same gate because restored ready rounds pass through
the same flush path.

## Automated proof

The regression constructs the live ordering directly:

1. commit a Player 1 proposal prepare/build;
2. report the same train held on both peers;
3. prove no `vehicle.sync_release` is ordered while the proposal is pending;
4. submit matching physical completions;
5. prove the release remains held while the proposal checkpoint is pending;
6. submit matching checkpoints; and
7. prove the release is the next commit and the session remains healthy.

Validation after the change:

- exact serialization regression: passed;
- all 51 `NetworkIntegrationTests`: passed;
- complete 202-test Python suite: passed;
- source-size and architecture-boundary checks: passed.

## Live retest

Use a fresh release/session with at least one running train. Place or edit a
road while that train is reaching a station. The expected sequence is physical
proposal outcome, checkpoint outcome, then vehicle release. A train may remain
held for the extra consensus round, but the session must not fault and both
peers must retain matching road geometry and passenger state.
