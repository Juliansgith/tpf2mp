# TPF2MP prototype status

Last updated: 2026-08-26 after prototype `0.41.3-alpha`, state schema `33`,
checkpoint format `5`, operation schema `4`, passenger-presentation schema `4`,
cargo-presentation schema `2`, freight-industry schema `3`, edge proposal
schema `5`, construction proposal schema `7`, and native hook `0.19.0`.

## Executive status

The implementation is code-complete for the deliberately restricted
`trusted-lan-two-player-alpha` profile. “Code-complete” here means every
advertised alpha capability has a fail-closed authority path and automated
verification; it does not replace the final physical two-computer and
clean-machine acceptance run in `ALPHA_RELEASE_CHECKLIST.md`.

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
  vanilla play: the line lifecycle has typed ordinary-UI capture and stock
  BuyVehicle/SetLine now have pre-mutation typed capture plus human
  two-process purchase/assignment/movement proof. Shared-clock v2 and a
  canonical per-station train hold/release barrier now pass a populated
  two-process run with four releases, zero faults, and matching final state.
  Current state excludes the native hold bit from lifecycle authority, prunes
  completed rounds, and checkpoints exact passenger and cargo presentation.
  Model headway remains a demand input; registered and ordinary lines now both
  use a short guarded physical release after every peer arrives. The prompt
  path has exact two-process proof, and human
  speed-3 play recovered after deliberately delaying one peer. A bounded
  reconnect fence now pauses immediately, removes a lost peer from readiness,
  replays its complete ordered backlog before `sync_ready`, resets protected
  deadlines, and faults closed after 120 seconds. The newly captured vehicle
  lifecycle, stock multi-sale, broader topology/resource manager, multi-hop
  passenger/cargo, and recovery stress are code-complete but still need the
  single combined two-computer alpha receipt. Opaque scripted callbacks remain
  explicitly outside the profile.

The network architecture has crossed the populated-world convergence gate. It
has not crossed the finished-product gate.

Prototype 0.40 adds the preferred Internet transport without moving authority
out of Player 1. Host and Join make outbound authenticated WSS connections to
two relay channels: gameplay carries the existing framed TCP protocol and save
carries the existing verified starting-save stream. Neither player exposes an
inbound port. A short-lived opaque join code fixes separate Host/Join roles;
the relay rejects role duplication, cross-session credentials, and mismatched
content fingerprints. Tunnel loss enters the existing pause/reconnect/backlog
fence and never falls back silently to direct mode. Both clients also submit
only bounded, named, double-redacted status/log evidence under a non-secret
support ID; command payloads, save bytes, raw dumps, and arbitrary files are
not retained. A full localhost relay run transferred a 54,455,136-byte save
triplet, synchronized both companions, survived relay loss/restart, and
delivered both diagnostic timelines without credentials. Real HTTPS deployment
and one fresh two-computer relay match remain the new live gates.

The Multiplayer panel now includes a fail-closed **Alpha Status** view. The
companion's `alpha-live-report` produces `core`, `playable`, and `alpha`
verdicts from converged checkpoints and both companion statuses. The strongest
profile requires construction, operations, economy, multiple vehicles, town
development, passenger transfers, conserved cargo transfers, one recovered
disconnect, and a matching current restore plan; a missing receipt is a failed
gate rather than prose judgment.

Prototype 0.38 added one deterministic carrier-neutral service graph. Passenger
connections now add through-demand to every used corridor, including
interchanges at intermediate stops. Cargo refuses to ship without a reachable
compatible consumer, then moves through conserved authoritative station stock
over up to four legs; only final industry delivery enters final-delivery totals
and revenue. Unused paths may replan, while the first ordered vehicle release
pins the whole operating path. State 31/freight schema 3 retires deleted line
cursors into compact lifetime-history maps. The Multiplayer panel now exposes
Routes / Transfers and a bounded Compatibility inventory for the exact named
road, track, model, construction, and module resources admitted by portable
replay. Lua/Python route/state parity and focused behavior tests pass; the
fresh ordinary-UI two-process checklist remains open.

Prototype 0.29 additionally serializes a topology edit and every obstructing
construction removal into one atomic native BuildProposal. Offline integration
proves the compound path remains separate from ordinary station bulldozing; a
fresh through-house/tunnel live pass is pending. A live depot-open hang was
traced to mod-created children retained in hidden stock windows plus renderer
reentrancy. Stock UI now mutates existing native leaves only, uses deferred
bounded discovery, current-schema GUI-state acceptance, and 30-frame snapshot
projection. The exact populated crash save then survived five native depot/
Vehicle Manager open-close cycles; the two views showed roughly 135-163 and
159 FPS during the captured idle checks, and the full companion audit passed.
The same live lab exposed two co-located native nodes when track crossed a road.
Those nodes now use a sorted canonical incident-edge anchor; divergent-ID add,
replacement, and removal paths pass offline. A fresh source-matched ordinary-UI
two-process run now live-proves the crossing, three-edge public-road split,
issuer-only debit, identical checkpoints, and a subsequent extension from the
event-created track end. Removal-only connected road/track proposals now pass
canonical capture/materialization, ownership, physical disappearance,
binding-retirement, finance, consensus, and checkpoint tests. A fresh
ordinary-UI two-process demolition/rebuild pass remains open.
The preserved lab also exposed 5,469/6,048 immutable outbox files. Companion
polling had sorted the full history at 10 Hz; a real-directory benchmark
measured 15.460 ms versus 0.015912 ms for the exact cursor successor. Polling
is now constant-time per message and gaps fail closed. Durable evidence remains;
acknowledged replaceable clock-health and vehicle-sync source files older than
a 4,096-message tail are pruned. The live host still consumes every heartbeat,
but journals one forensic clock-health sample per peer per ten seconds.

