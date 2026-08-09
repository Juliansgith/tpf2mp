# TPF2:MP — Technical Plan

**Companion to the concept document. Architecture, phase order, and go/no-go gates — not a task backlog.**

---

## Prototype checkpoint

The repository now implements the deterministic market core, canonical registry, persistent Lua game-script shell, atomic file bridge, Python host/client commit sequencer, audit replay, digest acknowledgements, GUI capture probes, installation tooling, deterministic match lifecycle, signed checkpoints, immutable digest-chained event records, and independent cross-language model replay. Standalone mode also has an independently implemented native turn proxy: the original player is a temporary UI desk, two added players are the real companies, active assets are leased into the desk, and assets plus the desk's signed balance delta return to the company on turn reconciliation. See `PROTOTYPE_STATUS.md` for the exact proven boundary and `REMAINING_FROM_BRIEF.md` for the itemized gap.

The empty-world proxy finance cycle, two native company creation, real journal debit/payouts, checkpoint export, and model replay passed unattended Build 35924 runs on 2026-08-01. On 2026-08-02, prototype 0.16/state schema 13 retained the 39-check standalone canonical-track proof and passed a bidirectional two-real-game localhost sequence: peer-local company mapping, match checkpoint, one host-origin and one client-origin canonical track replay, schema-3 quoted-cost charging, two post-build checkpoints, and a 600-tick structure/finance soak. The companion pins the two-player roster, blocks later commits while either phase is unresolved, compares canonical output/core digests, applies the transaction cost to canonical accounts, reconciles peer-local native wallet caches, then compares model/canonical/structural/financial checkpoints; it emits ordered outcomes, generates checksummed restart plans, and faults on rejection, mismatch, missing peers, or timeout. The native layer validates 17 unique signatures plus the pinned visitor table, mirrors callable command bindings, wraps `api.cmd.sendCommand`, observes `CommandList::Swap` and `ApplyCommand`, classifies the complete 37-tag variant, gates `BuildProposal`, and safely rejects selected unsupported line/vehicle/name/speed/terrain/date/cheat actions before mutation. The remaining gates are a two-computer human usability proof, automatic native-save recovery, original-player capture hardening, and canonical payload/replay breadth.

**2026-08-03 superseding checkpoint.** Prototype 0.17/state schema 16 closes the pre-existing populated-world ownership mismatch: two real processes loaded the same world containing towns, industries, a depot, stations, a passenger line, and a train; both mapped that network to the same canonical owner and finished the bidirectional track/checkpoint sequence with identical core `7a1b9f9d`, model `5b59ecf2`, structure `07db112f`, and mobility `a7ae06ac`. Direct ECS telemetry read 413 people, 10 line users, 8 aboard, and 2 waiting on both peers. Canonical line and railway-vehicle operation codecs now pass offline authority/consensus tests. Production Host/Join has a receipted `MULTIPLAYER` title entry and byte-pinned native save load; the host also watches for a later stable native save and archives it against the latest verified checkpoint. The final 300-tick populated soak was paused and autonomy-frozen, and the archive is checkpoint-associated rather than exact-tick, so the next gates are an unpaused two-computer human run, live line/vehicle proof, broader command codecs, and coordinated exact-boundary recovery. See `investigation/POPULATED_NETWORK_RECOVERY_AND_MENU_2026-08-03.md`.

**2026-08-03 construction/clock checkpoint.** Prototype 0.18/state schema 17 responds to a live one-sided public-road failure. Pre-existing base nodes and edges can now be rebound lazily from stable geometry, road/track resources travel by repository name instead of local index, and construction is split into unanimous no-mutation prepare followed by host build commit. A peer that cannot resolve a town junction or resource rejects the placement on both machines without faulting the session. Pause and speeds 1-4 are also host-ordered generations; peer engine rate, observed speed, heartbeat age and command backlog drive adaptive step-down, resync pause and hysteretic recovery. The full offline suite passes. Fresh two-process proof is required before either addition is called live-proven. Data-only road/track mods fit the named-resource path; arbitrary scripted mods still require explicit canonical adapters and complete mod-pack fingerprinting. See `investigation/GENERIC_PREFLIGHT_AND_SHARED_CLOCK_2026-08-03.md`.

