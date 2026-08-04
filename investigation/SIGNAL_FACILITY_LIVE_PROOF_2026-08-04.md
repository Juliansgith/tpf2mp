# Signal and facility live proof — Build 35924

Date: 2026-08-04  
Prototype: `0.20.0-alpha`  
State schema: `19`  
Edge proposal schema: `5`  
Construction proposal schema: `7`  
Native hook: `0.8.0`

Historical boundary: this remains the valid one-process engine receipt for
prototype 0.20. The later broad two-process UI run found integration failures
outside that receipt and is superseded for release status by
[FACILITY_UI_FAILURES_2026-08-04.md](FACILITY_UI_FAILURES_2026-08-04.md).

## Result

The exact pinned Windows x64 Build 35924 now has automated, disposable-world
live receipts for the engine primitives behind signals, depots, generic assets,
station editing, and construction removal. The release-wide Lua/Python tests
also carry these forms through canonical capture, validation, replay, ownership,
finance, physical consensus, and checkpoint consensus.

This closes the one-process engine-shape uncertainty. It does **not** replace the
remaining ordinary-UI two-process network matrix: both peers must still prove
that each player-originated form is captured, prepared, replayed, charged, and
checkpointed exactly once.

## Signal receipt

`runtime/supported-api-probe/20260804-021739` used a real GUI-state
`SimpleProposal` and the generated nested edge-object binding exposed by this
build. It:

1. built a private source track;
2. replaced that track while adding stock
   `railroad/signal_path_c.mdl` at spline parameter `0.5`;
3. enumerated exactly one new `SIGNAL_LIST` entity and its carrier edge;
4. verified both signal and replacement edge belonged to the expected player;
5. replaced the carrier again while removing the signal; and
6. verified the signal entity disappeared.

An earlier run exposed same-command edge-ID reuse in the probe. Retiring the
source alias before binding the replacement fixed it; the successful receipt is
the rerun above. The separate GUI capture at
`runtime/supported-api-probe/20260804-021226` proves the native player action
reaches the captured `BuildProposal` surface rather than only a synthetic
engine helper.

## Facility/edit/removal receipt

`runtime/live-validation/20260804-032456` repeated and passed the normal `39`-check validator,
all `17` executable signatures, the pinned visitor table, native wrapper/gate
integration, independent checkpoint replay, and the enhanced facility sequence.
The final marker reported `stage=complete` and `success=true`.

The disposable sequence proved:

- rail depot: one `CONSTRUCTION`, one `VEHICLE_DEPOT`, and one attached track;
- modular passenger station: one `CONSTRUCTION`, one `STATION`, one
  `STATION_GROUP`, and twelve attached tracks;
- four complete company-custody transitions: every one of the 18 observable
  player-owned facility components returned to its rightful company and leased
  back to the turn desk twice;
- station edit: all twelve unpowered platform tracks were removed and replaced
  by twelve catenary tracks, with the station construction identity and owner
  retained;
- arbitrary `ASSET_DEFAULT`: stock `default_multi_bench_old.con` produced a
  real `ASSET_GROUP` root with no `CONSTRUCTION` component, was assigned to the
  expected player, then was removed completely;
- depot removal: construction, depot, and attached track disappeared together;
- station removal: construction, station, and all twelve edited tracks
  disappeared together.

Build 35924 intentionally leaves an empty `STATION_GROUP` shell after the last
station is bulldozed. The probe reads its station list and accepts the shell
only when it references no live `STATION`; a surviving active station still
fails the postcondition.

The run restored `settings.lua` byte-for-byte, removed the temporary base-game
probe route, stopped only its exact game process, verified the installed source
tree, and wrote:

- `runtime/live-validation/20260804-032456/evidence.json`;
- `runtime/live-validation/20260804-032456/run-status.json`;
- `runtime/live-validation/20260804-032456/research.md`;
- `runtime/live-validation/20260804-032456/checkpoint-replay.md`.

## Important negative finding

`runtime/live-validation/20260804-024603` deliberately failed after a stronger
rendered-model assertion was introduced. `game.interface.upgradeConstruction`
returned successfully for an attempt to replace the old bench asset with the
new bench asset, but `MODEL_INSTANCE_LIST` still contained only
`asset/bench_old.mdl`. The helper had performed no mutation.

The production finalizer now requires every upgrade to produce an observable
component delta or a changed stable root fingerprint. Construction params and
rendered model repository names participate in that fingerprint. A successful
helper call with an unchanged world therefore times out/fails closed and is
never announced as a physical network success. Stock `ASSET_DEFAULT` is
currently supported for build/removal, not in-place replacement. Editable
`CONSTRUCTION` entities, including the proven modular station path, retain the
upgrade route.

This negative receipt also found a validator bug: the unattended runner had
searched the nested JSON text for any `"success":true`, so a successful custody
subobject could mask a top-level failure. It now parses the marker and reads only
the top-level `success` field. The failed run was correctly rejected after that
fix; the final run passed under the stricter runner.

## Protocol consequences

Construction schema `7` adds `asset` as a first-class canonical root kind. It
selects `ASSET_GROUP` rather than assuming every `.con` creates a
`CONSTRUCTION`, preserves the stable `asset:` canonical identity, and supports
build/removal of topology-free assets. State schema `19` persists selected
bindings and the strengthened stable manifest digest. Autonomous map
construction/asset rows remain digest evidence and bind lazily only when
selected, avoiding an oversized operational state; see
`SCHEMA7_COMPACT_MANIFEST_LIVE_REGRESSION_2026-08-04.md`. Local numeric
entity/model/repository IDs remain outside portable messages and digests.

The full automated suite passes with:

- 29 Lua unit tests;
- game-script, ownership, GUI, hot-seat, network-company, and 104-event replay
  integration;
- 14 mod Lua and 4 bootstrap/probe syntax checks;
- 39 PowerShell syntax checks;
- native launcher/hook boundary tests and launcher UI smoke construction;
- 36 Python protocol/network/checkpoint/recovery/report tests.

## Remaining live gate

Run a fresh two-process localhost session through ordinary player UI actions:

1. add/remove a signal from each company and reject rival attachment/edit;
2. place/use/remove a depot and charge only its owner;
3. place/remove a topology-free asset;
4. edit a modular station, preserving position, active lines, ownership, and
   canonical source identity;
5. remove a disposable station and accept only an empty transient group shell;
6. require physical and checkpoint consensus after every action.

Then repeat the same matrix on two computers with byte-identical content. A
curated data-only construction mod is the next compatibility proof; opaque
script side effects still require an explicit adapter.
