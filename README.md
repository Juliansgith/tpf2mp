# TPF2MP competitive multiplayer prototype

TPF2MP is an executable research prototype for competitive Transport Fever 2. It currently contains two related products:

1. A playable local hot-seat mode with two native companies, separate wallets, separate logical assets, a turn-desk proxy, contested demand, fares, scoring, match rules, save state, and checkpoints.
2. A restricted playable two-player alpha with an outbound-only TLS relay (or direct trusted LAN/VPN fallback), a TCP commit sequencer, canonical identities, an exact-build native command gate, portable construction/line/vehicle replay, a shared economy, reconnect fencing, and receipt-bound recovery.

This is now code-complete for that deliberately bounded alpha profile, not general hostile-peer multiplayer. Prototype `0.42.1-alpha`, state schema `34`, checkpoint format `5`, operation schema `4`, passenger-presentation schema `4`, cargo-presentation schema `2`, freight-industry schema `3`, edge proposal schema `5`, and construction proposal schema `7` cover canonical construction, atomic topology edits with collateral demolition, lines, portable vehicle lifecycle, synchronized station legs, exact passenger and multi-hop cargo presentation/revenue, connecting demand, feeder access, save-owned difficulty, model and physical town development, bounded disconnect/reconnect backlog replay, receipt-bound coordinated restore, loaded-content agreement, settlement-coupled freight stocks/production/transport, automatic starting-save transfer, and an outbound-only TLS relay with centralized redacted diagnostics. Stock road, rail, tram, air, and water carriers now have explicit automated coverage, including exact-build aircraft and ship movement. Connected street constructions—including road/tram depots and passenger/cargo terminals—use graph-derived exact replay without a stock-resource allowlist. The remaining release gate is the physical two-computer run defined in [ALPHA_RELEASE_CHECKLIST.md](ALPHA_RELEASE_CHECKLIST.md), not another unnamed code subsystem. Start with [ALPHA_QUICK_START.md](ALPHA_QUICK_START.md); see [SECURE_RELAY.md](SECURE_RELAY.md), [PROTOTYPE_STATUS.md](PROTOTYPE_STATUS.md), [REMAINING_FROM_BRIEF.md](REMAINING_FROM_BRIEF.md), and [the investigation index](investigation/README.md) for the broader post-alpha boundary.

## What works now

