# Research-export architecture boundary

Date: 2026-08-09 (Europe/Amsterdam)

## Finding

The game-script entrypoint had reached its enforced 3,400-line ceiling. The
largest cohesive inline diagnostic path was `probe.export_research`: report
assembly, account projection, limitation documentation, bridge emission, and
receipt/error bookkeeping were all embedded in the event dispatcher.

That made unrelated gameplay work compete for entrypoint space and left the
export schema without a direct unit boundary. Its limitation text had also
drifted behind the implementation: it still named format-4 checkpoints, called
competitive credit unimplemented, and described authored cargo presentation as
telemetry-only.

## Change

`research_report.lua` now owns the complete report projection and export
receipt. The entrypoint supplies only live dependencies: state, native-hook
status, core/model digest functions, the public economy projection, native
account reads, and the bridge emitter. No persisted, checkpoint, protocol, or
event schema changed.

The projection retains every previous report field and additionally keeps the
automatic freight/passenger load-receipt probes introduced in 0.37. Its known
limits now describe format-5 checkpoints, authored competitive credit,
host-authored town/freight models, and the distinction between native scenery
agents and authoritative passenger/cargo ledgers accurately.

The extraction reduced the game-script entrypoint from 3,400 to 3,332 physical
lines. Both the entrypoint and report module now have independently enforced
source budgets.

## Adversarial checks

The focused runtime fixture verifies:

- ordered session/peer/tick and core/model/structure identities;
- proposal and operation counters/schema;
- native account and canonical finance projections;
- automatic freight/passenger milestone diagnostics;
- deep-copy isolation from the live state;
- successful bridge sequence receipts; and
- explicit bridge-failure propagation.

The success-path test caught a Lua truthiness trap during extraction: `ok and
nil or error` evaluates to the error branch even when `ok` is true. The shipped
implementation uses an explicit conditional and preserves the original
successful `error = nil` contract.

The complete repository suite passed after the extraction, including 122 Lua
model tests, cross-language economy/freight parity and stress, game-script and
company-mapping integration, 1,024-event replay, syntax/release/recovery tests,
and 135 companion/consensus tests.
