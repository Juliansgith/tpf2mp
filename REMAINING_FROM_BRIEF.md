# What remains from the TPF2MP brief

Last updated: 2026-08-07 after prototype `0.23.0-alpha`, state schema `23`,
checkpoint format `3`, edge proposal schema `5`, construction proposal schema `7`, populated two-process convergence,
direct passenger telemetry, automatic checkpoint-linked save archiving, and the
live title-screen multiplayer entry.

## Bottom line

The local competitive game exists. The same-area network architecture also now
works through a real populated two-process vertical slice: identical source
save, canonical pre-existing ownership, host/client construction transactions,
canonical finance, physical consensus, all-peer checkpoints, mobility
comparison, and fail-closed faults. State schema 19 additionally preflights
every construction on both peers before native mutation and provides a
host-ordered adaptive simulation clock. Signal and facility engine primitives
have exact-build receipts, and the bounded ordinary-UI two-process matrix now
passes for signals/waypoints, a rail depot, modular-station edit/removal, bench
placement/removal with rival denial, and lamp/fence placement. The
release candidate also passes bidirectional proposal/checkpoint consensus after
compacting autonomous scenery into a digest-only manifest. The stock line
manager now passes human two-process create/rename/color/delete and populated
add/remove-stop proof. Stock train purchase, assignment, peer visibility, and
movement now have human two-process proof. Future-time clock rendezvous and a
canonical per-station train barrier also pass a populated exact-build run with
four alternating releases and zero faults; human slow-peer/disconnect stress,
two-stop reorder/alternate-terminal proof, the rest
of the vehicle lifecycle, complex topology, and two-computer proof remain.

State 23 additionally passes receipt-bound two-peer restore and three rounds of
ordered physical town development with identical intermediate structural
digests. Fresh-world skeleton and minimum-safe crowd policies load cleanly;
literal zero capacity is a pinned-build fatal negative. The remaining gates in
those areas are gameplay pacing/appearance, an active-round restore stress, and
the first true two-computer run—not basic mechanism discovery.

It is not yet general Transport Fever 2 multiplayer. The remaining work is no
longer “discover whether any synchronization architecture works.” It is to
broaden and human-live-prove the command vocabulary, test unpaused drift, align
native passenger/cargo presentation with the host model, and complete recovery
and product hardening.

## Brief-to-build matrix

