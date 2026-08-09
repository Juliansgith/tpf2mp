# Local passenger feeders and portable carriers

Date: 2026-08-09 (Europe/Amsterdam)  
Prototype: `0.33.0-alpha`  
State schema: `29`  
Economy model: `8`

> Superseding audit: this `0.33` slice proved the portable codec and replay,
> but its ordinary stock-GUI normalizer still filtered model names to
> `vehicle/train/` and `vehicle/waggon/`. Prototype `0.34` closes that live-click
> boundary and adds fail-closed capture limits, replacement re-registration,
> and 32 more parity scenarios. See
> [the portable stock-vehicle capture audit](PORTABLE_STOCK_VEHICLE_CAPTURE_AUDIT_2026-08-09.md).

## Outcome

Same-town passenger routes are no longer an unsupported line shape. They
register into one canonical `market:local:*` market per town, retain exact
company/carrier/stop metadata, earn completed-trip passenger revenue, and feed
the same canonical town-growth ledger as an intercity route without counting a
same-town trip twice.

The portable operation path is carrier-neutral: vanilla, data-only mod, and
mod-namespaced `vehicle/*.mdl` resources use the same buy/replace/assignment,
finance, physical-result, and checkpoint contracts. Automated fixtures now
cover rail, bus, truck, tram, ship, plane, and a mod namespace. This is not a
claim of live non-rail proof; only stock rail has been bought, assigned, and
observed moving through two ordinary game processes.

A read-only audit of the installed Build 35924 `res/models/model.zip` confirms
the production metadata shape used by the classifier: `ecitaro_v2.mdl` is
`ROAD` with 68 seats, `ktm_1_v2.mdl` is `TRAM` with 100,
`ae_4_7_v2.mdl` and `3axes_person_v2.mdl` are `RAIL` (the coach has 56),
`damen_ferry_v2.mdl` is `WATER` with 400, `airbus_a320_v2.mdl` is `AIR`
with 148, and `40_tons_universal_v2.mdl` is `ROAD` with named alternative
cargo loads. ROAD therefore needs the passenger-market test as well as its
carrier value; a truck cannot become a feeder merely by sharing that carrier.

## Model-v8 feeder rule

A local service provides access to an intercity service only when all of these
are true:

- both services belong to the same canonical company;
- the local passenger carrier is `ROAD` or `TRAM`;
- its route contains at least two distinct canonical station groups;
- it is enabled and has positive hourly capacity;
- one of its station groups is exactly the intercity endpoint station group;
- its canonical town is the corresponding intercity endpoint town.

The benefit is recomputed from authored services at every settlement. It is
not persisted as a cache and therefore cannot survive assignment, capacity, or
enablement changes accidentally.

For each connected intercity endpoint:

```text
frequency cents = floor(90000 / feeder headway seconds)
access cents = min(150, feeder hourly capacity, frequency cents)
```

The maximum is therefore `$1.50` per endpoint and `$3.00` per two-ended
corridor. This amount joins comfort as a subtraction from passenger generalized
cost. Multiple local services at one endpoint use the best value rather than
adding together. A token low-frequency or low-capacity shuttle receives only
the weaker value; duplicate-service spam, rival feeders, cargo lines, disabled
lines, and zero-capacity lines receive no benefit.

The result exposes `baseComfortCents`, `feederAccessCents`, and
`feederAccessEndpoints`. The standard line projection reports the endpoint
count and exact cost reduction. Model versions 2 through 7 retain their old
factor shape and arithmetic when replayed explicitly; loading a current save
migrates it to model 8 as expected.

## Synchronization throughput policy

Every urban curb stop cannot afford an all-peer TCP barrier. The presentation
ledger already boards and alights passengers only at route endpoints, so the
native vehicle policy now follows the authored boundary:

- road/tram passenger services synchronize at first and last route stops;
- freight synchronizes at its exact contract source and destination indices;
- rail, water, air, mixed/unknown, and not-yet-registered services retain the
  conservative every-stop policy.

An intermediate road/tram stop passes without emitting a synchronization
intent. Reaching one while a vehicle is still held or release-armed is a fatal
state contradiction rather than an implicit release. This reduces normal
urban network traffic while keeping unsafe or unreadable carriers fail-closed.

## Protocol integrity

`line.register` now validates local/corridor scope, carrier, two canonical
endpoint towns, and the canonical station-group route in the companion. The
endpoint towns must exactly match the market metadata, local scope requires one
town, and corridor scope requires two. The validation lives in
`line_registration_protocol.py`, keeping the main protocol module below its
existing source budget.

## Automated evidence

The complete repository gate passes:

- `121/121` core Lua tests;
- `76/76` cross-language economy scenarios spanning v2-v8;
- `2/2` freight parity steps and 256 deterministic freight stress steps;
- runtime, game-script, ownership, GUI, hot-seat, network-company, and
  1,024-event replay integrations;
- `129/129` Python protocol/network/checkpoint/recovery/report tests;
- all source-boundary, Lua/PowerShell syntax, release-manifest, watcher, and
  checkpoint-replay gates.

Specific regressions prove same-town market construction, carrier aggregation,
full same-town growth credit, ROAD/TRAM endpoint-only synchronization,
unregistered every-stop fallback, company isolation, frequency/capacity
scaling, non-stacking, disabled/zero-capacity exclusion, strict metadata
rejection, UI projection, and Lua/Python v8 parity.

## Live boundary

The next focused ordinary-UI test should use two game processes and one town:

1. Build a two-or-more-stop bus or tram line whose final stop shares the exact
   station group of an existing intercity passenger line.
2. Buy and assign the road/tram vehicle through its stock depot UI.
3. Confirm both peers show one local market/service, matching carrier and
   capacity, and the intercity line reports one connected feeder endpoint.
4. Run through an intermediate stop and both endpoints. The intermediate stop
   should not pause for peer rendezvous; both endpoints should.
5. Settle one completed local leg and one completed intercity leg, then compare
   balances, loads, station queues, market shares, and the final checkpoint.
6. Disable or unassign the feeder and confirm the next settlement removes its
   access benefit.

Ship/air purchase and assignment remain separate live gates. Their every-stop
barrier is intentionally conservative until real route behavior is measured.
