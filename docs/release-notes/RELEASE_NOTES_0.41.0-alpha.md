# TPF2MP 0.41.0-alpha

This release restores vanilla construction parity for topology edits that
deliberately demolish buildings and repairs signal/waypoint capture after the
semantic build-correlation hardening. Save state remains schema 32, checkpoint
format 5, economy model 10, and native hook 0.19.0.

## Atomic collateral demolition

- A road or track edit through a building is still one native transaction. The
  replay no longer rejects the vanilla GUI's intended collateral `Collision`
  merely because the multiplayer path previously forced strict proposal mode.
- Error tolerance is enabled only for schema-7 topology edits that explicitly
  carry canonical construction removals. Ordinary roads, tracks, stations,
  depots, signals, waypoints, and constructions remain strict.
- Every local construction id is resolved before mutation, assigned through
  the generated native whole-vector setter, and read back exactly.
- The processed `BuildProposal` is verified a second time before its one-shot
  native authorization. A missing, duplicated, or changed removal fails before
  submission, so demolition can never become a separate half-applied command.

## Signal and waypoint capture

- Build 35924 exposes its stock signal/waypoint tool as
  `streetTerminalBuilder`. The correlation guard no longer mistakes that name
  for a station-only source and reject its valid edge-object payload as a stale
  preview.
- Only that live-proven dual-use terminal builder admits edge objects. Generic
  construction, station, depot, and asset builders remain construction-only.
- Moving a signal ghost no longer emits a frame-by-frame correlation rejection
  storm; signal and waypoint clicks can enter the ordinary ordered proposal
  path again.

## Verification

- New regressions prove exact construction-removal round trips, silent native
  vector-write rejection, processed-command integrity, strict clean builds,
  the exact `streetTerminalBuilder` source/family pair, and the real network GUI
  preview path.
- The code and protocol gates pass: 140 Lua tests, 7 transport-network tests,
  3 alpha-readiness tests, all economy/freight cross-language parity and stress
  vectors, Python/launcher tests, source boundaries, and PowerShell syntax.
- The packaged-install round trip was intentionally deferred while a live
  0.40.9 session remained open; its active-session guard correctly refused to
  overwrite the running companion. The release bundle is still independently
  manifest- and checksum-verified before publication.

Both players must install `0.41.0-alpha`; mixed versions are unsupported. A
running game cannot hot-load these Lua changes, so use a fresh session after
updating.
