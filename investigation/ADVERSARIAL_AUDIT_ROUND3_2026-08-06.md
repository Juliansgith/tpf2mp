# Adversarial audit round 3: authored follow-ups, bankruptcy, anchors, towns

Date: 2026-08-06 (Europe/Amsterdam)  
Scope: registration storms, commit reentrancy, bankruptcy determinism,
companion sequence identity, anchor readiness, restore-plan integrity,
canonical town binding, and Lua/Python parity.  
Result: **six session-stranding defects and one unsafe live-flow omission
confirmed; all fixed.** The full offline suite passes. Live engine experiments
are tracked separately below and are not implied by the static result.

## 1. Registration storm and reentrancy: confirmed, fixed

`vehicle.assign` called auto-registration from inside `applyCommitted`.
`corridor_binding.autoRegisterLine` treated a non-throwing `submit()` that
returned `false` as success, while `network_intent_runtime` only deferred
physical actions. A registration submitted while an operation/checkpoint
barrier was active was therefore rejected and silently lost. Town development
had the same nested-submit problem and ignored the result entirely.

Commit-derived authored work now has a separate deferred lane:

- it never emits recursively from `applyCommitted`;
- physical captures always drain first;
- registrations coalesce by canonical line id;
- town batches accumulate and emit in protocol-valid chunks (at most eight
  calls per town and 512 towns per action);
- transient bridge failures retain the follow-up with bounded retry delay;
- anchor health reports physical and authored queue depth together.

The adversarial runtime test models the stated case literally: eight rapid
`vehicle.assign` operations produce one in-flight operation, seven FIFO
entries, and exactly one eventual `line.register` action—not eight registration
barriers. A separate test proves 12 accumulated development calls split 8+4.

## 2. Bankruptcy determinism: confirmed, fixed

`evaluateMatchEnd` read `state.probes.bankruptCid`. Probes are deliberately
outside the authored digest, so equal canonical accounts could reach different
match winners if the local diagnostic differed.

The solvency verdict now lives in `finance.networkAccounts.bankruptCid`, is
projected by `finance.networkDigestView`, replayed by Python, reset with the
ledger, and is the only bankruptcy input accepted by `match_runtime`. A test
sets the probe to the opposite company and proves the canonical ledger wins;
another proves the verdict changes the authored digest.

## 3. Companion local sequence space: confirmed, fixed

Starting companion attestations at `1,000,000,000` only postponed collision
with the positive game sequence and repeated after a companion restart.
All host-generated intents and synchronization controls now share one negative,
monotonic, audit-restored namespace. Game intents remain positive. Client save
receipts use the same negative rule in their peer-scoped namespace and persist
the exact signed intent across reconnects. The test starts with a game sequence
of one billion, restarts the companion, and proves every synthetic identity
remains distinct and decreases.

## 4. Anchor readiness completeness: confirmed, hardened

The first readiness predicate saw host consensus tables but not work still
inside a game process. It could say READY while a local intent awaited host
ordering, a deferred FIFO was non-empty, a game had not consumed the checkpoint
outcome, or a clock/vehicle rendezvous remained active.

Clock health schema 3 now carries `localWorkPending` and
`deferredIntentCount`. READY requires a fresh schema-3 sample from every peer,
native speed observed as zero, the acknowledged pause generation, consumption
through the checkpoint outcome, empty game-local queues, and no host proposal,
operation, checkpoint, clock, pause-fence, rendezvous, or station-round work.
Tests individually make stale health and local queued work refuse READY.

Residual engine limitation: a GUI capture exists for a fraction of a frame
before its script event enters the engine queue. Build 35924 exposes no atomic
"save only if GUI and engine are quiescent" primitive. The watcher accepts only
a peer-specific save created after READY and unchanged for six seconds, then
the host rechecks READY before ordering the receipt. This closes practical
races but is not represented as an impossible-to-violate engine transaction.

## 5. Restore-plan integrity: confirmed, fixed

