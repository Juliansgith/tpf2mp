# Connected-station parity and construction input backlog - 2026-08-22

## Live failure

In session `match-20260822-1718`, Player 1 suppressed two ordinary station
clicks and emitted portable captures, but the companion rejected both before
host ordering:

- local sequences `282` and `300`;
- game ticks `821` and `860`;
- error `station graph cardinality does not match its track count`;
- 24 new nodes and 24 track edges;
- one edge endpoint referencing an existing canonical `node:` identity.

The Lua codec already treated that canonical endpoint as a boundary vertex.
The Python protocol validator still required every vertex to be a new sequential
slot. The earlier report in
`CONNECTED_STATION_BOUNDARY_CAPTURE_2026-08-20.md` therefore overstated the
fix: its Lua regression passed, but there was no cross-language attached-station
vector. This was a validator-parity defect, not a track-access, road-connection,
transform, wallet, or physical-replay failure.

## Delayed extra stations

The three stations that appeared later were not duplicates of one native
command. They were three distinct accepted clicks at local sequences `336`,
`363`, and `389`, about ten seconds apart. Each entered the ordinary deferred
physical FIFO while earlier work was still settling, then replayed in order.
That behavior preserved commands but was hostile construction UX: a suppressed
station, depot, asset, edit, or bulldoze click has no immediate native mutation,
so retaining several of them makes old placement intent materialize after the
cursor has moved and makes later bulldoze attempts look ignored.

## Fix

The companion station graph proof now mirrors Lua exactly:

- new slots and canonical `node:` boundary vertices share one adjacency graph;
- `new nodes + unique boundaries = edges + selected tracks`;
- every canonical boundary is a degree-one endpoint;
- every component remains one open, non-branching path;
- component count still equals the selected track count.

Construction input is now single-flight at the GUI/network boundary. While the
host order, physical proposal/operation consensus, shared-clock rendezvous, or
checkpoint barrier is active:

- the vanilla builder gets an explicit error saying the input was not queued;
- construction preview/apply correlation is not armed;
- an engine-side `reject-if-busy` backstop refuses any capture that races the
  GUI snapshot;
- the diagnostics panel reports the reason and busy-input rejection count.

This policy covers station/depot/asset placement, station editing, and
construction bulldozing. Road, track, signal, and waypoint proposals retain the
existing bounded FIFO because short topology sequences are deliberate and have
portable geometry. The policy is machine-local control metadata and never
crosses the canonical wire format.

## Verification

- exact Python attached-station acceptance and malicious-boundary rejection;
- existing Lua attached-station acceptance and boundary-path rejection;
- GUI preview/apply rejection with the native builder error contract;
- engine proof that a construction-only busy action does not enter the FIFO;
- proof that ordinary topology captures still retain FIFO ordering;
- source budgets, 137 Lua model checks, 7 transport-network checks, 3 alpha
  readiness checks, 181 companion checks, GUI/game/company-map integration,
  syntax, packaging, updater, recovery, native-profile, and launcher suites all
  pass.

## Required fresh-process live check

The games that produced the trace loaded the old Lua/Python bundle. After
restart, place one terminus station snapped to Player 1's own track and wait for
it to appear on both peers. While it is synchronizing, a second station or
bulldoze attempt must show the wait/error message and must never appear later.
Once Alpha Status returns to `READY`, bulldoze the station once and confirm it
disappears on both peers with only the owning company charged/refunded.