- Two persistent native company players with independently audited balances and configurable starting cash. New matches default to `$50,000,000`; `$25m`, `$50m`, and `$100m` presets are available.
- A native turn desk that temporarily leases the active company’s manageable assets and mirrors only that company’s wallet.
- Fail-atomic reconciliation: asset return is verified before money moves, and failed settlement cannot be multiplied by retrying.
- Safe road/track handling on Build 35924. The game’s legacy `setPlayer` path asserts on direct `BASE_EDGE` transfer, so company ownership is retained logically. Native custody is normally the desk; depot/station cascades may place attached edges on their rightful company, which is now an explicitly validated state.
- Pre-commit rejection of builder proposals that touch another company’s tracked road, track, node, edge object, or construction.
- A broader GUI-level logical-owner veto for known line, vehicle, station, depot, and construction mutations, backed in network mode by fail-closed native visitors for 31 consequential and autonomous command tags.
- A deterministic contested-demand economy (model version 10) with passenger and cargo market kinds. Fare, journey time, wait, transfers, comfort, feeder access, and lagged crowding become a generalized cost in cents; demand splits through an integer-exact pinned-logit model; market share is a persistent stock; and fare-shock/cutoff rules prevent retained-rider and maximum-fare exploits. Requested demand is distinct from admitted route throughput: capacity-constrained excess becomes a synchronized waiting class, and requested load feeds the next epoch's crowding cost. Passenger revenue additionally requires both endpoint station groups to reach at least one building through the native street catchment; disconnected services remain visible and pay upkeep but receive no modeled passengers or revenue, and topology edits revalidate them automatically. Same-town passenger lines own local markets. A company road/tram feeder sharing an exact station group with its intercity service lowers passenger cost at that endpoint by up to `$1.50`, scaled by the weaker of feeder frequency and hourly capacity; two distinct local stops are required and duplicate feeders never stack. It settles automatically every five synchronized minutes, prorates hourly demand/capacity exactly, and pays passenger and cargo revenue once from completed synchronized legs. The world-creation menu offers Hard (60% gross revenue), Normal (100%), Easy (150%), and Relaxed (200%); the chosen rule is stored in the save, host-authored at match start, read-only during play, and old saves migrate to Normal. Difficulty changes revenue only—never native/mod purchase prices, upkeep, demand, or physical capacity—and exact residual carry prevents rounding exploits. The default passenger fare is `$5 + $1.50/km`, each displayed passenger represents a 1,000-person financial cohort, and the cargo baseline is `$1,000/unit-km`. Native purchase price and resolved annual maintenance remain exact; competitive upkeep compresses a financial year into three authored hours. Parked vehicles cost money, private infrastructure costs ten percent of capital per financial year, and public town roads are excluded. Lua and Python replay demand, feeder access, passenger/cargo delivery cursors, freight stocks, costs, difficulty residuals, canonical town growth, signed wallet-cent carry, settlement, and scoring digest-identically; archived v2-v9 economy paths remain readable.
- Checksummed checkpoint format `5`, immutable digest-chained events, independent Python model replay, and canonical state that excludes machine-local numeric IDs. Checkpoint convergence includes authored state, canonical bindings, structural state, canonical company balances/loans, authorized per-vehicle station-release rounds, exact passenger/cargo queues and loads, and freight stock/production/transport cursors. Formats 1 through 4 remain readable for archived evidence.
- A dependency-free Python host/client sequencer with content fingerprints, ordered commits, reconnect replay, acknowledgements, and divergence reporting. Hook `0.19.0` moves numbered bridge file I/O onto its bounded native worker; the game Lua thread signs/validates envelopes and exchanges only in-memory FIFO entries. The no-hook compatibility path remains available. Its durable file bridge polls the exact next sequence in constant time and refuses gaps. Checkpoints/events/research remain available for offline evidence; acknowledged replaceable clock-health and vehicle-sync source files older than a 4,096-message tail are pruned instead of accumulating indefinitely. Every heartbeat still drives live policy, while the authority journal retains one forensic health sample per peer per ten seconds. Windows audit reads use closed-handle snapshots and bounded sharing retries; permanent persistence failure leaves an observable fail-closed host instead of silently killing authority.
- Canonical multi-hop freight authority behind the loaded-content gate. Each game captures the construction resources it actually loaded, the companion strictly merges them, and all peers attest the exact registry before the host bootstraps canonical live industries. State 32/freight schema 3 persist recipes, input/output stock, production residuals/totals, exact active cursors, and compact retired-line history. Carrier-neutral cargo legs discover producers and compatible inputs at every stop, route through exact shared station groups, and keep authoritative transfer-station inventory; a source without a reachable consumer has zero demand/capacity and cannot ship. An unused route may replan, while the complete route is pinned at its first ordered vehicle release. Ordered releases own queues, loads, transfers, completed deliveries, and unit-kilometre revenue. A five-minute boundary atomically validates aggregate reservations and transfer conservation, withdraws source stock, deposits only final delivery into the destination, advances production, records money, and moves both presentation epochs. Standard cargo/line/vehicle/station/manager surfaces show these authored values. Native cargo agents and history remain cosmetic. Missing, changed, ambiguous, overdrawn, or reload-incompatible content, paths, stocks, and cursors fault closed. The exact vanilla registry remains 16 positive-flow resources and 160 variants at digest `edc7a517`; multi-hop cargo-positive live play is the remaining proof gate.
- A deterministic carrier-neutral transport graph adds passenger through-demand and cargo paths across up to four registered lines, including transfers at intermediate stops of through services. The Multiplayer panel's **Routes / Transfers** view shows canonical chains, transfer demand/capacity, unresolved cargo lines, and authoritative station stock. Its **Compatibility** view inventories every successfully admitted named road, track, model, construction, and module resource. Vanilla and data-only mods share the same exact-name/content-fingerprint path; opaque executable callbacks still require explicit adapters.
- Native hook `0.19.0`, pinned to the exact Windows x64 Build 35924 executable. It validates SHA-256, PE metadata, 17 unique signatures, and 31 entries in the command visitor table; observes the native command pipeline; wraps `api.cmd.sendCommand`; strictly gates tag-15 `BuildProposal`; and gates 31 consequential/autonomy tags before mutation. Its bounded suppression FIFO stamps every rejected BuildProposal visitor with a process-monotonic generation and the exact GUI preview token that was armed before the click; stale, reordered, missing, and overflowed correlations fail visibly instead of reusing the latest preview. The constant-time B2 sample keeps hover previews away from the full native-status serializer. Tags 17-24 now close the native Create/Remove/Develop Town, SetTownInfo, town-cargo, town/industry-connect, manual-industry-development, and building-closure command surface. Ordered town development, town information, and industry freezing consume exact one-shot tags 19, 20, and 23; the other five have no gameplay authorization path. The hook also converts suppressed vanilla pause/speed clicks into ordered shared-clock requests; captures typed CreateLine/DeleteLine/UpdateLine plus SetName/SetColor payloads from the ordinary line manager as optimistic origin pass-throughs; captures pointer-free BuyVehicle, SetLine, reverse, start/stop, maintenance, depart, send-to-depot, SellVehicle, ReplaceVehicle, and manual-departure identities before mutation; and owns the bounded asynchronous bridge worker plus a native monotonic performance clock. Config-bearing buy/replace commands are correlated with the bounded stock GUI consist. Tag 12 uses a versioned envelope that retains the complete bounded, duplicate-free stock selection for canonical batch sale. Build 35924 asserts if the line visitors reject, so any later rejection of an origin-applied line operation faults the session closed and requests the ordered pause.
- Canonical proposal schema `5` for street/track and named edge objects. It uses stable output slots, canonical existing references, deterministic negative temporary IDs, repository resource names rather than machine-local indices, a bounded authoritative builder cost quote, private/public ownership, geometric postcondition matching, supported ownership replacement, and canonical result binding. Co-located road/rail topology nodes use a deterministic canonical incident-edge anchor instead of leaking or guessing native IDs. Signals and waypoints are serialized by `.mdl` name, and existing edge objects can be retained and rebound when their carrier edge is upgraded. Removal-only road/track clicks may carry ordinary attached-building removals in the same atomic native proposal; exact edge/node/object/construction disappearance is required before retirement or finance. A verified no-world/no-wallet-change native rejection rolls back only command-local lazy bindings, permitting a rejection checkpoint and the next valid build. Vanilla and data-only mod resources use the same path when the complete match content is identical.
- Canonical proposal schema `7` for construction build, upgrade, edit, and removal. The strict stock modular passenger/cargo rail-station adapter remains available for menu placement. A bounded portable adapter carries a named `.con`, full finite transform, recursive plain parameters, and named `.module` records for depots, ordinary constructions, assets, and modular edits. Engine replay inventories and binds construction/station/group/depot/asset/edge-object/graph outputs, preserves source identities across real upgrades, normalizes finance, and enters physical/checkpoint consensus. Schema 7 recognizes the real `ASSET_GROUP`-only root used by `ASSET_DEFAULT`. Opaque callbacks, local IDs, missing resources, ambiguous outputs, and native “success” calls that do not change the world fail closed. These forms pass the automated sequence and exact-build engine proof; stock depot/station/graphless-asset forms also pass the ordinary-UI two-process matrix. Mod construction variants and broader facility families remain unproven.
- Authoritative shared-save ownership: pre-existing world assets receive the same canonical owner on both peers before peer-local player binding. Fresh bootstrap then projects manager-visible stations, depots, constructions, lines, and vehicles onto each peer's native company representatives and verifies readback before checkpoint; unsafe base-edge reassignment remains excluded. A replay records the local command issuer separately from the intended native output owner, preventing either source assets or remote builds from changing company merely because local native player IDs differ. See [the save/load ownership repair](investigation/SAVE_LOAD_NATIVE_MANAGER_OWNERSHIP_2026-08-06.md).
- Three-stage construction consensus. Every captured proposal first becomes `proposal.prepare`; all pinned peers must resolve its canonical geometry, named resources, and ownership against an unchanged core before the host emits `proposal.build`. A prepare rejection mutates neither world and does not poison the session. Successful native replay is followed by a local-ID-free completion record containing canonical outputs, physical/core digest, and the transaction's canonical cost. The host applies the signed cost only after physical agreement and then requires the normal checkpoint barrier. Stations, depots, assets, construction edits, and construction bulldozes are physically single-flight. While an ordered physical/checkpoint barrier is active, one exact latest-only construction lane retains the newest click and replaces an older pending construction at the FIFO tail; it never accumulates a delayed ghost backlog. A full bounded queue rejects visibly. Short road/track/signal/waypoint sequences retain the ordinary bounded topology FIFO.
- A host-ordered shared simulation clock. Pause and speeds 1-4 use future-time `clock.rendezvous` barriers: staggered heartbeats are projected to one host time, both games pause at the same target, overshoot gets a bounded speed-1 catch-up round, and only then is the requested speed released. Paused GUI heartbeats keep resume safe after long menus. The adaptive governor compares each peer's measured game-time progress with the nominal rate of its selected speed rather than render/update FPS, requires sustained soft skew or slow progress before stepping down, preserves an immediate hard-skew path, and requires a stable interval before recovery. It therefore catches one slow peer and two equally overloaded peers without punishing harmless FPS asymmetry. Heartbeat age, command backlog, pending construction, and observed-speed mismatch remain fail-safe inputs.
- A canonical station-leg barrier for replicated assigned vehicles. Each native copy uses the supported at-terminal state and `stopIndex`, holds through gated `setUserStopped`, and waits for the complete peer roster before an ordered future-time release. Passenger rail/water/air and unreadable services retain every-stop synchronization; road/tram services rendezvous at their route endpoints, and freight at its exact source/sink, avoiding a network round at every urban curb stop. Competitive headway remains a demand/capacity input and is not imposed as a second native timetable. Release state is checkpointed and restart-safe. Once every peer acknowledges an ordered shared pause, pending station-round wall-clock deadlines stop until the latest-generation running control is also acknowledged; a peer that never acknowledges still times out normally. Mismatch, active-time timeout, premature departure, or rejection faults and pauses the session. This bounds leg drift but does not claim deterministic native agents or metre-by-metre position lockstep.
- Canonical network accounts own competitive balances; native player wallets are reconciled peer-local caches. Automatic five-minute accounting applies completed-trip gross revenue minus complete-consist and private-infrastructure upkeep, with signed sub-dollar carry into the integer native wallets. Adaptive reconciliation follows authored corrections immediately but audits an idle cache every 15 engine updates; it removes native trip income, loan-interest, and maintenance drift without making a full player-entity pass on every simulation update. The normal account, earnings, passenger, vehicle, line, station, manager, finance, and statistics surfaces show last-tick, pending completed-trip, and projected-hour TPF2MP figures; misleading native load, queue, transported, profit, and history widgets are hidden or explicitly relabelled cosmetic. Stock purchase price and annual maintenance deliberately remain unchanged because they are the exact mod-resolved native values admitted by consensus. The native world-space trip-income popup is engine-rendered presentation only and does not move competitive cash.
- A populated bidirectional two-live-process localhost harness. It safely starts and hooks two exact game PIDs, loads a byte-pinned save containing towns, industries, a depot, line, stations, train, and passengers, waits for both paused clock samples, proves checkpoints and bidirectional proposals, runs the real train through four station barriers, compares mobility/lifecycle/route phase, restores shared settings, and independently audits the result.
- Canonical line and vehicle operation codec schema `4` has strict host/company authorization, replay/result checking, finance routing, physical consensus, and checkpoint tests. Ordinary vanilla **New Line**, stop add/remove/reorder/terminal updates, and line deletion feed the line codec through typed capture. **Buy** accepts any bounded portable `vehicle/*.mdl` resource (including data-only mod vehicles) and pairs the GUI's ordered carrier-neutral model list with the pinned native player/depot payload; oversized, deeply nested, missing-resource, or truncated captures fail closed. **Set Line** is captured from the native visitor. Hook 0.17 retains the pre-mutation stock adapters for reverse, start/stop, maintenance, immediate departure, send-to-depot/sell-on-arrival, direct or multi-selection sale, replacement, and manual departure. A stock sale of 2-256 unique vehicles becomes one sorted canonical transaction: all targets are preflighted, replay uses the public scalar sale API in deterministic order, and finance, entity-absence postconditions, presentation cleanup, line refresh, physical consensus, and checkpointing remain one aggregate boundary. Native failure after an earlier scalar deletion faults the session because the public API provides no physical rollback. Replacement refreshes the canonical consist and automatically re-registers its assigned line so capacity/speed/upkeep facts cannot remain stale. Railway purchase, assignment, peer visibility, movement, and four station rounds have two-process evidence. All stock aircraft and ship resources now pass the portable protocol gates, and exact-build disposable runs prove native AIR and WATER facility creation, purchase, assignment, and movement; their ordinary-GUI two-computer acceptance remains open.
- A one-window multiplayer launcher (`LAUNCH_TPF2MP.cmd`) with Host, Join, one-click **SYNC FROM HOST** for the complete starting-save set, automated Localhost Test, exact fingerprinting, connection/recovery status, logs, evidence collection, exact-session stop controls, manual verified restore selection, and one-click discovery of the newest complete peer-local restore. Normal Host pins the selected `.sav`/`.sav.lua`/optional `.jpg` and exposes only those bytes on the adjacent TCP port; Join receives them transactionally, verifies every SHA-256, and makes the `.sav` visible last. The ordinary match fingerprint still independently proves equality before traffic. Normal Host/Join installs a real `MULTIPLAYER` title-screen entry and waits for the player to select it before loading the pinned save. Restore mode locks the plan's resume-session identity and uses that machine's peer-specific attested archive; starting-save sync is deliberately disabled for peer-specific restores. Each GUI-launched match has an exact PID/executable/start-time lifecycle supervisor: game exit tears down its detached helpers, launcher exit additionally closes its game, and a new launch replaces only a cryptographically/session-state-identifiable prior TPF2MP owner. Unknown port owners are never killed.
- Strict packaged freight and passenger-feeder acceptance commands. Both use one shared audit scanner for ordered sequencing, physical outcomes, faults, current checkpoints, exact two-peer authored payload equality, and unresolved barriers. The feeder report additionally requires an operational same-town ROAD/TRAM line, an operational same-company corridor, a real positive access benefit, completed local passengers/revenue, and a settled payment cursor; empty, rival, zero-capacity, stale, or registration-only shapes fail.
- A second all-peer checkpoint barrier after match start, every successful physical action, and every unanimously rejected no-mutation proposal. Later commands stay blocked until both peers attest the same core, structure, and finances. **Prepare & Save Restore Point** orders a shared pause/quiescence/checkpoint boundary. The host now orders the identical receipt-bound workflow automatically every 15 minutes after the previous completed restore point; restart uses receipt timestamps to refresh an already-stale point immediately. An automatic attempt has a three-minute bound, emits an ordered cancellation on failure, restores the prior shared speed only while the session remains healthy, and is reconstructed safely across companion restart. The game first attempts a callable native save command; because pinned Build 35924 does not publish one, the exact-process watcher falls back to the ordinary stock Save UI only after the matching `recovery.prepare` reaches READY. An incidental READY checkpoint never launches UI automation. Automatic names use a short deterministic session digest and stay below the dialog's 50-character limit. The watcher then requires a stable `.sav`/`.sav.lua` pair, hashes it, files an ordered peer receipt, and archives only the bytes named by that receipt. Once both receipts exist, the host publishes the verified current v6 plan over the pinned companion link; player2 independently verifies it and re-archives its local save as receipt-bound. V6 binds both load-bearing files, the source agent/town-development profile, two consecutive paused native route-phase samples, and each active vehicle's canonical line plus last authorized station round. The loader freezes each save at its first native-world boundary before slower diagnostics can advance its trains. Live session `phase-anchor-v6-earlyfreeze-20260811` synchronized an active train through round 1, created paired boundary-15 archives and plan `7da2035d`, reloaded the peer-specific saves, converged the mandatory fresh checkpoint, seeded the saved cursor, and released round 2 at stop 1 with zero faults. Real Host/Join discovery remains role-local so neither PC needs the other PC's save; the signed plan and mandatory remote handshake bind the pair. Positive-freight/growth restore stress, multi-train restore throughput, two-physical-computer automatic-recovery UX, and geometry repair remain open. See [the active-train restore evidence](investigation/LIVE_ACTIVE_TRAIN_RESTORE_PHASE_2026-08-11.md).
- A distributable ZIP with a standalone companion executable, auto-detecting rollback-safe installer, stable installed launcher/update/verify/uninstall commands, optional first-install desktop shortcut, launch-time update checks and verified post-update restart, private-or-public GitHub Release updater, verifier, recoverable uninstaller, match-manifest tool, and host/client/native launchers. Updates require a versioned clean release ZIP and SHA-256 evidence; no deploy key or shared repository credential is shipped.
- A one-button coordinated restore boundary: pause/quiescence preparation,
  distinct peer save receipts, legacy v2/v3 inspection and current v6 restore-plan verification, peer-local
  reload, `recovery.resume` admission, and a mandatory fresh checkpoint all
  pass on two exact processes before train service resumes. The formerly manual
  stock Save-dialog step is now an explicit-prepare/READY-gated, exact-process stock-UI fallback
  when the pinned build's public command factory is absent. Derived resume sessions stay within the launcher's
  64-character identity limit even for the longest legal source match id. The
  slow automatic save step is fixture- and historical-live-proven; fresh
  compacted capture/reload and an active train's next station round now pass.
