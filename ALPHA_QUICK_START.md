# TPF2MP playable-alpha quick start

TPF2MP `0.38.0-alpha` is a restricted two-player competitive build for the
Windows x64 Transport Fever 2 Build 35924. It is intended for two people who
trust each other and connect over a LAN or private VPN. It is not safe public
Internet multiplayer and it does not support host migration.

## Before the first match

Both computers need:

- the exact supported game executable;
- the same TPF2MP release;
- byte-identical starting `.sav` and `.sav.lua` files;
- identical enabled game content and data-only mods;
- TCP port `29742` reachable from Player 2 to Player 1.

Install the release on both computers by double-clicking
`INSTALL_TPF2MP.cmd`, or from PowerShell:

```powershell
powershell -ExecutionPolicy Bypass -File .\tools\install_release.ps1
powershell -ExecutionPolicy Bypass -File .\tools\verify_install.ps1 -StrictNative
```

A normal install creates a `TPF2MP Multiplayer` desktop shortcut plus stable
Launch and Update commands under `%LOCALAPPDATA%\TPF2MP`. The launcher also has
a **CHECK / INSTALL UPDATE** button. Private-repository updates use each
tester's own GitHub authorization; no shared token or deploy key is shipped.
See [DISTRIBUTION_AND_UPDATES.md](DISTRIBUTION_AND_UPDATES.md).

## Start a match

1. Open `TPF2MP Multiplayer` (or `LAUNCH_TPF2MP.cmd`) on both computers.
2. Enter the same session name, port, and starting save.
3. Player 1 clicks **HOST + LAUNCH GAME** and gives Player 2 the host's LAN or
   VPN address.
4. Player 2 enters that address and clicks **JOIN + LAUNCH GAME**.
5. In each game's title screen, click **MULTIPLAYER**. Do not load the save
   through the ordinary Load Game button.
6. Open the in-game Multiplayer panel and select **Alpha Status**. Begin only
   after both games say `READY` and show no blocker.

Each peer has its own company, wallet, assets, lines, and vehicles. Roads may
connect to public roads; private rival track, stations, depots, constructions,
lines, and vehicles remain protected. Construction and ordinary line/vehicle
commands are ordered by Player 1 and replayed on both worlds before money or a
checkpoint commits.

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

Executable mod callbacks, arbitrary script commands, hostile peers, encrypted
transport, host migration, and in-place repair of already-divergent geometry
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
