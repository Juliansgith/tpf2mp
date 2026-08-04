# Build and investigation report — 2026-07-31

This report pins the exact prototype delivered on 2026-07-31. It separates executable test evidence from live-game claims.

## 2026-08-02 prototype 0.16 superseding addendum

Prototype 0.16/state schema 13/proposal schema 3 closes the bidirectional localhost track-and-finance gate. `runtime/localhost-live/localhost-20260802-175636` started two exact Build 35924 processes with native hook 0.8.0; both `player1` and `player2` originated a 25,000 private track; both games reconstructed and canonically bound both transactions; and both companies ended at 4,975,000 on both peers. Three checkpoint barriers and both physical results converged. A 600-tick soak held core `fdaceb08`, structure `33cdc17a`, and canonical finance with zero reconciliation or consensus failures.

The longer run disproved the remaining origin-wallet assumption. Native debits can appear late or not at the expected boundary, and the original native player receives recurring machine-local loan-interest/maintenance entries. Proposal schema 3 therefore carries the native builder's bounded cost quote, while canonical network accounts own competitive balances. Native wallets are peer-local caches reconciled after ordered finance and at safe 60-tick intervals. The suite now passes 18 Lua core tests and 23 Python tests, including independent replay of the canonical ledger.

Unsupported station/depot construction remains fail-closed, but targeted capture diagnostics now preserve construction filenames, hints, transforms, parameters, and module counts for the next manual evidence export. See [BIDIRECTIONAL_NETWORK_FINANCE_2026-08-02.md](BIDIRECTIONAL_NETWORK_FINANCE_2026-08-02.md).

## 2026-08-02 prototype 0.15 superseding addendum

Prototype 0.15/state schema 12 closes the first two-live-game road/track vertical-slice gate. `runtime/localhost-live/localhost-20260802-144832` started two exact Build 35924 processes, injected and verified the native authority hook in both, connected `player1`/`player2` companions over localhost, passed the initial canonical/model/structure/finance checkpoint, agreed on native mobility, replicated and geometrically bound one private electrified track, normalized the proposal origin's 25,000 native debit, passed the post-build checkpoint, held structure through the soak, and agreed on final mobility. It finished core `818c056f`, structure `65335255`, with one physical success, two checkpoint successes, four converged comparisons, and zero faults.

The run exposed and fixed Lua empty-table/JSON empty-list ambiguity, GUI-state wallet staleness, and Build 35924's origin-only native debit behavior. Physical result consensus now excludes machine-local finance timing; engine-thread settlement samples the local effect, the origin delta is authoritative, and every peer books the necessary correction before its financial checkpoint.

The release now includes `LAUNCH_TPF2MP.cmd`: one Host / Join / automated Localhost Test UI that creates fingerprints, writes a short-lived peer/session profile, starts the companion, launches Steam, injects the hook, polls status, exposes logs, and stops exact session PIDs. The next gates are a two-computer human vanilla-builder run, automatic native-save boundary capture/reload, and broader construction/line/vehicle/autonomy codecs.

## 2026-08-02 prototype 0.14 superseding addendum

Prototype 0.14/state schema 11/checkpoint format 2/proposal schema 2 advances the native authority boundary without changing the portable state formats. Hook 0.7.0 validates the exact 37-entry command visitor table and installs fail-closed detours for 23 consequential speed/calendar, line, vehicle, field/terrain, date, color/name, no-costs, and debug-person tags. `BuildProposal` retains its separate payload-aware gate. Network mode now requires both gates and all 23 selected visitors; otherwise it refuses outgoing intents and incoming gameplay traffic. The new tags are intentionally unavailable until their category-specific canonical codecs, authorization, replay, result binding, finance treatment, and postcondition consensus are implemented.

Post-hardening exact-build run `runtime/supported-api-probe/20260802-075034` proved ordinary completion semantics at the new boundary: an unauthorized tag-0 `SetGameSpeed` completed with `success=false`, one matching token admitted the retry with `success=true`, and the final status reported 23 hooked visitors, one suppression, one admission, zero pending tokens, and zero visitor mismatches.