**2026-08-04 edge-object/construction checkpoint.** Prototype 0.20/state schema 19 broadens the ordered BuildProposal path. Schema 5 carries named signal/waypoint objects, removals, and retained-object rebinding across track replacement. Schema 7 retains the exact stock-station adapter and adds bounded portable `.con`/`.module` payloads for depots, ordinary constructions, upgrades, modular station edits, and removal; it also admits the real `ASSET_GROUP`-only root used by `ASSET_DEFAULT`. Replay inventories compound outputs, preserves construction/station/group/depot identities across edit, binds assets and graph results, normalizes finance, checks ownership twice, and enters the existing physical/checkpoint consensus chain. Rendered model names and construction params strengthen stable fingerprints, and an engine helper that returns success without a physical edit now fails its postcondition instead of being acknowledged. Python rejects opaque values, machine-local fields, missing/unknown fields, invalid resources, and tampering. The integrated mock-engine network sequence passes. Exact-build live receipts prove signal add/remove plus depot/station/asset build, four custody cycles, station catenary editing, and removal; ordinary-UI two-process proof is the next gate. See `investigation/EDGE_OBJECT_AND_CONSTRUCTION_SCHEMA6_2026-08-04.md` and `investigation/SIGNAL_FACILITY_LIVE_PROOF_2026-08-04.md`.

**2026-08-04 compact-state live correction.** Stronger construction/asset fingerprints initially admitted hundreds of autonomous scenery roots into persistent operational state and reproducibly drove Build 35924 into its generic internal-error path at the next physical proposal. The manifest now still hashes every root but retains only digest/counts; construction and asset identities bind lazily when selected. `runtime/localhost-live/schema7-compact-20260804-032006` then passed both proposal directions and three checkpoint barriers at matching core `73af1552` and structure `53bb77bb`. This restores a real two-process regression gate for the state-19/schema-7 release candidate without pretending the remaining ordinary-UI facility matrix is proven. See `investigation/SCHEMA7_COMPACT_MANIFEST_LIVE_REGRESSION_2026-08-04.md`.

**2026-08-04 ordinary-UI facility acceptance.** The bounded schema-5/schema-7 matrix now passes through normal player clicks in two concurrent exact-build processes. Staged runs cover named signals/waypoints, rail-depot placement/use, stock modular-station placement/edit/removal, bench placement/removal with rival denial, and lamp/fence placement. Reruns fixed two additional UI-boundary defects: Build 35924's upgrade helper owns the station `seed`/`upgrade` control fields, and a graphless `ASSET_GROUP` preview cannot be required to contain station-style nodes and edges. The final asset run independently audits 6/0/0 physical proposals and 7/0/0 checkpoints with no relevant game errors. The next shortest playable-network gate is the ordinary line/train lifecycle, followed by unpaused drift and a two-computer session. See `investigation/ORDINARY_UI_FACILITY_MATRIX_2026-08-04.md`.

---

## Ordering principle

Phases are ordered by **information gain**, not by dependency.

Two independent questions can kill the project:

1. **Is competitive TPF2 fun?** This is answered in hot-seat on one machine.
2. **Can one authoritative stream control two native worlds?** This is answered with a dual-instance synchronization spike.

Neither question should wait for the other. After the basic journal test, the hot-seat product work and the world-authority research run in parallel. They converge only when both have passed their own gate.

Reverse engineering is not assumed to be late polish. It is a conditional implementation tier. If pure Lua cannot intercept consequential player actions before commit, suppress autonomous mutations, or reproduce their physical results, the required native hooks move onto the critical path immediately.

---

## Architectural invariants

These are product rules, not optimisation targets:

- **The host owns decisions.** Score, demand, payouts, contracts, industry allocation, accepted player actions, and autonomous growth policy are computed once.
- **The event log owns history.** Every consequential mutation has one ordered authoritative event. No peer independently invents a town-growth step, industry transition, construction, purchase, or ownership change.
- **Engine IDs never cross the network.** Every addressable object has a stable canonical identity. Each machine maintains a `canonical ID ↔ local entity ID` mapping.
- **Autonomy is disabled or mediated.** A native subsystem that can change geometry, topology, player-addressable entities, or competitive inputs must be frozen, made deterministic, or driven by host events.
- **Structural disagreement is a hard fault.** Vehicle animation and individual agents may drift within a defined tolerance. Topology, ownership, line configuration, canonical object relationships, and score may not.
- **The host is trusted.** This is private friend-to-friend multiplayer, not an anti-cheat architecture.

### Canonical identity and commit flow

Pre-existing towns, industries, constructions, station groups, depots, lines, vehicles, and any edges or nodes addressable by an MVP event receive canonical identities during the session handshake from a verified starting snapshot. Newly created objects are identified by the authoritative event that created them and a stable output slot; local numeric entity IDs are only bindings.

