# Universal connected-street construction replay

Date: 2026-08-31 (Europe/Amsterdam)

Status: implemented and regression-tested. The non-depot typed path remains
live-proven for the modular street-terminal family. The typed depot-root part
of the original proof is superseded by
[SELECTABLE_CONNECTED_DEPOT_HELPER_REPAIR_2026-08-31.md](SELECTABLE_CONNECTED_DEPOT_HELPER_REPAIR_2026-08-31.md):
road and tram depots now use a selectable stock helper root followed by an
exact topology-only connection repair.

## Problem class

The road-depot failure from relay session `mp-87164966f1cca6a9` was not really
a road-depot-specific bug. `api.cmd.make.buildConstruction` receives a
construction resource, parameters, transform, and player, but no explicit
existing-road endpoint. Any captured building whose graph names an existing
street node can therefore lose its connection if exact proposal conversion
falls back to that helper.

A filename allowlist would fix only the currently known vanilla resources and
would immediately fail for another era, DLC, or mod-provided facility. The
authoritative fact is in the captured graph, not in the resource name.

## Universal policy

`construction_connection_replay.lua` now classifies a fresh construction by
one invariant: at least one captured STREET edge terminates at an existing
canonical node. That result is independent of filename, construction kind,
era, module count, and stock versus mod provenance.

For all supported fresh construction graphs:

1. non-depot construction builds use typed exact replay;
2. connected street depots use a stock-helper root plus an exact topology-only
   connection repair, because typed depot roots are not stock-UI safe;
3. a graph with an existing street endpoint is atomic and may never degrade to
   transform-only placement;
4. explicit edge-object additions, retained objects, and removals travel in
   the same exact graph and also make fallback atomic;
5. collateral buildings are removed through the established bounded first
   stage, after which the exact connected graph is issued; and
6. any converter, resource, topology, or postcondition mismatch rejects
   fail-closed instead of leaving a detached or incomplete shell.

This directly covers:

- vanilla road depots;
- both ordinary and electrified tram depots;
- every passenger bus/tram terminal and cargo truck terminal built from
  `station/street/modular_terminal.con`;
- road-connected airports, harbours, industries, assets, and other portable
  constructions when their native click exposes the connection graph; and
- equivalent data-driven mod resources without adding their filenames to the
  code.

Curbside bus, tram, and truck stops are edge objects rather than buildings.
They remain on the schema-5 edge-object replay path; this construction change
does not reclassify them.

## Deliberate exception

Connected track depots are still rejected before mutation. Build 35924's stock
selection UI is known to crash on typed rail-depot output. The new structural
classifier therefore admits a depot only when every topology edge is STREET
and at least one street edge names an existing endpoint. An isolated depot may
still use the established selectable helper path and then be connected by a
separate road or track build.

This is an engine-specific safety boundary, not a filename compatibility rule.

## Automated coverage

The codec and replay tests now include:

- road and tram depot resources, including both tram-catenary variants;
- connected road and electrified-tram depot graphs;
- an arbitrary `industry/modded_road_facility.con` fixture proving that no
  resource allowlist participates in routing;
- the same generic construction with an integrated edge object;
- an isolated generic construction proving that low-risk fallback is not
  disabled globally;
- all 216 passenger/cargo, platform, length, and tram-track combinations of
  the stock modular street terminal;
- all 60 stock airport option combinations and all 12 harbour templates; and
- the established exact-topology, collateral, ownership, finance, and output
  binding invariants.

The final complete suite passes: 147 Lua tests, 7 transport-network tests, 3
alpha-readiness tests, 225 Python tests, all cross-language economy/freight
parity vectors, the 256-step freight stress replay, 1,024-event randomized
replay, and Lua/PowerShell/launcher/recovery syntax and lifecycle checks.

## Native evidence

Three complementary two-process runs provide the live boundary:

1. `runtime/localhost-live/depot-bus-20260831-3--mp87164966/run-status.json`
   replays the exact connected road depot, purchases a stock bus through it,
   and ends at core `d668d9ad`, structure `fe731d20`.
2. `runtime/localhost-live/tram-depot-universal-20260831-2--street-family/run-status.json`
   builds an electrified `depot/tram_depot_era_a.con` against the existing
   canonical road node. Both peers report `gui-build-proposal`, the complete
   construction/depot/node/edge graph, exactly `-$12,726` to Company 1, three
   healthy checkpoints, core `f82816e4`, and structure `724de860`.
3. `runtime/localhost-live/street-terminal-universal-20260831-1--street-family/run-status.json`
   replays the road-connected modular passenger terminal with a split town
   road and two collateral buildings. Both peers converge through staged exact
   replay with three healthy checkpoints, core `077d9afd`, and structure
   `07fbabc9`.

Each successful run has one completed physical proposal, zero rejected,
faulted, or pending proposals, and matching post-build checkpoint state. The
tram and terminal runs closed both disposable game processes and companions;
no test game was left running.

## Remaining acceptance

The non-depot engine, canonical graph, finance, and consensus paths are proven.
The replacement road-depot helper path is also live-proven through purchase; a future
packaged two-computer acceptance should still click one road depot, one tram
depot, one passenger terminal, and one cargo truck terminal from the ordinary
UI, then open/buy/bulldoze immediately afterward. That checks human-facing
selection and visual attachment; it is not a missing authority implementation.
