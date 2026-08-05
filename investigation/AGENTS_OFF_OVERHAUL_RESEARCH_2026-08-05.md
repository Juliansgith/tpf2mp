# Agents-off overhaul: feasibility research

Date: 2026-08-05 (Europe/Amsterdam)  
Author: Claude, research only — no implementation.  
Question: can the native agent simulation be removed (or fully demoted) so the
canonical model owns demand, growth, and presentation, dissolving the
autonomous-sync problem and the agent CPU ceiling?

Sources: Build 35924 game files at
`F:\SteamLibrary\steamapps\common\Transport Fever 2` (config, shipped scripts,
model archives), this repository's live capability-probe corpus, and the
public modding ecosystem. Confidence tiers: **[CONFIRMED]** read directly from
game files or this repo's live probe exports; **[ECOSYSTEM]** established
community technique; **[PROBE]** needs a live session to settle; **[RE]**
needs native reverse engineering.

## Executive summary

Every load-bearing lever exists on a supported surface. Zero-spawn is
reachable through building `personCapacity` data (the technique behind the
public "Population Factor" mod) combined with the already-live development
freeze; the load→physics coupling can be severed by one shipped config flag;
dwell becomes deterministic by data or trivially by having nothing to load;
world-anchored presentation has two documented channels (`setMarker`/`setZone`
and the GUI widget toolkit). The one thing with **no supported path** is
writing cosmetic sim state (fake occupants in vehicles, fake queue sprites on
platforms): the scripting API is read-only outside commands, so Tier-2
presentation is native-hook territory. Nothing found contradicts the
agents-off direction; the CPU argument is quantified and decisive.

## 1. Zero-spawn (flavor A)

**Mechanism of spawning.** Town sims exist because town buildings carry
`personCapacity = { type = landUseType, capacity = ... }`, assigned at
construction by `res/scripts/townbuildingutil.lua` (lines 146–151, 319–321)
from town-simulation parameters. People are simulated *from* building
capacity; no capacity, no sims. **[CONFIRMED]**

**Levers, in order of preference:**

1. **Data-level capacity zeroing.** A pure-Lua mod shadowing
   `townbuildingutil.make_building*` (or a metadata modifier over town
   buildings) forces `personCapacity.capacity = 0`. The public
   "Population Factor" mod applies exactly this multiplier technique
   (0.5 = half population); 0 (or a 0.01 floor if the engine dislikes zero) is
   the same move. **[ECOSYSTEM]** Because this project already generates and
   byte-pins its starting saves, a save generated with the zero-capacity mod
   active is a clean empty world from tick zero — no retroactive surgery
   needed. Existing pinned saves would be regenerated once. **[PROBE: does
   capacity 0 destabilise town building assignment or UI?]**
2. **`game.interface.setTownCapacities`** — **present on Build 35924**
   (probed live, `yes` in every post-correction export; see §7) but never
   yet called. If its semantics allow zeroing at runtime, existing pinned
   saves need no regeneration. **[CONFIRMED presence; PROBE semantics]**
3. **Industry silence.** `game.config.economy.industryDevelopment` ships with
   `spawnIndustries = false` already available, plus closure controls
   (`base_config.lua:472–484`); cargo generation follows industry production
   and town `cargoNeedsPerTown` (config). Frozen industries + zero town
   cargo needs = no cargo items. **[CONFIRMED config surface; PROBE for
   full silence]**
4. **Development freeze** — already live-proven by this project
   (`world.freezeAutonomy`: `setTownDevelopmentActive(id, false)` per town,
   manual industry development). The public "No Town Development" mod uses
   the same API, with a documented caveat this project already handles by
   pinned saves: the flag persists into savegames. **[CONFIRMED]**

**Ambient consequences of empty towns:** town cars/trucks are commuting sims —
they disappear with the population (this is the visual cost, §4); the
`townhudicon` population labels will show static/zero values — the overhaul's
own UI owns those numbers instead (§5).

## 2. Determinism decouplers

