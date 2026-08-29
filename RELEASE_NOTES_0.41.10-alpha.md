# TPF2MP 0.41.10-alpha

This release fixes the remaining road-connected street-terminal failure from
relay session `mp-ab70273a64a19ffa`. A large stock bus terminal could be built
on empty land, but snapping it to a town road either rejected unchanged or,
when houses were in its footprint, removed the houses and faulted before the
terminal appeared. State schema 34, checkpoint format 5, construction proposal
format 7, operation format 4, economy model 10, and native hook 0.19.0 are
unchanged.

## Exact post-expansion topology

- Construction resources are now reconciled after Build 35924 expands them
  inside `api.cmd.make.buildProposal`. This is the first point where the
  engine-generated station graph actually exists.
- Native-generated nodes and edges retain their engine IDs, but receive the
  exact captured snapped geometry.
- External topology from the player's click—such as both halves of a split
  town road—is appended with fresh non-colliding temporary IDs and references
  the retained station entrance node.
- Carrier, resource, endpoint, and edge-object mismatches reject before the
  command is issued. Exact removal verification remains active.
- A normal modular rail station remains its native 13-node/12-edge graph; the
  reconciler does not duplicate construction-generated topology.

## Regression and live proof

- Offline tests reconstruct the exact connected terminal and separately prove
  the normal modular rail-station path.
- The localhost validator can load a populated archived save and run this
  exact transaction without unrelated empty-map fixtures.
- Two hooked Build 35924 processes replayed the archived
  `mp-ab70273a64a19ffa` starting world in
  `terminal-topology-live-20260829g`.
- The result contained exactly one construction, one station, one station
  group, two nodes, and three edges. The old town-road edge and both houses
  retired on both peers.
- The audit recorded one completed physical proposal, zero rejected/faulted/
  pending proposals, three completed checkpoint barriers, identical core
  digest `af3d8eff`, and identical structural digest `3d4fa231`.

The complete Lua, Python, cross-language parity, launcher/updater, relay,
recovery, packaging, syntax, and architecture suite passes; the main Lua
model/codec suite passes `143/143`.

Both players must install `0.41.10-alpha`. Mixed versions remain unsupported.
The already-faulted relay session crossed the older one-way demolition boundary
and cannot be resumed as an unchanged rejection.
