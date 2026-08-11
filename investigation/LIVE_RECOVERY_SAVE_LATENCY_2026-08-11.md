# Live recovery-save latency, 2026-08-11

## Scope

The populated localhost session `perf-017-skeleton-20260810-2217` was paused at
recovery boundary 416. Both peers agreed on core digest `255e2f73` and
convergence digest `47196ac0`; the initial paused native-time skew was zero.
The audit replay in the collected evidence is valid and the session did not
fault.

This run tested the automatic stock-UI recovery-save path on the same world
that had completed the long vehicle/barrier/performance soak. It did not prove
a complete two-receipt restore plan: the old watcher timed out before either
native save had finished, health subsequently became stale while the two local
windows were switched, and player 1 was closed after its save completed.

## Live result

Player 1 produced the main `tpf2mp_r_9c3408be_p1_b416.sav` at 01:29:25 local
time. Its `.sav.lua` metadata and preview did not appear until 01:40:45, about
680 seconds later. The final files were non-empty and the temporary metadata
file was retired.

Player 2 was then saved through the ordinary stock pause-menu workflow rather
than a developer-console component invocation. It exhibited the same staged
behavior: the main `.sav` appeared immediately while a zero-byte
`.sav.lua.tmp` remained during the long metadata phase. Its metadata and
preview finalized 966 seconds after the main save appeared, and the temporary
file was retired. This rules out console reentrancy as the explanation for
player 1's delay. Both peers' three final files were non-empty and were hashed
before shutdown.

The old helper allowed only 60 seconds for both UI acquisition and native file
completion. It therefore reported a false failure and permitted the watcher to
schedule retries while Transport Fever 2 was still completing the first save.
The saves themselves were not corrupt; the timeout model was wrong for this
populated world.

Evidence captured before shutdown is under
`runtime/manual-network-evidence/perf-017-skeleton-20260810-2217-save-finalization-failure-20260811-0152`.
The earlier clean soak package remains under
`runtime/manual-network-evidence/perf-017-skeleton-20260810-2217-20260811-001014`.

## Correction

`tools/save_recovery_via_ui.ps1` now separates its short same-machine UI/lock
timeout from a bounded 1,200-second native-completion timeout. It holds the
same-machine save lock throughout that completion phase, verifies the exact
game process is still alive on every poll, recognizes fresh `.sav`, `.sav.lua`,
and `.sav.lua.tmp` activity, and records elapsed time and observed native
activity in the completion receipt. A watcher cannot start its next bounded
attempt while this helper still owns the operation.

The published pause-menu Save state now reflects effective ancestor visibility
rather than only the button's own stale visibility bit. The input helper also
has client-message text/click actions for the game's DPI-virtualized local
windows; these were useful for diagnosis, but the production save path remains
the bounded published-control workflow.

## Verification

- Both peers' `.sav`, `.sav.lua`, and `.jpg` artifacts were non-empty and
  SHA-256 hashed; neither peer retained a `.tmp` file.
- Source and architecture boundaries pass; the save helper remains within its
  240-line budget.
- The stock-UI fallback fixture passes with the new native-activity and elapsed-
  duration receipt fields.
- The complete repository gate passes: 132 Lua cases, 167 Python companion
  cases, PowerShell/Lua syntax, native tests, provenance/install rollback,
  recovery handoff, parity checks, and the 1,024-event replay at `c9fe205f`.
- After verification, both game processes and both session companions were
  stopped and a process audit reported zero remaining instances.

## Follow-up: bounded save state and paired restore acceptance

The long metadata phase was not the only avoidable contributor. Historical
worlds retained complete proposal/result payloads inside every diagnostic event
and several large native/GUI capture tails. `state_retention.lua` now keeps at
most 64 portable event summaries, preserves their action/result hashes and
digest chain fields, and caps each diagnostic capture family independently.
The compaction is idempotent across reloads and removes engine-local and nested
builder graphs from saved diagnostics. Profiling the old populated state before
and after migration reduced the retained Lua object graph by approximately
70 percent without changing authored model, canonical, finance, structure, or
vehicle-synchronization digests. This should improve future saves, but the
eleven-to-sixteen-minute metadata timings above remain the honest measurement
for the pre-compaction world.

