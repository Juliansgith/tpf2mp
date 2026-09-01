# TPF2MP 0.43.1-alpha

This patch release fixes TPF2MP remaining active in ordinary Transport Fever 2
games after the mod was disabled or uninstalled. Gameplay and protocol schema
versions are unchanged from `0.43.0-alpha`.

## Runtime isolation

- The base-game runtime overlay now remains inert unless the normal mod is
  explicitly selected, an authenticated launcher session supplies a complete
  peer/session/bridge identity, or a disposable validator explicitly opts in.
- Orphaned menu and localhost bootstrap scripts no longer initialize outside a
  valid launcher-owned multiplayer process.
- An incomplete or stale launcher environment fails closed instead of
  activating only part of the multiplayer runtime.

## Cleanup and recovery

- Stop-session, failed-launch, localhost-validation, update, install, and
  uninstall paths now archive the four managed base-game overlay targets after
  the last Transport Fever 2 process exits.
- Uninstall repairs affected older installations even when the ordinary
  `tpf2_mp_1` mod directory has already been removed.
- Cleanup recognizes bounded legacy TPF2MP overlays, refuses unknown or
  foreign files, records an `overlay-cleanup.json` receipt, and rolls moved
  items back if archival fails partway through.
- Release packages now include the shared cleanup implementation and the
  standalone cleanup command.

## Regression coverage

- New isolation tests reproduce an unselected/orphaned global game script and
  prove that it performs no runtime work.
- New uninstall tests reproduce the exact missing-mod/stale-overlay failure,
  verify archival of all managed targets, and prove foreign files are retained.
- Launcher lifecycle and release-install tests cover final-session cleanup and
  historical positional installer compatibility.
- The complete automated gate passes: 154 Lua tests, 7 transport-network tests,
  227 Python tests, 215 mod Lua syntax files, 10 investigation Lua syntax files,
  and 82 PowerShell syntax files.

## Supported boundary

This remains a trusted two-player Windows x64 alpha for exact Transport Fever 2
Build 35924. Both players must install `0.43.1-alpha`; mixed versions are
unsupported. Start a fresh multiplayer session after updating.
