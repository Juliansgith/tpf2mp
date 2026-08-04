# Manual two-road proxy run and fail-atomic settlement finding

Date: 2026-08-01 (Europe/Amsterdam)  
Game: Transport Fever 2 Build 35924, Windows x64  
Prototype loaded during run: mod 0.5 / state schema 4  
Native hook: 0.5.0, exact-build profile active  
Session/peer: `local-dev` / `player1`

## What passed before the failure

The match initialized two added native company players at balance 0 and loan 0. The original turn desk retained balance/loan 30,000,000. The new setup rule issued two verified 5,000,000 grants and then mirrored Company 1 into the desk.

The player built two ordinary roads with the BuildProposal gate disabled:

| Company | Opening balance | Native road cost | Resulting balance |
|---|---:|---:|---:|
| Company 1 | 5,000,000 | 10,671 | 4,989,329 |
| Company 2 | 5,000,000 | 8,307 | 4,991,693 |

The native hook retained two successful tag-15 `BuildProposal` applies, zero suppressed proposals, zero unknown tags, and zero queue/apply tag mismatches. Several Company 1/Company 2 cycles then preserved both balances. Research export `000000000029.json` at tick 1629 reported:

- structural digest `9cb25ad2`;
- Company 1 / Company 2 balances `4,989,329` / `4,991,693`;
- active desk balance `4,989,329`;
- setup target/grants `5,000,000` / `10,000,000`;
- company loans `0` / `0`, desk loan `30,000,000`;
- 16 proposal previews and 2 applies;
- no company-owned assets while the road builder's ownership setting was `Keep`.