- Optional host-authored physical town development. Points and placement
  cursors are digest-projected/replayed, every ordered batch is strict and
  atomic, and three eight-call rounds converge at every intermediate
  structural checkpoint on two exact processes.
- Save-owned canonical model towns. Line registration observes a crowd-policy-
  independent building-count baseline; completed passenger service grows the
  two endpoint populations with exact residual carry, and every linked market
  refreshes from those authored sizes. This controls future demand even while
  native physical town development remains off, so a long 1850-2030 game does
  not depend on independently simulated native populations for its economy.
- Automatic service registration distinguishes a transient bridge outage from
  a permanently unsupported route shape. Same-town passenger routes register
  as local markets; an unresolved town/industry route or stale line is quarantined with a visible bounded reason
  instead of retrying forever and preventing restore readiness. A later line
  edit/assignment retries from fresh facts and clears the current quarantine
  on success. Exact stop/platform cargo flags and every assigned consist's
  repository cargo-entry types
  prevent freight capacity from being counted as passenger seats. Every
  runnable saved line is revalidated; an old unsupported service is disabled
  through an ordered portable update on both peers, so stale passenger revenue
  and queues cannot survive. A cargo line becomes authoritative only when an
  exact source/destination contract and named consist capacity can be derived.
- Match-bound native crowd policies. Skeleton is the default and now caps every
  otherwise populated town building at exactly one native capacity slot while
  retaining a small moving decorative crowd; minimum-safe uses the same safe
  floor with destination recomputation disabled. Native agents never determine
  authored demand, queues, loads, revenue, growth, or score. Full vanilla
  population remains an explicit option, while literal zero capacity is an
  exact Build 35924 fatal and is not shipped.

