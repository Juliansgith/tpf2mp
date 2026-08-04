# Canonical road/track proposal replay — 2026-08-02

## Result

TPF2MP now has a working canonical transaction for the simple physical street/track slice. The transaction contains no engine-local positive IDs, native player IDs, userdata, pointers, or callback-order assumptions. One disposable Build 35924 run reconstructed an electrified private track in GUI state, discovered its native results, corrected ownership through a supported replacement, bound stable canonical output identities, routed finance, reconciled the company, and retained a continuous checkpoint/event hash chain.

This document records the original one-machine vertical-slice proof. It has since been superseded for the same bounded road/track category by proposal schema 3 and the bidirectional two-live-process run in [BIDIRECTIONAL_NETWORK_FINANCE_2026-08-02.md](BIDIRECTIONAL_NETWORK_FINANCE_2026-08-02.md). Human vanilla-tool use across two computers remains unproven.

## Why this layer is required

Transport Fever 2 assigns local entity IDs as native objects are created. Two machines can produce different numeric IDs even when they perform equivalent work. Commands that later refer to a line, vehicle, station, node, or edge therefore cannot safely transmit those numeric IDs.

The live edge-ownership probe added a second complication: replacing one edge changes its local ID, and BuildProposal callbacks may return no result IDs. Creation order and callback order cannot be treated as identity.

TPF2MP separates:

- canonical identity, derived from the authoritative event and stable output slot;
- local binding, maintained independently on each machine;
- normalized physical postconditions, used to prove the binding is the intended object.

## Schema 2

The current payload supports:

- a canonical company ID;
- sequential node and edge output slots;
- finite node positions and edge tangents;
- street or track carrier;
- local resource index plus optional stable resource name;
- edge type/typeIndex;
- catenary for track;
- explicit private/public flag;
- canonical logical owner;
- node references by new output slot or existing canonical node ID;
- edge/node removals by canonical ID;
- deterministic digest and transaction ID.

It rejects:

- local positive entity IDs in wire references;
- native player IDs;
- duplicate/nonsequential slots;
- missing or nonfinite geometry;
- unknown carriers/resources;
- mismatched logical owner;
- tampered digest/transaction ID;
- constructions, station modules, edge objects/signals, and other unsupported proposal containers;
- oversized payloads.

Lua and Python implement matching strict validation. Network peer `playerN` is authorized only for `company:N`.

## Two-phase application

### Phase 1: authoritative queue

`proposal.build` is applied as an ordered action. It validates the transaction, translates existing canonical inputs to this machine’s local bindings, records the control player and pre-command balance, and stores an asynchronous proposal record.

The record cap is 32 genuinely active transactions. Completed diagnostic records are pruned deterministically to 16 when space is required; queued work is never discarded.

### Phase 2: GUI native issue

The GUI state observes queued records through the game script’s save/load bridge. It materializes a fresh `SimpleProposal`:

- output edge IDs start at `-1`;
- output node IDs follow deterministically;
- canonical existing references are translated locally;
- private edges receive `PlayerOwned` for the local control player;
- the exact-build hook consumes one authorization token in network mode;
- before/after component sets are captured because callbacks may omit IDs.

The GUI returns only a local completion envelope to the engine state. That envelope is never emitted to the network or checkpoint stream.

## Result binding

The engine inspects returned node/edge IDs and matches them to expected slots using:

- finite node position within tolerance;
- edge carrier;
- direct or reversed endpoint geometry;
- exactly one match per output slot;
- no unexpected unmatched output.

It does not use local creation order.

For a private edge, the observed native owner must be the control player or absent/public at the measured fresh-build boundary. If it is absent/public, the engine constructs the live-proven ownership replacement proposal, issues it synchronously, discovers exactly one owner-matching replacement, and replaces the provisional local ID before canonical binding.

Canonical IDs are then derived from the original committed event ID and output ordinal. Removed inputs are unbound only after all outputs bind successfully.

## Finance

The native BuildProposal charges the local control player. Finalisation measures the exact balance delta. When the canonical company’s native player differs from the control player, the engine restores the desk by the opposite journal entry and applies the native delta to the company player. A failed route leaves the proposal failed and reports the error.

The automated app-started validation world may have no-cost rules, so its measured delta can be zero. Manual normal-game road and track tests separately proved real nonzero active-company debits.

## Audit-chain repair

The first live implementation called the finalizer directly on receipt of the GUI result. Canonical bindings changed after the preceding event’s recorded post-digest but before the next event’s pre-digest. The checkpoint analyzer correctly reported:

```text
core digest discontinuity at event 14
```

The repair keeps the local result envelope in module-local memory, then calls `applyCommitted` with only:

```text
type = proposal.finalise
proposalId = <canonical proposal event ID>
localOnly = true
```

The handler consumes the process-local payload inside that audited action. Its persisted action contains no local output IDs. Canonical changes are therefore recorded as canonical/native-only core changes while the authored economic model remains independently replayable.

Automated integration now asserts that the finalization event’s pre-digest equals the queued event’s post-digest and that local result IDs are absent from the persistent action.

## Live evidence

### Supported API ownership

`runtime/supported-api-probe/20260802-024721`:

- normal private track: success;
- electrified private track: success;
- observed owner: player `5743` in both cases.

### Full game-script transaction

`runtime/live-validation/20260802-075533` (prototype 0.14 / state schema 11 / checkpoint format 2 / native hook 0.7.0):

- 39 checks passed at tick 376;
- one electrified private track transaction;
- two node and one edge outputs bound;
- proposal replay count increased;
- control wallet restored;
- company wallet matched expected native delta;
- reconcile succeeded;
- core digest `f859604c`;
- native queue/apply accounting clean.

Checkpoint replay:

- 14 events verified after baseline;
- 3 portable model changes replayed;
- 2 canonical/native-only changes observed;
- 11 model no-op events;
- model replay status `verified`;
- final model digest `95dd1197`;
- final core digest `f859604c`.
- canonical financial digest `fde11e45`.

### Two-live-process transaction

`runtime/localhost-live/localhost-20260802-144832` (prototype 0.15 / state schema 12) passed the same canonical transaction across two exact game processes. Both bound the same canonical edge/two-node outputs and physical/core digest. Build 35924 debited 25,000 only on the proposal-origin process, so completion now samples finance on a later engine tick, excludes local wallet timing from the physical digest, orders the origin delta, and normalizes each canonical wallet before the second all-peer checkpoint. Both checkpoints, the structural soak, and two mobility comparisons converged.

## Remaining gates

1. Capture an actual human vanilla player proposal on one computer while network mode's gate suppresses the original, normalize it, host-commit it, and release the canonical reconstruction on two computers from an identical save.
2. Capture identical native saves at agreed boundaries and exercise the checksummed coordinated-restart plan after a fault.
3. Add construction/station and edge-object codecs.
4. Add complex topology/dependency migration.
5. Add equivalent authority paths for lines and vehicles.

The host-issued linear track slice is now accurately described as two-live-process canonical physical replay with consensus. It is still not general playable network construction until the human capture path and broader proposal categories pass.
