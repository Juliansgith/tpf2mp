# Water transport support audit (2026-08-30)

## Outcome

Water transport is no longer an untested consequence of the generic
construction and vehicle codecs. Build 35924 now has automated evidence for
all 12 stock harbor templates, every stock ship resource, passenger and cargo
water services, divergent native entity IDs, compound harbor removal, and
actual native ship movement.

The disposable-world run was
`runtime/live-validation/20260830-142018`. Its exact-build hook and normal
39-check standalone validator passed before the water slice ran. The slice
then:

- built two passenger harbors, one cargo harbor, and one shipyard;
- read back the construction, station, station-group, and depot outputs and
  verified their passenger/cargo/depot classifications;
- verified every created output was owned by the active player;
- bulldozed the isolated cargo harbor and verified its construction and
  station retired completely (the remaining empty station-group shell was
  identified explicitly as transient native residue);
- created a two-stop water line between the passenger harbors;
- bought `vehicle/ship/rigi.mdl` through the production canonical vehicle
  codec and read back its exact consist;
- assigned it to the created line and read back the same native line entity;
- ran at speed 3, after which the ship was unstopped, remained assigned to the
  line, and had moved `626.771` metres.

The construction ID removed with the cargo harbor was subsequently reused by
the native game for the ship. That is useful live confirmation that local
entity IDs cannot be durable multiplayer identities and that the existing
canonical-ID layer is required for water transport too.

The runner closed the disposable game and restored `settings.lua` byte for
byte. No game process was intentionally left running.

## Automated coverage added

### Harbor and shipyard construction

The portable-construction tests cover all 12 stock harbor templates:

- passenger and cargo;
- 50-metre and 100-metre docks; and
- one, two, and four terminals.

The fixtures reproduce the stock module-slot geometry and metadata rather than
testing an unrelated empty construction shell. Collateral removal is included
in the matrix, and the disposable-world helper supplies small passenger and
cargo harbors plus the stock shipyard for native readback.

### Ships, passenger economy, and freight

All 23 ship `.mdl` resources shipped in Build 35924 are accepted by both the
Lua and Python operation validators as portable vehicle purchases. The list
covers passenger ferries, hovercraft, general cargo vessels, tankers, and
universal vessels.

A WATER passenger-service regression verifies:

- computed consist capacity, speed, and custom upkeep;
- corridor rather than feeder market classification;
- positive authored allocation and fare revenue;
- passenger queue/load conservation; and
- an all-peer rendezvous at every harbor stop.

An explicit WATER-freight regression boards 40 units, delivers the same 40
units at the destination, deducts them from the source industry, adds them to
the sink, and settles the conserved distance revenue. It prevents a future
rail-only or air-only carrier assumption from silently producing phantom or
non-paying ship cargo.

Named vehicle resources remain carrier-neutral in the protocol. A modded ship
does not require a new command type, but both peers must still have identical
attested content and the resource must be usable by the native game.

### Network-facing determinism

The vehicle lifecycle regression now runs for both AIR and WATER on two
independent peer worlds. Purchase, assignment, replacement, and sale use
deliberately disjoint player, depot, line, and vehicle entity IDs. Both peers
still produce the same canonical vehicle ID, results, and state digest.

The station synchronization regression now includes an intermediate WATER
stop. A ship enters the all-peer barrier, accepts the ordered release, and
departs, keeping harbor arrivals in the same physical-position anchoring model
as rail and air services.

These are in-process network regressions over the production codecs and state
machines. They do not replace the human two-computer acceptance below.

### Native harness reliability

The first water run exposed an automation-only race: the native load sequence
could destroy its temporary window between a key-down and the matching key-up.
The release-only path now sends the scan-code release globally and records that
foreground verification was intentionally not required. A failed first run
was killed safely and restored the original settings; the immediate retry
completed the full water probe.

## Honest remaining boundary

This is strong standalone engine proof, not yet a two-computer acceptance of
water transport. Before advertising it as fully supported, one human network
run should still:

1. Build small and large passenger/cargo harbors through the ordinary GUI and
   confirm terminal count, geometry, cost, and ownership on both peers.
2. Edit and bulldoze a harbor through the exact GUI-captured route, including
   rival-edit rejection.
3. Create passenger and cargo shipping lines, buy and assign ships, and confirm
   the same vessels are visible and moving on both peers.
4. Pause one peer during a harbor arrival and verify the every-stop rendezvous
   releases both worlds cleanly.
5. Settle a valid industry-to-industry water cargo route and confirm stock,
   transfer, delivery, revenue, and upkeep presentation.

Only the stock Rigi has a live native movement proof. The other 22 stock ship
resources have repository and protocol coverage, not 22 individual voyages.
The live construction proof used the small one-terminal harbor; all other
stock layouts are codec-tested. Native water geography and route finding remain
the game's responsibility, while consensus, ownership, and authored economy
remain TPF2MP's responsibility.

Modded harbors remain subject to the generic portable-construction limits:
named resources and modules, no opaque callbacks, bounded collateral removal,
and unambiguous output binding on every peer.

## Repeatable commands

Full deterministic suite:

```powershell
powershell -ExecutionPolicy Bypass -File .\tools\run_tests.ps1
```

Disposable exact-build harbor/ship run:

```powershell
powershell -ExecutionPolicy Bypass -File .\tools\run_unattended_live_validation.ps1 `
  -SkipTests -NativeHook -SkipNativeBuild -RunWaterFacilityProbe
```
