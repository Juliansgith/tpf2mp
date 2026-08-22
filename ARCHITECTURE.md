# TPF2MP architecture

This document describes the source boundaries of the multiplayer prototype. It
is intentionally about code ownership and invariants; feature status remains in
`PROTOTYPE_STATUS.md` and `REMAINING_FROM_BRIEF.md`.

## Runtime shape

Each Transport Fever 2 process contains two isolated Lua states:

- the engine state owns canonical match state and applies host-ordered actions;
- the GUI state observes vanilla controls, captures bounded payloads, and sends
  sanitized intents to the engine state.

The companion process orders intents, coordinates all-peer prepare/physical/
checkpoint barriers, and distributes commits. The native DLL observes or gates
exact Build 35924 command visitors before an unsupported local mutation can
escape host authority. Hook `0.17.0` also owns the bounded bridge worker: the
game Lua thread signs and validates protocol envelopes but performs no numbered
bridge file I/O when the exact hook is active. The native worker transports
opaque bytes only; it never reads engine entities or applies commands.

`companion/tpf2mp/bridge.py` owns the durable numbered file cursor. Outbound
polling may inspect only the exact successor sequence, never enumerate session
history or skip a gap. Durable protocol/evidence records remain available;
only acknowledged replaceable clock-health and vehicle-sync source files older
than the 4,096-message tail are pruned. Every health report still updates live
authority, while the host audit retains one forensic clock-health sample per
peer per ten seconds instead of fsyncing every heartbeat. The host audit remains
the primary replay authority for durable actions, barriers, and checkpoints.

No machine-local entity ID is portable. Every peer binds its own native IDs to
stable canonical identities and reports portable physical postconditions.

## Game-mod modules

`tpf2_mp_1/res/config/game_script/tpf2_mp.lua` is the Transport Fever game
script entry point and orchestration root. It owns the engine/GUI callbacks,
action dispatcher, match/proxy lifecycle, and the small UI-window shell. New
domain behavior should not be implemented inline when an existing module
boundary applies.

Domain modules under `res/scripts/tpf2_mp`:

- `canonical.lua` owns canonical/local identity bindings and canonical digests.
- `economy.lua` owns deterministic demand, five-minute accounting state,
  delivery cursors, operating-cost stocks/residuals, signed wallet-cent carry,
  and scoring. `economy_flow.lua` owns generalized cost, pinned-logit share
  movement, exact hourly-rate proration, and per-market evaluation.
  `economy_allocation.lua` owns canonical largest-remainder choice, capacity
  admission, and the explicit waiting-demand remainder.
  `economy_feeder_access.lua` derives company-owned local
  road/tram access at exact intercity station groups; its frequency/capacity
  score is recomputed at settlement and never becomes a stale authored cache.
  `economy_revenue.lua` owns passenger cohorts, distance fares,
  and cargo unit-kilometre revenue. `economy_difficulty.lua` owns the four
  exact save presets and overflow-safe revenue scaling; `economy_town_demand.lua`
  owns model-town populations, growth residuals, and corridor-demand refresh.
- `economy_costs.lua` owns the compressed financial-year/interval cost
  conversions and exact
  canonical capital allocation; `economy_asset_cost_runtime.lua` converts
  consensus proposal deltas into infrastructure capital; `vehicle_cost_runtime.lua`
  converts all-peer resolved native `MAINTENANCE_COST` postconditions into
  durable vehicle costs, including uniquely manifest-bound starting vehicles;
  `economy_clock_runtime.lua` submits only the host's due synchronized boundary;
  `economy_action_runtime.lua` constructs portable line registration and
  completed-trip settlement actions; `economy_line_registration.lua` stages
  economy, canonical, vehicle-cost, passenger, and cargo changes as one
  all-or-nothing registration transaction; `economy_pending_delivery.lua`
  builds the unified passenger/cargo delivery snapshot; and
  `economy_settlement_transaction.lua` stages economy evaluation, freight stock
  transfer, settlement recording, and both presentation epochs before any live
  state is adopted. `delivery_snapshot.lua` validates and merges the two
  independently monotonic delivery domains. `economy_service_quarantine.lua`
  converts an already-registered but newly unsupported service into an
  ordered portable disabled copy, without leaking native IDs or local read
  diagnostics.
