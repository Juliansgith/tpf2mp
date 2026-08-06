# Physical town development, as a measurable experiment

Date: 2026-08-06 (Europe/Amsterdam)  
Scope: towns can now gain buildings as a consequence of the service they
receive. Shipped **off by default**, because whether native development is
deterministic enough to keep is exactly what this slice is built to find out.

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

## What each outcome means

- **Digests converge** — native development is deterministic under identical
  ordered calls, visible town growth is nearly free, and the feature can be
  switched on by default.
- **Digests diverge** — native lot choice is per-peer random. That is a real
  finding, arrives on the first attempt, and makes authored placement through
  the schema-7 construction pipeline the plan. The building data is already
  portable there; only lot selection would need writing.

Either way the answer costs one session instead of a research project.

## Fail-soft and bounded

An unavailable `developTown` factory or an unmapped town is recorded in
`probes.townDevelopment.errors` and skipped — a growth experiment must never
fault an otherwise healthy session. The protocol validator bounds the batch
strictly: canonical `town:` ids only, 1-8 calls each, at most 512 towns, exact
field set.

Native tags 19-22 remain ungated in the hook, as with the existing town
commands. Acceptable for trusted sessions; listed as required before town
commands are adversary-safe.

## Tests

`tests/run_lua_tests.lua` (68/68): points banking below the threshold and
carrying their remainder forward; a boom clamped to the per-settlement
maximum with a bounded accumulator; identical inputs producing identical
batches; one native call per due building with the right local id; and an
unmapped town reported rather than silently developed.
`tests/test_companion.py`: the `town.develop` validator rejects malformed
ids, out-of-range counts, oversized batches, and unknown fields.

Full offline suite passes (79 Python, 68 Lua, boundaries, cross-language
replay with an unchanged model digest — development changes no authored
model state).

## Also in this slice

The auto-registration policy and the ordered-development handler both moved
into `corridor_binding.lua`, because the game script crossed its source
budget again. The gate keeps doing its job: growth policy, registration
policy, and schedule policy now live together in the module that owns
corridor behaviour, and the game script keeps only the dispatch.

## Live verification owed

- Turn **Physical town growth (experimental)** on, run several settlements,
  and compare structural digests across two peers. That is the whole
  experiment.
- Watch what the towns look like after a dozen buildings: spaghetti is
  acceptable, a wall of towers on one tile is not.
- Confirm growth pacing feels right; 400 carried passengers per building is a
  first guess sitting beside the other constants.
