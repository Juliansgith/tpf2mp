# Canonical freight-industry authority

Date: 2026-08-09 (Europe/Amsterdam)

Prototype: `0.31.0-alpha`

State schema: `28`

Freight-industry schema: `1`

## Outcome

TPF2MP now owns a deterministic freight-industry substrate. After both peers
attest the exact loaded recipe registry, the host authors one sorted portable
bootstrap for every canonical live industry. The save and every checkpoint
then contain its evaluated recipe, input and output inventories, production
residual, last cycle count, and cumulative produced/consumed totals.

Production advances atomically with the existing authored economy settlement.
Lua and the independent Python checkpoint replayer implement the same integer
arithmetic and produce the same pinned digest. Native industries remain frozen
and are presentation scenery; they are not allowed to evolve as a second
authority.

This is not yet a transported-cargo claim. No canonical station queue, vehicle
load, completed-delivery action, cargo revenue from a real chain, or native
cargo display is connected to these inventories yet.

## Portable bootstrap contract

`freight.industry_bootstrap` contains only:

- schema version, agreed content digest, and current economy epoch;
- a canonical-ID-sorted list of live industries;
- for each industry, its portable `.con` resource, finite plain parameters,
  recipe digest, hourly capacity, indexed stocks, ordered input alternatives,
  and outputs;
- a digest over the complete normalized payload.

The companion limits the action to 2 MiB, 2,048 industries, 32 recipe items,
bounded strings and integers, exact field sets, canonical order, and positive
flow. Local native construction IDs never enter the action. Only Player 1 may
submit it, only after content agreement and match initialization, and its epoch
must match the current authored economy epoch on every peer.

Application is idempotent only for the same bootstrap digest. A second,
different bootstrap is rejected rather than replacing a running ledger.

## Production arithmetic

For industry capacity `C`, authored settlement duration `S`, and saved residual
`R`, one epoch computes:

```text
numerator = R + C * S
quota     = floor(numerator / 3600)
R'        = numerator mod 3600
```

Input alternatives retain their evaluated recipe order. The first alternative
with a positive feasible cycle count is consumed; an empty alternative is a
source and can produce its quota without input. Output and cumulative maps use
a shared `10^15` saturation boundary, below the exact-integer limit of Lua's
double representation. The production epoch must be exactly the previous epoch
plus one, and settlement applies the already-computed candidate only if the
passenger/economy action also succeeds.

Cargo deposits identify a canonical industry and cargo type. If a mod recipe
contains the same cargo in multiple stock slots, the target stock index is
mandatory; the convenience cargo-only call fails as ambiguous instead of
silently filling the wrong input.

## Save/load and mismatch policy

Industry content is session-scoped and freshly attested after load, whereas
inventories persist in the save. Settlement therefore remains blocked until
the saved bootstrap is revalidated against both:

1. the newly agreed content digest; and
2. a fresh enumeration of the current canonical live industries and their
   evaluated recipe bindings.

A changed resource pack, missing or duplicate canonical live binding, changed
parameters, different recipe digest, or malformed/tampered saved bootstrap
installs a deterministic fail-closed session fault. Old pre-schema-28 saves
start with an empty freight ledger and bootstrap only after the normal content
gate succeeds.

## Cross-language proof

The pinned fixture contains a source farm, a grain-to-food processor, and an
input-only consumer. It exercises residual production, zero-input sources,
stock deposit, multi-unit consumption, output withdrawal, cumulative totals,
migration, malformed bootstrap rejection, canonical ordering, epoch binding,
checkpoint replay, and content/binding mismatch faults.

After three 300-second epochs and a withdrawal, Lua and Python independently
produce freight-state digest `c102a3fd`. The complete repository gate passes
108 Lua tests, 75 economy parity scenarios, 115 Python tests, game/runtime/GUI/
network integration, the 1,024-event replay, source budgets, launcher smoke,
and release install verification.

## Exact two-process live proof

Strict localhost session
`runtime/localhost-live/freight-bootstrap-live-20260809-1200` required both
industry-content consensus and a freight bootstrap. It bound five actual live
industries:

| Canonical industry | Resource | Capacity/hour | Input | Output |
|---|---|---:|---|---|
| `industry:pre:24d119d0` | `industry/tools_factory.con` | 100 | 1 PLANKS | 1 TOOLS |
| `industry:pre:2f161cfe` | `industry/food_processing_plant.con` | 100 | 2 GRAIN | 1 FOOD |
| `industry:pre:2f992040` | `industry/construction_material.con` | 100 | 1 STONE | 1 CONSTRUCTION_MATERIALS |
| `industry:pre:4815169e` | `industry/farm.con` | 200 | source | 1 GRAIN |
| `industry:pre:556d174a` | `industry/quarry.con` | 400 | source | 1 STONE |

The action used content digest `edc7a517` and bootstrap digest `c5352cf8`.
Both peers checkpointed it at core digest `b34fbdae`. The complete validator
finished with core `2417b3fd`, structure `23c28901`, 14 converged commits, two
successful physical proposals, three successful checkpoint barriers, no
pending ordered lane, and a valid independent audit. The distilled
machine-readable receipt is
[`freight_industry_authority_evidence_2026-08-09.json`](freight_industry_authority_evidence_2026-08-09.json).

An earlier strict run, `freight-bootstrap-live-20260809-1130`, reached the same
game/model result but the PowerShell evidence parser treated records without a
`record_type` property as a strict-mode exception. That was a harness-only
failure. The parser now checks property presence explicitly, and the 1200 run
proves the corrected acceptance path. The negative receipt remains preserved
instead of being relabelled as a pass.

The live session did not order an `economy.settle`, so it proves discovery,
authorization, recipe binding, bootstrap application, checkpoint convergence,
and audit durability—not live production advancement. Production advancement
is currently established by exact Lua/Python replay only.

## Code boundaries

- `freight_industry_model.lua`: portable schema, inventories, arithmetic,
  migration, digests, and public view.
- `freight_industry_runtime.lua`: host submission, local binding verification,
  action application, settlement candidate/commit, and checkpoint trigger.
- `freight_industry_revalidation.lua`: saved-content/live-binding fail-closed
  checks.
- `freight_protocol.py`: independent strict action validator.
- `freight.py`: independent checkpoint/bootstrap/production replay.
- `world_industry_reading.lua`: canonical live-industry enumeration without
  portable local IDs.

## Next freight slice

1. Canonically bind cargo-capable stations and line directions to one source
   output and one destination stock index.
2. Add exact station queues and vehicle loads, using ordered station releases
   rather than native cargo agents as authority.
3. Deposit only completed canonical deliveries into destination inventory and
   pay cargo revenue once through the existing delivery cursor/economy ledger.
4. Project queue/load/output/input values into standard station, line, vehicle,
   and industry UI surfaces.
5. Live-prove a non-zero farm-to-food chain on two processes, including
   save/load with stock in flight, then repeat with a data-only mod resource.

## Subsequent implementation

Prototype 0.32 completes items 1-4 above in state 29/freight schema 2. The
historical 0.31 evidence and digest in this document remain unchanged; the new
transport, presentation, checkpoint, and parity boundary is recorded in
[`FREIGHT_TRANSPORT_AND_PRESENTATION_AUTHORITY_2026-08-09.md`](FREIGHT_TRANSPORT_AND_PRESENTATION_AUTHORITY_2026-08-09.md).
The cargo-positive two-process and save/load gates in item 5 remain open.
