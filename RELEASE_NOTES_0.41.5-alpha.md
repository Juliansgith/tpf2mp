# TPF2MP 0.41.5-alpha

This release repairs large bus, tram, and truck terminal placement observed in
relay session `mp-23bcbc168adb0862`, and removes an over-broad restriction on
road/tram depot connections. State schema 34, checkpoint format 5, proposal
format 7, operation format 4, economy model 10, and native hook 0.19.0 are
unchanged.

## Modular street terminals

- Build 35924 projects a native module `MetadataMap` into the GUI capture as
  the exact opaque sentinel `<userdata>`. The construction codec previously
  rejected that resource-owned value before a proposal could reach the relay,
  so every large street-terminal click disappeared even on flat empty ground.
- The codec now recognizes only that exact module-metadata sentinel. It carries
  a portable empty map, then resolves each content-attested module name through
  `api.res.moduleRep` immediately before native replay and restores the module's
  metadata and dynamic update script from the local resource.
- Other opaque or truncated values remain rejected. Data-driven mod modules use
  the same named-resource path; arbitrary executable callbacks are not admitted.

## Road and tram depots

- Stock road depots and both electric/non-electric tram-depot variants retain
  their separate non-modular `STREET_DEPOT` construction path.
- A blanket depot endpoint guard has been narrowed to its real safety case:
  hidden rail-depot snapping onto existing track. Road and tram depots may now
  reconstruct their declared street snap directly against synchronized road
  geometry.
- Rail depots attached directly to existing track remain fail-closed. Place the
  rail depot clear of track, wait for synchronization, and connect it afterward.

## Verification

- All 216 combinations of six vanilla bus/tram/truck terminal templates, four
  platform counts, three lengths, and three tram modes accept the live metadata
  shape.
- Typed replay preserves repository-provided custom metadata and dynamic update
  scripts while a different opaque sentinel remains rejected.
- Isolated road depot, non-electric tram depot, electric tram depot, and a road
  depot snapped to an existing road pass Lua/Python parity; the equivalent rail
  track snap remains rejected.
- The full Lua, Python, cross-language parity, game-script integration,
  launcher/updater, relay, recovery, packaging, syntax, and architecture suite
  passes.

Both players must install `0.41.5-alpha`. Mixed versions remain unsupported.
