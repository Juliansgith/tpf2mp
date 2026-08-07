# Save-owned difficulty and canonical model-town growth

Date: 2026-08-07 (Europe/Amsterdam)

Implementation: prototype `0.28.0-alpha`, state schema `26`, economy model `7`,
checkpoint format `4`.

Status: implemented and offline-verified. No game was launched for this slice;
a fresh two-process balance/presentation run remains required.

## Player-facing contract

Economy difficulty is selected with the other mod settings when the world is
created:

| Mode | Gross revenue |
|---|---:|
| Hard | 60% |
| Normal | 100% |
| Easy | 150% |
| Relaxed | 200% |

The selection becomes an ordered match rule and saved economy parameter at
`match.initialise`. Current actions carry both the canonical key and exact
parts-per-million multiplier. The normal company/economy UI reports that rule;
there is no mid-game mutation action. A peer's later local menu setting cannot
change an initialized match. Saves from before economy v7 explicitly migrate
to Normal, even when loaded on a machine whose new-world menu currently says
something else.

Difficulty scales gross passenger and cargo revenue only. It does not alter:

- native or modded purchase prices;
- resolved native annual maintenance;
- private-infrastructure upkeep;
- demand, allocation, capacity, speed, or generalized cost;
- credit rules, score formulas, or physical train behavior.

Scaling uses quotient/remainder arithmetic instead of forming one unsafe
`rawRevenue * multiplier` Lua-double product. Each service persists its
sub-cent-in-ppm remainder, so many small payments equal one combined payment.
That remainder, the selected key, and the multiplier are all in checkpoint
state and in the independent Python replay.

## Why model-town growth is separate from native growth

The default skeleton crowd policy deliberately makes native people sparse.
Optional physical town development asks the engine to place buildings and is
still an experimental presentation feature. Neither is a safe authority for
competitive demand.

Economy v7 therefore persists its own canonical town rows:

```text
town cid -> size, fractional growth remainder, total earned growth
```

Line registration supplies the initial size from town building count times the
pinned nominal capacity per building. It never reads presentation-scaled native
person capacity. At each five-minute settlement, delivered passenger demand is
split between the two corridor endpoints and aggregated across all markets.
For each town:

```text
numerator = prior remainder + carried passengers * 4
size gain = floor(numerator / 400)
remainder = numerator mod 400
```

Every linked passenger corridor then recomputes gravity demand from the two
canonical sizes and the shortest registered corridor distance. Demand may rise
but a stale observation or line re-registration cannot shrink a market players
already invested against. Cargo markets do not grow towns.

The settlement result discloses the exact town transition. `towns`, market
metadata/demand, and growth residuals are public-snapshot and checkpoint input,
so a missing or divergent update changes the model digest immediately.

## Era behavior

There is intentionally no calendar-year revenue bonus. Era progression comes
from real service and market facts:

- faster stock shortens journey/cycle time and can add departures;
- larger consists add hourly capacity;
- successfully carried passengers grow future endpoint demand;
- purchase price and upkeep remain the resolved values of the chosen vanilla
  or mod vehicle resources.

Old stock is therefore not invalidated merely because the calendar advances.
If its real cost/capacity remains competitive it can still be useful; if a new
train supplies better journey time, frequency, capacity, or upkeep economics,
the demand model rewards the upgrade directly.

`tools/audit_economy_era_balance.py` runs the exact Python v7 evaluator over a
replaceable JSON matrix. The shipped `economy_era_reference.json` contains
synthetic 1850/1900/1950/2000/2030 calibration tiers, clearly labelled as such;
it is not a claim about named vanilla vehicles. The checker requires newer
reference tiers to add actual capacity and net-income incentive and proves all
four difficulties leave allocation, capacity, and upkeep identical. Exact
vanilla and mod-resolved facts should be substituted during the live balance
campaign before adding any age penalty or calendar multiplier.

## Offline evidence

- 88/88 core Lua tests;
- 75/75 Lua-to-Python economy scenarios spanning v2-v7, including a town below
  the missing-observation fallback to catch accidental population inflation;
- exact difficulty residual and all-four-mode invariants;
- old-save-to-Normal and non-default new-save state tests;
- mutation tests proving difficulty, town size/growth, demand remainder, and
  revenue remainder are digest-visible;
- the era calibration checker across all four presets;
- the full game-script, GUI, launcher, replay, companion, and packaging gates.

## Live acceptance

Create a fresh save for each mode, or at minimum Normal plus one non-default
mode. In two connected processes:

1. confirm both UIs report the same locked mode after initialization and load;
2. register the same real passenger corridor and complete at least twelve
   automatic settlements;
3. verify demand/allocation/upkeep match while gross revenue follows the exact
   preset ratio;
4. verify model town sizes and corridor demand rise identically on both peers;
5. save/reload and confirm the selected rule, growth remainder, balances, and
   model/core digests continue unchanged;
6. replace the synthetic era rows with exact facts from representative vanilla
   and modded consists before making further payback or ageing changes.
