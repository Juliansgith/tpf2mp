# File-bridge long-session scaling

Date: 2026-08-09 (Europe/Amsterdam)

Prototype: `0.29.0-alpha`

## Finding

The companion's outbound poll was linear in the complete session history. At
10 Hz, `GameBridge.pending_outbound()` globbed and sorted every immutable JSON
file even though its durable cursor names the only legal successor.

The preserved `topology-depot-live-20260808-111411` run ended with 5,469 host
and 6,048 client outbox files. A read-only benchmark on the real host directory
measured:

- enumerate and sort all 5,469 files: **15.460 ms per poll**;
- test the exact next numbered path: **0.015912 ms per poll**;
- avoidable lookup ratio: approximately **972x**.

That work ran independently in both companions and grew throughout the match.
It does not explain native rendering cost by itself, but it is a concrete
mod-side CPU/filesystem tax and would become untenable in a multi-day session.

## Correction

Outbound consumption now resolves exactly `outbox_cursor + 1` and walks at
most the caller's bounded limit. A missing successor stops the poll; it never
permits skipping to a later file. Envelope, session, peer, filename, and
message-sequence validation remain unchanged.

The cursor file is schema 2 and additionally records `pruned_through` and the
retention contract. Checkpoints, events, intents, completions, telemetry
samples, and manual research exports remain intact for offline tools. Only the
high-frequency acknowledged `clock_health` stream is replaceable: the
companion retains at least the latest 4,096 messages' worth and removes older
heartbeats. A crash cannot lose unconsumed work because maintenance stays 4,096
sequences behind the newly acknowledged cursor, whose earlier position was
already durable.

Old schema-1 cursors remain readable. Their pre-existing historical prefix is
treated as outside the new maintenance range, avoiding a large synchronous
delete storm on upgrade. New messages are bounded from that point onward.

## Automated evidence

The bridge tests prove:

- polling succeeds while `Path.glob` is forced to raise, so history
  enumeration cannot silently return;
- only the exact next sequence is accepted and a gap is never skipped;
- acknowledgement at sequence 4,098 removes an old sequence-1 clock heartbeat
  while preserving a sequence-2 checkpoint;
- the schema-2 cursor persists the cursor, maintenance boundary, and 4,096-
  message ephemeral-tail contract; and
- existing atomic-replace retry and idempotent inbound behavior still pass.

A fresh long two-process run remains useful for end-to-end FPS/CPU comparison,
but the algorithmic defect and its real-session scaling cost are closed.