| Brief item | Current state | Remaining work/proof |
|---|---|---|
| Two distinct companies | Implemented with two persistent native companies plus the original UI turn desk. Repeated live initialization and compound depot/station custody cycles pass. | Long-session save/reload and broader asset-type management tests. |
| Separate finances | Standalone mirrors and settles only the active company. Network mode uses canonical accounts and reconciles native wallets as local caches. Fail-atomic settlement and quoted construction costs are tested. | Authoritative operating revenue, maintenance, purchases/sales, competitive credit, insolvency, and bankruptcy. |
| Separate roads/tracks | Logical ownership, private/public distinction, rival veto, canonical replay, private endpoint custody, and defense-in-depth endpoint authorization are implemented. Resource names are resolved data-first rather than hardcoded by index. Exact-geometry lazy binding and all-peer prepare make local resolution failure non-mutating. A unanimous post-commit native rejection is now recoverable only under a strict no-output/no-finance/unchanged-core predicate and its own checkpoint. Own extension, rival rejection, upgrades, queued upgrades, and named signals/waypoints are live-proven. | Fresh public-town-road/resource-preflight proof; then crossings, splits/joins, bridges, tunnels, complex dependencies, and optional access/leasing rules. Live-prove that an invalid curve rejects and the immediately following edit still synchronizes. |
| Stations and depots | Local compound custody and rival denial are live-proven. Network schema 7 retains strict stock station placement and adds a bounded named adapter for depots, ordinary constructions, `ASSET_GROUP` assets, observable upgrades, modular station edits, and removal. Exact-build receipts plus ordinary two-process UI runs prove depot placement/use, station placement/edit/removal, bench placement/removal with rival denial, lamp/fence placement, physical consensus, and checkpoints. | Broader station/depot families, data-only mod construction variants, scripted adapters, and long-session use/removal with active lines. |
| Lines | Canonical lifecycle/update operations, strict validation, authorization, replay/result consensus, and tests exist. Hook 0.13 captures ordinary CreateLine/DeleteLine/UpdateLine/SetName/SetColor payloads, including exact ordered stop/station/terminal tuples; zero- and one-stop vanilla editor states and the bounded rapid-action queue are covered. Two stock-widget localhost sessions prove New Line, rename, color, Delete Line, Add Station, and per-stop removal across independent processes with matching physical results and checkpoints. | Two-populated-stop reorder and alternate-terminal visual proof, live rival-edit fault-path proof (origin residue now faults closed with an ordered pause), rapid-click/rejection recovery playtests, then broader schedule settings. |
| Railway vehicles | Canonical operation representation, authorization, replay/result, finance, consensus, and checkpoints exist. Hook 0.13 captures stock BuyVehicle player/depot scalars before mutation and correlates them with the GUI's exact loco+waggon consist; SetLine has typed native capture. An exact NOHAB + two BC4 purchase succeeds in a disposable Build 35924 process and through the ordinary UI on two independent processes with matching physical/checkpoint results and isolated finances. The station barrier holds each copy until both peers report the same vehicle/line/stop/round. State 23 gives registered competitive services canonical departure slots; ordinary lines use the same barrier with a short guard and no invented timetable. Scheduled and unscheduled exact-build runs converge all four digests with zero faults, the 50-train authority stress passes, and a human speed-3 run recovered after substantially delaying Player 2. | Live multi-train throughput/signaling, a line registered to a real market, two-computer latency, and disconnect/reconnect recovery. Add transparent start/stop, reverse, maintenance, send-to-depot, replacement and sale capture, depot/failure constraints, and safe paused relaunch recovery. Road vehicles, ships, and aircraft follow afterward. |
| Contested passenger demand | Model version 4: generalized cost in cents (fare/time/wait/transfers/comfort/lagged crowding), integer-exact logit shares over a pinned exp table, zero demand beyond the 8-theta cutoff, share-as-stock with exact conservation, and a digested last-fare latch that moves downward immediately on a fare hike while retaining smooth crowding decay. Markets carry a kind: cargo weights waiting at half the passenger rate, pays 1800 s per transshipment, values time at 60 cents/hour, and competes against trucking; the seeded demo now includes a freight corridor and cross-language cargo parity vectors. Authored aggregates saturate below Lua's exact-integer limit; v2/v3 replay remains supported. | Passenger corridor binding is implemented: line.register derives gravity demand from town capacities over computed distance and service facts (journey/headway/capacity) from canonical geometry plus repository consist metadata, origin-computed and carried on the ordered action, with a recorded fail-soft fallback ladder; per-station model boards with log-scale crowd glyphs render in the panel. | Live-verify the computed facts path (`factsSource` telemetry; does Build 35924 expose `modelRep.get`?), calibrate the corridor constants against real lines, hot-seat playtests to tune VOT/theta/alpha per market kind, bind cargo services to industry chains, decide transfer behavior, and balance match pacing. Freight scarcity mechanics remain the concept-layer follow-up. |
| Passenger/cargo presentation | Direct ECS telemetry now reads the populated passenger service: 413 people, 10 line users, 8 aboard, 2 waiting, identical on both peers. Cargo paths are present. | Cargo-positive proof and a host steering/injection/withholding policy so visible queues/loads reflect authoritative allocation. |
| Fares, score, match ending | Implemented in the model and in-game panel, with deterministic epoch/value ending and tie-breaks. | Better route-selection UX, calendar-based options, balance, and multi-hour human sessions. |
| Save/load | State migrates through schema 23, including canonical shared-save ownership, accounts, bindings, proposal/checkpoint consensus, shared-clock rendezvous, train release rounds/departure slots, authored town-development progress, and receipt-bound restore state. Byte-pinned load is automated after title entry. Fresh bootstrap verifies manager-visible ownership; a prepared two-peer boundary, distinct save receipts, schema-2 restore plan, reload, mandatory fresh checkpoint, and resumed train service pass live. | Live save/reload during an active held/releasing round, more than two pre-existing native companies, long-running sessions, and removal of the remaining manual stock Save-dialog step. |
| Checkpoints/resync | Format 3 covers model, canonical registry/structure, canonical balances/loans, and authorized per-train station rounds; formats 1/2 remain readable. Future-time clock barriers project staggered telemetry, correct bounded overshoot, refresh while paused, and adapt to the slowest peer. Assigned trains use all-peer station hold/release barriers; scheduled and prompt ordinary releases, human long-pause/speed-3 recovery, and deliberate slow-peer waiting are live-proven. Unanimously acknowledged pauses suspend station-round deadlines until unanimous latest-generation resume. Because Esc can stop bridge frames before its game acknowledges, a pending pause with another successful peer acknowledgement, recent pre-pause telemetry, and a still-connected TCP companion receives a distinct `connected-quiescent-modal` timeout protection; strict acknowledgement stays false. Disconnected, negatively acknowledging, or uncorroborated peers still fail closed. Pause-adjusted timeout and mode-transition behavior is automated. | Live-prove the connected-quiescent modal transition and long hold after a source restart; disconnect/reconnect proof; then coordinated return-to-depot/relaunch recovery, exact-boundary native snapshot, automatic two-peer restore, and local binding recovery. Arbitrary divergent geometry or moving-train coordinates are not patched in place. |
| Recovery archives | Host watcher links a later stable native save to the latest verified agreed boundary, hashes the save triplet, and exposes status. End-to-end boundary-8 proof passes. | Automatically request the native save at the boundary, require both-peer archive agreement, and execute coordinated rollback. Current association is explicit, not exact-tick proof. |
| Authoritative history/replay | Ordered commits/controls, digest-chained events, checkpoint reports, 4-event and 104-event independent Python replay pass. | Rotation/retention, full replay coverage for new operations, randomized long traces, and automatic first-fault bundles. |
| Canonical identity | Local IDs stay out of portable state. Shared-save pre-existing ownership is now authoritative and live-convergent on both peers. | Deletion/reuse stress, every dependency class, multiple pre-existing companies, disconnect/restart rebinding. |
| Native proposal replay | Schema 5 covers road/track/node changes plus named signals/waypoints and retained edge objects. Schema 7 covers strict stock station placement plus bounded portable construction/asset build, observable upgrade/edit, and removal. Engine replay, compound binding, finance, consensus, checkpoints, malformed-payload rejection, no-op rejection, and the bounded ordinary-UI facility matrix pass. | Complex topology, broader/mod construction adapters, and a two-computer human proof. |
| Vanilla action capture | Native hook observes queue and direct apply paths; BuildProposal has a payload-aware gate; 23 consequential visitors fail closed. Construction uses prepare -> unanimous readiness -> host build -> one-shot release -> result/checkpoint. Hook 0.13 captures tag-0 speed, typed tags 3-5/28-29 line payloads, and pointer-free tag-6/tag-13 SetLine/BuyVehicle scalar payloads. Stock purchase/assignment has human two-process proof; canonical terminal holds reuse gated tag 8 and pass four live populated rounds. | Add versioned adapters for remaining vehicle/category commands, and continue bypass-route auditing. Arbitrary script-mod commands are not automatically safe. |
| Frozen autonomy | Town/industry freeze and readback are implemented and used in authority validation. | Long unpaused no-player-change drift trace, then host-authored town/industry events one subsystem at a time. |
| Main-menu/session UX | Launcher Host/Join plus a real title-screen `MULTIPLAYER` entry are live-proven. Selection receipt gates automatic pinned-save load. Status, logs, evidence, and exact-session stop exist. | Two-computer usability, clearer lobby/roster/ready/error UX, reconnect/restore UI, optional discovery, and onboarding. |
| Installer/release | One-file companion, native binaries, checksum manifest, Steam discovery, backup install, strict verify, recoverable uninstall, launcher, menu coordinator, recovery watcher, and docs are packaged. | Clean-machine testing, updater/code signing, more Steam layouts, compatibility matrix, public support policy. |
| Security | Trusted-LAN/VPN transport with integrity/fingerprint checks. | Authentication, encryption, hostile-client validation, rate limits, and security review before Internet exposure. |
| Finished product | Not reached. | Human playtests, performance, balance, accessibility, tutorials, privacy/telemetry policy, crash support, and versioned match packs. |

