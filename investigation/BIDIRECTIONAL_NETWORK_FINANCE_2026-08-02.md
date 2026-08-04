# Bidirectional network replay and canonical finance

Date: 2026-08-02 (Europe/Amsterdam)  
Prototype: `0.16.0-alpha`  
State/checkpoint/proposal schemas: `13` / `2` / `3`  
Native hook: `0.8.0`  
Pinned game: Transport Fever 2 Build 35924 (Windows x64)

## Result

`runtime/localhost-live/localhost-20260802-175636` passed the first bidirectional two-real-process construction and finance proof. The automated harness started two isolated disposable game worlds, injected the pinned native hook into both exact PIDs, connected `player1` and `player2` through the real file bridges and localhost TCP companion, and completed:

1. ordered match initialization and an all-peer checkpoint;
2. a 25,000 private track originated by the host and reconstructed on both peers;
3. physical consensus and a second all-peer checkpoint;
4. a 25,000 private track originated by the client and reconstructed on both peers;
5. physical consensus and a third all-peer checkpoint;
6. a 600-tick finance and structural drift soak;
7. final mobility sampling, research export, audit replay, cleanup, and exact settings restoration.

The final evidence was:

- status: `PASS` on both games;
- core digest: `fdaceb08` on both;
- structural digest: `33cdc17a` on both;
- model digest: `5b59ecf2` on both;
- Company 1 canonical/native balance: `4,975,000` on both;
- Company 2 canonical/native balance: `4,975,000` on both;
- physical proposals complete/faulted/pending: `2/0/0`;
- checkpoint barriers complete/faulted/pending: `3/0/0`;
- audit: 5 commits, 5 controls, 52 telemetry records, 5 converged comparisons, none awaiting;
- reconciliation failures: zero;
- validator checks: `32` host and `27` client.

## Finance failure found by the longer soak

The earlier bidirectional run proved physical convergence but exposed that a client-origin build could produce a zero native wallet delta on the reporting boundary. Treating the origin machine's observed balance movement as authoritative therefore undercharged a valid replicated build.

The 600-tick soak also exposed recurring peer-local native entries even with calendar speed frozen:

- 100-unit periodic debits on native player wallets;
- 25,000-unit recurring debits on the machine's original native player, consistent with its seeded 30-million loan/maintenance environment.

Those entries are machine-local simulation artifacts: their company association swaps with peer mapping, so accepting them into authoritative finance would diverge the match.

## Implemented correction

Proposal schema 3 includes a required bounded integer `cost`, captured from the native builder's quoted `costs` field before the original proposal is suppressed. The cost participates in the proposal digest and is strictly validated in both Lua and Python. Successful physical consensus applies `-transaction.cost` to the proposal company's canonical account; native balance observations are diagnostic only.

State schema 13 adds canonical network accounts and their ordered ledger. Network checkpoints and independent Python replay use those accounts as the money source of truth. Each machine's native player balances are caches used by Transport Fever's UI and affordability checks. They are reconciled:

- after match initialization and ordered finance changes;
- after physical proposal outcomes;
- after model settlement payouts;
- every 60 safe ticks when no proposal or checkpoint is pending.

The final run proved that both peers retain the same canonical balances while the reconciler removes local interest/maintenance drift. It recorded the corrections, verified the native balances afterward, and produced no settlement failure.

## Construction boundary learned for the next manual test

Linear road/track/node transactions are supported. Station and depot construction proposals are still intentionally rejected because their construction/module payload codec is unfinished. Capture diagnostics now preserve a targeted, bounded projection of construction additions/removals, including filename, station/depot hint, transform presence, parameters, and module counts. An unsupported manual station/depot attempt should therefore fail closed and produce useful research evidence instead of an opaque serialization error.

## What this proves—and what it does not

This proves bidirectional ordering, peer-local company mapping, physical replay, canonical finance, native-wallet cache repair, three checkpoint barriers, and short drift stability through two real engine instances on one PC.

It does not yet prove:

- ordinary human vanilla-tool capture over two computers;
- station/depot/line/vehicle network codecs;
- identical native-save capture and coordinated reload at checkpoint boundaries;
- long-running services, authoritative operating revenue/maintenance, or passenger/cargo presentation;
- public-Internet security or hostile-client resistance.

The next high-value experiment is therefore a human two-instance or two-computer run: one ordinary vanilla private-track build from each peer, followed by a deliberately unsupported station/depot attempt and evidence export.
