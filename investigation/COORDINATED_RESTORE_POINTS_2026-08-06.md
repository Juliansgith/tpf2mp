# Coordinated restore points

Date: 2026-08-06 (Europe/Amsterdam)  
Scope: turning an agreed checkpoint boundary into a place both peers can
actually return to. Closes the gap that made every fault terminal.

## Why this outranked more features

Every consensus failure in this system faults closed. That is correct — it is
what stops a silent divergence becoming a corrupted match — but until now the
only thing behind a fault was "restart from the pinned save". From a player's
chair that is indistinguishable from being desync-kicked, which is precisely
the failure mode the Transport Fever community names when asked about
multiplayer (Prison Architect is the reference everyone reaches for). We had
roughly fifteen ways to fault and zero ways to rewind.

## The property that makes it tractable

A Transport Fever 2 save contains the mod's own script state. A save written
while a peer is paused at an agreed boundary therefore **is** the canonical
state of that boundary: the canonical registry, accounts, economy, and
vehicle-sync tables all travel inside it.

Restoring consequently needs no state patching and no exact-tick save
command (which Build 35924 does not expose). It needs one thing: proof that
both peers return to the *same* boundary.

## What makes a restore point

`companion/tpf2mp/restore.py` reads the ordered audit and reports every
candidate boundary with a ready/not-ready verdict. A point is ready only
when all four hold:

1. **The boundary converged** — a successful `network.checkpoint_outcome`,
   so every peer already agreed on that state.
2. **Every required peer filed a save receipt** — a new ordered
   `recovery.save_receipt` control naming the boundary, the save's SHA-256,
   the core digest, the convergence key, and attesting a paused world.
   Because it is ordered, both peers see each other's claim.
3. **Nothing was ordered in between** — no commit exists between the
   checkpoint outcome and a peer's receipt. Otherwise that peer's save
   contains work past the boundary and the two worlds would resume out of
   step. Receipts themselves are excluded from this count: they change no
   world.
4. **The peers attested the same world** — matching core digest and
   convergence key across receipts, and agreement with the checkpoint's own
   core digest.

Every failure is reported as a reason rather than silently downgraded. A
restore point that cannot be proven is worse than none, because it invites a
resume into divergent geometry.

## Restoring

`build_restore_plan` produces a signed plan naming the boundary, the
convergence key and core digest, each peer's attested save hash, and a
`resumeSession` id (`{session}-r{boundary}`). Using a fresh session id is
what makes rollback clean: the faulted audit stays intact as evidence, and
the resumed session starts its own ordered history rather than trying to
rewind the old one.

`confirm_restore_readiness` then re-hashes each peer's save **on disk at
restore time**. The receipt proves what a peer saved then; this proves the
file is still that save now. A replaced, edited, or missing save is refused
by name rather than resumed.

## Protocol

`recovery.save_receipt` is strictly validated: exact field set, positive
boundary, non-negative timestamp, a real 64-character lowercase hex SHA-256,
non-empty digests, and `paused` that must be literally `true`. A receipt that
does not attest a paused world is rejected outright.

## Tests

Five groups in `tests/test_companion.py::RestorePointTests`, all asserting
refusal as loudly as success:

- a boundary with only one peer's receipt is not ready, and planning against
  it raises rather than guessing;
- a save taken after an intervening ordered commit is refused, with the
  count of commits in the reason;
- peers attesting different core digests for the same boundary are refused;
- a fully ready point builds a verifiable plan, resolves the right boundary
  when an earlier one lacks receipts, confirms both saves on disk, and then
  refuses the same plan once one save is edited or omitted;
- the receipt action's validator rejects each malformed field and any extra
  field.

Full offline suite passes (75 Python tests, 64 Lua, boundaries,
cross-language replay).

## Original limitations (superseded where noted below)

- **No in-game flow yet.** The engine does not currently emit
  `recovery.save_receipt`; the protocol, readiness logic, plan, and
  verification exist, but a player still cannot trigger "save an anchor" from
  the panel. That is the next slice: a paused-and-quiescent check, a prompt,
  and the receipt emission after the watcher observes the new save.
- **No automated relaunch.** The plan tells both peers exactly what to load
  and with which session id; nothing yet performs the load for them.
- **No live proof.** Everything here is offline-verified. A live rollback —
  fault a session deliberately, restore, and confirm both worlds resume
  converged — is the acceptance test this slice is written for.

## Follow-up hardening (2026-08-06)

The in-game receipt path described above is now implemented rather than merely
planned. Both host and client launch a process-pinned save watcher, each watcher
hands its own stable save to its authenticated companion, and the client can
file a host-ordered receipt without entering the game's positive local-sequence
namespace. On localhost, peer-specific filename prefixes prevent both watchers
from attesting the same file in the shared save directory.

Restore plans are now schema 2. They require the exact peer set and bind every
peer's save to one session, boundary, checkpoint core digest, checkpoint
convergence key, receipt commit sequence, and SHA-256. Conflicting duplicates,
pre-checkpoint receipts, mixed sessions or boundaries, missing or extra peers,
and duplicate roster entries are rejected. Anchor readiness also consumes
schema-3 game health, including local/deferred work and pause acknowledgement;
stale health cannot produce READY.