## Strongest proof and its exact meaning

`runtime/localhost-live/train-prompt-barrier-state22-20260806-105918` loaded
the same populated save in two exact game processes and ran the pre-existing
three-part train through four prompt ordinary-line barriers. It finished with
identical core `fba1630d`, model `98f01295`, structure `15189409`, and mobility
`8e5d90e6`. Host status reports four completed/pruned rounds, zero scheduled
and four unscheduled release commits, zero pending rounds, zero faults, 1.86
seconds average latency, and 2.38 seconds maximum latency. The independent
audit reports 15/15 commit convergences, 2/0/0 physical proposals, 3/0/0
checkpoint barriers, and no unresolved peer digests.

`train-scheduled-state22-20260806-1010` remains the registered-schedule
mechanism baseline. `ownership-human-state22-20260806-103252` subsequently
proved long-pause/speed-3 recovery with a deliberately delayed peer and exposed
the synthetic fallback dwell that the prompt run removes. The evidence still
does not claim deterministic native passengers, exact mid-leg coordinates,
multi-train live throughput, or two-computer latency behavior.

Direct ECS telemetry succeeded in the populated source world even though the
documented convenience readers did not. Passenger count is no longer an
observation blocker. Steering it and proving non-zero cargo remain blockers.

The production menu proof `menu-production3-20260803` established that the game
waits at the title screen, exposes a real `MULTIPLAYER` entry, records the human
selection, then loads the pinned save and starts host authority plus the recovery
watcher. The localhost validator bypasses the click only because it is an
automated harness.