A committed event carries, at minimum: session ID, monotonic sequence, logical tick, event ID, actor/company, operation, canonical references, normalised payload, precondition digest, and expected postcondition. The flow is:

1. A client submits an **intent**.
2. The host validates and applies it first.
3. The host assigns canonical identities to the result and broadcasts the committed event.
4. Each peer applies it, binds its local result IDs, and acknowledges a canonical postcondition digest.
5. A failure or unexpected result pauses the session. The peer never guesses a mapping and continues.

This protocol only works if an action can be captured before the originating client permanently commits it, or if the action is performed through a mod-owned interface. Proving that capability is a Phase 0 gate.

---

## Phase 0 — Recon and world-authority gates

**Purpose:** kill assumptions cheaply. Nothing here is production code.

### 0a. The journal test — *gating*

The single load-bearing assumption in the whole design is that the mod can neutralise the game's native revenue and substitute its own. Everything about the host-authoritative overlay rests on it.

Write a throwaway mod that reads a company's income across a tick and books an equal-and-opposite entry. Confirm the balance holds flat across delivery events, over time, across save/load, and with multiple simultaneous income sources.

- **Passes** → the overlay architecture is viable. Proceed as planned.
- **Fails, or is lossy/laggy** → the economic layer has to move into native hooks, which reshapes the plan substantially. Better to know now than after Phase 1.

Test arbitrary player journals, not only the currently selected company. Confirm that custom payout entries are distinguishable from native revenue and do not get reversed again.

This is the first thing written. Once basic viability passes, the remaining synchronization gates and Phase 1 can proceed in parallel.

**Prototype finding (2026-08-01):** arbitrary-player journal debit and payouts work in Build 35924, including two independently observed company payouts. Exact native delivery-income neutralization across running services and multiple sources is not yet proven. The legacy neutralizer is intentionally disabled in turn-proxy mode because it cannot distinguish mirror entries safely.

### 0b. Multi-company source and licence audit — *gating for reuse*

**Prototype finding (2026-07-31):** the referenced Workshop item is removed, is not present in the local cache, and exposes no discoverable source licence. The prototype therefore has no code dependency on it and independently uses documented company/ownership APIs. See `multiplayer-companies-audit.md`. Native UI player switching remains a separate capability gate.

**Independent workaround implemented (2026-07-31; empty-world live pass 2026-08-01):** no native UI-player switch is assumed. In standalone mode the current player acts as a temporary control proxy. Each logical company has a different native player and wallet. On a turn boundary, every entity carrying `PLAYER_OWNED` is returned from the proxy to the outgoing company, the proxy's signed net balance delta is moved to that wallet, and the incoming company's assets are temporarily assigned to the proxy. The real game passed company creation, wallet mirroring, debit attribution, two cycles, payouts, and reconciliation. Asset custody across track/lines/vehicles remains the next live matrix rather than an inferred result.

Acquire and inspect the multi-company hot-seat implementation rather than treating its Workshop behaviour as an API contract. Confirm:

- How players and wallets are created and switched
- Which assets are assigned ownership and when
- How public roads, private infrastructure, leasing, and bulldozing are enforced
- Save/load behaviour and compatibility with the current game build
- Source availability, licence, and permission to depend on or adapt the work

If reuse is not permitted or the source is unavailable, reproduce only the observed behaviour through documented APIs and do not copy implementation details.

### 0c. Companion and file-bridge round trip

Prove a complete game → outbox → companion → network loopback → inbox → engine-script-event round trip. The bridge uses atomic files, sequence IDs, acknowledgements, checksums, session IDs, retransmission, heartbeat, and idempotent consumption. Never use the game's main log as a transport.

This proves transport only. It says nothing yet about whether native actions can be controlled.

**Prototype finding (2026-08-01):** the atomic game bridge runs in the actual game, and the companion host/client path passes a real localhost TCP integration test with matching manifests. This gate is implemented for the trusted-LAN experiment.

### 0d. Player-intent interception — *gating*

For each MVP action category, determine whether the player's native UI action can be captured before irreversible local commit:

- Track and street construction, modification, and demolition
- Station and depot construction or reconfiguration
- Line creation, editing, and deletion
- Vehicle purchase, replacement, assignment, reversal, and sale
- Ownership, naming, fare, lease, and company operations

The acceptable implementations, in preference order, are:

1. A documented pre-commit event that can be normalised and replayed
2. A mod-owned UI/builder that submits intent without first mutating the world
3. A native dispatcher hook that intercepts and optionally suppresses the command

