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
- `economy.lua` owns deterministic demand, settlement, and scoring.
- `finance.lua` owns canonical network accounts and native-wallet reconciliation.
- `world.lua` owns native-world inventory, ownership, autonomy, and telemetry.
- `edge_ownership.lua` owns private/public edge custody rules.
- `proposal_codec.lua` validates and materializes portable construction/edge
  transactions.
- `operation_codec.lua` validates and materializes line and vehicle operations.

Runtime-controller modules:

- `runtime_config.lua` reads dynamic process/mod configuration. Its injected
  read boundary keeps tests independent from the real process environment.
- `state_schema.lua` exclusively creates and migrates persisted game state.
- `checkpoint_runtime.lua` owns authored/core digests, event records, checkpoint
  payloads, and checkpoint export barriers.
- `public_snapshot.lua` produces the read-only engine-to-GUI state projection.
- `operation_runtime.lua` owns canonical operation authorization, native result
  binding, postconditions, completion reports, and finance deltas.
- `proposal_runtime.lua` owns proposal prepare/build/finalize, construction
  stabilization, canonical output binding, physical completion, and finance
  normalization.
- `network_intent_runtime.lua` owns the local intent FIFO, host-order wait state,
  barrier back-pressure, bridge ingress, acknowledgement, and reset lifecycle.
- `network_clock_runtime.lua` owns ordered native clock application, peer-health
  emission, calendar freeze, and manual-network match bootstrap.
- `validation_runtime.lua` owns both disposable standalone and two-process
  validation state machines. It has no production authority when validation is
  disabled.
- `validation_construction.lua` contains stock resources used only by disposable
  engine validation.

GUI/native-adapter modules:

- `gui_state.lua` creates machine-local GUI state with no shared mutable tables.
- `gui_capture.lua` projects bounded vanilla proposal/userdata payloads and owns
  station-preview caching/rebasing helpers.
- `gui_view.lua` formats the prototype overlay from a public snapshot.
- `gui_event_runtime.lua` owns vanilla GUI event authorization, native observer
  installation, bounded build/line/speed capture, and GUI callback lifecycle.
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
- `network.py` owns host ordering, prepare/physical/checkpoint consensus, shared
  clock policy, and re-exports `CommitClient` for compatibility.
- `consensus.py` owns tracker construction, deadlines, pending selection, and
  strict proposal/operation/clock payload validation. `network.py` retains
  outcome policy and durable broadcast ordering.
- `bridge.py`, `checkpoint.py`, and `recovery.py` own durable local transport,
  independent replay, and recovery archives respectively.

## Native modules

- `build_profile.hpp` is the only authority for exact Build 35924 RVAs,
  signatures, layouts, and visitor tags.
- `native_common.cpp` owns executable validation and shared file utilities.
- `native_command_codec.cpp` owns bounded exact-layout reads plus typed
  line/name/color command decoding and pointer-free encoding.
- `native_hook_status.cpp` owns the stable native status JSON schema and formats
  a lock-protected view supplied by the hook.
- `injector.cpp` owns exact-profile verification and DLL injection.
- `hook_dll.cpp` owns hook installation, visitor gates, capture queues, Lua
  bindings, and the synchronized native state presented to the support modules.

Future typed vehicle layouts belong in `native_command_codec.cpp`, never inline
in detour bodies. Every such change requires native build/CTest and exact-
executable profile verification in the same commit.

## Dependency and authority rules

1. Domain modules may depend on smaller domain utilities; they must not require
   the game-script entry point.
2. GUI capture may retain native IDs only in machine-local queues. A codec must
   translate them before an intent becomes portable.
3. Network input never mutates a native world before host ordering and the
   required prepare barrier.
4. A native success callback is insufficient. Physical output/postconditions
   and then a checkpoint must agree on all required peers.
5. Canonical finance is authoritative. Native wallets are display/execution
   caches and are never summed across peers.
6. Unsupported or ambiguous payloads fail closed. A gate without a typed codec,
   authorization, replay, and postcondition is not a synchronized feature.
7. GUI view/state modules must not enter canonical digests or saved match state.
8. Schema changes require an explicit state/protocol version decision and a
   migration or a documented fresh-match requirement.

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
GUI/native capture, long replay, PowerShell syntax, launcher smoke tests, Python
protocol/network tests, and cross-language checkpoint replay.

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
