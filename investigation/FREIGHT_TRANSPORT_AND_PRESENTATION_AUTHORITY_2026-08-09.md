# Freight transport and presentation authority

Date: 2026-08-09 (Europe/Amsterdam)

Prototype: `0.32.0-alpha`

State/checkpoint schemas: `29` / `5`

Freight-industry/cargo-presentation/delivery schemas: `2` / `1` / `2`

## Outcome

TPF2MP now connects its canonical industry inventories to synchronized cargo
trains. A cargo-only line with canonically bound consists is assigned one
deterministic source-output to destination-stock contract. Ordered station
releases load exact cargo units at the source, preserve them on the train, and
complete them only at the destination. The next five-minute economy boundary
withdraws boarded units from the source, deposits completed units into the
destination, advances production, and pays completed-trip revenue once.

This is an automated authority result, not yet a live cargo-positive claim.
No two-process game was launched for this slice. The first human gate is still
a real farm-to-processor line whose queue, train load, delivery, stocks,
revenue, checkpoints, and save/reload are observed on both processes.

## Contract binding

`freight_service_binding.lua` considers both endpoint orientations. An
industry is in a station endpoint's authored catchment when its canonical live
root is at most 500 metres away. A candidate requires:

- a source recipe that outputs a named cargo type;
- a destination recipe stock with the same cargo type and exact stock index;
- at least one assigned consist with portable capacity for that named type;
- different source and destination industries.

The lowest combined catchment distance wins, with a canonical string key as
the deterministic tie-break. The line metadata carries canonical industry and
station-group IDs, stop indices, cargo type, destination stock index, and a
digest of that identity. Mod-added cargo types work when their repository
entry is a bounded uppercase portable name. Local repository and entity IDs do
not enter the ordered action.

Capacity is not fabricated from a representative wagon. Every assigned
consist contributes an exact per-cargo capacity map. The ordered service keeps
the exact capacity by canonical vehicle ID, fleet total, and conservative
fleet-average rate. A heterogeneous fleet therefore gives each train its own
true authored limit; a consist that cannot carry the selected type has zero
capacity instead of borrowing another train's space.

## Queue, load, delivery, and stock conservation

`cargo_presentation.lua` owns cumulative boarded, delivered, discarded, and
earned-revenue counters plus each active vehicle's exact load and release
round. At a source release it boards the minimum of:

1. the epoch allocation still unboarded;
2. that vehicle's free exact capacity; and
3. source output stock not already reserved by unsettled boardings on any line.

At the destination release, the whole matching onboard load completes at its
boarding-time fare and distance. Duplicate release rounds are idempotent;
backwards, skipped, or same-round/different-stop releases reject. Reassignment,
sale, deletion, disabling, or passenger conversion explicitly discards any
in-flight load, so no hidden reservation survives a retired cargo service.

Stock changes are settlement-coupled. `freight_transport_settlement.lua`
validates every cumulative cursor, exact contract identity, source recipe,
destination stock, and aggregate withdrawal before mutating a candidate. It
then subtracts newly boarded units and deposits newly delivered units. A
failed aggregate withdrawal changes no stock, economy share, money,
presentation epoch, or delivery cursor. Zero-movement snapshots do not pin an
otherwise unused contract.

## Atomic boundary

`economy_settlement_transaction.lua` stages all deterministic state touched by
an accounting boundary:

- economy evaluation and completed-delivery cursors;
- settlement ledger and difficulty residuals;
- freight withdrawal, deposit, and production;
- passenger and cargo presentation epoch transitions.

The live save adopts those candidates only after every stage succeeds.
Line registration uses the same principle in
`economy_line_registration.lua`: economy, canonical bindings, vehicle costs,
and both presentation ledgers are staged together. An attempted active freight
contract change can no longer reject after partially replacing its service.

Native wallet projection and physical town-development commands still occur
after authored adoption because they are engine side effects rather than
copyable Lua state. Their existing fail-closed reconciliation boundary is not
relabelled as rollback.

## Standard UI projection

The stock account, line, vehicle, station, manager, statistics, passenger, and
cargo surfaces now read the authoritative snapshots. Cargo lines show their
source-to-destination contract and cargo type; vehicles show exact load and
capacity; source stations show queues; destination stations show completed
deliveries; and the top cargo counter shows canonical loaded units instead of
`--`. Pending completed units and gross revenue are visible immediately and
settled at the next boundary.

Native cargo agents, native transported history, native floating trip-income
text, and native industry animation remain cosmetic. They are not inputs to
stock, revenue, score, or checkpoints.

## Save, checkpoint, and replay integrity

State 29 persists cargo presentation and freight transport cursors. Freight
schema 2 migration rebuilds every recipe, validates exact cursor identity and
counter sums, accepts schema-1 production saves with an empty transport layer,
and faults malformed current saves closed. Checkpoint format 5 binds canonical
freight inventories, production and transport totals, exact cargo lines and
vehicles, per-line conservation, presentation/economy epoch equality, and the
vehicle synchronization round.

The Python companion independently validates unified delivery schema 2,
replays transport and production, and verifies current checkpoints. A two-step
Lua/Python vector covers one line followed by two lines and finishes at exact
freight digest `3c79af8d`. The pre-existing broader freight arithmetic fixture
remains pinned at `f758bc34`.

The complete repository gate passes 117 core Lua tests, 75 economy parity
scenarios, 119 Python tests, runtime/game/GUI/network tests, two-step freight
transport parity, the 1,024-event replay, source budgets, launcher smoke, and
release-oriented checks. The distilled automated receipt is
[`freight_transport_authority_evidence_2026-08-09.json`](freight_transport_authority_evidence_2026-08-09.json).

## Explicit limits and next live gate

- One cargo contract and cargo type are selected per line; there is no manual
  contract picker or multi-commodity routing yet.
- Contract catchment is TPF2MP's deterministic 500-metre endpoint rule, not a
  claim that every native station-catchment nuance has been reproduced.
- Mixed passenger/cargo stations or consists remain fail-closed.
- Cargo-positive two-process play, non-zero production/delivery, save/load with
  cargo aboard, and mod-cargo presentation remain unproven live.
- Road/tram/ship/air freight inherits the portable consist facts in principle,
  but only railway station releases have human synchronization proof.

The shortest useful human test is a fresh two-process farm-to-food chain:
allow one settlement to produce grain, observe a source queue, run one freight
train to the processor, verify equal exact load/delivery/stock/revenue on both
peers, settle again, checkpoint, save both peers, and reload.
