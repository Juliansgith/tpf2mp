# Exact passenger presentation and native boundary

Date: 2026-08-07 (Europe/Amsterdam)  
Prototype: `0.24.0-alpha`  
State/checkpoint/passenger schemas: `24` / `4` / `1`

## Outcome

Passenger presentation is now model-owned, deterministic, synchronized, and
checkpointed. A selected train, line, or station receives an exact count in the
TPF2MP HUD. The count drives presentation only; the existing deterministic
economy remains authoritative for revenue, score, and town development.

Native simulated people remain a small cosmetic population. The implementation
does not claim that the base game's passenger glyph is authoritative and does
not issue an unsafe native person command.

## Ledger policy

For each registered passenger service, the current settlement allocation `A`
is split between its endpoint station groups. Integer halves alternate the odd
passenger by epoch so neither direction gets a permanent rounding advantage.
The station sequence, endpoint identities, line/company/market identities, and
all counts are canonical; local entity IDs enter only the GUI projection.

The planned departures for an authored hour are:

```text
D = max(1, floor(3600 / clamp(headwaySeconds, 30, 3600)))
```

Seats come from the registered consist facts. A capacity/vehicle/departure
derivation is the second choice; `100` seats is the explicit fail-soft fallback.
At an endpoint release, the train boards:

```text
remaining = max(1, D - departuresAlreadyUsed)
wanted    = ceil(waiting / remaining)
boarded   = min(waiting, freeSeats, max(1, wanted))
```

This update runs inside the existing ordered `vehicle.sync_release` action. It
creates no new network round trip and samples no local time or entity ID.

- The first endpoint boards toward the last endpoint.
- Intermediate stops preserve the load.
- The destination endpoint alights the entire trip, then boards the reverse
  direction.
- A repeated release round is idempotent and must name the same stop.
- A skipped/backward round fails closed.
- A new settlement adds demand to the old endpoint backlog and does not empty a
  train in motion.
- A route edit accounts old queues as overflow and onboard riders as discarded;
  it never silently teleports either to new endpoints.
- Cargo services are excluded. Cargo requires its own industry-chain ledger.

All authored counters saturate at `1,000,000,000`, comfortably inside Lua 5.1's
exact integer range.

## Persistence and consensus

`world.passengerPresentation` stores canonical line and vehicle records. The
vehicle-sync digest is schema 3 and embeds passenger-presentation schema 1;
checkpoint format 4 therefore binds the ledger into the core digest and
convergence key.

The Python verifier independently requires:

- exact fields and bounded integer counts;
- sorted, unique canonical line/vehicle IDs;
- the full canonical stop sequence, endpoint agreement, and an eight-hex-digit
  route digest;
- line/company/market identities and the full stop sequence equal the authored
  economy service, whose metadata is now part of the model digest;
- vehicle company/line agreement;
- `aboard <= capacity`;
- loaded-trip endpoints equal the line endpoints;
- the last station lies on the line;
- passenger last round/stop equal the synchronized vehicle release round/stop.

These checks still reject a malformed ledger when every outer checksum is
recomputed. Formats 1, 2, and 3 remain readable for archived evidence. Loading
a schema-23 save can seed a missing passenger round cursor from vehicle sync,
but invents no historical riders; a non-pristine mismatch is never repaired.

## UI and native scenery

`gui_passenger_hud.lua` mounts in the already live-proven `gameInfo.layout`.
It shows:

- selected train: exact aboard/capacity, trip endpoints, and line;
- selected station/group: exact waiting and passengers per epoch;
- selected line: waiting, allocated, and boarded;
- no supported selection: global exact aboard/waiting totals.

Intermediate stations receive an explicit zero board under the current
endpoint-corridor demand model rather than disappearing from the display.
Native ECS aboard/waiting counts appear only in the tooltip as scenery
telemetry.

## `Debug_SetSimPersonState` result

The exact Build 35924 command visitor table maps tag 36 to the visitor stub at
RVA `0x009D6250`. Static control-flow recovery reaches the implementation at RVA
`0x009D79F0`. The consumed command payload is eight bytes:

```text
+0x00  entity id
+0x04  selector constrained to 0 or 1
```

The corresponding Lua command factory shape is `(personEntityId, boolean)`.
There is no vehicle, terminal, station group, line, transform, or other target
field. Consequently, constructing this command can reset/toggle one local
person state but cannot prove where that person will go. Native person IDs also
differ between peers. Sending it as an injection primitive would be locally
nondeterministic.

`passenger_cosmetics.lua` therefore:

1. reads bounded native person/vehicle/terminal telemetry;
2. constructs both boolean factory variants only to verify availability/shape;
3. records desired authoritative totals and the bounded cosmetic policy;
4. always reports `targetWritesEnabled=false` and `appliedWrites=0`;
5. never calls `sendCommand`.

A future writable adapter requires a pinned target-bearing operation, or a
separate exact-build hook that overrides only the stock UI's displayed value.
Neither is implied by tag 36.

## Automated evidence

The new regressions cover:

- exact queue/load/alight conservation over endpoint and intermediate releases;
- odd allocation, multiple vehicles, duplicate release, and epoch carry;
- route-edit overflow/discard accounting and cargo exclusion;
- pre-ledger save alignment and live mismatch rejection;
- full-stop-sequence checkpoint validation, authored-service binding, and
  passenger/vehicle-sync binding;
- re-signed malformed capacity, round, and trip-endpoint rejection;
- selected-vehicle exact HUD rendering;
- construction of the debug factory shape with an assertion that zero native
  commands were issued;
- architecture size ratchets after extracting `vehicle_sync_passengers.lua`.

## Human test boundary

The next two-process test should use a freshly registered real passenger line:

1. settle one epoch so the line has non-zero allocation;
2. select both endpoint stations and compare the TPF2MP waiting count;
3. let the canonical train reach/release from an endpoint, then select it on
   both peers and compare exact aboard/capacity and destination;
4. delay one peer before the next station and verify both HUDs advance only on
   the shared release;
5. inspect an intermediate station (if present) for an exact zero board;
6. export research and a checkpoint, then compare passenger ledger digest,
   epoch, lines, vehicles, aboard, and waiting.

The base game's stock passenger icon may show the smaller native cosmetic count.
That mismatch is expected and explicitly labelled; the TPF2MP HUD is the
authoritative multiplayer display.
