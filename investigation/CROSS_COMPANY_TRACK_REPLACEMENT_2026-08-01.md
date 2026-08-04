# Cross-company track replacement — Build 35924 — 2026-08-01

## Outcome

A disposable prototype-0.7 hot-seat run proved that desk-pinned track editing was financially safe but did not preserve logical ownership across native edge replacement. Company 1 electrified Company 2's normal track. The game accepted the edit, Company 1 paid the exact native cost, but the two replacement edge IDs were treated as new Company 1 assets.

The trace also supplied the missing live binding needed to fix that class: the final `builder.proposalCreate` identifies the committed source edges, `builder.apply` identifies the replacement edges, and their unchanged node topology pairs them deterministically. Prototype 0.8/state schema 7 now migrates canonical, logical-owner, and pinned-custody records as one atomic batch. Ambiguous tracked replacements fail closed before proxy finance settlement.

Native custody is still pooled. Prototype 0.9 made allowed replacement rebinding safe; prototype 0.10 now adds the payload-aware pre-commit access policy that this trace required. Rival tracked sources are rejected before apply, while own and public/untracked construction remains allowed. The new policy is automated-test complete and awaits the short live confirmation described below.

## Exact environment

- Game: Transport Fever 2 Build 35924, Windows x64
- Executable SHA-256: `782b904a8f7bbdac1f7a18528f1a5c778691e5aa3087c37c351bf6912585175c`
- Native hook: 0.6.0, all 17 pinned signatures valid
- Test mod: prototype 0.7/state schema 6
- Session/peer: `local-dev` / `player1`
- Final raw research/snapshot envelopes: bridge sequences `88` / `90`
- Rendered report: `runtime/research-local-dev-player1.md`
- Closed-game evidence: `runtime/live-evidence/evidence-20260801-204211.json`

## Controlled chronology

1. Company 1 built two roads, one explicitly player-owned, and reconciled once.
   - Balance: `5,000,000 -> 4,991,217` (`-8,783`)
   - Logical/pinned edges: Company 1 = 1
2. Company 2 extended Company 1's road and reconciled once.
   - Balance: `5,000,000 -> 4,995,534` (`-4,466`)
   - Logical/pinned edges: Company 1 = 1, Company 2 = 1
3. Company 2 built one normal and one electrified track. Each build produced two edges.
   - Balance: `4,995,534 -> 4,970,979` (`-24,555`)
   - New Company 2 edge IDs: `27011`, `27012`, `27017`, `27018`
   - Logical/pinned totals: Company 1 = 1, Company 2 = 5
4. Company 1 used the native track modifier to electrify Company 2's normal track.
   - Game accepted the cross-company edit.
   - Balance: `4,991,217 -> 4,988,997` (`-2,220`)
   - Company 2 stayed at `4,970,979`.
   - Reconciliation succeeded with zero finance failures.
   - Logical ownership changed incorrectly from `1 / 5` to `3 / 3`.

All six BuildProposal commands applied successfully. The hook recorded zero invalid layouts, unknown tags, pending overwrites, apply failures, tag mismatches, or hook errors.

## Exact replacement evidence

The final pre-apply track-modifier preview at tick 5203 contained the two original positive IDs:

- `27018`, nodes `27015 <-> 27016`, carrier type 1
- `27017`, nodes `27014 <-> 27015`, carrier type 1

The `builder.apply` observation at tick 5207 contained the committed replacements:

- `15370`, nodes `27015 <-> 27016`, carrier type 1
- `27020`, nodes `27014 <-> 27015`, carrier type 1

Both old and new segments carried native `playerOwned.player = 19786`, the shared turn desk. Native ownership therefore could not identify the competitive company. Reconciliation retained `27011/27012` for Company 2 but created new Company 1 bindings for `15370/27020` because the old `27017/27018` local-ID records had not migrated.

The unambiguous mapping is:

| Canonical source | Replacement | Stable match |
|---:|---:|---|
| `27017` | `27020` | carrier + unordered nodes `27014/27015` |
| `27018` | `15370` | carrier + unordered nodes `27015/27016` |

The applied proposal's `new2oldSegments` remains opaque userdata in this Lua state, so the topology match is the strongest exposed binding in this run.

