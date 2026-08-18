# TPF2MP 0.38.1-alpha

This is the first updater-distributed build of the restricted TPF2MP trusted-LAN alpha.

## Included

- Two-player Host/Join launcher flow with the in-game Multiplayer entry.
- Ordered, checkpointed replication for supported construction, ownership, lines, vehicles, stations, signals, depots, scenery, and demolition.
- Separate company finances and ownership enforcement.
- Replicated train buying, assignment, operation, station-leg synchronization, shared pause/speed control, and bounded reconnect replay.
- Authoritative passenger and multi-hop freight models with native UI projection, save-owned economy difficulty, feeder access, town development, and cargo conservation.
- Receipt-bound coordinated recovery points and restore-plan verification.
- Rollback-safe installer, verifier, uninstaller, and GitHub Release updater.

## Installation and updating

Download `TPF2MP-0.38.1-alpha.zip`, extract it, and run `INSTALL_TPF2MP.cmd`.
Existing `0.38.0-alpha` installations can use `UPDATE_TPF2MP.cmd` or **CHECK / INSTALL UPDATE** in the launcher. Because the repository is private, the tester must already have GitHub access through Git Credential Manager, `gh`, or a personal environment token.

## Supported profile and limits

- Windows x64 Transport Fever 2 Build 35924 only.
- Two trusted players over LAN or a private VPN; this is not hardened public-Internet multiplayer.
- Both peers need byte-identical starting saves and loaded content.
- Host migration and arbitrary mod compatibility are not supported.
- The final physical two-computer alpha acceptance run remains the release-quality proof gate; this prerelease is intended to make that test installable and repeatable.

Read `ALPHA_QUICK_START.md` and `ALPHA_RELEASE_CHECKLIST.md` before testing.
