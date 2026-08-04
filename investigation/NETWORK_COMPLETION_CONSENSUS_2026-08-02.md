# Network proposal identity and completion consensus — 2026-08-02

## Result

Prototype `0.16` / state schema `13` implements and live-proves the physical and checkpoint phases for the canonical road/track transaction. A host commit does not count as physically complete merely because both game scripts queued it, and a physical success does not permit later work until schema-3 quoted-cost finance is committed to canonical accounts, native wallet caches are reconciled, and both peers sign the same recovery boundary.

For every `proposal.build` commit:

1. The host pins the expected roster (`player1`, `player2`) and refuses a physical commit while a required remote peer is absent.
2. Each game realizes the proposal locally.
3. Each game emits a `completion` record containing only the canonical proposal ID, commit sequence, proposal digest, canonical output IDs/slots, physical/core digest, and the transaction's canonical cost. Native entity IDs and native player IDs are excluded.
4. The host blocks later network intents until both required peers report.
5. Matching success reports produce a globally ordered `network.proposal_outcome` control consumed by both games.
6. Native rejection, an output/core mismatch, a conflicting duplicate, or the 45-second timeout produces a fault outcome and permanently closes the session to later intents. Finance is applied from the proposal's builder quote before the checkpoint rather than requiring engine-local debit timing to match.
7. Match initialization and each physical success open a format-2 checkpoint barrier covering model, canonical registry, structural digest, and canonical company balances/loans.
8. Only an ordered `network.checkpoint_outcome` success reopens the intent stream. Mismatch or timeout faults closed.

The audit replayer validates the commit/control sequence and independently requires the completion evidence behind every successful outcome.

## Peer-local identity correction

Canonical company number and native player number are different namespaces. On player 2's machine, the original native player is mapped to canonical Company 2; a newly added local native player represents Company 1. Therefore a replay of Company 1's build has two distinct identities:

- `issuerPlayerId`: the current local player through which this machine issues and observes the native command;
- `nativeOwnerPlayerId`: the local native player placed in `SegmentAndEntity.playerOwned` and required by the ownership postcondition.

The previous record used one `controlPlayerId` for both jobs. On player 2 that would materialize a remote Company 1 edge under Company 2. State schema 10 introduced the migration, retained `controlPlayerId` only as a compatibility alias for the issuer, and used the two explicit fields everywhere consequential. State schema 11 preserves it and adds persisted checkpoint-barrier state.

Finance follows the same identity separation but cannot require the same raw native effect. The live two-process run proved that Build 35924 may debit only the machine where the canonical owner is also the local command issuer. Each game samples the settled engine-thread delta; the completion physical digest excludes that local timing/effect; the host selects the proposal origin's delta; and `network.proposal_outcome` books the difference between that authoritative delta and each peer's local delta into the canonical company wallet. The following financial checkpoint must then match.

## Automated evidence

`tests/run_network_company_mapping_tests.lua` simulates the player-2 engine state and applies two ordered private-track commits:

- player 2 / Company 2: issuer `100`, native owner `100`;
- remote player 1 / Company 1: issuer `100`, native owner `101`.

Both proposals bind one edge and two nodes, emit local-ID-free completion records, consume ordered host outcomes and matching checkpoint outcomes, and finish with two successful physical records, three successful checkpoint barriers, and no session fault. The remote physical edge remains owned by local native player `101`.

Python integration tests exercise dependency blocking, the required connected roster, matching success, physical/financial checkpoint mismatch, timeout, permanent fail-closed behavior, audit replay, and checksummed restart-plan verification. A full localhost route uses two real `GameBridge` directory trees, a TCP `CommitHost`, a TCP `CommitClient`, two completion files, two format-2 checkpoint files, and both ordered outcomes delivered to both inboxes.

The full offline suite currently reports 16 Lua core tests and 23 Python tests. Standalone run `runtime/live-validation/20260802-075533` passed 39/39 and independently verified 14 post-checkpoint records plus financial digest `fde11e45`. Two-process run `runtime/localhost-live/localhost-20260802-144832` passed the physical result and both all-peer checkpoint barriers under state schema 12. Post-hardening run `runtime/supported-api-probe/20260802-075034` separately proves the 23-tag native fail-closed gate required by network startup.

## Boundary

This consensus is now bidirectionally live-proven. `runtime/localhost-live/localhost-20260802-175636` ran two real exact Build 35924 processes through match initialization, one host-origin and one client-origin canonical track proposal, matching physical outcomes, two schema-3 25,000 canonical charges, three checkpoints, a 600-tick finance/structure soak, and final mobility agreement. It completed with two physical successes, three checkpoint successes, and zero faults. The next decisive experiment is the same slice between two computers from a byte-identical save through each human vanilla builder path.

There is deliberately no automatic continuation after a fault. The audit now generates a checksummed coordinated-restart plan for the last agreed checkpoint, but native-save capture/reload and physical binding reconstruction have not been automated. A failed consensus therefore still requires both peers to load an identical saved boundary rather than patching divergent live geometry. Broader stations, constructions, signals/edge objects, lines, and vehicles also remain outside the canonical replay slice.
