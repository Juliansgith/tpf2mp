# TPF2MP playable-alpha quick start

TPF2MP `0.40.5-alpha` is a restricted two-player competitive build for the
Windows x64 Transport Fever 2 Build 35924. It is intended for two people who
trust each other. Its preferred transport is the TPF2MP secure relay: both
players make outbound WSS connections, so neither player opens a port. Direct
LAN/private-VPN mode remains available. It does not support hostile peers or
host migration.

## Before the first match

Both computers need:

- the exact supported game executable;
- the same TPF2MP release;
- one complete starting save on Host (`.sav`, `.sav.lua`, and optional `.jpg`);
- identical enabled game content and data-only mods; and
- outbound HTTPS/WebSocket access to the configured TPF2MP relay.

Join does not need the starting save and neither player needs port forwarding.
If **Use secure relay** is turned off for direct LAN/VPN mode, TCP ports `29742`
and `29743` must instead be reachable from Player 2 to Player 1.

Install the release on both computers by double-clicking
`INSTALL_TPF2MP.cmd`, or from PowerShell:

```powershell
powershell -ExecutionPolicy Bypass -File .\tools\install_release.ps1
powershell -ExecutionPolicy Bypass -File .\tools\verify_install.ps1 -StrictNative
```

A normal first install offers a `TPF2MP Multiplayer` desktop shortcut and
creates stable Launch and Update commands under `%LOCALAPPDATA%\TPF2MP`. The
launcher checks for updates when opened, retains a manual update button, and
restarts into a newly verified version after installation. Private-repository updates use each
tester's own GitHub authorization; no shared token or deploy key is shipped.
See [DISTRIBUTION_AND_UPDATES.md](DISTRIBUTION_AND_UPDATES.md).

## Start a match

1. Open `TPF2MP Multiplayer` (or `LAUNCH_TPF2MP.cmd`) on both computers. Keep
   each launcher open for its whole match. Closing it now cleanly ends its exact
   game, companion, relay tunnel, diagnostics, recovery helpers, and autosave
   guard; it never leaves a hidden multiplayer session behind.
2. Leave **Use secure relay** checked. Player 1 selects the starting save and
   clicks **CREATE SESSION**, then **COPY CODE** and sends that opaque code to
   Player 2. The displayed `mp-...` value is the non-secret support ID.
3. Player 2 pastes the code into **Join code** and clicks **PREPARE JOIN**.
   Player 2 leaves the save field empty; the room fixes the session identity.
4. Player 1 clicks **HOST + LAUNCH GAME**. After Host reaches the title screen,
   Player 2 clicks **JOIN + LAUNCH GAME**. Join receives `.sav`, `.sav.lua`, and
   optional `.jpg` through the relay, verifies every SHA-256, installs `.sav`
   last, fingerprints the resulting world, and launches it automatically.
5. In each game's title screen, click **MULTIPLAYER**. Do not load the save
   through the ordinary Load Game button.
6. Open the in-game Multiplayer panel and select **Alpha Status**. Begin only
   after both games say `READY` and show no blocker.

Starting another Host or Join from the launcher replaces a prior verified
TPF2MP session on that computer. It closes only processes whose executable,
PID, start time, role, and session state all match; an unknown process is never
terminated merely because it uses the same port. **Stop session** performs the
same complete teardown immediately.

Each peer has its own company, wallet, assets, lines, and vehicles. Roads may
connect to public roads; private rival track, stations, depots, constructions,
lines, and vehicles remain protected. Construction and ordinary line/vehicle
commands are ordered by Player 1 and replayed on both worlds before money or a
checkpoint commits.

Starting-save sync is for a fresh normal match. It is not used for
receipt-bound restore: each role must load its own attested restore save. The
ordinary match fingerprint independently rejects a changed or incomplete
synchronized copy before gameplay begins.

The relay retains bounded protocol metadata and redacted structured logs from
both clients under the support ID. It does not retain save bytes, command
payloads, raw crash dumps, or arbitrary local files. See
[SECURE_RELAY.md](SECURE_RELAY.md) for the exact privacy and failure boundary.

### Direct LAN/private-VPN fallback

Uncheck **Use secure relay**, then use the earlier Session/Host address/port
fields. Host launches first and reports `SAVE READY:29743`; Join clicks
**SYNC FROM HOST**, then **JOIN + LAUNCH GAME**. Direct mode does not upload
central diagnostics and requires the two inbound Host ports to be reachable.

## If a connection drops

The host pauses immediately and gives the missing peer 120 seconds to
reconnect. Do not build or edit while **Alpha Status** says reconnecting. The
client companion retries automatically, replays every missing ordered commit,
and becomes connected only after catch-up. Once both panels are synchronized,
resume normally. A missed grace period faults the match; use the newest
receipt-bound restore rather than continuing one world alone.

## Saves and recovery

Use **Prepare & Save Restore Point** in the Multiplayer panel. It establishes a
shared paused, quiescent checkpoint and then lets each exact game process save
its own peer-specific world. The launcher exposes **LOAD LATEST RESTORE** after
both receipts form a current restore plan. Never mix peer saves, boundaries,
or plans, and never use a normal autosave as if it were a coordinated restore.

## What this alpha supports

- named vanilla and data-only-mod roads, tracks, bridges, tunnels, signals,
  waypoints, stations, depots, modular edits, and plain constructions;
- ordinary line create/edit/delete, portable vehicle purchase and assignment,
  lifecycle controls, replacement, and bounded multi-sale;
- synchronized speeds, pauses, station departures, passenger/cargo loads,
  five-minute competitive accounting, model-town growth, feeder services,
  passenger connections, and conserved multi-line freight transfers;
- automatic checkpoints, first-fault evidence, and paired recovery saves.

Executable mod callbacks, arbitrary script commands, hostile peers, host
migration, and in-place repair of already-divergent geometry
are outside this alpha. Native people, yellow station icons, income popups, and
mid-leg vehicle coordinates are presentation; the Multiplayer views contain
the authoritative counts and finances.

## Evidence buttons

**CHECK PLAYABLE ALPHA** in the launcher collects both local bridges and fails
unless the session is connected, quiescent, converged, and has exercised real
construction, operations, economy, and vehicles. The stricter release gate is:

```powershell
.\tools\run_alpha_live_acceptance.ps1 -Session <name> -Profile alpha
```

For two physical computers, collect Player 1 and Player 2 evidence separately,
copy the client bundle to the host, then run:

```powershell
.\tools\analyze_alpha_live_evidence.ps1 `
  -EvidenceDirectory C:\evidence\host `
  -ClientEvidenceDirectory C:\evidence\client `
  -Profile alpha
```