The later receipt-bound restore run exposed a second performance class and a
checkpoint migration defect. Boundary 29 contained matching core/model/
structure state on both peers, but its manifest-bound train lacked the
vehicle-sync `companyCid` already present in the canonical service and
passenger ledger. Strict validation correctly stopped the session. Release
creation and migration now bind that field from the authored service. The same
audit removed duplicate network-runtime execution, cached the 518-entry
canonical vehicle scan, moved idle wallet audits from every update to every 15
updates, halved idle native balance reads, and removed idle per-frame line
enumeration. The full suite passes. Fresh session
`perf-ownerfix-live-20260809-2351` then completed automatic settlement/checkpoint
14 with matching core/model/structure/convergence and an owned synchronized
train on both peers. Matching minimized running samples averaged 21.7% of one
core on both processes; same-camera foreground spot readings were 105 FPS on
P1 and 128 FPS on P2. The former persistent 4-5x host/client regression is no
longer present in the reproduced world; dense-network frame-time percentiles
remain a future scalability benchmark.

Hook `0.19.0` addresses measured native-bridge and build-preview hot paths
without weakening the
durable protocol. Signed envelopes are now queued in memory on the game thread;
the hook worker performs numbered outbox publication and exact-successor inbox
reads in bounded batches. Stable content/freight probes, idle vehicle scans,
clock-health emission, routine native telemetry, public capture projection,
and unchanged stock-toolbar writes now have explicit cadence or dirty checks.
Bounded native-monotonic p50/p95 task telemetry is available in snapshots and
the Multiplayer panel. The default skeleton policy now caps every otherwise
populated building at exactly one native capacity slot, and the balanced
localhost profile places the two complete game processes on disjoint CPU sets
with bounded side-by-side render surfaces. Native build/CTest and the complete
offline suite pass. This is not yet an FPS claim: the profiled live pair
predated 0.17, so same-camera running measurements belong to the next
fresh launch.

The first ordinary-user construction pass then isolated the remaining tool-
active frame collapse. Build 35924 emits proposal previews at render cadence;
the GUI path was recursively scanning and copying projected graphs, serializing
the complete native status, and emitting two durable diagnostic records even
when the player merely hovered. The resident title-menu bootstrap additionally
walked hidden save widgets and reread launcher files at uncapped render cadence.
Hook 0.19 exposes a versioned constant-size build-gate sample plus a bounded,
generation-bound suppressed-build correlation queue; normal network
hover now retains one detached snapshot, defers hashing/copying until native
click evidence, uses bounded wrapper/source predicates, and emits diagnostics
only in research/validation modes. Hidden menu/status and idle capture polling
now have explicit bounded cadence. Exact suppression correlation, rival-owner
denial, click payloads, consensus, and checkpoints remain unchanged.

The subsequent populated multi-train soak exposed authority loss rather than a
native pathing deadlock: a concurrent Windows audit read held the journal long
enough for the host append to fail, after which the games safely retained their
station holds. The same 2.7-hour audit showed 611 clock generations, including
220 adaptive step-downs and 224 recoveries, because unequal render/update rates
were mistaken for unequal simulation progress; most skew corrections were only
2-3 game seconds. It also contained 16,212 clock-health records (7.7 MiB), one
unsettled final commit, and a loaded-vehicle retirement residue of 13 riders.
Journal snapshots now close before parsing and boundedly retry Windows sharing
denials; permanent persistence loss leaves a visible fail-closed host. The
clock governor uses game-time progress with debounce/hysteresis, the health
audit is sampled, passenger schema 4 accounts explicit discard, disconnected
replaceable telemetry is coalesced, and the interactive harness requires live
companions plus a strictly settled audit before it can report success. These
corrections pass the full offline suite; a fresh long live soak is still the
acceptance gate.

Prototype 0.31 built canonical freight-industry state on the loaded-content
gate introduced in 0.30. Both exact processes
independently capture the construction resources they actually loaded, publish
strict content-addressed artifacts, bind live industry roots to evaluated
recipes, and order one digest/count attestation each before match start. State
28 then lets only the host author the sorted live-industry bootstrap and
checkpoints each canonical recipe, input/output stock, exact production
residual, and production/consumption total. The exact vanilla set is 16
freight resources / 160 variants / zero ambiguities at digest `edc7a517`;
incompatible or ambiguous mod content faults closed, and a saved bootstrap must
revalidate against both freshly agreed content and the current canonical live
bindings before settlement.

Prototype 0.32 completes the first authored freight-transport path. A cargo-only
line binds its exact source industry, destination stock slot, cargo type, and
every assigned vehicle's named capacity. Ordered station releases now move
canonical source queues into exact per-vehicle loads and record destination
deliveries. Five-minute settlement atomically validates all transport cursors,
withdraws aggregate source stock, deposits destination stock, advances
production, pays unit-kilometre revenue, and advances passenger and cargo
presentation. State 30/checkpoint 5 and an independent Python replayer validate
the full stock, cursor, load, delivery, and conservation projection. Standard
line, vehicle, station, manager, statistics, and top-bar surfaces display the
authored freight values; native cargo agents/history remain cosmetic. This
slice has complete automated cross-language and checkpoint proof, but its first
cargo-positive two-process play receipt remains open.

## Strongest current evidence

`industry-artifact-write-20260809-0550` independently ran the resource loader
in two fresh Build 35924 worlds. Each wrote the same 17 content-addressed
artifacts; strict aggregation retained 16 positive-flow industry resources,
160 evaluated variants, zero ambiguities, and digest `edc7a517`.
`runtime/localhost-live/industry-consensus-live-20260809-0745` then required
those peer-local artifacts as part of the normal two-process gate. Attestations
occupied commits 1 and 2, the match checkpoint anchored the agreed content at
commit 3, and the full run ended with matching core/model/structure
`c3bf105f`/`4b315eeb`/`ae4f8ceb`. The audit verified 13 converged commits,
2/0/0/0 physical proposals, 3/0/0 checkpoint barriers, and no fault. See
`investigation/LIVE_INDUSTRY_RESOURCE_BINDING_2026-08-09.md`.

