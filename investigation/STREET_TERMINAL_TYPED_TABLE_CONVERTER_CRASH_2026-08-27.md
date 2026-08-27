# Street-terminal typed table-converter crash - 2026-08-27

> Followed the same day by
> [Connected street-terminal staged replay](CONNECTED_STREET_TERMINAL_STAGED_REPLAY_2026-08-27.md).
> The collateral-only helper proved crash-safe but could not recreate the
> external town-road split. The current design retires live collateral first,
> then issues a pointer-free typed proposal without those retired roots.

## Live failure

Relay session `mp-5e5d4c732aae691e` reproduced a real engine crash on Player 2
while replaying Player 1's modular bus terminal. The canonical transaction was
valid and had already committed on both peers. It contained:

- `station/street/modular_terminal.con`;
- three named modules;
- two explicit collateral town-building roots;
- one replaced town-road edge;
- two new nodes and three replacement/access street edges; and
- quoted cost `$90,020`, transaction digest `3b49d402`.

The crash dump is
`6d85791e-622f-46db-9c8c-6bc171235fb5.dmp`, 562,204 bytes, SHA-256
`d458346d400d74b6bf3049f16f2dcbc0331b16fc952182f7b555bb17da4e110e`,
written at 17:59:15 local time. The matching stdout records successful
`proposal.prepare` at tick 99 and `proposal.build` at tick 100, followed
immediately by the minidump. Transport Fever 2's crash handler identifies the
active frame as `tpf2_mp.lua_guiUpdate()`.

## Boundary localization

The native hook remained active and validated, but its BuildProposal gate had
zero calls, zero authorizations, zero passes, and zero suppressions. The last
game event left `proposalPending=true` and produced no native proposal result.
The failure therefore happened before `BuildProposalVisitor`, before command
queueing, and before relay/result consensus. It is not a network disconnect,
save-sync failure, authorization rejection, or native proposal-application
failure.

Minidump inspection identifies `EXCEPTION_ACCESS_VIOLATION` reading address
`0x8`. The faulting instruction is executable RVA `0x8d434`, inside the Lua
table iterator reached by `lua_next`; the immediate caller at RVA `0x719f1`
invokes the internal table-next routine. The surrounding stack is the engine's
recursive Lua-to-native value conversion used by `api.cmd.make.buildProposal`.

The 0.41.6 change had placed a module-bearing construction, two existing
construction removals, and replacement road topology into a newly materialized
typed `SimpleProposal`. It also copied module repository `metadata` and
`updateScript` objects directly into that proposal. Those resource objects are
engine-owned. A Lua `pcall` cannot contain the resulting native access
violation. The exact offending nested member is not exposed in the dump, but
the converter boundary and the absence of a visitor call are conclusive.

## Correction

Two independent safety boundaries now apply:

1. A fresh construction with explicit collateral no longer enters typed
   `ConstructionEntity` replay. It uses the staged helper route which existed
   before 0.41.6: bulldoze only the explicitly named roots, wait until those
   roots retire, then call `buildConstruction` at the captured absolute
   transform. The useful 0.41.6 correction is retained: the barrier excludes
   the town-road/track topology which only the eventual construction can
   replace.
2. Typed module hydration never forwards repository tables by reference.
   Captured portable metadata is retained; missing resource metadata and
   dynamic update-script parameters are copied into a bounded, acyclic,
   scalar/table-only graph. Opaque userdata, functions, threads, cycles,
   non-finite numbers, and oversized graphs reject before the native factory,
   allowing a safe helper fallback.

This deliberately gives up single-command atomicity for the collateral case.
The helper lane remains ordered and blocks later physical work while it clears
and builds, so no other player action can interleave. If demolition succeeds
but the later helper build rejects, consensus still faults closed because the
native world mutated; it never reports a false successful transaction.

## Regression contract

The reconstructed live transaction now proves:

- collateral builds are not classified as typed exact replay;
- only the two construction roots are part of the clearing barrier;
- the replaced road edge is excluded from that barrier;
- ordinary isolated typed construction replay remains available;
- resource metadata and update-script parameters are deep-copied rather than
  aliased; and
- an opaque nested resource value is rejected before the native command
  converter.

Focused model and runtime-module suites pass. The full repository suite must
pass before packaging, and the remaining live gate is one fresh two-computer
bus/tram terminal placement across buildings followed by a truck-terminal
placement through the same generic helper route.