- **`game.config.simulateCargoWeight = true`** (`base_config.lua:184`) — a
  shipped boolean that couples load to vehicle physics. Setting it false
  severs load→weight→kinematics, making vehicle motion independent of
  occupancy even under flavor B. **[CONFIRMED flag; PROBE semantics]**
- **`game.config.simPersonDestinationRecomputationProbability = 1.0`**
  (`base_config.lua:185`) — a shipped dial on the single most expensive agent
  behavior (destination/path recomputation). Relevant only to flavor B
  (agents-as-decoration): lowering it caps their CPU without killing them.
  **[CONFIRMED flag]**
- **Dwell.** Per-vehicle `loadSpeed` is plain `.mdl` data (confirmed in
  `model.zip` train entries; community practice edits it directly). A
  metadata modifier can set effectively-instant loading for every vehicle;
  with agents off there is nothing to load and stop time collapses to engine
  constants. Either way dwell stops being a function of unsynced sims.
  **[CONFIRMED data field / ECOSYSTEM technique]**
- **`game.config.trainAccelerationFactor` / `trainBrakeDeceleration`**
  (`base_config.lua:196–197`) — global kinematic constants, identical on both
  peers by shipped default; useful later if computed journey times need to
  match a closed-form performance model. **[CONFIRMED]**

## 3. Computed service facts (journey/headway/capacity without observation)

- `game.interface.findPath(stationA, stationB, transportModes)` is a shipped,
  documented reachability query (used by `missionutil.lua:371`) — supported
  line-connectivity validation. Whether it returns distance/legs needs one
  probe. **[CONFIRMED presence; PROBE return shape]**
- Track geometry (edge lengths, speed limits) is already canonically read by
  this project's proposal pipeline; consist specs (speed, capacity,
  `loadSpeed`) are repository data readable by name — the same data-first
  resolution the codecs already use. A closed-form journey-time model
  (accelerate–cruise–brake per edge chain with the two global constants
  above) is ordinary integer math on data both peers share by construction.
  **[CONFIRMED inputs exist]**
- `api.engine.util.getTransportedData`, `simPersonSystem.getCount`,
  `getSimPersonsForLine`, `simCargoSystem.getSimCargosForLine`,
  `simPersonAtTerminalSystem.getEdgeInfoMap` are the shipped read family the
  mobility telemetry already uses — they become irrelevant (return zeros)
  under flavor A, and stay per-peer diagnostics under B. **[CONFIRMED]**

## 4. Presentation channels

**Tier 1 — owned UI (guaranteed).** The stock GUI toolkit is broad:
`game.gui.component_create/boxLayout/absoluteLayout_setPosition/imageView_*`
plus window creation the mod already performs. Screen-anchored overlays,
station boards, bucketed crowd icons (small=10–20, large=50–100, huge=500+),
line-load bars: all ordinary widget work driven by model numbers, per-peer,
zero digest surface. **[CONFIRMED]**

**Tier 1.5 — world-anchored engine visuals (documented, mission-grade).**
`game.interface.setMarker(key, marker)` and `setZone(key, zone)` are the
engine's own world-anchored display primitives (mission system:
`taskutil.lua:312–333, 567–576`, called from the engine thread). Markers pin
icons to world positions; zones draw terrain shapes. This is a supported
channel for "icon above station" without any custom projection math.
**[CONFIRMED presence; PROBE visual fidelity/limits — icon set, scale,
count budget]**

**Tier 2 — cosmetic native state (fake passengers in trains, platform
crowds, cargo piles). No supported write path exists.** The scripting API is
read-only outside the command system: the shipped scripts use only
`getComponent`/`forEachEntityWithComponent`/system getters, and no
`setComponent`-style function appears anywhere in the shipped script corpus.
Writing vehicle occupancy or station queue visuals therefore requires the
native hook (locate the render-relevant state, write it post-simulation,
prove no feedback into revenue or sim). Feasible for this project — it is the
same exact-build discipline as the command gates — but it is **[RE]**, not a
config flag, and it should be scheduled as post-v1 polish, not core scope.
CommonAPI2 offers runtime/debug access that might shortcut exploration, but
it is a third-party dependency requiring the same licence audit the project
applied to Multiplayer Companies — do not bundle without permission.

