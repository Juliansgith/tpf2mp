# TPF2MP 0.42.3-alpha

This release repairs modular street-terminal placement after the ownership
hardening introduced in 0.42.2. Gameplay authority remains state schema 34,
checkpoint format 5, construction proposal format 7, operation format 4,
economy model 10, and native hook 0.19.0.

## Canonical construction ownership

- Exact construction replay now carries a separate immutable edge-owner plan
  derived from the validated canonical transaction before native expansion.
- Private entrance edges are assigned to the peer-local representative of the
  building company. Public split-road edges are explicitly cleared to owner
  `-1`.
- Missing private `PlayerOwned` components are recreated through the supported
  local typed factory.
- Captured and generated ownership userdata are never treated as authority.
  Build 35924 may mutate those objects while expanding a construction.
- Incomplete, tampered, or non-round-tripping owner plans continue to reject
  before an unsafe native command can commit.

This fixes the clean modular bus-terminal rejection observed in relay session
`mp-4eda75851212bd35`. That session remained synchronized and unchanged; the
fault was local exact-replay validation, not relay transport or consensus.

## Regression protection

- A dedicated adversarial suite covers engine-mutated ownership, missing
  ownership components, polluted public roads, and mismatched canonical plans.
- Connected passenger-bus, passenger-tram, and cargo-truck terminal modes all
  pass exact topology and ownership replay.
- The existing 216-case vanilla street-terminal matrix still covers every
  type, platform count, length, and tram-mode combination.
- Architecture checks now forbid restoring the old engine-userdata ownership
  precondition or dropping the complete canonical owner plan.

## Validation

- 147 Lua model/codec tests, 7 transport-network tests, and 3 alpha-readiness
  tests pass, together with the new exact-construction ownership suite.
- Cross-language parity, the 256-step freight stress run, the 1,024-event
  deterministic replay, launcher/lifecycle/package tests, and all 225 Python
  companion, relay, and recovery tests pass.
- The release archive is built from a clean exact commit, SHA-256 signed, and
  verified through the transactional install/uninstall test.

Both players must install `0.42.3-alpha`. Mixed versions remain unsupported.