Observing an action after it has committed is insufficient unless it can be rolled back losslessly. `api.cmd.sendCommand` proves an issuing path, not a universal interception path.

**Prototype finding (updated 2026-08-02):** supported GUI hooks provide useful proposal/vehicle observations, but no documented universal pre-commit boundary. The earlier “factory absent” conclusion was a probe bug: Build 35924 exposes `api.cmd.make.*` factories as callable tables. The native layer observes every queue/apply tag, has a proven payload-aware gate for tag 15 (`BuildProposal`), and hooks 23 additional consequential visitors. Proposal schema 2 normalizes the supported road/track/node slice; each peer reconstructs it with canonical reference translation and reports a second-phase physical digest. The complete host-issued slice now passes through the real bridge/TCP stack and two live processes; the remaining capture gate is a human original-player vanilla builder action between two computers. Non-build categories still need canonical payload capture/replay rather than mere rejection.

**Edge-ownership refinement (2026-08-01):** Build 35924's legacy `setPlayer` path asserts for `BASE_EDGE`, but its `SegmentAndEntity` Lua binding contains `playerOwned`. A disposable supported-API run replaced one public road with an arbitrary-company-owned edge and replaced it back to the desk. Both commands succeeded and both changed the local entity ID; callback result-ID vectors were empty. The source now constructs this proposal, discovers exactly one owner-matching replacement, and atomically rebinds its stable canonical/logical identity. The local default remains pinned custody until multi-edge callbacks, rollback replacements, reference migration, save recovery, and finance settlement form one fail-atomic asynchronous transaction. For networking, the result strengthens rather than removes the canonical-ID requirement.

### 0e. Canonical identity and static-world replication — *gating*

Start two instances from an identical paused save and replicate this vertical slice through authoritative events:

1. Build one track segment
2. Build one station and connect it
3. Create and edit one line
4. Buy, configure, assign, reverse, and sell one vehicle
5. Modify and then demolish one created construction

For every operation, bind created local entities to host-assigned canonical identities. Verify normalised geometry, resources, ownership, topology, line-stop relationships, and deletion results. Include multi-output proposals and failure cases.

Canonical IDs solve differing local numbers; they do not repair differing physical results. Any ambiguous output binding or asymmetric command result fails this gate.

### 0f. Own the autonomous world — *gating*

Do not try to keep two independently evolving native worlds approximately aligned. Remove independent sources of consequential change, then reintroduce them as host policy and ordered events.

Test in increasing difficulty:

1. **Frozen baseline.** Disable town development and industry level/closure changes. Replay player events for at least 60 minutes and verify structural digests.
2. **Host-driven town policy.** The host computes R/C/I targets and broadcasts them. This proves policy ownership only.
3. **Host-driven physical development.** Trigger town development as discrete events and verify the exact buildings, streets, parcels, and relationships created on both instances. Setting identical capacities is not enough if the engine realises them differently.
4. **Host-driven industry state.** Put industries into manual development where possible; make level, closure, output allocation, and contract changes authoritative and verify their physical state.
5. **Visual demand coupling.** Determine whether passengers or cargo can be injected, withheld, redirected, or otherwise calibrated so native loads and queues agree directionally with authoritative demand. A load-time cargo-definition injector is not proof of runtime station-cargo control.

The frozen mode is the diagnostic baseline and a fallback ruleset, not a separate architecture. Host-driven growth uses the same World Authority event stream when its physical-realisation gate passes.

**Prototype finding (2026-08-01):** the live validator successfully issued town-autonomy freeze and captured a structural digest in a fresh world. Canonical mobility snapshot/comparison code exists for native person/cargo line membership and terminal occupancy, but the final fresh-world Build 35924 engine/GUI states reported all required simulation-system reads unavailable. The live observation bridge, long-duration/industry/dual-instance freeze, host-driven physical development, and runtime steering therefore remain open.

### 0g. Determinism and drift baseline

Run the same authoritative event log from the same save on two machines. Hash selected structural state canonically, excluding local entity IDs, individual agents, and harmless animation timing. Measure time-to-first-divergence, classify the first differing subsystem, and test failure recovery from a checkpoint.

Client-side town population drift does not corrupt host scoring because the client never computes score. It remains fatal if it changes local geometry, command validity, capacity feedback, or what the player sees.

### 0h. Native anchor probe and tier decision

