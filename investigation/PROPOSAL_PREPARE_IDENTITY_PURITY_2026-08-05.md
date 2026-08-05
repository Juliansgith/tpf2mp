# Proposal prepare identity purity — 2026-08-05

## Outcome

Point-to-point track construction between two newly synchronized stations now
passes the no-mutation prepare barrier, physical consensus, canonical finance,
and the dependent checkpoint. The failure was not track materialisation: local
GUI normalization inserted/enriched canonical node bindings on the origin
before the host ordered PREPARE. The resolver is now read-only; missing
pre-existing identities are bound identically on every peer only after the
ordered build commit.

## Failed live evidence

In session `vehicle-buy-repeatfix18-20260805-134013`, Player 1 attempted one
nine-edge/eight-node track costing 417,954 between station-throat identities
`node:pre:f9770bd5` and `node:pre:052b0c0c`. The previous checkpoint had core
`84dbc2fe` on both peers. The prepare acknowledgements then reported:

- Player 1: `eec1f390`;
- Player 2: `84dbc2fe`.

The host emitted `proposal-prepare-core-digest-mismatch`. This was a correct
safe rejection: no `proposal.build` was committed and neither native world was
changed. The network session itself remained unfaulted because PREPARE is a
no-mutation phase.

The canonical discontinuity was already real, however. On the origin,
`proposalResolveCanonical` called the mutating `world.bindExisting` for the
previously unbound `f9770bd5` node and added `metadata.owner` to the already
bound `052b0c0c` node. The remote peer only performed the intended read-only
geometric inspection. The archived evidence therefore correctly fails replay
at the first origin-only canonical mutation; it is diagnostic failure evidence,
not a valid resumable checkpoint.

## Fix

`world.identifyExisting(registry, localId, kind)` now derives and validates a
portable pre-existing identity without modifying the registry. It:

- returns an existing local binding unchanged;
- derives a `kind:pre:fingerprint` identity for an unbound unique object;
- verifies that the identity resolves back to the selected local object;
- rejects ambiguous fingerprints;
- never binds or enriches canonical metadata.

The game-script proposal resolver now uses this read-only path. Later,
`proposalPreparation.bind` calls `world.resolvePreExisting` after the ordered
build commit, giving every peer the same owner, fingerprint, lazy-resolution,
and proposal metadata.

`tests/run_lua_tests.lua` covers an already-bound node, an unbound unique node,
and an ambiguous node. It hashes the registry before and after identification,
proves the digest remains unchanged, and proves binding occurs only through the
explicit committed resolver. The complete Lua/native/PowerShell/Python/replay
suite passes.

## Passing two-process receipt

Fresh session `vehicle-buy-repeatfix19-20260805-135755` loaded the pinned
populated save in two exact Build 35924 processes. Player 1 placed two new stock
stations and drew one point-to-point track between their throats. The track
appeared on both games. Machine-readable evidence records:

- prepare commit 11: digest `883c1547` on both peers;
- build commit 12: `success=true` on both peers;
- nine canonical physical outputs on each peer;
- physical core `cc94bd1e` on each peer;
- finance delta `-132911` on each peer;
- checkpoint boundary 13 with convergence key `6a095fad`;
- final core `c9c3bd16`, canonical `31e0a5a1`, model `a53f1324`, structural
  `402e02a8`, and financial `3bfc1ecc` on both peers.

The host reports `lastAgreedCheckpointSeq=13`, `nextCommitSeq=15`, no pending
proposal/checkpoint, no companion error, and `sessionFault=null`.

## Boundary

This proves unique station-throat nodes and the tested stock track transaction.
Ambiguous existing geometry remains deliberately unavailable until it gains an
event-derived identity; choosing a machine-local duplicate ordinal would make
the wire format nondeterministic.
