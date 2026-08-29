# Relay and recovery reliability hardening - 2026-08-29

## Scope

This slice closes seven reliability findings without changing gameplay
authority, simulation rules, or save formats:

1. automatic recovery-point freshness;
2. diagnostic-volume control;
3. useful relay action metadata;
4. stable cross-peer Lua failure text;
5. retry-safe failures before the authority boundary;
6. one-shot save-channel lifetime; and
7. relay-room cleanup after a failed Host launch.

## Recovery freshness

The host now schedules the existing `recovery.prepare` workflow 15 minutes
after the last complete pair of signed save receipts. It does not promote an
incidental checkpoint. It waits for both peers, a first agreed checkpoint, an
empty ordered tail, no competing preparation, and an open continuation fence.
The resulting save is therefore the same receipt-bound v6 restore point as the
manual button.

An automatic preparation is journalled with a host-only `automatic=true`
marker. This lets a restarted host adopt a drain/checkpoint/save already in
progress. If both receipts were written immediately before restart, the host
finishes that exact boundary and restores the prior shared speed. The later
host-authored clock control is reconstructed as superseding the prepared
boundary, preventing an already-complete attempt from being adopted again.

An attempt is bounded to three minutes. Timeout or preparation failure emits
ordered `recovery.cancel`, supersedes a still-pending checkpoint tracker, and
releases the preparation fence. Healthy play resumes at the previously agreed
speed; a faulted session remains paused. Turning future automatic anchors off
does not strand an in-flight journalled attempt.

If a peer disconnects after both receipts exist but before the prior speed is
restored, the restore point remains complete and the games remain safely
paused. The rejected resume is exposed in status and does not terminate the
host loop; ordinary reconnect/clock handling can resume later.

## Diagnostic and relay lifetime policy

Client status is now sampled every 20 seconds while semantically unchanged.
Fault, connection, recovery, receipt, and relay-channel transitions bypass the
timer. Identical log text is emitted at most once per minute. Routine
`game.stdout` lines are discarded; bounded failure markers remain available.
Offsets advance only after relay acceptance, so a failed upload still retries
the same evidence.

The relay extracts `payload.action.type` into `actionType` without retaining
the action. Raw repeated `clock_health` and `anchor_state` gameplay frames are
not stored in the timeline because the sampled status channel already retains
their meaningful transitions.

The save tunnel exits after one acknowledged and verified transfer. It does
not repeatedly pair a channel whose protocol has already completed. If Host
launch fails, cleanup uses the exact local credential file to close only that
room; Join failures cannot close a room.

## Launcher and deterministic-error policy

The same-session retry allowlist now covers native menu/page timing, companion
readiness, hook-injection startup, and paused-menu wake failures only when they
occur before authority is ready. Fingerprint, credential, content, identity,
and stale-traffic errors remain hard failures. Each failed attempt still
archives its evidence and retires its own process identities before retry.

Lua result handling now walks the bounded stable fields `error`, `errorCode`,
`detail`, `message`, and `reason`, then uses a fixed fallback. It never calls
`tostring(table)` for a consensus-visible error, so allocator addresses cannot
create cross-peer disagreement.

## Automated evidence

The focused recovery suite covers periodic success, timeout cancellation,
fault-preserving pause, stale-receipt restart, first-checkpoint gating,
interrupted-preparation adoption, post-receipt restart finalization, replayed
resume retirement, strict wire validation, and cancellation after fault. Lua
runtime tests cover the automatic marker, marker persistence into checkpoint
state, deterministic error selection, and ordered cancellation.

Relay tests cover steady-state sampling, immediate critical and nested-channel
transitions, game-log filtering, duplicate suppression, post-accept cursors,
one-shot transfer completion, nested action metadata, and transient-frame
elision. PowerShell tests cover the positive and negative retry allowlists and
credential-scoped failed-Host cleanup. Both repositories' complete automated
suites and the main repository's source-boundary check pass.

No game was launched for this code slice. The remaining evidence gate is a
fresh physical two-computer relay match left running past one automatic
recovery interval, plus one deliberately interrupted pre-authority launch.
