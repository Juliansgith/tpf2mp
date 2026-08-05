# Corridor binding: computed service facts, gravity markets, station boards

Date: 2026-08-05 (Europe/Amsterdam)  
Scope: `line.register` now derives its market and service facts from
canonical geometry, town capacities, and consist metadata instead of legacy
line-entity estimates, and the model drives a per-station display layer.
This is the decision-independent engineering identified alongside the
agents-off research: it is correct whether or not native agents remain.

## Architecture: origin-computed, wire-carried

All new arithmetic runs only on the peer that submits `line.register`.
`normaliseForNetwork` already evaluates the facts on a preview state and
embeds the resulting market and service records in the ordered action; every
peer and the companion replay apply the embedded values. Nothing here is
recomputed cross-peer, so floating-point steps (one `math.sqrt` per stop
pair) cannot desynchronize anything, and the Python replayer needed no
changes.

## New module: `tpf2_mp/corridor_binding.lua`

Extracted as its own module because `world.lua` crossed its 2100-line
architecture budget during implementation — the source-size gate forced the
split, as designed. `world.lua` re-exports every entry point
(`M.SERVICE_FACTS`, `M.consistTransportFacts`, `M.computedServiceFacts`,
`M.gravityDemand`, `M.makeLineService`, `M.stationBoards`), so no caller
changed.

### Computed service facts

Inputs, all canonical or repository data: ordered station-group positions
(decimeter integers from the existing `positionOfEntity`), the line's
vehicle count, and one representative consist read from the first vehicle's
`TRANSPORT_VEHICLE.transportVehicleConfig` resolved to portable model names.

Derivation (constants in `SERVICE_FACTS`, all documented in-source):

- route length = euclidean stop-chain distance × 1.25 routing allowance;
- journey = route / (consist limiting top speed × 0.70 sustained) + 45 s
  dwell per stop, floor 60 s;
- cycle = 2 × journey + 240 s turnaround; headway = cycle / vehicles,
  floor 60 s;
- capacity per settlement = seats × vehicles × departures per authored hour
  (`epochSeconds = 3600`).

Consist seats and limiting speed come from
`api.res.modelRep.get(find(name)).metadata.transportVehicle` — summing the
best load configuration per compartment (`compartmentsList`/`loadConfigs`/
`cargoEntries.capacity`, both known shapes handled) and taking the minimum
positive `topSpeed`. `modelRep.get` is **not yet probed on Build 35924**;
the entire chain is fail-soft.

### The fallback ladder, recorded per service

`service.metadata.factsSource` records which path ran, so live sessions can
verify the computed path activates:

1. `computed-consist` — geometry plus repository consist metadata;
2. `computed-default-speed` — geometry with the 100 km/h default when the
   consist cannot be resolved;
3. `estimated-legacy` — the previous frequency/rate estimates when even
   positions are unavailable (also what existing integration fixtures hit,
   which is why no integration test changed).

### Gravity markets

`demand = clamp(capA × capB / (25 × km), 50, 100000)` from the two towns'
land-use person capacities over the corridor's computed distance. Markets
registered this way now carry `kind = "passenger"` and drop the legacy
`outsideWeight`. Nearer, bigger town pairs are worth more; the constants sit
beside the others for the calibration playtests.

### Station boards (Tier-1 presentation)

`stationBoards(economyState, registry)` aggregates, per station group cid on
each registered service: epoch throughput, a momentary waiting estimate
(allocated × headway/epoch — people present in one headway window), and
per-line rows. `line.register` now records the ordered
`stationGroupCids` in service metadata to make that join possible; service
metadata is deliberately outside every digest, and the boards are computed
in `public_snapshot` per peer — display only, never convergence material.

The panel renders the eight busiest stations with log-scale crowd glyphs
(`gui_view.crowdIcons`: one `█` = 500 waiting, `◼` = 100, `▪` = 20, `·` =
fewer) — reading magnitude beats counting sprites, per the overhaul's
information-design direction:

```text
Station Bromborough Central: waiting ~137 ◼▪ | 412 pax/epoch over 2 line(s)
```

## Tests

`tests/run_lua_tests.lua` (51/51): gravity scaling/clamps; exact
journey/headway/capacity numbers for a synthetic two-stop corridor plus a
repeatability digest; consist metadata summation across both compartment
shapes with slowest-part speed limiting and fail-soft on a missing
repository; board aggregation with registry names, cid fallback, and the
waiting-≤-throughput bound; crowd-glyph buckets. Full offline suite passes,
including the cross-language replay (line.register facts travel embedded,
so replay parity is structural).

## Live verification still owed

- Does Build 35924 expose `modelRep.get` with `metadata.transportVehicle`?
  Register a real line and read `factsSource` from the service metadata:
  `computed-consist` answers yes; `computed-default-speed` means geometry
  works but metadata needs the on-disk match-pack fallback from the
  agents-off research.
- Sanity of the constants against a real corridor (journey within ~25% of
  watched time; headway within one departure).
- Board numbers versus panel share for a two-line station.
