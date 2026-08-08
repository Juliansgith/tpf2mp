# Freight classification and the remaining industry-authority schema

Date: 2026-08-09 (Europe/Amsterdam)

Prototype: `0.29.0-alpha`

State schema: `26`

## Result

A real freight consist can no longer enter the passenger economy merely
because its station groups happen to resolve near two towns. The correction is
resource-driven and therefore applies to data-only mod vehicles as well as
vanilla vehicles:

- each exact line stop resolves its zero-based `Line.Stop.station` through the
  corresponding `STATION_GROUP.stations` entry and reads `STATION.cargo`;
- a group-level fallback is admitted only when every readable station in that
  group has the same cargo flag; an unreadable mixed group fails closed;
- every assigned consist and every compartment/load configuration is inspected through
  `modelRep` metadata, and only cargo entries explicitly typed `PASSENGERS`
  count as seats; heterogeneous passenger fleets use average consist capacity
  and their slowest top speed; and
- pure freight and mixed passenger/freight consists are rejected before a
  passenger market or service can be created.

This also repairs old state rather than merely preventing new mistakes. After
the initial all-peer checkpoint, every runnable owned line is revalidated,
including already registered lines. If an existing service is no longer
authoritative, its owner emits an ordinary ordered `line.register` containing
a disabled copy of the prior service and a portable reason code. Every peer
therefore removes it from allocation and the passenger queue/load ledger at the
same committed boundary. Native IDs and local read diagnostics never enter
that action. A later supported line edit emits fresh facts and re-enables the
service normally.

No state, checkpoint, proposal, operation, or network schema changed. This is
a correctness fence, not freight gameplay.

## Shipped vanilla industry data

The pinned Build 35924 construction archive contains sixteen ordinary industry
resources. Their `stockListConfig` is passed to `industryutil.addIndustryData`;
the helper exposes `rule.input`, named outputs, and base capacity, then
multiplies capacity by the selected production level.

| Industry | Inputs per cycle | Output | Base capacity |
|---|---:|---:|---:|
| Coal mine | none | 1 coal | 400 |
| Farm | none | 1 grain | 200 |
| Forest | none | 1 logs | 400 |
| Iron ore mine | none | 1 iron ore | 400 |
| Oil well | none | 1 crude | 400 |
| Quarry | none | 1 stone | 400 |
| Chemical plant | 1 oil | 1 plastic | 100 |
| Construction material plant | 1 stone | 1 construction materials | 100 |
| Food processing plant | 2 grain | 1 food | 100 |
| Fuel refinery | 1 oil | 1 fuel | 100 |
| Goods factory | 1 plastic + 1 steel | 1 goods | 100 |
| Machines factory | 1 planks + 1 steel | 1 machines | 100 |
| Oil refinery | 2 crude | 1 oil | 200 |
| Sawmill | 2 logs | 1 planks | 200 |
| Steel mill | 2 iron ore + 2 coal | 1 steel | 200 |
| Tools factory | 1 planks | 1 tools | 100 |

These values are useful fixtures, not a portable authority format. A mod can
replace the construction resource, parameters, levels, stocks, recipes, or
update function. Static regular-expression parsing of `.con` source would
silently disagree with what each game actually loaded, so it is deliberately
not used for gameplay.

## Exact remaining freight slice

The existing economy already evaluates a canonical `cargo` market kind and
exact unit-kilometre revenue; direct ECS telemetry can count native cargo. A
real industry-backed service still needs all of the following before it may be
enabled:

1. Resolve each live `SIM_BUILDING` to its named construction resource and
   evaluated recipe/level on every peer, with a digest-bound match-content
   preflight. Dynamic or opaque update callbacks must fail closed.
2. Give source, processor, destination, station, line, and vehicle stable
   canonical identities without treating independently generated native cargo
   entities as authoritative.
3. Add ordered supply, input-stock, output-stock, demand, transfer, queue, load,
   and completed-delivery state with Lua/Python parity and checkpoint replay.
4. Couple native cargo presentation to that ledger where a supported mutation
   path exists; otherwise label native piles/loads as cosmetic as is already
   done for unsupported totals.
5. Prove a non-zero vanilla chain through two exact processes, then repeat with
   a data-only modded industry and vehicle pack.

Until those gates pass, freight infrastructure and native trains may be
replicated physically, but they are visibly quarantined from competitive
passenger revenue.

## Automated evidence

The repository tests now cover passenger, pure-cargo, passenger-first mixed-fleet,
unknown cargo-type, heterogeneous passenger-fleet, indexed mixed-station,
and unreadable mixed-group classification; passenger-versus-freight capacity
from repository metadata; rejection before market creation; portable disabling
of a previously registered service without local-ID leakage; initial saved-line
revalidation; removal from the passenger ledger; diagnostic persistence; and
recovery after a later supported edit. The complete gate passes with 94/94 core
Lua tests, 75 cross-language economy scenarios, runtime/game/network/GUI
integrations, 108 Python tests, and the 1,024-event independent replay.

Fresh exact-build passenger and cargo-line UI acceptance remains a human/live
gate because the game is not being left running unattended.
