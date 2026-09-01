# TPF2MP 0.41.9-alpha

This release fixes the staged street-terminal failure observed in relay
session `mp-38e37ebd38deb5e2`. Both peers demolished the same two obstructing
houses, but Build 35924 exposed the entrance module's empty metadata map as
opaque userdata and rejected the typed terminal stage. State schema 34,
checkpoint format 5, proposal format 7, operation format 4, economy model 10,
and native hook 0.19.0 are unchanged.

## Build 35924 module-map compatibility

- The exact top-level opaque `MetadataMap` used by stock construction-module
  resources is now represented by a fresh empty Lua map when the captured
  canonical module metadata is empty.
- Dynamic update-script parameter maps use the same bounded representation
  rule.
- The engine-owned userdata itself is never forwarded into the native command
  converter. Plain resource tables are still copied into a fresh pointer-free
  graph.
- Functions, threads, nested userdata, cycles, non-finite numbers, and
  oversized resource graphs remain rejected fail-closed.

## Pre-demolition validation

- Staged exact construction now resolves and validates every module resource
  before demolishing any declared collateral.
- A deterministic metadata or update-script shape failure therefore rejects
  while the native world is unchanged and rolls back commit-time lazy
  bindings, instead of leaving a half-applied transaction that faults the
  match.
- GUI replay performs the same hydration again when it creates the typed
  proposal. Loaded-content attestation keeps the resource facts immutable
  between the preflight and native stages.

## Failure semantics

The existing `native-rejection-mutated-prepared-core` guard remains strict.
Two peers displaying the same partial demolition is not enough to prove that
canonical identities, topology, finance, and retained native bindings are
coherent. This release prevents the observed deterministic failure before
that irreversible boundary; it does not disguise arbitrary partial native
mutations as successful or unchanged transactions.

## Verification

- Regression coverage uses real Lua userdata for the top-level module metadata
  and update-parameter containers and proves that only fresh empty maps cross
  the native boundary.
- Staged collateral tests prove safe content passes preflight and unsafe
  content rejects before demolition.
- The complete Lua, Python, cross-language parity, game-script integration,
  launcher/updater, relay, recovery, packaging, syntax, and architecture suite
  passes; the main Lua model/codec suite passes `143/143`.

Both players must install `0.41.9-alpha`. Mixed versions remain unsupported.
The already-faulted `mp-38e37ebd38deb5e2` session crossed the old irreversible
boundary and cannot be resumed as an unchanged rejection.
