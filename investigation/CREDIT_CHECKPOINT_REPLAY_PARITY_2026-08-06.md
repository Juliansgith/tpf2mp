# Credit checkpoint replay parity - 2026-08-06

## Outcome

The configurable credit/insolvency work made `insolventSettlements` and
`creditLimit` authored finance state. Lua correctly projected them into both
`model.networkFinance.accounts` and the checkpoint's independently digested
`financial.companies`, but the Python checkpoint verifier still required the
legacy exact shape `{balance, loan}`. The complete suite therefore stopped with:

```text
checkpoint account company:1 has invalid fields
```

The verifier now accepts exactly one of two versioned account shapes: the
legacy two-field shape or the current four-field shape. When canonical network
finance is initialized, the independently digested financial account must also
equal its authored model account. Re-signing the outer checkpoint after
changing only `creditLimit` is rejected.

## Replay semantics

Portable `economy.settle` replay now mirrors `finance.lua` in the same order:

1. record the deterministic economy settlement;
2. derive each credit limit from settled revenue and settlement count;
3. charge integer permille interest on drawn credit;
4. advance or clear the consecutive insolvency count;
5. select the first bankrupt company only when elimination is enabled;
6. apply settlement revenue to canonical balances;
7. evaluate bankruptcy before valuation and epoch victory conditions.

Only the digest-projected account fields are changed in the Python model. Lua's
native journal entries and bounded finance audit history remain deliberately
outside cross-language authored replay.

## Compatibility and architecture

Older checkpoint versions remain readable because their exact two-field
account shape is still accepted. Mixed, partial, non-integer, negative credit
metadata, or model/financial disagreement fails closed.

The concurrently expanded ranking/end-condition block was extracted unchanged
into `match_runtime.lua`. That restored the enforced entrypoint boundary from
3,435 measured lines to 3,388, with the new module at 76/120 lines. A direct
test preserves ranking order and bankruptcy precedence.

## Verification

The complete local suite passes:

- 65 Lua tests and 73 cross-language economy parity scenarios;
- all engine, hot-seat, network, GUI, native, launcher, and tooling tests;
- 75 Python companion tests, including digest-bound credit tampering;
- 5-event engine checkpoint replay;
- 104-event long deterministic replay.
