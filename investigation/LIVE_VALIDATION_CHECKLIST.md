# TPF2MP live validation checklist

Use only fresh disposable worlds. Never continue after a custody, proposal-finalisation, or finance error unless the step explicitly tests recovery. Export evidence once, then close without saving.

Prototype under test: `0.34.0-alpha`, state schema `29`, economy model `8`, checkpoint format `5`, edge proposal schema `5`, construction proposal schema `7`, native hook `0.14.0`, exact game Build 35924.

## 0. Automated baseline

Close Transport Fever 2 and run:

```powershell
.\tools\run_unattended_live_validation.ps1 -NativeHook -SkipNativeBuild
```

Pass requires:

- all offline tests pass;
- exact executable and all 17 signatures validate;
- all 23 selected consequential-command visitors match the pinned dispatch table and hook successfully;
- 39 in-game checks pass;
- canonical track proposal binds three outputs;
- post-proposal reconcile passes;
- native unknown/mismatch/invalid/overwrite counters are zero and any shutdown-tail pending entries are accounted for;
- settings are restored and temporary resources removed;
- checkpoint report verifies the complete core chain and model replay.

Current reference: `runtime/live-validation/20260802-075533`, core `f859604c`, model `95dd1197`, finances `fde11e45`, 14 verified post-anchor events. Post-hardening focused authority reference: `runtime/supported-api-probe/20260802-075034`, with one rejected and one one-shot-authorized tag-0 command, 23 hooks, and zero mismatches.

For the compound depot/station custody regression, close the game and run:

```powershell
.\tools\run_unattended_live_validation.ps1 -RunFacilityCustodyProbe -NativeHook -SkipNativeBuild -SkipTests
```

Reference `runtime/live-validation/20260802-125058` created a rail depot plus attached edge and a modular passenger station with 12 track edges, station, and station group. All 18 player-owned components completed four company cycles, ending `stage=complete`, `success=true`, with 20 independently verified events.

Before a network test, inspect each process's native status and require both `gates.buildProposal.enabled=true` and `gates.commandVisitors.enabled=true`, with `hooks.authorityCommandVisitors.hooked=23`. A missing or inactive gate must leave `networkAuthority=false` and prevent match traffic.

## A. Fresh local match

1. Enable only the prototype and known-compatible map/content mods.
2. Select `player1`, `Standalone / hot-seat`, native turn proxy, pause-on-switch, 5M starting cash.
3. Initialise.
4. Confirm Company 1 and Company 2 show 5M, zero company loans, and distinct native players.
5. Confirm the turn desk mirrors Company 1 and the UI shows no turn failure.
6. Export Research and Checkpoint.

Pass: two companies, two wallets, one active turn, baseline checkpoint, no repair needed.

## B. Rival track veto — highest-value short manual test

Status: passed manually on 2026-08-02; retain these steps for regression testing.

1. Cycle to Company 2.
2. Build a short private normal track and reconcile once.
3. Record Company 2 balance, asset count, pinned count, native proposal/apply counters, replacement counters, and blocked counters.
4. Cycle to Company 1.
5. Attempt to electrify, upgrade, or delete Company 2’s exact track.
6. Require a visible `TPF2MP: entity ... belongs to Company 2` error before the build applies.
7. Refresh and confirm:
   - entity/proposal blocked counter increased;
   - `builder.apply` did not increase for the attempt;
   - replacement counters did not increase;
   - track local IDs remain unchanged;
   - Company 1 gained no asset;
   - Company 2 retained the track;
   - neither balance changed.
8. Reconcile Company 1 once; balances and custody must remain unchanged.
9. Cycle back to Company 2 and electrify its own track.
10. Reconcile once. Company 2 should pay and retain the same logical asset count even if native edge IDs change.
11. Export Research, Snapshot, and Checkpoint.

Fail immediately on any rival apply, debit, ID replacement, asset theft, ownership ambiguity, or blanket rejection of Company 2’s own edit.

## C. Public road policy

1. Company 1 builds a road with ownership `Keep`; reconcile.
2. Company 2 connects a road to it; reconcile.
3. Repeat with explicit player ownership on a separate road.
4. Attempt a rival upgrade/delete on the explicitly owned road.

Pass: public road topology remains shared; explicitly private tracked road edits are rejected for the rival and allowed for the owner. Record this as a gameplay rule, not an engine accident.

