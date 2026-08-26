# TPF2MP 0.40.9-alpha

This maintenance release makes Player 2's automatic replacement launch work
after Transport Fever 2's native Load Game manager intermittently stalls.
Save state remains schema 32, checkpoint format 5, economy model 10, and native
hook 0.19.0.

## Connected Join recovery

- The reported `mp-2531696972584b97` failure was not a corrupt synchronized
  save or a native crash. The game remained alive after the exact Load Game
  click; the launcher closed it at its fail-closed page-transition deadline.
- A connected Join can already have ordered host traffic before the world
  opens. The replacement attempt no longer mistakes traffic from its own first
  attempt for an unrelated stale session.
- Before retrying, the launcher now retires the exact failed game/companion,
  staged save, autosave guard, and launcher configuration, then reconnects the
  replacement client to the same relay room for normal ordered-history replay.
- The entire first-attempt bridge, state, logs, and native-menu click evidence
  are archived under that session's `failed-launch-attempts` directory. Nothing
  is silently deleted, and unrelated session bridges remain untouched.
- The authenticated outer relay tunnel stays active across the bounded retry.
  Fingerprint, authority, protocol, convergence, and foreign stale-traffic
  failures remain non-retryable.

## Verification

- A new regression starts from a failed Player 2 bridge containing host commit
  1 and a local intent, then proves exact teardown, evidence preservation,
  unrelated-session isolation, and a clean replacement bridge.
- The complete repository suite passes: all Lua integration and deterministic
  parity suites, 202 Python tests, launcher lifecycle/update/install checks,
  release dependency validation, source boundaries, and PowerShell syntax.

Both players must install `0.40.9-alpha`; mixed versions are unsupported.