**Tier 3 — ambient road traffic.** Town cars are commuting sims; no
parametric traffic system exists to keep cars without people. Accept empty
roads at launch, or leave flavor B as an opt-in "ambient life" toggle
per player. **[CONFIRMED by construction]**

## 5. Town growth, host-authored

`setTownDevelopmentActive` (freeze) is live-proven; `developTown` and
`instantlyUpdateTownCargoNeeds` exist as probed command factories awaiting
semantics probes; town land-use capacities are readable
(`getLandUsePersonCapacities`) and buildings are placeable through the
already-live schema-7 construction pipeline. The host-authored growth design
(model growth points → ordered construction events → physical consensus)
stands unchanged; agents-off removes the last tension with native growth
inputs, since the `advancedOptions` sensitivity scales
(`publicTransportDestinationsSensitivityScale`,
`cargoSupplySensitivityScale`, `emissionSensitivityScale`,
`trafficSpeedSensitivityScale`, `stationOverflowSensitivityScale`,
`base_config.lua:486–495`) confirm vanilla growth is driven by exactly the
agent-derived inputs that will read zero. Vanilla growth starves by itself in
an empty world; ours replaces it. **[CONFIRMED surface]**

## 6. Performance case (quantified)

Community evidence is unambiguous: the region population is simulated in its
entirety, pathfinding for those agents is the dominant CPU cost, the
simulation is effectively single-thread-bound, ~30k sims marks lag onset and
~75–150k is unplayable, and there is no engine cap. The canonical model
evaluates a 25,000-passenger corridor as a handful of integer operations per
settle. Removing agents deletes the game's scaling ceiling; the overhaul can
honestly advertise *larger populations than vanilla at higher framerates*.
Config-level mitigations that exist today
(`simPersonDestinationRecomputationProbability`, population-factor data
mods, dynamic-industry off) are the community already fighting this cost with
the same levers we would pull to zero.

## 7. Build 35924 probe-corpus evidence

(From this repository's live research exports and investigation corpus,
recorded on the exact pinned build.)

- **`game.interface.setTownCapacities` is PRESENT** — capability probe
  `world.lua:2037` records `yes` in multiple live exports
  (`runtime/live-validation/20260804-024044/research.md:52`,
  `20260801-183544/research.md:36`). It has never been called in production
  code; signature and despawn semantics are unrecorded → §8 probe 2 stands.
- **`setTownDevelopmentActive(townId, bool)` is present and live-effective**:
  355 samples across both peers held development frozen
  (`investigation/OPERATIONAL_CAPTURE_LAB_2026-08-02.md:101-136`).
- **Town command factories all present, never issued**: `developTown`,
  `setTownInfo`, `instantlyUpdateTownCargoNeeds` probe `yes` (as callable
  tables). The native town command family is tags 17–22 (`CreateTowns`,
  `RemoveTown`, `DevelopTown`, `SetTownInfo`,
  `InstantlyUpdateTownCargoNeeds`, `ConnectTownsAndIndustries`) per
  `NATIVE_COMMAND_PIPELINE_BUILD35924_2026-08-01.md:70-88` — a complete
  host-authored growth command surface already mapped.
- **The four documented sim convenience readers are ABSENT on this build**
  (`simPersonSystem.getCount`, `getSimPersonsForLine`,
  `simCargoSystem.getSimCargosForLine`,
  `simPersonAtTerminalSystem.getEdgeInfoMap`) — `no` in engine and GUI
  states, in empty *and populated* worlds
  (`OPERATIONAL_CAPTURE_LAB_2026-08-02.md:140-144`). The working read path is
  direct ECS traversal via `forEachEntityWithComponent` over `SIM_PERSON`,
  `SIM_CARGO`, `SIM_ENTITY_AT_VEHICLE`, `SIM_ENTITY_AT_TERMINAL`
  (`world.lua:1584-1816`), live-proven identical on both peers (413 persons,
  digest `a7ae06ac`). Under flavor A these reads return zero and retire; the
  zero-spawn acceptance check in §8 uses the direct counts, not the absent
  conveniences.
