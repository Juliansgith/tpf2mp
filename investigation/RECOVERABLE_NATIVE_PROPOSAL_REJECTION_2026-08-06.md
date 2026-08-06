# Recoverable native proposal rejection

Date: 2026-08-06 (Europe/Amsterdam)

## Result

The failed final track connection in
`prompt-multitrain-human-state22-20260806-110906` was not a one-sided codec
failure. Both exact Build 35924 processes received the same ordered schema-5
transaction, both native `BuildProposal` calls rejected it, and neither world
changed. The native log gives the base-game reason immediately before the
failure record: `Too much curvature`.

The multiplayer defect was the response to that result. The old host treated
every post-commit native rejection as `peer-native-proposal-failed`, faulted
the session, and consequently blocked the user's later bulldoze attempt. A
deterministic invalid placement must reject the click without making all later
play impossible.

The implementation now distinguishes a clean, unanimous native rejection from
physical divergence. It still fails closed unless every no-mutation condition
below is proven.

## Preserved evidence

The captured bundle is:

`runtime/manual-network-evidence/prompt-multitrain-human-state22-20260806-110906-20260806-113254/evidence.json`

The bundle reports a valid audit and source/install equality. The relevant
ordered build is sequence 76, with proposal digest `c1df2433`. It contains a
compound track split/join (three new nodes, five new edges, three removed
edges, and two removed nodes), so it was substantially richer than the earlier
linear segments that had succeeded in the same run.

The decisive observations are:

- both peers emitted `success=false` for the same proposal;
- both emitted no canonical outputs and no finance delta;
- both emitted result digest `f18f37f5`;
- both emitted the same core digest as the successful prepare barrier,
  `9a36eb41`;
- no physical/canonical mutation appeared on either peer;
- both games were paused, so the rejection was not caused by a moving train or
  a one-sided simulation-time race;
- the shared native stdout records `Too much curvature` immediately before the
  rejected proposal;
- ordered sequence 77 nevertheless declared a fatal
  `peer-native-proposal-failed`, after which normal edits were correctly
  blocked by the session-fault gate.

The interleaved two-process stdout is useful for the native reason but is not
used as consensus authority. The signed peer completion records and prepare
barrier supply that proof.

## Recovery predicate

A failed native proposal is now recoverable only when all of these statements
are true:

1. every required peer supplied a completion;
2. every completion names the committed proposal digest;
3. every peer reports `success=false`;
4. every peer reports an empty output set;
5. no peer reports a finance delta;
6. peer error codes agree;
7. result digests agree;
8. core digests agree;
9. the agreed failed core digest exactly equals the all-peer prepare-barrier
   core digest captured before the build commit.

If and only if that predicate holds, the host emits an ordered
`network.proposal_outcome` with `success=false`, `recoverable=true`, and
`errorCode=native-proposal-rejected`. The proposal is counted as `rejected`,
not `complete` or `faulted`. It then opens an ordinary all-peer checkpoint with
reason `physical-rejection:<proposalId>` before another gameplay action is
admitted.

Mixed success/failure, non-empty outputs, a finance delta, differing error,
result or core values, a changed prepare core, missing completions, queue
rejection, and timeout all remain fatal. The Lua consumer independently checks
its own failed completion before honoring the host's recoverable bit; an
unknown proposal or local residue promotes the outcome back to a session
fault.

## Durability and observability

The prepare-core baseline is retained in the live host tracker and rebuilt
from signed prepare acknowledgements during audit restoration. Audit inspection
validates the same predicate, recovery-anchor analysis does not misclassify a
recoverable rejection as a later fault, and the post-rejection checkpoint is a
normal recovery boundary.

Runtime snapshots, the in-game panel, and research reports now separate
physical proposal counts into completed, rejected, and faulted. This avoids
presenting an ordinary invalid curve as either a successful build or a damaged
session.

## Automated proof

Coverage now includes:

- unanimous empty rejection preserving the prepare core;
- the post-rejection checkpoint and recovery-plan interpretation;
- host reconstruction of the rejected state from its audit;
- fatal changed-core, non-empty-output, and mixed-result cases;
- Lua-side acceptance of a matching local failed completion;
- Lua-side rejection of a falsely recoverable outcome with local residue;
- research and audit-report rendering of the new rejected category.

The focused Python and Lua integrations pass. The complete repository suite is
the release gate for this change.

## Remaining live check

One fresh two-process run should intentionally draw a curve that vanilla
rejects, wait for the rejection checkpoint, then immediately bulldoze or place
a valid segment. The expected result is: no track from the invalid click, both
peers remain structurally equal, `rejected` increments once, session health
stays healthy, and the following valid action synchronizes normally.

## Follow-up live run

The disposable two-process session
`rejection-recovery-human-state22-20260806-1147` verified the surrounding
success path after this change. Its captured bundle is:

`runtime/manual-network-evidence/rejection-recovery-human-state22-20260806-1147-20260806-115155/evidence.json`

The audit is valid and reports 17 converged ordered actions, eight completed
physical proposals, nine completed checkpoint barriers, and zero faulted or
pending proposals/barriers. The user successfully continued with track
building, bulldozing, and signal placement on both peers.

This run did **not** emit a recoverable rejection: the audit reports
`complete/rejected/faulted/pending=8/0/0/0`. The attempted invalid placement
was therefore either rejected by the vanilla preview before it entered the
multiplayer proposal stream or accepted as valid geometry. It proves that the
normal edit path remains healthy after the change, but it does not replace the
remaining live check above. The recoverable branch itself is currently proven
by the automated cross-language tests and the preserved failed transaction,
not yet by a fresh live trigger.
