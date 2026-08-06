# TPF2MP investigation record

Last updated: 2026-08-06 (Europe/Amsterdam), prototype `0.22.0-alpha`, state schema `22`, checkpoint format `3`, edge proposal schema `5`, construction proposal schema `7`, native hook `0.13.0`.

This directory distinguishes four things that must not be blurred together:

- documented Transport Fever 2 scripting behavior;
- local shipped-script or exact-binary evidence;
- automated simulated-interface proof;
- behavior observed in a disposable running game.

A function existing in the API is not proof that a particular native transition is safe, and a one-machine physical replay is not proof of two-machine equivalence.

The adversarial review of demand arithmetic, fare hysteresis, optimistic line
residue, manifest binding, and test honesty is recorded in
[ADVERSARIAL_MODEL_AND_RESIDUE_AUDIT_2026-08-04.md](ADVERSARIAL_MODEL_AND_RESIDUE_AUDIT_2026-08-04.md).

The railway purchase codec, exact Build 35924 `loadConfig` contract, successful
NOHAB + two BC4 native receipt, and route-phase policy are recorded in
[VEHICLE_PURCHASE_AND_ROUTE_PHASE_2026-08-05.md](VEHICLE_PURCHASE_AND_ROUTE_PHASE_2026-08-05.md).

The deterministic two-peer post-initialisation crash, identical native entity
view access violations on both processes, GUI-safe canonical-account
projection, and clean replacement bootstrap are recorded in
[GUI_PLAYER_ENTITY_LOAD_CRASH_2026-08-06.md](GUI_PLAYER_ENTITY_LOAD_CRASH_2026-08-06.md).

The future-time shared-clock rendezvous, paused heartbeat, canonical
per-station train barrier, format-3 convergence projection, restart behavior,
and focused live-test contract are recorded in
[TRAIN_CLOCK_RENDEZVOUS_AND_STATION_BARRIERS_2026-08-06.md](TRAIN_CLOCK_RENDEZVOUS_AND_STATION_BARRIERS_2026-08-06.md).

The two-train Escape-pause trace, exact stock speed-button contract,
authoritative indicator projection, immediate native pause fence, and bounded
resume path are recorded in
[CLOCK_INDICATOR_AND_NATIVE_PAUSE_FENCE_2026-08-06.md](CLOCK_INDICATOR_AND_NATIVE_PAUSE_FENCE_2026-08-06.md).

The follow-up lifecycle normalization, single departure-schedule policy,
durable slot allocator, barrier pruning, and 50-train authority stress are
recorded in
[STATION_SCHEDULE_INTEGRATION_AND_BARRIER_LOAD_2026-08-06.md](STATION_SCHEDULE_INTEGRATION_AND_BARRIER_LOAD_2026-08-06.md).

The unanimous `Too much curvature` rejection, the old fatal-session response,
and the strict reject-and-continue no-mutation predicate are recorded in
[RECOVERABLE_NATIVE_PROPOSAL_REJECTION_2026-08-06.md](RECOVERABLE_NATIVE_PROPOSAL_REJECTION_2026-08-06.md).

## Pinned build

- Executable: `F:\SteamLibrary\steamapps\common\Transport Fever 2\TransportFever2.exe`
- Size: `72,843,280` bytes
- Runtime identifier: `Build 35924 Windows 64-bit`
- SHA-256: `782b904a8f7bbdac1f7a18528f1a5c778691e5aa3087c37c351bf6912585175c`
- PE timestamp: `0x675ABCC6`
- Image size: `0x046CE000`

The native component additionally requires 17 unique signatures at the pinned locations and validates the selected entries in the exact 37-command visitor table. Any mismatch rejects the hook before it becomes active.

## Current strongest live evidence

### Two real localhost game processes

