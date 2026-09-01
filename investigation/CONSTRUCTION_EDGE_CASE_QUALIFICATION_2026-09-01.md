# Construction edge-case qualification

Date: 2026-09-01 (Europe/Amsterdam)

Target: Transport Fever 2 Windows x64 build `35924`, development tree after
`0.42.5-alpha`, construction proposal schema `7`, native hook `0.19.0`.

## Outcome

The stock construction surface now has an explicit inventory, strict portable
codec coverage, adversarial size/budget tests, and representative native-engine
proof for every distinct persistent entity shape found in Build 35924.

This pass found and fixed two real codec defects:

1. the headquarters marker lived outside `params` and was discarded, which
   could reproduce the model without reproducing headquarters semantics;
2. `asset/field_decoration.con` and `asset/ground_texture_builder.con` advertise
   `ASSET_DEFAULT` but create persistent `CONSTRUCTION` roots, not
   `ASSET_GROUP` roots.

It also pinned two non-obvious shapes that were previously only assumptions:

- roundabout and interchange templates expand into rootless node/edge graphs;
- a buoy is hybrid: it retains a `CONSTRUCTION` root and also creates two nodes
  and one water-street edge.

All focused tests and the complete repository suite pass. The three mature
native facility probes also still pass after the codec changes. No release was
packaged or published by this qualification.

The follow-up
[practical track and station geometry qualification](PRACTICAL_TRACK_AND_STATION_GEOMETRY_2026-09-01.md)
extends this resource-shape audit with kilometre-scale rail, grades, tunnels,
road crossings, combined collateral demolition, steep-site stations, and
pinned ordinary-GUI bridge transactions.

## Exact inventory

The audit reads Urban Games' installed `construction.zip` rather than relying
on menu labels. It excludes ordinary town buildings and pins every other `.con`
resource in an explicit fixture:

| Inventory | Count | Result |
|---|---:|---|
| Non-building construction resources | 52 | Exact match |
| Public player-facing resources | 33 | Exact match |
| Direct native evidence | 19 | Recorded |
| Prior manual evidence | 2 | Recorded |
| Offline portable-codec evidence | 14 | Passing |
| Authored/internal content resources | 17 | Content-bound |
| Stock street resources | 35 | Exact match |
| Stock track resources | 2 | Exact match |
| Stock bridge resources | 6 | Exact match |
| Stock tunnel resources | 3 | Exact match |

The audit fails if a game update adds, removes, or reclassifies a resource.

- Construction fixture:
  [`stock_nonbuilding_constructions.lua`](../tests/fixtures/stock_nonbuilding_constructions.lua)
- Network-resource fixture:
  [`stock_network_construction_resources.lua`](../tests/fixtures/stock_network_construction_resources.lua)
- Construction audit receipt:
  [`stock-coverage.json`](../runtime/construction-edge-cases/stock-coverage.json)
- Network-resource audit receipt:
  [`stock-network-resources.json`](../runtime/construction-edge-cases/stock-network-resources.json)

The thirteen public resources without an individual native build in this pass
are eight track-decoration variants, the cloverleaf template, and four older
buoy variants. They are not silently untested: every file is normalized,
validated, materialized, and resource-identity checked through the same schema
as its natively exercised family representative.

## New native proof

The disposable exact-build probe constructed, inspected, and removed eight
edge cases:

| Case | Observed native shape | Build/remove result |
|---|---|---|
| Headquarters | 1 `CONSTRUCTION` root | Pass |
| Asset builder | 1 `ASSET_GROUP` root | Pass |
| Field decoration | 1 `CONSTRUCTION` root | Pass |
| Ground texture | 1 `CONSTRUCTION` root | Pass |
| Track sound barrier | 1 `ASSET_GROUP` root | Pass |
| Roundabout | 4 nodes + 4 street edges, no root | Pass |
| T interchange | 18 nodes + 18 street edges, no root | Pass |
| Buoy | 1 construction + 2 nodes + 1 water edge | Pass |