## Prototype 0.8 correction

`edge_ownership.lua` now provides two additional operations:

1. `matchBuilderReplacements(before, applied)` extracts positive source and target IDs and pairs unique, topology-preserving segments independently of container order.
2. `rebindObserved(world, canonical, observation, deskPlayer)` validates the complete tracked batch, verifies replacement native ownership, snapshots the affected registries, and atomically migrates every canonical/local, logical-owner, and pinned-custody record.

The GUI always retains the most recent proposal preview in its builder transaction context and attaches the compact match to the subsequent `builder.apply` observation. The engine applies migration before ordinary ownership reconciliation. It exports observed/rebound/failure counters and an eight-entry bounded migration history.

If any tracked source is unmatched, ambiguous, duplicated, already occupied, or owned by the wrong native player:

- no partial canonical migration is committed;
- an `edgeReplacementFailure` is persisted on the turn;
- `Reconcile Turn`/`Cycle Company` stops before returning assets or settling money;
- the live desk balance is not repeatedly converted into company credit.

Regression coverage reproduces the exact reversed two-edge live trace and a partial two-edge observation. The former preserves both Company 2 canonical identities; the latter mutates nothing and fails closed. The full repository suite passes, including hot-seat integration, GUI lifecycle pairing, 104-event replay, and 14 Python/companion tests.

## Prototype 0.8 live retest and timing failure

The focused two-edge regression was then run under prototype 0.8/state schema 7. Company 2 built one player-owned two-edge track and reconciled to `4,982,749`. Company 1 electrified it for `3,326`, leaving the live desk/effective Company 1 balance at `4,996,674`. The topology matcher itself succeeded completely:

| Source | Replacement | Stable endpoints |
|---:|---:|---|
| `25863` | `25866` | `25860/25861` |
| `25864` | `9803` | `25861/25862` |

Both committed `builder.apply` targets explicitly contained `playerOwned.player = 20521`, the turn desk. However, when the GUI forwarded that committed observation, the engine-state `PLAYER_OWNED` lookup had not exposed either new entity yet and returned `nil`. Prototype 0.8 treated this transient absence as a wrong-owner postcondition. It therefore reported replacement counters `1/0/1`, persisted both failed IDs, and stopped reconciliation before any journal settlement. The permanent Company 1 wallet remained `5,000,000`, Company 2 remained `4,982,749`, and the spent `3,326` remained only on the active desk. This proves the financial fail-closed barrier worked; it also proves native component visibility can lag the committed GUI result by at least one script-event boundary.

Final artifacts:

- final research envelope: bridge sequence `30`, tick `799`;
- failure snapshot: bridge sequence `26`, core digest `477903b6`;
- manual checkpoint: bridge sequence `28`, independently replayed with four subsequent events to model digest `93a3c3a1`;
- rendered research: `runtime/research-local-dev-player1.md`, structural digest `b7d3c210`;
- closed-game evidence: `runtime/live-evidence/evidence-20260801-231041.json`;
- native hook PID status: `status-31500.json`, all 17 signatures valid, all observed proposals applied successfully, and zero native apply failures, invalid layouts, unknown tags, pending commands, or tag mismatches.

## Prototype 0.9 correction

Prototype 0.9 keeps the topology match and fail-atomic state migration, but distinguishes an unavailable engine component from an observed mismatch:

1. The matcher retains `playerOwned.player` from each committed `builder.apply` target.
2. If the engine component is already readable, that engine owner remains authoritative and any mismatch fails closed.
3. If—and only if—the engine owner is temporarily unavailable, the committed apply owner may bridge the gap when it exactly equals the expected turn desk.
4. Before reconciliation can move any finance, every pinned edge is checked again through the engine component. An absent or non-desk owner then fails the turn with no journal settlement.

This gives the early builder lifecycle enough evidence to preserve Company 2's IDs while retaining a later engine-authoritative postcondition. Automated coverage now includes the exact missing-component timing case, a wrong apply owner, an actual engine mismatch, partial batches, and the final pinned-custody check.

