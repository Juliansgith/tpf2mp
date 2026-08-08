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
escape host authority.

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
  movement, exact hourly-rate proration, capacity allocation, and per-market
  evaluation. `economy_revenue.lua` owns passenger cohorts, distance fares,
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
  completed-trip settlement actions.
- `economy_public_view.lua` builds the display-only local-ID map and exact
  purchase/upkeep/service/company figures used by the standard-UI projection.
- `economy_demo.lua` contains developer-only seeded-market fixtures and has no
  production authority.
- `passenger_presentation.lua` owns exact endpoint queues, per-train loads,
  ordered-release boarding/alighting, migration, and the canonical digest/public
  projections. `passenger_cosmetics.lua` owns read-only native-person telemetry
  and the fail-closed optional-write boundary.
- `finance.lua` owns canonical network accounts and native-wallet reconciliation.
- `world.lua` owns native-world inventory, ownership, and autonomy;
  `world_station_reading.lua` owns station-group to town association reads;
  `world_operational_telemetry.lua` owns read-only clock, journal, autonomy,
  and composed operational snapshots.
- `corridor_binding.lua` derives line.register market/service facts (gravity
  demand, geometry/consist journey-headway-capacity), the per-peer station
  boards, settlement-coupled deterministic town growth, and the departure
  slot table; origin-computed or settlement-derived, re-exported through
  `world.lua`.
- `edge_ownership.lua` owns private/public edge custody rules.
- `proposal_codec.lua` validates and materializes portable construction/edge
  transactions.
- `operation_codec.lua` validates and materializes line and vehicle operations.

Runtime-controller modules:

- `runtime_config.lua` reads dynamic process/mod configuration. Its injected
  read boundary keeps tests independent from the real process environment.
  World-creation choices are inputs only until `match.initialise`; the ordered
  match rules and saved economy state are authoritative after that boundary.
- `state_schema.lua` exclusively creates and migrates persisted game state.
- `checkpoint_runtime.lua` owns authored/core digests, event records, checkpoint
  payloads, and checkpoint export barriers.
- `recovery_prepare_runtime.lua` owns game-side preparation/checkpoint handlers
  and the persisted, non-digested preparation status shown after save/load.
- `public_snapshot.lua` produces the read-only engine-to-GUI state projection.
- `match_runtime.lua` owns deterministic ranking, match completion, bankruptcy
  precedence, and running-match authorization.
- `operation_runtime.lua` owns canonical operation authorization, native result
  binding, postconditions, completion reports, and finance deltas.
- `proposal_runtime.lua` owns proposal prepare/build/finalize, construction
  stabilization, canonical output binding, physical completion, and finance
  normalization.
- `network_intent_runtime.lua` owns the local intent FIFO, host-order wait state,
  barrier back-pressure, bridge ingress, acknowledgement, and reset lifecycle.
- `network_followup_queue.lua` owns non-reentrant, coalesced authored work
  derived from commits; `network_bridge_consumer.lua` owns ordered inbox
  application and acknowledgements.
- `authored_followup_runtime.lua` owns strict town-development application,
  save-receipt acknowledgement, and development checkpoint export.
- `network_clock_runtime.lua` owns ordered native clock application, peer-health
  emission, future-time rendezvous/catch-up, paused heartbeats, physical
  line/vehicle pause prerequisites, calendar freeze, and manual-network match
  bootstrap.
- `vehicle_sync_runtime.lua` owns local canonical train arrival detection,
  native station holds, ordered release application/retry, and the digested
  station-round projection. `vehicle_sync_state.lua` owns its checkpoint view;
  `vehicle_sync_passengers.lua` atomically couples passenger state to releases
  and vehicle operations. None writes a native vehicle position.
- `validation_runtime.lua` owns both disposable standalone and two-process
  validation state machines. It has no production authority when validation is
  disabled.
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
- `gui_replay_runtime.lua` owns GUI-state proposal and line/vehicle command
  materialization, callback correlation, and result delivery to the engine.
- `native_hook.lua` parses native status and validates the fail-closed authority
  boundary exposed by the DLL.

Controllers receive a `getState` callback instead of retaining the initial state
table. Transport Fever can replace the saved table through `script.load`; a
captured table reference would therefore mutate stale state after loading.

## Companion modules

- `protocol.py` defines canonical envelopes and strict portable action schemas.
- `transport.py` owns framed socket I/O and connected-peer transport state.
- `client.py` owns client connection/retry and bridge forwarding.
- `anchor.py` owns the host's quiescent-boundary predicate and receipt truth;
  `anchor_io.py` owns peer-local native-save requests, hashes, persistent
  negative identities, and transient READY transport.
- `anchor_prepare.py` owns the one-action pause/quiescence/checkpoint state
  machine and fences new ordered work while it manufactures a save boundary.
- `restore_session.py` owns receipt-bound resume admission and the mandatory
  fresh-checkpoint fence; `host_status.py` owns the public companion projection.
- `network.py` owns host ordering, prepare/physical/checkpoint consensus, and
  re-exports `CommitClient` for compatibility.
- `consensus.py` owns tracker construction, deadlines, pending selection, and
  strict proposal/operation/clock/vehicle-sync payload validation. `network.py` retains
  outcome policy and durable broadcast ordering.
- `synchronization.py` owns the host's projected shared-clock policy,
  rendezvous/correction lifecycle, adaptive slowest-peer governor, canonical
  train station-round barrier, synchronization faults, and audit restoration.
  Clock skew may drive authority only when all fresh health samples describe
  the same current clock generation; mixed-generation projection is diagnostic.
- `bridge.py`, `checkpoint.py`, `restore.py`, and `recovery.py` own durable local
  transport, independent replay, all-peer restore plans, and native-save
  archives respectively.
- The long-running `watch_recovery_saves.ps1` process also owns a strictly local
  one-shot first-fault trigger. `collect_live_evidence.ps1` owns immutable bridge
  copying, copied-audit replay, bounded session-log tails, native status, and
  source/install fingerprints; neither tool mutates authority or performs a
  restore.

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
install/verify/uninstall round trip.

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