- `economy_public_view.lua` builds the display-only local-ID map and exact
  purchase/upkeep/service/company figures used by the standard-UI projection.
- `economy_demo.lua` contains developer-only seeded-market fixtures and has no
  production authority.
- `passenger_presentation.lua` owns exact passenger endpoint queues, per-train
  loads, ordered-release boarding/alighting, migration, and canonical
  digest/public projections. `cargo_presentation.lua` owns the corresponding
  exact freight queues, each vehicle's named-cargo capacity and load,
  boarding/delivery/discard conservation, settlement epochs, and public
  projection. `cargo_presentation_validation.lua` owns save-boundary
  conservation and cross-checks against economy contracts, freight cursors,
  economy payment cursors, and synchronized vehicle rounds.
- `aboard_milestone_runtime.lua` owns the shared host-only, one-shot proof
  protocol for the first non-zero authored load. Thin freight and passenger
  policies select the ledger; the passenger policy admits only a valid
  same-town ROAD/TRAM service with two distinct station groups, so an earlier
  rail departure cannot consume feeder evidence. `aboard_milestone_integration.lua`
  is the game-script seam. `aboard_milestone_witness.lua` owns the strict wire
  shape and monotonic round/boarding-cursor proof that survives a vehicle
  alighting before the checkpoint. `aboard_milestone_followup.lua` coalesces
  retries and maintains a FIFO evidence-priority prefix ahead of uncommitted
  physical/registration work. Milestones verify existing ledger state and open
  a checkpoint; they never mutate a load a second time. A semantically stale
  witness is a non-proof no-op so a later release can retry without faulting a
  healthy match.
  `passenger_cosmetics.lua` owns read-only native-person telemetry
  and the fail-closed optional-write boundary.
- `finance.lua` owns canonical network accounts and native-wallet reconciliation.
- `world.lua` owns native-world inventory, ownership, and autonomy;
  `world_vehicle_restore_phase.lua` owns the local-ID-free discrete vehicle
  phase projection and its fail-closed native-save safety predicate;
  `native_command_authority.lua` is the single Lua seam that grants exact
  one-shot native visitor tokens to mod-authored commands and revokes an unused
  token when command submission fails before the visitor;
  `world_station_reading.lua` owns station-group to town association reads;
  `world_line_reading.lua` resolves each exact line stop through its station
  group and classifies passenger/cargo/mixed transport mode fail-closed;
  `world_operational_telemetry.lua` owns read-only clock, journal, autonomy,
  and composed operational snapshots.
- `corridor_binding.lua` derives line.register market/service facts (gravity
  demand, local/corridor scope, carrier, endpoint-town identity, and
  geometry/consist journey-headway-capacity), the per-peer station boards,
  settlement-coupled deterministic town growth, and the departure slot table;
  origin-computed or settlement-derived, re-exported through `world.lua`.
- `vehicle_resource_facts.lua` classifies every load configuration in a
  consist by portable cargo resource type and aggregates all consists assigned
  to a line into conservative passenger/cargo/mixed capacity, carrier, and
  speed facts. Unknown unpowered parts are neutral; conflicting known carriers
  become `MIXED`.