`runtime/localhost-live/train-prompt-barrier-state22-20260806-105918` is the
current strongest ordinary-line proof. Two exact Build 35924 processes loaded
the same populated save and ran its real NOHAB + two-BC4 train through four
prompt barriers. Host status records zero scheduled and four unscheduled
release commits, zero pending rounds/faults, 1.86 seconds average latency, and
2.38 seconds maximum latency. Both peers finished at core `fba1630d`, model
`98f01295`, structure `15189409`, and mobility `8e5d90e6`; the audit records
15/15 commit convergences, 2/0/0 physical proposals, and 3/0/0 checkpoint
barriers. The separate `train-scheduled-state22-20260806-1010` receipt remains
the authored-schedule mechanism baseline. Full evidence is in
[STATION_SCHEDULE_INTEGRATION_AND_BARRIER_LOAD_2026-08-06.md](STATION_SCHEDULE_INTEGRATION_AND_BARRIER_LOAD_2026-08-06.md).

`runtime/localhost-live/populated-network-ownershipfix-20260803` remains the
static ownership baseline. Two exact Build 35924 processes loaded the same populated save containing towns, industries, a depot, stations, a passenger line, a train, and 413 simulated people. Both peers mapped the pre-existing network to the same canonical owner, originated one private 25,000 track transaction each, reconstructed both results, and finished with matching core `7a1b9f9d`, model `5b59ecf2`, structure `07db112f`, and mobility `a7ae06ac`. Three checkpoints, two physical results, and five mobility comparisons converged with zero faults. The 300-tick final soak was paused and autonomy-frozen; it is a populated static-convergence proof, not a running RNG-lockstep proof. Direct ECS telemetry read 10 line users, 8 aboard, and 2 waiting on both peers. Full evidence, the canonical ownership fix, recovery watcher, and title-menu proof are in [POPULATED_NETWORK_RECOVERY_AND_MENU_2026-08-03.md](POPULATED_NETWORK_RECOVERY_AND_MENU_2026-08-03.md).

`runtime/localhost-live/localhost-20260802-175636` is the preceding empty/disposable-world two-live-game proof. Two exact Build 35924 processes connected as `player1`/`player2`; each peer originated a private 25,000 track transaction; both peers reconstructed and bound both results; and both canonical/native company balances ended at 4,975,000 on both machines. Three checkpoints and both physical results converged, then canonical finance and structure held for 600 ticks with zero reconciliation failures.

The run finished `PASS` with core digest `fdaceb08`, structural digest `33cdc17a`, five commits, five controls, two completed physical proposals, three completed checkpoint barriers, five converged telemetry comparisons, and zero faults. The long soak exposed recurring peer-local loan-interest/maintenance entries and directly motivated the schema-3 quoted-cost plus canonical-account design. Full evidence and conclusions are in [BIDIRECTIONAL_NETWORK_FINANCE_2026-08-02.md](BIDIRECTIONAL_NETWORK_FINANCE_2026-08-02.md); the earlier bring-up history remains in [LOCALHOST_TWO_INSTANCE_NETWORK_2026-08-02.md](LOCALHOST_TWO_INSTANCE_NETWORK_2026-08-02.md).

`runtime/localhost-live/localhost-manual-lab-smoke2-20260802` then exercised the new post-proof manual-lab branch. Both real windows stayed connected at `MANUAL LAB READY`; a clean two-peer stop triggered post-close evidence capture with two native statuses, both bridge trees and the game log; the audit was valid; and all shared settings and temporary injected resources were restored. This makes same-PC human capture practical without weakening the automated gate.

### Ordinary-UI facility matrix

Three staged human localhost runs now close the bounded schema-5/schema-7 UI
matrix. `facility-vectorfix-manual-20260804-1009` preserves completed
signal/waypoint and rail-depot boundaries before an independently fixed station
edit fault. `station-editfix-manual-20260804-1122` then passes stock station
placement, module editing, rival denial, and owner removal. Finally,
`assetfix-manual-20260804-1203` passes named bench placement/removal with rival
denial plus lamp and wooden-fence placement. Its independent audit records
6/0/0 physical proposals and 7/0/0 checkpoint barriers, source/install equality,
both exact native statuses, and no relevant game errors. See
[ORDINARY_UI_FACILITY_MATRIX_2026-08-04.md](ORDINARY_UI_FACILITY_MATRIX_2026-08-04.md).

### Signal and facility exact-build proof