Latest full evidence is `runtime/live-validation/20260802-075533`. It passed 39/39 at tick 376 with hook 0.7.0 and the same verified core/model/financial digests (`f859604c` / `95dd1197` / `fde11e45`). Native evidence counted 12,886 queued commands and 12,912 applies, including 26 direct applies, with no invalid layouts, unknown tags/applies, pending/overwrite entries, queue/apply tag mismatches, or authority-visitor mismatches. The 23-tag gate remained disabled and transparent in standalone mode. See [CONSEQUENTIAL_COMMAND_GATES_BUILD35924_2026-08-02.md](CONSEQUENTIAL_COMMAND_GATES_BUILD35924_2026-08-02.md).

## 2026-08-02 prototype 0.13 superseding addendum

The current source is prototype 0.13/state schema 11/checkpoint format 2/proposal schema 2. It supersedes the older “proposal payload and replay are absent” boundary for one narrow category: simple linear road/track/node transactions normalize without local IDs, validate in Lua and Python, reconstruct in GUI state, match native outputs geometrically, correct private ownership through the supported replacement primitive, bind canonical event/slot identities, route the native finance delta, and reconcile. It also maps each original player to its assigned canonical company, separates a replay's local issuer from its native output owner, requires physical completion consensus, then requires an all-peer wallet-aware checkpoint before later work.

Latest full evidence is `runtime/live-validation/20260802-062137`. It passed 39/39 at tick 376 with state schema 11, checkpoint format 2, hook 0.6.0, and core digest `f859604c`. The independent checkpoint report verified 14 post-anchor events and replayed the authored model to `95dd1197`; two canonical/native-only changes remained continuous in the core chain and the canonical financial digest was `fde11e45`.

Focused run `runtime/supported-api-probe/20260802-024721` also proved normal and electrified track proposals with the requested native owner in a GUI/console-capable state. Together with the earlier ID-changing ownership round trip, this is the evidence basis for supported ownership correction and geometry-based result binding.

The automated suite now covers 16 Lua core cases, player-2 native/canonical mapping, distinct issuer/output-owner handling, ordered proposal/checkpoint outcomes, edge access/rebinding, hot-seat fail-atomic custody/finance, asynchronous canonical finalisation, deterministic proposal retention, GUI proposal/generic entity vetoes, a 104-event replay, syntax checks, and 22 Python tests. The Python layer exercises two real bridge directories and TCP peers, physical/checkpoint dependency blocking, roster pinning, success, financial divergence, timeout, fail-closed continuation, legacy evidence, audit verification, and checksummed recovery-plan generation. Release packaging builds a one-file companion and passes a temporary install/strict-native-verify/recoverable-uninstall cycle.

The remaining network boundary is narrower but still decisive: there is no completed two-live-game vanilla capture -> host commit -> physical finalisation -> ordered physical/checkpoint consensus run; checksummed restart planning exists but automatic native-save capture/reload is absent; station/construction/edge-object, line, and vehicle codecs/gates are absent; and autonomous world plus passenger/cargo presentation are not synchronized. See [CANONICAL_PROPOSAL_REPLAY_2026-08-02.md](CANONICAL_PROPOSAL_REPLAY_2026-08-02.md), [NETWORK_COMPLETION_CONSENSUS_2026-08-02.md](NETWORK_COMPLETION_CONSENSUS_2026-08-02.md), [CHECKPOINT_BARRIERS_AND_RECOVERY_2026-08-02.md](CHECKPOINT_BARRIERS_AND_RECOVERY_2026-08-02.md), and [LIVE_VALIDATION_CHECKLIST.md](LIVE_VALIDATION_CHECKLIST.md).

## 2026-08-02 prototype 0.10 superseding addendum

Prototype 0.10/state schema 7 adds strict company isolation at the documented GUI proposal decision point. Existing non-negative source IDs from removed segment, edge, node, edge-object, and construction containers are resolved against logical ownership with pinned custody as fallback. A rival source returns the shipped game's `errorMessages` veto contract before commit. Own sources, new negative preview IDs, and public/untracked infrastructure remain allowed. Denial evidence is bounded and machine-local IDs are stripped from the persistent portable event tail.

