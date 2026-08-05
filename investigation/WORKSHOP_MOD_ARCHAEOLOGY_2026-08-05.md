# Workshop mod archaeology for the agents-off overhaul

Date: 2026-08-05 (Europe/Amsterdam)  
Method: source reading of subscribed Workshop items under
`F:\SteamLibrary\steamapps\workshop\content\1066780\<id>`. Read-only research;
no code copied into this repository (licences unaudited — patterns only).
Companion to `AGENTS_OFF_OVERHAUL_RESEARCH_2026-08-05.md`; this document
records which of its probes are now answered by production mod code.

## Capacity Factor (2036235984) — the zero-spawn mechanism, verbatim

`res/scripts/adjustTownBuildingCapacity.lua`: a `loadConstruction` modifier
(`addModifier`) wraps every `TOWN_BUILDING` construction's `updateFn` and
rescales `building.personCapacity.capacity` on the result. Forty-five lines,
pure supported surface, applies to new/renewed buildings (existing buildings
update as the AI renews them — or immediately in a freshly generated pinned
save, which is this project's workflow).

Notable defensive detail: it floors the result at **1**, not 0
(`if capacity<=0 then capacity = 1`). Whether 0 is genuinely unsafe or merely
untested is the one part of §8 probe 1 still open; a floor of 1 is an
acceptable fallback (one sim per building is negligible CPU and the demand
model ignores native sims entirely).

## Town Tuning (2265952996) — town-capacity command signatures, in production

`res/config/game_script/lollo_town_tuning.lua` uses the exact command
factories this project has probed-but-never-called, resolving §8 probe 8
(and most of probe 2) from working code:

```lua
api.cmd.sendCommand(api.cmd.make.setTownInfo(townId, {resCapa, comCapa, indCapa}), callback)
api.cmd.sendCommand(api.cmd.make.instantlyUpdateTownCargoNeeds(townId, townCargoNeeds), callback)
```

- `setTownInfo` (native tag 20) takes the town id plus a three-element
  residential/commercial/industrial capacity array — the write twin of
  `getLandUsePersonCapacities`.
- `instantlyUpdateTownCargoNeeds` (tag 21) takes the town id plus a cargo
  needs table, with a success callback.
- These are **commands**, which is exactly what the ordered authority
  pipeline wants: host-authored town parameters become gated, canonically
  encoded, replayed commits like every other consequential mutation. Tags
  17–22 are currently outside the 23 gated visitors and must be gated when
  town authoring lands.
- The same mod also applies a runtime `personCapacityFactor` through a
  `loadConstruction` `updateFn` wrapper (mod.lua:130–147), i.e. both
  mechanisms — data modifier and live command — coexist in one production
  mod.

`game.interface.setTownCapacities` (present on Build 35924, still uncalled
anywhere) may be redundant given `setTownInfo`; prefer the command form.

## Timetables (2408373260) — the departure-slot mechanism, five years in production

`res/scripts/celmi/timetables/timetable_helper.lua`:

- **Arrival detection is a supported read**: `TRANSPORT_VEHICLE.state == 2`
  means at-terminal (`getTrainLocations`, line 33), combined with
  `stopIndex` for which stop. No polling of positions, no native hook.
- **Holding is the stock stop command**: hold with
  `api.cmd.make.setUserStopped(vehicle, true)`, release with `false`
  (lines 99–109).

Mapping to this project: the operation codec already models
`vehicle.stop`/start as canonical ordered operations, and `stopIndex` +
lifecycle state are already in the mobility digests. Host-ordered departure
slots are therefore: observe `state == 2` at the slot stop, hold via the
existing ordered `vehicle.stop`, release on the slot tick — bounded per-lap
drift using only machinery that already exists plus a scheduler. The
Timetables mod is five years of field evidence that per-station
hold-and-release does not break native vehicle behavior.

## Doug Dawson's load-speed mod (1967180838) — the dwell lever pattern

`mod.lua:62–100`: a model modifier mutates
`data.metadata.transportVehicle.loadSpeed` (clamps, scales, divides by
compartment count). Confirms the exact metadata path and the modifier hook
for a fixed-dwell/instant-load data mod, and that per-compartment semantics
matter when normalizing.

## Advanced Town Builder (2308330610) — town buildings as ordinary constructions

Places town-like buildings through a custom `.con`
(`advanced_town_builder.con`) via the standard construction menu, detected in
`guiHandleEvent` by `param.proposal.toAdd[1].fileName`. Demonstrates that
town-scale building placement works as an ordinary named construction — the
same portable named-`.con` path schema 7 already replays with physical
consensus. Host-authored growth can materialize buildings exactly this way.

## Advanced Statistics (2454731512) — read patterns

Uses `api.engine.util.getTransportedData()` with an availability guard.
Notably, per-vehicle `cargoLoad` appears only as a commented-out field
(`script/data/vehicle.lua:67`), suggesting the author found no reliable
per-vehicle load read — consistent with this repository's finding that
per-vehicle occupancy is not exposed. One follow-up for the live session:
dump a full `TRANSPORT_VEHICLE` component to see whether a load-ish field
exists at all on Build 35924.

## Towns Development Active (2044636379)

Same `setTownDevelopmentActive` technique this project already live-proves;
its value is the documented save-persistence behavior (the flag persists in
saves after mod removal), which the pinned-save workflow already absorbs.

## Probe-list impact on AGENTS_OFF_OVERHAUL_RESEARCH_2026-08-05.md §8

| Probe | Status after archaeology |
|---|---|
| 1. Zero-capacity world | Mechanism confirmed (modifier + `personCapacity`); only "is 0 safe or floor at 1" remains live. |
| 2. `setTownCapacities` semantics | Superseded: use the `setTownInfo` command (signature confirmed in production). |
| 3. `simulateCargoWeight=false` | Still live (config flag untested in any read mod). |
| 4. Instant-load dwell | Mechanism confirmed (`metadata.transportVehicle.loadSpeed` modifier); variance measurement still live. |
| 5. `findPath` return shape | Still live. |
| 6. `setMarker`/`setZone` fidelity | Still live. |
| 7. Kinematic drift soak | Still live (now with hold/release slots grounded by Timetables). |
| 8. `developTown`/cargo-needs semantics | `instantlyUpdateTownCargoNeeds` + `setTownInfo` answered from code; `developTown` payload still live. |

Net: the one-session live list shrinks to probes 1 (the 0-vs-1 floor), 3, 4
(measurement only), 5, 6, 7, and the `developTown` payload — everything else
moved to confirmed.
