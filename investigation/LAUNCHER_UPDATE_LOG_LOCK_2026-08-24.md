# Launcher update log lock (2026-08-24)

## Live finding

The in-app update from `0.39.1-alpha` to `0.39.2-alpha` installed and verified
successfully, then the old launcher's WinForms timer raised an unhandled
`IOException`. Its progress callback called `File.ReadAllText` while the
updater still held the redirected stdout file exclusively.

The installed `current.json`, completed stdout, signed release manifest, and
automatic follow-up check all confirmed `0.39.2-alpha`; no installation state
was lost.

## Fix and invariant

Launcher progress logs are advisory. A writer-owned file must therefore be
treated as temporarily unavailable, never as an application error and never
as proof of success. The polling helper requests read/write/delete sharing,
returns no snapshot when the writer denies access, and lets the next 500 ms
tick retry. The updater process exit plus signed installed-release receipt
remain authoritative.

`run_launcher_qol_tests.ps1` holds a real exclusive file handle to reproduce
the Windows sharing violation, verifies the read is skipped, then verifies the
same log becomes readable after release.