The analyser silently overwrote conflicting duplicate receipts, did not reject
a receipt ordered before its checkpoint outcome, checked core digest but not
the checkpoint convergence key, and could implicitly mix sessions. The plan
verifier accepted duplicate peer rosters and did not prove an exact one-save-
per-peer set at one boundary.

Restore plan schema 2 now rejects:

- implicit multi-session audits;
- non-origin-attributed, pre-outcome, conflicting, or malformed receipts;
- a receipt whose core digest **or** convergence key differs from the
  checkpoint;
- duplicate required peers, missing/extra peer saves, mixed boundaries,
  inconsistent receipt sequences, or an unrelated resume session.

Every per-peer record binds boundary, core digest, convergence key, receipt
commit sequence and save hash. The verifier checks exact field sets and the
exact peer-key set before any file can be trusted.

## 6. Town binding and cross-language parity: confirmed, fixed

Python bounded `town.develop`, but Lua accepted looser numeric/table shapes and
the native application skipped an unmapped town while returning success. A
client could therefore partially develop a batch and still acknowledge it.
There was also no dedicated checkpoint boundary after development, so the
structural-digest claim was not enforced at that moment.

Lua and Python now agree on the exact action shape, 512-town limit, canonical
`town:` ids, and integer call range `[1,8]`. Lua preflights **every** canonical
town against its manifest-bound local town before making the first native
call; a missing binding or native command error rejects the action rather than
partially succeeding. Successful `town.develop` commits open and export a
`town-development` checkpoint boundary, reconstructed after companion restart.
Direct parity tests cover valid/invalid batches and the exact-safe integer and
field contract for `recovery.save_receipt`.

## 7. Adjacent live-flow omission: confirmed, fixed

The code claimed a player could save on both peers, but the launcher started a
watcher only for `player1`, and that watcher tried to build a restore plan
*before filing any ordered receipt*. Thus an all-peer restore point could never
exist live.

Both launch paths now start one process-identity-pinned watcher per game. The
host broadcasts transient READY boundary/digest data to the client companion.
Each watcher hands its stable local `.sav` to its authenticated companion;
the companion hashes it and files the ordered receipt without touching the
game's sequence namespace. The host validates the claim against current READY
truth. On localhost, filenames must begin
`tpf2mp_<session>_<peer>` so one instance cannot attest the other instance's
save from the shared directory. A real host/client socket test proves the
client request becomes a negative-sequence `player2` receipt.

## Static verification

- source-size and extracted-boundary ratchets pass;
- Lua syntax and runtime-module suites pass, including the literal eight-train
  FIFO/coalescing case;
- strict Lua/Python action parity and 104-event checkpoint replay pass;
- Python companion, consensus, restore, anchor I/O and live-socket tests pass;
- the complete `tools/run_tests.ps1` gate passes.

Research exports now include the configured agent-policy readback, the last
physical town-development outcome, and the pending development follow-up. This
makes the remaining engine experiment directly auditable instead of requiring
those facts to be reconstructed from diagnostic log lines.

## Live verification queue

Items 1, 2, 3, and 5 below are now complete. Items 4 and 6 still require the
human stock UI and remain the next honest gates:

1. **Passed:** existing-world runtime scaling reads false without mutation;
2. **Passed:** three physical town-development rounds converge structurally;
3. **Passed:** one-button preparation, two receipts, restore plan, reload, and
   mandatory fresh checkpoint;
4. **Open:** visually verify automatic line registration and second-train fact
   refresh, including `factsSource`;
5. **Passed with correction:** skeleton/minimum-safe fresh worlds run; literal
   zero capacity is an exact fatal negative and is no longer shipped;
6. **Open:** perform a vanilla rival edit and accept only the deliberate
   all-peer `origin-applied-capture-rejected` session fault.

## Live result 1: existing-world agent scaling is unsafe

The first populated two-peer run answered item 1 negatively. Both peers loaded
the same two-town/two-train save with the skeleton policy. Player 1 reported
`applied=2`, `verified=0`, `runtimeScalingWorks=false`: the native command was
accepted but the capacities did not change. Player 2 rejected
`match.initialise` before reaching this probe; the simultaneous native
assertion was subsequently isolated to saved-company ownership projection,
not attributed to `setTownInfo`. No later result from that session is trusted.

