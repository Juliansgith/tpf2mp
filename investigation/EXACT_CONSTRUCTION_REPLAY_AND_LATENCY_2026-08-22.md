# Exact construction replay and latency — 2026-08-22

## Outcome

Fresh schema-7 constructions can now use Transport Fever 2 Build 35924's real
typed `BuildProposal` command instead of waiting on the asynchronous
`game.interface.buildConstruction` helper. The path has live proof for a plain
construction and the stock smallest modular passenger station, including a
two-process network run through physical consensus, finance, checkpoint
consensus, and a structural-drift soak.

The safe/helper path was optimized as well. It now schedules verification work,
uses targeted collateral checks where they are authoritative, spaces full
component scans, and avoids ordinary per-component fingerprint captures. This
reduces idle and in-flight engine-thread work without weakening a postcondition.

Upgrades and removals deliberately retain the helper path. Their old-to-new
mapping and retirement semantics need separate native proof before the exact
path may own them.

## Native construction type

Build 35924 does expose a writable construction proposal type, but not at the
top-level name originally probed. The usable factory is:

```text
api.type.SimpleProposal.ConstructionEntity.new()
```

The live probe established these writable fields:

- `fileName`
- `params`
- `transf`
- `name`
- `playerEntity`
- `headquarters`

`transf` requires a native `Mat4f`. A Lua array of 16 numbers is not accepted;
the working representation constructs four `Vec4f` columns and passes them to
`Mat4f.new`.

`construction_proposal_materializer.lua` owns this conversion. It resolves
canonical removal inputs, fills `constructionsToAdd` / `constructionsToRemove`,
and verifies that the typed value round-trips through `SimpleProposal` before a
command can be issued.

## Exact replay design

`construction_replay_state.isExact` admits only a bounded class:

- current construction schema;
- one fresh construction build;
- no construction collateral to demolish;
- no separately materialized edge-object additions/retentions;
- no topology-only construction removal.

The collateral restriction was added after the first physical two-computer
run. Build 35924 rejected a typed multi-track station proposal that also named
two town buildings for removal, identically on both peers. Compound builds now
use the established helper, which retires collateral before replaying the
captured absolute transform; isolated builds keep the low-latency exact path.

The construction itself is assigned to the typed proposal. Generated topology
is not also inserted into the street proposal; doing both caused Build 35924 to
generate a duplicate 26-node/24-edge graph. The native construction generator
owns physical graph creation, while the canonical transaction remains the
portable expected graph used for postcondition matching and canonical binding.

The GUI path captures expanded component sets before issue and again after the
actual wallet mutation has occurred and remained stable for three GUI frames.
There is no longer a fixed 90-frame minimum for exact construction builds. It
then sends a strict scalar `v1` delta attestation covering:

- constructions;
- stations and station groups;
- depots and assets;
- edge objects;
- nodes and edges.

The scalar form is intentional. Passing the equivalent nested table across the
Build 35924 GUI-to-game script-event boundary terminated the receiving script
environment. `construction_delta_attestation.lua` validates version, field
order, ID shape, uniqueness, bounds, and disjoint add/remove sets before the
engine can use the claim.

The engine reconstructs the post-build component sets from the trusted before
snapshot plus that delta, geometrically matches the canonical graph, binds
event-derived canonical identities, normalizes the observed debit, and emits
the ordinary physical result. No engine-thread exhaustive component scan is
needed between native completion and canonical finalization.

## Fresh construction native-read boundary

Build 35924 exposes generated construction IDs to the GUI before their native
component userdata is safe to inspect from the engine game-script thread.
`pcall` does not contain this failure; a `CONSTRUCTION` fingerprint read ends the
game-script environment and produces the game's generic “An error just
occurred” dialog.

Exact-replay generated semantic outputs are therefore bound with:

```text
nativeReadUnsafe = true
```

For those bindings, structural snapshots:

