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
| `empty` (compatibility key) | ÷1,000,000,000, floor 1 | pinned | off | 0% | minimum-safe crowd; every positive-capacity building keeps one native slot |

Selected from the mod's own settings (`Native crowd simulation`) or
`TPF2MP_AGENT_MODE`.

**Skeleton is the default and the recommendation.** It answers the only real
objection to agents-off — a dead-looking world — for almost nothing. The
legacy `empty` key now means minimum-safe crowd: literal zero capacity crashes
Build 35924 during fresh-world generation and is no longer offered.

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

## Probe semantics after live testing

Build 35924 accepted `setTownInfo` against an existing world but did not change
the relevant native capacities. Runtime mutation is therefore deliberately
disabled. `runtimeScalingWorks=false` is the expected honest result, not a
policy failure.

`probes.agentPolicy` now distinguishes the two mechanisms:

- `constructionScalingActive` says the selected `loadConstruction` modifier
  was active while a fresh world loaded its town buildings;
- `runtimeScalingWorks` remains false because existing-world capacity writes
  are not used;
- `mode` and `configuredFingerprint` identify the exact policy that produced
  the observed native population.

Operational capture carries this object beside construction count, total town
capacity, and direct person count so a small crowd is never accepted as proof
without the configuration/readback evidence.

## Match content, not a local preference

Building capacities feed the structural digest, so peers running different
policies would build different worlds from identical commands. Launchers now
write a deterministic `match-content-profile.json` containing `agentMode` and
the town-development flag and include it in the match manifest. The launcher
config is authoritative over stale mod-menu settings, and the applied outcome
carries the `configuredFingerprint` it was derived from.

## Tests

`tests/run_lua_tests.lua` (71/71): exact scaling per mode including the
minimum-safe floor and vanilla identity; distinct stable fingerprints;
readback behavior on cooperative and ignored writes; and the production rule
that configured policies never runtime-mutate an existing network world.
`tests/run_mod_launcher_config_tests.lua` now mirrors the game's module path
so the harness exercises the real `require` rather than a stub.

## Exact live evidence (2026-08-07)

The native-world launcher follows the stock **Free Game → Next → Start**
wizard, so these worlds actually load the selected mod modifiers. The earlier
`app.startGame()` route is not valid policy evidence because it can bypass
active mod data modifiers.

- Skeleton:
  `runtime/localhost-live/round3-skeleton-native-fresh-v4-20260807`.
  Player 1 had 584 constructions, town capacity 563, and 267 persons; Player 2
  had 409, 388, and 190. Capacity per construction was about 0.95.
- Vanilla control:
  `runtime/localhost-live/round3-vanilla-native-fresh-20260807`.
  The two independent worlds reported 374/493 constructions,
  1263/1857 town capacity, and 428/628 persons. Capacity per construction was
  3.38-3.77, several times the reduced policies.
- Literal zero negative:
  `runtime/localhost-live/round3-empty-native-fresh-20260807`.
  Build 35924 raised a fatal `PersonCapacity` component assertion for entity
  20061 during world initialization; dump id
  `5d1f7ac5-ac61-4b64-ac43-e298caf2ce76`.
- Minimum-safe replacement:
  `runtime/localhost-live/round3-minimum-native-fresh-20260807`.
  Both worlds passed: 429/410 constructions, 408/389 capacity, and 208/193
  persons. Both reported `mode=empty`,
  `constructionScalingActive=true`, and the expected pinned fingerprint.

These are independent local worlds, not a network-consensus claim. They prove
that fresh-world construction scaling runs, that literal zero is unsafe, and
that the replacement loads cleanly.

## Passenger-display follow-up (2026-08-07)

State 24 now owns a separate exact passenger ledger. Settled model allocation
becomes endpoint queues; the existing ordered station release moves a bounded
share onto the train, preserves it at intermediate stops, and alights it at the
opposite terminal. Checkpoint format 4 binds those counts and cursors to the
canonical vehicle release state. A selection-aware TPF2MP HUD renders the exact
train, line, and station numbers while the small native crowd remains scenery.

The mapped tag-36 lead was resolved statically. Its real visitor consumes an
eight-byte `{ personEntityId, booleanSelector }` payload. It contains no train,
station, terminal, line, or canonical destination, so it cannot safely inject a
person into a requested target. The shipped adapter probes the command factory
shape and native ECS counts but issues zero writes. A target-bearing operation
or an exact-build stock-UI value hook would be required to change that policy.

## Not done

- Physical town development now exists and passes an exact two-process
  three-round convergence experiment; pacing and visual quality remain open.
- `setMarker`/`setZone` world-anchored presentation is still unexercised.
- Native target-addressed cosmetic occupants remain unavailable; tag 36 is
  explicitly insufficient and fails closed.
- Mobility aggregate comparison is unchanged; under a reduced policy its
  counts simply go small. Retiring it to structural facts is a follow-up
  once a live run shows what the counts actually do.

## Suite status at time of writing

The complete `tools/run_tests.ps1` gate passes: 75 core Lua tests, 73
cross-language economy vectors, game/GUI/launcher integrations, syntax and
architecture ratchets, 100 Python tests, and both long replay reports. The
native Release build and both CTest cases also pass against all 17 signatures
of the pinned executable.