The automated localhost acceptance path now discovers a *pair* rather than
merely the newest archive for one role. It verifies that both receipt-bound
archives name the same plan version/checksum, source session, resume session, boundary,
checksum, peer roster, and on-disk load-bearing save pair before staging either
world. The ordinary two-computer launcher deliberately remains role-local:
each machine verifies and keeps only its own large save while the signed plan
binds both receipts and the remote independently proves its bytes. The
localhost loader touches only the disposable staged peer save immediately
before that exact process starts, waits for the native save index and stable
row geometry, and fails fast if post-load telemetry identifies the wrong
source session or peer. A bounded whole-run retry covers the native Load Game
manager's observed intermittent startup hang; it never retries an authority or
convergence failure.

On 2026-08-11, `run_latest_local_restore_acceptance.ps1` loaded both distinct
boundary-11 archives from session `restore-handoff-live-20260809-2127` into
resume session `restore-handoff-live-20260809-2127-r11`. Both games independently
validated plan checksum `0b009dd3`, source core `b308c2a8`, source convergence
key `3de86cf4`, and their own peer identity. Schema migration legitimately
changed the current core, so the source anchor remained the admission proof and
the mandatory fresh checkpoint became the migration proof. Both peers agreed
on state schema 30 core `1873f67c`, model `07fa4478`, structure `5c15a724`,
finance `57ed3c1e`, vehicle synchronization `e9ff2b2c`, and convergence key
`9db26dfe`. Host status finished `restoreStatus=complete`, commit/checkpoint
boundary 1, with one completed and zero faulted checkpoint barriers.

The clean end-to-end receipt is
`runtime/restore-acceptance/20260811-165530.json`; its linked run status is under
`runtime/localhost-live/restore-handoff-live-20260809-2127-r11--restore-acceptance-20260811-165530-attempt-01`.
The wrapper closed both game processes, the host/client companions, and the
recovery watcher. The subsequent complete repository gate passes 132 Lua cases,
167 Python cases, native and shell tests, cross-language parity, packaging, and
the 1,024-event replay.

## Fresh compacted-build capture and reload

The fresh gate subsequently passed on the compacted state-30 build. The
launcher-only `prepare-restore` marker asks player1 to submit the ordinary
host-authored `recovery.prepare`; it bypasses neither host ordering nor
quiescence, checkpoint, native-save, receipt, or plan verification. Both exact
watchers are also bound to the current game PIDs so stale status from an earlier
attempt cannot be mistaken for a new archive.

The chained run exposed two automation assumptions before passing. Checkpoint
numbers belong to a sequencer session and restart after restore, so resume
boundary 8 is not older than source-session boundary 11. Also, the local
"prepare submitted" diagnostic had been serialized in the save; migration now
clears that process/session-local latch. A regression test covers both the
independent sequence namespaces and the cleared loaded-save latch.

`run_fresh_local_restore_cycle.ps1` then completed the whole workflow without
human input. Session `restore-handoff-live-20260809-2127-r11-r8` reached a new
READY boundary 8, generated both stock saves, filed both ordered receipts, and
published plan checksum `020ea09f`. The paired archive was ready 55.5 seconds
after the launcher request; player1 and player2 stable-file observations were
about 21.7 and 33.9 seconds after READY respectively. The wrapper closed the
first pair, discovered only the newly receipt-bound saves, loaded them as
`restore-handoff-live-20260809-2127-r11-r8-r8`, admitted `recovery.resume`, and
converged checkpoint 1 before cleaning every exact process.

The durable receipts are
`runtime/fresh-restore-cycle/20260811-173418.json` and
`runtime/restore-acceptance/20260811-173643.json`; their linked run statuses
contain the exact PIDs, save/archive pointers, checksum, and final companion
state.

## Honest remaining recovery stress

Fresh receipt-bound capture, automated same-machine relaunch, paired reload,
and post-migration checkpoint convergence are live-proven. The subsequent v6
gate also captures an active train after round 1 and releases round 2 after
restart; see [the active-train restore evidence](LIVE_ACTIVE_TRAIN_RESTORE_PHASE_2026-08-11.md).
The higher-risk matrix remains positive freight stock/queues/onboard cargo,
several authored town-growth ticks, multiple simultaneous trains, and the
role-local workflow on two physical computers. Automatic geometry repair, host
migration, and production-grade crash relaunch are still not claimed.
