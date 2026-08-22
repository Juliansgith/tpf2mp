# Duplicate match-bootstrap fault

Date: 2026-08-22 (Europe/Amsterdam)

Affected release: `0.38.4-alpha`

Fixed release: `0.38.5-alpha`

## Live finding

Session `match-20260822-1614` did not fail during its real bootstrap. Player 1
automatically emitted `match.initialise` as local sequence 13 at tick 240. It
committed as authority sequence 3 on both peers, the `match-initialised`
checkpoint converged, and the freight-industry bootstrap and its checkpoint
also converged.

At tick 426, Player 1 emitted a second `match.initialise` as local sequence 55.
Both peers deterministically rejected authority sequence 7 with `match is
already initialised`. The host correctly converted that generic ordered-action
rejection into `network.sync_fault` sequence 8. The panel's later
`checkpoint-consensus-timeout:player1,player2` was a downstream symptom of
that already-faulted boundary, not the first failure.

The automatic fault watcher preserved the exact evidence under:

`%LOCALAPPDATA%\TPF2MP\sessions\match-20260822-1614\player1\fault-evidence\20260822-141647-758-attempt-1`

## Root cause

Launcher-managed network worlds already initialize automatically once both
authority gates and the peer connection are ready. The diagnostic panel still
showed an active **Initialise Match** button and described a missing company as
`Active: not initialised`. A user could therefore submit a second lifecycle
command after successful automatic setup. The companion quite reasonably
treated the ordered rejection as fatal because generic rejected authored
commands are not safe to ignore.

## Fix

The lifecycle is now defended at three boundaries:

- launcher-managed network panels no longer expose a manual Initialize action;
  they state that setup starts automatically after both peers connect;
- a stale GUI, script event, or automation retry after initialization is
  acknowledged locally as `alreadyInitialized` without receiving a bridge
  sequence;
- an older client that nevertheless places a duplicate in the ordered stream
  receives the same successful no-op on every peer. That no-op is audited but
  does not open another checkpoint barrier.

The header now reports `Match: waiting for peer`, `Match: starting
automatically`, or `Match: ready` separately from `Company: ...`, so company
assignment cannot be mistaken for a lifecycle instruction.

## Verification

The game-script harness reproduces both failure paths. A post-bootstrap local
submission leaves `nextOutSeq` unchanged, and a synthetic older-client commit
at authority sequence 6 succeeds on both the event and consensus boundaries
without increasing checkpoint exports. The focused runtime test also proves
zero bridge emissions, no awaiting-order latch, a clean published result, and
an explicit diagnostic record.

The complete repository gate passes: 137 Lua model tests, transport/parity and
256-step freight stress checks, game/GUI/hot-seat/network integration, all
release/install/recovery PowerShell gates, 1,024-event replay, and 181 Python
protocol/consensus/recovery tests.

The already-faulted `0.38.4-alpha` session remains intentionally unrecoverable;
the fix applies to fresh sessions under `0.38.5-alpha`.
