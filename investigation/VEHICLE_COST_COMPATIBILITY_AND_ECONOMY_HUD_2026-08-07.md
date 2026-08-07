# Vehicle cost compatibility, speed incentive, and economy HUD

Date: 2026-08-07 (Europe/Amsterdam)

Status: implemented and offline-tested; fresh two-process visual/economic
acceptance remains.

The cost-capture findings remain current. Cadence, upkeep conversion, revenue,
and HUD-period wording are superseded by
[Five-minute delivered economy](FIVE_MINUTE_DELIVERED_ECONOMY_2026-08-07.md).

## Decision

TPF2MP no longer assigns every vehicle an invented purchase-price ratio when
the engine already has the final mod-resolved annual maintenance value. A
successful canonical purchase now has two distinct authoritative facts:

1. the native wallet delta is the exact purchase price actually paid;
2. `MAINTENANCE_COST.maintenanceCost` on the resulting vehicle is the exact
   annual upkeep after the active vanilla/mod resource pipeline.

Both enter the physical completion record. Completion digests must agree across
peers before the economic record is admitted. This makes a different vehicle
mod, load order, or economy modifier a consensus failure rather than a hidden
balance divergence.

The same reader updates replacements and uniquely canonical pre-existing
vehicles. Sale removes the annual cost stock. Purchase-price divided by six is
retained only to migrate or fail-soft an old record for which the component is
unavailable.

## Resource scope

The operation protocol previously allowed only `vehicle/train/` and
`vehicle/waggon/`. Buy/replace now accepts a bounded, traversal-free
`vehicle/*.mdl` resource, resolves it through each peer's model repository, and
validates its actual transport compartments/load configurations. The rule is
category-neutral and therefore covers vanilla or data-only mod trains, wagons,
buses, trucks, trams, ships, and aircraft without a resource allow-list.

This is a code-path claim, not a live-proof claim. Railway purchase/assignment/
movement has human two-process evidence; the other carriers still need the same
ordinary-widget acceptance.

## Why a faster train has value

The limiting top speed of the complete consist feeds the registered service:

```text
cruise speed = limiting top speed * 70%
one-way journey = route distance / cruise speed + 45 s per stop
cycle = 2 * one-way journey + 240 s turnaround
headway = max(60 s, cycle / number of consists)
fleet departures per authored hour = floor(3600 / headway)
hourly seat capacity = seats per consist * fleet departures
```

The earlier capacity expression also multiplied by fleet count after headway
had already divided by fleet count. That made two trains look like four times
the capacity. Prototype 0.25 removes the second multiplication and adds a
regression proving that faster consists improve journey, headway, departures,
and capacity without quadratic fleet inflation.

Journey and half-headway wait time become money-valued generalized cost. A
faster service therefore:

- wins share from a rival at the same fare;
- wins share from the ever-present outside/not-travel option even when it is
  the only operator;
- can serve more demand if the faster cycle adds a departure;
- has additional fare headroom before reaching the outside option's generalized
  cost.

Fare is not raised automatically. If an exclusive route already captures
nearly all demand, has spare capacity, and a speed step does not add a departure,
the upgrade can rationally be unprofitable. That diminishing return is
intentional: the player compares added native capital/upkeep against induced
demand, capacity relief, and manually chosen fare headroom.

## UI contract

The stock buy/detail UI remains the source presentation for native purchase and
annual maintenance. TPF2MP consumes the resulting component rather than
overwriting resource prices. Prototype `0.26` projects the competitive layer
into the normal account, earnings, vehicle, line, station, manager, finance,
and statistics surfaces. The legacy selection-aware `TPF2MP ECO` row is now a
fallback only:

- selected vehicle: exact purchase price, annual upkeep, hourly upkeep, and
  assigned-line gross/net;
- selected line: fare, diagnostic outside-parity fare, limiting speed, journey,
  headway, gross, fleet upkeep, and line net;
- no selection: active company's gross, vehicle cost, infrastructure cost, and
  net for the latest authored hour.

The outside-parity fare is explanatory, not an optimizer. Crowding, discrete
capacity, competing services, share glide, and future fare changes still affect
the profit-maximizing choice.

The floating native arrival income remains cosmetic because it is rendered by
the engine outside the supported GUI component tree. Native historical revenue
is hidden or explicitly labelled cosmetic. Canonical accounts are reconciled
back to the authored result, and standard windows now present the figures that
actually move competitive cash and score. See
`STOCK_UI_AUTHORITATIVE_REPLACEMENT_2026-08-07.md` for the complete matrix.

## Starting capital

New matches now default to `$50,000,000`, with `$25m`, `$50m`, and `$100m`
presets. Vehicle purchase prices are not discounted: an `$8m` train still costs
`$8m`. The larger default makes 1990 rolling stock practical while preserving
capital allocation as a real strategic choice.

## Source and verification boundary

Transport Fever 2's model resource documentation defines price and running-cost
fields/scales and permits automatic values; the engine component API exposes
`MAINTENANCE_COST`. The UI API documents both `vehicleManager/accept` and stock
component extension via `api.gui.util.getById`/`guiUpdate`:

- https://wiki.transportfever2.com/doku.php?id=modding%3Aresourcetypes%3Amdl
- https://wiki.transportfever2.com/api-testing/modules/api.type.html
- https://wiki.transportfever2.com/doku.php?id=modding%3Auserinterface

Offline coverage includes Lua/Python generic-resource validation, traversal
rejection, consensus-native purchase costing, replacement refresh, sale cleanup,
pre-existing vehicle backfill, public-view projection, all three selection
contexts, and the corrected linear capacity formula. A fresh two-process test
must still compare the stock annual value with the authoritative standard-window
panel, settle parked and running vehicles, and exercise at least one economy-
modified or data-only mod vehicle.
