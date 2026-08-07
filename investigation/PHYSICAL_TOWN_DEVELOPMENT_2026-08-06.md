# Physical town development, as a measurable experiment

Date: 2026-08-06 (Europe/Amsterdam)  
Scope: towns can gain physical buildings as a consequence of the service they
receive. The exact two-process determinism experiment now passes; the option
remains **off by default** until growth pacing and appearance are playtested.

## Why this, and why as an experiment

Capacity growth already works and converges, but a town whose capacity rises
without gaining buildings still looks frozen — and frozen towns are the thing
testers objected to by name. The permission slip came from the same feedback:
*"the town builder as is builds a spaghetti, I'm not sure we'd really notice a
difference."* We do not need a good town planner. We need towns that grow.

Two routes existed. Authored placement through the construction pipeline is
fully deterministic but requires reading lots and choosing positions
ourselves. Host-ordered `developTown` lets the game's own logic choose, and
costs almost nothing — *if* two peers running the same call produce the same
buildings. Nobody knows whether they do.

Rather than guess, this implements the cheap route in a way that measures
itself: both peers make identical ordered calls, and the structural digest
they already compare says whether the results agreed. One live session with
the setting on answers a question that has been open since the agents-off
research.

## Pipeline

1. **Points accumulate.** `accumulateDevelopment` adds each settlement's
   carried passengers per town (the same `carriedByTown` split that feeds
   capacity growth) and spends them in whole buildings at 400 carried
   passengers each. A quiet corridor banks progress rather than losing it; a
   boom is capped at two buildings per town per settlement and the
   accumulator is bounded, so no single settlement can flood a world.
2. **The host orders a batch.** `settleDevelopment` turns what is due into
   one `town.develop` action carrying the canonical town ids and call counts.
   Only the host emits; in standalone it applies directly.
3. **Both peers apply it identically.** The handler issues one native
   `developTown` per due building, then immediately refreshes the structural
   probe so the *next* checkpoint compares the world these calls produced
   rather than the one before them.
4. **The digest judges.** No new comparison is introduced: town buildings
   already live in the structural snapshot. If the two worlds diverge, the
   existing structural digest says so.

## Experiment outcome

The convergent branch won. In session
`round3-town-construction-pos-20260807`, two exact Build 35924 processes began
from the same physical town state and applied three rounds of eight ordered
development calls. Both peers selected the same local candidate set, produced
the same town after every round, and converged the dedicated development and
final structural checkpoints.

## Strict, atomic, and bounded

The production network contract is fail-closed. Before the first native call,
each peer resolves every canonical town through its local manifest. An
unmapped town or native command error rejects the whole action; it is never
reported as a partially successful batch. Lua and Python both require the
exact field set, canonical `town:` ids only, integer call counts from 1 through
8, and at most 512 towns.

Native tags 19-22 remain ungated in the hook, as with the existing town
commands. Acceptable for trusted sessions; listed as required before town
commands are adversary-safe.

## Tests

`tests/run_lua_tests.lua` (71/71): points banking below the threshold and
carrying their remainder forward; a boom clamped to the per-settlement
maximum with a bounded accumulator; identical inputs producing identical
batches; one native call per due building with the right local id; and an
unmapped town rejected before mutation. Runtime-module coverage also drives
the extracted three-round validator through each development checkpoint, its
native settle window, and the final ordered structural boundary.

The full offline suite passes: 71 Lua cases, 73 Lua/Python economy vectors,
99 Python companion/consensus/restore tests, source-boundary checks, syntax,
and long cross-language replay. Development points and placement cursors are
authored, digest-projected, and replayed; native entity ids remain local.

## Also in this slice

`corridor_binding.lua` owns growth calculation and deterministic candidate
selection. `authored_followup_runtime.lua` owns strict ordered application and
checkpoint export. `validation_town_development.lua` owns only the live
three-round experiment. This keeps production policy, application, and test
orchestration separate.

## Exact live result (2026-08-07)

Evidence:
`runtime/localhost-live/round3-town-construction-pos-20260807/run-status.json`.

- Both peers passed (`52` host checks, `39` client checks).
- Initial structure digest: `1ef990cc`; final: `2de890d4` on both peers.
- Northfleet capacity moved identically from `633` to `657`, `687`, then
  `704`; intermediate digests were `4f3b90dd`, `4c6390e2`, and `2de890d4`.
- The final ordered structural boundary was sequence `22`; both peers ended at
  core `b418e90f` and model `ca0582b4` with no consensus fault.
- The run issued 24 physical development calls in total and proved an actual
  structural change rather than merely identical no-ops.

This closes the engine-determinism gate for the tested starting world. It does
not yet settle product questions: watch several towns after dozens of
buildings, tune the current 400-carried-passenger threshold, and perform the
true two-computer latency/usability run before enabling growth by default.

## Follow-up hardening (2026-08-06)

The ordered handler is now strict and atomic at the script boundary. Lua and
Python accept the same exact action shape: at most 512 canonical `town:` ids,
integer call counts from 1 through 8, and no unknown fields. Before issuing any
native command, Lua resolves every canonical town through the local manifest;
one missing binding rejects the entire action, so peers cannot acknowledge a
partially applied batch. A native command error also rejects the action.

Successful development now opens a dedicated `town-development` checkpoint.
That makes the experiment answerable at the moment growth occurs instead of at
some later incidental checkpoint, and the companion reconstructs the pending
tracker after restart. The environment-driven localhost launcher can enable
the experiment without rebuilding the source mod.

The original fail-soft prototype is superseded by the strict contract above.
See `ADVERSARIAL_AUDIT_ROUND3_2026-08-06.md` for the static audit and
`AUTOMATED_NATIVE_WORLD_AND_POLICY_EVIDENCE_2026-08-07.md` for the launcher and
fresh-world policy controls used alongside this experiment.