## Vehicle and service economics

A faster consist does not receive an arbitrary automatic fare bonus. Its
limiting top speed lowers modeled journey time; its shorter round trip lowers
headway and can add fleet-wide departures and capacity. That reduces generalized
cost, attracting passengers from a rival and from the permanent outside/not-
travel option. The selected-line HUD also shows the fare where the current
service would reach outside-option parity, exposing potential pricing headroom.

That means an exclusive route still has an upgrade incentive when speed induces
travel, relieves crowding/capacity, adds a departure, or supports a higher manual
fare. If it already captures nearly all demand with spare capacity and the speed
step adds no departure, a costly faster train may correctly be a bad investment.
Purchase price remains the exact native debit and annual upkeep remains the
vehicle/mod's resolved native amount; the default `$50m` opening budget makes
modern rolling stock practical without removing that capital tradeoff.

Era progression is automatic rather than a hidden calendar multiplier. Early
stock supplies fewer seats and departures to smaller model towns; later speed,
capacity and service frequency can monetize the larger markets created by
delivered service. Old stock is allowed to remain useful when its real
price/capacity/upkeep is still competitive. `tools/audit_economy_era_balance.py`
runs the exact v7 evaluator over a replaceable 1850-2030 consist matrix and all
four difficulties, so vanilla and mod vehicle facts can be audited without
adding vehicle-name special cases or silently changing saved rules.

Accounting runs every five synchronized simulation minutes. Passenger money is
earned only when a synchronized train completes a leg, at the fare stored when
that cohort boarded, and is paid at the next tick. Hourly demand and capacity
are preserved through exact residual carry. The default 3 km fare is `$9.50`;
a healthy 40-seat bidirectional corridor at 320 completed passengers/hour
grosses about `$3.04m/hour`. With `$1.2m` native annual upkeep compressed to
`$0.4m/hour`, its tested net is about `$2.64m/hour`, putting a `$10m` consist in
the intended roughly 45-90 minute real-time payback range at maximum speed.
Victory-value presets are correspondingly `$250m`, `$500m`, and `$1b`; legacy
nonzero targets migrate by the same 1,000-person cohort factor.

## Install from the development tree

Run PowerShell from this directory:

