# TPF2MP prototype status

Last updated: 2026-08-04 for prototype `0.21.2-alpha`, state schema `19`,
checkpoint format `2`, edge proposal schema `5`, construction proposal schema
`7`, and native hook `0.12.0`.

## Executive status

TPF2MP contains two usable but differently mature modes:

- **Local hot-seat:** two persistent native companies, separate wallets and
  logical assets, a temporary turn desk, rival-edit protection, deterministic
  demand/fare/scoring rules, save state, and checkpoints. This is playable now
  within the tested asset/custody boundary.
- **Same-area network prototype:** two independent game processes load the same
  pinned save, map it to canonical identities, exchange host-ordered actions,
  preflight construction on every peer before mutation, require physical result
  consensus, reconcile canonical finances, share an adaptive simulation clock,
  and stop at all-peer checkpoints. Roads, tracks, upgrades, stock station
  placement, signals/waypoints, a rail depot, station editing/removal, bench
  placement/removal, and lamp/fence placement are live-proven through ordinary two-process
  UI actions. The facility slice includes rival denial, owner use/removal,
  physical consensus, and post-action checkpoints. This is still not arbitrary
  vanilla play: the line lifecycle has just reached typed ordinary-UI capture
  but still needs its first human two-process proof; vehicle lifecycle, complex topology, scripted callbacks,
  autonomous drift, and a two-computer session remain open.

The network architecture has crossed the populated-world convergence gate. It
has not crossed the finished-product gate.

## Strongest current evidence

`runtime/localhost-live/populated-network-ownershipfix-20260803` passed with two
real Build 35924 processes loading the same populated 1992 save. The source
world contained 2 towns, 5 industries, 363 constructions, a depot, a passenger
line, and a running-stock vehicle. Both peers assigned the pre-existing network
to the same canonical company, applied one private track transaction from each
peer, and completed with:

| Domain | Both peers |
|---|---:|
| Core | `7a1b9f9d` |
| Model | `5b59ecf2` |
| Structure | `07db112f` |
| Mobility | `a7ae06ac` |

The independent host audit verified 5 commits, 5 controls, 68 telemetry
records, 5 mobility convergences, 2/0/0 complete/faulted/pending physical
proposals, 3/0/0 checkpoint barriers, 6 peer checkpoints, and 34 events with no
consensus or reconciliation fault.

The 300-tick final soak was intentionally paused and autonomy-frozen. It proves
populated static convergence and wallet stability, not running-simulation RNG
lockstep. The exact experiment and its limits are recorded in
`investigation/POPULATED_NETWORK_RECOVERY_AND_MENU_2026-08-03.md`.

`runtime/live-validation/20260804-032456` is the strongest current
single-process engine-shape receipt. It passed the 39-check validator and exact
native profile, built a depot and modular station, completed four custody
transitions across 18 owned components, replaced twelve station tracks with
catenary tracks, built/removed an `ASSET_GROUP`-only asset, and removed the depot
and station compound outputs. `runtime/supported-api-probe/20260804-021739`
separately added and removed a real signal. The exact boundary and negative
asset-upgrade finding are in
`investigation/SIGNAL_FACILITY_LIVE_PROOF_2026-08-04.md`.

`runtime/localhost-live/schema7-compact-20260804-032006` is the current
release-candidate two-process regression receipt. Both exact game processes
completed host- and client-origin proposals plus three checkpoint barriers and
finished with matching core `73af1552` and structure `53bb77bb`. Two immediately
preceding runs had reproducibly crashed the host at the first BuildProposal
because richer fingerprints eagerly retained hundreds of autonomous scenery
roots in operational state. State 19 now hashes those roots into the world
manifest but defers their canonical binding until a player selects one. See
`investigation/SCHEMA7_COMPACT_MANIFEST_LIVE_REGRESSION_2026-08-04.md`.

The first human facility session `facility-ui-20260804-083528` remains a useful
negative receipt: it isolated sentinel edge-object parameters, four native
visitors for one station edit, signed-zero bridge instability, and missing
vanilla speed capture. Later reruns found two more UI-boundary defects:
helper-owned station-upgrade fields and a transport-graph requirement applied
to graphless assets. All six now have targeted regressions. The staged passing
runs are preserved in `facility-vectorfix-manual-20260804-1009`,
`station-editfix-manual-20260804-1122`, and
`assetfix-manual-20260804-1203`. The final asset audit records 6/0/0 physical
proposals and 7/0/0 checkpoint barriers with no game errors. See
`investigation/ORDINARY_UI_FACILITY_MATRIX_2026-08-04.md`.

