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

## Not done

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
