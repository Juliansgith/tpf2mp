# Proposal-based edge ownership on Build 35924

Date: 2026-08-01  
Executable: `TransportFever2.exe` Build 35924  
SHA-256: `782b904a8f7bbdac1f7a18528f1a5c778691e5aa3087c37c351bf6912585175c`

## Result

The crashing legacy path is no longer the only known way to change a road's native owner. A disposable live run proved that a supported `api.cmd.make.buildProposal` command can replace an existing `BASE_EDGE_STREET` with identical geometry and a chosen `PlayerOwned.player` value. A second proposal can replace it again and restore desk ownership.

This is a usable exact-build primitive, not yet a complete hot-seat transaction. Every successful ownership replacement created a new local edge entity ID, and the command callback exposed an empty `resultEntities` vector. Live turn integration therefore requires asynchronous batch completion, failure rollback, and atomic canonical rebinding before finance settlement.

## Static evidence

The exact executable contains these UI strings and call sites:

- `Player ownership control tool` at VA `0x143001720`, referenced from function RVA `0x59F5D0..0x59FA81`.
- `playerOwn_` at VA `0x143001750`, referenced at RVA `0x59F896` in the same tool-construction function.
- `ownStreet` at VA `0x143001418`, referenced from RVAs `0x5A083B` and `0x5AA2E2`.

The binary's Lua-binding type string for `street_util::SegmentAndEntity` includes an `optional<ecs::component::PlayerOwned>` member exposed under an eleven-character field name. Runtime construction confirmed that field is `playerOwned` and accepts an `api.type.PlayerOwned` value.

This extends, but does not contradict, the public API description. The official documentation says a `SimpleStreetProposal` modifies a street by removing the old edge and adding a `SegmentAndEntity`, and that the proposal updates dependent lines, stops, people, and cargo. It does not currently list `SegmentAndEntity.playerOwned`: [api.type reference](https://wiki.transportfever2.com/api/modules/api.type.html), [replace-street example](https://wiki.transportfever2.com/api/examples/replace_street.lua.html), and [command API](https://wiki.transportfever2.com/api/modules/api.cmd.html).

## Live proof

Evidence directory: `runtime/supported-api-probe/20260801-190732`.

The disposable probe performed this sequence:

1. Selected public road edge `1444`.
2. Created native player `9478`.
3. Replaced edge `1444` with edge `9479`, whose `PLAYER_OWNED.player` was `9478`.
4. Replaced edge `9479` with edge `8145`, whose owner was restored to desk player `5743`.

Both transitions reported `entityChanged=true`; both callback result-ID lists were empty. Replacement discovery succeeded through an exhaustive before/after `BASE_EDGE` delta plus an owner postcondition.

The native hook remained healthy: hook `0.6.0`, 43 observed Lua states, four wrapped command calls, 4,556 queued commands, 4,558 applies including two direct applies, and zero invalid layouts, unknown tags, pending commands, or tag mismatches. The process was stopped and temporary probe resources were removed.

The saved marker contains a misleading non-null `error` field alongside `success=true`; that was a Lua `and/or` formatting defect in the probe callback, fixed immediately afterward. The actual command outcome, final owner, replacement IDs, native accounting, and runner result all report success.

The earlier directory `20260801-190301` is not ownership evidence. Its synthetic-road setup exhausted invalid terrain coordinates before dispatching an ownership command. Directory `20260801-191344` is also not ownership evidence: the external UI helper was interrupted before world readiness and cleaned itself up.

## Implemented reusable code

- `res/scripts/tpf2_mp/edge_ownership.lua` constructs street or track ownership proposals, issues them, verifies the replacement owner, and discovers exactly one replacement edge without trusting an empty callback ID vector.
- `canonical.rebindLocal` atomically retires the old local ID and installs the replacement local ID while retaining the stable canonical identity and metadata.
- `edge_ownership.rebind` migrates logical ownership and pinned-custody records after a verified replacement.
- `tests/run_edge_ownership_tests.lua` covers street/track proposal construction, two successive ID-changing transfers, canonical/logical migration, and callback failure.

Prototype 0.7 still uses desk-pinned edge custody by default. The live proof does not justify switching the match path until multi-edge asynchronous completion is fail-atomic and the ID changes are propagated through every dependent local/canonical reference.

### Prototype 0.8/0.9 replacement follow-up and 0.10 isolation

The later manual run in [CROSS_COMPANY_TRACK_REPLACEMENT_2026-08-01.md](CROSS_COMPANY_TRACK_REPLACEMENT_2026-08-01.md) supplied the missing real multi-edge case. A Company 1 electrification removed Company 2 track IDs `27017/27018` and added `27020/15370` on the same two endpoint pairs. Prototype 0.7 misclassified both targets as Company 1 assets. Prototype 0.8 consumed the final builder preview/apply snapshots and, in its focused retest, matched `25863/25864 -> 25866/9803` completely. It failed closed because the engine-state owner component was not readable yet, although both committed apply targets named desk `20521`. Prototype 0.9 retains that committed owner only for the transient absence, still rejects observed contradictions, atomically migrates the batch, and reconfirms pinned engine custody before finance. Prototype 0.10 prevents a rival proposal from reaching that replacement path by checking its non-negative source IDs against logical/pinned custody in `builder.proposalCreate`. Automated tests cover own, rival, public, negative-preview, edge-object, and construction sources plus all earlier replacement cases.

## Remaining integration gates

1. Live-prove that prototype 0.10 rejects the exact rival two-edge electrification before apply/debit/ID change, then prove the owner can perform it.
2. Decode split/join and edge-object mappings that cannot be proven by unchanged endpoint pairs for allowed same-company edits.
3. Add explicit leases only if the product later wants consensual cross-company access; rejection is now the default.
4. Validate connected roads, tracks, signals, stations, crossings, lines, and running vehicles.
5. Normalize the proposal into a pointer-free network payload and reproduce equivalent replacements on a second machine.
6. Capture the built-in ownership tool with hook 0.6.0 and compare its processed `new2oldSegments` mapping with the supported reconstruction.
