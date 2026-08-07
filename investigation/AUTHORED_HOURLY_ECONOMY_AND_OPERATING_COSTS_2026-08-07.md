# Authored hourly economy and operating costs

Date: 2026-08-07 (Europe/Amsterdam)

Status: implemented and offline-verified; fresh two-process live acceptance is
still required. These scripts do not hot-reload into an already running match.

Superseded for current cadence and balance by
[Five-minute delivered economy](FIVE_MINUTE_DELIVERED_ECONOMY_2026-08-07.md).
This file remains the historical record of the native-cost capture and finance
quarantine slice.

## Outcome

The competitive economy no longer needs a player to press **Settle Epoch** and
no longer treats gross fare revenue as profit. Player 1 submits one ordered
settlement at each exact 3,600-second boundary of the synchronized simulation
clock. The action waits behind physical/checkpoint work, contains the host's
deterministically computed result, and is independently re-evaluated by the
other peer and the Python checkpoint replayer.

The authoritative result is now:

```text
gross fare revenue
- complete-consist vehicle upkeep
- active private-infrastructure upkeep
= signed net revenue
```

Net revenue drives the canonical wallet, score, credit limit, interest and
bankruptcy. The panel exposes gross, both cost classes, and net at company and
line level. Demo seeding and manual settlement are hidden unless
`TPF2MP_DEVELOPER_ECONOMY=1` (validators enable it automatically).

## Time and units

- One authored economy epoch is one model hour: 3,600 synchronized simulation
  seconds.
- All model arithmetic is integer cents and saturates below Lua 5.1's exact
  integer ceiling.
- Native player balances are integer dollars. A signed `[-99, 99]` cent
  residual is carried per company, using truncation toward zero, so cumulative
  native-wallet movement exactly equals cumulative model net revenue. A
  one-cent loss therefore remains `-1` carried cent instead of becoming an
  immediate one-dollar debit.
- If game time advances across several boundaries while authority is busy, the
  host catches up one ordered boundary at a time. It never coalesces or skips
  an hour.
- A wrong/repeated boundary is validated before any share, upkeep, scheduler,
  ledger, or payout-residual mutation. This transactional ordering was added
  after the focused adversarial test exposed the earlier half-apply risk.

The number shown by the model is per authored hour, not per native trip and not
per calendar month. For example, a consist with $1,200,000 annual upkeep costs
about $136.99 per authored hour (`1,200,000 / 8,760`). A model gross of $500 in
that hour is therefore about $363 net before infrastructure, not $2,000 monthly
revenue versus $100,000 monthly upkeep.

## Vehicle cost basis

The successful all-peer `vehicle.buy` outcome contains both the exact signed
native finance delta and a physical postcondition read from the resulting
vehicle's resolved `MAINTENANCE_COST` component. The cost runtime therefore
records exact capital and exact post-modifier annual upkeep without reproducing
the engine's automatic-price formula:

```text
purchase price dollars = -native purchase finance delta
annual vehicle upkeep cents = resolved native maintenance dollars * 100
```

The postcondition is part of all-peer operation consensus, so mismatched mod
resources/cost modifiers cannot silently produce different competitive costs.
Replacement refreshes the resolved cost, sale removes its cost stock, and a
unique manifest-bound pre-existing vehicle is backfilled from the same native
component. One sixth of purchase price remains only the fail-soft fallback for
a legacy record whose component cannot be read.

Each canonical vehicle owns an independent 8,760-hour residual. Every purchased
consist is charged once per authored hour whether assigned, running, stopped,
or parked in a depot. A registered line's canonical `vehicleCids` determine
which portion is displayed as that line's train cost; unassigned costs remain
in the company total. Moving a vehicle between lines changes presentation, not
whether it is charged.

The lifecycle handlers are cost-complete once an ordered replacement/sale
reaches them. Transparent stock-widget capture for those commands is still not
live-proven, so their broader product status remains gated rather than claimed.

## Infrastructure cost basis

Every successful canonical proposal has an authoritative finance delta and
canonical outputs. Cost attribution is deliberately generic rather than a list
of vanilla resource names:

1. compound construction/asset roots carry the proposal cost when present;
2. otherwise private canonical edges and edge objects carry it;
3. station/depot roots are the fallback;
4. public town roads carry no company upkeep.

Capital is allocated in sorted canonical-ID order, including exact remainder
cents. An upgrade/replacement retires the input's recorded capital and assigns
`old capital + new spend` to the outputs. Deletion retires capital. Bulldozing
expense is a current transaction, not new durable capital.

Company infrastructure upkeep is:

```text
annual infrastructure upkeep cents = floor(active capital cents / 10)
```

The annual amount also uses exact 8,760-hour residual carry. This ten-percent
rule matches the prototype's intended broad maintenance policy and works for
data-only mod resources because it depends on consensus outputs and spend, not
hardcoded road, track, station, or asset names. It does not attempt to reproduce
every resource author's custom native maintenance formula.

## Native-finance quarantine

Canonical accounts are authoritative. Build 35924 can still generate native
trip income, maintenance, interest, and the large floating arrival popup. Those
entries are local presentation/execution artifacts:

- account reconciliation now checks every update, while avoiding duplicate
  journal commands during an asynchronous adjustment;
- any native-only balance drift is returned to the canonical balance;
- only the ordered model net payout survives;
- the TPF2MP panel explicitly labels native trip income as quarantined.

The floating stock popup itself has no supported Lua suppression path in this
slice. It may visually say, for example, `$300,000`; that is not competitive
income and the canonical wallet is corrected. Replacing or relabelling that
popup is a later native-UI polish item.

## Convergence and verification

The canonical economy projection now includes:

- per-service cost fields and residuals;
- per-vehicle owner, annual upkeep, and residual;
- per-company infrastructure capital, annual upkeep, and residual;
- signed per-company wallet-cent residuals;
- scheduler start, last boundary, next boundary, and period;
- gross/cost/net results and ledgers.

Lua and Python implement the same ordering and arithmetic. The final offline
gate passes:

- 83/83 core Lua tests;
- 74 cross-language v2-v5 economy trajectories, including an assigned consist,
  a parked consist, infrastructure, losses, nonzero residuals, and scheduled
  boundaries;
- host-only/due/busy automatic-clock runtime tests;
- build/replacement/deletion and purchase cost-basis tests;
- invalid-boundary no-mutation tests in both languages;
- game-script, protocol, native, companion, and 104-event replay suites.

## Honest limitations and next live test

- A migrated old save has no trustworthy historical purchase/build deltas.
  Unique vehicles can import current annual maintenance safely, but their past
  purchase capital remains unknown; indistinguishable duplicate pre-existing
  vehicles remain deliberately unbound/unpriced.
- The portable codec and costing accept every safe `vehicle/*.mdl` resource,
  including mod vehicles. Railway remains the only carrier with human
  two-process purchase/movement proof; road/tram/ship/air need live acceptance.
- Native floating income text is cosmetic but potentially confusing.
- Native vehicle maintenance is now resource/mod-authored. The ten-percent
  infrastructure ratio and overall revenue calibration still need human balance
  tuning; arithmetic correctness is not balance proof.

The next acceptance should use a fresh two-instance network match: build new
private infrastructure, buy a multi-part train, leave it parked through one
automatic hour, assign/register it, run through several more hours, and compare
both panels, canonical balances, checkpoint/model/core digests, and the native
wallet after a visible stock trip-income popup. No manual settle button should
be used.
