# TPF2MP 0.40.2-alpha

This hotfix closes the repeatable Relay Join launcher race in which clicking
the in-game **MULTIPLAYER** entry could appear to do nothing. It also moves
bounded relay diagnostics into the startup window and makes failed relay
process cleanup complete. It remains compatible with state schema 31 and does
not change the network, checkpoint, proposal, operation, passenger, cargo, or
freight schemas.

## Reliable Multiplayer handoff

- The launcher now accepts the durable `menu-entry-selected` receipt when a
  player clicks **MULTIPLAYER** between readiness polls and the game has already
  advanced from `main-menu` to `ready-to-click-load-game`.
- A valid early click continues directly into the pinned Load Game flow instead
  of waiting 120 seconds for a menu stage that can no longer reappear.
- A regression test reproduces the exact observed state transition and proves
  the launcher resumes it successfully.

## Startup diagnostics and cleanup

- Redacted relay diagnostics now start before the synchronous game launcher
  reaches world-ready, so menu/bootstrap and companion startup failures are
  available under the relay support ID instead of disappearing before the
  reporter starts.
- After world-ready, the bounded startup reporter hands off to the full live
  reporter with game, native-hook, companion, menu, recovery, and relay status.
- Failed launches now verify and stop both the packaged-process supervisor and
  its service child for diagnostics and relay tunnels. This prevents an orphan
  process from retaining a loopback port and breaking the next fresh session.
- Invalid or timed-out diagnostic startup is also self-cleaning and covered by
  a process-lifecycle regression test.

## Verification

- The complete source suite, cross-language checkpoint replay, and deterministic
  1,024-event replay pass.
- All 167 Lua files and 72 PowerShell tool files pass syntax validation.
- Source-size boundaries, package manifests, update behavior, transactional
  installation, and rollback checks pass.

Both players must install 0.40.2-alpha before creating or resuming a match.