`runtime/supported-api-probe/20260804-021739` added and removed a real named
signal through the Build 35924 edge-object surface, verified its carrier and
owner, and left no signal behind. `runtime/live-validation/20260804-032456`
passed the ordinary 39-check validator and exact native profile, then built a
depot and modular station, ran four custody transitions across 18 owned
components, replaced twelve station tracks with catenary tracks, built/removed
an `ASSET_GROUP`-only asset, and removed the depot and station compound outputs.
The only surviving native object was a verified-empty transient station group.
This remains the exact one-process engine/postcondition receipt; the staged
ordinary-UI two-process matrix above now supplies the complementary capture,
ownership, physical-consensus, and checkpoint proof. See
[SIGNAL_FACILITY_LIVE_PROOF_2026-08-04.md](SIGNAL_FACILITY_LIVE_PROOF_2026-08-04.md).

### State-19 compact-manifest regression

Two release-candidate localhost runs reproducibly reached Transport Fever 2's
generic internal-error path when richer fingerprints eagerly admitted hundreds
of autonomous scenery roots into persistent operational state. The corrected
design still hashes every construction/asset into the shared-world manifest but
binds one only when selected. `runtime/localhost-live/schema7-compact-20260804-032006`
then passed both proposal directions and three checkpoint barriers with matching
core `73af1552` and structure `53bb77bb`. See
[SCHEMA7_COMPACT_MANIFEST_LIVE_REGRESSION_2026-08-04.md](SCHEMA7_COMPACT_MANIFEST_LIVE_REGRESSION_2026-08-04.md).

### Populated native-operation proof

`runtime/localhost-live/operations-20260802-guided50` is the current populated
human-operation result. In two explicitly independent local worlds, a passenger
train and a cargo train each completed multiple full cycles without an
ownership/path warning. Visual evidence records `8/30` passengers in Player 1
and `8/48` cargo in Player 2. Both worlds produced 355 initialized interval
samples; each spent 74-75 samples at engine speed 4 (UI speed 3), with no
post-build digest transition during that running interval. Towns stayed frozen,
all five industries retained `manualDevelopment=true`, and model/autonomy
digests stayed unchanged.

All five convenience mobility readers nevertheless remained unavailable in the
populated worlds. This originally looked like a scripting observation limit,
but the 2026-08-03 populated-network work found a direct ECS component path and
read real passenger counts on both peers. Player GUI construction, line and
vehicle actions reached queued native tags; none used direct apply. Player 2
then reconciled Company 1 exactly from `50,000,000` to `44,120,148`, retained
80 logical assets and 70 pinned edges, and cycled cleanly to funded Company 2.
See [OPERATIONAL_CAPTURE_LAB_2026-08-02.md](OPERATIONAL_CAPTURE_LAB_2026-08-02.md) and its [superseding telemetry result](POPULATED_NETWORK_RECOVERY_AND_MENU_2026-08-03.md).

### Full canonical transaction run

`runtime/live-validation/20260802-075533` is the historical canonical-track proof. It ran the exact game build with native hook `0.7.0`, state schema `11`, checkpoint format `2`, and passed 39/39 checks at tick 376, core digest `f859604c`. The 2026-08-04 signal/facility receipt above supersedes it for the current engine-shape boundary.

The run proved:

- two native competitive companies and the UI turn desk;
- explicit starting cash and initial wallet mirror;
- real native debit, two company cycles, isolation, and remirroring;
- host-model settlement and native payouts to both company players;
- accepted autonomy-freeze command and structural snapshot;
- a canonical electrified private-track transaction reconstructed in GUI state;
- geometric discovery of two nodes and one track edge;
- supported ownership correction after the fresh build emerged under desk/public ownership;
- stable canonical output binding despite changed/unknown callback result IDs;
- proposal finance routing and successful post-build reconciliation;
- research/validation/checkpoint export.

Native status counted 12,886 queued commands and 12,912 total applies, including 26 direct applies. It ended with zero invalid layouts, unknown tags/applies, pending commands/overwrites, queue/apply tag mismatches, or authority-visitor mismatches. One deliberately rejected candidate proposal was retried successfully. All 23 consequential-command visitors remained transparent while their standalone gate was disabled.

