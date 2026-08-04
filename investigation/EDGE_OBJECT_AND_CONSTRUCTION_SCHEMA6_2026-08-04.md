# Edge objects and portable construction replay — Build 35924

Date: 2026-08-04  
Prototype: `0.20.0-alpha`  
State schema: `19`  
Edge proposal schema: `5`  
Construction proposal schema: `7`

## Question

Can the existing ordered `BuildProposal` path be broadened from linear
road/track and exact stock-station placement to signals, depots, ordinary
constructions, modular station editing, and removal without putting local
entity or repository indices on the wire?

## Result

Yes at the codec, authority, materialization, result-binding, finance, and
automated integration layers. Exact-build disposable runs now also prove real
signal add/removal plus depot/station/asset construction, station editing,
custody, and removal. The implementation still does not claim an ordinary-UI
two-process proof for the full matrix.

One mock-engine network scenario now executes this whole sequence:

1. replace a private track while adding a named signal and retaining existing
   edge objects;
2. build a rail depot with its attached graph;
3. build a generic no-topology construction/asset;
4. upgrade a modular rail station while preserving its canonical construction,
   station, station-group, and depot identities where applicable;
5. remove the disposable station and retire its compound outputs;
6. verify actor ownership, rival rejection, quoted finance, physical consensus,
   checkpoint consensus, and canonical registry state after every boundary.

The Python wire validator independently accepts the supported forms and rejects
tampering, malformed resources, opaque callback projections, machine-local
fields, contradictory retain/remove sets, and removal payloads that smuggle
build data.

## Schema 5: edge objects

Schema 5 adds three explicit lists beside nodes, edges, and topology removals:

- `add`: sequential `edge_object:N` slots attached to a new edge slot, using a
  stable `.mdl` repository name plus finite param, direction/side/category,
  name, privacy, and logical company;
- `retain`: an existing canonical edge-object ID rebound to a replacement edge
  slot, used when track type/catenary changes but its signal should survive;
- `remove`: sorted canonical edge-object IDs.

The local materializer resolves the model by repository name, constructs the
typed `api.type.EdgeObject`, and emits `edgeObjectsToAdd` / `edgeObjectsToRemove`.
Postconditions discover the created local objects, verify their carrier edge and
category, and bind event/slot-derived canonical IDs. Retained objects keep their
canonical identity while changing local carrier bindings.

The pre-click ownership scanner treats `edgeObjectsToAdd` as an access source.
It inspects every candidate field rather than using an `or` chain, because a
normal signal addition can contain both a negative temporary object ID and a
positive existing rival `edgeEntity`. Authoritative prepare/replay repeats the
ownership check.

## Schema 7: portable construction and asset roots

Every schema-7 transaction contains exactly one construction change with:

- mode: `build`, `upgrade`, or `remove`;
- adapter: `stock-rail-station` or `portable-construction`;
- kind: rail station, station, depot, ordinary construction, or asset;
- canonical `sourceCid` for upgrade/removal;
- stable `.con` filename;
- complete finite 4×4 transform;
- bounded recursive plain parameters;
- sorted module records containing numeric slot, `.module` name, variant, and
  bounded plain metadata.

Schema 7 supersedes schema 6 by recognizing the real `ASSET_GROUP`-only root
produced by `ASSET_DEFAULT` constructions. Asset canonical identities use the
`asset:` namespace and do not invent a nonexistent `CONSTRUCTION` component.

The codec recursively restores sparse numeric parameter keys after JSON
transport. It rejects capture truncation, userdata/function placeholders,
non-finite or excessive values, control characters, local entity/player fields,
oversized/deep payloads, and missing stable repository names. This supports
data-driven vanilla/mod constructions when every peer has the identical pinned
content, but it is not a universal serializer for arbitrary script closures or
side effects.

The exact `stock-rail-station` adapter remains stricter than the portable path:
it independently regenerates the stock module family and graph. The portable
path is the compatibility path for depots, assets, and modular edits whose
captured proposal is entirely named/plain data.

## Native execution and output identity

Execution selects the Build 35924 engine interface seam from the canonical mode:

- build → `game.interface.buildConstruction`;
- upgrade/edit → `game.interface.upgradeConstruction`;
- remove → `game.interface.bulldoze`.

Before issuing, the game inventories construction, station, station-group,
depot, asset, edge-object, node, and edge component sets. It waits for a stable
postcondition, compares the expected graph, then derives compound additions,
removals, and replacement pairs. Upgrade processing retires inputs before
rebinding outputs so same-command local ID reuse cannot corrupt the canonical
registry. Source canonical IDs are retained for in-place logical upgrades even
when the engine replaces local entities.