## C2. Connected segment demolition and recovery

Status: implemented and fully automated; fresh ordinary-UI proof pending.

1. On Player 1, build a private track mainline and a short connected spur.
2. After its checkpoint completes, bulldoze only the final spur segment.
3. Confirm it disappears on both peers, Player 1 remains authoritative, and
   Player 2 cannot remove another Player 1 segment.
4. Immediately rebuild the spur and require normal all-peer proposal/checkpoint
   completion.
5. Repeat with a public road segment connected to a stock town road.
6. Confirm the new codec diagnostic reports non-zero `edgesToRemove` (and any
   exact `nodesToRemove`) rather than `proposal has no supported street/track
   edges or construction change`.
7. Export Research after the track and road cases.

Pass: removal and rebuild appear on both peers, only the issuer's authored
wallet changes by the quoted native amount, custody is retired only after the
native component disappears, the next build is accepted, and no proposal or
checkpoint remains pending. If the native deletion creates implicit replacement
topology not present in the captured transaction, stop and preserve evidence;
that broader join shape intentionally still fails closed.

## D. Local asset matrix

Current proven slice: rail-depot construction/custody and a stock modular passenger-station construction/custody cycle. Modular editing, deletion, save/reload, maintenance, and the remaining types below are still open.

Test one category at a time, reconciling and exporting after each:

- rail station and modular upgrade;
- bus/truck stop;
- road and rail depot;
- harbour and airport when practical;
- line creation, rename, stop-order edit, deletion;
- road passenger/cargo vehicle;
- train;
- tram;
- ship;
- aircraft;
- vehicle line assignment, start/stop, reverse, depot, replacement, sale;
- signals, waypoints, one-way markers, bridge, tunnel, headquarters.

For each category require:

- active company can manage it;
- inactive company receives a veto or cannot act;
- cycle away/back preserves function and identity;
- no entity is stranded under the desk unexpectedly;
- all money lands on the intended company;
- save/reload/reconcile recovers the active turn.

An unsupported category must be documented and disabled or pinned; do not mask it with post-hoc asset claiming.

## E. Running finance

1. Give both companies one working line and vehicle.
2. Record company balances, desk balance, desk loan, and game date.
3. Run Company 1’s turn across a month boundary without building.
4. Reconcile once.
5. Repeat for Company 2.
6. Observe revenue, maintenance, and desk-loan interest separately.

Pass: operational deltas can be attributed without charging an inactive company or treating desk-loan interest as gameplay spending. Until this passes, keep competitive build turns paused and treat running operation as a separate accounting subsystem.

## F. Save/load and failure recovery

1. Save during Company 2’s active turn after a successful private build.
2. Reload and reconcile once.
3. Save/reload after a completed canonical proposal.
4. In a separate disposable world, force a proposal failure and export before retrying.
5. Verify pending/completed proposal records survive safely and completed records do not block later builds.

Pass: no duplicate debit, no lost canonical binding, no stranded desk asset, no digest-chain gap, and a clear fail-closed error for the deliberately failed transaction.

## G. Frozen world

1. Enable freeze and export a structural snapshot.
2. Do no player construction.
3. Run at high speed for one in-game year and at least 60 real minutes where practical.
4. Export the same normalized structural facts at intervals.
5. Repeat on two identical instances.

Pass: no unexplained town/industry/topology/ownership change. Classify every changed field; do not simply exclude a divergent subsystem without a product decision.

## H. Native presentation baseline

1. Give both companies competing services on one corridor.
2. Register lines and settle several host-model epochs with meaningfully different fares/headways.
3. Use **Sample Pax / Cargo** after each epoch.
4. Record station queues and vehicle loads visually.

Pass for observation: stable canonical aggregate reads are available and comparable. Product pass requires the native presentation to agree directionally with the score. Detection alone is not synchronization.

## H2. Local bus/tram feeder

1. In one town, build a road or tram passenger line with at least two distinct
   stops. Make one stop share the exact station group used by an existing
   intercity passenger line owned by the same company.
2. Buy and assign one bus/tram through the ordinary depot UI. Confirm purchase,
   assignment, line, vehicle, and balance synchronize before continuing.
3. Confirm the Multiplayer line view shows a `road local` or `tram local`
   service and the intercity line shows one connected feeder endpoint with a
   passenger-cost reduction between `$0.01` and `$1.50`.
