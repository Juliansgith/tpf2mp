# Town size must not depend on the crowd policy

Date: 2026-08-07 (Europe/Amsterdam)
Scope: the competitive economy stops reading presentation-scaled native
capacity. Found by static reading while answering "what else drives town
growth?"; fixed, tested, and ratcheted in the same slice.

## The defect

`AGENT_PRESENTATION_POLICY_2026-08-06.md` states the principle plainly:
*"Native sim agents are decoration: never read as market truth."* The
implementation contradicted it.

```
presentation.lua      scales personCapacity.capacity by 1/64 per building
world.townCapacity()  sums getLandUsePersonCapacities() -- those same values
corridor_binding      gravityDemand(capA, capB, km) = capA*capB / (div * km)
```

The crowd policy is a cosmetic setting. It was feeding the demand model its
primary input, and demand goes as the **product** of two town sizes, so the
error compounds. Measured capacity per construction was 3.38-3.77 under
vanilla and 0.95 under skeleton, so switching policy moved total demand by
roughly an order of magnitude.

Skeleton is the default. The physical-development experiment ran under
`agentMode=vanilla` (confirmed in that session's `match-content-profile.json`),
so the only live economy numbers came from the configuration players would not
be using.

## Why inversion does not work

Dividing the policy back out is impossible, not merely awkward.
`presentation.scaledCapacity` floors the result and then clamps it up to
`capacityFloor`:

```lua
local scaled = math.floor(base * numerator / denominator)
if base > 0 and scaled < policy.capacityFloor then scaled = policy.capacityFloor end
```

Under skeleton every building with base capacity 1-63 maps to exactly 1. Under
minimum-safe essentially all of them do. The original value is destroyed at
load time and no arithmetic recovers it.

## The fix

Town size becomes a **building count**, which is policy-independent for an
exact reason worth stating: the capacity floor keeps every populated building
at one slot or more under every policy, so the *set* of town buildings is
identical whatever the crowd setting. Only the per-building magnitudes move,
and those are exactly the presentation-owned part.

- `world_town_reading.townBuildingCount(townId)` returns the count, or `nil`
  when the enumeration is unavailable -- it never substitutes a number, so the
  caller decides what an unsized town means.
- `corridor_binding.townMarketSize` converts a count into the range the gravity
  divisor was tuned against via `nominalCapacityPerBuilding`, and applies the
  documented `fallbackTownBuildings` when a town cannot be sized.
- `world.townCapacity` keeps returning raw native capacity and gains a third
  return reporting whether the read was real. `presentation.lua` still needs
  the raw value: verifying what native actually holds is its whole job. Its
  `300, {100,100,100}` fallback previously made every town identical in
  silence, which reads as a uniformly flat world rather than a failed read.

### Calibration, still open

`nominalCapacityPerBuilding = 4` comes from the measured vanilla
capacity-per-construction (3.38-3.77) rounded to an integer. Town buildings are
a subset of constructions, so the true per-building figure is somewhat higher
and this constant is provisional. Calibrate it against a live vanilla world by
comparing the computed size to that world's reported town capacity. The
`minDemand`/`maxDemand` clamps bound the error meanwhile.

## The feedback loop this exposes

Naming the coupling makes an unnamed loop visible:

```
buildings -> land-use capacity -> gravity demand -> carried passengers -> buildings
```

Physical development adds buildings, which added capacity, which raised demand,
which earned more buildings. Before this fix the loop's *gain* was set by the
crowd policy -- compounding roughly 3.6x faster under vanilla than skeleton.
After it, growth still feeds demand, but at a rate the policy cannot move.

## Structure and ratchet

`world.lua` crossed its 2100-line budget, so the town-reading cluster moved to
`world_town_reading.lua` (building enumeration, development positions, building
count) rather than raising the limit. `world.lua`'s budget ratchets down to
2080. `check_source_boundaries.ps1` gains two checks: that `world.lua` still
composes the boundary, and that corridor binding never again assigns
`townCapacity(...)` into a gravity input.

## Tests

`tests/run_lua_tests.lua` adds *model town size is independent of the native
crowd policy*: across vanilla, skeleton, and minimum-safe, the populated
building count is identical, while the capacity sums demonstrably are not, and
capacity-sized demand would differ. The negative half is kept deliberately --
it documents the defect the boundary check now forbids.

Full offline gate passes (92 checks). The long-replay model digest is
unchanged at `f1e019a3`: the economy vectors take demand as an input rather
than reading the world, so this fix does not move them.

## Not verified here

No live run. The physical-development experiment should be repeated under
`skeleton` -- the default, and the configuration this fix changes most -- before
town growth is enabled by default.