Price the fallback rather than assuming it is optional. Confirm the Lua binding registration table, command dispatcher, tick loop, RNG, and save serialiser anchors. Estimate the hooks required by any failed gate above:

- Universal command interception and pre-commit suppression
- Tick coordination and deterministic stepping
- RNG control around native event realisation
- Direct canonical command injection and result capture
- Runtime cargo/passenger mutation if required for visual coherence

Use pattern scanning, never fixed offsets. The output is a written decision: pure Lua is sufficient, a scoped native layer is required, or the simultaneous-world design must narrow.

**Prototype finding (updated 2026-08-02):** the scoped native layer is required and its observer/gate tiers are implemented. The injector and DLL fail closed on full SHA-256, architecture, PE timestamp/image size, 17 exactly-once signatures, and the selected command visitor table entries. Live evidence covers the binding table, `SetupCommandInterface`, wrapped states, `CommandList::Swap`, `ApplyCommand`, the 37-tag discriminator, direct applies, the tag-15 build gate, and normal suppress/authorize callback behavior for the 23-tag gate. The first semantic tier above it is implemented for linear roads/tracks: canonical payload, host-ordered action, one-shot release, local reconstruction, result discovery, ownership correction, and canonical binding. The next priced tier is category-specific payload/replay for the newly gated commands; tick/RNG/agent hooks remain conditional.

**Exit criteria:** journal control proven; reuse/licensing resolved; IPC proven; MVP player actions have an authority path; the static vertical slice remains structurally identical; autonomous systems have a proven frozen or host-driven mode; and the required RE tier is named honestly.

---

## Phase 1 — The game, hot-seat, pure Lua

**Purpose:** build the actual product. No networking, one machine, on top of the independently implemented native turn-proxy layer.

This is the largest product phase and runs in parallel with Phase 0c–0h after the journal mechanism is viable. It answers the only question engineering cannot rescue: whether the competitive rules are worth networking.

Scope:

- **Turn custody and accounting.** Treat the native current player as a UI proxy, not a competitor. Reconcile all proxy-owned entities and the signed proxy balance delta before leasing in the next company's assets. Keep the legacy post-build capture path only as a diagnostic comparison and fallback.

- **A small first market.** Two towns, direct passenger corridors, no transfers, no freight contracts. Prove that fares, frequency, journey time, capacity, and an outside option produce readable strategic choices before expanding the graph problem.
- **The demand model.** Deterministic by construction: integer arithmetic, explicitly sorted iteration, and an owned seeded RNG. Inputs come from the host's canonical, verified world view — never from independently sampled client state. Native facts used by the model are normalised, versioned, and represented in the authoritative state.
- **Fares.** Per-line pricing, invented wholesale — vanilla has no equivalent — plus the UI to set and read it.
- **Contention mechanics.** Begin with passenger demand splitting and capacity. Add transfers, exclusive contracts, capped industry output, station access, and land claims only when the simpler game demonstrates a need for them.
- **Scoring and payout.** Company valuation, revenue, reach; paid via the 0a counter-entry mechanism.
- **State serialisation.** Full save/load of the model's own state through the script hooks. **Design this as if it's a network packet from day one** — it becomes the resync payload in Phase 3 at no extra cost.
- **Legibility UI.** Why you're losing share on a corridor, shown plainly. Per the concept doc, competition the player can't read is noise.
- **Visual-coherence experiment.** On one machine, compare authoritative share with native loads and queues. Establish the minimum directional agreement the multiplayer product must preserve.

**Exit criteria:** two people play it hot-seat for several hours and want to keep playing. If they do not, iterate here. Networking never rescues a ruleset that is not fun.

**Prototype status (2026-08-01):** the direct-corridor economy, fares, payouts, scoreboard, epoch/value match endings, two-company turn custody, and portable model checkpoint exist. The actual-game empty-world financial loop passed. The phase has not exited: asset-heavy native play, running operations, competitive credit/bankruptcy, visual coherence, broader contention mechanics, and multi-hour human fun testing remain.

---

## Phase 2 — Authoritative event log and replay

**Purpose:** prove both the authored model and the controlled structural world can be reconstructed before a network exists to blame.

Build two related harnesses:

1. **Model replay.** Feed normalised intents and world facts into the economic model from the same snapshot. Require byte-identical self-authored state.
2. **World-event replay.** Feed committed canonical events into fresh copies of the starting save. Require identical canonical structural digests even when local entity IDs differ.

Digest companies, ownership, constructions, geometry, relevant edges/nodes, station groups, lines, vehicle configuration, town/industry authoritative state, canonical mappings, and model state. Do not require byte-identical vehicle positions, individual native agents, or UI animation.

