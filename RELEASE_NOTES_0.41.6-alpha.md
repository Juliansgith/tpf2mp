# TPF2MP 0.41.6-alpha

This release fixes the street-terminal partial-build fault observed in relay
session `mp-748086c41a5e1f9f`: a terminal could demolish the buildings in its
footprint but never place the station. State schema 34, checkpoint format 5,
proposal format 7, operation format 4, economy model 10, and native hook
0.19.0 are unchanged.

## Atomic connected-terminal placement

- Fresh non-depot constructions now keep their explicit building demolition,
  connected road replacement, construction, and generated access topology in
  one native GUI `BuildProposal`.
- This restores the stock transaction boundary: the complete terminal applies
  once on both peers, or the unchanged proposal rejects on both peers.
- Construction placement uses the native soft-collision path only when the
  canonical transaction explicitly names collateral removals. The exact native
  removal vector is still verified before acceptance.

## Fail-closed fallback

- An atomic construction which cannot be materialized no longer degrades to a
  staged helper that can bulldoze only part of the site.
- Helper-only construction classes now wait exclusively for the collateral
  roots they actually bulldozed. Road and track inputs that belong to the
  eventual construction proposal cannot deadlock the pre-build barrier.

## Verification

- A regression fixture reconstructs the live modular bus-terminal transaction:
  two town buildings, one replaced town-road edge, two new nodes, and three
  station/access street edges.
- The fixture proves atomic GUI routing, resource-hydrated module metadata,
  exact collateral materialization, strict fallback refusal, and filtered
  helper barriers.
- The complete Lua, Python, cross-language parity, game-script integration,
  launcher/updater, relay, recovery, packaging, syntax, and architecture suite
  passes.

Both players must install `0.41.6-alpha`. Mixed versions remain unsupported.