`runtime/localhost-live/freight-bootstrap-live-20260809-1200` extends that gate
through a real state-28 bootstrap. It bound five live industries (farm, quarry,
food processing, tools, and construction materials) to the same `edc7a517`
registry, ordered bootstrap digest `c5352cf8`, and produced matching bootstrap
checkpoints with core `b34fbdae`. The complete run converged 14 commits and
ended at core/structure `2417b3fd`/`23c28901`, with 2 successful physical
proposals, 3 successful checkpoint barriers, no unresolved lane, and a valid
independent audit. The run proves discovery, authorization, binding, bootstrap,
checkpointing, and convergence; settlement production advancement is currently
cross-language automated proof, not yet a live cargo-production receipt. See
`investigation/FREIGHT_INDUSTRY_AUTHORITY_2026-08-09.md`.

The 0.32 automated freight gate extends that live bootstrap without pretending
it is a live cargo run. It proves exact heterogeneous consist capacities,
portable source/sink binding, ordered boarding/delivery, aggregate stock
reservation, zero-movement cursor behavior, line retirement/discard
conservation, atomic registration and settlement rollback, state-29/checkpoint-5
validation, an independent Lua/Python two-step vector, and a 256-boundary
three-cargo/12-line stress replay ending at digest `74b018d9`. See
`investigation/FREIGHT_TRANSPORT_AND_PRESENTATION_AUTHORITY_2026-08-09.md`.

State 24 retains two newer gates. `round3-town-construction-pos-20260807` ran
three eight-call physical-town rounds on two exact processes and converged
Northfleet at capacities `633 → 657 → 687 → 704`, ending at core/model/
structure `b418e90f`/`ca0582b4`/`2de890d4`. The receipt-bound restore session
`anchor-button-20260806-2211-r6` loaded distinct peer saves, admitted
`recovery.resume` first, converged its mandatory fresh checkpoint, resumed the
real train, and returned to a shared pause without a fault. Fresh native-world
controls also prove skeleton/minimum-safe construction scaling; literal zero
person capacity is an exact Build 35924 fatal and is no longer shipped.

`runtime/localhost-live/train-prompt-barrier-state22-20260806-105918` is the
strongest ordinary-line receipt. Two exact Build 35924 processes loaded the
same populated save and ran its real three-part train through four prompt
station rounds. The host records zero scheduled and four unscheduled releases,
zero pending rounds, zero faults, a 1.86-second average round latency, and a
2.38-second maximum. Both peers ended at core `fba1630d`, model `98f01295`,
structure `15189409`, and mobility `8e5d90e6`; the audit verifies 15/15 commit
convergences, 2/0/0 physical proposals, and 3/0/0 checkpoint barriers. The
  older scheduled mechanism retains a readable exact-build baseline in
  `train-scheduled-state22-20260806-1010`. It is no longer the production
  policy: a 2026-08-07 registered-line run exposed a 364.2-game-second hold and
  active-round timeout, so all new station rounds use prompt release.

The older `runtime/localhost-live/populated-network-ownershipfix-20260803`
remains the static ownership baseline. It passed with two
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

`runtime/live-validation/20260809-021602` is the strongest current
single-process engine-shape receipt. It passed the 39-check validator and exact
native profile, built a depot plus separate modular passenger and cargo
stations, classified their live indexed station components as `passenger` and
`cargo` through the production reader, completed four custody transitions
across 33 owned components, replaced twelve passenger-station tracks with
catenary tracks, built/removed an `ASSET_GROUP`-only asset, removed every
facility compound output, and verified a 27-event hash chain.
`runtime/supported-api-probe/20260804-021739` separately added and removed a
real signal. The exact boundary and negative
asset-upgrade finding are in
`investigation/SIGNAL_FACILITY_LIVE_PROOF_2026-08-04.md`.

`runtime/supported-api-probe/20260809-024229` is the strongest destructive
vehicle receipt. On the exact executable it bought a real three-part train,
proved stop/start, two reversals, 7,500-basis-point maintenance on every part,
replaced it with a different two-part consist, sold it, verified entity
absence, and cleaned up the depot. Production operation consensus now verifies
those native fields against the ordered transaction before comparing peers;
the remaining gate is the ordinary-widget two-process/running-route matrix.

`runtime/localhost-live/localhost-20260809-030632` is the current clean
companion-integrity regression. Two exact Build 35924 processes converged all
11 ordered commits, both physical proposals, all three checkpoint barriers,
and matching core `d9366b44` / structure `1ab06cc6` after 600 soak ticks.
Completions are now checksum-recomputed from their signed physical fields,
complete views are compared directly, restart rejects conflicting receipts,
and offline replay covers operations as well as proposals. A historical
75-commit economy audit with six operations also replays under the stricter
rules. See `investigation/PHYSICAL_COMPLETION_AUDIT_INTEGRITY_2026-08-09.md`.

`runtime/localhost-live/schema7-compact-20260804-032006` remains the historical
schema-7 release-candidate regression receipt. Both exact game processes
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
- State schema 24 makes shared-save ownership authoritative, persists the
  generation-numbered shared clock and canonical train-release rounds, and includes constructions, assets, and
  edge objects in the stable world manifest. The same
  pre-existing network no longer becomes Company 1 on one peer and Company 2 on
  the other merely because each peer has a different original native player.
- Autonomous construction/asset scenery contributes to that manifest digest
  without bloating operational state; a player-selected root receives the same
  stable pre-existing identity through lazy binding.
- Private edges and terminal nodes already present in the pinned starting save
  are included from the canonical ownership seed and receive `manifestBound`
  deterministically; this strict path now passes under PowerShell and Git Bash.
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
- A unanimously rejected native build is recoverable only when every peer
  reports no outputs or finance delta, identical result/core/error values, and
  a core digest equal to the prepare barrier. It is counted separately as a
  rejected placement and must close a new all-peer checkpoint before another
  command. Mixed results, residue, changed core, timeout, or missing evidence
  still fault closed. This fixes the live `Too much curvature` case where both
  worlds stayed unchanged but the old fatal outcome blocked later bulldozing.
- Canonical proposal schema 5 for bounded road/track/node changes plus named
  signal/waypoint edge objects, with stable existing references, repository resource names, geometry, private ownership,
  catenary, removals, deterministic temporary references, and a bounded builder
  cost quote.