The event log and checkpoint form the forensic artefact for every later desync. A structural mismatch stops at the first differing event with its precondition, local result, and expected postcondition recorded.

**Exit criteria:** byte-identical model state and equivalent canonical structural state across repeated long-session replays.

**Prototype status (updated 2026-08-02):** state schema 13/checkpoint format 2 exports separate authored-model, canonical, structural, and canonical-financial domains plus immutable pre/post-digest events. Canonical network accounts and ordered ledger entries now participate in model replay; native wallets are cache diagnostics. Asynchronous native proposal results are finalized inside a sanitized audited event; machine-local output IDs stay in process memory. Physical completion/checkpoint reports and ordered consensus controls are audit-verifiable, and the latest agreed boundary can be rendered as a checksummed restart plan. A 104-event cross-language trace passes. The strongest two-process localhost run passed three all-peer checkpoints around two bidirectional physical track replays and a 600-tick soak, finishing core `fdaceb08` and structure `33cdc17a`. This completes the bidirectional two-live-instance physical-event slice, but not Phase 2’s full exit: randomized/human long traces and automatic identical-save capture/reload are still absent.

---

## Phase 3 — Networking, host-authoritative

**Purpose:** make it live.

A companion application per player sits outside the game. It transports client intents to the host and committed events back to each game through the proven bridge. It does not decide game state.

The host validates intents, applies accepted actions first, assigns canonical result identities, runs the demand and autonomous-world models, and broadcasts one ordered event stream. Clients render and never compute score. The originating client must not permanently commit an unapproved native action; the authority path proven in Phase 0d is mandatory here.

Verification has two layers:

- **Self-authored state:** hierarchical hashes per company, market, line, contract, and canonical registry. Diverged subtrees can be replaced from the host.
- **Selected native structure:** canonical postcondition digests after every consequential event. Do not pretend arbitrary native map divergence can be repaired by replacing a Lua table. If no tested repair exists, stop and reload from the latest agreed checkpoint.

The session handshake pins and verifies the game build, protocol version, starting-save checksum, DLC, every active mod and load order, mod parameters, resource manifest, and companion version. Initial compatibility is a curated match pack, not arbitrary Workshop content. Steam auto-updates must fail the handshake rather than silently changing one peer.

The host is trusted and can cheat by altering its process or files. State that plainly; anti-cheat is outside scope.

**Exit criteria:** two machines complete a full session from a fixed scenario with live competition, equivalent canonical structure, directionally coherent presentation, and an undisputed scoreboard. Host-driven town and industry development is enabled only for the subsystems that passed Phase 0f; the remainder stay frozen.

**Prototype status (updated 2026-08-02):** the external transport, automatic release fingerprint, ordered commits/controls, reconnect replay, audit, and convergence alerting work over localhost TCP. Host-normalized rules/results and ordered mobility samples are included. BuildProposal has a native gate, and schema-3 proposal actions are normalized, company-authorized, cost-quoted, reconstructable, canonically bindable, and subject to two-peer completion/checkpoint consensus. Twenty-three other consequential tags fail closed at their own visitors. Queue acknowledgements do not advance physical dependencies: the host waits for matching completions or faults. Bidirectional two-live-process physical runs pass, but the phase is not yet playable general native-world multiplayer because the human vanilla capture path is unproven across two computers, fault recovery is restart-only, unsupported proposal subtypes fail closed, and non-build actions have no canonical payload/replay tier.

---

## Phase 4 — Conditional native authority layer

**Purpose:** supply capabilities that Phase 0 proves are required but unavailable through documented Lua. This phase may be on the critical path.

Possible scoped hooks:

- **Universal command interception** before native commit
- **Suppression or deferral** of speculative local actions until host acceptance
- **Tick coordination** for pause, step, and bounded lead
- **RNG control** around town, industry, and proposal realisation
- **Direct command injection and result capture** for canonical binding
- **Targeted native cargo/passenger mutation** if visual coherence cannot be achieved in Lua

Keep the surface minimal and anchored from readable binding, dispatcher, and serialiser metadata. Build with **pattern scanning, never hardcoded offsets**, pin supported game builds, and treat the native component as a separate launcher/plugin with its own distribution and support burden.

