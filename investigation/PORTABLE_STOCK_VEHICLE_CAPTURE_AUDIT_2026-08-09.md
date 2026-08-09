# Portable stock-vehicle capture audit

Date: 2026-08-09 (Europe/Amsterdam)
Prototype: `0.34.0-alpha`
State schema: `29`
Operation schema: `3`
Economy model: `8`

## Outcome

The portable operation codec was already carrier-neutral, but the ordinary
stock vehicle-manager boundary was not. `normaliseOperationCapture` extracted
only `vehicle/train/*.mdl` and `vehicle/waggon/*.mdl` from the GUI payload.
Consequently a native bus, truck, tram, ship, aircraft, or mod-namespaced
purchase could be suppressed successfully and paired with the correct depot,
then fail before an ordered transaction was created. Codec-only carrier tests
did not exercise that missing link.

The capture boundary now accepts any bounded portable `vehicle/*.mdl`
resource. Repository lookup remains mandatory when the typed config is built,
so accepting a namespace is not the same as trusting an absent resource.
Traversal is cycle-safe and fails closed on excessive depth, payload size, or
part count; it cannot silently buy a truncated consist.

The installed Build 35924 source supplies useful independent shape evidence.
`res/scripts/mission/vehiclestore.lua` handles
`vehicleManager` / `accept`, iterates `param.vehicleConfig` from `1` through
`#param.vehicleConfig`, and treats every element as the model filename. That is
the flat ordered list preserved by the TPF2MP GUI/native FIFO correlation.

## Additional findings closed

### Replacement left stale competitive facts

A successful `vehicle.replace` refreshed the exact native maintenance basis,
but did not refresh the canonical binding's consist models or automatically
re-register the assigned line. A faster or larger replacement could therefore
move correctly while the competitive model and manager projection continued
to describe the old consist.

Completed replacement now deep-copies the ordered config into the canonical
vehicle binding. After all-peer physical consensus, the owning peer schedules
the same coalescing `line.register` follow-up used by assignment. This re-reads
the real replaced consist, carries new speed/capacity/upkeep facts through the
ordered action, and opens the normal checkpoint barrier.

### Empty legacy line invented capacity

The computed-geometry service path already assigned zero capacity to a line
with no vehicles. Its unreadable-geometry compatibility fallback instead used
`max(50, native rate)`, so a stale native rate could give an empty service 50
units of modeled capacity. The fallback now preserves the zero-vehicle
invariant. A regression uses an unresolved route with native rate `999` and no
vehicles and requires capacity zero.

### Live evidence was hard to read after shutdown

`Export Research` now includes the complete public authoritative economy
projection. The rendered Markdown report contains one row per canonical line:
company, passenger/cargo kind, carrier, local/corridor scope, vehicle and
capacity facts, `factsSource`, feeder benefit/endpoints, delivered traffic, and
net authored revenue. This makes tomorrow's non-rail run auditable without
keeping either game process open.

## Automated evidence

- `122/122` core Lua tests, including portable GUI extraction limits, empty
  legacy capacity, replacement metadata, and replacement re-registration;
- ordinary GUI/native FIFO fixtures for rail, bus, truck, tram, ship, plane,
  and a mod namespace;
- `108/108` Lua/Python economy scenarios: the prior 76 plus 32 deterministic
  model-v8 multimodal feeder fuzz cases;
- research-renderer coverage for both a rail corridor and local road feeder;
- `129/129` Python protocol/network/checkpoint/recovery/report tests;
- runtime, game-script, ownership, GUI, hot-seat, network-company, 1,024-event
  replay, source-boundary, Lua/PowerShell syntax, launcher, watcher, release
  manifest, and checkpoint replay gates.

`tools/run_tests.ps1` passed after the complete change set. Release packaging
and an installed-package verification remain a separate final gate below the
source-level suite.

## Honest live boundary

No non-rail vehicle has yet completed the ordinary two-process purchase,
assignment, movement, endpoint barrier, delivery, and settlement sequence.
The next live test remains one bus or tram feeder first, followed by one truck,
ship, and aircraft route. Stock GUI model order is source-backed and the whole
offline capture/replay chain is covered, but Build 35924 can still expose a
carrier-specific depot or route behavior that mocks cannot prove.

The stock accept event exposes filenames, not every advanced editor choice.
TPF2MP currently reconstructs the engine's default per-model load selection,
color, logo, and orientation. Exact custom liveries, reversed consist parts,
and user-selected alternative cargo load configurations therefore remain an
explicit future capture-schema item rather than an implied claim of this fix.
