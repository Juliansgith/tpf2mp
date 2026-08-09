# Witnessed aboard-evidence hardening

Date: 2026-08-09 (Europe/Amsterdam)

Implementation target: prototype `0.37.0-alpha`, state schema `29`, checkpoint
format `5`, passenger-presentation schema `2`, cargo-presentation schema `1`

## Finding

The automatic freight and local-passenger acceptance milestones introduced a
real short-route timing race. A positive load schedules an ordered follow-up,
but an already-running physical proposal, checkpoint barrier, or local intent
can delay that follow-up until the vehicle reaches its next stop. The original
milestone then inspected only the current `aboard` value. A perfectly valid
load could therefore become zero before the evidence commit was applied.

Making the old rejection fatal would fault a healthy match. Merely accepting
the empty checkpoint would create a false proof. The evidence needs to survive
alighting without turning native vehicle position into authority.

## Portable witness

Newly generated `freight.milestone` and `passenger.milestone` actions retain
their four identity fields and add three exact-safe positive integers:

```text
observedRound = authored vehicle release round
boardedTotal  = authored cumulative vehicle boarding cursor
aboard        = authored load immediately after that release
```

The host captures these values from the deterministic passenger or cargo
presentation ledger, not from native agents. Both peers accept the commit only
when the same canonical vehicle still belongs to the same line, its current
round is at least `observedRound`, and both vehicle and line boarding cursors
are at least `boardedTotal`. The current load may already be zero. Positive
cumulative boarding is itself monotonic evidence that the vehicle carried a
load at an earlier authored release.

Legacy four-field actions remain readable for old audits and in-flight 0.36
messages. They still require a positive current load and cannot provide
historical evidence.

All identities, field sets, boolean exclusions, lower bounds, ordering
constraints, and the IEEE-754 exact-safe upper bound are checked independently
by Lua and Python. A partial witness is invalid.

## Stale actions and retries

A structurally valid witness can become semantically stale if its line is
retired, its vehicle is reassigned, or a peer has not reached the claimed
cursor. Applying such an ordered action now succeeds as an evidence-only stale
no-op instead of faulting the whole match. It records
`aboardCheckpointed = false`; the subsequent checkpoint cannot satisfy the
strict live report, and a later qualifying release may schedule a fresh
milestone.

This is intentionally different from accepting the proof. Divergent authored
cursors still produce divergent checkpoint/model digests and fail closed.

## Priority without reentrancy

The evidence action cannot bypass an intent already sent to the host, a live
physical/checkpoint consensus barrier, or a disconnected peer. Once those
prerequisites clear, however, passenger and freight milestones now form a
small priority prefix ahead of locally queued but uncommitted physical work and
ordinary derived actions such as line registration.

Priority items preserve FIFO order across the passenger and freight domains.
Each domain still coalesces to one pending one-shot action; a newer witnessed
observation replaces the older pending witness. Passenger and freight actions
never coalesce with each other. Emission remains tick-driven and non-reentrant.

## Audit binding

The shared live-evidence scanner now revalidates every ordered commit against
the current strict protocol and carries the exact ordered boundary action into
each completed checkpoint record. Freight and passenger-feeder reports verify
the witness against the independently validated checkpoint ledger.
Passenger proof is additionally restricted to a currently linked, qualifying
local ROAD/TRAM feeder with a corridor and positive feeder benefit. Freight
proof rejects retired lines.

The reports expose current and historical loads separately:

- `aboard` / `localAboard` is the load at checkpoint time;
- `witnessedAboard` / `localWitnessedAboard` is the verified earlier load;
- `aboardWitness` identifies its exact line, vehicle, round, and cursor.

## Automated evidence

Runtime tests cover historical proof after alighting, stale passenger and cargo
cursors, invalid zero-round capture, host/client authority, evidence priority
over deferred physical work, FIFO order between evidence domains, coalescing,
and disconnection/barrier behavior.

Companion tests cover both legacy and witnessed wire formats, exact-field and
integer bounds, wrong line/vehicle identity, future rounds, inflated boarding
cursors, retired freight lines, passenger feeder binding, and complete
two-peer audit reports whose checkpoint load is already zero.

No game is launched by this slice. The remaining live proof is deliberately
ordinary UI: run a short ROAD/TRAM feeder and a freight service, allow either
vehicle to unload before its milestone checkpoint, and require both strict
reports to accept the witnessed load without a session fault.
