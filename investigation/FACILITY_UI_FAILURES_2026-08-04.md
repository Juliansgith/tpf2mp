# Facility UI and shared-clock failure investigation

Date: 2026-08-04 (Europe/Amsterdam)  
Failed human session: `facility-ui-20260804-083528`  
Failed build: prototype `0.20.0-alpha`, state schema `19`, edge schema `5`, construction schema `7`, native hook `0.8.0`  
Corrected build: prototype `0.21.0-alpha`, native hook `0.9.0`

## Scope and evidence

The player tested two ordinary Build 35924 game windows over the localhost TCP
path. Signals and waypoints were rejected, vanilla speed controls rolled back,
a station module edit appeared to do nothing, a rail depot did not build, and
the client overlay eventually reported that it was waiting for its companion.

The original launcher run is retained at
`runtime/localhost-live/facility-ui-20260804-083528`. The coordinated stop
collected both native-hook statuses, both research logs, bridge traffic, game
stdout, and the independent audit under
`runtime/manual-network-evidence/facility-ui-20260804-083528-20260804-090214`.
The game, companion, and runner processes were stopped only after that evidence
was copied.

## Findings and fixes

### Signal and waypoint placement

The four failures at ticks 3847, 3888, 4164, and 4177 all said
`edge-object param is outside [0,1]`. Build 35924's GUI proposal can place an
out-of-range sentinel in the processed edge-object record while its associated
model instance still contains a valid world transform. The schema-5 codec only
reconstructed a spline parameter when the field was absent, so it rejected the
sentinel before using the valid geometry.

The codec now treats both a missing and an out-of-range parameter as requiring
geometric recovery. It projects the model-instance position onto the carrier's
Hermite spline, validates the reconstructed value, and remains fail-closed when
neither a valid parameter nor usable geometry exists. Bounded diagnostic
samples now preserve the raw parameter, model identity, category, position, and
transform for future edge-object shapes.

A subsequent human rerun (`facility-fixes-manual-20260804-0926`) proved that
the codec recovery alone was not sufficient. The raw Build 35924 proposal did
contain the signal's `Mat4f`, but the generic GUI snapshot projector represented
that opaque userdata value as the literal string `<userdata>`. Consequently the
codec never received the geometry described above. Player 2 exported research
at the failure boundary (tick 4304, snapshot digest `fa6357eb`), preserving the
temporary carrier edge, model id 2014, and the erased transform. The stopped
session evidence is retained at
`runtime/manual-network-evidence/facility-fixes-manual-20260804-0926-20260804-094819`.

The GUI capture now has a narrow edge-object transform projector. Before a
proposal is encoded, it reads exactly sixteen finite numeric values from each
bounded `modelInstance.transf`/`transform` value and replaces the diagnostic
placeholder with a portable matrix. It does not broaden generic userdata
inspection or weaken proposal validation. A Lua 5.1 regression uses genuinely
opaque userdata with indexed matrix access, so this boundary cannot regress to
an ordinary-table-only test.

The first two-process rerun with that projection reached native replay, then
both exact game processes asserted at
`construction_util_terminal.cpp:105/GetEdgeObjectType`. Evidence is retained at
`runtime/manual-network-evidence/facility-matrixfix-manual-20260804-0950-20260804-095459`;
the pending commit was the signal transaction `9f9e28fa`. This exposed a second,
independent boundary: production materialisation appended Lua pairs directly
to the generated `BaseEdge.objects` vector proxy. The write was readable from
Lua but did not invoke the binding's typed pair-vector conversion, so the
builder received an untyped temporary edge-object entity.

Production replay now constructs the complete object-reference list, assigns
it through the whole-vector setter, and validates every pair by reading the
generated binding back before any command is issued. A userdata regression
counts whole-vector setter calls and therefore fails under the old indexed
mutation. Exact Build 35924 probe `runtime/supported-api-probe/20260804-100656`
then added and removed a stock signal successfully using that live-proven
whole-vector shape.

### Station module editing

At tick 4512 the native gate reported `suppressedDelta=4` and the GUI capture
aborted with `multiple native builds were suppressed before they could be
correlated`. One logical stock station edit invokes four BuildProposal visitors
on this build. The earlier ambiguity rule required exactly one suppression and
therefore discarded the edit.

The correlator now coalesces up to sixteen suppressed visitors into one logical
capture only when there is exactly one pending capture and its snapshot contains
a construction change. Road and track ambiguity still fails closed. Both a
single batched delta and incrementally observed suppressions are handled, and
the receipt records the coalesced and total suppression counts.