## Implemented system

### Canonical world and ownership

- Stable canonical companies, constructions, edges/nodes, edge objects,
  stations/groups, depots, lines, and railway vehicles.
- Machine-local numeric IDs remain in per-peer binding maps and do not enter the
  portable transaction/checkpoint digest.
- State schema 19 makes shared-save ownership authoritative, persists the
  generation-numbered shared clock, and includes constructions, assets, and
  edge objects in the stable world manifest. The same
  pre-existing network no longer becomes Company 1 on one peer and Company 2 on
  the other merely because each peer has a different original native player.
- Autonomous construction/asset scenery contributes to that manifest digest
  without bloating operational state; a player-selected root receives the same
  stable pre-existing identity through lazy binding.
- Output identities derive from ordered event/slot identities and are bound by
  normalized geometry or bounded operation postconditions.
- Rival edits are rejected against logical ownership in standalone and network
  mode. Public/untracked roads can remain shared; private track remains protected.

### Local company proxy

- Two added native player entities are the persistent companies.
- The original player is a UI turn desk that leases only the active company's
  manageable assets and wallet.
- Reconciliation verifies asset return before moving money and is retry-safe.
- Rail depot and modular passenger-station compound custody, including attached
  edges/station group, passed repeated live Company 1/Company 2 cycles.
- Native borrow/repay is locked on the desk because competitive credit is not
  yet modeled.

### Network authority

- Dependency-free Python TCP host/client with a pinned two-peer roster,
  fingerprints, ordered commits, acknowledgements, reconnect replay, timeouts,
  and audit output.
- Construction capture is an all-peer prepare/commit protocol. Every peer must
  resolve named data resources, canonical geometry and logical ownership while
  its world is still unchanged. A failed prepare mutates neither world and is a
  recoverable placement rejection; only unanimous readiness permits the host to
  emit the native build commit.
- Canonical proposal schema 5 for bounded road/track/node changes plus named
  signal/waypoint edge objects, with stable existing references, repository resource names, geometry, private ownership,
  catenary, removals, deterministic temporary references, and a bounded builder
  cost quote.
- Public roads can lazily resolve a pre-existing town-road junction from exact
  canonical position even when that junction was not present in the peer's
  original binding map. Base-node and base-edge fingerprints exclude unstable
  native names and IDs; ambiguous geometric matches fail closed.
- Road/track resource resolution is data-driven by repository name, so a
  byte-identical mod-added road or track does not need a TPF2MP hardcoded ID.
  Arbitrary scripted mods still need explicit canonical command adapters and a
  complete enabled-mod-pack fingerprint.
- Private expansion endpoints now carry canonical company custody. Added-edge
  positive node references are checked before capture and again at ordered
  replay, closing the one-sided endpoint-snap gap found in the manual localhost
  handoff. Fresh session `lan-endpointfix-20260803-1350` live-proved own
  extension and rival rejection from both players.
- Topology-preserving track-type and catenary upgrades are represented as
  zero-node edge replacements. The companion accepts Lua's digest-preserving
  empty-table wire spelling only when it is truly empty; end-to-end integration
  proves canonical endpoint resolution, replacement output binding, custody,
  owner-only finance, physical consensus, and checkpoint completion. The first
  live upgrade physically changed both worlds but exposed same-command native
  edge-ID reuse during canonical rebinding. Inputs are now retired before output
  binding under an atomic registry/custody backup. The fresh manual localhost
  retest applied both upgrades on both worlds, including two queued in quick
  succession. Schema 5 now serializes added/removed signals and waypoints by
  stable `.mdl` name and retains/rebinds existing objects across edge
  replacement. Rival-edge attachment is rejected at the GUI boundary and
  authoritative replay. Real signal/waypoint UI placement and signal removal now
  pass in the two-process facility matrix as well as the disposable exact build.
- A vanilla physical action suppressed during another proposal/checkpoint barrier is now
  held in a 32-action machine-local FIFO and submitted after consensus rather
  than disappearing. The overlay shows queue depth and outbound-order status;
  integration proves that two independent captures retain order and geometry
  across physical/checkpoint barriers; the manual localhost retest also
  completed two successive upgrades in order.
- The duplicate post-GUI finance delay that measured about 39 seconds per live
  build is removed. Completion now uses the GUI's already-stabilized journal
  observation and the signed quoted cost, with periodic wallet reconciliation
  retained. Fresh latency measurement remains pending.