The complete automated suite passes: 11 core Lua tests, proposal ownership/access and atomic replacement tests, engine/game-script integration, hot-seat financial/custody integration, GUI veto integration, a 104-event replay trace, 12 mod Lua syntax checks, two investigation Lua checks, 17 PowerShell syntax checks, and 14 Python companion tests. This is code-level evidence. The remaining live gate is one short Company 2 track / Company 1 electrification attempt proving zero apply, debit, ID change, or ownership change, followed by a successful Company 2 owner upgrade.

The mod was installed while Transport Fever 2 was closed. Evidence `runtime/live-evidence/evidence-20260802-004556.json` records `process.running=false` and matching 12-file source/installed tree fingerprint `92b491bd41471513f7936f985d324fe8d3f01d26f7f47114ce977066eac6b461`. Match manifest `4bcc9fcecf65e9d7e16501f0aaa536ba931fec03c4f0a8f780c1c4ceae3c1c50` covers the pinned game executable, installed mod, companion, and 130,560-byte hook DLL. These are install-integrity facts, not live gameplay evidence.

## 2026-08-01 prototype 0.9 superseding addendum

The latest source is prototype 0.9/state schema 7 with hook 0.6.0. Follow-up live probing proved that legacy `game.interface.setPlayer` asserts for `BASE_EDGE`, while the native ownership tool is a `BuildProposal`. Version 0.7 therefore pinned road/track edges to the turn desk with logical company ownership. A supported proposal round-trip proved every transfer changes the local edge ID, and a manual cross-company electrification made 0.7 change the logical split from `1/5` to `3/3`. Prototype 0.8 then matched the focused two-edge retest exactly and protected finance, but its engine owner lookup ran before the new component became readable. Prototype 0.9 uses the committed apply owner only for that absence, still rejects engine contradictions, atomically rebinds the batch, and verifies every pinned engine owner before finance. Native custody is still pooled, so this preserves ownership after an edit but does not reject the rival edit. Hook 0.6.0 adds an opt-in same-state pre-issue callback which projects the original Lua command envelope before transparent call-through.

The newest hook-enabled unattended run `runtime/live-validation/20260801-183544` supersedes the earlier live boundary for native integration:

- the full executable SHA-256, architecture, PE timestamp/image size, and 17 exactly-once code signatures validated before hook activation;
- three command-interface setup calls were observed across 42 Lua states, three states received the deferred `api.cmd.sendCommand` wrapper/mirrors, one GUI state registered the pre-issue observer, and 21 real mod commands were forwarded;
- all 30 in-game checks passed at tick 270 with core/replayed-model/structural digests `ca649fa9` / `9621119a` / `1be6e32a`;
- `CommandList::Swap` recorded 10,721 commands in 206 non-empty batches; the evidence snapshot had 10,695 completed applies, 47 pending queue entries, and 21 direct applies, exactly satisfying conservation with zero invalid layouts, unknown tags/applies, pending overwrites, or tag mismatches;
- the corrected GUI/engine matrix recognizes proposal, vehicle, line, naming, finance, town, and industry factories as callable tables;
- exact settings restoration, temporary-resource cleanup, and exact disposable-process cleanup passed. Historical evidence preserves earlier installs. Current closed-game evidence `runtime/live-evidence/evidence-20260801-234038.json` proves the 12-file prototype-0.9 source/installed trees match fingerprint `d9b20090c06905f9bcf26b6136f786c4963f8926d74b25007a784affeba10110`; its copied log remains the preceding 0.8 timing session and is not presented as a 0.9 gameplay pass.
- the regenerated current match manifest fingerprints the real 72,843,280-byte game executable, 12-file mod, companion, and hook DLL as `858da334279f5666eeacc60d986671abb9bff613124a0c5ec101f98637aeb2b3`.

