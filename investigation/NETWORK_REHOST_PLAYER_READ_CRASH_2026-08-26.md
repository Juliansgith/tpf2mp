# Network rehost initialization crashes (2026-08-26)

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
The native-hook trace ended with a successful `BookJournalEntry`, and the old
save's wallet did not equal the fresh match's configured starting cash. That
made the synchronous book-then-read path unsafe and a valid first fix, but the
correlation was not sufficient to assign the native exception to PLAYER.

The exact-save release gate settled the attribution. After removing every
synchronous wallet mutation from `match.initialise`, both peers still crashed
at the same RVA. Bounded initialization markers placed the failure after
`finance-staged`. Per-kind manifest tracing then showed both peers completing
towns, industries and station groups before crashing on the first loaded
`STATION` entity. Build 35924's broad `game.interface.getEntity` projection
dereferenced a null optional native string while materialising that station.
Lua `pcall` cannot contain a C++ access violation.

After the manifest was made component-only, the same save cleared the manifest
and then reproduced the same failure in the immediately following structural
snapshot, which re-projected the manifest bindings. New paired dumps were:

- `2257a5dd-5abc-43f5-b16d-7bbd184b4204.dmp` and
  `9821baf7-c613-4f2a-b620-f7bb1ac7bd44.dmp` at the loaded-station manifest;
- `7505faf5-8f21-4e72-b5ec-b36a7f657263.dmp` and
  `0507cf8a-9db1-44bf-90cc-b0a809fa5442.dmp` at the structural snapshot.

All four record the same read-at-`0x10` and executable RVA `0x0117CA6A`.

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

Pre-existing-world initialization now has a separate component-only identity
path. The canonical manifest and structural snapshot read only specific engine
components, never the broad entity projection. Loaded station, depot, vehicle,
asset, construction and ownership-bearing identities use the same narrow
fingerprint on both peers. A precomputed manifest fingerprint is passed into
the binding operation so it cannot accidentally be recomputed through the old
broad path.

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
- A loaded-station regression makes every `game.interface.getEntity` call
  fatal, then runs both the canonical manifest and structural snapshot. Neither
  may attempt the broad projection.
- The complete repository suite passes with 142 Lua unit checks plus the
  network, hot-seat, replay, cross-language, launcher, recovery, and packaging
  checks.

## Exact-save live gate

The original 53.8 MB `mp-fea4b787442345c3` starting save was loaded into two
separate hooked Build 35924 processes. Both peers completed:

- company and finance staging;
- a 60,502-entity component-only world manifest;
- vehicle-cost backfill and a 425-object structural snapshot;
- match initialization and initial checkpoint consensus;
- shared-clock run/pause coordination through checkpoint boundary 18.

The generic validator's later fixed-coordinate track proposal collided with
the populated map and was rejected consistently by both peers. Its
`physical-rejection` checkpoint converged; it did not reproduce either native
crash and is not evidence of a rehost failure.
