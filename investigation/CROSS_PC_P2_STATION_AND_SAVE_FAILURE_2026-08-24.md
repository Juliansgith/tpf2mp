# First cross-PC P2 station and save failure — 2026-08-24

## Scope and outcome

Session `tailscale-test-2` was the first ordinary two-computer TPF2MP run over
Tailscale. Player 1 ran on the development machine and player 2 on `BABA-PC`.
Match bootstrap, ownership gates, roads/tracks, isolated stations, pause/speed,
and normal physical/checkpoint consensus all worked across the real network.

Two player-2 station attempts that combined a modular station with town-
building demolition were rejected by Build 35924 on both machines. The
rejections were consensus-safe and the session recovered, but each rejected
record retained a complete native-component snapshot. A later player-2 save
then remained in Lua metadata finalization, and player 1 reproduced the same
shape: the main `.sav` appeared, while a zero-byte `.sav.lua.tmp` remained and
one game thread consumed a core until the process was closed.

The code correction is complete and the repository gate passes. A fresh
two-computer build/save/load run remains the live acceptance boundary.

## Durable session evidence

The host audit is:

```text
%TEMP%\tpf2mp_bridge\tailscale-test-2\player1\audit\tailscale-test-2.ndjson
SHA-256 edfcaf1f5996a2ad32b5cada0e3977675f79d099ad5c913ec20587b0dcb6d3b1
```

Strict offline replay reported 31 commits, 16 controls, 527 telemetry records,
31 converged queue states, five completed and two identically rejected physical
proposals, nine completed checkpoint barriers, and no faulted or pending
physical/checkpoint work.

The successful isolated player-1 station had one construction, 24 edges, 25
nodes, 14 modules, no collateral, and a `$177,801` canonical cost. The two
failed player-2 attempts each had one construction, 48 edges, 50 nodes, 27
modules, and two town-building construction collaterals. Both peers returned
the same `native-proposal-rejected` result and converged afterward. This was a
native exact-replay compatibility rejection, not network loss or canonical
divergence.

## Construction correction

`construction_replay_state.isExact` now admits only isolated fresh
constructions. A build with any construction collateral is sent through the
existing staged helper:

1. resolve and bulldoze the canonical collateral;
2. wait until those construction inputs are observably absent;
3. replay the captured absolute construction transform;
4. verify and bind the generated graph;
5. settle the canonical finance delta and checkpoint normally.

That helper path previously passed live station-over-houses testing. It is
slower than typed exact replay, but it matches Build 35924's required ordering
and preserves fail-closed postconditions. Isolated stations, depots, assets,
and other fresh constructions retain the exact `BuildProposal` path.

The live payload combined two variables — first two-track exact station and
first exact station with collateral — so multi-track exact replay without
collateral is not inferred broken. The retest separates those cases.

## Save-finalization correction

Construction replay preparation captures complete component sets so that a
later native result can be compared with an exact pre-build world. Successful
construction finalization already cleared `record.constructionPending`.
`proposalFailure` did not. Therefore every rejected exact/helper construction
could leave another full-world snapshot under a terminal proposal record,
which was then returned verbatim by the game script's `save()` callback.

The correction has two layers:

- terminal proposal failure releases `constructionPending` immediately;
- `state_retention.compact` sweeps terminal proposal scratch, and `save()` now
  invokes that idempotent compaction immediately before native serialization.

Active construction scratch is deliberately retained. An autosave may begin
while a replay is in flight, and deleting active verification state would make
that save non-resumable. Completed and failed records retain their signed
transaction, result, completion payload, hashes, and consensus identity; only
the runtime-only world snapshot is removed.

A synthetic state with two failed and one active 8-family/25,000-entry world
snapshot contained 1,200,087 recursively counted entries before compaction and
400,061 afterward. Cleanup released 800,026 entries while retaining the active
snapshot. This is not a native-save timing claim, but it proves that terminal
copies are removed in constant traversal time rather than handed to the game's
Lua serializer.

## Incomplete save artifact

Player 1's manual save produced:

```text
tailscale-test-2-recovery.sav
size 54,914,402 bytes
SHA-256 f0bb06abd2cdb5e6671bef65c8bdb3466f034dd11cff710966f134aea174578b
```

The process was closed before metadata finalization. Only a zero-byte
`tailscale-test-2-recovery.sav.lua.tmp` existed; there was no final `.sav.lua`
or `.jpg`. The `.sav.lua` is load-bearing TPF2MP state, so the transferred
`.sav` alone is not an exact multiplayer recovery save and must not be paired
with metadata from another save. `.jpg` is only the native preview, but the
`.sav`/`.sav.lua` pair must both finalize and travel together.

## Automated verification

- Collateral builds are rejected by the exact-path selector.
- Terminal proposal failure releases construction scratch immediately.
- Save compaction removes scratch from applied and failed records while
  preserving an active replay, and remains idempotent.
- Source-size boundaries pass after extracting proposal-state retention.
- 137/137 Lua core cases pass.
- 7/7 transport-network and 3/3 alpha-readiness cases pass.
- 181/181 Python cases pass.
- Cross-language economy, transport, and freight parity/stress pass.
- Lua/PowerShell syntax, native authority, installer/updater, recovery,
  provenance, packaging, and the 1,024-event replay all pass.

## Fresh live gate

Both machines must run the same newly packaged build. In one fresh session:

1. On player 2, place an isolated two-track station on flat empty terrain.
   It should use exact replay, appear on both peers, and settle one checkpoint.
2. On player 2, place a station over one or two town buildings. It should use
   helper replay, remove the same buildings on both peers, land at the previewed
   transform, and settle one checkpoint without a native rejection.
3. Pause through the multiplayer clock control and save player 2 under a unique
   name. Record the time from `.sav` creation until non-empty `.sav.lua` and
   `.jpg` appear and `.sav.lua.tmp` disappears.
4. Repeat the save on player 1. Neither game may remain permanently busy; the
   three native artifacts must stabilize. Tens of seconds may still be normal
   for Transport Fever 2, but retained-proposal cost must no longer multiply
   with rejected constructions.
5. Transfer each peer's complete `.sav` plus `.sav.lua` (and preferably `.jpg`),
   verify hashes, and load the peer's own save. A fresh post-load checkpoint
   must converge before gameplay resumes.

Until that gate passes, compound-station compatibility and the save-latency
correction are automated/static proof, not claimed live proof.
