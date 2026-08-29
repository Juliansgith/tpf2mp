# Opaque entrance metadata after staged collateral - 2026-08-28

## Live result

Relay session `mp-38e37ebd38deb5e2` attempted one stock modular passenger
street terminal for Company 1. The canonical transaction, digest `6c23d2e4`,
contained two town-building collateral roots, one replaced town road, the
three-edge replacement/access graph, and three station modules. Both peers
removed the two buildings and then rejected the second stage before placing
the terminal.

Both games reported the same native error:

`construction module metadata at slot 20015503 contains non-portable userdata`

The failed completions also matched: result digest `cee22e36`, post-commit core
digest `6b7499bb`, no outputs, and no reported finance delta. The all-peer
PREPARE core was `73b27d9d`, so commit 9 correctly closed the session as
`native-rejection-mutated-prepared-core`.

## Why equal-looking worlds still faulted

The staged transaction had crossed a one-way native boundary. Its first phase
removed live construction entities, while successful finalisation is what
retires their canonical identities, binds the station and replacement road,
and settles finance. A failed second phase therefore leaves more than a visual
result: it leaves a transaction whose intended atomic postcondition was never
authored.

The matching completion core proves the authored projections agree, but it is
not a fresh structural/world-manifest checkpoint and does not cover every
native topology detail. Merely clearing the fault would also preserve lazy
input bindings that may now point at retired native entities. Safe continuation
would require a distinct partial-commit protocol: normalize finance, retire
exactly the proven collateral identities, roll back every retained input
binding, pause both games, and converge fresh structural and world-manifest
witnesses. That protocol does not exist yet; weakening the current guard would
turn an obvious fault into delayed corruption.

## Cause

The entrance module was
`station/street/entrance_exit.module`, slot `20015503`. Build 35924 exposes the
resource descriptor's top-level metadata container as engine-owned userdata.
The GUI capture had already represented the instance metadata as an empty
portable map. Replay nevertheless tried to hydrate that empty map from the
descriptor and passed the opaque container to the pointer-free copier.

Rejecting the pointer was correct: relay session `mp-5e5d4c732aae691e` proved
that forwarding engine-owned resource objects into the recursive Lua-to-native
converter can cause an access violation. Rejecting the complete terminal was
not necessary. The regression fixture supplied descriptor metadata as a plain
Lua table and therefore never exercised the real top-level `MetadataMap` shape.

## Correction

Resource hydration now distinguishes an opaque top-level map container from an
opaque nested value. When the canonical captured map is empty and the local
descriptor exposes its map as userdata, replay retains a fresh empty Lua map.
It never forwards the userdata. Plain resource tables are still deep-copied,
and functions, threads, nested userdata, cycles, non-finite numbers, and
oversized graphs remain rejected.

The same representation rule applies to an opaque top-level dynamic-script
parameter map. Its file name remains content-derived; only the inaccessible
map container falls back to a fresh empty table.

Staged exact construction now runs this entire module hydration pass before
the first collateral demolition. A deterministic resource or update-script
shape failure therefore rolls back commit-time lazy bindings and becomes an
unchanged recoverable rejection. GUI state repeats hydration when it creates
the eventual typed proposal, but the content is locally immutable and already
attested.

## Regression contract

- Real Lua userdata stands in for Build 35924's top-level `MetadataMap` and
  must materialize as a fresh empty Lua table.
- A plain resource metadata/update-parameter graph must still be copied and
  preserve its values without aliases.
- An opaque nested/function value must still reject before the native command
  converter.
- A staged collateral record must pass safe opaque-map preflight before its
  demolition phase and reject unsafe resource content at that boundary.
- Source-size and full repository verification must pass before packaging.

## Remaining recovery work

An identical-partial-mutation recovery lane is feasible, but it must be an
explicit authored partial commit followed by a fresh all-peer checkpoint. It
must not be implemented as a special case that simply ignores
`native-rejection-mutated-prepared-core`.