- Public roads can lazily resolve a pre-existing town-road junction from exact
  canonical position even when that junction was not present in the peer's
  original binding map. Base-node and base-edge fingerprints exclude unstable
  native names and IDs. Co-located nodes use a canonical incident-edge anchor;
  ambiguity without a unique portable anchor still fails closed.
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
- Canonical line and portable vehicle operation codecs with strict validation,
  peer/company authorization, materialization, result validation, finance
  routing, physical consensus, and checkpoint sequencing. Hook 0.17 decodes the
  exact Build 35924 CreateLine/DeleteLine/UpdateLine native payloads after the
  ordinary command is suppressed, including the full ordered station-group,
  station, and terminal tuple. Vanilla zero-stop creation and one-stop editor
  states are admitted, and rapid updates use the 32-action FIFO. Native-build,
  Lua/Python, GUI, and consensus tests pass. A fresh two-process run proves
  create/update/delete from both player origins, canonical target translation,
  matching physical results, and checkpoints. Follow-up stock-widget sessions
  prove New Line, rename, color, Delete Line, Add Station, and per-stop removal
  visually on two independent processes. Reorder and alternate-terminal visual
  proof remain. Hook 0.17 also captures BuyVehicle's pinned native
  player/depot scalars and correlates them with the stock GUI's ordered,
  carrier-neutral `vehicle/*.mdl` list; bounded capture fails closed instead
  of truncating oversized or deeply nested payloads. SetLine carries canonical
  vehicle/line/stop identities. The exact NOHAB + two BC4 purchase now passes
  a disposable Build 35924 engine run with concrete model-derived load configs,
  and a stock human NOHAB + two BC4 purchase now reaches matching physical and
  checkpoint consensus on two processes. A later stock test assigned the
  canonical train and observed it moving in both worlds. Its small phase lead,
  amplified by a one-sided Escape pause, is the direct motivation for the new
  station barrier. Reverse, start/stop, maintenance, immediate departure,
  send-to-depot/sell-on-arrival, direct and bounded multi-selection sale,
  replacement, and manual-departure stock adapters now pass exact-layout and
  integration tests but remain live-unproven. Operation schema 4 represents a
  2-256 vehicle selection as one sorted canonical transaction. Every target is
  company/access preflighted before deterministic scalar native replay; the
  aggregate result verifies every deletion before one finance, physical-
  consensus, and checkpoint boundary. A native failure after an earlier scalar
  deletion faults closed because the public API has no physical rollback.
  Replacement also refreshes canonical consist metadata and schedules an
  owning-peer line registration, so new speed/capacity/upkeep facts cannot stay
  hidden behind the old service record.
- Later commits remain blocked until both peers agree on physical output and
  then on core/model/canonical-structure/canonical-finance checkpoint state.
- Canonical accounts are authoritative. Native wallets are reconciled
  peer-local caches, preventing local interest/maintenance drift from changing
  competitive money.
- A prepare/readiness rejection is non-fatal because no world has mutated. A
  rejected, mismatched, or timed-out result after build commit faults the
  session closed.
- Pause and speeds 1-4 are host-ordered through native tag-0 authorization on
  both peers. Hook 0.17 captures suppressed normal controls as `clock.request`.
  A running request now becomes a future-time `clock.rendezvous`; the host
  projects staggered heartbeats to one instant, both peers pause at the target,
  and bounded overshoot receives a speed-1 catch-up round before release.
  Paused GUI heartbeats preserve resume readiness. The governor normalizes each
  peer's measured game-time progress against its selected speed rather than
  native update/render `tickRate`: soft skew must
  persist for four seconds, slow progress for eight seconds, hard eight-second
  skew corrects immediately, and recovery requires thirty stable seconds.
  Observed speed, heartbeat age, and backlog remain fail-safe inputs.
- Every replicated assigned vehicle now observes native terminal state, holds via
  gated tag-8 `setUserStopped`, and reports a canonical vehicle/line/stop/round.
  Both peers must match before one ordered future-time release. State 21 and
  checkpoint 3 persist/digest the authorized round; retries and host restart
  are idempotent. An all-peer-acknowledged shared pause suspends pending round
  deadlines and pause-adjusts latency telemetry; timeout budget resumes only
  after a latest-generation running control is acknowledged by all peers. Esc
  can stop a game's bridge loop before that acknowledgement. A pending pause
  is therefore also timeout-protected when another peer accepted it, the
  missing game had fresh pre-pause telemetry, and its TCP companion remains
  connected. This is reported separately as `connected-quiescent-modal` and
  never changes strict `pauseAcknowledged`. Disconnect, negative
  acknowledgement, uncorroborated staleness, mismatch, active-time timeout,
  rejection, or premature departure still faults and pauses. Exact coordinates
  remain native and per-peer. Four live populated localhost rounds alternate
  correctly between both stops. Model-v8 passenger rail/water/air and unknown
  carriers retain every-stop safety; road/tram passenger services rendezvous
  only at route endpoints, and freight only at its exact source/sink. This
  avoids a network round at every urban curb stop without weakening the
  authored boarding/alighting boundary. The carrier-specific policy is fully
  automated but only rail has live two-process proof.

### Native authority layer

- Hook `0.19.0` accepts only the exact Build 35924 executable SHA-256 and PE
  profile.
- It validates 17 unique code signatures/RVAs and 31 selected entries in the
  complete 37-tag command visitor table before enabling hooks.
- It observes `api.cmd.sendCommand`, `CommandList::Swap`, and direct
  `ApplyCommand`, pairs queued commands with outcomes, and reports conservation
  errors.
- It supplies a one-shot payload-aware BuildProposal gate and pre-mutation gates
  for 31 consequential line/vehicle/name/speed/terrain/date/cheat/autonomy
  visitors. The eight added tags 17-24 deny unilateral native town/industry
  commands; ordered town development, town information, and industry freeze
  consume one-shot tags 19, 20, and 23.
