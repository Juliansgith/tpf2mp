# Automatic restore-plan handoff and local discovery

Date: 2026-08-09 (Europe/Amsterdam)

## Problem

The automatic READY-gated save path still left one manual distribution step.
Only player1 can derive the authoritative receipt-bound restore plan from the
host audit. Player2 archived its independently attested save before that plan
existed, so the player had to copy the host JSON to the second machine, select
it manually, and then locate the correct peer archive. A wrong role, stale
boundary, or unanchored archive could therefore become a confusing late launch
failure even though startup itself remained fail-closed.

## Implemented flow

After both ordered save receipts make a boundary restorable, the host watcher:

1. generates and metadata-verifies the current v4 plan;
2. creates player1's receipt-bound recovery archive;
3. atomically publishes the exact plan into the host companion bridge; and
4. records its semantic checksum in schema-6 watcher status.

`RestorePlanExchange` admits only a checksummed plan whose source session is the
active bridge session. It wraps that plan in the existing checksummed network
envelope, broadcasts it to player2, and replays it to a client that connects
after publication. The client independently validates both envelopes and the
nested v4 plan before atomically writing `received_restore_plan.json`.

Player2 deliberately retains its first local archive when its receipt is
accepted. When the host plan arrives, its watcher verifies the plan again,
requires the same source session, peer roster, and archived boundary, copies it
into player2's durable recovery directory, and creates a second archive. The
archive writer re-hashes `.sav` and `.sav.lua` against player2's exact plan
attestation. Only that second archive is marked `receiptBoundArchiveReady` and
becomes the latest restore pointer. Pending or manually unanchored archives use
separate candidate pointers, so a newer incomplete boundary cannot displace the
last known-good restore. A failed bind preserves the earlier bytes and
reports the error; it never upgrades an unanchored archive by assertion.

## Launcher discovery

The launcher now has **LOAD LATEST RESTORE**. `local_restore.py` scans only
`%LOCALAPPDATA%/TPF2MP/sessions/<session>/<peer>/recovery`, then verifies:

- pointer/session/peer identity and containment (no path escape);
- pointer hash of the archive manifest;
- plan checksum, schema, resume identity, and peer roster;
- every signed archive entry and receipt-bound association;
- exact plan checksum equality between plan and archive; and
- the archived peer-specific `.sav` plus adjacent `.sav.lua` against the plan.

Invalid or unanchored candidates are skipped. The newest complete candidate is
loaded into the existing strict Host/Join path: the launcher locks the derived
resume session, selects the archived save, adopts the bound match policy, and
still performs startup verification. On a normal two-computer setup each
machine finds only its own role. A development machine with both local roles is
asked which one to load.

## Offline evidence

- Isolated exchange tests reject a wrong outer peer and wrong source session.
- A socket integration test proves a plan published before player2 connects is
  replayed and durably received after connection.
- Discovery builds a real v4 receipt-bound archive, rejects a newer
  path-escaping pointer, selects the older valid candidate, and exercises the
  JSON CLI used by the launcher.
- A synthetic shell integration now executes byte-exact host publication,
  player2's real archive writer/verifier, promoted-pointer checks, and the exact
  launcher discovery wrapper. It caught and fixed an untested assumption that
  the eight-character protocol checksum was at least twelve characters long.
- Watcher fault/race fixtures, launcher construction, source budgets, and the
  existing recovery/archive tests remain part of the full suite.

No game was launched for this slice.

## Trust and remaining live gate

The existing protocol checksum is corruption/integrity detection, not keyed
authentication. Match fingerprints bind the exact plan bytes and every local
consumer re-verifies them, but this is still a trusted-LAN/VPN design.

The next live gate is one populated two-process automatic boundary: prove both
native saves, two distinct receipts, host publication, player2's receipt-bound
re-archive, one-click discovery on both roles, peer-local reload, mandatory
`recovery.resume` checkpoint, and resumed train/freight state. Automatic game
process relaunch and hostile-network authentication remain separate work.