The separate gate run `runtime/supported-api-probe/20260801-163359` suppressed one tag-15 proposal before mutation and admitted two one-shot-authorized calls to the original visitor, ending with callback results `false, false, true`. This is a real BuildProposal authority primitive, not network replication. Run `20260801-190732` additionally proved supported arbitrary-player edge replacement and mandatory ID rebinding. The exact 0.7 ownership failure, 0.8 timing failure, and 0.9 correction are documented in [CROSS_COMPANY_TRACK_REPLACEMENT_2026-08-01.md](CROSS_COMPANY_TRACK_REPLACEMENT_2026-08-01.md). General payload serialization, host-mediated release/injection, cross-machine multi-output binding, other command visitors, tick/RNG control, and passenger/cargo mutation remain unimplemented. See [NATIVE_COMMAND_PIPELINE_BUILD35924_2026-08-01.md](NATIVE_COMMAND_PIPELINE_BUILD35924_2026-08-01.md), [PROPOSAL_EDGE_OWNERSHIP_BUILD35924_2026-08-01.md](PROPOSAL_EDGE_OWNERSHIP_BUILD35924_2026-08-01.md), [NATIVE_HOOK_BUILD35924_2026-08-01.md](NATIVE_HOOK_BUILD35924_2026-08-01.md), and [MOBILITY_TELEMETRY_2026-08-01.md](MOBILITY_TELEMETRY_2026-08-01.md).

## 2026-08-01 superseding validation addendum

The original main-menu-only live boundary below is preserved as historical evidence, but it is no longer the newest result.

The installed state-schema-3 build passed two consecutive fully unattended disposable free-game runs on Transport Fever 2 Build 35924 after adding a 180-update native-mutation warm-up. Evidence directories: `runtime/live-validation/20260801-033437` and `20260801-033644`.

- 30/30 in-game validator checks passed at tick 270 with zero recorded script-error lines in both guarded runs.
- Two native companies, separate wallets, a real journal debit, two turn cycles, payout to both companies, and reconciliation passed.
- Match lifecycle initialization and automatic checkpoint export passed.
- The independent companion replay verified seven post-checkpoint events and reached the recorded model digest `7eee0ab0`.
- Structural digest: `1be6e32a`; the fresh world contained no player-built lines, vehicles, or depots, so asset transfer remains an explicit live gate.
- Source and installed mod fingerprint: `4dc45465fe19f437d4ce681b17c999d7983d6bfa36dd6569d887a661c8f02fea` (matching).
- Match manifest fingerprint: `b8917cb8d7cae05b18f5451cf9bdb4b3abc25dfedd07c7644519e7fe57829a64`.
- Settings restoration was byte-identical; temporary injected resources and activation marker were absent after cleanup; the game process was stopped.

Earlier unguarded attempts intermittently entered the game's generic Internal-error/hang path around the first tick-15 native finance stage. The validator now records `auto-validation-warmup` and performs no native player/journal mutation before tick 180. The two consecutive guarded runs ended at identical core/model/structural digests (`ef1598bf` / `7eee0ab0` / `1be6e32a`).

A separate supervised capability run, `runtime/supported-api-probe/20260801-032701`, reached a fresh disposable world but used a function-only type predicate and therefore misclassified callable command tables as absent. Corrected runs `20260801-161030` and `20260801-162057` prove the public proposal/event factories callable and a real documented road proposal successful. The historical run remains startup/cleanup evidence, not negative factory evidence.

The current automated suite passes 11 Lua unit tests plus edge-replacement, game-script, hot-seat, replay, and GUI integrations; syntax checks for all 12 mod Lua files, two investigation Lua probes, and 17 PowerShell tools; 14 Python/companion tests including real localhost TCP and the Windows-Lua halfway-float checksum vector; an actual Lua-checkpoint-to-Python replay; and a separate 104-event cross-language replay trace.

See `REMAINING_FROM_BRIEF.md` for the current itemized product gap. The old hashes and “main-menu only” result later in this dated report describe the 2026-07-31 artifact, not the installed 2026-08-01 build.

