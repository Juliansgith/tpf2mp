# TPF2MP 0.38.8-alpha

This release contains the corrections found during the first ordinary
two-computer TPF2MP session over Tailscale.

## Compound station construction

- Stations that must demolish town buildings no longer enter the unproven
  exact typed-construction path that Build 35924 rejected on both peers.
- Compound builds use the established staged helper: retire canonical
  collateral, wait for disappearance, replay the captured absolute transform,
  verify the generated graph, settle finance, and checkpoint.
- Isolated stations and other isolated fresh constructions retain the faster
  exact `BuildProposal` path.

## Native save finalization

- Failed construction proposals now release their complete pre-build native
  component snapshot as soon as the result becomes terminal.
- The game-script save boundary performs an idempotent retention sweep, which
  also repairs terminal scratch inherited from an older in-memory state.
- Active construction scratch is preserved so an autosave cannot silently make
  an in-flight replay non-resumable.
- Terminal records keep their signed transaction, result, completion payload,
  hashes, and consensus identity; only runtime-only world snapshots are removed.

## Cross-computer evidence and verification

- The original cross-PC audit remained consensus-safe: 31 commits, five
  completed and two identically rejected physical proposals, nine completed
  checkpoint barriers, and no faulted or pending physical/checkpoint work.
- Regression coverage distinguishes isolated exact replay from collateral
  helper replay and exercises immediate failure cleanup plus direct native-save
  compaction.
- The complete automated gate passes: 137 Lua core cases, seven transport-
  network cases, three alpha-readiness cases, 181 Python cases, cross-language
  parity/stress, syntax and architecture gates, recovery, installer/updater,
  packaging, and the 1,024-event replay.

## Honest live boundary

The failed-session diagnosis and correction are code- and evidence-backed, but
the new compound-station and save-finalization paths still require a fresh
two-computer live acceptance run. The incomplete historical `.sav` cannot be
used as a multiplayer restore because its load-bearing `.sav.lua` never
finalized.

## Updating

Close every Transport Fever 2 instance on both computers. Use **CHECK / INSTALL
UPDATE** in the multiplayer launcher or run
`%LOCALAPPDATA%\TPF2MP\UPDATE_TPF2MP.cmd`, verify both machines report
`0.38.8-alpha`, and start a fresh session.