- `industry_resource_loader.lua` wraps the loaded construction repository at
  resource-load time and emits immutable content-addressed recipe artifacts.
  `industry_resource_facts.lua`, `industry_resource_view_reader.lua`,
  `industry_resource_merge.lua`, and `industry_resource_artifact.lua` own
  bounded extraction, evaluated-variant normalization, strict deterministic
  merge, and artifact encoding. `world_industry_reading.lua` binds live
  `SIM_BUILDING` roots back to portable construction resource names without
  making native IDs authoritative. `freight_industry_model.lua` owns the
  canonical recipe/bootstrap schema, per-industry input/output inventories,
  exact production residuals, production/consumption totals, pure settlement
  advancement, and digest/public views. Cargo deposits target a canonical
  industry plus an explicit recipe stock index whenever one cargo type occurs
  in more than one stock slot; cargo type alone is accepted only when unique.
  `freight_service_binding.lua` derives a portable source/sink/cargo contract
  from exact live stops, recipes, and every assigned consist's named capacity.
  `freight_transport_settlement.lua` reserves boarded and delivered stock as
  one aggregate boundary transaction and retires a line's contract cursor at
  ordered line-deletion consensus without erasing lifetime transport totals;
  `freight_transport_validation.lua`
  enforces saved-contract and cursor integrity; `freight_industry_public.lua`
  builds the stock/production/transport view without exposing local IDs.
- `edge_ownership.lua` owns private/public edge custody rules.
- `proposal_codec.lua` validates and materializes portable construction/edge
  transactions.
- `operation_codec.lua` validates and materializes line and vehicle operation
  schema 4. A bounded stock multi-selection sale is one sorted canonical
  transaction even though the public engine replay primitive remains scalar.
- `vehicle_sync_state.lua` owns which native stops are synchronization anchors:
  every stop for conservative passenger carriers, route endpoints for urban
  road/tram services, and exact contract endpoints for freight.

Runtime-controller modules:

- `runtime_config.lua` reads dynamic process/mod configuration. Its injected
  read boundary keeps tests independent from the real process environment.
  World-creation choices are inputs only until `match.initialise`; the ordered
  match rules and saved economy state are authoritative after that boundary.
- `state_schema.lua` exclusively creates and migrates persisted game state.
- `state_retention.lua` is the save-boundary compactor. It retains a 64-event
  scalar/hash tail and independently bounded diagnostic capture tails, removing
  nested native/proposal graphs that are neither authored truth nor replay
  authority. Compaction is idempotent and never changes canonical/model digest
  inputs.
- `state_success_normalization.lua` removes the narrowly identified historical
  false-error residue from records whose explicit success proof is retained.
- `checkpoint_runtime.lua` owns authored/core digests, event records, checkpoint
  payloads, and checkpoint export barriers.
- `recovery_prepare_runtime.lua` owns game-side preparation/checkpoint handlers
  and the persisted, non-digested preparation status shown after save/load.
- `recovery_native_save_runtime.lua` derives the bounded peer-specific save
  name and attempts a native `SaveGame` command only while the companion and
  local checkpoint state identify the same READY boundary and current core.
  Build 35924 exposes no public factory, so failure is diagnostic and the
  exact-process watcher owns the guarded stock-UI fallback. This machine-local
  state is deliberately excluded from the authored digest.
- `public_snapshot.lua` produces the read-only engine-to-GUI state projection.
  `capture_public_view.lua` reduces high-volume local capture histories to
  counters, maps, and retained-tail metadata before they cross into GUI state.
- `research_report.lua` owns the full diagnostic export projection, current
  limitation inventory, bridge receipt, and failure status.
- `match_runtime.lua` owns deterministic ranking, match completion, bankruptcy
  precedence, and running-match authorization.
- `operation_runtime.lua` owns canonical operation authorization, native result
  binding, postconditions, completion reports, and finance deltas.
- `proposal_runtime.lua` owns proposal prepare/build/finalize, construction
  stabilization, canonical output binding, physical completion, and finance
  normalization. `network_finance_housekeeping.lua` owns the adaptive cadence
  for the native wallet presentation cache and its barrier-safe deferral.
- `network_intent_runtime.lua` owns the local intent FIFO, host-order wait state,
  barrier back-pressure, bridge ingress, acknowledgement, and reset lifecycle.
  `network_busy_rejection.lua` is its fail-fast policy for suppressed
  construction input that must never become delayed physical work.
