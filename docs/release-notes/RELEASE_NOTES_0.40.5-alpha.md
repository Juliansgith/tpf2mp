# TPF2MP 0.40.5-alpha

This hotfix makes a launcher-managed multiplayer match one owned process group
instead of a collection of detached helpers. Closing the game or launcher now
cleans up the complete session, and a new launch can safely replace a verified
older TPF2MP match. It retains state schema 31 and changes no gameplay,
checkpoint, proposal, operation, passenger, cargo, freight, relay-wire, or
native-hook protocol.

## Complete lifecycle ownership

- Every GUI launch records the launcher's and game's exact PID, executable, and
  process start time and starts a hidden lifecycle supervisor.
- Closing Transport Fever 2 tears down that session's companion, relay tunnel,
  diagnostics, menu/recovery helpers, bridge profile, and autosave guard.
- Closing the launcher performs the same teardown and also closes its exact game.
- **Stop session** now ends both the session and game instead of leaving the game
  and detached helpers alive.
- Starting Host or Join reclaims a prior TPF2MP port/autosave owner only after
  its role, session state, process command line, executable, PID, and start time
  verify. A missing or mismatched identity fails closed and no unknown process
  is terminated.
- Autosave settings are restored synchronously after the exact game is gone;
  a verified stuck guard watcher is bounded and cleaned rather than retaining a
  permanent machine-wide lease.

## Regression coverage

- A launcher-exit subprocess test proves complete teardown is requested.
- A game-exit subprocess test proves detached helpers are reclaimed without
  trying to kill an already-closed game.
- A prior active autosave-guard owner is replaced only through its exact saved
  session identity.
- The real stop path terminates a verified fake companion and writes a terminal
  reasoned session receipt.
- The complete Lua/model/native/launcher/relay/save-sync/recovery suite passes:
  168 packaged Lua files, 74 PowerShell files, 197 Python tests, deterministic
  1,024-event replay, and transactional install/update checks.

Both players must install `0.40.5-alpha`. Keep the launcher open while playing;
closing it is intentionally equivalent to **Stop session**.
