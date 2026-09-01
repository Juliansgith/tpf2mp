# TPF2MP 0.40.8-alpha

This maintenance release makes quitting a relay match reliably release every
TPF2MP helper, including after a fault or failed launch. Save state remains
schema 32, checkpoint format 5, economy model 10, and native hook 0.19.0.

## Relay lifecycle cleanup

- Closing the exact Transport Fever 2 process now tears down its companion,
  relay tunnel, diagnostics, watchers, and autosave lease even when the match
  had previously entered recoverable `failed` state.
- Relay diagnostic and tunnel cleanup no longer trusts only the two PIDs seen
  at startup. It discovers every process matching the exact installed
  executable, relay command, and private credential path, stops PyInstaller's
  supervisor before its child, and rescans through the bounded handoff window.
- Failed Host/Join launch cleanup and the explicit **Stop session** path use the
  same rule. An unpublished, replaced, or re-parented child can no longer keep
  the updater blocked after the game and launcher are closed.
- Process cleanup remains fail-closed: a different executable, command, or
  credential is never terminated.

## Verification

- A regression starts duplicate diagnostic workers on one credential and a
  control worker on another. One stop removes both matching workers and leaves
  the control worker untouched.
- A lifecycle regression starts an already-faulted session and proves the
  watcher remains alive until the exact game exits and requests normal helper
  teardown.
- The complete repository suite passes, including Lua/Python deterministic
  parity, protocol/consensus integration, launcher/update/install flows,
  source boundaries, and PowerShell syntax.

Both players must install `0.40.8-alpha`; mixed versions are unsupported.