- `network_pump_runtime.lua` owns the authority-preserving engine cadence for
  bridge ingress, clocks, deferred work, vehicle synchronization, and stable
  content/freight maintenance. `performance_runtime.lua` supplies bounded
  native-monotonic task timings plus explicit scheduler run/skip counters; its
  output is diagnostic and never enters an authored digest.
- `network_followup_queue.lua` owns non-reentrant, coalesced authored work
  derived from commits; `service_registration_runtime.lua` owns its bounded
  submitted/quarantined/recovered diagnostic and permanent-failure policy;
  `network_bridge_consumer.lua` owns ordered inbox application and
  acknowledgements.
- `industry_registry_sidecar.lua` reads and revalidates the exact
  session/peer-bound companion registry. `industry_content_runtime.lua` owns
  state migration, local/live binding, ordered two-peer content attestations,
  agreement/fault semantics, and the checkpoint projection. Match
  initialization is gated on that agreement. `freight_industry_runtime.lua`
  lets only the host author a sorted bootstrap after content agreement, applies
  it only when every local live binding and economy epoch match, checkpoints
  it, and advances production atomically with economy settlement.
  `freight_industry_revalidation.lua` fails closed when a saved ledger no
  longer matches freshly attested content or current canonical live-industry
  bindings. Freight transport is applied only through the staged economy
  boundary: aggregate reservations withdraw source output, deposit the exact
  destination stock, and advance production and both presentation ledgers
  atomically.
- `authored_followup_runtime.lua` owns strict town-development application,
  save-receipt acknowledgement, and development checkpoint export.
- `network_clock_runtime.lua` owns ordered native clock application, peer-health
  emission, future-time rendezvous/catch-up, paused heartbeats, physical
  line/vehicle pause prerequisites, calendar freeze, and manual-network match
  bootstrap.
- `vehicle_sync_runtime.lua` owns local canonical train arrival detection,
  native station holds, ordered release application/retry, and the digested
  station-round projection. `vehicle_sync_state.lua` owns its checkpoint view;
  `vehicle_sync_release_runtime.lua` validates and applies ordered releases;
  `vehicle_sync_passengers.lua` atomically couples both passenger and cargo
  state to releases and vehicle operations. None writes a native vehicle
  position or treats native agents as authoritative.
- `validation_runtime.lua` owns both disposable standalone and two-process
  validation state machines. It has no production authority when validation is
  disabled.
- `validation_content_gate.lua` prevents validator match initialization from
  racing the content attestation or any other ordered-lane work.
- `validation_town_development.lua` owns the bounded three-round physical-town
  experiment and its final ordered structural checkpoint.
- `validation_clock.lua` owns validator-only shared-clock readiness, settled
  state, ordered-event, and rendezvous acceptance predicates.
- `validation_construction.lua` contains stock resources used only by disposable
  engine validation.
- `operational_capture_runtime.lua` samples independent-world diagnostics and
  emits policy, population, native-pipeline, account, and digest evidence; it
  never participates in multiplayer authority.

GUI/native-adapter modules:

- `gui_state.lua` creates machine-local GUI state with no shared mutable tables.
- `gui_capture.lua` projects bounded vanilla proposal/userdata payloads and owns
  station-preview caching/rebasing helpers.
- `gui_network_bootstrap.lua` re-arms native game/calendar pause authority in
  the GUI Lua state after a saved world replaces the pre-load engine state.
- `gui_view.lua` formats the prototype overlay from a public snapshot.
  `native_observation_telemetry.lua` emits only a digest and bounded shape
  summary for routine native observations; complete bounded shapes remain in
  research evidence rather than crossing the durable bridge every update.
- `gui_authoritative_text.lua` formats canonical company, service, vehicle,
  station, fleet, and toolbar projections without retaining native GUI objects.