- The pinned tag-0 visitor layout supplies a bounded suppressed-speed queue and
  same-state Lua consumer; invalid values and overflow remain suppressed and
  visible in native status.
- The pinned tags 3-5 and 28-29 layouts supply a bounded typed line-command queue.
  It copies pointer-free line name/color/owner/target and ordered stop tuples,
  then lets the original command complete because rejecting these visitors
  asserts the stock widget. Lua consumes an `L3` envelope and submits the
  canonical operation. Native queue overflow emits a sticky `F1` residue
  sentinel; read/decode loss, GUI dispatch failure, authority/finance rejection,
  FIFO overflow, and bridge failure now retry or fault the session instead of
  continuing with a one-sided mutation.
- The pinned tags 6-14 and 30 supply a separate pre-mutation vehicle queue.
  Scalar commands use `V2`; tag 12 uses `V3` to retain the complete bounded,
  duplicate-free SellVehicle selection.
  SetLine carries vehicle/line/stop index. Reverse, start/stop,
  maintenance, immediate departure, send-to-depot, and manual departure carry
  only bounded scalars. SellVehicle carries every selected target; Lua maps one
  target to the legacy sale and 2-256 targets to one schema-4 batch. BuyVehicle
  carries native player/depot; ReplaceVehicle
  carries the target. Both are FIFO-correlated with the stock GUI's bounded
  consist. Native config pointers and repository IDs never cross the boundary.
  V1 remains decode-only compatibility for tags 6 and 13. Queue overflow or
  gate-reset loss raises a sticky fail-closed sentinel.
- Unsupported categories fail closed in network mode. A gate is not a codec and
  therefore is not claimed as playable synchronization.

### Competitive economy

- Demand model 8 retains integer generalized cost, the pinned logit table,
  carried share residuals, lagged crowding, induced demand, deterministic
  capacity allocation, and passenger/cargo market weighting.
- Same-town passenger lines now register a shared local market instead of being
  quarantined. Road and tram services can improve their own company's
  intercity generalized cost by sharing an exact station group at either
  endpoint. Each endpoint contributes at most 150 cents, scaled by the weaker
  of hourly capacity and `floor(90000/headwaySeconds)`; the route needs two
  distinct stops and only the best feeder at a station counts. Rival feeders,
  disabled/zero-capacity lines, duplicate shuttles, and cargo never help.
  The access index is derived afresh at settlement, and the line panel exposes
  both connected endpoint count and exact cents. Lua/Python replay agrees on
  the v8 result while explicit v2-v7 states keep their historical factor shape.
- Automatic line-registration follow-ups now distinguish permanent local
  facts-derivation failures from transient bridge failures. Unresolved-town,
  industry, or stale routes leave the authored queue, appear in a
  bounded panel/research diagnostic, and can recover after a later edit;
  transient bridge failures continue retrying. This prevents an unsupported
  service from keeping anchor readiness false forever without misclassifying
  it as passenger demand.
- Exact stop/platform cargo flags and consist cargo-entry types now classify
  passenger, cargo, mixed, and unreadable lines before registration. Only
  explicit `PASSENGERS` entries count as seats. Freight or mixed lines cannot
  create passenger markets; already registered stale services are revalidated
  and retired by an ordered portable disable, which also removes their model
  queues and loads. Freight infrastructure still replicates physically. Loaded
  industry recipes are authoritative match content: both peers capture and
  strictly attest the same evaluated resource registry before play, and live
  `SIM_BUILDING` roots resolve to those portable recipes. State 30 additionally
  owns canonical per-industry input/output stock, exact hourly-capacity
  production residuals, alternative-input consumption, and cumulative totals;
  exact cargo-only lines bind a source output and destination stock slot within
  500 metres of their terminal groups. Every assigned consist contributes its
  exact named-cargo capacity. Ordered station rounds own source queues,
  per-vehicle loads, delivered/discarded conservation, and unit-kilometre
  revenue; every authored economy settlement advances transport, industry,
  economy, and both presentation candidates atomically. Disposable exact-build
  runs measured the stock
  NOHAB/BC4/open-wagon cases as empty, passenger-only, cargo-only, and mixed,
  and the vanilla industry set as 16 resources / 160 unambiguous variants.
- Hard, Normal, Easy, and Relaxed are world-creation choices that scale gross
  revenue to 60%, 100%, 150%, or 200%. The selected key and exact integer
  multiplier are ordered match rules and saved economy state; they are
  read-only after initialization. Purchase price, resolved upkeep, demand,
  service facts, and scoring inputs are otherwise unchanged. Pre-v7 saves
  migrate to Normal rather than inheriting a machine-local menu selection.
- Passenger service advances canonical endpoint populations with an exact
  growth remainder. All corridors linked to those towns refresh their gravity
  demand upward from the authored sizes, independently of native crowd policy
  and independently of whether optional physical town development is enabled.
- An upward fare shock uses the authored `lastFareCents` latch and immediately
  adopts a lower equilibrium, while non-price deterioration keeps the smoother
  250-per-thousand down-glide. Options at least eight theta above the best
  choice now receive zero weight. Together these close both retained-rider
  harvesting and the one-passenger max-fare rounding exploit without reviving
  the crowding relay oscillation.
- Player 1 automatically authors the exact next accounting tick every 300
  seconds of synchronized simulation time. Hourly demand and bidirectional
  service capacity are prorated with exact integer residual carry, so 12 ticks
  conserve the hourly rate. A physical/checkpoint barrier delays but never
  skips a due boundary; catch-up remains ordered. Manual settle/demo controls
  are hidden outside developer/validator mode.
- Passenger revenue is delivery-based. Boarding stores the current fare;
  alighting at the next synchronized station advances cumulative completed
  passengers and earned cents; the next tick pays only the monotonic cursor
  delta. Repeated snapshots pay zero and backwards snapshots fail closed. The
  default fare is `$5 + $1.50/km`, while a displayed passenger is a financial
  cohort of 1,000. Cargo delivery uses `$1,000/unit-km` at fare index 1,000 and
  is paid only from the monotonic authored delivery cursor.
