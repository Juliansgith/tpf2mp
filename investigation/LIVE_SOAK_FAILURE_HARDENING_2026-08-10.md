# Live soak failure hardening

Date: 2026-08-10 (Europe/Amsterdam)

Implementation target: prototype `0.37.0-alpha`, state schema `30`, economy
model `9`, checkpoint format `5`, passenger-presentation schema `4`

## Live findings

The populated localhost soak did not expose a native pathing deadlock. The
authority companion had stopped after a Windows `Permission denied` failure
while appending its journal. Once authority disappeared, both game scripts did
the safe but visually confusing thing: they retained their station holds and
stopped accepting later work. A concurrent evidence read was the relevant
trigger shape because the former reader held the audit file open throughout a
full parse.

Two secondary durability findings were visible in the same evidence:

- the disconnected peers each accumulated roughly 1,545 pending
  `clock_health`/`vehicle_sync` files;
- selling a loaded legacy vehicle left an unexplained 13-rider line residue:
  1,513 boarded, 1,498 alighted, and two still aboard.

The passenger mismatch did not mint revenue. Completed alightings remained the
only payable cursor. It was nevertheless an incomplete conservation ledger and
would make a strict future checkpoint ambiguous.

## Journal hardening

`AuditLog.messages()` now snapshots the journal bytes and closes the Windows
handle before checksum parsing or replay. A live append therefore overlaps only
the short read, not an arbitrarily long analysis.

Append and snapshot opens retry access-denied/sharing-violation failures for a
bounded five seconds. A failed write is never blindly retried after the handle
has opened because the write outcome may be uncertain and duplicating an
authority record would be worse than stopping.

If persistence is still unavailable, the host now enters an explicit
`audit-persistence-failure` state. It does not acknowledge the originating game
sequence, closes all TCP peers, publishes `status=faulted`, and remains alive as
an observable fail-closed process until the launcher stops it. Status includes
append/read retry counts and the audit-fault bit. The listener/poll lifecycle
was extracted into `host_runtime.py`, and the journal implementation into
`audit_log.py`, to retain the repository's source-size limits.

## Passenger conservation

Passenger-presentation schema 4 adds a lifetime `discardedTotal` to every
active line. Vehicle sale, batch sale, reassignment, route replacement, and
inactive-service retirement now account any onboard load before removing or
resetting its vehicle record.

Current checkpoints enforce all three identities:

```text
vehicle boarded = vehicle alighted + vehicle discarded + vehicle aboard
line boarded    = line alighted + line discarded + sum(active aboard)
line generated  = line boarded + both waiting queues + line overflow
```

Schema-1-through-3 saves migrate deterministically. The line residue is
recovered from its monotonic counters; the observed live values therefore
become exactly 13 discarded riders. Schema 3's historical reassignment behavior
could carry an old line's discard counter onto a fresh vehicle record, so the
migration also reconstructs each vehicle's line-local residue rather than
preserving that unrelated value.

## Disconnected queue bound

Only replaceable `clock_health` and `vehicle_sync` reports are coalesced. When
the companion is unavailable, or its unconsumed queue reaches 256 records, a
new report does not consume a local sequence or create a file. Durable intents,
checkpoints, completions, events, research, and evidence remain untouched.
The reporting runtimes keep their latest state pending and emit it after the
companion reconnects, so coalescing cannot create a numbered-queue gap.

After acknowledgement, both replaceable kinds are pruned outside the existing
4,096-message forensic tail. Vehicle synchronization witnesses remain in the
authority audit. Clock health is live telemetry rather than recovery state:
every report updates authority, while one forensic sample per peer per ten
seconds is journaled. The multiplayer panel exposes the source-side coalesced
count and the host status exposes audited/skipped health-sample totals.

## Follow-up audit of the same soak

The first correction pass deliberately revisited the complete evidence rather
than treating the journal-sharing failure as the only defect. That found four
more concrete issues:

- the localhost harness wrote `passed: true` even though the host companion had
  exited and one otherwise valid commit still awaited a peer digest;
