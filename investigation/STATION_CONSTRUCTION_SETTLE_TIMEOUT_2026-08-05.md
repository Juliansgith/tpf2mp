# Station construction settle timeout — 2026-08-05

## Outcome

The false `peer-native-proposal-failed` seen after a visibly successful final
station build is fixed. Construction replay remains bounded and fail-closed,
but its native-result observation window is now 600 engine updates instead of
120. A delayed-result regression passes beyond the old cutoff, and a fresh
two-process ordinary-UI sequence completed six station build/removal proposals
plus every dependent checkpoint with no fault.

## Failure and diagnosis

In localhost session `vehicle-buy-repeatfix17-20260805-124024`, final proposal
`vehicle-buy-repeatfix17-20260805-124024:player1:24` appeared physically in both
worlds. Direct engine queries showed the same new construction and identical
construction/station/station-group/node/edge counts on both processes.
Nevertheless, both peers emitted a failed completion at the old 120-update
deadline and the host correctly faulted the session.

This was not a transaction-codec, ownership, or cross-machine divergence. The
native construction had completed, but the canonical compound-result observer
had not resolved its postconditions before its deadline. Treating that timing
as an immediate native failure produced a false negative after valid geometry
was already present.

## Implementation and automated proof

`tpf2_mp_1/res/scripts/tpf2_mp/proposal_runtime.lua` now defines a named
`CONSTRUCTION_SETTLE_TIMEOUT_TICKS = 600` bound. The proposal still fails
closed if the expected compound result cannot be resolved by that deadline;
the change does not accept a no-op, mismatch, ambiguous output, or unilateral
peer result.

`tests/run_network_company_mapping_tests.lua` now withholds a station's child
topology for 150 updates. It proves that:

- the record remains in `building-construction` beyond the former 120-update
  cutoff;
- no failed completion is emitted at that point;
- materialising the expected station/group/nodes/edges later produces the
  normal successful completion and checkpoint path.

The complete `tools/run_tests.ps1` suite passes, including Lua/runtime/network
integration, syntax and launcher checks, 45 companion tests, cross-language
replay verification, and the delayed-construction case. The rebuilt native
hook also passes both pinned-profile CTest cases.

## Fresh two-process live proof

Session `vehicle-buy-repeatfix18-20260805-134013` loaded the same pinned
populated save in two exact Build 35924 processes. The user performed this
ordinary-UI sequence, waiting for peer visibility after each action:

| Commit | Origin | Action | Physical core on both peers | Finance delta |
|---:|---|---|---|---:|
| 4 | player1 | build station 1 | `2c81b6ee` | -113,215 |
| 8 | player1 | build station 2 | `08821957` | -122,910 |
| 12 | player1 | remove station 2 | `bdf70986` | 0 |
| 16 | player2 | build 160 m/two-track station | `1e9d139b` | -504,267 |
| 20 | player2 | remove that station | `34d95c56` | 0 |
| 24 | player1 | build final 80 m/one-track station | `874ec305` | -154,069 |

Every completion reported `success=true` independently on both game processes.
The final build settled in five engine updates on each process and produced
checkpoint boundary 25 with identical:

- convergence key `6ed45fad`;
- core digest `84dbc2fe`;
- canonical digest `f030ab64`;
- model digest `abf21349`;
- structural digest `402e02a8`;
- financial digest `3e0f1ef1`.

The host then reported `lastAgreedCheckpointSeq=25`, `nextCommitSeq=27`, no
pending proposal/checkpoint, no companion error, and `sessionFault=null`.
This closes the hidden-timeout regression for the tested stock station flow.

## Remaining boundary

The 600-update value is a pragmatic bound for Build 35924, not a claim that all
modded construction callbacks finish within it. A future configurable bound
must remain roster-bound and deterministic; silently accepting an unresolved
construction would reintroduce mutation residue. Broader construction families
and a real two-computer latency run remain separate acceptance gates.
