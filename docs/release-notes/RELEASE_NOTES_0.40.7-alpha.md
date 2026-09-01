# TPF2MP 0.40.7-alpha

This release closes the disconnected-station passenger-revenue exploit and an
ordering race between physical construction consensus and synchronized train
departures. It also restores road/track builds that demolish ordinary
buildings, and hardens launcher teardown. Save state remains schema 32,
checkpoint format 5 and native hook 0.19.0; the authored economy advances to
model version 10.

## Passenger service now requires real access

- A passenger line is economy-eligible only when both endpoint station groups
  reach at least one building in their bound town through the native station
  street-catchment graph.
- Disconnected lines may still run cosmetically and continue to incur vehicle
  upkeep, but receive no modeled passengers, revenue, passenger-network edge,
  or town-growth credit. Their authored queues and onboard presentation are
  retired.
- Missing or unreadable native catchment data fails closed. The ordered
  `line.register` payload carries readiness and bounded building counts, and
  the companion binds those counts, the eligibility flag, and the service's
  enabled state into one validated contract.
- Successful street, station, construction, and conservative edge-removal
  changes automatically schedule a coalesced re-registration after physical
  consensus. Connecting an isolated station can therefore enable its line;
  cutting its last access road disables it without a manual market action.
- The Multiplayer panel identifies disabled services and shows both endpoint
  reachability counts.
- Economy v2-v9 saves remain readable. Existing passenger services without the
  new proof are quarantined and have their delivery cursor cleared until their
  owning peer re-registers them, preventing one legacy payout after loading.

## Construction and train ordering fixes

- Road and track proposals that remove houses or other constructions as
  collateral remain classified as their actual transport tool. They no longer
  fail the preview correlation as a stale construction-tool click merely
  because demolition is included atomically.
- Construction additions remain construction actions, and pure construction
  removal remains a bulldozer action, preserving the existing fail-closed
  family boundary.
- A train ready to leave a station now waits behind any active proposal or
  vehicle-operation consensus and the resulting all-peer checkpoint. Its
  release receives the next authored sequence only after that boundary closes.
  This prevents peers from snapshotting the same successful build on opposite
  sides of a train-state mutation and falsely faulting on different core
  digests.

## Lifecycle hardening

- Exact-session teardown now treats a process that exits after identity
  verification as a successful stop instead of turning the harmless
  `Stop-Process` race into a launcher cleanup failure. PID reuse remains
  protected by the existing executable/session/peer checks.

## Compatibility and verification

- Both players must install `0.40.7-alpha`; mixed versions are unsupported.
- The already-faulted session that exposed the ordering race cannot be repaired
  by installing this build. Start a fresh session from its original save or an
  earlier verified recovery point.
- Automated verification covers 140 Lua unit cases, 7 transport-network cases,
  109 Lua/Python economy-v2-v10 parity scenarios, 202 Python tests, the
  1,024-event replay, protocol and consensus integration, source boundaries,
  syntax, relay and launcher lifecycle checks. Exact-build live proof of the
  new catchment reader and the road-build/train-arrival overlap remains the
  release's first two-computer acceptance run.

Keep the launcher open while playing; closing it is intentionally equivalent
to **Stop session**.