- `gui_stock_presentation.lua` is the standard-UI adapter. It overwrites the
  normal account/earnings/passenger totals and mutates only existing native
  leaves: conflicting load/queue/history controls are hidden, relabelled, or
  given an authoritative tooltip. It never inserts a mod-created child into a
  stock layout; Build 35924's hidden-manager `CSelector` rejects public
  `api.gui` layout children during a later checked downcast. Missing stock IDs
  fail soft, and full synchronized details remain in the Multiplayer window.
- `gui_entry_points.lua` idempotently mounts the overlay reopen controls into
  the stock `gameInfo.layout` and the parent of the pause menu's quit button.
- `gui_event_runtime.lua` owns vanilla GUI event authorization, native observer
  installation, bounded build/line/speed/vehicle capture, and GUI callback lifecycle.
- `gui_line_command_codec.lua` strictly decodes the pointer-free native line
  envelope, including primary terminals and typed `{station, terminal}`
  alternative-platform selections.
- `gui_replay_quarantine.lua` owns the machine-local no-dereference window for
  builder ghosts while a delayed canonical BuildProposal settles.
- `gui_construction_submission.lua` projects ordered-lane busy state into the
  stock builder error contract and makes construction capture single-flight.
- `gui_replay_runtime.lua` owns GUI-state proposal and line/vehicle command
  materialization, callback correlation, and result delivery to the engine.
- `native_hook.lua` parses native status and validates the fail-closed authority
  boundary exposed by the DLL.

Controllers receive a `getState` callback instead of retaining the initial state
table. Transport Fever can replace the saved table through `script.load`; a
captured table reference would therefore mutate stale state after loading.

## Companion modules

- `protocol.py` defines canonical envelopes and strict portable action schemas;
  `line_registration_protocol.py` owns carrier/scope/endpoint metadata checks
  so a claimed feeder cannot disagree with its authored market.
- `industry_content.py` strictly validates and merges peer-local loader
  artifacts into the deterministic companion registry; `host_intents.py`
  centralizes host-authored ordered intents, including content claims.
- `freight_protocol.py` owns the bounded exact-field validation and canonical
  digest contract for `freight.industry_bootstrap`; `freight.py` independently
  applies that bootstrap and replays the Lua integer inventory/production
  arithmetic. `freight_transport.py` independently replays aggregate source
  withdrawal, destination deposit, transport cursors, and idle-line behavior.
  `freight_checkpoint.py` and `cargo_checkpoint.py` strictly validate the full
  freight and presentation projections, including exact per-line conservation.
  `checkpoint.py` includes those ledgers in the model/core projection and
  advances them on every replayed economy settlement. `live_evidence.py` owns
  the shared strict audit sequence, physical-outcome, fault, roster, and exact
  two-peer checkpoint-payload scanner. `freight_live_report.py` and
  `passenger_feeder_live_report.py` add only their domain proof ladders; they
  must not fork their own definitions of physical or checkpoint consensus.
- `transport.py` owns framed socket I/O and connected-peer transport state.
- `client.py` owns client connection/retry and bridge forwarding.
- `anchor.py` owns the host's quiescent-boundary predicate and receipt truth;
  `anchor_io.py` owns peer-local native-save requests, hashes, persistent
  negative identities, and transient READY transport.
- `anchor_prepare.py` owns the one-action drain/pause/checkpoint state machine
  and fences new ordered work while it manufactures a save boundary;
  `anchor_prepare_checkpoint.py` owns the host-generated checkpoint control;
  `anchor_prepare_drain.py` owns fresh-health drain proofs and the internal
  resume/re-pause transitions needed when station rounds cross that boundary;
  `anchor_prepare_phase.py` orders two consecutive paused mobility samples and
  refuses a boundary unless every peer's canonical vehicle/next-stop phase
  agrees and each game reports a stable native/barrier restore phase;
  `anchor_prepare_phase_recovery.py` advances an unbound vehicle to one shared
  station boundary before resampling. The final proof also carries identical,
  sorted canonical line/station-round cursors for every active vehicle.
  Exact native coordinates remain deliberately non-authoritative.
