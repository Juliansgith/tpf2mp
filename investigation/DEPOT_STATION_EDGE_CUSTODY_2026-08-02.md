# Depot and station edge-custody fix (Build 35924)

Date: 2026-08-02 (Europe/Amsterdam)  
Applies to: prototype `0.14.1-alpha`, state schema `11`, Transport Fever 2 Build 35924

## Result

The Company 2 rail-depot turn lock is fixed, and the same ownership shape has been tested for a real modular passenger station.

A depot or station is a compound native facility. When TPF2MP returns its construction from the shared turn desk to the logical company, Build 35924 may also transfer the facility's attached `BASE_EDGE` entities. The old postcondition accepted only the desk as the native holder of every tracked edge. It therefore rejected a valid engine cascade to Company 2, stopped before financial settlement, and left the turn on Company 1.

The corrected invariant is:

- logical ownership remains authoritative;
- a tracked edge may be held natively by the shared turn desk or by its own logical company's native player;
- a rival company, an unobservable owner, or a record with no permitted owner still fails closed;
- custody is checked before any wallet settlement, as before.

This is deliberately narrower than accepting any company-owned edge. It recognizes only the desk and the exact native player resolved from `logicalOwnerCid`.

## User-observed failure

The reproduced sequence was:

1. Company 2 built a rail depot.
2. The depot added assets and at least one tracked edge.
3. Cycling Company 2 to Company 1 succeeded.
4. Cycling back failed at `pinned-edge-postcondition`.
5. No financial settlement occurred, so the fail-atomic money barrier worked, but the match could not advance.

The important evidence was that the construction transfer also changed its attached edge's native owner to Company 2. That was rightful custody, not ownership theft.

## Code changes

`edge_ownership.validatePinnedCustody` now receives the canonical company table and resolves two allowed native holders per tracked edge:

1. the current turn desk;
2. the native player backing the edge's logical company.

Its result records `logicalNativeOwner`, `allowedNativeOwners`, and `observedNativeOwner` for diagnosis. The world and turn-reconciliation callers now forward the company mapping.

The GUI access policy is unchanged and remains strict. A rival builder proposal touching a tracked construction or edge is vetoed before `builder.apply`; known station, depot, line, vehicle, and construction actions also pass through the generic logical-owner check. This fix permits rightful native custody—it does not grant rival access.

## Automated regression proof

The Lua suite covers all relevant branches:

- desk-owned tracked edge: accepted;
- depot/station edge held by its logical company's native player: accepted;
- the same edge held by a rival company: rejected;
- missing/unobservable/no-permitted owner: rejected;
- simulated Company 2 depot construction plus one attached track edge;
- simulated Company 2 station construction, station, station group, and two attached track edges;
- repeated Company 2 -> Company 1 -> Company 2 cycles in both directions;
- serialized save/load followed by reconcile;
- rival `constructionBuilder` removal and generic entity mutations vetoed.

`tools\run_tests.ps1` passes 16/16 core Lua tests, the edge-ownership integration, game-script/network/hot-seat/GUI suites, all Lua and PowerShell syntax checks, and 22/22 Python tests.

## Live engine proof

Disposable run `runtime/live-validation/20260802-125058` passed on the exact pinned Build 35924 executable with native hook `0.7.0`.

The test-only validator constructed:

- rail depot: construction `9483`, track edge `9486`, depot `9488`;
- modular passenger station: construction `3579`, track edges `9502` through `9513`, station `9515`, station group `9516`.

The numeric IDs are local evidence only and never enter canonical/network state.

All 18 player-owned facility components initially belonged to the desk (`5743`). Four consecutive company cycles then proved two complete custody round trips:

- on each return, every depot/station component and attached track edge belonged to Company 2's native player (`9478`);
- on each lease, every component belonged to the desk again (`5743`);
- the final marker was `facility-custody-complete`, `stage=complete`, `success=true`;
- the normal 39-check live validator also passed at tick 376;
- the independent checkpoint report verified 20 events;
- `settings.lua` was restored byte-for-byte and only the disposable game process was closed.

Evidence:

- `runtime/live-validation/20260802-125058/evidence-20260802-125307.json`
- `runtime/live-validation/20260802-125058/run-status.json`
- `runtime/live-validation/20260802-125058/checkpoint-replay.md`
- `runtime/live-validation/20260802-125058/stdout-20260802-125307.txt`

## Remaining station/depot boundary

This closes local hot-seat custody cycling for the tested rail depot and stock modular passenger-station shape. It does not yet provide network serialization/replay for construction or station proposals, nor does it prove every station/depot type, modular upgrade, deletion, save/reload lifecycle, maintenance path, or vehicle interaction. Those remain separate coverage and codec tasks.

An existing save stopped by the old postcondition should not require a new match: load it with the fixed mod and cycle or reconcile again. Because the failed turn did not settle money, the corrected custody check can complete the original transaction without a compensating balance repair.