**Implemented authority tiers (updated 2026-08-02):** the Build 35924 injector/DLL validates the exact file, 17 signatures, and the visitor table, observes/mirrors bindings, wraps the issuing function after sol2 setup, pairs queued commands with applies, identifies direct applies, classifies 37 tags, and retains timelines. Tag 15 and 23 selected consequential tags can reject or consume one matching authorization. Above it, schema 3 provides canonical linear road/track payloads, authoritative builder costs, local reconstruction, multi-output geometry binding, supported ownership correction, physical result consensus, a canonical account ledger, native-wallet reconciliation, and a wallet-aware checkpoint barrier. Standalone run `20260802-075533` retained the 39-check proof; focused run `20260802-075034` proved the generic visitor gate; localhost run `localhost-20260802-175636` passed bidirectional two-live-game replay and the 600-tick finance/structure soak. Broader codecs, two-computer human capture, and automatic native-save recovery remain on the critical path.

**Exit criteria:** every capability promoted from a failed Phase 0 gate is proven on the pinned build, including update failure that is loud and safe. If the required hook cannot be supported reliably, narrow the product rather than masking structural desync.

---

## Phase 5 — Native presentation integration and agent pathing

**Purpose:** make the visible operational world agree more closely with the authoritative competitive model.

The minimum product requirement is directional coherence: a route awarded more demand should normally carry more passengers or cargo, subject to its capacity and operations. Exact agent-for-agent agreement is unnecessary.

First prefer supported levers: town cargo needs, production/manual-development controls, capacity, and host-authored discrete events. If runtime cargo or passenger creation is not exposed, decide explicitly between a scoped native mutation layer and positioning the mode as a scoring overlay. Do not describe load-time cargo-definition injection as proof of runtime station-stock control.

For deeper fidelity, map struct layouts from the save serialiser rather than from scratch. Attack route cost functions or graph edge weights upstream of the pathfinder rather than replacing the search itself, which may be batch-vectorised.

Note that replacing per-agent logic doesn't by itself fix drift, since the engine's scheduler still determines processing order. Serialising the agent update is a separate hook and a separate decision.

Exact agent synchronization remains stretch work. Directionally misleading loads are not dismissed as cosmetic; they either meet the acceptance threshold or force an honest change in product scope.

---

## Critical path summary

| Work | Pure-Lua status | Native layer | Produces |
|---|---|---|---|
| 0a–0c | Expected | None expected | Finance, reuse, and transport foundations |
| 0d–0h | Partial; still gating | Universal observation, BuildProposal gate, and 23 fail-closed visitors implemented; canonical replication tier still required | Go/no-go and exact authority tier |
| 1 | Expected | None | **The competitive game in hot-seat** |
| 2 | Depends on 0d–0f | Conditional | Model + structural replay harness |
| 3 | Networking itself is pure external/Lua | Inherits gate results | **Live authoritative competition** |
| 4 | Not applicable | Queue/apply observation and tag-15 pre-mutation gate live-proven; serialization/injection/result tier missing | Missing critical authority capabilities |
| 5 | Aggregate observation implemented | Mutation optional-to-deep, except minimum visual gate | Visual and operational coherence |

**Current-table correction (2026-08-02):** Phase 2 now has complete authored-model replay, canonical network accounts, and one live canonical physical road/track slice. Phase 4 includes the linear schema-3 semantic payload/cost/reconstruction/result-binding tier plus 23 fail-closed non-build visitors. Both remain partial because human two-computer proof, broader canonical payloads/replay, and automatic save-boundary recovery are missing.

A complete hot-seat competitive game is expected to require no reverse engineering. A complete simultaneous same-world product is reverse-engineering-independent **only if** Phase 0d–0f prove pre-commit authority, canonical physical replay, and autonomous-world control through supported scripting. Until those gates pass, “Phases 0–3 deliver the complete product without RE” is not a claim this plan makes.

---

## Current implementation addendum (2026-08-06)

State schema 21/checkpoint format 3 added shared-clock and vehicle-synchronization domains to the authored-model, canonical, structural, and financial projections. Completed per-vehicle station-release rounds are persisted and digested so reload cannot repeat a departure barrier. State schema 24/checkpoint format 4 additionally binds exact model passenger queues, per-train loads, full canonical stop sequences, trip endpoints, and the passenger round cursor to that same release authority.

Vanilla roads, tracks, stations, station modules, depots, signals, waypoints, assets, bulldozing, and supported upgrades have live bidirectional capture/replay evidence with company authorization. Vehicle purchase, line assignment, peer visibility, and movement passed a human two-instance run. Shared-clock v2 turns pause, resume, and speed changes into future rendezvous barriers, projects fresh peer heartbeats to host time, caps speed to the slowest healthy peer, and faults failed corrections. A per-canonical-vehicle station barrier holds every replica at the same stop until all peers report the same round, then orders one future release. Ordinary lines use only the bounded network guard; registered competitive services use the same barrier with their one authored departure policy and a host-reserved slot. This bounds accumulated service divergence at operationally meaningful points without requiring identical mid-leg physics.