`checkpoint-replay.md` in that directory anchored the initial format-2 checkpoint and verified 14 later events. Three portable model changes replayed independently, two canonical/native-only changes remained continuous in the core chain, the final model digest was `95dd1197`, and the canonical company financial digest was `fde11e45`. This closes the earlier bug where asynchronous proposal finalisation changed canonical state outside an audited action and verifies the new wallet-aware checkpoint format in the real engine.

### Depot and station compound-custody proof

`runtime/live-validation/20260802-125058` reproduced the compound native ownership shape behind the user's rail-depot turn failure and exercised the equivalent stock modular passenger station. It created one depot construction/depot/track edge and one station construction/station/station-group/12-track-edge set, then completed four company cycles. All 18 player-owned components returned atomically to Company 2 and leased atomically back to the shared desk twice. The final `facility-custody-complete` marker reported `stage=complete`, `success=true`; the ordinary 39-check validator, native-hook integration, 20-event checkpoint replay, and byte-for-byte settings restoration also passed.

The fix accepts only the desk or the edge's exact logical company's native player as valid tracked-edge custody. Rival, missing, and unobservable owners still fail closed before finance. Full details: [DEPOT_STATION_EDGE_CUSTODY_2026-08-02.md](DEPOT_STATION_EDGE_CUSTODY_2026-08-02.md).

### Focused supported-API track proof

`runtime/supported-api-probe/20260802-024721` built one normal and one electrified private track through a GUI/console-capable state. Both received native player owner `5743`. This corrected a misleading engine-state-only result where `PlayerOwned` was dropped or not visible at the same boundary.

### Ownership replacement proof

`runtime/supported-api-probe/20260801-190732` replaced public road edge `1444` with company-owned edge `9479`, then with desk-owned edge `8145`. Both supported BuildProposal commands succeeded, both changed the local ID, and neither callback supplied a usable result-ID vector. This is the direct evidence for enumeration plus geometric matching and canonical rebinding.

### Native BuildProposal gate proof

`runtime/supported-api-probe/20260801-163359` suppressed one proposal before mutation and admitted two one-shot-authorized proposals to the original visitor. It ended with `suppressed=1`, `allowed=2`, callback outcomes `false, false, true`, and no tag mismatches. This is a real pre-mutation authority primitive for tag 15.

### Consequential-command gate proof

`runtime/supported-api-probe/20260802-075034` live-proved the hardened generic hook-0.7 gate across the exact pinned visitor table. An unauthorized tag-0 `SetGameSpeed` command completed normally with `success=false`; one matching authorization admitted the retry and completed with `success=true`. Final counters were 23 hooks, one suppression, one admission, zero pending tokens, and zero table/tag mismatches. Network mode requires this gate and the BuildProposal gate before it will emit or consume gameplay traffic.

## Manual hot-seat findings

The user’s manual sessions established the product failures that shaped the current implementation:

- New company players start at zero in the tested setup; TPF2MP must grant configured starting cash explicitly.
- Separate real road costs were retained by the correct company across repeated cycles.
- Roads built with ownership `Keep` are public/shared and can be connected from either company.
- Explicitly owned road/track edges cannot be moved with legacy `setPlayer`; doing so reaches a Build 35924 internal assertion.
- Retrying the old split custody/finance transaction could multiply money. The current turn close verifies custody before money and is fail-atomic.
- Company 2 built normal/electrified track and retained six pinned logical edges without reconcile errors.
- Company 1 was able to electrify Company 2’s track before the strict veto. Replacement IDs were treated as new Company 1 assets, proving pooled native edge custody alone is insufficient.
- Prototype 0.8 matched the replacement topology exactly but saw the engine ownership component one update too early; it correctly stopped before money moved.
- Company 2's rail depot was inaccessible to Company 1 as intended, but returning its construction also cascaded the attached edge to Company 2. The old desk-only edge postcondition treated that rightful owner as a fault and blocked the next cycle. The corrected invariant and a real depot/station round trip now pass.

The complete traces are preserved in:

- [MANUAL_ROAD_PROXY_FAILURE_2026-08-01.md](MANUAL_ROAD_PROXY_FAILURE_2026-08-01.md)
- [CROSS_COMPANY_TRACK_REPLACEMENT_2026-08-01.md](CROSS_COMPANY_TRACK_REPLACEMENT_2026-08-01.md)
- [PROPOSAL_EDGE_OWNERSHIP_BUILD35924_2026-08-01.md](PROPOSAL_EDGE_OWNERSHIP_BUILD35924_2026-08-01.md)

## Current implemented conclusions

### Native turn proxy

The mod does not rely on an undocumented UI-player switch. It retains the original native player as the UI desk, creates Company 1 and Company 2 as native players, leases the active company’s supported assets into the desk, mirrors the active wallet, and settles on reconcile/cycle. Base edges are separated logically because direct legacy transfer is unsafe. They normally stay on the desk, but a depot/station construction transfer may natively cascade attached edges to their rightful logical company; both holders are validated explicitly.

### Strict local edit boundary

At `builder.proposalCreate`, positive existing source IDs are checked against the logical/pinned ownership map. A rival source returns `errorMessages` before `builder.apply`. Own sources, new negative IDs, and public/untracked infrastructure remain usable. Known line/vehicle/station/depot/construction GUI mutations are checked similarly. BuildProposal has its payload-aware native gate; 23 selected speed, line, vehicle, terrain, date, naming, and cheat/debug command tags also fail closed at their native visitors in network mode. Hook 0.12 promotes line tags 3-5 and line-targeted tags 28-29 beyond denial: it copies typed CreateLine/DeleteLine/UpdateLine/SetColor/SetName payloads after suppression and feeds the canonical operation protocol. Stock create/rename/color/delete and populated add/remove-stop widgets pass two-process visual proof. The other gated categories remain unavailable until they receive equivalent codecs and replay/postconditions.

### Canonical proposal transaction

Schema 5 normalizes the live-proven road/track/node slice plus named signal/waypoint edge objects into a pointer-free payload. It translates existing entity references through canonical IDs, recreates negative temporary IDs locally, names road/track/model resources by stable repository path instead of machine-local index, validates geometry/ownership and the native builder's quoted cost, issues a supported BuildProposal, enumerates and matches native outputs by geometry, performs supported ownership replacement when required, binds stable output slots, retires removed canonical inputs, and charges the canonical account ledger. A state-schema-19 prepare barrier first requires every peer to resolve the named resources and canonical inputs without mutating its world.

Schema 7 covers the stock modular passenger/cargo station placement family and bounded portable construction changes. Lua and Python independently validate stock module maps/graphs or named `.con`/`.module` data, then bind construction, station, station-group, depot, asset, edge-object, node, and edge outputs. It recognizes `ASSET_GROUP`-only roots, preserves source identities on observable upgrades, and rejects native helper no-ops. The stock 80-320 m/1-8-track placement matrix is human-live-proven; depot/station edit/removal and graphless stock assets now also pass the staged ordinary-UI two-process matrix. See [ORDINARY_UI_FACILITY_MATRIX_2026-08-04.md](ORDINARY_UI_FACILITY_MATRIX_2026-08-04.md), [NETWORK_STATION_SCHEMA4_2026-08-03.md](NETWORK_STATION_SCHEMA4_2026-08-03.md), and [EDGE_OBJECT_AND_CONSTRUCTION_SCHEMA6_2026-08-04.md](EDGE_OBJECT_AND_CONSTRUCTION_SCHEMA6_2026-08-04.md).

Full details: [CANONICAL_PROPOSAL_REPLAY_2026-08-02.md](CANONICAL_PROPOSAL_REPLAY_2026-08-02.md).

### Peer mapping and physical completion consensus

