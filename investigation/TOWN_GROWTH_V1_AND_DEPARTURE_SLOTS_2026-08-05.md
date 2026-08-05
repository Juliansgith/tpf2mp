# Town growth v1 and the departure-slot foundation

Date: 2026-08-05 (Europe/Amsterdam)  
Scope: towns now grow as a deterministic consequence of ordered settlements,
and departure slots exist as a pure computation whose enforcement mode is
deliberately gated on the agents-off pivot decision.

## Town growth v1: growth is a consequence of the settlement

Design principle: no new protocol, no authored-model state, no replay
change. An ordered `economy.settle` already delivers identical results to
every peer; growth is a pure function of those results plus digested market
metadata, so every peer computes identical capacity targets and issues
identical native `setTownInfo` commands. Convergence is verified by the
structural probe, which already digests every town's land-use capacities.
The companion replay is untouched because nothing digested changes — the
suite's final model digest is identical before and after this slice.

Pipeline, all in `corridor_binding.lua` (re-exported through `world.lua`):

1. `carriedByTown(results, markets)` — corridor allocations split between
   the endpoint towns named by the market's digested metadata (odd totals
   keep every passenger somewhere).
2. `townGrowthTargets(carriedByTown, currentCapacities)` — 5% of carried
   passengers become growth points, split 60/25/15 across
   residential/commercial/industrial, stepped at most 50 per land use per
   settlement, capped at 100000, and silent when nothing changes.
3. `applyTownGrowth(registry, economyState, results)` — resolves town cids
   to local ids, reads current capacities, issues one `setTownInfo` per
   grown town (the command signature confirmed from Town Tuning's
   production usage), fail-soft with a recorded outcome in
   `state.probes.townGrowth`.

The settle handler calls this after `recordSettlement` on every peer, in
both modes. With development frozen (the current network default) the
capacity targets are inert until building growth is enabled — but they are
readable, so the structural digests already prove cross-peer convergence of
the growth policy itself.

Deliberate v1 boundaries: passenger capacities only (cargo needs follow the
same pattern later); no physical building placement (that is the schema-7
construction-event layer from the agents-off design); native command tags
20/21 remain ungated in the hook — acceptable for trusted sessions, listed
as a required gate before town commands are considered adversary-safe.

## Departure slots: computation now, enforcement after the pivot

`departureSlots(service, gameTimeSeconds)` assigns each line a stable phase
(adler32 of its canonical id modulo its headway) and returns the period,
phase, next departure time, and hold duration — pure integer arithmetic on
digested facts plus the shared clock, strictly future-dated, advancing by
exactly one period.

Enforcement is deliberately not built. Holding a vehicle uses
`setUserStopped` (the Timetables mod's five-year-proven mechanism, already
modeled as the canonical `vehicle.stop` operation), but under the current
architecture `userStopped` is lifecycle-digest material: per-departure
ordered operations would serialize every train through physical-consensus
and checkpoint barriers, and locally issued holds would flap the digest.
The two coherent enforcement modes are:

- after the agents-off pivot reclassifies vehicle state as per-peer
  presentation: local hold/release from the shared slot table, free;
- without the pivot: reclassify `userStopped` out of the lifecycle digest
  into phase state with a tolerance, then locally enforce.

Either way the slot table is the shared source of truth, and it doubles as
the enforced-headway input the demand model wants. This is recorded so the
pivot decision consciously owns it.

## Tests

`tests/run_lua_tests.lua` (55/55): exact growth arithmetic including split,
step limit, cap clamp, idle silence, and zero-carried quietness; carried
splitting with odd totals and metadata-less markets; slot periodicity,
phase stability, future-dating, and exact period advance; an end-to-end
`applyTownGrowth` with mocked commands asserting one deterministic
`setTownInfo` per grown town with exact capacity arrays. Full offline suite
passes; the unchanged final replay digest doubles as evidence that growth
adds no digest surface.

## Live verification owed

- `setTownInfo` acceptance on Build 35924 with development frozen
  (capacities readable via `getLandUsePersonCapacities` afterward).
- Structural-digest convergence across two peers after several settles
  with growth active.
- Growth-rate feel: 5%/60-25-15/step-50 are first-guess constants sitting
  in `TOWN_GROWTH` for the playtests.