4. Run through at least one intermediate local stop and both endpoints. The
   intermediate stop must not create a visible peer wait; endpoint departure
   must still wait for the slower peer when deliberately delayed.
5. Complete and settle one local leg plus one intercity leg. Compare authored
   loads, queues, revenue, market share, balances, and the settlement
   checkpoint on both peers.
6. Disable or unassign the feeder. At the next settlement its access endpoint
   and cost reduction must disappear. Re-enable it and confirm they return.
7. Replace the local vehicle with a visibly different capacity or speed class.
   Wait for the automatic registration follow-up and confirm both the line
   panel and next settlement use the replacement facts, not the old consist.
8. Export Research on both peers before shutdown. The authoritative economy
   table must name the same local line, company, ROAD/TRAM carrier, local scope,
   capacity, `factsSource`, feeder endpoints, delivery count, and net revenue.

Pass: both processes retain matching core/model/structure, the local service
earns only completed-trip revenue, its same-town growth credit is not halved or
doubled, a rival company's intercity service gets no access benefit, and no
intermediate urban stop creates an all-peer barrier round.

## I. First two-peer canonical construction

### Focused two-process freight acceptance

Run this only after closing every Transport Fever 2 process:

```powershell
.\tools\start_freight_live_acceptance.ps1 -Session freight-live-YYYYMMDD-HHMM
```

The wrapper starts a clean manual-network match with 50M per company, requires
the initial two-peer checkpoint, and then leaves both disposable windows open
without synthetic validator construction. The final audit gate—not a visual
assumption—requires identical industry content and an authored freight
bootstrap. In the host window:

1. Build and connect one cargo source, one compatible cargo sink, two cargo
   stations, a depot, a cargo line, and a suitable vehicle.
2. Let at least one unit become visibly waiting, travel aboard the vehicle, and
   arrive at the compatible sink.
3. Wait for the automatic five-minute economy settlement. Do not treat native
   floating income text as the authoritative payment.
4. If cargo aboard must be captured as evidence, start the wrapper with
   `-RequireObservedAboard`. The first authoritative non-zero load now opens a
   one-time `freight-milestone:aboard` checkpoint automatically; do not race a
   manual **Export Checkpoint** click.
5. Close either disposable game only after delivered cargo, positive authored
   cargo revenue, and the settled epoch are visible.

The wrapper then collects both bridge trees and runs:

```powershell
.\tools\analyze_freight_live_evidence.ps1 `
  -Session freight-live-YYYYMMDD-HHMM `
  -RequireStage settled
```

Pass requires a current-format, successful two-peer checkpoint with identical
freight stocks, cargo presentation, delivery cursors, and authored revenue;
zero fatal consensus faults; and no unresolved prepare, proposal, operation, or
checkpoint barrier. The report distinguishes `ready`, `service`, `waiting`,
`aboard`, `delivered`, and `settled`, so an incomplete run fails with the exact
missing stage. A successful settlement now creates this checkpoint
automatically. The first cargo-positive two-process live pass is still open;
automated tests do not satisfy this gate.

Automated localhost baseline (already passed bidirectionally as `localhost-20260802-175636`):

```powershell
.\tools\run_localhost_live_validation.ps1 -SkipNativeBuild -SoakTicks 600
```

One-PC manual lab:

Status: the lifecycle and automatic evidence/cleanup path passed live as `localhost-manual-lab-smoke2-20260802`; ordinary human builder attempts remain the next use of the lab.

1. Close every existing Transport Fever 2 process and open `LAUNCH_TPF2MP.cmd`.
2. Tick **After the automated proof, leave both connected game windows open for manual testing**.
3. Click **Run 2-Instance Localhost Test**. Wait for the log to print `MANUAL LAB READY`; the scripted bidirectional build, three checkpoints and 600-tick soak run first.
4. Treat the window assigned `player1` as Company 1 and `player2` as Company 2. Do not cycle companies in this simultaneous lab.
5. For the first construction discovery pass, attempt one isolated stock train depot and one smallest stock modular passenger station through the ordinary UI. A safe rejection is expected until the construction codec exists.
6. In each window, export Research and Snapshot after each useful attempt.
7. Click **Stop companion** or close either disposable game. The harness collects both bridge trees, hook statuses, exports and the independently replayed host audit before cleanup.

The manual lab runs against fresh disposable `app.startGame` worlds, not a valued save. It is suitable for capture, drift and authority tests; the two-computer identical-save flow below remains the product usability gate.