State schema 22 maps pre-existing shared-save assets to authoritative canonical owners, maps each machine's original native player to its assigned canonical company, persists canonical accounts, and retains construction/asset/edge-object manifests plus shared-clock, train-release authority, and line-stop departure-slot reservations. Public base nodes/edges can be lazily rebound by exact canonical geometry when a town-road junction was not in the original local map. The companion requires unanimous no-mutation prepare acknowledgements before a build, then matching two-peer physical completion records before it emits `proposal.build`. A failed prepare is non-fatal. The canonical builder quote is authoritative; the ordered outcome charges the canonical account and reconciles peer-local native wallet caches before the financial checkpoint. Match start and each physical success require matching format-3 model/canonical/structural/financial/train-release checkpoints before another gameplay intent can commit. Post-build mismatch, missing-peer timeout, native failure, or an unchanged upgrade postcondition faults closed. Host clock/train controls may bypass gameplay barriers so authority can rendezvous, slow, pause, or release a fully matched station round.

[OPERATIONAL_CAPTURE_LAB_2026-08-02.md](OPERATIONAL_CAPTURE_LAB_2026-08-02.md)
defines and records the separate populated-play investigation path. Two
independent standalone windows keep vanilla operations unrestricted while
collecting intermediate speed/time, autonomy, journal/account, native command
and passenger/cargo evidence. A parallel bounded GUI-event envelope covers
actions that bypass the Lua issuing wrapper without intercepting gameplay. It
is deliberately not a network-convergence test.

The real file-bridge/TCP path, player-2 Lua engine simulation, bidirectional two-live-game replay, and 600-tick finance/structure soak now pass. The audit can generate a checksummed coordinated-restart plan for the latest agreed boundary, while automatic native-save capture/reload remains open. Full details: [BIDIRECTIONAL_NETWORK_FINANCE_2026-08-02.md](BIDIRECTIONAL_NETWORK_FINANCE_2026-08-02.md), [LOCALHOST_TWO_INSTANCE_NETWORK_2026-08-02.md](LOCALHOST_TWO_INSTANCE_NETWORK_2026-08-02.md), [NETWORK_COMPLETION_CONSENSUS_2026-08-02.md](NETWORK_COMPLETION_CONSENSUS_2026-08-02.md), and [CHECKPOINT_BARRIERS_AND_RECOVERY_2026-08-02.md](CHECKPOINT_BARRIERS_AND_RECOVERY_2026-08-02.md).

### Audit boundary

Native callback payloads contain machine-local output IDs. They are held in module-local memory only. Engine receipt records a sanitized `proposal.finalise` action keyed by proposal ID; the handler consumes the local payload inside the audited `applyCommitted` boundary. This lets canonical outputs change without local IDs entering network/checkpoint/event actions and preserves digest continuity.

### Long-match retention

Proposal diagnostics previously accumulated forever and would reject the 33rd transaction. The queue now deterministically retains at most 16 oldest-relevant completed records when it needs space, never prunes queued work, and fails only when 32 proposals are genuinely in flight.

## Primary documented sources

