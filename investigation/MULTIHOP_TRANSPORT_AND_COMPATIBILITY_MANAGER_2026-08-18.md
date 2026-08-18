# Multi-hop transport and compatibility manager

Date: 2026-08-18 (Europe/Amsterdam)

Implementation target: prototype `0.38.0-alpha`, state schema `31`, economy
model `9`, cargo-presentation schema `2`, delivery schema `3`, freight-industry
schema `3`, checkpoint format `5`, and exact game Build 35924.

## Outcome

The authored transport model is no longer restricted to one line whose first
and last stops directly cover both endpoints. It now builds one deterministic,
carrier-neutral network from registered services and uses it for:

- passenger demand that travels over connecting lines;
- cargo paths with real authoritative inventory at transfer stations;
- intermediate-stop interchanges on through lines;
- one in-game Routes / Transfers view;
- one Compatibility view that inventories every named infrastructure resource
  successfully admitted by the existing portable proposal codec.

This is an authored-model feature. Native people and cargo agents remain
cosmetic; they are not used to decide allocations, revenue, industry stock, or
checkpoint convergence.

## Deterministic transport graph

`transport_network_graph.lua` and the independent Python mirror
`transport_network.py` derive directed service edges from canonical station
group IDs. A line with more than two stops can contribute any ordered segment
between its stops. A route may contain at most four lines, may not revisit a
station group, and may not use one line twice.

The graph is carrier-neutral. Rail, road, tram, water, and air services can
connect when their normal registration exposes compatible facts. A transfer
requires the exact same canonical station group on both services. Two merely
nearby but separately grouped stations are not silently treated as connected.

Route choice is stable and deterministic: generalized journey/headway cost is
sorted first, then a canonical route key breaks ties. Passenger transfers add
480 seconds per change; cargo transfers add 1,800 seconds per change.

## Passenger multi-hop demand

For each reachable pair of distinct model towns that needs at least two lines,
the planner selects one best path and calculates a bounded gravity demand from
the two canonical town sizes, route distance, and transfer count. That
through-demand is added to every constituent corridor before ordinary market
allocation. Adding `B <-> C` can therefore increase demand on an existing
`A <-> B` service when both lines share the same station group at B. Removing
the connection removes the derived through-demand on the next rebuild.

Town growth runs before the passenger network is rebuilt at settlement, so
larger canonical towns increase both direct and connecting demand without
depending on native agent counts.

The present boundary is deliberately honest: the model accounts for a
passenger's complete route, but passenger presentation still maintains
per-line cohorts rather than a persistent identity for every transfer. The UI
and economy show the additional demand; native yellow station icons and native
person destinations remain cosmetic.

## Cargo transfer authority

Every registered cargo line publishes named capacity by cargo type and source
or destination industry facts for every stop in industry catchment. The route
planner then searches from a producing industry to a compatible input stock.

The important behavior is:

1. A source line with no compatible downstream destination stays in
   `awaiting-compatible-path`, with zero authored demand and capacity. It does
   not load cargo merely because a producer is nearby.
2. Adding a compatible downstream line through the exact same station group
   causes automatic replanning.
3. The first vehicle withdraws only from the source industry's authoritative
   output stock.
4. Its unload increments authoritative `stationStock[station][cargo]`.
5. The next vehicle can board only cargo actually held in that station stock.
6. Only the final leg deposits into the destination industry's authoritative
   input stock and earns final-delivery settlement credit.

The conservation validator recomputes each transfer station balance from
cumulative upstream delivery minus cumulative downstream boarding. A missing,
duplicated, negative, or edited unit fails the checkpoint. `totalTransported`
counts physical movement on every leg; `totalDelivered` counts only arrival at
the final industry.

An unused candidate path may adopt a better compatible service. The complete
path is pinned atomically on its first ordered vehicle release, and settlement
also repairs the pin from moved cargo when loading an older state. After that
point a new shortcut cannot reinterpret stock, payment, or cursor history. A
broken operated path becomes visibly `pinned-path-unavailable`; abandoning it
currently requires deleting and recreating its operated legs.