Every persistent root was owned by the active company and disappeared after
removal. The junction helper's generated edges were removed as one typed graph.
Its legacy helper does not expose representative per-edge ownership, so private
ownership for that family remains proven by the production GUI transaction
tests, not by this helper.

The native component reader does not expose the headquarters boolean for
readback. The proof therefore combines the correct native resource/root with
strict GUI capture, schema, materializer, and contradictory-marker rejection.

- Edge-case native receipt:
  [`run-status.json`](../runtime/live-validation/20260901-091506/run-status.json)

## Regression proof across mature construction families

The pass reran the existing native construction slices after the changes:

- rail depot, passenger station, cargo station, asset, station
  electrification/edit, four ownership cycles, and complete compound removal:
  [`20260901-092358`](../runtime/live-validation/20260901-092358);
- passenger/cargo airfield and airport, removal, aircraft purchase, assignment,
  and 560.43-metre movement:
  [`20260901-092615`](../runtime/live-validation/20260901-092615);
- two passenger harbors, cargo harbor, shipyard, cargo-harbor removal, ship
  purchase, assignment, and 634.53-metre movement:
  [`20260901-092904`](../runtime/live-validation/20260901-092904).

Each run also completed the 39-check authoritative validator at digest
`86bf7792` with the exact-build native hook active.

## Adversarial codec matrix

The offline layer now checks both breadth and hostile shapes:

- every one of the 52 resources crosses normalize, portable validation, and
  materialization without leaking temporary native IDs;
- 216 street-terminal combinations cover passenger/cargo, one-way/two-way,
  terminal count, length, era, and collateral demolition;
- 60 airport/airfield combinations cover era, passenger/cargo, terminals,
  hangar, landing direction, and a 384-node/383-edge large-airport graph;
- 12 harbor combinations cover template, size, and terminal count;
- a production-shaped 52-edge cloverleaf graph validates as a private,
  canonical rootless topology transaction;
- exactly 64 collateral constructions are accepted and 65 are rejected;
- exactly one construction addition is accepted and two are rejected;
- exactly 256 modules are accepted and 257 are rejected;
- cyclic parameters, depth over 16, and more than 8,192 projected parameter
  values fail closed;
- construction graphs may use up to 1,024 nodes and 1,024 edges, while ordinary
  topology remains bounded at 256 of each.

The complete command was:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\tools\run_tests.ps1
```

It ended with `All TPF2MP tests passed.` The focused Lua total is now
`153/153`.

## Honest remaining limits

1. Track decorations can be built and removed through the native construction
   API, but exact snapping to a selected rail edge requires a real GUI cursor.
   That visual/attachment gesture remains a human test.
2. Calling the legacy `game.interface.buildConstruction` helper for the stock
   cloverleaf enters an engine-critical placement state on the disposable
   world. The production path does not use that helper: it captures the GUI's
   already-expanded 52-edge proposal. That production-shaped graph passes
   offline, but the cloverleaf still needs a fresh human two-peer click.
3. Roundabout/T-interchange geometry and removal are native-proven; private
   ownership of every generated edge is production-codec proven rather than
   observable through the legacy helper.
4. Bridge and tunnel file inventories are pinned, but Build 35924 carries their
   selected structure as a local numeric `typeIndex`. The exact binary/content
   profile makes that deterministic for the current alpha; arbitrary mod load
   orders that reorder those repositories remain outside the compatibility
   promise.
5. Data-only mod constructions flow through the generic resource/parameter
   codec. Arbitrary third-party Lua callbacks with local side effects are not
   claimed deterministic merely because their `.con` filename is accepted.
6. This is strong local/native evidence, not a substitute for two humans
   exercising dense modular edits, terrain-heavy junctions, deletion queues,
   and the remaining cursor-dependent cases on two physical PCs.

## Decision

No additional stock construction family was found outside the pinned matrix.
The fixes are regression-clean and the candidate is ready for the remaining
human GUI/WAN construction matrix. Keep the limitations above visible instead
of treating generic `.con` serialization as proof of arbitrary scripted-mod
compatibility.