- Each purchased canonical vehicle records the exact consensus purchase delta
  and the engine-resolved annual `MAINTENANCE_COST` after vanilla/mod resource
  modifiers. Replacement refreshes it, sale retires it, and uniquely
  manifest-bound starting vehicles are backfilled from the same component.
  One sixth of purchase price remains only a fail-soft legacy fallback. Upkeep
  continues while parked or unassigned and every vehicle has its own exact
  interval residual. The native annual number is compressed into a three-hour
  competitive financial year. Private proposal spend becomes active infrastructure capital at ten percent annual upkeep;
  replacements carry old capital plus new spend, removals retire it, and public
  town roads are excluded.
- Every result and ledger separates gross revenue, vehicle upkeep,
  infrastructure upkeep, operating cost, and signed net revenue. Score, credit,
  bankruptcy, and canonical-wallet payout use net. Signed sub-dollar residuals
  make repeated positive/negative settlements exactly cumulative despite the
  native wallet's integer-dollar boundary.
- Native trip income, maintenance, and loan-interest journal entries are not
  authoritative. Native wallets are continuously reconciled to canonical
  accounts. The normal account and earnings controls now show canonical balance
  plus completed-trip revenue pending and projected hourly net; vehicle, line,
  station, finance, manager, and statistics windows receive authoritative
  TPF2MP panels. Misleading native
  load/queue/history widgets are hidden or labelled cosmetic. The engine-only
  world-space trip-income popup can still appear but never changes competitive
  cash. Native purchase and annual-maintenance figures remain visible because
  they are the exact consensus cost inputs, not competing estimates.
- Lua aggregates saturate at `10^15` cents so every authored integer remains
  exact in Lua 5.1 and Python. Model-v2-v7 behavior remains available for
  archived replay. The offline gate now includes 128 Lua tests and 108
  cross-language v2-v9 scenarios, including feeder access, completed-trip cursors,
  bidirectional capacity, passenger/cargo balance fixtures, assigned and parked
  vehicle costs, infrastructure costs, losses, exact residual carry,
  scheduled-boundary rejection, four difficulty presets, canonical town
  growth, and a deterministic randomized 1,024-event replay. A replaceable
  1850-2030 era matrix checks
  that newer reference tiers add real capacity/net incentive while difficulty
  never changes demand, capacity, or upkeep. Exact vanilla/mod vehicle facts
  and human balance remain live-test questions.

### Passenger and cargo presentation

- Canonical read-only mobility samples contain aggregate line/vehicle counts
  without local IDs and participate in cross-peer comparison.
- Direct populated-world ECS reads are now proven. The source passenger line
  reported 413 people, 10 line users, 8 passengers aboard, and 2 waiting on both
  peers.
- Direct cargo entity/terminal/vehicle paths were available in the earlier
  populated probe, but that source save contained zero cargo. The authored
  cargo ledger no longer depends on those native counts; a cargo-positive live
  UI proof remains required.
- Passenger schema 4 treats model demand as a deterministic arrival rate and
  advances both endpoint queues to each host-ordered `vehicle.sync_release`
  timestamp. A train boards up to its own physical seats instead of receiving a
  smoothed share of five-minute throughput; excess riders remain visibly
  waiting, bounded excess arrivals abandon, and requested/throughput/queue facts
  feed the authoritative UI and lagged crowding. Intermediate stops preserve
  the load; opposite terminals alight and board deterministically; duplicate
  releases are idempotent; route edits, reassignment, and vehicle retirement
  account discarded/backlogged riders. Checkpoints enforce exact generated,
  boarded, alighted, discarded, aboard, and waiting conservation.
- Cargo schema 1 mirrors that release boundary with a portable source/sink
  contract, exact per-vehicle capacity, source queue, aboard cargo, destination
  delivery, and explicit discard totals. Idle lines do not invent a transport
  cursor, and retirement accounts any onboard units before removing a vehicle
  record.
- State 30 persists both ledgers. Checkpoint format 5 validates their full
  canonical stop sequence, line/company identity, capacities, trip endpoints,
  release rounds, contract identity, transport cursors, and exact cargo
  conservation against the synchronized vehicle projection and freight stocks.
  Standard vehicle, line, station, manager, statistics, and top-bar surfaces
  show the authored counts, including waiting cargo at the source and cumulative
  delivery at the destination. The separate HUD rows remain only as a fail-soft
  fallback when a supported stock component cannot be located.
- Every five-minute economy settlement now opens one two-peer checkpoint, so
  its stock transfer, cargo delivery cursor, authoritative revenue, and finance
  are automatically convergence-receipted without checkpointing every station
  visit. Save migration revalidates cargo line/vehicle conservation, service
  contracts, synchronized rounds/stops, and freight cursors. A functional
  fixture preserves 40 units aboard, completes their delivery after load,
  preserves the settled cursor through another save/load migration, and
  rejects both a one-unit conservation tamper and a payment cursor one unit
  ahead of delivery.
- The first authoritative cargo load above zero now queues one host-authored
  `freight.milestone`. Its exact release round, cumulative boarding cursor, and
  immediate load survive a short route unloading before the action commits;
  both peers bind that witness to the same canonical line/vehicle and monotonic
  presentation ledger before `freight-milestone:aboard` can count as proof.
  This removes the timing-dependent manual checkpoint without adding a network
  round at every station.
- The same one-shot protocol now covers the first non-zero authored passenger
  load on a valid local ROAD/TRAM feeder. A shared runtime verifies both peers'
  canonical line/vehicle ledger, while a passenger policy requires local scope,
  two equal endpoint towns, and two distinct station groups. Rail corridors,
  duplicate-stop routes, disabled services, and malformed bindings cannot
  consume the proof. The ordered `passenger.milestone` opens
  `passenger-milestone:aboard`; the focused feeder wrapper requires it
  automatically, removing its last timed checkpoint click. Passenger and cargo
  evidence share a FIFO priority prefix ahead of queued-but-uncommitted builds;
  stale witnesses remain non-proofs and may retry rather than faulting a
  healthy match.
