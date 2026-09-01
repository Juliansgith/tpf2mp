# TPF2MP 0.40.0-alpha

This is the secure-relay alpha milestone. It combines outbound-only Internet
multiplayer, automatic starting-save delivery, centralized privacy-bounded
diagnostics, launcher/update hardening, and the native-autosave guard proven
necessary by the first physical two-computer relay session. It does not change
state schema 31 or any network/checkpoint payload version.

## Secure relay and save delivery

- The launcher enables **Use secure relay** by default. Host creates a
  short-lived room and shares one opaque join code; neither player exposes a
  game or save-transfer port.
- Gameplay and starting-save bytes use separate authenticated TLS channels.
  Host remains the sole commit-ordering authority and the relay never
  simulates gameplay.
- Host pins `.sav`, `.sav.lua`, and optional `.jpg`; Join receives and verifies
  the immutable bundle before world launch. Installation is transactional and
  never exposes a partially transferred save.
- Both roles upload only bounded, redacted status and diagnostic sources under
  one non-secret support ID. Credentials, invite codes, command payloads, save
  contents, local paths, and addresses are excluded or redacted.

## Launcher and readiness reliability

- First install can create a stable desktop shortcut. Opening the launcher
  checks for updates without blocking, and a verified update restarts directly
  into the newly installed launcher.
- Live updater logs tolerate normal Windows sharing locks instead of raising a
  WinForms exception while the updater is still writing.
- Automatic match initialization waits for matching content attestations from
  both live worlds and the first converged checkpoint. A companion socket alone
  can no longer produce a false `ready` state.
- Durable relay receipts remain authoritative when Windows reports a blank
  short-lived worker exit code.

## Native autosave guard

- Launcher-managed network games temporarily raise
  `autosaveIntervalMinutes` to at least 10,080 minutes before the exact game
  process starts.
- A current-user lease binds the change to the session, peer, executable, PID,
  and process start time. A hidden watcher restores the player's prior interval
  after that exact process exits while preserving every other setting.
- Crashed/stale launch leases repair on the next launch. A live lease refuses a
  second network game under the same Windows profile, and an explicit external
  settings change is never overwritten during cleanup.
- The launcher reports when stock autosaves are suspended and distinguishes
  them from coordinated READY-boundary recovery saves.

## Why

Relay session `mp-82a4b6ad61de51f8` proved that player 2 began a native
autosave in the same second it received a station proposal. The relay and both
companions remained connected, but Transport Fever 2 spent 256,781 ms saving;
the host's 45-second physical-completion deadline therefore faulted correctly.
The 53,532,582-byte save eventually completed, too late for that session.

The full autosave timeline and next live gate are in
`../../investigation/RELAY_AUTOSAVE_PROPOSAL_TIMEOUT_2026-08-24.md`.

## Verification state

- The complete source suite passes: 137 Lua tests, 197 Python tests, all
  transport-network and cross-language economy/freight parity vectors, 167 Lua
  syntax files, and 70 PowerShell syntax files.
- Exact-process autosave restoration, stale-process repair, external-change
  preservation, release-manifest/transitive-tool coverage, launcher/updater
  behavior, and recovery/install transaction tests pass.
- Publication additionally rebuilds the exact-build native hook and companion,
  verifies every packaged hash, and performs a temporary
  install/verify/uninstall round trip.

Both players must update to the same release before creating the next room.