- Proposal schema 7 retains the strict stock modular passenger/cargo rail-station
  menu family: through/terminus, five lengths, 1-8 tracks,
  standard/high-speed, and catenary on/off. The validators independently port
  the stock `createTemplateFn`, require its exact module slots/resources, and
  validate the generated graph as one open path per track. Engine replay binds
  variable compound output counts, normalizes the quoted cost, and closes
  physical/checkpoint consensus. The 80 m/one-track passenger terminus passes
  human two-process runs across the placement matrix. A second bounded
  `portable-construction` adapter carries named `.con` resources, a finite 4x4
  transform, recursive plain parameters, and named `.module` records. It
  implements depot and ordinary construction placement, upgrade, modular
  station editing, and removal; inventories compound outputs, preserves source
  canonical identities, normalizes finance, and requires physical/checkpoint
  consensus. Opaque callbacks, machine-local fields, missing resources, and
  ambiguous output mappings fail closed. Schema 7 treats the real
  `ASSET_GROUP`-only root as a first-class `asset:` identity. Upgrades must
  produce a component delta or changed stable params/rendered-model fingerprint,
  so native helper no-ops are rejected. The complete sequence passes the
  game-script and Python protocol suites and exact-build engine receipts.
  Stock depot, modular-station edit/removal, and graphless asset build/removal
  also pass ordinary-UI two-process capture and checkpoint consensus.
- Canonical line and railway-vehicle operation codecs with strict validation,
  peer/company authorization, materialization, result validation, finance
  routing, physical consensus, and checkpoint sequencing. Hook 0.12 decodes the
  exact Build 35924 CreateLine/DeleteLine/UpdateLine native payloads after the
  ordinary command is suppressed, including the full ordered station-group,
  station, and terminal tuple. Vanilla zero-stop creation and one-stop editor
  states are admitted, and rapid updates use the 32-action FIFO. Native-build,
  Lua/Python, GUI, and consensus tests pass. A fresh two-process run proves
  create/update/delete from both player origins, canonical target translation,
  matching physical results, and checkpoints. Follow-up stock-widget sessions
  prove New Line, rename, color, Delete Line, Add Station, and per-stop removal
  visually on two independent processes. Reorder and alternate-terminal visual
  proof remain.
  Vehicle capture remains incomplete.
- Later commits remain blocked until both peers agree on physical output and
  then on core/model/canonical-structure/canonical-finance checkpoint state.
- Canonical accounts are authoritative. Native wallets are reconciled
  peer-local caches, preventing local interest/maintenance drift from changing
  competitive money.
- A prepare/readiness rejection is non-fatal because no world has mutated. A
  rejected, mismatched, or timed-out result after build commit faults the
  session closed.
- Pause and speeds 1-4 are host-ordered `clock.set` generations applied through
  native tag-0 authorization on both peers. Hook 0.12 captures suppressed normal
  game speed controls and converts them into `clock.request` intents. Peer engine rate, game time,
  observed speed, heartbeat age and command backlog drive a slowest-peer cap,
  resync pause and hysteretic recovery. This pacing is not native-agent lockstep
  and still needs live threshold/pause-resume proof.

### Native authority layer

- Hook `0.12.0` accepts only the exact Build 35924 executable SHA-256 and PE
  profile.
- It validates 17 unique code signatures/RVAs and 23 selected entries in the
  complete 37-tag command visitor table before enabling hooks.
- It observes `api.cmd.sendCommand`, `CommandList::Swap`, and direct
  `ApplyCommand`, pairs queued commands with outcomes, and reports conservation
  errors.
- It supplies a one-shot payload-aware BuildProposal gate and pre-mutation gates
  for 23 consequential line/vehicle/name/speed/terrain/date/cheat visitors.
- The pinned tag-0 visitor layout supplies a bounded suppressed-speed queue and
  same-state Lua consumer; invalid values and overflow remain suppressed and
  visible in native status.
- The pinned tags 3-5 and 28-29 layouts supply a bounded typed line-command queue.
  It copies pointer-free line name/color/owner/target and ordered stop tuples
  before returning failure to the original vanilla command. Lua consumes an
  `L1` envelope and submits the canonical operation; malformed layouts remain
  suppressed and visible instead of being replayed.
- Unsupported categories fail closed in network mode. A gate is not a codec and
  therefore is not claimed as playable synchronization.

### Passenger/cargo observation

- Canonical read-only mobility samples contain aggregate line/vehicle counts
  without local IDs and participate in cross-peer comparison.
