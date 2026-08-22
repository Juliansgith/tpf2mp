# Launcher retry and orphan cleanup — 2026-08-20

## Outcome

The public localhost launcher flow now completes unattended from two title
screens through two loaded, connected worlds.  The accepted run was:

- session: `launcher-e2e-20260820-231144`
- starting save: `TFPM_ALPHA_STARTER.sav`
- Host: `hosting-world-ready`
- Join: `joined-world-ready`
- matching fingerprint: `d06091fba47229b1c72183694ee9f9dafa332189895c9b2894c5003ea7ca3c2b`
- native hook, BuildProposal gate, and command-visitor gates: active on both
- host connected peers: `player2`
- client connected and synchronized: true
- session faults: none
- cleanup: both games stopped and TCP 29742 unowned

The machine-readable receipt is
`runtime/launcher-e2e/launcher-e2e-20260820-231144/result.json`.

## Failures reproduced

The original user attempt exposed three independent faults.

1. `match-20260820-2237/player2` reached the exact title entry and physically
   clicked Load Game, but Build 35924's native Load Game manager stopped
   transitioning.  This is the intermittent native-manager hang already seen
   by the restore acceptance harness.
2. Closing that attempt left the Host companion (PID 33672) listening on TCP
   29742.  A later `match-20260820-2241/player2` connected to that wrong old
   host and was rejected for its session mismatch.
3. Retrying the same role/session/save then failed before launch because the
   safe pinned copy already existed.  The pin operation was fail-closed but not
   idempotent.

The new automated run reproduced the native menu hang on its first P1 game
process.  The bounded retry retired that exact process, verified and reused the
identical pinned save, launched a replacement process, and loaded it
successfully.  This is live evidence for the retry path, not only a unit test.

A later acceptance attempt exposed a fourth launcher issue: status polling and
the launcher's direct `Set-Content` could contend for `session-state.json`.
Player 2 had already loaded and passed paused-network wake, but the final state
publication failed with a sharing violation.  Session state now uses
same-directory atomic replacement with bounded retry, and readers explicitly
share read/write/delete access.

## Corrections and invariants

- Exact role/session/save retries reuse a pin only when every expected sidecar
  exists and every SHA-256 matches.  Partial, unexpected, or different residue
  is still rejected.
- The native Load Game page transition has a 45-second sub-deadline instead of
  consuming the entire world-load timeout.
- Host and Join buttons use a two-attempt wrapper only for the narrow native
  menu failure class.  Fingerprint, authority, stale-traffic, and convergence
  errors are never retried as if transient.
- A Host refuses an occupied TCP port and identifies a TPF2MP owner when
  possible.  A localhost Join refuses a listener belonging to another session.
- When the exact recorded game exits, its recovery watcher retires the exact
  companion.  It does not kill an unverified PID or another session.
- Session-state publication is atomic and reader-safe; polling cannot corrupt
  or block the readiness handoff.
- `run_launcher_end_to_end.ps1` recreates the real user sequence, follows a
  replacement game PID across a bounded retry, verifies both native authority
  surfaces and network convergence, writes a receipt, and performs exact
  cleanup by default.

## Verification

- PowerShell parser checks passed for every changed launcher/recovery script.
- Source-boundary checks passed.
- Exact pin reuse, differing residue, incomplete residue, occupied port, and
  atomic state publication are regression-covered by `tools/run_tests.ps1`.
- The complete project test suite passed before the live run; it is rerun after
  the final atomic-publication correction.
- Live end-to-end acceptance passed and left zero `TransportFever2` processes
  and zero listeners on TCP 29742.
