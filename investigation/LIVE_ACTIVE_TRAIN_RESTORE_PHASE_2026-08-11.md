# Live active-train restore phase, 2026-08-11

## Question

Can two independent Transport Fever 2 processes save a running passenger
train at one receipt-bound boundary, restart from their peer-specific native
saves, and continue at the next all-peer station round without guessing native
entity IDs or coordinates?

## Defects found before acceptance

The first phase-bound plan carried the two matching native route-phase digests
but not the companion's last authorized station round. The native save resumed
with `lastAuthorizedRound=1`; the fresh host reset its cursor to zero and
correctly rejected the first post-restart report (`round=2`) as a gap. Plan v5
is therefore retired rather than accepted with a guessed cursor.

A separate launcher race let a running save advance while the loader waited
for slower game-script and authority diagnostics. Two copies of the same save
could consequently start on opposite sides of their next stop. Session
`phase-anchor-v6-20260811-2140` demonstrated the safe failure: player 1 held at
stop 0 while player 2 next held at stop 1, producing
`vehicle-sync-stop-mismatch`. No save was admitted and all disposable
processes were cleaned up.

The loader now presses the exact-process hard pause at the first native-world
boundary, then waits for game-script observers and command gates while that
world remains frozen. The passing rerun reached stop 0 on both peers at game
times 58.4 and 60.0 before one host release.

## Current binding

Current restore-plan version 6 adds a strict `vehicleRounds` array to the
signed `vehiclePhaseProof`. Each sorted item contains only:

- canonical `vehicleCid`;
- canonical `lineCid`;
- `lastAuthorizedRound` in the supported station-round range.

The array is derived from the same two consecutive, paused, all-peer mobility
samples that establish route-phase stability. Missing, malformed, duplicate,
unsorted, or peer-different cursors fail preparation. The plan checksum and
both save receipts bind this proof. During restart the verified plan seeds the
empty host station barrier before the restore fence can open. Exact native
coordinates remain non-authoritative; the next all-peer station barrier is the
physical reconvergence point.

## Live capture

Session `phase-anchor-v6-earlyfreeze-20260811` loaded the populated railway save
into two exact Build 35924 processes. The existing train
`vehicle:pre:e8c0305d` on `line:pre:2820313f` completed synchronized round 1 at
stop 0. Two consecutive paused route-phase samples agreed, including
`lastAuthorizedRound=1`.

Automatic preparation then created boundary 15, both stock-UI native saves,
both ordered receipts, both peer-local recovery archives, and current plan
checksum `7da2035d`. The host audit finished with 15 converged commits, one
completed station round, four matching station reports, one completed
checkpoint barrier, and no synchronization fault.

Capture evidence:

`runtime/localhost-live/phase-anchor-v6-earlyfreeze-20260811--phase-bound-capture`

## Live restore and next round

`run_latest_local_restore_acceptance.ps1 -RequireVehicleSyncRound` discovered
only the complete same-plan pair, re-hashed each peer's `.sav` and `.sav.lua`,
and launched resume session `phase-anchor-v6-earlyfreeze-20260811-r15`.

Both worlds accepted `recovery.resume` and converged the mandatory fresh
checkpoint at sequencer boundary 1. Before gameplay resumed, host status
reported one tracked vehicle seeded at round 1. Both native trains then held at
stop 1 (game times 209.0 and 210.6), the host ordered round 2, and both reported
release at game time 212.2. Final status was:

- `restoreStatus=complete`;
- station releases `0 -> 1` after restart;
- `lastRelease.round=2`, `lastRelease.stopIndex=1`;
- four station reports, one pruned completed round, zero barrier faults;
- no session fault and no pending station round.

Restore evidence:

`runtime/localhost-live/phase-anchor-v6-earlyfreeze-20260811-r15--restore-acceptance-20260811-214713-attempt-01`

Compact acceptance receipt:

`runtime/restore-acceptance/20260811-214713.json`

The wrapper closed both games, both companions, and the recovery watcher after
verification.

## Automated verification

The post-change complete gate passes 132 Lua tests, 172 Python tests, 108
cross-language economy scenarios, freight parity and randomized stress,
PowerShell/Lua syntax, source boundaries, release provenance/install rollback,
recovery publication/discovery, the 1,024-event replay, and both native CTest
targets. Focused tests additionally prove strict cursor schema rejection and a
restored host accepting round 2 after seeding round 1.

## Honest boundary

This proves one active railway vehicle across automatic localhost capture,
paired native save/reload, mandatory checkpoint, and its next station round.
It does not prove exact-coordinate equality, multiple simultaneous trains,
positive freight ledgers, town-development commands during the boundary, a
disconnect during restore, or the role-local workflow on two physical
computers. Those remain separate stress/acceptance gates.