`setTownInfo` is therefore not an existing-world person-capacity scaler. Match
initialisation no longer calls it. Skeleton/empty capacity policy is applied
only through the supported `loadConstruction` resource modifier, and the probe
records the known negative runtime result without mutating either world. A
freshly generated skeleton world remains a separate live test because its town
buildings load under the modifier from the beginning.

## Live result 2: Company-1-selected shared saves expose the reverse projection

The retry removed runtime town mutation and failed at the same client point.
The save's persisted player list is `{5743, 9619}` and all 113 logical assets
belong to Company 1. Because the binary save was written with native player
5743 selected, Player 2 must move Company 1's manager-visible objects away from
its local UI player during fresh bootstrap. A legacy `setPlayer` projection
asserted. The earlier live save/load proof covered the inverse direction, in
which a Company-2-selected save already held Company 1's assets on the remote
player, so its fixture did not exercise this case.

The instrumented replay identified the first unsafe type as `edge_object`.
Signals and waypoints now follow base edges: their native holder is retained,
while canonical logical custody and rival-edit rejection remain authoritative.
They are not stock-manager rows, so no manager visibility is lost.

The exact save then passed the reverse-direction replay: both Build 35924
processes accepted `match.initialise`, checkpoint boundary 1 converged, and the
launcher audit reported one complete checkpoint with no pending or faulted
physical work. This upgrades the fix from an offline exclusion to live
save/load evidence.

This is not accepted as a town-development result. The remaining experiments
use a clean pre-multiplayer starting world. Projection failures now carry their
entity kinds in the game acknowledgement, and any ordinary ordered action
rejected by one peer immediately orders an `authored` synchronization fault
instead of leaving the launcher parked on a checkpoint timeout.

## Live result 3: the in-game reopen controls targeted container components

The first anchor run exposed a UI-only defect before any recovery save was
taken: the overlay window existed, but neither documented reopen control was
visible. The installer asked the outer `gameInfo` and `ingameMenu` components
for layouts. Build 35924 exposes the stable HUD insertion surface directly as
`gameInfo.layout`; the pause menu's button layout is the parent of
`ingameMenu.quitButton`.

`gui_entry_points.lua` now owns those two bindings, requires a persistent
component id before insertion, and retries idempotently while the pause menu is
being constructed lazily. A mock of the exact stock shape proves both controls
are inserted once and reopen the window. The full offline gate passes. The
already-running processes were not hot-reloaded; their existing hidden windows
were reopened through the console API so the anchor experiment can continue.

The subsequent clean two-process launch then proved the permanent fix live:
the in-game `MULTIPLAYER` reopen control was visible after both copies loaded
the pinned save. The localhost native loader deliberately sets
`requireMenuEntry=false` and therefore still bypasses the title-screen entry;
normal Host/Join sessions retain that separate title-screen bootstrap.

## Live result 4: manual checkpoint export could not create an anchor

At the first paused anchor attempt, both games emitted matching sequence-4
checkpoints (`convergenceKey=d5516a99`, `coreDigest=22db9d70`), and both
companion cursors consumed them. The host nevertheless remained at agreed
boundary 1. Static tracing confirmed the reason: `_record_checkpoint_locked`
archived checkpoints with no pre-existing tracker and returned. The UI's
manual exporter did not create a game-side barrier either, so simply promoting
the payloads host-side would have made the later outcome fail locally as
`local-checkpoint-is-unavailable`.

The fix replaces that timing-sensitive ritual with ordered
`recovery.prepare` plus a companion-owned state machine. It fences other work,
uses the existing future-time pause rendezvous, proves all-peer quiescence from
schema-3 health, then orders `network.checkpoint_request`; that handler creates
and exports the barrier on both games at the control's own sequence. Matching
checkpoints advance the normal consensus outcome and READY predicate. Protocol
validation is exact in Lua and Python, audit replay reconstructs an interrupted
preparation, and the client receives transient preparation status with anchor
readiness. The legacy matching-manual path now opens a tracker only for an
acknowledged paused latest sequence.