Prototype 0.9 is installed. Closed-game evidence `runtime/live-evidence/evidence-20260801-234038.json` proves all 12 installed/source files match fingerprint `d9b20090c06905f9bcf26b6136f786c4963f8926d74b25007a784affeba10110`; match-manifest fingerprint `858da334279f5666eeacc60d986671abb9bff613124a0c5ec101f98637aeb2b3` covers the game executable, mod, companion, and hook DLL. This is installation evidence, not the still-pending 0.9 gameplay retest.

The same run also exposed bridge-generation tooling issues: a fresh world reset its script sequence and overwrote low-numbered files while stale high-numbered files remained. Prototype 0.9 never overwrites an existing numbered outbox file; it advances to the first unused sequence. Research selection now uses write time before sequence, and checkpoint analysis ignores stale older-generation files after its selected anchor. The final 0.8 export and its four-event checkpoint stream now render and replay successfully.

## Prototype 0.10 pre-commit isolation

The replacement machinery remains necessary for legitimate same-company upgrades, but a rival should not reach it. Prototype 0.10 adds a policy at the game's documented `builder.proposalCreate` decision point:

1. The bounded proposal projection collects non-negative existing entity IDs from removed segment, edge, node, edge-object, and construction containers. Negative temporary preview IDs are ignored.
2. Each source ID is resolved through `world.logicalOwners`, with pinned custody as a fallback.
3. An own-company source is allowed. An untracked/public source is allowed, preserving ordinary roads built with ownership `Keep`.
4. Any rival-owned source returns `{ errorMessages = { ... }, warnings = {} }`, the same veto contract used by the shipped mission helpers. No builder context is retained and no `builder.apply` should follow.
5. Denials are counted and retained as bounded local research evidence; their machine-local IDs are stripped from the persistent portable event tail.

Automated coverage exercises the exact nested `removedSegments` shape, raw `edgesToRemove`, edge objects, constructions, negative preview IDs, public IDs, own IDs, and pinned-custody fallback. GUI integration verifies the actual error contract and Company 2 message. The complete Lua, hot-seat, GUI, 104-event replay, syntax, and 14-test Python companion suite passes.

Prototype 0.10 is installed. Closed-game evidence `runtime/live-evidence/evidence-20260802-004556.json` records matching 12-file source/installed tree fingerprint `92b491bd41471513f7936f985d324fe8d3f01d26f7f47114ce977066eac6b461`; match-manifest fingerprint `4bcc9fcecf65e9d7e16501f0aaa536ba931fec03c4f0a8f780c1c4ceae3c1c50` covers the game executable, mod, companion, and hook DLL. This is installation evidence, not the pending gameplay veto test.

The live proof is intentionally stronger than the old 0.9 retest: Company 1's electrification attempt against Company 2 must now produce no native apply, no debit, no ID replacement, and no ownership migration. Company 2 must then be able to electrify its own track, proving this is company isolation rather than a blanket build gate.

## Companion checksum correction

This research export also exposed a protocol-tooling mismatch. Lua on this Windows build formats numbers with `%.17g` and rounds exact halfway cases away from zero; Python's stock JSON encoder uses shortest/ties-to-even formatting. The report helper therefore rejected valid coordinate-bearing Lua envelopes even though integer-only test vectors passed.

`companion/tpf2mp/protocol.py` now reproduces the Windows Lua number format explicitly. It verifies both the early road export and the final track-theft export, and checkpoint replay verifies 80 event records from the first anchor.

## Remaining gates

1. Live-retest the same cross-company electrification under prototype 0.10. Expected: the Company 2 ownership error appears, the blocked counter rises, no `builder.apply`/debit/ID change occurs, and logical assets remain Company 1 = 0 and Company 2 = 2.
2. In the same world, prove Company 2 can electrify its own track and a public `Keep` road remains connectable.
3. Define guarded matching for topology-changing split/join proposals that are allowed because every tracked source belongs to the active company. Rival split/join proposals are already rejected when their positive source IDs are exposed.
4. Integrate explicit physical proposal ownership transfer/lease batches only if native management visibility needs isolation beyond the logical veto.
5. Use the proposal policy and replacement mapping as local validation layers inside future host-authoritative two-machine command replication.