- Native people remain bounded scenery. Exact-build reverse engineering shows
  `Debug_SetSimPersonState` contains only a person ID and boolean, with no
  train/station target; the cosmetic adapter therefore issues zero writes.
  Native cargo agents and history are likewise cosmetic; the canonical cargo
  queue/load/delivery values are the competitive truth.

### Recovery and UX

- Development state 32 adds fail-closed in-place requalification for one narrow
  fault class: a proposal completion timeout whose late all-peer results are
  identical empty failures at the prepared core. The host derives and orders
  the proof, both games re-evaluate it, and a fresh core/structure/world-manifest
  checkpoint must converge before the exact timeout fault is cleared. The panel
  exposes **Recover / Resync Session** and leaves the recovered game paused.
  Progress events renew the ordinary proposal deadline up to an absolute hard
  cap. Mixed results, residue, changed state, and every other fault remain
  verified-restore-only.
- Format-5 checkpoints add both exact presentation ledgers and freight
  transport/stock state to the canonical train-release projection, core, and
  convergence key. Formats 1/2/3/4 remain readable, and digest-chained events
  can be independently replayed in Python. Four-event and deterministic
  randomized 1,024-event cross-language traces pass.
- Recovery plans identify and hash the latest all-peer agreed boundary. Current
  version-4 plans bind both load-bearing native files and the exact source
  match-content profile. Version 2 (main save only) and version 3 (profile but
  no metadata attestation) remain readable with explicit legacy semantics.
  Current resume identities retain readable `<session>-r<boundary>` spelling
  when it fits and use the same cross-language collision-tagged 64-character
  form in Python, Lua, and the launcher for long legal source sessions.
- **Prepare & Save Restore Point** orders shared pause, quiescence, and checkpoint
  convergence. Only while the companion and local runtime expose the same READY
  boundary and core may a save start. Build 35924 does not expose a public
  `SaveGame` factory, so the watcher falls back to the exact process's stock Save
  dialog only when that explicit preparation owns the READY boundary. Ordinary
  incidental READY checkpoints expose manual-save availability but never launch
  focus-stealing automation. Names use
  `tpf2mp_r_<session-adler32>_<p1|p2>_b<boundary>` and remain
  under the native 50-character limit. The watcher waits for a stable
  save triplet, links it to the verified boundary, files the ordered peer
  receipt, archives and hashes every file, and exposes its state in the launcher.
- The watcher verifies exact PID/path/start time and stops on process exit or PID
  reuse. It passed an end-to-end boundary-8 archive proof.
- Before that liveness check, every peer now preserves its first published
  session fault without allowing a later fault to replace it. A transient
  collector failure receives at most three attempts for that same fault, and
  the exact-process watcher exposes a 30-day finite expiry. The bounded local bundle includes the copied
  bridge/audit, session-specific game and companion log tails, native status,
  and source/install fingerprint; the launcher and status command expose its
  summary path. This is diagnostic only and never uploads or restores state.
- The automatic save runtime is nondigested and machine-local, refuses stale
  local preparation or core state, retries at most three times with a 60-update
  cooldown, times out a lost callback after 1,800 updates, and never grants
  restore authority by itself. Distinct ordered receipts remain mandatory. The
  runtime and watcher's exact-name READY-poll race are offline-proven. Native
  completion now has a separate 1,200-second bound because a populated live
  world took 680/966 seconds to finalize its metadata. Live
  boundary 11 in `restore-handoff-live-20260809-2127` produced both ordered
  receipts, verified plan checksum `0b009dd3`, and receipt-bound archives for
  both peers.
  The host now atomically publishes that verified plan over the pinned companion
  link; a late client receives it on connect, and player2 verifies and durably
  re-archives its retained local save against the exact plan. The launcher can
  manually select a plan or discover this machine's complete role-local
  plan/archive/save set, locks its resume session, and passes that attested save
  through hash verification. The localhost acceptance tool additionally
  requires both local role archives. Two exact Build 35924 processes loaded the
  distinct boundary-11 saves, independently revalidated source core `b308c2a8`,
  migrated schema 29 to 30, and converged fresh core `1873f67c`/key `9db26dfe`
  before the restore fence opened. Startup
  adopts a current plan's agent/town-development policy and rejects explicit
  conflicts. The compacted build then completed an unattended chained run:
  new boundary-8 stock saves and both receipts were ready in 55.5 seconds,
  plan `020ea09f` was discovered, both exact processes were relaunched with
  their own save, and the mandatory checkpoint converged.
  Current plan v6 additionally binds two stable paused native route samples
  and each active vehicle's canonical line/last-authorized station round; v5
  is retired because it could not seed the restarted companion cursor. The
  launcher freezes each loaded save at its first native-world boundary before
  waiting for slower diagnostics. Session
  `phase-anchor-v6-earlyfreeze-20260811` synchronized round 1, captured paired
  boundary-15 archives at plan `7da2035d`, restored both peer saves, converged
  its mandatory checkpoint, and released the active train at round 2/stop 1
  with zero faults. Production crash
  relaunch and two-computer proof remain open.
- Normal Host/Join now installs a real `MULTIPLAYER` title-screen entry. The
  game remains idle until the player selects it; selection is receipted, then
  the byte-pinned save is loaded and the session proceeds. Disposable production
  session `menu-production3-20260803` proved that entire path.
- The launcher provides Host, Join, **SYNC FROM HOST** for the complete pinned
  starting-save set, verified/manual and one-click latest-local restore
  selection, automated Localhost Test, local-only Populated Capture Lab,
  fingerprints, status/logs, evidence collection, and exact-session stop
  controls. Starting-save sync uses the adjacent TCP port, verifies every
  SHA-256, never overwrites a different save, and exposes `.sav` only after its
  metadata is complete. Peer-specific restore saves remain excluded.
- `start_freight_live_acceptance.ps1` now starts a clean 50M-per-company manual
  two-process match, proves its initial checkpoint, hands the windows to the
  player, collects the audit on close, and requires a strict current-format
  two-peer freight report. The report exposes
  ready/service/waiting/aboard/delivered/settled stages and can require an
  automatically captured converged checkpoint with cargo aboard.
