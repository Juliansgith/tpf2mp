# Air transport support audit (2026-08-29)

## Outcome

Air transport is no longer an untested consequence of the generic codecs.
Build 35924 now has automated evidence for all four stock airport templates,
every stock airport creation option, every stock aircraft resource, a native
air-line creation, a native aircraft purchase and assignment, and actual
aircraft movement.

The latest disposable-world run was
`runtime/live-validation/20260830-131243`. Its exact-build hook and the normal
39-check standalone validator passed before the air slice ran. The slice then:

- built a passenger airfield, cargo airfield, passenger airport, and cargo
  airport;
- read back one construction root, one `VEHICLE_DEPOT`, one `STATION`, and one
  `STATION_GROUP` for each facility;
- classified the two passenger and two cargo station groups correctly;
- verified every created output was owned by the active player;
- bulldozed the isolated cargo airfield and cargo airport, then verified their
  construction, station, and depot roots retired completely (the empty native
  station-group shells were identified explicitly as transient residue);
- created a two-stop air line between the passenger facilities;
- bought `vehicle/plane/junkers_f_13_v2.mdl` through the production canonical
  vehicle codec and read back its exact consist;
- assigned it to the created line and read back the same native line entity;
- ran at speed 3 for 25 seconds, after which the aircraft was unstopped, had
  advanced to stop index 1, and had moved `546.935` metres.

The runner closed the disposable game and restored `settings.lua` byte for
byte. No game process was left running.

## Automated coverage added

### Airport construction

The portable-construction tests cover 60 stock cases:

- airfield passenger/cargo, hangar on/off, and one to three terminals;
- airport passenger/cargo, hangar on/off, one to three terminals, both landing
  directions, and both pre-1980 and post-1980 landing-light eras.

One modern-airport fixture carries 384 nodes and 383 runway/taxiway `STREET`
edges. This proves the construction schema's airport-sized graph budget rather
than accidentally testing only a small decorative shell. Collateral removal is
also present in the first case.

The GUI preview cache now includes `templateIndex`, `hangar`, `terminals`, and
`dir`. Changing an airport option while retaining the same resource and rough
topology therefore cannot replay an older cached airport. The same correction
also covers the stock street-terminal option fields.

The disposable construction helper materialises the exact stock module map.
`game.interface.buildConstruction` does not call a construction's
`createTemplateFn`; without this, it returns a successful but empty airport
shell. A live failure found that false positive and the final probe verifies
the terminal and hangar outputs explicitly.

The public `game.interface.upgradeConstruction` helper is not a valid airport
edit path on Build 35924. A readback-guarded experiment in
`runtime/live-validation/20260830-130929` asked it to remove the hangar and
reverse the landing direction. The call reported success but the native
construction retained `hangar=0` and `dir=0`, with no physical delta. The
validator rejects that false success. Player airport edits must therefore stay
on the exact typed GUI `BuildProposal` path; helper fallback is not evidence of
an applied edit.

### Aircraft and economy

All 29 aircraft `.mdl` resources shipped in Build 35924 are accepted by both
the Lua and Python operation validators as portable vehicle purchases. The
test inventory includes passenger and cargo aircraft from the Junkers F 13
through the Airbus A320 and Tupolev Tu-204 families.

An AIR service test verifies:

- road-connected passenger-airport catchment;
- computed consist capacity, speed, and custom upkeep;
- corridor rather than local-feeder market classification;
- positive authored allocation and fare revenue;
- passenger queue/load conservation; and
- an all-peer rendezvous at every airport stop.

An explicit AIR-freight regression boards 40 units onto a cargo aircraft,
delivers the same 40 units at the destination, deducts them from the source
industry, adds them to the sink, and settles the conserved distance revenue.
This prevents a future rail-only carrier assumption from silently producing a
phantom or non-paying cargo flight.

