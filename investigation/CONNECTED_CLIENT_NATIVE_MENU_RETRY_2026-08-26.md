# Connected-client native menu retry — 2026-08-26

## Live finding

Relay session `mp-2531696972584b97` reached a verified Player 2 starting-save
bundle and an active Build 35924 hook. The physical **Load Game** click was
delivered to the exact foreground game window, but the native title UI stopped
publishing frames while constructing the Load Game page. No minidump,
Application Error, Application Hang, or spontaneous process exit was recorded.
After the 45-second transition deadline, the launcher intentionally terminated
the still-live partial game so it could not be mistaken for a playable peer.

The bounded replacement attempt then failed for a separate reason. The first
client companion had already connected and received host commit 1, leaving an
inbox file in its bridge. The generic stale-traffic guard correctly rejected
that residue, but the retry wrapper had not retired and rotated its own failed
attempt first. Thus a transient native-menu failure on a connected Join could
never recover, despite the same retry path having been live-proven on a Host
before network history existed.

## Correction

- A narrow native-menu retry now retires the exact failed game, companion,
  staged save, autosave guard, and launcher configuration through the normal
  managed-session stop boundary.
- It verifies the failed session/peer and computed bridge path, then moves the
  complete bridge into a unique `failed-launch-attempts` evidence directory.
  First-attempt state, logs, click receipts, and ordered traffic remain
  available for support analysis rather than being deleted.
- The active bridge path is recreated empty by attempt two. The replacement
  client reconnects with its normal last-commit cursor and receives ordered
  host history through the existing replay protocol.
- The outer authenticated relay tunnel and startup diagnostic reporter remain
  alive. Cleanup is scoped to the inner failed game/companion boundary; an
  unrelated session or credential cannot be terminated.
- Fingerprint, authority, protocol, stale-traffic, and convergence faults remain
  non-retryable. At most one replacement process is launched.

## Automated proof

The regression creates a failed Player 2 state whose bridge already contains
both host commit 1 and a local intent. It proves that cleanup:

1. requests exact managed game/companion teardown;
2. preserves the first attempt's state, logs, menu evidence, inbox, and outbox;
3. leaves an unrelated bridge untouched; and
4. permits a replacement bridge with zero stale traffic, ready for host replay.

The complete repository suite passes, including 202 Python tests, all Lua
runtime/integration/parity suites, release dependency validation, launcher
update/install flows, source boundaries, and PowerShell parsing.

## Remaining live gate

Install `0.40.9-alpha` on both PCs and Join a fresh relay room. If Build 35924's
native save manager transitions normally, Player 2 should load on attempt one.
If it repeats the intermittent stall, the launcher should visibly archive the
first attempt, start one replacement game, reconnect to the same room, replay
the host history, and reach `joined-world-ready` without asking for a new code.
