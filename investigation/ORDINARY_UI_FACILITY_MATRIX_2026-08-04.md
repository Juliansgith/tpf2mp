# Ordinary-UI facility matrix acceptance (2026-08-04)

## Conclusion

The bounded schema-5/schema-7 construction matrix now passes through ordinary
player clicks in two concurrent Transport Fever 2 Build 35924 processes on one
PC. The accepted slice includes named signals and waypoints, a rail depot,
stock modular rail-station placement/edit/removal, and graphless
`ASSET_GROUP` decoration build/removal. Logical ownership rejects a rival's
mutation while allowing the owner to use, edit, or remove the object.

This is not a claim of arbitrary Transport Fever 2 multiplayer. The test used
the same pinned save and mod pack, frozen autonomous development, localhost
transport, and the bounded proposal adapters. Lines, vehicle lifecycle,
complex topology, terrain, scripted construction callbacks, unpaused
simulation drift, and a two-computer session remain separate gates.

## Evidence chain

### Signals, waypoints, and depot

`runtime/manual-network-evidence/facility-vectorfix-manual-20260804-1009-20260804-123116`
preserves the broad UI run. Before its final station-edit fault, both peers
completed and checkpointed the signal/waypoint and depot proposals. The human
check confirmed that Company 2 could open and use its depot and Company 1 could
not interact with it. The independent audit is valid and records 11 completed
physical proposals before one later fault:

```text
physical proposals complete/faulted/pending=11/1/0
checkpoint barriers complete/faulted/pending=12/0/0
```

The fault was isolated to station-edit replay and did not invalidate the prior
agreed boundaries.

### Station placement, edit, ownership, and removal

`runtime/manual-network-evidence/station-editfix-manual-20260804-1122-20260804-120041`
is the clean station rerun. Company 2 placed a stock modular station, changed a
module, and removed the station. Company 1 could not edit or bulldoze Company
2's station. Edit proposal `station-editfix-manual-20260804-1122:player2:18`
completed on both peers at core `bc511a8e`; owner removal proposal
`:player2:22` completed at core `4bdf77bb`. The audit records:

```text
physical proposals complete/faulted/pending=5/0/0
checkpoint barriers complete/faulted/pending=6/0/0
```

### Graphless assets

`runtime/manual-network-evidence/assetfix-manual-20260804-1203-20260804-122837`
is the clean asset rerun. Company 2 placed a bench, lamp, and wooden fence from
the normal asset UI. Each appeared on Company 1's peer. Company 1 could not
bulldoze Company 2's bench; Company 2 could remove it. The named resources on
the wire were:

- `asset/default_multi_bench_new.con`
- `asset/default_multi_lamp.con`
- `asset/default_multi_fence_wood.con`

Bench build commit 14 converged at core `426a5a7b`; bench removal commit 18
returned to `a2c014f8`; lamp commit 22 converged at `7a855a57`; fence commit 26
converged at `7225a041`. Evidence collection reported source/install equality,
both exact native statuses, no relevant game errors, and a valid audit:

```text
audit valid: 15 commits, 13 controls, 1189 telemetry records, 15 converged
physical proposals complete/faulted/pending=6/0/0
checkpoint barriers complete/faulted/pending=7/0/0
14 checkpoints, peers=['player1', 'player2']
```

## Two last-mile defects found by the rerun

### Helper-owned station upgrade fields

The captured station edit correctly retained top-level `seed` and
`upgrade=true` in its canonical transaction, but Build 35924's
`game.interface.upgradeConstruction` inserts those control fields itself.
Passing them back into the helper caused the `lua::Table::Put` duplicate-key
assertion at `Value.cpp:38` before either world mutated.

`proposal_codec.materialiseConstruction` now retains the fields for validation
and digesting but removes them from the local helper parameters. The exact
Build 35924 disposable receipt is
`runtime/supported-api-probe/20260804-111830/run-status.json`: all twelve station
track edges were upgraded, reserved fields were stripped, and cleanup passed.

### Graphless preview rebasing

The construction GUI caches one fully projected preview and cheaply samples
subsequent mouse movement. Its click-time rebase originally required at least
one projected node and edge, a condition appropriate for the stock station but
false for an `ASSET_GROUP` decoration. The failed bench click was captured as:

```text
native.buildProposal.captureError:
construction click could not rebase its cached preview
projected construction graph is unavailable
```

The rebase now accepts the intentional zero-node/zero-edge case and updates the
named construction's 4x4 transform. A half-present graph still fails closed as
incomplete. `tests/run_gui_tests.lua` reproduces the full-preview, lightweight
mouse move, empty suppressed `builder.apply`, native suppression, and final
portable capture without inventing graph entities.

## Verification and release

- Lua canonical/protocol suite: 29/29.
- GUI/native capture regression: pass.
- Network construction/ownership/finance/consensus integration: pass.
- Python companion suite: 37/37.
- Lua, bootstrap, and PowerShell syntax checks: pass.
- Packaged installer/verify/uninstall round trip: pass.
- Installed release: `dist/TPF2MP-0.21.0-alpha.zip`.

## Next boundary

The shortest next playable-network proof is no longer another facility codec
test. It is the ordinary two-process line and railway-vehicle lifecycle:
create/name a line, edit stops, buy a simple train, assign and run it, then sell
the vehicle and delete the line with finance and checkpoint consensus. In
parallel, pause/speed controls and an unpaused populated drift soak still need
their explicit live proofs before a two-computer play session is meaningful.