That last result is consistent with the base-game rule that streets are usually public even when constructed by a player. Explicit road ownership is a separate tool/state; owned streets resist town upgrades and incur maintenance. See the official [Streets and Tracks manual](https://www.transportfever2.com/wiki/doku.php?id=gamemanual:streetstracks) and [`PlayerOwned` API component](https://transportfever2.com/wiki/api/modules/api.type.html).

## Userdata proposal evidence

The research projection safely traversed the live userdata boundary. It found:

- outer `proposal`, `toAdd`, and `toRemove`;
- nested `addedSegments`, `removedSegments`, `new2oldSegments`;
- nested `addedNodes`, `removedNodes`;
- `edgeObjectsToAdd` and `edgeObjectsToRemove`.

The last retained preview was empty, so sequence containers had no elements and were represented as `<userdata>`. This motivated the 0.6 eight-sample preview/apply ring; it does not yet establish a stable replay schema.

## Failure

The player then explicitly applied player ownership to Company 1's road and pressed **Reconcile Turn**. Two edge entities became associated with Company 1, but the outgoing custody operation reported a postcondition failure. Version 0.5 nevertheless ran financial settlement, restored the desk from the mirrored 4,989,329 to its 30,000,000 baseline, and retained the old active turn with `balanceStart=4,989,329`.

That was a split transaction. Each retry interpreted the 30,000,000 desk as a fresh turn result and credited the difference:

`30,000,000 - 4,989,329 = 25,010,671`

The player clicked cycle/reconcile repeatedly before the failure mechanism was identified. Snapshot `000000000057.json`, exported safely at tick 3486 before closing without saving, records:

- active Company 1 turn still starting at `4,989,329`;
- desk balance/loan `30,000,000` / `30,000,000`;
- Company 1 balance `405,140,220`;
- Company 2 balance `4,991,693`;
- 22 transfer-ledger entries;
- cumulative absolute operational transfer `400,209,559`;
- repeated successful settlement entries of `25,010,671`;
- two Company 1 `edge` assets;
- no native observer unknown tags or tag mismatches.

The match was disposable and was closed without saving. It must not be used as a valid economy result.

## Root cause and 0.6 correction

`finishProxyTurn` previously performed these operations in the wrong commit order:

1. attempt asset return;
2. settle the desk/company balance regardless of asset-return failures;
3. decide overall success;
4. on failure, try to lease assets back but leave the old turn active.

Prototype 0.6 changes the invariant:

1. enumerate the exact source-owned entity IDs;
2. apply and verify every ownership change;
3. if any change fails, roll back every already-changed entity by its recorded ID;
4. persist failed IDs, kinds, observed/expected owners, and rollback postconditions;
5. issue **no journal command** on any custody failure;
6. only after complete custody success, settle money transactionally;
7. if finance fails, roll finance back and re-lease exactly the entities moved by that transfer.

The integration regression forces one edge postcondition to fail after earlier assets moved. It verifies an unchanged 5,000,000 desk and company wallet, no new transfer-ledger entry, exact-ID ownership rollback, a persisted `asset-return` failure record, and successful reconciliation after the obstruction is removed.

## Follow-up: ownership mechanism resolved

The original snapshot alone did not identify the refusing entity because 0.5 did not persist detailed failures. Two later evidence sources resolve it:

1. The PID-specific native status from the manual run records exactly three successful tag-15 `BuildProposal` applies. They correspond to the two road builds and the later player-ownership tool. The native UI therefore changes edge ownership through a proposal, not through the legacy setter used by the proxy.
2. Isolated fresh-world run `runtime/supported-api-probe/20260801-181750` built road edge entity `9480` and tested `game.interface.setPlayer` under protected Lua calls. Same-owner assignment, assignment to the added company, and restore each entered Transport Fever 2's internal assertion at `legacy/interface.cpp:2340`. This is not an ordering or timing failure; the legacy path is invalid for `BASE_EDGE` on Build 35924.

## Prototype 0.7 correction

State schema 6 makes the entity rule explicit:

1. `BASE_EDGE` never enters `game.interface.setPlayer` during claim, lease, return, or rollback.
2. Each edge receives a canonical binding and a persistent logical company owner.
3. Native custody remains pinned to the original turn desk and is reported under `ownership.pinned` by kind/company.
4. Pinned edges count as a successful, deliberately unchanged custody outcome, so the already fail-atomic financial stage can settle exactly once.
5. The UI/research export warns that native edge maintenance and edit custody remain pooled.

This removes the assertion/reconcile failure and closes the repeated-credit path without pretending the edge is natively isolated. The next manual action is to reconcile one owned road under 0.7 and verify no error or balance jump, then click **Export Research**. With native hook 0.6.0, the ownership `BuildProposal` should be retained as `native.sendCommand.buildProposal`. Supported arbitrary-player proposal replacement has since round-tripped independently in `20260801-190732`; the built-in sample is now needed to compare its `new2oldSegments` mapping and improve result binding, not to prove reassignment is possible.

## Follow-up: prototype 0.8 replacement identity

That 0.7 reconcile path subsequently passed for owned roads and tracks with exact wallet preservation. A new failure then appeared when Company 1 electrified Company 2's normal track: the native proposal retired Company 2 IDs `27017/27018` and created `27020/15370`, while 0.7 treated both targets as Company 1 construction. Pinned edge count stayed six, finances remained correct, but logical ownership changed from `1/5` to `3/3`. The full evidence and exact endpoint mapping are in [CROSS_COMPANY_TRACK_REPLACEMENT_2026-08-01.md](CROSS_COMPANY_TRACK_REPLACEMENT_2026-08-01.md).

Prototype 0.8/state schema 7 fixes that distinct failure class by atomically rebinding the complete topology-preserving preview/apply batch before new-asset claiming. An unresolved tracked mapping now blocks financial settlement with no money moved. This complements the 0.6 finance ordering and 0.7 crash-safe pinning; it does not yet prevent a rival from initiating the native edit.

The focused 0.8 retest subsequently proved both topology pairs were correct but exposed a separate script-state timing boundary: committed `builder.apply` already contained the desk owner while the engine component lookup returned `nil`. Version 0.8 failed closed and moved no journal money. Prototype 0.9 permits that exact committed value as provisional evidence and then requires an engine-authoritative pinned-owner postcondition before settlement. See the cross-company investigation for IDs, balances, and artifacts.

Prototype 0.10 closes the competitive-access gap above the custody workaround. Before commit, the builder preview's existing source IDs are checked against logical/pinned ownership. A rival private road/track edit is vetoed with the game's proposal error contract; own infrastructure and public `Keep` roads remain usable. The live follow-up is therefore a rejection test, not another intentional cross-company replacement.