- [Legacy game interface](https://wiki.transportfever2.com/script-doc/modules/game.interface.html)
- [User-interface events](https://wiki.transportfever2.com/doku.php?id=modding:userinterface)
- [Engine/entity API](https://wiki.transportfever2.com/api/modules/api.engine.html)
- [Commands and callbacks](https://wiki.transportfever2.com/api/modules/api.cmd.html)
- [Proposal/component types](https://wiki.transportfever2.com/api/modules/api.type.html)
- [Game-script lifecycle](https://wiki.transportfever2.com/doku.php?id=modding:gamescripts)

Relevant documented behavior used by the implementation:

- engine-state command callbacks can be immediate, while GUI/console work may complete in a later simulation update;
- SimpleProposal additions use temporary negative IDs, which can be rebuilt deterministically;
- a proposal may remove and add an edge rather than mutate it in place;
- `SegmentAndEntity.playerOwned` provides the supported ownership field;
- engine enumeration and component reads can discover results when callback vectors are empty.

## Investigation documents

- [TRAIN_CLOCK_RENDEZVOUS_AND_STATION_BARRIERS_2026-08-06.md](TRAIN_CLOCK_RENDEZVOUS_AND_STATION_BARRIERS_2026-08-06.md) - projected future-time clock barriers, paused telemetry, station-leg holds/releases, format-3 durability, automated fault/restart proof, and four-round populated localhost acceptance.
- [GUI_PLAYER_ENTITY_LOAD_CRASH_2026-08-06.md](GUI_PLAYER_ENTITY_LOAD_CRASH_2026-08-06.md) - deterministic post-init native entity-view crash, GUI-safe load projection, and clean replacement bootstrap.
- [PROPOSAL_PREPARE_IDENTITY_PURITY_2026-08-05.md](PROPOSAL_PREPARE_IDENTITY_PURITY_2026-08-05.md) - origin-only station-throat canonical mutation, read-only pre-consensus identity resolver, automated purity checks, and passing two-station track receipt.
- [STATION_CONSTRUCTION_SETTLE_TIMEOUT_2026-08-05.md](STATION_CONSTRUCTION_SETTLE_TIMEOUT_2026-08-05.md) - false native-result timeout after visibly successful station construction, bounded 600-update fix, delayed-result regression, and clean six-operation two-process checkpoint proof.
- [VEHICLE_PURCHASE_AND_ROUTE_PHASE_2026-08-05.md](VEHICLE_PURCHASE_AND_ROUTE_PHASE_2026-08-05.md) - typed stock railway purchase/assignment capture, consist namespace fix, canonical vehicle identity, route-phase policy, and the focused live-test boundary.
- [VANILLA_LINE_MANAGER_CAPTURE_2026-08-04.md](VANILLA_LINE_MANAGER_CAPTURE_2026-08-04.md) - exact Build 35924 tags 3-5 payload layouts, stop stride/fields, typed native queue, canonical replay path, automated evidence, fresh two-process create/update/delete proof, and the remaining human widget/stop visual test.
- [ORDINARY_UI_FACILITY_MATRIX_2026-08-04.md](ORDINARY_UI_FACILITY_MATRIX_2026-08-04.md) - passing staged two-process signals/depot/station/graphless-asset matrix, two last-mile fixes, audit receipts, and the new boundary.
- [FACILITY_UI_FAILURES_2026-08-04.md](FACILITY_UI_FAILURES_2026-08-04.md) - first broad two-process facility-UI failure evidence; sentinel edge-object recovery, four-visitor station-edit coalescing, signed-zero bridge repair, and native vanilla-speed capture.
- [SIGNAL_FACILITY_LIVE_PROOF_2026-08-04.md](SIGNAL_FACILITY_LIVE_PROOF_2026-08-04.md) - exact-build signal add/remove, facility custody, station edit, asset/depot/station removal, `ASSET_GROUP` discovery, no-op upgrade rejection, and evidence paths.
- [SCHEMA7_COMPACT_MANIFEST_LIVE_REGRESSION_2026-08-04.md](SCHEMA7_COMPACT_MANIFEST_LIVE_REGRESSION_2026-08-04.md) - reproducible oversized-state native crash, lazy scenery binding fix, and the passing two-process state-19/schema-7 receipt.
- [EDGE_OBJECT_AND_CONSTRUCTION_SCHEMA6_2026-08-04.md](EDGE_OBJECT_AND_CONSTRUCTION_SCHEMA6_2026-08-04.md) - schema-5 edge objects and schema-7 portable construction/asset design, validation, materialization, and remaining two-process matrix.
- [GENERIC_PREFLIGHT_AND_SHARED_CLOCK_2026-08-03.md](GENERIC_PREFLIGHT_AND_SHARED_CLOCK_2026-08-03.md) - public-town-road failure root cause, named data-resource portability, all-peer no-mutation prepare, adaptive shared speed, mod-compatibility boundary, and live test contract.
- [NETWORK_STATION_SCHEMA4_2026-08-03.md](NETWORK_STATION_SCHEMA4_2026-08-03.md) - exact exported station payload, schema-4 allow-list, engine replay, 28-output compound binding, finance normalization, automated proof, and next live test.
- [CONSTRUCTION_CODEC_SEAM_BUILD35924_2026-08-02.md](CONSTRUCTION_CODEC_SEAM_BUILD35924_2026-08-02.md) - exact construction capture surface, missing typed constructor, legacy replay seam, modular-station graph requirements, and fail-closed implementation plan.

- [BIDIRECTIONAL_NETWORK_FINANCE_2026-08-02.md](BIDIRECTIONAL_NETWORK_FINANCE_2026-08-02.md) — two-origin live replay, canonical account ledger, quoted proposal cost, native-wallet drift discovery, and 600-tick proof.
- [LOCALHOST_TWO_INSTANCE_NETWORK_2026-08-02.md](LOCALHOST_TWO_INSTANCE_NETWORK_2026-08-02.md) — two-process startup research, first end-to-end live network pass, cross-language/finance failures, and launcher consequences.

- [DEPOT_STATION_EDGE_CUSTODY_2026-08-02.md](DEPOT_STATION_EDGE_CUSTODY_2026-08-02.md) — depot failure root cause, rightful-company edge invariant, station-equivalent regression coverage, and four-cycle live proof.
- [CONSEQUENTIAL_COMMAND_GATES_BUILD35924_2026-08-02.md](CONSEQUENTIAL_COMMAND_GATES_BUILD35924_2026-08-02.md) — exact visitor-table validation, 23 fail-closed tags, APIs, and live suppress/authorize proof.

- [CANONICAL_PROPOSAL_REPLAY_2026-08-02.md](CANONICAL_PROPOSAL_REPLAY_2026-08-02.md) — schema 2, two-phase application, result matching, audit repair, and latest live proof.
- [SUPPORTED_API_BUILD_PROBE_2026-08-01.md](SUPPORTED_API_BUILD_PROBE_2026-08-01.md) — callable factory correction and documented road/track probes.
- [NATIVE_COMMAND_PIPELINE_BUILD35924_2026-08-01.md](NATIVE_COMMAND_PIPELINE_BUILD35924_2026-08-01.md) — native command layout, tag map, queued/direct paths, and gate.
- [NATIVE_HOOK_BUILD35924_2026-08-01.md](NATIVE_HOOK_BUILD35924_2026-08-01.md) — fail-closed hook design and signature evidence.
- [PROPOSAL_EDGE_OWNERSHIP_BUILD35924_2026-08-01.md](PROPOSAL_EDGE_OWNERSHIP_BUILD35924_2026-08-01.md) — arbitrary-player edge replacement and ID changes.
- [CROSS_COMPANY_TRACK_REPLACEMENT_2026-08-01.md](CROSS_COMPANY_TRACK_REPLACEMENT_2026-08-01.md) — manual ownership theft, exact topology pairs, and finance barrier.
- [MOBILITY_TELEMETRY_2026-08-01.md](MOBILITY_TELEMETRY_2026-08-01.md) — aggregate passenger/cargo observation boundary.
- [SAVE_LOAD_NATIVE_MANAGER_OWNERSHIP_2026-08-06.md](SAVE_LOAD_NATIVE_MANAGER_OWNERSHIP_2026-08-06.md) — stale native player IDs, manager invisibility, fail-closed ownership projection, and exact reload proof.
- [LIVE_VALIDATION_CHECKLIST.md](LIVE_VALIDATION_CHECKLIST.md) — next manual and two-peer experiments in order.
- [BUILD_REPORT_2026-07-31.md](BUILD_REPORT_2026-07-31.md) — historical delivery record with superseding addenda.

## Open questions

- Does every vanilla builder route pass through the captured Lua call and tag-15 visitor gate?
- How long can two independently running Build 35924 worlds remain equivalent after schema-5/7 transactions when autonomous systems and real services are introduced?
- What automatic native-save boundary and reload mechanism can turn a consensus fault into a coordinated recovery instead of a manual restart?
- What station-barrier latency and signaling interactions appear with two or more real trains on one populated line? Long-pause/speed-3 and deliberate slow-peer recovery now pass with one train.
- Do two populated stops retain their order and alternate-terminal selections through the actual widgets from both origins? Basic stock create/rename/color/delete/add/remove now passes.
- Which canonical payload, reference-translation, replay, and postcondition formats are required to turn each gated vehicle category into playable synchronized actions?
- Which consequential or autonomous mutation paths remain outside the selected 23 visitors?
- Can towns and industries be held stable for long dual-instance runs, then driven by host events?
- Where can native passengers/cargo be read and steered so presentation agrees with score?
