# TPF2MP alpha release checklist

This is the release definition for the restricted trusted-peer two-player
alpha over secure relay or direct LAN/VPN. A feature is not accepted because
it looked correct once: the final report must prove every required item from
converged all-peer checkpoints.

## Automated code gate

Run from the repository root:

```powershell
.\tools\run_tests.ps1
.\tools\package_release.ps1 -Version 0.43.0-alpha
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
5. With relay enabled, create a room on P1, prepare the opaque code on P2, and
   require automatic save delivery without an inbound player port. Record the
   common support ID and verify the server timeline contains both roles but no
   credentials, local user paths, raw payloads, save bytes, or dumps.

## Full live-alpha scenario

Use one fresh, flat, populated save and leave physical town development on.

1. Before building, compare both peers at the same camera. Hold and move a
   station ghost for ten seconds, then a bulldozer ghost for ten seconds. The
   issuer may remain slower because it runs native collision/terrain preview,
   but must not show the former sustained single-digit multiplayer collapse.
   Click once and require exactly one replicated result.
2. Build private road/rail infrastructure, two sequential rail stations, a
   depot, signal, line, and
   at least two assigned vehicles. Exercise one line edit and one vehicle
   lifecycle command. Verify rival private edits are rejected. In a disposable
   area, explicitly run station -> bulldoze -> long track, construction ->
   Escape/cancel -> road, rejection -> retry, and signal/waypoint transitions;
   originate at least three accepted builds from each peer.
3. Operate `A-B` and `B-C` passenger services through the exact same station
   group at B. Require a multi-line passenger route and at least one automatic
   five-minute settlement.
4. Create a cargo source-to-hub line without a consumer. Require zero authored
   demand. Add a hub-to-compatible-consumer line, then require cargo to arrive
   at hub stock and later board the downstream vehicle without creation or
   duplication.
5. Allow at least one ordered `town.develop` batch and three all-peer
   checkpoints. Let one automatic five-minute economy settlement complete and
   require the authored and native dates to match on both peers. Keep both
   worlds running for at least ten minutes with a real assigned vehicle,
   revisit several station barriers, then require an acknowledged shared pause
   and a new paired recovery boundary.
6. Disconnect Player 2's companion while the games stay open. Require an
   immediate pause, reconnect within 120 seconds, complete backlog replay, no
   timeout, and a clean manual resume.
7. Prepare one restore point. Require both peer receipts, a current v6 plan,
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

Before accepting the construction slice, also require the fresh-session native
correlation gate:

```powershell
.\tools\verify_build_transition_gate.ps1 -Session <name>
```

It must report hook `0.19.0`, no dropped/pending native build events, no stale
or ambiguous capture, increasing unique generations/tokens, both-peer input,
construction/track/street/edge-object/bulldozer coverage, and one matching
agreed checkpoint.

The repository's exact second-station fixture is a pinned copy of the two
sequential live transactions from support session `mp-2b831d5eac67c488`. The
automated suite verifies its compressed SHA-256, topology, costs, module set,
and collateral identities. The dedicated two-instance `second-station` slice
must also report `second-station-collateral-retired` on both peers; a generic
validator pass is rejected as a stale install.

## Explicit alpha limits

Do not advertise this build for public Internet play, untrusted opponents,
arbitrary executable mods, host migration, more than two players, another game
build, or automatic repair after native-world divergence. Those are later
product gates, not hidden alpha promises.