The remaining claim is deliberately narrower than an atomic engine snapshot:
Build 35924 exposes no save-if-quiescent primitive. A save is accepted only if
it was created after READY, remains unchanged for six seconds, and the host is
still READY when it orders the receipt. This is practical race closure, not a
proof that native GUI state can never change within a frame. The complete
implementation and adversarial results are recorded in
`ADVERSARIAL_AUDIT_ROUND3_2026-08-06.md`; live save/restore acceptance remains
to be run.

## One-button boundary preparation (2026-08-06)

The first live UI attempt disproved the manual workflow. Both peers exported
byte-compatible checkpoints at ordered sequence 4, but the host only archived
them: checkpoint consensus was opened only by match/physical/development
boundaries, never by an unsolicited manual export. Consequently
`lastAgreedCheckpointSeq` remained 1 and READY correctly stayed false.

The production flow is now one action: **Prepare Restore Point**. Either peer
may submit ordered `recovery.prepare`; the host then fences new gameplay work,
rendezvous-pauses both games, waits for fresh schema-3 health and empty local
queues, and emits host-only `network.checkpoint_request` at one shared ordered
sequence. Both game processes automatically export that exact boundary. The
usual all-peer checkpoint comparison emits the outcome, and READY appears only
after both games consume it. The preparation state reconstructs from the audit
after a companion restart.

The old two-click `manual-ui` route is also repaired for diagnostics: at an
acknowledged paused history tip, the first export opens the tracker and the
second may converge it. It is no longer exposed as the ordinary UI button.

The remaining native step is intentionally explicit. Build 35924 exposes no
documented script command for writing a save, so after READY each player uses
the ordinary Save dialog. The existing process-pinned watcher detects the new
peer-prefixed save, waits for stability, files its receipt, and produces a
restore point once both receipts exist. Automating mouse/keyboard input into
the Save dialog would be less portable and less trustworthy than this single
native interaction.

### Live acceptance: one-button preparation

The localhost populated-save run `anchor-button-20260806-2211` accepted one
**Prepare Restore Point** click while both games were running. Ordered
`recovery.prepare` committed at sequence 3, the shared pause converged, and the
host emitted `network.checkpoint_request` at sequence 6. Both peers exported
the same boundary and accepted `network.checkpoint_outcome` at sequence 7.

The agreed checkpoint contained matching canonical, core, model, structural,
financial, and world-manifest digests. Both companions then independently
reported `anchorPreparationStatus = ready`, `anchorReady = true`, and
`anchorPreparationCheckpointSeq = 6`; neither reported a session fault. This
closes the live acceptance gate for automatic boundary preparation. Native
save creation and receipt/restore acceptance remain separate live gates.

### Live acceptance: receipt-bound reload and resumed service

Those remaining gates subsequently passed. The two peer-specific saves for
boundary 6 were independently observed, stabilized, hashed, and committed as
ordered receipts 8 and 9. The resulting schema-2 plan is:

`C:\Users\Sepgi\AppData\Local\TPF2MP\sessions\anchor-button-20260806-2211\coordinated-restore\restore-plan-boundary-6.json`

It binds source session `anchor-button-20260806-2211`, resume session
`anchor-button-20260806-2211-r6`, core `22db9d70`, convergence key `a0396aa5`,
and checksum `99734250`. The attested save hashes are
`29fb9374758009bfce7406cbe8aad04e6421c51bca8bb90831a3aeceb2e9ca68`
for Player 1 and
`da939523521e5f91af8aef4c28f8aff966fb2da0ece4f342449db7f7b42446e8`
for Player 2.

The first relaunch exposed an important launcher assumption rather than a
world-state divergence. Native player IDs are save-local: Player 1's restored
world reported `5743,9619`, while Player 2's reported `9673,5743`. Requiring
those lists to be byte-identical was invalid. Restore startup now validates and
passes each save's own two-ID map to that game process; it never treats a
machine-local ID as a network identity.

Both exact Build 35924 processes then accepted ordered `recovery.resume` at
sequence 1, recomputed the plan-bound core `22db9d70`, and converged a mandatory
fresh checkpoint with structural digest `84a886c5` and new-session convergence
key `c64f6b75`. Gameplay remained fenced until that checkpoint outcome. A
second connected run resumed the shared clock, produced two real
`vehicle.sync_release` commits from the loaded trains, and returned to a clean
shared pause with no session fault. Its archived evidence is:

`runtime/manual-network-evidence/anchor-button-20260806-2211-r6-20260807-000538`

Independent audit replay reports 21 commits, one control, 858 telemetry
records, 21 converged commit digests, two checkpoints, no pending physical or
checkpoint work, and no proposal fault. This closes coordinated receipt,
plan verification, peer-local reload, mandatory post-load convergence, and
resumed-service acceptance. The only intentionally manual engine operation is
using Transport Fever 2's native Save dialog after the one-button preparation;
Build 35924 still exposes no supported save command.

A final exact-save recheck after the adjacent-generation clock fix is archived
at
`runtime/manual-network-evidence/anchor-button-20260806-2211-r6-20260807-001633`.
The restored trains ran for roughly 35 seconds, completed four station-release
orders, and required no absolute-skew correction. The requested generation-4
pause finished acknowledged with actionable/projected skew zero, no pending
vehicle round, no error, and no session fault. Audit replay passed with 9
commits, one control, 228 telemetry records, 9 converged digests, and two
checkpoints; both disposable game processes were then closed.