- the 2.7-hour run produced 611 clock generations: 220 adaptive step-downs and
  224 recoveries oscillated mostly between speeds 4 and 3;
- 16,212 `clock_health` records occupied 7.7 MiB of the 19.3 MiB authority
  journal, despite replay never using them as recovery state; and
- after the host died, the client printed the same connection-refused error
  every two seconds.

The clock storm was a policy error, not proof that the slower-rendering game
could not keep simulation time. The old governor compared native update/render
`tickRate`; P1 and P2 could have very different FPS while advancing game time
at the same rate. Seventy-four of the observed corrections were for only 2-3
game seconds of skew, immediately followed by recovery.

`clock_governor.py` now compares measured `gameRate` with the nominal rate of
each peer's selected speed. A soft two-second skew must persist for four wall
seconds, a progress ratio below 0.65 must persist for eight, an eight-second
skew remains an immediate safety correction, and speed
recovery requires thirty stable seconds. The vehicle release barrier uses the
same debounced skew predicate. Status separately reports progress ratio,
debounce durations, step-downs, recoveries, and skew corrections, so the next
soak can distinguish legitimate intervention from churn.

Interactive/manual validation now continuously checks both companion
processes and their fault/status files. Its final audit replay uses
`--require-settled`, which rejects no-commit runs, incomplete peer digests, and
pending/faulted proposal, operation, or checkpoint lanes. The preserved failed
audit is therefore still structurally valid for diagnosis but correctly fails
the acceptance gate with one commit awaiting peer digests. Client reconnect
uses bounded exponential backoff (2, 4, 8, then 10 seconds) and rate-limits an
unchanged error to one visible message per thirty seconds.

## Recovery UI finding

The evidence also explained an earlier seemingly unrelated report that the
game unexpectedly went fullscreen, opened Save, and typed a name. The recovery
watcher had treated any incidental `anchorReady` checkpoint as permission to
operate the stock Save dialog. No `recovery.prepare` action existed at those
boundaries.

The UI fallback now requires both `anchorPreparationStatus == ready` and a
matching `anchorPreparationCheckpointSeq`. An incidental quiescent boundary is
reported as `manual-save-available` and never focuses or clicks a game window.
The helper also recognizes an already-open pause menu and rejects zero-sized
stale UI rectangles before clicking. Expected retry diagnostics are written to
the attempt evidence directory instead of polluting watcher stderr.

## Verification

Automated proof includes transient reader denial, closed-handle replay,
permanent journal denial, fail-closed host liveness, cursor non-acknowledgement,
source coalescing, durable-sequence preservation, reconnect emission,
acknowledged vehicle-report pruning, loaded single/batch sale, reassignment,
legacy residue migration, and Lua/Python checkpoint tamper rejection.

The complete repository test runner passes, including 128 Lua unit tests,
cross-language economy and freight parity/stress, runtime and game-script
integration, packaging/install/rollback, recovery handoff, syntax checks, and
156 Python protocol/network/checkpoint/recovery tests. It also checks 120 mod
Lua files, 8 investigation/tool Lua files, and 47 PowerShell files for syntax.
Source budgets and `git diff --check` also pass.

## Remaining live gate

These fixes require a fresh state-30 pair; an already-running game cannot load
changed Lua/Python code. The next useful live run is deliberately narrow:

1. run two or more trains on one line at speed 3;
2. read/export the live audit repeatedly while trains reach stations;
3. confirm the host remains `running` and every held train receives release;
4. sell one loaded train, then checkpoint and confirm the displayed discarded
   count rises without a conservation fault;
5. stop one companion long enough to pass the telemetry cap and confirm no
   numbered gap or unbounded outbox appears after reconnect;
6. verify normal unequal P1/P2 FPS does not cause speed oscillation, while one
   deliberately sustained slow game-time peer still causes a bounded step-down;
7. allow an ordinary settlement checkpoint to become READY and confirm no Save
   UI appears, then press **Prepare & Save Restore Point** and confirm the
   explicit boundary does invoke the fallback.

That run is the human acceptance gate. The failure mechanics and migration are
covered automatically, but native station visuals and Windows process/file
sharing still warrant a real two-process receipt.
