# Construction codec seam on Build 35924

> Update 2026-08-03: the first bounded implementation described here now
> exists as proposal schema 4 for the smallest stock modular passenger station.
> See [NETWORK_STATION_SCHEMA4_2026-08-03.md](NETWORK_STATION_SCHEMA4_2026-08-03.md).
> Other construction categories remain fail-closed.

Date: 2026-08-02 (Europe/Amsterdam)

## Conclusion

Build 35924 does not expose enough typed surface to reuse the linear
`SimpleProposal` materializer safely. The measured seam instead requires a
dedicated, allow-listed construction transaction and complete component-graph
binding before physical consensus. Schema 4 now implements that design for one
smallest stock passenger-station template; depots, broader layouts, upgrades,
and removals remain fail-closed.

This is an implementation boundary, not a claim that constructions are impossible.

## Measured facts

- The live console capability probe repeatedly reported `simpleProposal=true`, `mat4f=true`, and `constructionEntity=false`. A representative exact-build record is `runtime/live-validation/20260802-125058/stdout-20260802-125307.txt`.
- `api.type.SimpleProposal` can be materialized for the proven node/road/track slice, but Build 35924 does not expose a callable `api.type.ConstructionEntity` constructor for `constructionsToAdd`.
- The engine-thread legacy interface exposes `game.interface.buildConstruction(fileName, params, transform)` and `upgradeConstruction(id, fileName, params)`. Shipped mission code also uses the upgrade helper.
- The disposable live validator successfully built a stock train depot and stock modular passenger station through `buildConstruction`. The station created the expected compound construction/station/station-group/edge ownership shape, and that shape passed four turn-desk custody cycles.
- An earlier player-built depot capture preserved `depot/train_depot_era_a.con`, `trackType=0`, and `catenary=1`. Its transform remained opaque userdata, which is why the current capture now performs a bounded direct numeric probe for Mat4f-like values.
- Shipped `res/scripts/mission/proposalutil.lua` shows that construction-builder events expose proposal `toAdd`/`toRemove` content. The current GUI observer therefore has the right discovery boundary even though replay is still disabled.
- Stock `modular_station.con` is not a single opaque object. Its behavior depends on a module map whose stable slot keys, resource names, and plain metadata determine platforms, tracks, roofs, access and capacity. Typed module userdata cannot simply be put on the wire.

## Capture now implemented

Unsupported construction attempts are still rejected, but research evidence now retains a bounded, pointer-free summary:

- construction resource filename and station/depot hint;
- up to 16 finite transform values when the engine userdata exposes numeric indices;
- bounded scalar/nested parameter values;
- module count, stable module-slot keys, resource names and bounded metadata;
- node, edge, construction, removal and edge-object counts.

Machine-local entity/player/owner fields are removed from this diagnostic projection. The deep `__constructionAdditions` and `__constructionRemovals` projections are explicitly recognized, so exhausting the general proposal budget no longer hides the useful construction sample.

## Required canonical transaction

A construction addition should eventually contain only deterministic data such as:

1. schema version, transaction ID, issuer company and authoritative quoted cost;
2. allow-listed construction resource name plus a resource fingerprint;
3. finite 4x4 transform;
4. strictly validated scalar parameters;
5. for modular stations, stable module-slot keys, allow-listed module resource names and validated plain metadata;
6. canonical references to any existing source objects;
7. expected output slots and bounded postconditions.

It must not contain native entity IDs, player IDs, arbitrary script paths, functions, userdata or unrestricted parameter tables.

## Required replay sequence

1. Capture the original player builder envelope before mutation.
2. Normalize and validate the allow-listed resource, transform, params, modules, ownership and cost.
3. Commit the canonical transaction through the host sequencer.
4. Give each peer a one-shot authorization and call the dedicated engine-thread construction helper.
5. Diff pre/post engine state and discover the complete output graph: construction, station, station group, depot, nodes, edges and relevant edge objects.
6. Match outputs by resource, transform/topology and component relationships rather than callback IDs.
7. Bind deterministic output slots to local IDs, apply logical ownership and charge the canonical account.
8. Require matching local-ID-free physical results from both peers, followed by a structural/financial checkpoint barrier.
9. On any ambiguity, missing component, cost mismatch or peer disagreement, fault closed and retain the last agreed checkpoint.

Upgrades and removals need separate transaction variants. An upgrade can replace several graph members and local IDs; it cannot be treated as an in-place filename change. Removal must verify that every canonical dependent was removed and that no rival-owned component was captured by the cascade.

## Why the shortcut is rejected

Calling `buildConstruction` on both peers with a filename and transform alone would be deceptively easy. It would not prove equal modular contents, graph topology, ownership, cost, station-group membership, attachment IDs or upgrade/removal behavior. The earlier track-electrification asset theft and depot-edge custody failure already demonstrate why apparent visual success is not a sufficient postcondition.

The next useful live sample is therefore one stock depot and one smallest stock modular passenger station placed through the ordinary UI in the two-window manual lab, followed by Research and Snapshot exports. Those captures can define the first strict allow-list; replay should remain closed until the complete graph matcher passes one-machine and two-peer tests.