```powershell
.\tools\run_tests.ps1
.\tools\install.ps1
```

`install.ps1` discovers the most recently used Transport Fever 2 Steam userdata profile, stages the copy, archives the previous mod under `runtime\install-backups`, and prepares the two bridge roots under `%TEMP%\tpf2mp_bridge`. Pass `-LocalModsPath` only when auto-detection selects the wrong Steam profile.

## Build and test a distributable

```powershell
.\tools\package_release.ps1
```

This runs the full suite, rebuilds the native DLL/injector, creates a one-file `tpf2mp.exe`, writes strict schema/version/size/SHA-256 metadata for every packaged file, binds the manifest to the exact Git commit, creates `dist\TPF2MP-0.42.1-alpha.zip`, and performs a temporary install/verify/uninstall round trip. Packaging refuses a dirty source tree by default; `-AllowDirtySource` exists only for explicitly marked development builds.

An extracted package installs with:

```powershell
powershell -ExecutionPolicy Bypass -File .\tools\install_release.ps1
```

Windows users can instead double-click `INSTALL_TPF2MP.cmd`; matching update,
verify, and recoverable-uninstall launchers are included beside it. A normal
install also creates `%LOCALAPPDATA%\TPF2MP\LAUNCH_TPF2MP.cmd`, an adjacent
`UPDATE_TPF2MP.cmd`, and offers a desktop shortcut on first install. The
launcher checks for releases in the background and restarts itself after a
verified launcher-driven update. See
[DISTRIBUTION_AND_UPDATES.md](DISTRIBUTION_AND_UPDATES.md).

After installation, double-click `LAUNCH_TPF2MP.cmd` for Host / Join / automated two-instance localhost testing. Host and Join fingerprint the selected save, game, mod, companion, and native binaries, then start Transport Fever 2 at its title screen. Click the new **MULTIPLAYER** entry in the game; only that receipted selection allows the launcher to load the pinned save. To resume an automatically coordinated boundary, click **LOAD LATEST RESTORE**; the launcher discovers only a complete receipt-bound archive for this role, locks the resume session, and fills the peer-specific save (Host uses player1, Join uses player2). **SELECT RESTORE PLAN...** remains as the manual fallback. Both paths re-hash the selected `.sav` and adjacent `.sav.lua` before launch. Tick **After the automated proof, leave both connected game windows open** before Localhost Test to turn the passing harness into a manual two-window lab. **Run Populated Capture Lab (Local Only)** instead opens two unrestricted independent worlds for observation and is not synchronized multiplayer. Ending either lab bundles evidence and restores temporary resources.

The release installer:

- verifies every bundle checksum before copying;
- commits the support bundle, game mod, and `current.json` pointer as one
  transaction, restoring the prior install if post-copy verification fails;
- auto-discovers Steam userdata and library folders;
- installs the support bundle under `%LOCALAPPDATA%\TPF2MP\versions`;
- archives any previous mod instead of deleting it;
- verifies the installed mod and standalone companion;
- reports whether the exact native profile is compatible.

Use `.\tools\verify_install.ps1` to recheck it and `.\tools\uninstall.ps1` to move the active mod to a recoverable archive.

## Local hot-seat flow

Create a fresh free game with **TPF2MP Competitive Prototype**, `player1`, and **Standalone / hot-seat**. Keep **Native turn proxy** and **Pause simulation on company switch** selected.

1. Click **Initialise Match**. The original native player becomes the UI turn desk; Company 1 and Company 2 are separate native players with separate wallets.
2. Build only for the active company. The desk’s balance is a mirror of that company’s real balance, so ordinary affordability checks use the right budget.
3. Click **Reconcile Turn** after consequential building or management work. It returns supported assets, verifies custody, transfers only the signed desk balance delta, and reopens the same company.
4. Click **Cycle Company** to settle the outgoing company and lease in the other company’s assets.
5. Public/untracked roads remain connectable by both companies. Private tracked track and other assets are protected from rival edits. Explicit access/leasing rules can be added later without changing the ownership model.
6. Register a line and use the fare controls; accounting now occurs automatically every five synchronized simulation minutes. Demo seeding and manual settlement are developer-only controls (`TPF2MP_DEVELOPER_ECONOMY=1`).
7. Use **Run Sync Probe**, **Sample Pax / Cargo**, **Export Research**, **Export Snapshot**, and **Export Checkpoint** for evidence.
8. **Finish Match** selects the deterministic leader. Epoch and valuation rules can also finish automatically.

Native borrow/repay is intentionally disabled on the standalone turn desk. Network mode has deterministic authored credit, interest, insolvency, and bankruptcy; native loan and operating journal entries are presentation-only and are reconciled out of canonical accounts. Paused turns remain the safest standalone proxy configuration because the local desk is a different accounting mode.

Road and track ownership has a special implementation because Build 35924 asserts if legacy `game.interface.setPlayer` is called on a base edge. TPF2MP therefore:

- records logical company custody;
- normally leaves local native custody on the desk, while accepting an attached depot/station edge only when the engine cascades it to that exact logical company;
- rejects rival builder sources before commit;
- uses the supported `SegmentAndEntity.playerOwned` proposal field for canonical private builds;
- handles the resulting local edge-ID replacement before binding canonical output slots.

The user’s manual runs already proved separate road/track debits, repeated company cycles, six tracked edges, the original cross-company electrification ownership theft, and rival depot access denial. The reported rail-depot turn lock exposed a second issue: returning its construction cascaded its attached edge to the rightful company, which the old desk-only postcondition rejected. The corrected invariant now has automated depot/station coverage and a real four-cycle live proof.

## Automated live validation

The full disposable-world validator is:

```powershell
.\tools\run_unattended_live_validation.ps1 -NativeHook -SkipNativeBuild -RunFacilityCustodyProbe
```

It runs the offline suite, installs the current mod, verifies a match manifest, backs up and restores `settings.lua` byte-for-byte, injects a temporary test-only game-script route, launches a fresh unsaved world, injects the exact-build native hook, runs the validator, collects evidence, renders the research report, verifies the checkpoint/event chain independently, removes temporary resources, and closes only the disposable game process.

