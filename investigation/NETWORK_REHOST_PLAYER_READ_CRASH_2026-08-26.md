# Network rehost PLAYER-read crash (2026-08-26)

## Incident

Session `mp-fea4b787442345c3` loaded a populated save from an earlier network
match and started a fresh two-player authority session. Both peers showed the
base game's `An error just occurred` dialog while applying the ordered
`match.initialise` action. The host later faulted with
`checkpoint-consensus-timeout:player1,player2` because neither game survived
long enough to acknowledge commit 3.

The relay and companions remained connected. Both industry-content attestations
had already converged, which rules out transport loss and content mismatch as
the initiating fault.

## Native evidence

The host captured minidump
`1f5b1cab-7084-47e8-829e-80811325a7c1.dmp` for pinned Windows Build 35924.
It records:

- `EXCEPTION_ACCESS_VIOLATION`, read address `0x10`;
- executable RVA `0x0117CA6A`;
- a null `rbx` at `mov r8, qword ptr [rbx + 0x10]`;
- the faulting game thread attributed to `tpf2_mp.lua_update()`.

The caller at RVA `0x0117A04B` is in the engine's Lua entity projection path.
The native-hook trace ends with a successful `BookJournalEntry`. The old save's
wallet did not equal the fresh match's configured starting cash, so
`ensureCompanyStartingCash` issued that command and immediately called
`game.interface.getEntity` again to verify the result. Build 35924 can expose a
transient PLAYER component during that same-update read; fresh starter saves
did not exercise the path because their adjustment was zero.

## Fix

Network initialization now creates the authoritative starting accounts without
mutating native wallets inside the ordered initialization handler. Native
wallets are presentation caches and are reconciled only after the initial
checkpoint reaches a quiescent boundary.

Wallet reconciliation now:

1. samples all PLAYER balances before any mutation;
2. issues at most one `BookJournalEntry` per update;
3. never performs a same-update post-book PLAYER read;
4. verifies the result on a later update;
5. prefers the company affected by the current ordered finance event.

`match.initialise` also emits bounded stage markers so a future native failure
identifies the last completed initialization boundary without another bespoke
instrumented build.

## Regression coverage

- The network company-mapping integration starts with a pre-existing local
  wallet at `$30m` and a `$5m` canonical target. It asserts that the ordered
  initialization commit issues no journal command, then proves the wallet is
  reconciled only after initial checkpoint consensus.
- A finance regression makes every PLAYER read fatal after a journal command.
  It also gives both companies stale wallets and asserts that only one is
  mutated per reconciliation pass.
- The complete repository suite passes with 141 Lua unit checks plus the
  network, hot-seat, replay, cross-language, launcher, recovery, and packaging
  checks.

