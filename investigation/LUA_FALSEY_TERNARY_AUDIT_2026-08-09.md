# Lua falsey-ternary audit

Date: 2026-08-09 (Europe/Amsterdam)

## Finding

Lua's common `condition and value or fallback` shorthand is valid only when
`value` is truthy. It cannot select `nil` or `false`: in both cases evaluation
continues to `fallback`.

An adversarial follow-up to the research-export extraction found twenty such
falsey projections in shipped Lua, plus one in the investigation probe. The
effects were deterministic across peers, which is why consensus tests had not
treated them as divergence, but the resulting state and diagnostics were
wrong:

- successful native-authority setup retained a failure message;
- successful proposal, operation, and checkpoint outcomes retained an
  `errorCode`;
- successful checkpoint exports and recovery preparation retained false
  errors;
- valid launcher restore attestations were marked with an error string;
- successful wallet reconciliation, starting-cash grants, mobility exports,
  passenger reads, and stock-UI scans retained false errors;
- a proxy-company bootstrap leaked `localCompanyIndex` even though that field
  is intentionally absent in proxy mode; and
- an explicit native command result of `success = false` was collapsed to
  `nil` in compact hook status.

The automatic load-milestone scheduler also logged a successful queue result as
an error. The same expression was caught and corrected in the newly extracted
research exporter before it was committed.

## Fix

Every shipped occurrence now either inverts the condition (`not ok and error or
nil`) where the selected error is guaranteed truthy, or uses an explicit
conditional where a tri-state or tuple is involved. Native command events now
assign true and false explicitly. Delivery-snapshot combination now has an
explicit failure return, and proxy initialization only writes a local-company
index outside proxy mode.

`check_source_boundaries.ps1` scans every shipped Lua source and rejects both
`and nil` and `and false or`. This converts the language pitfall from a review
convention into an enforced repository rule.

`state_success_normalization.lua` also makes the correction durable for saves
written by the affected builds. On load it clears error residue only where the
record retains independent success proof (`success = true`, `ok = true`, a
ready recovery preparation, a ready authority probe, or a checkpoint with a
successful export receipt). Explicit failed outcomes and their real error codes
are preserved. The old checkpoint-level `table: ...` artifact is removed only
when a successful local sequence receipt is also present.

## Evidence

New assertions cover clean native-authority and checkpoint setup, recovery
readiness, valid restore attestation, explicit false native command results,
successful proposal/checkpoint consensus, delivery snapshots, native passenger
reads, wallet reconciliation, and proxy company identity. The full repository
suite passes, including exact Lua/Python economy and freight parity, ordered
game-script/company integration, native/release/recovery checks, all companion
tests, and the 1,024-event replay.

This changes no wire schema. Older saved diagnostic records are normalized on
load; newly applied outcomes and newly generated reports are clean on both
peers.
