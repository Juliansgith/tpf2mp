# TPF2MP 0.41.7-alpha

This release replaces the unsafe collateral-terminal replay introduced in
`0.41.6-alpha`. Relay session `mp-5e5d4c732aae691e` produced a native access
violation while Player 2 materialized Player 1's modular bus terminal. State
schema 34, checkpoint format 5, proposal format 7, operation format 4, economy
model 10, and native hook 0.19.0 are unchanged.

## Native crash containment

- Fresh constructions with explicit building collateral no longer enter the
  typed `ConstructionEntity` command factory which crashed Build 35924 before
  `BuildProposalVisitor` or native authorization could run.
- They use the ordered staged helper path: remove only the explicitly declared
  construction roots, wait for those roots to retire, then build at the exact
  captured transform.
- The useful `0.41.6` barrier correction remains. A road or track replaced by
  the eventual construction is not mistaken for pre-build collateral, so the
  helper cannot wait for an edge that only its blocked build can remove.

## Pointer-free module replay

- Typed construction hydration no longer forwards engine-owned repository
  tables directly into the native Lua-to-command converter.
- Metadata and dynamic update-script parameters are copied into a bounded,
  acyclic scalar/table-only graph. Captured instance metadata remains
  authoritative over generic resource defaults.
- Opaque userdata, functions, threads, cycles, non-finite values, and oversized
  resource graphs reject before the native factory and may use the safe helper
  fallback instead of risking an uncatchable engine exception.

## Evidence and verification

- The exact crash dump is 562,204 bytes with SHA-256
  `d458346d400d74b6bf3049f16f2dcbc0331b16fc952182f7b555bb17da4e110e`.
  Its failing instruction is in the engine's recursive Lua table iterator;
  native-hook evidence records zero BuildProposal visitor calls.
- Regression coverage reconstructs the live terminal, two demolished town
  buildings, replaced road, and generated access topology; it proves helper
  routing and collateral-only barrier membership.
- Module tests prove hydrated data has no repository-table aliases and reject
  an opaque nested value before native conversion.
- The complete Lua, Python, cross-language parity, game-script integration,
  launcher/updater, relay, recovery, packaging, syntax, and architecture suite
  passes.

Both players must install `0.41.7-alpha`. Mixed versions remain unsupported,
and the already-crashed `0.41.6` session cannot be resumed safely.
