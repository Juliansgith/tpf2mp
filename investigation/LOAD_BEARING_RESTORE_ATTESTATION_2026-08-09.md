# Load-bearing restore save attestation

Date: 2026-08-09 (Europe/Amsterdam)

## Finding

Transport Fever 2 reloads two load-bearing files for a native save:
`name.sav` and `name.sav.lua`. The second file contains script-owned state,
including TPF2MP's canonical state and peer-local native bindings. Recovery
archives already hashed both files, but the ordered `recovery.save_receipt`,
restore plan, and pre-launch verifier named only the main `.sav` hash.

That split was fail-closed eventually: the mandatory post-load core checkpoint
would reject wrong script state. It was still the wrong boundary. A changed or
mispaired `.sav.lua` could be copied and loaded before the system discovered it,
and a plan claiming to identify a native restore point did not identify all
bytes that determine that point.

## Implemented boundary

Current receipts add `metadataSha256`, while the legacy receipt shape remains
valid for archived audits. Both host and client companions independently hash
the `.sav` and `.sav.lua` observed by their local exact-process watcher. The
hash helper requires both files, samples size and nanosecond modification time
before and after streaming both hashes, and refuses a pair that changes during
the read.

Restore plan version 4 requires, for every peer:

- the main `saveSha256`;
- the script-state `metadataSha256`;
- the ordered receipt sequence/time;
- the exact boundary, core digest, and convergence key; and
- the v3 match-content profile.

Plan generation refuses a boundary where only some peers have current
dual-file receipts. A fully legacy boundary may still produce/read v3 with its
historical main-save semantics; an explicitly policy-unbound old workflow may
still use v2. There is no silent mixed downgrade.

Before launch, v4 verification re-hashes both selected local files. The normal
pin and stage path then copies the same pair. Recovery-archive creation and
verification also require its metadata entry to match the plan attestation.
The optional `.jpg` preview remains archive-integrity data, not restore
authority, because it does not determine simulation/script state.

The schema and hashing responsibilities were extracted into
`restore_plan.py`, `native_save.py`, and `recovery_receipt_protocol.py` so the
coordinator and main protocol dispatcher remain below their enforced source
budgets.

## Compatibility and trust limit

V2 and v3 plans continue to verify exactly as before. They intentionally do not
pretend to contain a metadata hash. New automatic receipts plus a match profile
produce v4.

As elsewhere in this prototype, the plan checksum detects corruption and the
match fingerprint forces both peers to use identical plan bytes; it is not
secret-key authentication against a hostile participant.

## Offline evidence

- Python and Lua accept both legacy and current receipt shapes and reject bad
  metadata hashes or unknown/missing fields.
- Host and client anchor tests prove independent dual-file hashing and durable
  receipt replay.
- V4 plan construction/verification retains both peer metadata hashes;
  re-checksummed malformed hashes, mixed legacy/current receipt boundaries,
  missing metadata files, and changed metadata bytes fail closed.
- V2 and v3 plan fixtures remain readable.
- Current recovery archives bind their copied metadata hash to the peer plan;
  legacy receipt-bound archives still verify.
- The full source-boundary, Lua/Python, cross-language replay, watcher, release,
  installer, and launcher suites pass in the associated commit.

## Remaining live gate

Use **Prepare & Save Restore Point** in a populated two-process session, verify
the host emits a v4 plan with distinct `.sav` and `.sav.lua` hashes for both
peers, then close and resume through the launcher. Before the successful run,
copy player1's `.sav.lua` beside player2's `.sav`; Join must reject it before
launch. Restore the right pair and prove the mandatory checkpoint plus active
train/freight state resume.