- `start_feeder_live_acceptance.ps1` now starts a clean 200M manual two-process
  match and turns the focused ROAD/TRAM scenario into a strict receipt. Its
  shared audit scanner requires current exact two-peer authored payloads and no
  fault or unresolved physical/checkpoint work; the feeder report then requires
  an operational two-stop local line, a same-company corridor, positive modeled
  access, completed local passengers/revenue, and a settled payment cursor.
  Cross-company, zero-stock, zero-capacity, stale-cursor, missing-benefit, and
  peer-divergent fixtures all fail.

### Packaging and tests

- Release ZIP includes the mod, one-file companion, native injector/DLL,
  launcher, title bootstrap/coordinator, recovery watcher, archive/plan tools,
  transactional starting-save receiver, installer/verifier/recoverable
  uninstaller, docs, and SHA-256 manifest.
- Current post-change suite passes:
  - 137 core Lua tests and 108 cross-language economy scenarios;
  - game-script, ownership, GUI, hot-seat, network-company, and 1,024-event replay
    integrations;
  - 166 mod Lua and 9 investigation/tool Lua syntax checks;
  - 64 PowerShell syntax checks;
  - launcher construction smoke test;
  - 188 Python protocol/network/checkpoint/recovery/report/save-sync tests;
  - functional first-fault watcher/real-bundle fixtures, including the
    already-exited-game ordering case and the automatic-save READY-poll race;
  - a synthetic byte-exact host publication -> player2 receipt-bound archive ->
    launcher discovery flow, plus last-known-good pointer preservation.

## Not yet established

- Two physical computers completing a human Host/Join session.
- Fresh two-process proof that the non-fatal prepare path fixes public town-road
  junctions, resolves non-default resource names, and permits a later build
  after a rejected placement.
- Live multi-train station-barrier throughput, signaling interaction, and peak
  pending behavior. Human speed-3 play and a deliberately delayed peer now
  recover at the next station; automatic disconnect/reconnect recovery remains
  open.
- Moving populated worlds remaining equivalent over a long unpaused soak.
- Fresh human two-process proof for removal-only connected road/track segments,
  including the exact town-road/node plus attached-building bulldoze followed
  immediately by station placement. The live failure is preserved and its
  atomic topology route, station/depot helper boundary, disappearance checks,
  and exact unchanged-rejection binding rollback now have complete automation.
  Invalid-curve recovery after the live-proven collision-safe road/rail
  crossing and event-edge extension also remains a live gate.
  Broader complex topology splits/joins, bridges, tunnels, terrain mutation, scripted
  construction callbacks, mod construction variants, and arbitrary command
  families. The bounded stock signals/depot/station/graphless-asset matrix now
  has automated, exact-build, and ordinary two-process UI proof. Stock
  `ASSET_DEFAULT` replacement is a measured native no-op and intentionally
  fails closed; build/removal work.
- Populated line reorder/alternate-terminal visual proof, followed by the
  ordinary-widget two-process replace/sell/control matrix. The destructive
  exact one-process command/readback chain now passes.
  Purchase, assignment, peer visibility, and movement have human proof. The
  new station barrier bounds drift without exact-coordinate correction.
- Live proof of the expanded 31-visitor gate under autonomous growth and
  settlement, codecs for additional gameplay categories, and continuing proof
  that no consequential direct-script route bypasses the authority layer.
- Cargo-positive cross-peer transport and standard-UI presentation remain a
  live proof gate. Canonical industry recipes, inventories, production,
  source queues, exact per-vehicle loads, completed deliveries, revenue, and
  conservation now pass automated Lua/Python/checkpoint tests. The stock native
  agent glyph and native cargo history remain scenery by design.
- Same-town bus/tram registration, portable non-rail purchase, feeder benefit,
  endpoint-only synchronization, and authoritative line text still need a
  fresh ordinary-UI two-process proof. The packaged one-command run and strict
  staged two-peer analyzer are ready, so the next run produces a durable pass
  or the exact missing stage rather than relying on screenshots. Ship and air
  purchase/assignment need the same proof; their passenger barrier deliberately
  remains every-stop.
- Host-authored physical presentation for town and industry growth. Unproven
  autonomous systems remain frozen during authority tests. Canonical model-town
  growth and canonical industry production are implemented; this open item is
  native physical presentation plus live proof of movement between the already
  authored freight ledgers.
- Recovery stress beyond the now-passing fresh compacted-build capture,
  paired stock saves, automatic localhost relaunch/reload, and mandatory
  post-migration checkpoint plus one active train's next station round:
  positive freight/growth state and multiple simultaneous trains,
  two-computer role-local UX, production crash relaunch, host migration,
  authentication/encryption, and hostile-Internet deployment remain open.
- Live automatic-economy proof with a freshly purchased consist and newly built
  infrastructure; balance, pre-existing-save cost-basis policy, broader vehicle
  sale/replacement capture, onboarding, and public-release quality. Native
  floating income text remains explicitly cosmetic.

## Next gate

The bounded stock construction/facility, basic line/vehicle matrices, shared
clock, four-round train barrier, long pause, speed-3 rendezvous, and deliberate
slow-peer recovery now pass locally. Next use the manual lab for two trains on
one line to measure signaling interaction, station-barrier latency, and peak
pending rounds. Then run the remaining two-stop reorder/alternate-terminal
check and the focused same-town road/tram feeder scenario with
`start_feeder_live_acceptance.ps1`.

Then run the trusted two-computer populated test: enter via the title-screen
`MULTIPLAYER` button, compare the initial checkpoint, run several real passenger
cycles with intermediate samples, pause, submit one supported private track
from each peer, save on the host, confirm a linked recovery archive, and collect
both evidence bundles.

After that passes, live-prove each remaining vehicle lifecycle category one at a
time. Keep all other native command visitors fail-closed until
their canonical payload, host authorization, replay, finance, result binding,
and checkpoint chain are complete.
