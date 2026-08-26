# Phantom passenger access — 2026-08-26

## Finding

Session `mp-fd4866ceb405d303` proved a real economy exploit. Player 1's Line 1
ran between two rail stations with no street connection, yet the authored
passenger model showed 1,178 transported, 856 waiting, and 20 aboard.

The train movement was genuine: both peers repeatedly committed matching
`vehicle.sync_release` rounds. The invalid part was access. Both station groups
were mapped to Coleford, and line registration used Coleford's complete town
building count as the market input without proving that either station could
reach a building. By epoch 31 that phantom local market had grown to 1,953
passengers/hour. The five-minute settlement paid 60 completed passengers at
$7.39 each: $443,400 gross less $9,400.19 vehicle upkeep.

This was not RNG, native finance leakage, or a movement-proof failure. It was a
missing station-to-building access gate.

## Correctness rule

A passenger service may enter the authored market, passenger presentation,
multi-hop graph, and scoreboard only when both endpoint station groups reach at
least one building in their bound town through the native street catchment
graph. If the API or components cannot be read, access is unavailable and the
service fails closed.

Disabled services:

- receive no allocated passengers or passenger revenue;
- retire their authored queues and onboard presentation state;
- cannot contribute a passenger graph edge or town growth;
- remain physically visible and may continue to move cosmetically;
- continue to incur canonical vehicle upkeep.

## Implementation

`world_station_access.lua` reads the native station-to-street-edge catchment
map, intersects it with each town building's parcel street segments, and counts
each reachable building once. It exports bounded facts only; engine container
details do not enter canonical state.

Passenger `line.register` actions now carry a versioned access proof:

- `stationAccessSchema = 1`
- readiness for both endpoints
- reachable and total town-building counts for both endpoints
- a derived eligibility flag and source

The companion validates the entire relationship rather than trusting the
boolean. Economy state version 10 quarantines pre-proof passenger services on
load until their owning peer re-registers them. Enabling or disabling a service
also clears its delivery cursor, preventing a retired lifetime counter from
being paid after reconnection.

Successful canonical street or station changes schedule a coalesced owning-peer
registration scan after physical consensus. This means connecting an isolated
station enables it, while cutting its last access road disables it, without a
manual market button. Ordinary track additions do not cause a scan; untyped
edge removals are conservatively rechecked.

The multiplayer panel explicitly reports an economy-disabled line and its two
endpoint reachability counts, including that trains still cost upkeep.

## Verification

Automated coverage includes:

- exact catchment intersection, multi-parcel de-duplication, town isolation,
  and a valid zero-access station;
- unavailable native API fails closed;
- connected passenger service registers as enabled;
- losing one endpoint's access disables it and clears the delivery cursor;
- pre-v10 passenger state migrates to disabled/unverified;
- Lua/Python parity for enable-to-disable cursor retirement;
- protocol rejection of forged or internally inconsistent access proofs;
- proposal classification for street, station, track, and untyped removals;
- public-view propagation and the player-facing warning.

The live session predates this code and remains economically contaminated. Its
already-paid balance and authored town growth cannot be reconstructed safely;
use a fresh session or a recovery point from before Line 1 began operating.

## Deliberate limit / next slice

This patch closes zero-access revenue. It does not yet scale a town's direct
demand by the fraction of buildings in catchment, nor union the coverage of
multiple bus/tram feeder lines. Those require a canonical passenger-access
graph so buildings are counted once across overlapping feeders. The new exact
endpoint building sets/counts are the prerequisite for that model; until then,
one reachable building is the eligibility threshold and the town-level demand
calculation remains unchanged.