- still verify `entityExists`;
- use the ordered GUI attestation/proposal fingerprint for identity;
- use canonical logical ownership;
- continue to inspect and digest the generated node/edge graph normally;
- do not call `kindOf`, `ownerOf`, or `fingerprint` on the unsafe root.

This is an explicit authority boundary, not a swallowed error. Construction
root identity comes from the ordered proposal and strict GUI delta; physical
shape comes from the matched graph; disappearance is still detected. Later
station edits and removals remain ordered physical operations.

`run_lua_tests.lua` now contains a regression whose mocked native component
access always throws. A structural snapshot of an exact construction must
complete with zero component reads while preserving its attested fingerprint,
owner, existence, and construction count.

## Measured evidence

### Supported-API native probes

Plain construction:

- evidence: `runtime/supported-api-probe/20260822-134315`
- native `BuildProposal`: success
- generated construction root: observed
- elapsed: **273,020 µs (273 ms)**

Smallest stock modular passenger station:

- evidence: `runtime/supported-api-probe/20260822-135217`
- native `BuildProposal`: success
- generated: one construction, 12 track edges, one station, one station group
- elapsed: **436,411 µs (436 ms)**

These measurements cover the native command through observed physical output,
not network ordering or a later consensus checkpoint.

### Integrated two-process validation

Evidence:

```text
runtime/localhost-live/
  exact-station-safe-20260822-1--typed-station-safe/run-status.json
```

Both exact Build 35924 processes completed the same ordered station build:

- exact GUI `BuildProposal` path asserted on both peers;
- 28 canonical outputs bound on both peers;
- correct `$121,073` debit converged;
- post-proposal checkpoint boundary 18 converged;
- 60-tick structural soak stayed at `df896931` on both peers;
- final core digest `81753ce4` on both peers;
- 3 proposals complete, 0 rejected, 0 faulted, 0 pending;
- 4 checkpoint barriers complete, 0 faulted, 0 pending.

The validator observed physical consensus 15–18 game-script updates after its
station intent was queued. The exact native operation itself is represented by
the 436 ms measurement above; update counts are included because the localhost
validator does not record a trustworthy end-to-end wall-clock latency per peer.

## Failure modes found during implementation

1. Adding both the construction and its captured topology duplicates the
   generated graph. Exact replay now lets the typed construction generate it.
2. A targeted `getComponent(CONSTRUCTION)` can report false immediately after
   the full component enumeration has already observed the root. Full snapshots
   are authoritative on the helper path where they are required.
3. A nested result delta is not safe through this script-event seam. The strict
   scalar codec is used instead.
4. Engine-thread fingerprinting of the exact root terminates the script. Exact
   output ordering and structural identity now use proposal-derived fingerprints.
5. Multiple indistinguishable semantic outputs of the same kind cannot be
   ordered from IDs alone. Exact replay fails closed rather than binding
   machine-local creation order as canonical identity.

## Automated verification

The complete repository suite passed after the live run:

- Lua core: 137/137;
- transport network: 7/7;
- alpha readiness: 3/3;
- cross-language economy, freight, and transport parity;
- 256-step freight stress;
- runtime, game-script, GUI, ownership, and hot-seat suites;
- Lua syntax: 157 files;
- investigation Lua syntax: 9 files;
- PowerShell syntax: 61 files;
- packaging, release update/install, recovery, and launcher tests;
- Python: 181 tests.

The disposable game pair and companions were stopped after validation.

## Remaining acceptance boundary

The automated station is isolated on flat terrain. The next useful human check
is a fresh ordinary station build that connects to existing track and performs
landscaping/building collateral. It should now feel close to the stock native
construction time plus roughly one network consensus round, rather than the old
fixed settle delay.

Also test one mod-provided fresh construction whose resource is present in the
match manifest. The materializer is resource-name/parameter driven and is not
hard-coded to the stock station, but every unusual generated-output shape must
still pass the strict unambiguous binding rules. Upgrades, station edits, and
construction removals remain on the optimized helper fallback for now.