- `restore_session.py` owns receipt-bound resume admission and the mandatory
  fresh-checkpoint fence. The plan core authenticates the pre-migration source;
  identical fresh convergence keys authenticate the peers' current migrated
  state. A schema migration is therefore allowed to change core digest but not
  to bypass source validation or all-peer convergence. Before opening that
  fence, it seeds the otherwise-empty station barrier from the signed vehicle
  cursors so the first post-restart report is exactly round N+1. `host_status.py` owns the
  public companion projection.
- `restore_plan_exchange.py` owns fail-closed host publication, pinned-link
  delivery, late-client replay, and durable client receipt of a verified plan.
- `network.py` owns host ordering, prepare/physical/checkpoint consensus, and
  re-exports `CommitClient` for compatibility.
- `consensus.py` owns tracker construction, deadlines, pending selection, and
  strict proposal/operation/clock/vehicle-sync payload validation. `network.py` retains
  outcome policy and durable broadcast ordering.
- `synchronization.py` owns shared-clock actions, rendezvous/correction and
  native-pause fencing, synchronization faults, and audit restoration.
  `clock_governor.py` owns the adaptive slowest-peer policy and hysteresis; it
  compares measured game-time progress, never render/update frame rate.
  `vehicle_barrier.py` owns canonical train station rounds and uses the same
  debounced skew predicate before release. Clock skew may drive authority only
  when all fresh health samples describe the same current clock generation;
  mixed-generation projection is diagnostic.
- `bridge.py`, `checkpoint.py`, `restore.py`, and `recovery.py` own durable local
  transport, independent replay, coordinated restore analysis, and native-save
  archives respectively. `restore_plan.py` owns strict legacy v2/v3 and current
  v6 plan schemas; v4 lacks native route phase and v5 lacks the companion
  station-round cursor, so both are deliberately retired for network resume.
  plan construction requires exactly one policy choice: a bound match-content
  profile or an explicit opt-in to the weaker policy-unbound legacy plan.
  `native_save.py` owns stable `.sav`/`.sav.lua` hashing; v6 binds both, the
  source match profile, and the paused vehicle phase/cursor proof.
  `vehicle_phase_proof.py` and the matching Lua normalizer own that proof's
  exact cross-runtime schema. `session_identity.py` and the matching Lua
  `restore_session_identity.lua` keep derived resume identities portable and
  within the launcher's 64-character boundary. `local_restore.py` admits only
  contained, receipt-bound, peer-specific plan/archive/save sets and constructs
  a pair only when both roles bind the same verified plan and boundary.
  `audit_log.py` owns Windows-sharing-safe journal persistence and
  closed-handle snapshots; `host_runtime.py` owns listener/poll liveness and the
  observable fail-closed audit-fault state. `audit_replay.py` owns whole-audit
  ordering, physical consensus, checkpoint, and digest-chain verification; its
  strict settled mode additionally rejects incomplete terminal lanes and
  commits awaiting peer digests. `cli.py` is only the command dispatcher.
- The long-running `watch_recovery_saves.ps1` process waits for the stable
  automatically named native save (or a correctly prefixed manual fallback).
  If the public save factory is absent, it serializes same-machine peers through
  `save_recovery_via_ui.ps1`, which operates the stock Save dialog only at the
  READY boundary explicitly created by `recovery.prepare`; an incidental
  quiescent checkpoint may permit a manual save but never focus-stealing UI
  automation. `recovery_save_common.ps1` shares the <=50-character naming
  contract and resolves the exact receipt-bound bytes across retries. Native UI
  acquisition and native file completion have separate deadlines; the latter is
  bounded at 1,200 seconds and keeps the same-machine save lock until the stable
  `.sav`/`.sav.lua` pair exists. The watcher
  hands its hash to the ordered receipt path, passes the session's exact
  match-content profile into host plan generation, atomically publishes the
  host plan, and re-binds player2's retained local archive after verified
  delivery. It also owns a strictly local
  one-shot first-fault trigger. `collect_live_evidence.ps1` owns immutable
  bridge copying, copied-audit replay, bounded session-log tails, native status,
  and source/install fingerprints; neither tool mutates authority or performs
  a restore.
