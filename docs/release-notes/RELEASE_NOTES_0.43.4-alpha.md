# TPF2MP 0.43.4-alpha

This patch release prevents clean construction rejections from leaving stale
native geometry behind for later road, depot, bulldozer, or station retries.
Gameplay and protocol schema versions are unchanged from `0.43.3-alpha`.

## Native rejection integrity

- Rejection recovery now fingerprints the referenced nodes, edges,
  constructions, edge objects, carrier resources, ownership, and quantised
  geometry. An in-place mutation can no longer hide behind an unchanged entity
  ID set and later reach Build 35924's `StreetGeometry` assertion.
- Every canonical input reference is checked again immediately before replay,
  including pre-existing identity fingerprints and edge endpoint components.
- Raw GUI proposal captures are never retained behind topology-changing work.
  A click made while physical consensus is busy is rejected with a retry
  message; already canonical prepared work retains the bounded FIFO.
- Codec failures, completed replays, and native rejections retire their cached
  construction preview so a later click cannot resurrect an old station or
  edge transaction.

## Station and resource compatibility

- Fresh stock 80 m, one-track modular stations accept the engine's omitted
  zero-valued layout selectors and boolean catenary representation only when
  the exact module set and graph independently prove that default layout.
- Rejected station captures publish bounded scalar diagnostics for observed
  parameters, missing defaults, invalid fields, module count, and template
  match, making external relay reports actionable without uploading native
  proposal payloads.
- Station, road, and track replay remains resource-driven: stable repository
  filenames, construction/module payloads, and exact content manifests cover
  compatible vanilla and data-defined mod resources without a hardcoded list
  of every carrier. Arbitrary scripted native callbacks remain outside this
  alpha's universal compatibility claim.

## Regression evidence

- Focused tests reproduce an in-place edge/node mutation with unchanged entity
  IDs, reject stale pre-existing fingerprints, and prove that raw build clicks
  cannot survive a busy topology boundary.
- Stock station fixtures cover omitted defaults, boolean toggles, invalid
  selectors, non-default module mismatches, and relay-visible diagnostics.
- The complete automated gate passes Lua/Python parity, GUI/native replay,
  network ordering, recovery, packaging prerequisites, architecture budgets,
  and a deterministic 1,024-event replay.

## Supported boundary

This remains a trusted two-player Windows x64 alpha for exact Transport Fever 2
Build 35924. Both players must install `0.43.4-alpha`; mixed versions are
unsupported. Start a fresh multiplayer session after updating.