- Direct populated-world ECS reads are now proven. The source passenger line
  reported 413 people, 10 line users, 8 passengers aboard, and 2 waiting on both
  peers.
- Direct cargo entity/terminal/vehicle paths were available, but the source save
  contained zero cargo. A cargo-positive live proof remains required.
- Passenger/cargo state is observed, not yet host-steered. Native visual loads
  must eventually agree directionally with the authoritative market model.

### Recovery and UX

- Format-2 checkpoints and digest-chained events can be independently replayed
  in Python. Four-event and 104-event cross-language traces pass.
- Recovery plans identify and hash the latest all-peer agreed boundary.
- Host sessions automatically watch for the first later stable native save,
  link it to a verified plan, archive the save triplet, hash every file, and
  expose watcher state in the launcher/session status.
- The watcher verifies exact PID/path/start time and stops on process exit or PID
  reuse. It passed an end-to-end boundary-8 archive proof.
- Build 35924 has no supported exact-tick game-script save command. The archive
  is explicitly a later native-save candidate associated with a boundary, not a
  proof of exact-tick rollback. Automatic coordinated restore is still open.
- Normal Host/Join now installs a real `MULTIPLAYER` title-screen entry. The
  game remains idle until the player selects it; selection is receipted, then
  the byte-pinned save is loaded and the session proceeds. Disposable production
  session `menu-production3-20260803` proved that entire path.
- The launcher provides Host, Join, automated Localhost Test, local-only
  Populated Capture Lab, fingerprints, status/logs, evidence collection, and
  exact-session stop controls.

### Packaging and tests

- Release ZIP includes the mod, one-file companion, native injector/DLL,
  launcher, title bootstrap/coordinator, recovery watcher, archive/plan tools,
  installer/verifier/recoverable uninstaller, docs, and SHA-256 manifest.
- Current post-change suite passes:
  - 31 Lua unit tests;
  - game-script, ownership, GUI, hot-seat, network-company, and 104-event replay
    integrations;
  - 14 mod Lua and all 8 investigation/tool Lua syntax checks;
  - 39 PowerShell syntax checks;
  - launcher construction smoke test;
  - 40 Python protocol/network/checkpoint/recovery/report tests.

## Not yet established

- Two physical computers completing a human Host/Join session.
- Fresh two-process proof that the non-fatal prepare path fixes public town-road
  junctions, resolves non-default resource names, and permits a later build
  after a rejected placement.
- Fresh two-process proof of vanilla-control shared Pause/Speed 1-4, adaptive step-down under a
  deliberately slow peer, and automatic recovery without lost/duplicate work.
- Moving populated worlds remaining equivalent over a long unpaused soak.
- Complex topology splits/joins, bridges, tunnels, terrain mutation, scripted
  construction callbacks, mod construction variants, and arbitrary command
  families. The bounded stock signals/depot/station/graphless-asset matrix now
  has automated, exact-build, and ordinary two-process UI proof. Stock
  `ASSET_DEFAULT` replacement is a measured native no-op and intentionally
  fails closed; build/removal work.
- Populated line reorder/alternate-terminal visual proof and the train
  buy/assign/sell flow. The rest of the stock line lifecycle is live-proven.
- Safe synchronized commands for every one of the 23 currently rejected command
  categories or proof that no consequential route bypasses the authority layer.
- Cargo-positive cross-peer telemetry and host control of native
  passenger/cargo presentation.
- Host-authored town and industry growth. Unproven autonomous systems remain
  frozen during authority tests.
- Exact-boundary native save capture, automatic two-peer rollback/relaunch,
  host migration, authentication/encryption, or hostile-Internet deployment.
- Competitive credit, insolvency/bankruptcy, full native operating economics,
  balance, onboarding, and public-release quality.

## Next gate

The bounded stock construction/facility and line-manager matrices now pass.
Next exercise Pause and speed changes from alternating peers and deliberately
slow one process to verify adaptive step-down/recovery without lost work. Then
run the remaining two-stop reorder/alternate-terminal line-manager check and
begin the stock railway-vehicle lifecycle.

Then run the trusted two-computer populated test: enter via the title-screen
`MULTIPLAYER` button, compare the initial checkpoint, run several real passenger
cycles with intermediate samples, pause, submit one supported private track
from each peer, save on the host, confirm a linked recovery archive, and collect
both evidence bundles.

After that passes, live-prove the railway-vehicle lifecycle one category at a
time. Keep all other native command visitors fail-closed until
their canonical payload, host authorization, replay, finance, result binding,
and checkpoint chain are complete.
