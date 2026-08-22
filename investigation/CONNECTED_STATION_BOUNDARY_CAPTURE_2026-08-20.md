# Connected station boundary capture — 2026-08-20

## Live finding

Session `match-20260820-2323`, Player 2, tick 999 rejected a vanilla passenger-station placement before it entered the ordered network lane:

- telemetry local sequence: `337`
- snapshot digest: `be5d39fe`
- error: `station graph cardinality does not match its track count`
- construction: `station/rail/modular_station/modular_station.con`
- selector: one track (`params.tracks = 0`), 160 m (`params.length = 2`)
- captured topology: 24 added nodes and 24 added edges
- construction removals: 0
- edge/node removals: 0
- wallet/native world mutation: none

The session stayed synchronized and later clock-health records remained idle with
no pending proposal, operation, checkpoint, or deferred work.

An unattached station in the same session produced 25 added nodes and 24 added
edges and committed normally. The difference is the existing-track boundary:
Build 35924 omits the snapped endpoint from `nodesToAdd` and references the
existing positive node from one station edge. The old validator counted only
new node slots and therefore rejected a valid one-path graph before canonical
node resolution could occur.

## Fix

`proposal_codec.validateStationGraph` now treats canonical `node:` references as
boundary vertices when proving the station graph:

- `new nodes + unique canonical boundary nodes = edges + platform tracks`
- each boundary vertex must be a degree-one path endpoint
- every component must remain an open, non-branching track path
- component count must still equal the station's selected track count

The existing proposal preparation stage remains responsible for resolving every
canonical boundary node locally and rejecting attachment to rival private
infrastructure. No local entity ID is added to the portable transaction and no
wire/schema version changes.

The regression test covers a one-track station with 12 new nodes, one canonical
boundary endpoint, and 12 edges. It also proves that reusing the same boundary
to close the path is rejected.

## Verification

- focused Lua suite: 136/136 passed
- complete repository suite: passed, including source boundaries, Lua/Python
  parity, transport-network, alpha-readiness, game-script, company mapping,
  native hook, launcher/update, and companion tests

Live replay still needs one fresh-process test because the running games loaded
the pre-fix Lua module. The required test is one stock passenger station snapped
to the end of Player 2's own track, followed by confirmation that:

1. it appears at the same transform on Player 1;
2. the joined endpoint is path-connected on both peers;
3. only Company 2 pays;
4. both peers return to Alpha Status `READY` with the same checkpoint.

## Delay observation

The two successful stock-construction operations in this session spent about
6.6–7.1 seconds inside the same native construction/bulldoze call on both game
processes. Their ordered proposal delivery differed by only tens of
milliseconds, and their post-call construction settling took roughly another
one second. This delay is therefore not bridge latency or host serialization;
it is the synchronous Build 35924 construction helper running concurrently in
both localhost instances. It should be measured again on two physical machines
before treating localhost's station-build pause as a network regression.