The exact-build one-process receipt
`runtime/live-validation/20260804-032456` proves depot and modular-station
construction, four custody swaps, twelve-track catenary station editing,
`ASSET_GROUP` build/removal, and depot/station removal. Signal add/removal passes
in `runtime/supported-api-probe/20260804-021739`. The later ordinary-UI sessions
`facility-vectorfix-manual-20260804-1009`,
`station-editfix-manual-20260804-1122`, and
`assetfix-manual-20260804-1203` establish the corresponding bounded two-peer
capture, ownership, physical-consensus, and checkpoint slice.

`runtime/localhost-live/facility-ui-20260804-083528` is the first broad human
two-process attempt and remains the negative receipt for four initial defects.
Reruns found and corrected helper-owned station-upgrade fields and a graphless
asset preview-rebase assumption. The final asset run independently audits 6/0/0
physical proposals and 7/0/0 checkpoint barriers with no relevant game errors.
The combined evidence and exact remaining boundary are in
`investigation/ORDINARY_UI_FACILITY_MATRIX_2026-08-04.md`.

## Ordered next gates

### 1. Human train-clock stress

The automated populated localhost gate already proves four complete canonical
station releases, including one pause-safe release. Use the manual lab to pause
from Player 1 while mid-leg, remain paused for at least fifteen seconds, resume
from Player 2, then repeat at speed 3. Both overlays must return to zero pending
rounds with zero clock/train faults; the format-3 checkpoint projections must
match.

Then deliberately burden one process, verify adaptive step-down/resync and
hysteretic recovery without lost/duplicate work. Finally disconnect/reconnect
the client long enough for its train to hold at a station and verify the audit
replays the same next release.

### 2. Two-computer populated human run

Use trusted LAN/VPN peers and byte-identical saves. Enter through
`MULTIPLAYER`, compare the initial checkpoint/inventory, then unpause both games
at the same speed. Run the existing passenger train for several cycles while
collecting intermediate core/model/structure/finance/mobility samples. Pause,
perform one supported simple track transaction from each peer, save on the
host, verify a linked recovery archive, and collect both evidence bundles.

This is the next decision-quality gate because it combines real networking,
human launch UX, moving native agents, pre-existing assets, and the supported
construction slice without pretending unimplemented commands are safe.

### 3. Finish schedule depth, then live-prove railway vehicles

For each operation, require bounded vanilla capture, canonical payload without
local IDs, peer/company authorization, deterministic replay, finance routing,
local postcondition/result binding, two-peer physical agreement, and a new
checkpoint. The basic line lifecycle is complete; continue with:

1. create two populated stops and prove reorder plus alternate terminals;
2. live-prove the newly typed vanilla purchase of a loco plus at least two `vehicle/waggon/` cars;
3. assign it to the synchronized line while paused, verify one canonical train and one company debit on both peers, then take three route-phase samples while running;
4. exercise start/stop, reverse, maintenance, and send-to-depot controls;
5. replace and sell it, then delete the line.

Keep unsupported visitors rejected until each full chain passes.

### 4. Broaden schema 5/7 beyond the completed stock facility slice

The ordinary two-process UI matrix now passes for named edge objects, a rail
depot, stock station editing/removal, and graphless stock assets. Preserve that
gate while adding:

1. public-town-road/resource preflight and signal preservation during upgrades;
2. topology splits/joins, crossings, bridges/tunnels, and terrain facts;
3. broader facility families and curated data-only mod constructions;
4. explicit adapters for any scripted callback that affects portable state.

Every added category still needs strict normalization, materialization,
compound output matching, ownership, finance, fault behavior, offline tests,
one-process proof, and two-process proof.

### 5. Complete recovery

The watcher closes packaging and observability around recovery but not rollback.
Research a safe native save trigger. If none exists, require a coordinated human
save protocol with explicit timing/paused-state receipts. Then make both peers
agree on the archived native save identity, relaunch from it, restore canonical
checkpoint state, rebuild local bindings, and refuse continuation on any
postcondition mismatch.

### 6. Own autonomous development and presentation

First measure unpaused drift without player actions. Freeze every subsystem that
cannot retain peer equivalence. Reintroduce town/industry change only as
host-authored events with physical postconditions. Use the now-working direct
passenger/cargo observation to design an approximate native presentation layer
whose loads and queues agree with the authoritative market outcome.

### 7. Product hardening

Only after the authority gates: broader economy, leasing/access fees, freight
competition, balance, reconnect UX, clean-machine install/update, security, and
public testing.

## What can still progress locally

Hot-seat gameplay remains independently valuable. Fares, scoring, match rules,
asset access, freight contracts, balance, and UI can be tested without assuming
that two independently evolving native simulations already support every
vanilla action.