Latest enhanced exact-build proof: `runtime/live-validation/20260804-032456` passed all `39` game checks, native hook/profile validation, independent model replay, and the complete facility sequence on the compact-state fix. It built a real rail depot and modular station, passed four complete company-custody transitions for all 18 owned components, replaced all 12 station tracks with catenary tracks, built/removed an `ASSET_GROUP`-only stock asset, removed the depot and its track, and removed the station plus all edited tracks. The native empty station-group shell was accepted only after proving it referenced no live station. Signal add/remove separately passed in `runtime/supported-api-probe/20260804-021739`. See [the signal/facility live proof](investigation/SIGNAL_FACILITY_LIVE_PROOF_2026-08-04.md) and [the original custody investigation](investigation/DEPOT_STATION_EDGE_CUSTODY_2026-08-02.md).

The historical state-20/schema-7 build passed a real two-process gate in `runtime/localhost-live/schema7-compact-20260804-032006`: host- and client-origin physical proposals converged, checkpoint barriers 6 and 10 agreed, and both worlds finished at core `73af1552` and structure `53bb77bb`. That run caught and fixed a release-candidate regression first: richer scenery fingerprints had eagerly persisted hundreds of autonomous map objects and made Build 35924 crash at the next native proposal boundary. Scenery now remains in the shared manifest digest but binds operationally only when selected. Both failing receipts and the passing rerun are documented in [the compact-manifest regression](investigation/SCHEMA7_COMPACT_MANIFEST_LIVE_REGRESSION_2026-08-04.md).

The current strongest prompt-barrier proof is `runtime/localhost-live/train-prompt-barrier-state22-20260806-105918`. Two exact Build 35924 processes loaded the same populated save and ran its real NOHAB + two-BC4 train through four prompt station rounds: zero scheduled and four unscheduled releases, zero pending rounds, zero faults, 1.86-second average and 2.38-second maximum wall-clock latency. Both worlds finished at core `fba1630d`, model `98f01295`, structure `15189409`, and mobility `8e5d90e6`; the audit reports 15/15 commit convergences, 2/0/0 physical proposals, and 3/0/0 checkpoint barriers. The old scheduled-service receipts remain readable historical evidence, but a 2026-08-07 registered-line run proved that enforcing its 778-second model headway as a native timetable could add a 364.2-game-second hold and trigger the safety timeout. New registered and ordinary lines therefore share the prompt policy. See [the prompt-release investigation](investigation/PROMPT_STATION_RELEASE_POLICY_2026-08-07.md).

The same harness can leave both ordinary game windows connected for manual vanilla-UI tests. Stock rail-station placement has live coverage from 80-320 m and 1-8 tracks. The completed facility matrix additionally covers named signals/waypoints, a rail depot, station module editing/removal, bench placement/removal, and lamp/fence placement through all-peer physical/checkpoint consensus. Removal-only connected road/track bulldozer proposals are implemented and fully automated, with their fresh ordinary-UI proof still pending. See [the ordinary-UI acceptance](investigation/ORDINARY_UI_FACILITY_MATRIX_2026-08-04.md), [the connected-segment removal investigation](investigation/CONNECTED_SEGMENT_REMOVAL_2026-08-09.md), [the schema 5/7 implementation investigation](investigation/EDGE_OBJECT_AND_CONSTRUCTION_SCHEMA6_2026-08-04.md), [the live engine receipt](investigation/SIGNAL_FACILITY_LIVE_PROOF_2026-08-04.md), and [the station investigation](investigation/NETWORK_STATION_SCHEMA4_2026-08-03.md).

The first full facility-UI attempt, `facility-ui-20260804-083528`, did not pass. Signals and waypoints exposed a processed sentinel parameter; one station edit produced four suppressed native visitors; a depot payload containing negative zero caused a permanent cross-language checksum retry; and vanilla speed clicks were suppressed without becoming shared-clock requests. Reruns then found helper-owned station-upgrade fields and a station-specific graph requirement incorrectly applied to decorative assets. Prototype 0.21 fixes all six with targeted regressions. The passing staged reruns and exact evidence boundaries are in [the ordinary-UI facility-matrix acceptance](investigation/ORDINARY_UI_FACILITY_MATRIX_2026-08-04.md); the original four failures remain in [the failure investigation](investigation/FACILITY_UI_FAILURES_2026-08-04.md).

The manual-lab lifecycle itself is live-proven in `runtime/localhost-live/localhost-manual-lab-smoke2-20260802`: both windows reached `MANUAL LAB READY`, a two-peer stop was requested, automatic evidence collection found both native statuses and the game log, the host audit replayed successfully, and settings plus all temporary base-resource injections were restored.

The explicitly local-only operational lab has now completed a populated human
run. Two independent worlds sustained multiple passenger/cargo train cycles;
screenshots show `8/30` passengers and `8/48` cargo. Both worlds retained frozen
town/industry state, player commands used queued native tags, and Player 2
reconciled its exact `-5,879,852` native delta while retaining 80 assets. All
five convenience readers remained unavailable despite the visible loads. A
later populated network run found a direct ECS path and read 413 people, 10 line
users, 8 aboard, and 2 waiting identically on both peers. Direct cargo paths are
also available, but still need a cargo-positive source save and an authoritative
steering design. See [the operational capture investigation](investigation/OPERATIONAL_CAPTURE_LAB_2026-08-02.md) and [the superseding populated proof](investigation/POPULATED_NETWORK_RECOVERY_AND_MENU_2026-08-03.md).

To repeat the lab or live-prove the new stale-edge recovery and rival-access
checks:

```powershell
.\tools\start_operational_capture_lab.ps1 -Minutes 120
```

It opens two independent, unrestricted hot-seat worlds, auto-initializes two
50,000,000-funded companies in each, and samples real speed/time, balances/journals,
autonomy readback, intermediate model/core/structure/mobility digests, native
command tags, bounded line/vehicle/station GUI mutation envelopes, and
passenger/cargo APIs. It does **not** connect or synchronize the two worlds.
Closing either window triggers evidence collection and a
JSON/Markdown analysis. See [the operational capture design and test
contract](investigation/OPERATIONAL_CAPTURE_LAB_2026-08-02.md).

Smaller experiments remain available:

```powershell
.\tools\run_supported_api_build_probe.ps1 -NativeHook -SkipNativeBuild -TrackBuildTest
.\tools\run_supported_api_build_probe.ps1 -NativeHook -SkipNativeBuild -BuildGateTest
.\tools\run_supported_api_build_probe.ps1 -NativeHook -SkipNativeBuild -CommandGateTest
.\tools\run_supported_api_build_probe.ps1 -NativeHook -SkipNativeBuild -ProposalOwnershipTest
.\tools\run_supported_api_build_probe.ps1 -NativeHook -SkipNativeBuild -VehicleLifecycleTest
.\tools\run_unattended_live_validation.ps1 -RunFacilityCustodyProbe -NativeHook -SkipNativeBuild -SkipTests
.\tools\start_native_hook_test.ps1 -NoBuild
.\tools\get_native_hook_status.ps1
```

