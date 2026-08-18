# Behavior-preserving runtime performance pass

Date: 2026-08-19 (Europe/Amsterdam)

Scope: reduce TPF2MP's CPU, Lua/native-boundary, filesystem, and GUI overhead
without changing simulation results, economy rules, network ordering, vehicle
release policy, ownership, command acceptance, or content.

## Outcome

This pass removes repeated work from all four runtime layers. It deliberately
does not claim a live FPS result: the games were not launched while this work
was implemented. The fresh two-instance run remains the measurement gate.

The most important host-specific change is the economy scheduler. Player 1
previously built the full diagnostic clock snapshot on every running engine
update: native game speed, native game time, and a year/month/day table. The
scheduler needs only game time. It now performs one scalar native time read and
uses the exact same comparison against `nextBoundaryGameTimeSeconds`.

## Changes

### Engine/game script

- Core and model digests now share one authored-state projection. Checkpoint
  export also hashes the model, canonical map, and vehicle-sync view it already
  constructed instead of rebuilding them through `coreDigest()`.
- Proposal construction and finance workers retain an indexed active set. An
  idle 100-call regression performs one table scan, then sleeps until the
  proposal generation changes or the worker is explicitly invalidated.
- Network pumping skips settled clock maintenance and an empty deferred-intent
  processor. Disabled validators and disabled operational capture no longer
  cross protected-call boundaries every update.
- The vehicle synchronizer caches the sorted canonical vehicle list by the
  canonical registry revision. Each managed vehicle now has one protected
  boundary and one coherent component read rather than a component `pcall`
  plus four field-closure `pcall`s.
- Runtime measurement remains available, but native high-resolution timers are
  sampled: the first four calls and then one in eight. A 20-call regression
  records six samples and twelve clock reads rather than forty.

### GUI

- Proposal and operation replay use generation-aware work indexes. Empty
  queues no longer sort retained histories every rendered frame.
- Vehicle/build replay workers are not entered when their machine-local queues
  are empty.
- Authored toolbar text is cached for an unchanged snapshot. The safety scan of
  stock entity windows is event-driven with a 1,800-frame fallback; toolbar
  projection has a 60-frame fallback.
- Shared-speed button inspection has a 30-frame repair cadence. Ordered speed
  changes still project immediately; only detection of a stock-widget visual
  inconsistency can wait up to that fallback.

### Native hook

- Empty `CommandList::Swap` calls continue updating in-process counters but no
  longer wake the JSON status writer.
- Replaceable hook-status files are written without `MOVEFILE_WRITE_THROUGH`.
  Their maximum cadence is now one per second instead of four per second.
- Durable numbered bridge messages retain write-through behavior. No command,
  consensus, checkpoint, or audit record was weakened.

### Companion

- Replaceable `companion_status.json` writes skip `fsync`; durable queues and
  audit files still flush normally. Host/client status cadence is one second.
- Anchor requests are polled twice per second and content facts once per
  second. These are discovery/status paths, not ordered commit consumption.
- Client inbound commit history, host anchor history, and consensus tracker
  registries now use incremental indexes. Repeated readiness, reconnect, and
  timeout checks no longer re-read or sort complete session history.
- Unchanged restore plans are rejected by size/mtime signature before JSON
  reading and cryptographic/protocol verification.
- Timeout passes visit pending proposal, operation, checkpoint, and clock
  trackers only.

## Preserved invariants

- Native bridge commit consumption remains at `networkBridgeStride = 1`.
- Economy epochs remain automatic five-minute game-time boundaries with the
  same authored action and comparison.
- Vehicle station observation, holds, releases, schedules, and all-peer
  rendezvous are unchanged.
- Shared speed, pause, ownership, build/operation gates, cargo/passenger math,
  town growth, and finance are unchanged.
- Only replaceable diagnostic/status files use non-durable publication.
  Numbered messages, receipts, saves, restore plans, and the authority audit
  remain durable.

## Automated proof

The focused checks cover:

- identical paired versus separate core/model digests;
- one idle scan across 100 engine-worker and GUI-worker calls;
- immediate wake-up on a new generation;
- sampled profiler call counts;
- one inbound-directory scan across 50 repeated client cursor reads followed
  by incremental advancement;
- no `fsync` for replaceable status and retained `fsync` for durable writes;
- exact scalar economy-clock reads, including host-only and disconnect paths;
- clock/proposal/checkpoint timeout behavior after active-index conversion.

The complete acceptance run passed after the final GUI-index fixes:

- 135/135 core Lua tests, 7/7 transport-network tests, and 3/3 alpha-readiness
  tests;
- all cross-language economy, freight, checkpoint, and 1,024-event replay
  vectors;
- game-script, network, hot-seat, GUI, launcher, packaging, install/update, and
  recovery integration suites;
- 181/181 Python tests;
- both native CTests plus the exact 17-signature Build 35924 executable gate;
- Lua, investigation-Lua, and PowerShell syntax checks, source-size boundaries,
  and release-manifest validation.

## Fresh two-instance check

Use a new launcher-created session tomorrow; old running processes cannot load
the rebuilt hook or Lua modules.

1. Leave both worlds paused and untouched for 60 seconds. Record Player 1 and
   Player 2 FPS with the multiplayer window closed.
2. Run speed 3 for five minutes with one passenger train. Confirm continuous
   movement, one automatic economy settlement, matching clock behavior, and no
   synchronization fault.
3. Open the train, station, line manager, and multiplayer panels for about 20
   seconds each. Check that static panels no longer continuously re-layout or
   pulse, and record the lowest stable FPS.
4. Place one ordinary station and a short connected track section. Confirm the
   preview may still be expensive while native geometry is calculated, but FPS
   returns after placement and the result appears once on both peers.
5. Add a second train, run another five minutes, then pause one peer with Escape
   for 30 seconds and resume. Confirm both trains wait/recover as before.
6. Export Research on both peers. The report contains the sampled runtime task
   counters and native-bridge queue/status evidence needed to compare the host
   and client without relying only on visual FPS.
