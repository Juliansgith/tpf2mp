# In-place fault requalification

Date: 2026-08-26  
Implementation target: `0.40.5-alpha`, state schema `32`, checkpoint format `5`.

## Outcome

A narrowly proven physical-proposal timeout no longer requires abandoning the
current native world. The session stays paused and faulted until both games
finish the late command. When both report the same empty failure and unchanged
authored core, the Multiplayer panel reports `READY` and exposes one
`Recover / Resync Session` action. The host then orders a requalification and
requires a new all-peer checkpoint before it clears the fault.

This is not a general “ignore error” switch. Divergence, mutation residue,
mixed results, operation faults, checkpoint faults, missing evidence, and
different native errors remain restore-only.

## Evidence contract

The host derives every recovery field; a client can submit only
`{ type = "recovery.requalify" }`. Eligibility requires all of the following:

- the active fault is exactly one `proposal-completion-timeout:*` outcome;
- every required peer later reports `success=false`;
- every completion has no canonical outputs and no finance delta;
- physical result views, native error codes, and core digests are identical;
- the late core equals the core agreed during `proposal.prepare`;
- no non-clock ordered work followed the fault;
- both games freshly attest the same fault, a native pause, an empty local
  ordered queue, no pending proposal, and zero origin-applied residue.

The ordered recovery commit binds the original proposal commit/outcome,
proposal/result/core digests, native error, requester, and a deterministic
recovery id. Both games independently re-evaluate that evidence. They refresh
their structural snapshot and canonical world manifest, then emit a checkpoint
whose reason is bound to the recovery id. The host requires identical
eight-character structural and world-manifest digests, the original authored
core, and the normal format-5 convergence key. Only a successful checkpoint
changes the timed-out proposal from `faulted` to `rejected` and clears that
exact session fault. The games remain paused so resumption is deliberate.

The original timeout, late completions, recovery commit, and checkpoint remain
in the authority audit. Replay recognizes the proposal as recovered only when
that complete chain verifies; a missing, duplicated, or cross-boundary proof
still reports an unsettled fault.

## Timeout prevention

Native construction-step event records now count as proposal progress. Each
real step renews the ordinary completion deadline, bounded by a hard deadline
of at least five minutes (or eight ordinary timeout windows). This prevents a
large station/depot/terrain replay that is visibly progressing from being
faulted at the original short deadline, without allowing an infinite livelock.
The host status publishes progress count and remaining deadline.

## User flow

1. Let the automatic shared pause complete after a fault.
2. Open Multiplayer and read `Session recovery`.
3. If it says `READY`, press `Recover / Resync Session` once.
4. Wait for `RECOVERED - safely paused`, then choose a game speed.
5. If it says `RESTORE REQUIRED`, use the verified restore workflow; do not
   retry the native action in the faulted world.

## Automated proof

- Python integration constructs a real timeout, records two late identical
  empty failures, requalifies, converges a structural checkpoint, reloads the
  authority audit, and verifies that the session is healthy and the proposal
  is an auditable rejection.
- A sibling test gives the peers different native failures and proves the
  recovery request is rejected as restore-only.
- Consensus tests prove progress renewal and the absolute hard cap, plus the
  strict schema-4 recovery health fields.
- Lua runtime tests independently reject client-supplied proof, refresh native
  structural evidence, emit the bound checkpoint, and clear only the matching
  local timeout after checkpoint success.
- Source-boundary checks require the host coordinator, game runtime, and panel
  view to remain composed.

## Remaining live gate

On a disposable two-PC relay match, deliberately allow a slow compound depot
or station proposal to pass its ordinary timeout while still completing on
both games. Confirm the panel moves from waiting to ready, press recovery once,
observe one fresh checkpoint, resume, and then successfully place a new small
track segment from either peer. Also retain one deliberately mismatched fault
to confirm the panel says restore required.