**2026-08-06 train/clock live checkpoint.** Session `train-station-fresh-clock-20260806-0630` loaded the same populated save in two exact Build 35924 processes, paused both restored worlds until authority and both clock samples were ready, then resumed its real NOHAB + two-BC4 train. Four alternating canonical station rounds released at game times `1097.2`, `1146.6221294362097`, `1195.0`, and `1241.2`; the last was pause-safe. Host status ended at one tracked vehicle, four releases, zero pending rounds/faults, clock skew zero, and converged mobility/lifecycle/route phase. Final core/model/structure/mobility were `1fea40f9`/`98f01295`/`e1488bff`/`6fca8ed2` on both peers.

**2026-08-06 prompt-barrier checkpoint.** Session `train-prompt-barrier-state22-20260806-105918` removed the synthetic fallback timetable from ordinary lines while keeping registered-service slot allocation. The same real train completed four unscheduled releases with zero pending rounds/faults; average and maximum full-round latency were 1.86 and 2.38 seconds. Both processes converged at core/model/structure/mobility `fba1630d`/`98f01295`/`15189409`/`8e5d90e6`. A preceding human speed-3 run deliberately delayed Player 2 and observed Player 1 wait at the station until both departed together.

**2026-08-09 freight-authority checkpoint.** Prototype 0.32/state schema 29/checkpoint format 5 connects the loaded-content industry ledger to exact authored freight movement. Cargo-only lines bind a portable source-output/destination-stock/cargo contract and every assigned consist's exact named capacity. Ordered station rounds own source queues, heterogeneous per-vehicle loads, completed deliveries, discard conservation, and unit-kilometre revenue. Each five-minute boundary stages aggregate source withdrawal, destination deposit, production, economy, and passenger/cargo presentation as one transaction. The standard line/vehicle/station/manager/statistics/top-bar surfaces show those authored values; native cargo agents and history are explicitly cosmetic. Independent Lua/Python focused replay plus a deterministic 256-boundary, three-cargo, 12-line stress trace, current-checkpoint validation, tamper cases, and the full repository/release gate pass. The implementation is complete enough for a cargo-positive two-process run, but that live receipt and save/reload with cargo aboard remain open. See `investigation/FREIGHT_TRANSPORT_AND_PRESENTATION_AUTHORITY_2026-08-09.md`.

The next gates are the cargo-positive two-process run, human two-computer latency/slow-peer/disconnect proof, automatic identical-save recovery, and broader mod-command coverage. The earlier dated status paragraphs remain as historical milestones rather than the current capability statement.

---

## Standing risks

- **Only categories with proven visitors can be stopped before mutation** → keep the 23 newly gated commands unavailable until they also have canonical payload/replay; keep unlisted categories out of network authority until their own pre-mutation points are proven.
- **Canonical IDs bind to different results** → stop on the first asymmetric postcondition. IDs translate references; they do not cure divergent geometry.
- **Town policy is controllable but physical growth still diverges** → keep development frozen while testing explicit host-driven development or add scoped RNG/result control.
- **Target-addressed native cargo/passenger control is unavailable** → authored passenger/cargo queues and vehicle loads now replace misleading stock-UI values while native agents/history remain cosmetic. Live-prove that projection on both peers; do not quietly promote native scenery back into competitive authority.
- **0a fails** → the economic layer moves native and the timeline changes materially.
- **The ruleset is not fun** → the only unrecoverable product failure. Phase 1 runs early and gates on play, not completeness.
- **The multi-company dependency cannot be reused** → implement against documented APIs after the licence audit; do not ship copied code without permission.
- **Mods change resources or command outcomes** → start with a curated, hashed match pack and expand compatibility through testing.
- **Game updates break hooks or invalidate manifests** → pattern scanning, pinned builds, explicit compatibility checks, and loud refusal to start.
- **Native state leaks into client-side scoring** → clients never compute score; host inputs are canonicalised and replayed through the Phase 2 harness.
- **Structural desync cannot be repaired live** → checkpoint and reload. Do not claim Lua-state resync repairs a divergent native map.
- **Scope creep into a total conversion** → the concept document's “what this is not” section remains the check.