The carrier-neutral multihop and freight schemas require no airport-specific
IDs. Aircraft and modded `vehicle/...` resources travel through the same named
resource codec as trains, buses, ships, and trams.

### Network-facing determinism

The network integration harness now replays a production-shaped modern
passenger airport for Company 2. It uses the exact GUI-attested construction
path, all four compound roots, and the full 384-node/383-edge private runway
graph. The resulting 771 outputs are bound to event-derived canonical IDs,
retain Company 2 custody, and close both proposal and checkpoint consensus
without encoding the origin machine's entity allocation.

The full aircraft lifecycle is also replayed as two independent peers:
purchase, assignment, replacement with an Airbus A320, and sale.
The peers deliberately use disjoint local IDs for the player, airport depot,
line, and aircraft. Both executions nevertheless produce the same canonical
vehicle ID, canonical-state digest, and operation results while verifying both
native consists, preserving the line across replacement, and retiring all
canonical/logical ownership residue after sale.

The station synchronization regression now explicitly distinguishes AIR from
the ROAD/TRAM feeder optimization. An aircraft reaching the middle airport of
a three-stop route enters the all-peer barrier, accepts the ordered release,
and departs. Thus every airport stop remains a physical-position anchor.

These tests exercise the production codecs, runtimes, ownership rules, and
consensus state machines in-process. They do not replace the two-computer
acceptance listed below, but they make local-ID leakage and the most damaging
air-specific replay regressions deterministic test failures.

### Regression gate

After adding the network-air cases, the complete deterministic suite passed.
That includes 195 mod Lua files and nine investigation Lua files parsing, 76
PowerShell files parsing, the standalone/network gameplay suites, randomized
1,024-event replay, relay and launcher lifecycle tests, recovery/restore tests,
release/install integrity tests, and the Python consensus suites. The pinned
Build 35924 executable profile also remained an exact signature match.

## Other regression found

The one-shot live validator could inherit a short-lived network launcher
profile and start the disposable world in network mode. That made the local
proxy gate fail before a feature probe ran. Forced one-shot validation now
owns its mode as well as its peer/session/bridge identity, and a regression
test deliberately supplies a stale network profile.

## Honest remaining boundary

This is strong standalone engine proof, not yet a two-computer acceptance of
air transport. The following still need one human network run before airports
should be advertised as fully supported:

1. Build an airfield and a modern airport through the ordinary Player 1 GUI;
   confirm geometry, terminals, runway, hangar, cost, and ownership replicate
   to Player 2.
2. Exercise terminal count, hangar, landing direction, second-runway, and
   terminal-B edits through the exact GUI route, including network bulldozing
   and rival-edit rejection. Standalone compound bulldozing is proven; the
   public upgrade helper is conclusively a no-op and must not be used.
3. Create an airline, buy and assign a plane, and confirm the same plane is
   visible and moving on both peers.
4. Pause one peer during an airport arrival and verify the every-stop vehicle
   rendezvous releases both worlds cleanly.
5. Connect both passenger airports to roads and verify the authored station
   board, aircraft load, revenue, and upkeep presentation.
6. Fly cargo between valid industry-connected cargo airports and verify
   stock, transfer, delivery, and revenue conservation.

Only the small Junkers passenger aircraft has a live movement proof. The other
28 stock aircraft have repository and protocol coverage, not 28 individual
native flights. Modded airports remain subject to the generic portable limits:
named resources and modules, no opaque callbacks, at most 64 collateral
construction removals, and unambiguous output binding on every peer.

## Repeatable commands

Full deterministic suite:

```powershell
powershell -ExecutionPolicy Bypass -File .\tools\run_tests.ps1
```

Disposable exact-build airport/aircraft run:

```powershell
powershell -ExecutionPolicy Bypass -File .\tools\run_unattended_live_validation.ps1 `
  -SkipTests -SkipInstall -NativeHook -SkipNativeBuild -RunAirFacilityProbe
```