- `recovery_plan_common.ps1` is the testable shell boundary for metadata
  verification, byte-exact atomic publication, durable peer-plan copying, and
  receipt-bound re-archiving. The watcher owns retry/state policy but must not
  duplicate those file/verification operations.
- `automatic_restore_capture.ps1` owns the fail-closed wait for two current-PID
  watcher records naming one boundary and one plan checksum. The launcher
  marker it writes can only request the ordinary host-authored
  `recovery.prepare`; it grants no native-save or restore authority.
  `run_fresh_local_restore_cycle.ps1` composes the existing paired discovery,
  capture runner, process cleanup, and paired reload acceptance into the
  unattended localhost recovery gate.

## Native modules

- `build_profile.hpp` is the only authority for exact Build 35924 RVAs,
  signatures, layouts, and visitor tags.
- `native_common.cpp` owns executable validation and shared file utilities.
- `native_command_codec.cpp` owns bounded exact-layout reads plus typed
  line/name/color decoding, eight-byte `StationTerminal` vector reads, and
  pointer-free line encoding. `native_vehicle_command_codec.cpp` owns the
  exact-profile pointer-free vehicle scalar decoder and V2 encoder.
- `native_hook_status.cpp` owns the stable native status JSON schema and formats
  a lock-protected view supplied by the hook.
- `injector.cpp` owns exact-profile verification and DLL injection.
- `hook_dll.cpp` owns hook installation, visitor gates, capture queues, Lua
  bindings, and the synchronized native state presented to the support modules.
  Its exact Build 35924 authority surface is 31 visitors: the earlier 23
  consequential tags plus tags 17-24 for town/industry autonomy. Only tags 19,
  20, and 23 have authored gameplay token consumers.

Future typed vehicle layouts belong in `native_vehicle_command_codec.cpp`, never
inline in detour bodies. Every such change requires native build/CTest and exact-
executable profile verification in the same commit.

## Dependency and authority rules

1. Domain modules may depend on smaller domain utilities; they must not require
   the game-script entry point.
2. GUI capture may retain native IDs only in machine-local queues. A codec must
   translate them before an intent becomes portable.
3. Construction and suppressible operations never mutate a native world before
   host ordering and the required prepare barrier. The five Build-35924 line
   visitors are the documented exception because rejection asserts the stock
   widget: they use optimistic origin pass-through, an origin token, bounded
   capture, and fail-closed residue handling for every post-apply loss path.
4. A native success callback is insufficient. Physical output/postconditions
   and then a checkpoint must agree on all required peers.
5. Canonical finance is authoritative. Native wallets are display/execution
   caches and are never summed across peers. Native trip/maintenance/interest
   entries are quarantined by reconciliation; only ordered model net dollars,
   with authored sub-dollar carry, change competitive balances.
6. Unsupported or ambiguous payloads fail closed. A gate without a typed codec,
   authorization, replay, and postcondition is not a synchronized feature.
7. GUI view/state modules must not enter canonical digests or saved match state.
8. Schema changes require an explicit state/protocol version decision and a
   migration or a documented fresh-match requirement.
9. Native vehicle coordinates remain per-peer presentation state. Assigned
   canonical trains may start a leg only after the complete fixed peer roster
   has reported and received the same canonical station-round release.
10. Passenger queue/load changes occur only inside authored settlement or
    station-release actions. Native person IDs and stock agent counts never
    enter revenue, score, the passenger ledger, or a checkpoint. Passenger
    revenue advances only from the monotonic completed-leg/boarded-fare ledger
    and each cumulative delivery cursor can be paid once.