The native component is deliberately fail-closed. It loads only this executable:

```text
Transport Fever 2 Build 35924 (Windows x64)
SHA-256 782b904a8f7bbdac1f7a18528f1a5c778691e5aa3087c37c351bf6912585175c
```

An updated, altered, or unsupported executable is rejected before hooks are enabled. Standalone Lua mode can still be installed, but network construction experiments must stop until a new profile is researched and tested.

## Two-machine network experiment

Both machines need the same game executable, installed mod/binaries, mod order,
and session name. The launcher can deliver the Host's byte-identical starting
save over the trusted LAN/VPN. Double-click `LAUNCH_TPF2MP.cmd` on each machine:

1. Host selects the save, enters a fresh session name, and clicks **Host + Launch Game**.
2. Host sends player 2 the exact session name, LAN/VPN address shown by the
   launcher, and gameplay port. Both that port and the adjacent port must be
   reachable.
3. Player 2 enters those values, clicks **SYNC FROM HOST**, waits for the
   verified save path to fill automatically, and clicks **Join + Launch Game**.
4. Each launcher independently fingerprints the game, mod, companion, native binaries, and save. A mismatch is rejected before gameplay traffic.
5. In Transport Fever 2, click the new **MULTIPLAYER** title entry. The game remains idle until this click; afterward the launcher loads its byte-pinned copy of the selected save and the short-lived profile supplies the correct peer, session, bridge, and Network mode.

The equivalent scriptable entry points are:

```powershell
.\tools\start_network_session.ps1 -Role Host -Session match-1 -StartingSave 'C:\saves\match.sav'
.\tools\sync_starting_save.ps1 -Session match-1 -HostAddress 192.168.1.10
.\tools\start_network_session.ps1 -Role Join -Session match-1 -HostAddress 192.168.1.10 -StartingSave 'C:\saves\match.sav'
```

The older manifest/companion/hook scripts remain available for debugging, but ordinary testing no longer requires coordinating three terminals and mod-option dropdowns.

After any manual test, click **Collect evidence** in the launcher. It copies the local bridge traffic, research/checkpoint exports, relevant game log, native-hook status, session state, and then independently replays the host audit. The scriptable equivalent is:

```powershell
.\tools\collect_live_evidence.ps1 -Session match-1
```

The focused cargo-positive localhost gate is:

```powershell
.\tools\start_freight_live_acceptance.ps1 -RequireObservedAboard
```

It starts a clean manually playable two-process network world with 50M per
company, verifies match-start consensus, leaves both synchronized windows open
for a real freight line, collects the evidence on close, and requires the final
audit to prove loaded-industry bootstrap plus a converged checkpoint with
non-zero delivered cargo and settled authoritative revenue. With
`-RequireObservedAboard`, the first authoritative non-zero cargo load creates a
one-time host-ordered `freight-milestone:aboard` checkpoint automatically; no
manual timing or **Export Checkpoint** click is required. Its bounded authored
round/load witness remains valid if the vehicle unloads before the checkpoint.
An already collected
host audit can be checked independently with:

```powershell
.\tools\analyze_freight_live_evidence.ps1 -Session match-1 `
  -RequireStage settled -RequireObservedAboard
```

The focused local passenger-feeder gate is:

```powershell
.\tools\start_feeder_live_acceptance.ps1 -Carrier ROAD
```

It starts a clean two-process world with enough disposable setup capital for an
intercity passenger corridor and a same-company local bus/tram line. After the
automatic five-minute settlement, closing either game checks the complete audit
and requires exact peer convergence, a two-stop operational local service, an
operational corridor sharing an exact endpoint station group, a positive
modeled feeder link, completed local travel, and settled authoritative revenue.
The first non-zero authored load on a valid local ROAD/TRAM feeder automatically
opens a one-time `passenger-milestone:aboard` checkpoint; the wrapper requires
that receipt, so there is no timed **Export Checkpoint** click. The proof is
bound to monotonic vehicle/line boarding cursors and survives alighting. Rail corridors,
rival services, duplicate-stop routes, and malformed local bindings cannot
consume the milestone. Use `-Carrier TRAM` for a tram-specific receipt. Existing
evidence can be checked with:

```powershell
.\tools\analyze_feeder_live_evidence.ps1 -Session match-1 `
  -RequireStage settled -Carrier ROAD -RequireObservedAboard
```

The transport is designed for trusted private peers. Its checksums detect corruption and inconsistency; they are not hostile-client authentication or encryption. Do not expose TCP port `29742` directly to the Internet.

Current network boundary:

