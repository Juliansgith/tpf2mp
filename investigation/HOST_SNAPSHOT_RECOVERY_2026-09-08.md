# Host snapshot recovery validation — 2026-09-08

Implemented explicit host-save takeover; see `docs/HOST_SNAPSHOT_RECOVERY.md`.

## Automated evidence

- Full `tools/run_tests.ps1` gate passed: 162 main Lua tests, runtime-module
  checks, 387 Python tests, launcher checks and replay validation.
- Subsequently added refusal cases for unsupported state versions, unowned
  native residue and ordinary continuation of a faulted save. The runtime
  module suite passed again after correcting the synthetic proposal fixture
  to include its required proposal ID.
- Tests cover loading the same host state under both peer identities,
  retaining accounts and canonical identities, retiring old session work,
  preserving the input object, and seeding vehicle authorization round cursors
  once from the agreed continuation checkpoint.

## Native attempt: blocked before world load

Run: `runtime/localhost-live/host-takeover-20260908/run-status.json`.
The disposable fixture in `runtime/host-snapshot-fixture-20260908` copies a
real host native save and injects persisted proposal/operation faults plus
pending work into its copied metadata. Original archives were not modified.
This is a synthetic saved-state fault, not an induced native-operation fault.

Both game instances reached the main menu, but Windows foreground activation
failed and background-click retries did not open Load Game. The harness
exited unsuccessfully and cleaned up its two disposable game processes and
companions. No world loaded, so this attempt proves neither successful
takeover nor a recovery defect. An interactive desktop is needed to rerun.

Native takeover, subsequent save/reload, and moving-vehicle recovery are not
yet qualified by this attempt. Earlier ordinary save/load evidence does not
substitute for those checks.
