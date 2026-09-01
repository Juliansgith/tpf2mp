# TPF2MP 0.39.3-alpha

This launcher hotfix keeps the `0.39` network protocol and state schema 31
unchanged.

## Safe in-app update progress

- The launcher now treats an updater stdout/stderr file held exclusively by
  the still-running updater as a transient progress state instead of allowing
  the WinForms timer callback to raise an unhandled exception.
- Live log polling uses a read/write/delete-sharing handle when the writer
  permits it. If the writer temporarily denies sharing, that polling tick is
  skipped and the complete log is flushed after process exit.
- Update installation, manifest verification, and automatic launcher restart
  remain unchanged and fail closed.

The issue was reproduced from the 0.39.1 to 0.39.2 in-app update. That update
itself completed correctly; only the old launcher's live-log viewer failed.
