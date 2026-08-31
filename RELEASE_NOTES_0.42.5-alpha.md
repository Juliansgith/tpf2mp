# TPF2MP 0.42.5-alpha

This patch fixes a second-station regression introduced by the native selector
safety guard in `0.42.4-alpha`. Gameplay authority remains state schema 34,
checkpoint format 5, construction proposal format 7, operation format 4,
economy model 10, and native hook 0.19.0.

## Station replay correction

- Fresh construction graphs whose edges use only transaction-local node slots
  no longer require a GUI engine-component reader. There is no live canonical
  endpoint to inspect in that shape.
- The last-moment `BASE_NODE` preflight remains mandatory and fail-closed when
  a new edge actually attaches to a canonical node.
- Build 35924 callable function/table/userdata API wrappers are accepted instead
  of being mistaken for a missing plain Lua function.

This fixes relay session `mp-2b831d5eac67c488`. Its first modular station
completed normally. The second station first removed two collateral
constructions, then both peers rejected its slot-local graph with `canonical
node preflight API is unavailable`, producing the correct fail-closed
`native-rejection-mutated-prepared-core` outcome.

## Regression protection

- GUI coverage now exercises a staged fresh station with collateral demolition,
  slot-only endpoints, and no component API.
- Separate cases retain missing-API rejection for a true canonical attachment,
  callable-wrapper acceptance, and disappeared-node rejection.
- Existing selector suspension, atomic collateral, connected terminal, topology,
  ownership, relay, economy, and recovery suites remain part of the release
  gate.

## Public alpha documentation

- `docs/PUBLIC_ALPHA_GUIDE.md` gives Player 1 and Player 2 the complete first
  install, world/mod settings, relay launch, healthy save/continue, fault
  recovery, and Discord `#bugs-logs` flow.
- The guide distinguishes the safe public `mp-...` support ID from the secret
  full join code.

Both players must install `0.42.5-alpha`. Mixed versions remain unsupported.