11. Economy time is the synchronized simulation clock. Only Player 1 may
    submit the exact next 300-second boundary, only after local
    physical/checkpoint work is quiescent. Invalid or repeated boundaries
    reject before any share, rate residual, delivery cursor, upkeep, scheduler,
    or payout-residual mutation.
12. Purchased canonical vehicles accrue upkeep whether assigned, running, or
    parked. Private infrastructure accrues against active attributed capital;
    replacement carries old capital plus new spend, deletion retires it, and
    public town roads never enter a company's upkeep base.
13. Economy difficulty is a save-owned rule, not a peer-local live control.
    Current match actions carry both the preset key and its exact multiplier;
    no gameplay action may mutate them after initialization. Difficulty scales
    gross revenue only and its sub-cent-in-ppm residual is checkpoint state.
14. Native town population and crowd scaling never enter competitive demand.
    Registration supplies a building-count baseline; completed authored
    passenger service advances canonical model towns, and their future demand
    is digest-projected and replayed in both Lua and Python. Ordered physical
    town development remains a separate optional presentation experiment.
15. An authored follow-up retries only failures that can plausibly change
    without a new player/world action. In particular, bridge emission failure
    retains a line registration, while a route-facts normalization failure is
    quarantined and retried only after a fresh edit/assignment. Unsupported
    local or freight routes must not keep recovery readiness permanently busy.

## Adding a synchronized vehicle action

Vehicle work should follow this path:

1. Add or tighten the portable schema in `operation_codec.lua` and Python
   `protocol.py` without local IDs.
2. Add an exact-build native typed decoder/gate for the vanilla command.
3. Convert the GUI/native capture into a canonical intent.
4. Authorize, materialize, bind, and verify it in `operation_runtime.lua`.
5. Add host physical-consensus/checkpoint sequencing in `network.py` only if the
   existing generic operation path is insufficient.
6. Add codec, runtime-module, engine/GUI, companion, and two-process tests before
   promoting the native visitor from fail-closed to supported.

## Test gates

`tools/run_tests.ps1` is the offline behavioral contract. It covers pure Lua,
runtime-module boundaries, engine persistence, company mapping, hot-seat,
GUI/native capture, 1,024-event randomized long replay, first-fault bundle
fixtures, PowerShell syntax, launcher smoke tests, Python protocol/network
tests, and cross-language checkpoint replay.

Native changes additionally require `tools/build_native_hook.ps1`. Release-tree
or installer changes require `tools/package_release.ps1`, which performs an
install/verify/uninstall round trip. New release manifests use format 2 and bind
every file set to the exact 40-character Git commit plus an explicit clean/dirty
source flag. Packaging refuses dirty source by default; format-1 verification is
retained only for already-produced legacy archives. Installation commits the
versioned support tree, active mod, and schema-2 current pointer transactionally;
post-copy verification failure restores every prior surface automatically.

`tools/check_source_boundaries.ps1` is a ratchet. Production source budgets may
be lowered after an extraction; raising one requires a deliberate architecture
decision. A production file approaching 1,200 lines should receive a boundary
review, and crossing 1,600 lines requires a documented exception. Generated
artifacts, runtime evidence, native build output, and release archives never
belong in Git.

## Remaining structural work

No further size-driven extraction is required before feature work resumes. The
remaining large files have explicit ceilings. Split them only along these seams
when change pressure reaches them:

1. match/proxy lifecycle and the handler table from `tpf2_mp.lua`;
2. portable operation/proposal action normalization from `tpf2_mp.lua`;
3. outcome emission/resolution policy from `network.py`;
4. hook installation versus detour execution from `hook_dll.cpp`;
5. companion integration tests by protocol, consensus, and socket concerns.

Structural moves remain behavior-preserving commits protected by the existing
suite; protocol, save-schema, and gameplay changes belong in separate commits.
