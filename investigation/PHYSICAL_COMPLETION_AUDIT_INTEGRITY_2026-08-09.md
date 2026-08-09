# Physical completion and audit integrity

Date: 2026-08-09 (Europe/Amsterdam)
Prototype: `0.29.0-alpha`

## Finding

The game emitted a bounded physical-result view and its Adler-32 digest for
every native proposal and canonical operation. The companion validated the
shape of both values and compared peer digests, but did not recompute the
digest from the fields in the signed completion. A stale or defective producer
could therefore report a valid-looking digest that did not describe its own
outputs, postcondition, success flag, identity, or core digest. If both peers
made the same mistake, digest equality alone could hide it.

Offline `replay` had a second durability gap: it verified proposal physical
consensus, checkpoints, and event chains, but did not index or verify canonical
operation completions and outcomes. A line or vehicle operation could be valid
live and still be absent from the later audit verdict.

## Resolution

`completion_validation.py` is now the one strict boundary for proposal and
operation completion payloads. It reconstructs the exact Lua result view,
recomputes its canonical cross-language checksum, and rejects a mismatch before
the completion enters a live tracker or a restored tracker. The live host also
compares complete result views directly, so physical equality does not depend
only on a 32-bit digest collision check.

`audit_consensus.py` verifies both physical protocols during offline replay:

- commit/outcome/completion identity and transaction digest binding;
- every required peer's presence on a successful result;
- exact peer result-view and core equality;
- outcome digest equality with the verified completions;
- finance selection from the operation/proposal origin peer;
- residue-free identical proposal rejection and preservation of the prepared
  core digest;
- the checkpoint boundary following every successful physical outcome.

Conflicting duplicate completions or outcomes are rejected both when loading a
host audit after restart and during offline replay. The CLI reports physical
operation complete/faulted/pending counts beside the existing proposal counts.

The refactor leaves bounded ownership seams: completion validation is 127
source lines, physical audit verification is 157, consensus trackers are 263,
and the CLI is 419 by the repository's line counter. Source budgets are 150,
180, 300, and 430 respectively.

## Verification

- Adversarial tests change a completion's core digest or operation
  postcondition without changing `resultDigest`; both are rejected.
- The physical-divergence test now supplies two internally valid but different
  result views, proving live consensus still faults on actual disagreement.
- Operation integration now replays its complete two-peer operation,
  origin-finance choice, and following checkpoint.
- The full repository gate passes: 95 Lua core tests, 75 cross-language economy
  vectors, 108 Python tests, native tests, source boundaries, and the
  1,024-event replay.
- The historical `economy-v7-easy-20260808-020935` audit remains valid with 75
  commits, 33 completed physical proposals, 6 completed physical operations,
  and 40 completed checkpoint barriers.
- `runtime/localhost-live/localhost-20260809-030632` passes on two exact Build
  35924 processes after the change: 11/11 commits converged, both proposals and
  all three checkpoint barriers completed, 600 soak ticks retained matching
  core `d9366b44` and structure `1ab06cc6`, and offline replay reports zero
  physical or checkpoint faults.

This closes receipt self-consistency and operation audit omission. It does not
turn Adler-32 into an authentication primitive; envelope checksums remain a
deterministic corruption/divergence detector inside the trusted match-content
and LAN boundary.