## Delivered architecture

- Standalone play defaults to a native turn proxy: the original player is the UI/control desk and two added native players are the permanent companies.
- The active company's supported `PLAYER_OWNED` set is leased into the desk. Cycle/reconcile enumerates every current desk-owned object, so rolling stock or non-edge infrastructure omitted by a particular GUI event is still recovered. Build-35924 `BASE_EDGE` entities are the explicit exception: native custody is pinned to the desk. Prototype 0.9 retains logical ownership across complete uniquely matched replacement batches, handles the measured early component-visibility gap, and fails closed before finance on unresolved or later-invalid custody.
- The desk mirrors the active native wallet. On turn close, its signed gameplay delta is moved to that company and the desk returns to its baseline.
- Borrowing and repayment are blocked in proxy mode. The desk maximum is reasserted at zero, the known finance controls are disabled, and their GUI events are vetoed.
- Native commands are observed for research, but are not represented as network-authoritative commands. Network mode remains a canonical economy/sequencing laboratory.

## Automated evidence

`tools/run_tests.ps1` passes:

- 10 Lua unit tests covering canonical identity, cross-language checksums, demand allocation, settlement validation, proxy conservation, rollback, and file bridging;
- engine game-script intent/commit/save-state integration;
- standalone two-company ownership, rolling-stock, wallet, loan-guard, failed-ownership-postcondition, and serialized reload/reconcile integration;
- GUI-state thread bridge, repeated shared-state rendering, and finance-lock integration;
- syntax loading for all 12 installed-mod Lua files;
- syntax parsing for all 9 PowerShell tools;
- 7 Python tests, including manifest sensitivity, protocol tamper rejection, research rendering, bridge cursor persistence, and a real localhost host/client commit path.

These tests use simulated Transport Fever 2 interfaces. They prove the control and accounting algorithms, not the engine's behavior for every native entity type.

## Pinned artifacts

- Installed mod: `C:\Program Files (x86)\Steam\userdata\63389028\1066780\local\mods\tpf2_mp_1`
- Source/installed mod tree SHA-256: `9d1b95ce4b4aefef6e264d12d6f622924d01d0f36d186925ae32c4e0dec024d4` (matching)
- Match manifest: `runtime/match-manifest.json`
- Match fingerprint: `28f6d3b16eb1c9bd0e6cd246d732b8f5a3e19d20764f9c4bf6ca1e0efb3d4128`
- Evidence bundle: `runtime/live-evidence/evidence-20260731-183401.json`
- Game executable SHA-256: `782b904a8f7bbdac1f7a18528f1a5c778691e5aa3087c37c351bf6912585175c`
- Observed runtime build: `Build 35924 Windows 64-bit`

## Current live-evidence result

The captured game log is from a main-menu session. It contains no structured `[TPF2MP]` engine-init, GUI-init, or match-initialise marker and no research export. Therefore it is explicitly **not** evidence that the mod loaded in a save. It also contains no recorded `tpf2_mp` script error.

The next valid gate is a new disposable free-game map with the mod enabled, followed by checklist sections A–B2 and an in-game **Export Research**. `tools/run_live_validation.ps1` now automates installation, manifest generation, visible launch, post-exit log/evidence capture, and report rendering; it intentionally does not auto-load the user's existing 200 MB `Island Chain` saves.

## Facts versus hypotheses

Documented facts used by the implementation include the repeated engine-save/UI-load thread bridge, `game.interface.sendScriptEvent`, multiple player creation, player ownership changes, `PLAYER_OWNED`, entity enumeration, and command result fields. See [README.md](README.md) for the primary-source table and shipped-script evidence.

Still live-unproven: manager visibility after ownership changes, running vehicle/line behavior across transfers, transferability of every infrastructure subtype, arbitrary-player booking in this exact build, per-player loan interest, complete autonomy suppression, and deterministic physical proposal reproduction between machines. The executable sequence is in [LIVE_VALIDATION_CHECKLIST.md](LIVE_VALIDATION_CHECKLIST.md).