Offline acceptance covers malformed fields, the complete one-action state
machine, matching checkpoint convergence, READY only after outcome consumption,
manual-tip recovery, and companion restart reconstruction. The next live check
is deliberately small: click **Prepare Restore Point** once and require both
panels to reach `preparation: ready | anchor now: READY` without either player
pressing Pause or Export Checkpoint.

## Live result 5: coordinated restore and post-load play pass

The one-button run reached READY at boundary 6, and both process-pinned
watchers later filed distinct peer save receipts. Schema-2 restore plan
`restore-plan-boundary-6.json` binds receipts 8/9, source core `22db9d70`,
source convergence key `a0396aa5`, and plan checksum `99734250` to resume
session `anchor-button-20260806-2211-r6`.

The first restore attempt found that the launcher's equality check for native
company-player IDs was itself invalid: the two peer-local saves legitimately
reported `5743,9619` and `9673,5743`. The launcher now validates two IDs per
save and supplies each game its own mapping. No machine-local ID is compared
across peers.

After that correction, both games accepted `recovery.resume` as the first
ordered action and converged the mandatory fresh checkpoint before gameplay
was admitted. Its core remained `22db9d70`; its new structural digest and
convergence key were `84a886c5` and `c64f6b75`. A second connected run resumed
the loaded trains, completed two station-release rounds, and paused cleanly.
There was no session fault, no pending consensus work, and independent replay
validated the archived audit. Evidence lives at
`runtime/manual-network-evidence/anchor-button-20260806-2211-r6-20260807-000538`.

That run also found a non-fatal shared-clock defect. The host compared health
while one peer already described a new running clock generation and the other
still described the previous paused generation, then interpreted the expected
2.4-3.2 game-time transition as absolute skew. Seven redundant rendezvous
rounds converged safely but made the train run unnecessarily stop-start.
Skew is now actionable only when all fresh peer samples describe the current
authority generation. The projected diagnostic remains visible separately,
and a trace-shaped regression proves an adjacent-generation window cannot
order another rendezvous.

The exact-save live recheck at
`runtime/manual-network-evidence/anchor-button-20260806-2211-r6-20260807-001633`
then passed. During roughly 35 seconds of resumed service the only clock orders
were the requested resume pair and requested pause pair: zero
`absolute-skew-rendezvous` commits. Actionable skew sampled about `0.127` and
then `0.031`, four station releases completed, and the final generation-4
pause was acknowledged with zero pending rounds, no error, and no session
fault. Independent replay validated 9 commits, one control, 228 telemetry
records, 9 converged commit digests, and two checkpoints. The fix is therefore
live-proven as well as regression-covered.

## Live result 6: physical town development converges

Session `round3-town-construction-pos-20260807` applied three rounds of eight
ordered native development calls to the same manifest-bound Northfleet town on
two exact Build 35924 processes. Capacity advanced identically
`633 → 657 → 687 → 704`; the structural digest advanced identically
`1ef990cc → 4f3b90dd → 4c6390e2 → 2de890d4`. The final ordered structural
checkpoint was boundary 22, both peers ended at core `b418e90f` and model
`ca0582b4`, and neither session faulted. This closes the determinism question
for the tested world while leaving pacing/appearance and true two-computer
proof open.

## Live result 7: fresh-world crowd policy is effective, zero is unsafe

The stock-wizard native launcher produced independent fresh modded worlds for
skeleton, vanilla, literal zero, and the corrected minimum-safe policy.
Skeleton and minimum-safe worlds averaged about one capacity slot per town
construction, while vanilla controls averaged 3.38-3.77. Direct person counts
were correspondingly lower. Literal zero failed exactly at world generation
with a `PersonCapacity` component assertion; the compatibility key `empty` now
uses a one-slot floor and passes on both worlds with
`constructionScalingActive=true`. Existing-world `setTownInfo` mutation stays
disabled and honestly reports `runtimeScalingWorks=false`.

Full paths and normalized figures are in
`AUTOMATED_NATIVE_WORLD_AND_POLICY_EVIDENCE_2026-08-07.md`.