- Model-owned actions are ordered and replayed.
- `proposal.prepare` is company-authorized against the pinned peer-to-company map and carries no engine-local IDs. Every peer must resolve canonical inputs and stable resource names before the host is permitted to emit `proposal.build`.
- The native BuildProposal gate and all 31 selected consequential/autonomy-command visitors are mandatory in network mode. Missing/inactive authority gates prevent both outgoing intents and incoming gameplay commits.
- Every peer can reconstruct the supported road/track transaction and bind its own result IDs to the same canonical output identities.
- Queue acknowledgements remain diagnostic only. A physical proposal is complete only after both pinned peers report matching canonical outputs and physical/core digest. Schemas 5 and 7 carry the bounded integer builder quote; the ordered outcome applies its signed cost to the canonical account and reconciles each peer's native wallet cache before the financial checkpoint.
- Match initialization, every successful physical outcome, each five-minute economy settlement, and the first authoritative non-zero passenger or cargo load immediately open a checkpoint barrier. Later network intents remain blocked until both peers report the same format-5 convergence key, including canonical company finances, authorized train station rounds, exact model passenger/cargo queues and loads, and freight stock/transport state, and consume the ordered checkpoint outcome. Settlement therefore gains one convergence round per five model minutes; each load domain adds one proof boundary per match, not one round at every station visit. The in-game multiplayer panel and exported research snapshot show whether those automatic receipts are waiting, proved, or retrying a stale observation.
- A prepare rejection is non-fatal because no native world has changed. A post-commit native rejection is also recoverable only when every peer fails, emits no outputs or finance delta, agrees on result/core/error, and retains the exact prepare-barrier core; it receives its own checkpoint before play continues. Construction-step progress renews the ordinary proposal deadline up to an absolute hard cap. If that deadline still expires, late identical empty failures can be requalified in place with **Recover / Resync Session**: the host derives an ordered proof and clears only that exact timeout after a fresh all-peer core, structure, and world-manifest checkpoint. Mixed results, residue, changed state, and every other fault remain restore-only; in-place native geometry repair is not implemented. A peer-specific native save is requested only while the explicitly prepared shared pause/quiescence/checkpoint boundary remains READY and the current core matches it. Build 35924 has no public `api.cmd.make.saveGame`, so the watcher serializes exact-process stock-UI saves only for that prepared boundary, then hashes stable output and files the receipt. The two-peer receipt/verified-plan/archive handoff is live-proven at boundary 11; a fresh paired localhost capture, strict role-specific relaunch, and mandatory post-migration checkpoint now pass as one automated cycle as well. Ordinary Host/Join relaunch remains user-initiated, while the localhost recovery gate can perform the whole relaunch automatically. Interactive evidence collection uses strict audit replay, so a dead companion, pending lane, or commit awaiting a peer digest cannot be reported as a passing run.
- Populated bidirectional construction, shared-clock rendezvous, four real-train station rounds, and intermediate/final mobility convergence pass on localhost; a two-computer usability/latency/disconnect run is the next manual gate.
- The ordinary vanilla line manager now has typed capture for New Line, complete UpdateLine stop/terminal state, Delete Line, rename, and color. Two independent two-process sessions live-prove the actual stock widgets: create/rename/color/delete and a populated line's Add Station/remove-stop actions all reached ordered physical consensus and peer checkpoints, with matching stock Line Manager displays and zero native decode errors. Reordering two populated stops and alternate-terminal changes still need a focused visual pass. Railway BuyVehicle/SetLine have pre-mutation typed capture. The stock UI has now bought a train, replicated it into the peer depot, assigned it to the line, and shown the canonical train moving in both worlds; the latest observation exposed the expected mid-leg phase lead after a one-sided Escape pause. Stock modular rail-station placement and its 80-320 m/1-8-track matrix are human-live-proven. The shared portable-construction path now has a 216-case Lua/Python matrix for every vanilla large bus/tram/truck terminal template, platform count, length, tram mode, and collateral demolition; busy clicks use one bounded latest-only lane. Curbside category-0/1 stops additionally bind their native derived station/group identities so later bus/tram Line Manager updates stay canonical. Signals/waypoints, a rail depot, station editing/removal, bench placement/removal, and lamp/fence placement also pass ordinary two-process UI capture, ownership, physical consensus, and checkpoints. The new road-terminal and bus/tram-line corrections still require a fresh human two-peer pass. Unadapted command families remain safely rejected where gated; complex topology, executable mod callbacks, and unlisted/autonomous paths remain explicit authority gaps.
- Shared-clock rendezvous v2 and the per-station train barrier pass protocol, checkpoint, restart, timeout, adversarial, and populated two-process tests. Human speed-3 play with a deliberately delayed peer recovered at the next station; the leading train waited and both departed together. Four prompt ordinary-line releases also completed with zero skew/faults. A game that enters an Esc/modal loop may stop bridge frames before acknowledging the ordered pause; while its TCP companion remains connected and its pre-pause sample is recent, the host exposes `connected-quiescent-modal`, freezes active station deadlines, and leaves strict `pauseAcknowledged` false. Disconnects, negative acknowledgements, and uncorroborated stale peers retain normal fail-closed behavior. Exact-coordinate repair remains deliberately absent; different stop indices fault closed. Multi-train throughput, disconnect/reconnect, and two-computer latency remain live gates. Model passenger and cargo queues, train loads, and completed deliveries are exact in the standard vehicle, line, station, manager, statistics, and top-bar UI. Native people/cargo agents and history remain cosmetic; the cargo-positive projection still needs live two-process proof.

Accordingly, network mode remains an engineering experiment rather than a promise of playable multiplayer.

After a fault, first check **Session recovery** in the Multiplayer panel. If it
says **READY**, press **Recover / Resync Session** and wait for **RECOVERED**.
This applies only to proven non-mutating proposal timeouts. If it says
**RESTORE REQUIRED**, stop both games and companions, then run this from the
extracted host bundle:

```powershell
.\tools\new_recovery_plan.ps1 -AuditPath "$env:TEMP\tpf2mp_bridge\player1\audit\match-1.ndjson" -Session match-1
```

The plan names the exact convergence boundary and new session ID. Both roles create a receipt-bound `latest-recovery-archive.json`: player1 after host plan generation and player2 after verified network delivery. **LOAD LATEST RESTORE** admits this machine's verified role-specific archive; the signed plan already binds both receipts, and the other peer must independently load and attest its own bytes before the fresh checkpoint can converge. `run_latest_local_restore_acceptance.ps1` adds the stricter same-machine pair requirement for automated localhost testing. `run_fresh_local_restore_cycle.ps1` now proves the complete unattended localhost chain: restore the newest pair, prepare and save a fresh pair, close, rediscover those exact archives, reload, and require the post-load checkpoint. Restore remains restart authority, never an unsafe geometry importer.

## Repository map

- [ARCHITECTURE.md](ARCHITECTURE.md) - runtime layers, module ownership,
  authority invariants, and the supported path for adding command families.

- `tpf2_mp_1/` — installable prototype 0.41; state schema 34, economy model 10, checkpoint format 5, passenger-presentation schema 4, cargo-presentation schema 2, delivery schema 3, edge schema 5, construction schema 7, and freight-industry schema 3.
- `companion/tpf2mp/` — dependency-free protocol, bridge, host/client sequencer, manifests, replay, and reports.
- `native/` — pinned Build 35924 DLL/injector, signatures, MinHook pin, tests, and documentation.
- `tests/` — Lua unit/integration/replay tests and Python protocol/TCP tests.
- `tools/` — developer tests, live probes, release packaging, installer, verifier, launchers, and evidence tools.
- `investigation/` — supported-API and native reverse-engineering evidence.
- [PROTOTYPE_STATUS.md](PROTOTYPE_STATUS.md) — exact implemented/proven/untested boundary.
- [REMAINING_FROM_BRIEF.md](REMAINING_FROM_BRIEF.md) — ordered critical path to the original brief.
- [tpf2-competitive-multiplayer-concept.md](tpf2-competitive-multiplayer-concept.md) — product concept.
- [tpf2-competitive-multiplayer-technical-plan.md](tpf2-competitive-multiplayer-technical-plan.md) — phased architecture and go/no-go criteria.
