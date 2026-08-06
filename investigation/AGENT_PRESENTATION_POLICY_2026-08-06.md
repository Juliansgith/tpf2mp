# Agent presentation policy: skeleton crew

Date: 2026-08-06 (Europe/Amsterdam)  
Scope: the native crowd becomes a chosen presentation cost rather than an
unexamined default. Implements the agents-off research
(`AGENTS_OFF_OVERHAUL_RESEARCH_2026-08-05.md`) using the mechanisms the
Workshop archaeology confirmed, with the outstanding probes folded into the
implementation so one live match answers them.

## The principle

The competitive model owns demand, allocation, revenue, and score. Native sim
agents are decoration: never read as market truth, never scored. Vanilla
simulates the whole region population continuously — community measurement
puts lag onset near 30k sims and unplayability at 75-150k, single-thread
bound — so the crowd is a cost the player should be able to choose.

## Three policies, one number apart

| Mode | Capacity | Dwell | Cargo weight | Recompute | Effect |
|---|---|---|---|---|---|
| `vanilla` | unchanged | native | on | 100% | full population, full cost |
| `skeleton` (default) | ÷64, floor 1 | pinned | off | 25% | one inhabitant per building; platforms, streets and vehicles stay alive at roughly a tenth of the cost |
| `empty` | 0 | pinned | off | 0% | no agents; the model and its boards are the only passenger story |

Selected from the mod's own settings (`Native crowd simulation`) or
`TPF2MP_AGENT_MODE`.

**Skeleton is the default and the recommendation.** It answers the only real
objection to agents-off — a dead-looking world — for almost nothing, and it
is the same lever as `empty`, one integer apart.

## Implementation

`tpf2_mp/presentation.lua` holds the policy table, the deterministic capacity
scaler, the match fingerprint, and the runtime application. `mod.lua` applies
the data side at load:

- **`loadConstruction` modifier** wraps every `TOWN_BUILDING` `updateFn` and
  scales `personCapacity.capacity` — the mechanism the public Capacity Factor
  mod uses, confirmed by source reading. Sims exist because of that field, so
  scaling it scales the crowd.
- **`loadModel` modifier** pins `metadata.transportVehicle.loadSpeed` so
  dwell stops depending on how many agents board.
- **Shipped decouplers**: `game.config.simulateCargoWeight` (load→physics)
  and `simPersonDestinationRecomputationProbability` (the dominant per-agent
  cost).

`mod.lua` loads the module through a guarded `require`: a mod whose entry
point throws does not load at all, so an unreachable module degrades to the
vanilla policy rather than a partial one.

### Why this makes the economy more correct, not just faster

`SERVICE_FACTS.dwellSecondsPerStop` assumes a fixed 45-second stop. With
native dwell varying by boarding, that was a systematic approximation. With
load speed pinned, it describes the world exactly. The pivot does not only
buy performance — it makes the model's own inputs true.

## The probe is now the implementation

The data modifier only reaches buildings created after it loads, so a
pre-existing save keeps its original population. `setTownInfo` is the runtime
lever for those towns, and its exact effect on Build 35924 was one of the
outstanding research probes.

Rather than schedule a separate session, `applyToWorld` runs at match
initialisation: it scales each town's land-use capacities, **reads the value
back**, and records what actually happened in `probes.agentPolicy` —
`towns`, `applied`, `verified`, `unchanged`, `errors`, before/after totals,
and a `runtimeScalingWorks` verdict. A build that silently ignores the write
is reported as unverified, never assumed successful.

So the first live match with a non-vanilla policy answers:

- does `setTownInfo` scale an existing world (`runtimeScalingWorks`)?
- if not, do freshly generated saves carry scaled buildings (native sim
  counts in the mobility probe)?
- does anything destabilise at capacity 1 (errors, town UI, engine health)?

## Match content, not a local preference

Building capacities feed the structural digest, so peers running different
policies would build different worlds from identical commands. The policy
label and a `fingerprint` covering every value travel in the runtime config
alongside the pinned mod set, and the applied outcome carries the
`configuredFingerprint` it was derived from.

## Tests

`tests/run_lua_tests.lua` (59/59): exact scaling per mode including the
floor-of-one and the vanilla identity; distinct, stable fingerprints per
policy; readback verification proving `runtimeScalingWorks` true on a
cooperative build and **false** on one that ignores the write; the vanilla
policy issuing no commands and touching no town.
`tests/run_mod_launcher_config_tests.lua` now mirrors the game's module path
so the harness exercises the real `require` rather than a stub.

## Not done

- No physical building placement, so towns still do not visibly grow
  (that remains the schema-7 construction-event layer).
- `setMarker`/`setZone` world-anchored presentation is still unexercised.
- Cosmetic native-state writes (fake occupants in vehicles) remain native
  hook work, with `Debug_SetSimPersonState` (tag 36) as the mapped lead.
- Mobility aggregate comparison is unchanged; under a reduced policy its
  counts simply go small. Retiring it to structural facts is a follow-up
  once a live run shows what the counts actually do.

## Suite status at time of writing

My slice passes: 59/59 Lua, runtime module boundaries, game-script
integration, and the launcher-config mod test under the suite's fixture. The
full `run_tests.ps1` currently stops earlier on an unrelated in-flight edit
to `gui_event_runtime.lua` exceeding its source budget by 34 lines; that file
is untouched by this work.