- **ECS write surface: none, definitively.** The entire repository's
  aggressive surface-hunting touches exactly five `api.engine` members
  (`getComponent`, `forEachEntityWithComponent`, `entityExists`, `system`,
  `terrain`); no `setComponent`/`addComponent`/entity-creation function
  exists in any probe or export. All mutation flows through `api.cmd`
  commands or legacy `game.interface` helpers. This settles §4 Tier 2 as
  native-hook-only — with one mapped entry point: the native command table
  includes **`Debug_SetSimPersonState` (tag 36)**, currently gated
  fail-closed and disclaimed as a steering path; as an RE lead for cosmetic
  state it is the first thing to disassemble when Tier 2 is scheduled.
- **Journey/headway are currently estimates, not measurements**:
  `world.lua:1356-1376` derives headway from the legacy line entity's
  `frequency` and journey as half an estimated cycle. No line-length API and
  no native vehicle capacity/`loadSpeed` read exists anywhere in the corpus
  (`api.res` access is `modelRep.find/getName` plus `trackTypeRep.find`
  only). §3's computed-service-facts work therefore needs either an
  `api.res` metadata probe (does the model record expose capacity/loadSpeed
  at runtime?) or match-pack parsing of the on-disk `.mdl` data — both
  viable; the `.mdl` fields are confirmed present in `model.zip`.
- **GUI**: no world-anchored UI exists anywhere in the corpus — all mod UI
  is screen-space windows plus stock-tree injection (bottom `gameInfo` bar,
  ESC menu, title menu — all live-proven). `game.gui.setCamera(entityId)`
  works. `setMarker`/`setZone` (§4 Tier 1.5) appear in shipped game scripts
  but have never been exercised by this project → their fidelity probe in §8
  is genuinely open.
- **Probe-predicate caveat**: capability markers recorded before 2026-08-01
  16:10 used `type(x) == "function"` and are invalid as negative evidence
  for `api.cmd.make.*` factories, which are callable tables on this build.
  All conclusions above rest on post-correction exports.

## 8. The live-probe session list (one sitting, ordered)

1. **Zero-capacity world**: regenerate a small pinned save with a
   capacity-zeroing data mod active; verify no sims spawn
   (`simPersonSystem.getCount == 0`), no cargo items, stable town UI, no
   engine errors over a 30-minute unpaused run.
2. **`setTownCapacities` semantics** (if present per §7): call on a populated
   town; observe capacity readback and whether existing sims despawn.
3. **`simulateCargoWeight = false`**: confirm loaded weight no longer alters
   acceleration (compare timings of a loaded vs empty consist under flavor B).
4. **Instant-load dwell**: metadata-modify `loadSpeed`; measure stop-time
   variance with agents on; confirm constant dwell.
5. **`findPath` return shape**: log the full return value for a two-station
   query; record whether distance/legs are exposed.
6. **`setMarker`/`setZone` fidelity**: place markers over stations; record
   icon options, scaling, and a 50-marker stress render.
7. **Kinematic drift soak** (the reframed two-computer gate): empty world,
   fixed dwell, one running train per company, unpaused hour, intermediate
   structural samples. Expected: convergence; any residual drift is cosmetic
   by architecture.
8. **`developTown` / `instantlyUpdateTownCargoNeeds` semantics** for the
   host-authored growth path.

## 9. Conclusions

- Flavor A (agents off) is reachable on supported surfaces; the pinned-save
  workflow makes it cleaner here than for any ordinary mod.
- Flavor B (agents as unsynced decoration) is a per-player toggle, not an
  architecture: `simulateCargoWeight=false` + instant load sever its only
  consequential couplings, at full agent CPU price.
- Presentation: Tier 1/1.5 ship with the overhaul; Tier 2 (cosmetic
  occupancy) is the only piece needing native RE and belongs in post-v1.
- Nothing discovered blocks the 1–2 month overhaul framing; the research
  moved every open question from "unknown" to either "confirmed" or "one
  probe in one live session."