An upgrade must also cause an observable component delta or change the stable
root fingerprint. That fingerprint includes portable construction params and
rendered `.mdl` repository names when available. Build 35924 returns success for
an unsupported old-bench → new-bench `ASSET_GROUP` edit while doing nothing; the
new postcondition rejects this no-op instead of acknowledging it on the wire.

Completion output order is deterministic. Canonical kinds now include
`construction`, `station`, `station_group`, `depot`, `asset`, `edge_object`,
`node`, and `edge`; the companion accepts the maximum compound result produced
by the measured 320 m/eight-track station.

## World manifest and state migration

State schema 19 adds stable construction, asset, and edge-object rows to the
world manifest. Their fingerprints use stable repository/model names and
physical facts, never a numeric local entity ID fallback. This expands
checkpoint coverage and intentionally changes structural/world-manifest
digests relative to schema 17.

Generated maps contain hundreds of autonomous construction and decoration
roots. They participate in the manifest digest but are not eagerly retained as
operational canonical bindings. The selected construction/asset is bound lazily
by the proposal capture path using the same stable pre-existing identity. Only
the manifest digest and counts persist in game-script state. This compact-state
rule fixed a reproducible Build 35924 internal error at the next proposal
boundary; the failing and passing live receipts are in
`SCHEMA7_COMPACT_MANIFEST_LIVE_REGRESSION_2026-08-04.md`.

## Automated evidence

The relevant tests are:

- `tests/run_lua_tests.lua`: schema normalization/materialization, signal
  add/retain/remove, depot/asset build, upgrade/removal, truncation and opaque
  fail-closed cases;
- `tests/run_edge_ownership_tests.lua`: rival signal attachment and all observed
  construction-removal shapes are rejected before commit;
- `tests/run_network_company_mapping_tests.lua`: the complete mock-engine
  five-feature network sequence, output binding, ownership, finance, physical
  consensus, and checkpoints;
- `tests/test_companion.py`: strict cross-wire schema 5/7 validation and abuse
  cases.

The release-wide `tools/run_tests.ps1` result should be treated as the final
automated receipt for this checkpoint; packaging records its schema/version and
hashes in the release manifest.

## Known limits

- Schema-5 signal add/removal and schema-7 facility primitives now have
  exact-build one-process live receipts. The complete ordinary-UI two-process
  matrix still needs to prove capture, finance, ownership, and consensus.
- The current compact state-19/schema-7 build separately passes bidirectional
  real-process track proposal/checkpoint consensus; this guards the common
  authority path but is not a substitute for the facility UI matrix.
- Signals are ordinary edge objects in the measured component surface;
  waypoints may require additional component enumeration despite sharing the
  build payload.
- Output replacement matching is deliberately conservative. Ambiguous multiple
  same-fingerprint children fault closed rather than guessing.
- Stock `ASSET_DEFAULT` supports build/removal. Its in-place replacement helper
  is a native no-op on the pinned build and therefore fails closed.
- Bridges, tunnels, terrain deformation, arbitrary topology splits/joins, and
  construction scripts with opaque callbacks are outside this checkpoint.
- Identical mod manifests/resources remain mandatory. Named resources avoid
  hardcoded vanilla indices; they do not make unlike mod packs compatible.
- Fault after native mutation still stops the session; rollback is checkpoint
  restart, not unsafe in-place geometry repair.

## Shortest live proof

The one-process engine sequence is complete in
`runtime/live-validation/20260804-032456`; see
`SIGNAL_FACILITY_LIVE_PROOF_2026-08-04.md`. The corresponding ordinary-UI
two-process proof is now complete across the staged sessions recorded in
`ORDINARY_UI_FACILITY_MATRIX_2026-08-04.md`:

1. Player 1 places and removes one signal on owned track; Player 2 sees it and
   cannot attach/edit one on Player 1 track.
2. Player 2 builds a rail depot, opens it, and verifies only Company 2 pays and
   can use it.
3. Place one simple decorative asset construction with no transport graph.
4. Edit a disposable modular station (module add/remove or track expansion),
   verify position/children/line path survive, and confirm its canonical source
   identity is unchanged.
5. Remove that disposable station and verify all compound outputs disappear on
   both peers.
6. After every action wait for physical and checkpoint consensus, then export
   research/evidence once at the end.

All steps passed with physical/checkpoint consensus. The next expansion is to
repeat the matrix on two computers and with a curated data-only construction
mod; those are still separate claims.
