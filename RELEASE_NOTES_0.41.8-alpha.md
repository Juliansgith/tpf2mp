# TPF2MP 0.41.8-alpha

This release completes the crash-safe street-terminal path introduced in
`0.41.7-alpha`. Relay session `mp-e6cf454422150229` proved that the helper-only
containment could place a terminal and demolish its obstructing buildings, but
could not reproduce the captured split of the adjacent town road. State schema
34, checkpoint format 5, proposal format 7, operation format 4, economy model
10, and native hook 0.19.0 are unchanged.

## Connected collateral terminals

- A construction which removes buildings now uses two bounded native stages.
  Engine state first retires only the explicitly captured construction or asset
  roots. GUI state then issues the exact typed terminal proposal after those
  crash-prone live roots are absent.
- The second stage deliberately omits already-demolished construction IDs while
  retaining the original road or track removal, replacement nodes and edges,
  station entrance, construction transform, parameters, and hydrated modules.
- Bus, tram, and truck terminals can therefore retain their native road snap
  and path connectivity instead of merely appearing beside the road.
- The proposal work generation is advanced at the stage boundary, preventing
  either the GUI or engine work index from sleeping past the exact replay.

## Failure safety

- The post-demolition structural snapshot is the baseline for exact delta
  attestation; removed collateral is never mistaken for an unexpected part of
  the typed command.
- If materialization or the native second stage fails, the proposal cannot
  claim that the original PREPARE world is unchanged. It faults for verified
  restore rather than taking an invalid lazy-binding rollback path.
- Immediate typed construction, helper-only depot/upgrade/removal behavior,
  native soft-error handling, ownership, and one-time finance normalization are
  unchanged.

## Verification

- Regression coverage reconstructs the live two-building terminal and proves
  that staged materialization contains zero construction removals while the
  captured town-road split remains present.
- Runtime and GUI tests prove the post-collateral requeue, fresh attestation
  baseline, exact native route, and fail-closed rejection semantics.
- The complete Lua, Python, cross-language parity, game-script integration,
  launcher/updater, relay, recovery, packaging, syntax, and architecture suite
  passes; the main Lua model/codec suite passes `143/143`.

Both players must install `0.41.8-alpha`. Mixed versions remain unsupported.
The already-faulted `mp-e6cf454422150229` session contains a partial physical
build and cannot be resumed as an unchanged rejection.