The first slice chooses one deterministic source-to-sink path per cargo type
and claims each participating line for one path. It does not yet split one
line's capacity among several simultaneous cargo contracts.

## Save and deletion durability

Cargo presentation is schema `2`; the combined delivery snapshot is schema
`3`. Freight-industry state is schema `3` and adds compact
`retiredTransported` and `retiredDelivered` maps.

Deleting a line now removes its active contract cursor, while moving that
cursor's cumulative counts into the compact retirement maps. Lifetime totals
remain exact without retaining one unbounded record per deleted line. Schema-2
saves infer the retired residual from their lifetime totals during migration.
Active plus retired counters must equal lifetime totals in Lua and Python.

## General infrastructure compatibility manager

The construction path remains data-driven rather than maintaining a list of
vanilla road, track, station, or mod IDs. Portable proposals carry repository
resource names and finite data:

- roads and tracks use their named `.lua` repository resource;
- signals and waypoints use named `.mdl` resources;
- stations, depots, assets, and other constructions use a named `.con`, a
  finite transform/parameter tree, and named `.module` entries;
- exact peer preflight verifies that every named resource exists before the
  host authorizes mutation;
- the match content fingerprint requires both peers to load the same content.

`resource_compatibility.lua` observes successful portable transactions after
codec validation and maintains a bounded inventory of the exact resources and
adapters used. Vanilla resources and data-only mod resources follow the same
path. It is diagnostic, not a second authority gate.

There is no safe universal serializer for arbitrary executable mod callbacks,
closures, local entity IDs, or side effects outside a BuildProposal. Those
remain blocked and require an explicit adapter. This is shown in the UI rather
than being misrepresented as generic support.

## Player-facing manager

The Multiplayer panel now has three manager views:

- **Overview** keeps the existing match, economy, synchronization, and proof
  status;
- **Routes / Transfers** lists passenger chains, cargo chains, demand,
  capacity, unresolved cargo lines, and authoritative transfer stock;
- **Compatibility** lists every observed road, track, edge object,
  construction, and module resource, its adapter, and its use count, plus the
  explicit opaque-callback limit.

The manager uses canonical names where bindings expose them and falls back to
canonical IDs, so it does not leak machine-local entity numbers.

## Automated evidence

Focused verification after implementation:

- transport-network behavior: `7/7` Lua scenarios;
- Lua/Python graph, route, state, and operational-path-pin parity: `2/2`
  complete vectors;
- companion suite after alpha closure: `179/179` tests;
- source-size and extracted-module architecture boundaries: passed;
- unknown transport schemas, invalid cargo names, forged transfer inventory,
  overdraw, cursor reversal, and deleted-line history are rejected.

The complete repository gate also passed on 2026-08-18. That gate includes the
Lua and Python suites above, exact cross-language economy/freight/transport
replay, a 256-step multi-cargo stress trace, game-script integration, network
consensus, syntax, release-manifest and transactional-install checks, launcher
construction, native-hook boundaries, and recovery/restore tests. No game
process was required for these deterministic checks.

## Remaining live boundary

Tomorrow's test must establish the first human two-process receipt for:

- passenger through-demand appearing after a real second connection;
- a source cargo service refusing to ship before a compatible sink exists;
- physical cargo transfer through one shared station group;
- final industry stock and revenue advancing without a checkpoint fault;
- save/reload with transfer stock or cargo aboard;
- representative vanilla and data-only mod infrastructure appearing in the
  Compatibility view and replaying on both peers.

See
[`LIVE_MULTIHOP_COMPATIBILITY_UX_CHECKLIST_2026-08-18.md`](LIVE_MULTIHOP_COMPATIBILITY_UX_CHECKLIST_2026-08-18.md)
for the exact order.
