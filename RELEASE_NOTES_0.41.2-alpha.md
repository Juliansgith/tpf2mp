# TPF2MP 0.41.2-alpha

This release prevents an identical native vehicle-assignment rejection from
discarding an otherwise healthy match and extends the existing in-place
recovery control to that narrowly proven fault class. State advances to schema
33; checkpoint format 5, operation format 4, economy model 10, and native hook
0.19.0 remain unchanged.

## Vehicle assignment bursts

- `vehicle.assign` now records a native before/after witness covering the
  canonical vehicle, assigned line, stop index, user stop, and sell-on-arrival
  state.
- When every peer rejects the assignment identically and proves that nothing
  changed, the ordered outcome is an auditable rejection rather than a session
  fault. A normal all-peer checkpoint completes before queued work continues.
- Selecting and assigning several trains together is serialized without losing
  later captures or livelocking the deferred FIFO. A train that native pathing
  cannot assign remains in the depot and can be retried after its route is
  corrected.

## Recover / Resync Session

- The existing control can now requalify a supported legacy assignment fault
  after both peers are paused and quiescent, report the same empty native
  failure, retain the authored vehicle binding, and converge a fresh
  structural/core/world-manifest checkpoint.
- This is not general state copying. Mixed results, native mutation, finance or
  output residue, failed queue acknowledgements, missing proof, later gameplay
  work, and any additional fault still require the verified paired-save restore
  workflow.
- Audit replay, live evidence, snapshots, and the Multiplayer panel now report
  operation completed/rejected/faulted/pending counts separately.

Both players must install `0.41.2-alpha` and create a fresh session. Running
games cannot hot-load this state/runtime change, and mixed versions remain
unsupported.
