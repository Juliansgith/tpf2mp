# TPF2MP 0.41.4-alpha

This release makes normal multiplayer saves continue as the same canonical
match and removes stock Line/Vehicle Manager pause churn. It advances the state
schema from 33 to 34; checkpoint format 5, operation format 4, economy model
10, and native hook 0.19.0 are unchanged.

## Exact-save match continuation

- Hosting a clean, initialized multiplayer save now preserves both companies'
  authoritative balances, loans, transaction history, economy state, services,
  ownership, and canonical line/station/vehicle bindings. A new relay room no
  longer turns that save into a fresh $50M match.
- Host and Join attest the exact synchronized save/content fingerprint, rebuild
  loaded-industry content agreement for the new room, and attest the migrated
  core digest before a mandatory two-peer checkpoint releases gameplay.
- A save containing a fault, unfinished physical consensus, pending native
  work, or uncustodied origin mutation is refused explicitly. It is never
  silently reset to starting cash.
- A peer-local already-applied capture fault is promoted from schema-4 health
  into one durable all-peer fault after that peer consumes the ordered tail;
  the other game can no longer continue unaware of unsafe native residue.
- Preserving canonical bindings also prevents inherited lines from later being
  rejected as ambiguous when the stock Line Manager edits them.

## Line and vehicle workflow clock

- Engine-generated `SetGameSpeed(0)` calls caused by opening the stock line,
  vehicle, or depot interfaces are no longer mistaken for deliberate player
  pauses. The Esc menu and actual speed controls remain authoritative.
- A running line/vehicle mutation now takes one scoped shared safety hold and
  resumes the prior agreed speed only after its complete physical FIFO,
  follow-up registration, and checkpoint tail have drained.
- A real pause or speed request from either player cancels automatic resume, so
  the safety workflow cannot override player intent.

## Bus, tram, and truck facilities

- Large bus/tram terminals and truck terminals now retain the newest exact
  click while earlier ordered work settles. One latest-only construction lane
  replaces stale pending clicks instead of either discarding the build or
  replaying a backlog of ghost stations.
- The generic portable-construction codec is verified across all six vanilla
  street-terminal templates, every platform/length selection, all three tram
  modes, and collateral building demolition. Mod resources remain data-driven;
  no individual terminal allow-list was introduced.
- Curbside bus/tram stops now capture and event-bind the native station and
  station-group entities derived from their edge object. Ordinary bus/tram
  line creation and subsequent stop edits therefore no longer fault on an
  ambiguous `station_group:pre:*` identity. Stop removal retires those derived
  identities as well.

## Verification

- Regression coverage preserves a non-default company balance together with
  inherited line, station-group, and vehicle bindings on both roles.
- Dirty/faulted continuation, tampered attestation, startup fencing, manager
  modal pauses, explicit Esc/speed pauses, batched operation draining, and
  cross-peer clock cancellation are covered fail-closed. Street-terminal
  portability has an independent 216-case Lua/Python matrix; runtime tests
  cover derived stop identity and bounded latest-only construction ordering.
- The full Lua, Python, cross-language parity, game-script integration,
  launcher/updater, relay, syntax, and architecture-boundary suite passes.

Both players must install `0.41.4-alpha`. Mixed versions remain unsupported.
