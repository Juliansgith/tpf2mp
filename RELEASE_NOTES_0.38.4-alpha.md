# TPF2MP 0.38.4-alpha

This small follow-up release fixes the launcher's false **Task failed** result
after an otherwise successful self-update. It contains the full gameplay,
performance, construction, and launcher improvements from `0.38.3-alpha`.

## Launcher result hardening

- The launcher now waits for the hidden updater process to finish completely
  before reading its exit code.
- Worker names and terminal exit results are recorded in the launcher log, so
  future background-task failures are directly diagnosable.
- If Windows reports a nonzero updater exit after the updater printed its final
  success marker, the launcher no longer trusts that text by itself. It checks
  that stderr is empty, validates the installed `current.json` pointer, confines
  the bundle to the version store, verifies every packaged file against the
  release manifest, and requires a clean format-2 manifest for the exact
  reported version. Only then does it show **Update installed and verified**.
- Missing output, stderr residue, a mismatched pointer, an out-of-store bundle,
  dirty source metadata, or any manifest/hash failure remains a hard task
  failure.

## Verification

- The exact `0.38.2-alpha -> 0.38.3-alpha` updater branch was reproduced under
  the same hidden `Start-Process` wrapper and independently returned exit `0`.
- New regression cases cover verified success, stderr rejection, and installed
  version mismatch rejection.
- The multiplayer launcher construction smoke test passes.

## Updating

Close every Transport Fever 2 instance, then use **CHECK / INSTALL UPDATE** in
the multiplayer launcher or run `%LOCALAPPDATA%\TPF2MP\UPDATE_TPF2MP.cmd`.
