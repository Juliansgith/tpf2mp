# Five-minute delivered economy

Date: 2026-08-07 (Europe/Amsterdam)

Implementation: prototype `0.27.0-alpha`, state schema `25`, economy model `6`,
passenger-presentation schema `2`, checkpoint format `4`.

Status: implemented and offline-verified. A fresh two-process human balance and
UI acceptance run is still required; scripts do not hot-reload into an open
match.

This supersedes the one-hour cadence and 8,760-hour cost conversion documented
in [Authored hourly economy and operating costs](AUTHORED_HOURLY_ECONOMY_AND_OPERATING_COSTS_2026-08-07.md).
That report remains the history of the native-cost and finance-quarantine work.

## Result

Competitive accounting now advances automatically every 300 synchronized
simulation seconds. Demand and service capacity remain hourly rates, but each
tick takes exactly `rate * 300 / 3600`; integer remainders carry forward so 12
ticks reproduce the hourly total without drift.

Passenger cash is no longer created when demand is allocated. A passenger
cohort stores the fare when it boards, and the cumulative completed-leg ledger
advances only when the synchronized native train reaches the next canonical
station. The next five-minute tick pays the difference from the preceding
ledger cursor exactly once. A repeated snapshot pays zero and a backwards
cursor rejects the settlement.

The standard UI projections distinguish:

- passengers and net cash in the last five-minute tick;
- completed-trip revenue waiting for the next tick;
- projected hourly gross, upkeep, and net at the current cadence.

Native agents, native trip-income history, and the floating native arrival
popup remain cosmetic. Continuous wallet reconciliation prevents them changing
competitive cash.

## Passenger calibration

The default fare is distance-sensitive:

```text
fare = $5.00 + $1.50 per kilometre
```

Distance is rounded from metres in integer cents. Each displayed authored
passenger represents a financial cohort of 1,000 travelers, so delivered
revenue is:

```text
completed passengers * boarded fare cents * 1,000
```

The multiplier changes money only. The station and train UI still displays
legible train-sized queues and loads, and capacity remains physical seats times
departures in both directions. A 40-seat train making four departures per hour
per direction therefore supplies 320 passengers/hour, not 160.

Example balance fixture for a monopoly 3 km service:

```text
default fare                         $9.50
completed passengers/hour             320
gross/hour                      $3,040,000
native annual upkeep             $1,200,000
competitive upkeep/hour            $400,000
net/hour                         $2,640,000
```

At the previously observed maximum-speed clock, one synchronized model hour is
roughly 15 minutes of wall time. A healthy `$10m` consist at the fixture's
utilization therefore recovers its purchase price in about 57 minutes. Weak,
slow, empty, overbuilt, or contested services take longer; speed and frequency
still matter through generalized cost, induced demand, capacity, and fare
headroom.

## Cargo calibration

The deterministic cargo evaluator uses this baseline at fare index 1,000:

```text
$1,000 * delivered units * whole route kilometres
```

Thus 400 units delivered over 50 km gross `$20m`. Fare continues to affect
generalized cost and scales the baseline relative to index 1,000. The formula,
integer bounds, Lua/Python parity, and settlement accounting are implemented.
Automatic production-market binding to arbitrary native/mod industry chains is
not yet implemented, so this is not a claim that a newly drawn freight line is
already discovered and registered end to end.

## Costs and capital

Purchase prices remain the exact native consensus debit. Annual maintenance
labels remain the exact resolved native/mod `MAINTENANCE_COST`; the mod does not
rewrite vehicle resources or hardcode vehicle names.

Competitive time compresses one financial year into three authored operating
hours. Every five-minute tick charges:

```text
annual native upkeep * 300 / 10,800
```

with an exact per-vehicle residual. The same period conversion applies to the
ten-percent annual private-infrastructure rule. Parked and unassigned vehicles
continue to cost money. Credit earning power, interest, and bankruptcy grace
are period-scaled so moving from hourly settlement to five-minute accounting
does not make credit twelve times larger or eliminate a company twelve times
faster.

## Demand response

The first service in a market starts at its deterministic equilibrium instead
of spending many ticks gliding up from zero. Later rivals enter from zero and
move toward equilibrium at 350 per thousand upward and 500 per thousand
downward per tick. Fare increases retain the existing immediate downward shock
defense. Generalized cost, pinned logit weights, capacity spillover, lagged
crowding, the outside option, and integer share residuals otherwise retain the
audited model behavior.

## Determinism, migration, and replay

Economy model `6` adds demand-rate residuals, capacity-rate residuals, delivery
cursors, the 300-second scheduler, and the completed-revenue ledger to authored
state. Checkpoint digests include all fields that affect a future result. Lua
and Python independently replay the same integer operations, including safe
quotient/remainder scaling that avoids constructing unsafe IEEE-754 products.

An economy-v5 save migrates its nonzero match limit by a factor of 12, so a
24-hour match remains 24 financial hours (`24 -> 288` five-minute ticks).
Nonzero victory-value targets are multiplied by the 1,000-person cohort factor,
preventing the higher money scale from ending a match on its first tick.
Unlimited/disabled values remain zero. Scheduler and cost/rate residuals begin
at a clean v6 boundary; current v6 saves are not converted again.

Offline evidence after implementation:

- 86/86 core Lua tests;
- 74/74 cross-language economy scenarios spanning model versions 2-6;
- a 104-event post-checkpoint Lua-to-Python replay;
- strict delivery-snapshot protocol and backwards/double-payment rejection;
- game-script, network mapping, hot-seat, GUI, native, launcher, packaging, and
  Python companion suites in the full repository gate.

## Live acceptance still required

Use a fresh two-instance match, not an already-running save. Build and register
a real passenger corridor, complete several synchronized legs, and verify on
both peers that:

1. completed revenue appears as pending before the tick;
2. one automatic tick pays it once and clears pending;
3. line, vehicle, station, toolbar, finance, manager, and statistics panels show
   the same five-minute and projected-hour values;
4. the floating native trip popup does not change the canonical balance;
5. checkpoints retain matching model/core digests over several hours.

That run is the balance/usability proof. The offline suite proves conservation,
replay, and the numerical targets, not that every real corridor will be fun at
the first calibration.
