# TPF2MP alpha release checklist

This is the release definition for the restricted trusted-LAN two-player
alpha. A feature is not accepted because it looked correct once: the final
report must prove every required item from converged all-peer checkpoints.

## Automated code gate

Run from the repository root:

```powershell
.\tools\run_tests.ps1
.\tools\package_release.ps1 -Version 0.38.6-alpha
```

The gate covers Lua/Python deterministic parity, proposal and operation codecs,
ownership, finance, transport conservation, reconnect backlog replay, recovery
plan integrity, launcher construction, native-hook signatures/build, release
manifest checks, and a transactional clean install/uninstall.

## Clean-machine gate

On both test computers:

1. Remove any older TPF2MP install with its bundled uninstaller.
2. Install the ZIP on a supported Steam layout without repository tools or
   Python installed.
3. Run `VERIFY_TPF2MP.cmd` and require the exact Build 35924 hook profile.
4. Start through `LAUNCH_TPF2MP.cmd`; require the title-screen Multiplayer
   entry and an in-game `READY` Alpha Status.

## Full live-alpha scenario

Use one fresh, flat, populated save and leave physical town development on.

1. Build private road/rail infrastructure, a station, depot, signal, line, and
   at least two assigned vehicles. Exercise one line edit and one vehicle
   lifecycle command. Verify rival private edits are rejected.
2. Operate `A-B` and `B-C` passenger services through the exact same station
   group at B. Require a multi-line passenger route and at least one automatic
   five-minute settlement.
3. Create a cargo source-to-hub line without a consumer. Require zero authored
   demand. Add a hub-to-compatible-consumer line, then require cargo to arrive
   at hub stock and later board the downstream vehicle without creation or
   duplication.
4. Allow at least one ordered `town.develop` batch and three all-peer
   checkpoints. Keep both worlds running long enough to revisit several
   station barriers.
5. Disconnect Player 2's companion while the games stay open. Require an
   immediate pause, reconnect within 120 seconds, complete backlog replay, no
   timeout, and a clean manual resume.
6. Prepare one restore point. Require both peer receipts, a current v6 plan,
   and successful peer-specific reload. Confirm cargo inventory, active loads,
   finances, routes, canonical identities, and vehicle rounds survive, then
   complete a fresh post-restore checkpoint.

Collect evidence on each computer:

```powershell
.\tools\collect_live_evidence.ps1 -Session <name> -Peer player1 -OutputDirectory C:\evidence\host
.\tools\collect_live_evidence.ps1 -Session <name> -Peer player2 -OutputDirectory C:\evidence\client
```

Copy the client directory to the host and run:

```powershell
.\tools\analyze_alpha_live_evidence.ps1 `
  -EvidenceDirectory C:\evidence\host `
  -ClientEvidenceDirectory C:\evidence\client `
  -Profile alpha
```

The machine report must pass all of these: no fault; no pending work or missing
acknowledgement; at least three converged checkpoints; synchronized peer
status; successful physical construction and operation; running economy; at
least two synchronized vehicles; town development; passenger transfer route;
complete cargo transfer route; cargo arrival and onward boarding; recovered
reconnect without timeout; and a matching current receipt-bound restore plan.

## Explicit alpha limits

Do not advertise this build for public Internet play, untrusted opponents,
arbitrary executable mods, host migration, more than two players, another game
build, or automatic repair after native-world divergence. Those are later
product gates, not hidden alpha promises.