Populated operational capture (two independent worlds; **not multiplayer**):

```powershell
.\tools\start_operational_capture_lab.ps1 -Minutes 120
```

Wait for `OPERATIONAL CAPTURE LAB READY`. In each window build two stations, a
depot, a line and at least one vehicle; run until passenger/cargo use and a
journal/balance change are visible. Exercise both companies, then Export
Research and Export Snapshot in both windows. Close either game to collect and
analyze evidence. The report must show actual speed/time coverage, all
intermediate digest domains, autonomy readback, command/tag envelopes, direct
apply counts, finance deltas, and the populated passenger/cargo reader results.

Prerequisites: identical exact build, mod, companion, native binaries, mod order, parameters, session, and starting save; matching generated manifest fingerprints.

1. Open `LAUNCH_TPF2MP.cmd` on both computers. Host selects **Host + Launch Game**; player 2 selects **Join + Launch Game** with the same session/save and the host LAN/VPN address.
2. Require both launchers to show the same fingerprint and a connected link; they start the companion, pin peer/session/network mode, launch the game, and attach the hook.
3. Load the identical TPF2MP-enabled save/world on both computers.
4. Initialise from the host.
5. On the host, draw one isolated private straight track with no stations, signals, or crossings.
6. Require the original local proposal to be suppressed by the gate.
7. Require one canonical `proposal.build` commit with no local IDs.
8. Require both games to reconstruct and physically complete it.
9. Require both games to emit one local-ID-free `completion` with the same proposal/output/core digest and schema-3 cost. Raw native wallet deltas may differ; only the quoted transaction cost may change the canonical account before checkpointing.
10. Require the host to emit one ordered successful `network.proposal_outcome`; verify no dependent intent commits before it.
11. Require both games to automatically export format-2 checkpoints for the physical-outcome boundary.
12. Require the host to emit one ordered successful `network.checkpoint_outcome`; verify no dependent intent commits before it.
13. Repeat steps 5-12 with one isolated private track originated by player 2.
14. Export research from both, click **Collect evidence** in each launcher, and compare:
   - transaction digest;
   - canonical output IDs;
   - normalized geometry/resource/catenary/ownership;
   - canonical/core digest;
   - physical completion result;
   - checkpoint convergence key and canonical balance/loan digest;
   - both companies' canonical balances and peer-local native-cache matches.

Bidirectional physical/checkpoint consensus and a 600-tick finance/structure soak pass the automated two-real-process localhost harness. This section is now specifically the two-computer human vanilla-builder usability proof. Queue acknowledgements alone remain insufficient.

## J. Two-peer failure cases

With the implemented completion consensus, test:

- one peer missing the track resource;
- one peer unable to place at the target geometry;
- duplicate/retransmitted proposal;
- disconnect before local issue;
- disconnect after one peer applies;
- timeout during ownership correction;
- generate and verify the checksummed restart plan from the last agreed checkpoint;
- reload identical saved boundaries under the plan's derived session (manual until save capture is automated);
- dependent second build while the first is unresolved.

Current automated pass: all peers either reach the same postcondition plus checkpoint or fault closed with an identified proposal/reason, and the authority audit yields a checksummed latest-agreed restart plan. Future live recovery pass: both load the identical saved boundary and reconstruct valid local bindings under the derived session. Silent partial continuation is a failure.

## K. Expansion order

Only after I/J pass for isolated track:

1. public/private road;
2. track upgrade/removal with existing canonical input;
3. construction/station;
4. signals/edge objects;
5. splits/joins and dependent references;
6. line lifecycle;
7. vehicle lifecycle/assignment;
8. host-driven growth;
9. passenger/cargo steering.

Every new category needs codec validation, materialization, native gate, postcondition binding, rollback/recovery, automated tests, one-machine live proof, and two-peer proof.

## Evidence to preserve

For every manual or two-peer run keep:

- exact release manifest and match manifest;
- game executable hash;
- installed mod verification output;
- both bridge directories and audit logs;
- both PID-specific native status files;
- research, snapshot, and checkpoint exports;
- checkpoint/replay reports;
- game logs and screenshots of visible veto/failure;
- pre/post balances, ownership counts, canonical counts, proposal counters, and local IDs when diagnosing a single machine.

Local IDs are evidence only; they must never become cross-machine identity.