A later two-process run, `facility-vectorfix-manual-20260804-1009`, proved that
capture and consensus but exposed a separate replay boundary. Player 2 built a
160 m/two-track passenger station successfully, then removed one side-building
module. Both peers accepted canonical transaction `99d61dc6`, but both failed
before mutation at `lua::Table::Put` in `Value.cpp:38` with assertion
`pr.second`. The host consequently faulted the session closed at commit 52;
the last agreed checkpoint remained 47 and physical digest `dd1e66f0` did not
change. The exact wire intent is retained at
`runtime/live-evidence/facility-vectorfix-manual-20260804-1009-station-edit-failure/station-edit-intent.json`,
with the complete stopped run under
`runtime/localhost-live/facility-vectorfix-manual-20260804-1009`.

The captured prepared proposal contained top-level `seed=1` and
`upgrade=true`. Those are helper-owned control fields, not ordinary construction
parameters: Build 35924's shipped `constructionupgrader.lua` explicitly removes
`seed` before calling `game.interface.upgradeConstruction`, and the helper
creates the upgrade context itself. Re-supplying the prepared values made its
internal table builder insert an existing key. Construction materialisation now
retains both fields in the canonical transaction and digest for auditability,
but removes them only from the local parameter table immediately before the
legacy helper call. Build placement parameters are unchanged.

The regression covers both reserved keys and the nested numeric `span` and
`snapPoint` metadata arrays. The isolated real-engine proof at
`runtime/supported-api-probe/20260804-111830` then built a stock modular station,
canonicalised and materialised a GUI-shaped edit, verified both reserved fields
were absent at the helper boundary, upgraded all 12 observed station track
edges to catenary, and cleaned up. Its final marker reported
`reservedStripped=true`, `poweredTracks=12`, `trackCount=12`, and
`success=true` for transaction digest `bb0d73e6`.

### Depot placement and companion readiness

The companion did not crash. Player 2's companion repeatedly rejected
`game_outbox/000000000506.json`: Lua had signed checksum `453c76c3`, while the
Python side calculated `33d77696`. The depot transform contained JSON `-0`.
Python's JSON parser normalized that number to `0`, so re-encoding the parsed
message could never reproduce the Lua checksum. The companion retried the same
file every two seconds and the overlay correctly degraded to `WAITING`.

Canonical JSON now emits `0` for both positive and negative numeric zero in Lua
and Python. This removes the cross-parser ambiguity for all proposal types, not
just depots, while preserving the existing wire format for every nonzero value.

### Vanilla pause and speed controls

The native authority gate correctly suppressed player-issued tag-0
`SetGameSpeed` commands, but the GUI had no way to convert the suppressed
request into the shared ordered clock protocol. It therefore looked as though
the control briefly changed and was forced back.

Disassembly of the pinned `SetGameSpeed` visitor at RVA `0x009D57C0` shows
`mov r8d, dword ptr [rdx]`: the requested engine speed is a signed 32-bit value
at command-data offset zero. Hook `0.9.0` reads only values 0 through 4 from a
suppressed tag-0 visitor, stores them in a bounded queue, and exposes
`tpf2mp_native_take_suppressed_game_speed()` in the originating Lua state. The
GUI collapses a burst to the newest request and submits a normal
`clock.request`; host ordering, adaptive capping, generation tracking, and
one-shot native authorization remain unchanged. Invalid values and overflow are
counted in the PID-specific native status instead of being released.

## Verification boundary

The fixes have dedicated regressions for signed zero on both language sides,
sentinel edge-object reconstruction and rejection, four-visitor construction
coalescing without weakening track ambiguity, and conversion of a suppressed
vanilla speed into an ordered `clock.request`. The native payload offset is
pinned by compile-time tests. The full Lua, Python, PowerShell, launcher,
cross-language replay, and native CTest suites pass.

`runtime/supported-api-probe/20260804-092254` then loaded hook `0.9.0` into the
real Build 35924 process and passed the isolated capability probe. The live Lua
state reported `nativeGameSpeedCaptureApi=true`; native queue/apply accounting
remained active and the probe stopped and restored its temporary resources.

The subsequent ordinary two-process reruns proved signal add/remove, waypoint
add/remove, rival-track rejection, rail-depot placement/use/ownership veto, and
a 160 m/two-track modular station placement while both companions remained
connected. `station-editfix-manual-20260804-1122` then passed the fresh station
module edit, rival veto, owner removal, physical consensus, and checkpoint.
`assetfix-manual-20260804-1203` additionally passed graphless bench placement
and owner/rival removal, plus lamp/fence placement, after correcting the
preview-rebase assumption.
The combined acceptance receipt is
`ORDINARY_UI_FACILITY_MATRIX_2026-08-04.md`. Alternating-peer vanilla
pause/speed and adaptive slowdown/recovery remain separate live gates.
