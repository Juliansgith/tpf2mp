# Collision-safe topology node identity

Date: 2026-08-08 (Europe/Amsterdam)

Status: implemented, fully offline-tested, and live-proven on two exact Build
35924 processes in prototype `0.29.0-alpha`. Connected-segment removal/rebuild
remains a separate acceptance item.

## Live failure

During the populated localhost lab, drawing track across an existing road was
suppressed before either world changed. The origin logged:

`canonical node fingerprint f9fc0be2 is ambiguous across 2 local objects`

The captured native proposal contained four added edges and two added nodes.
The final lab evidence is
`runtime/manual-network-evidence/topology-depot-live-20260808-111411-20260808-131546/evidence.json`.
Its independent audit remained valid, with seven commits, seven controls,
eight checkpoints, three completed physical proposals, and no pending or
faulted proposal. The lab then expired normally and closed both game processes.

This was not a construction-demolition or road-resource regression. A native
crossing can expose distinct topology nodes at the same quantised position.
The former `node:pre:<position fingerprint>` locator deliberately rejected
that collision because either local node could otherwise be chosen on the
remote peer.

## Canonical identity

An otherwise ambiguous pre-existing node can now use:

`node:pre:<node fingerprint>:anchor:<full canonical incident-edge id>`

The anchor may be a geometrically discoverable `edge:pre:...` identity or an
already-bound `edge:event:...` identity. Candidate incident edges are converted
to canonical IDs and sorted before one is selected, so divergent native entity
numbers or enumeration order cannot affect the result.

On each peer, PREPARE resolves the anchor edge first and accepts the node only
when exactly one of that edge's endpoints has the stated node fingerprint.
Ownership checks then run against the resolved local node exactly as before.
No machine-local ID enters the proposal, registry digest, or companion.

Ordinary unique nodes keep their existing short identity. The proposal schema,
state schema, and Python wire format do not change. If neither position nor an
incident canonical edge uniquely identifies the node, capture still fails
closed.

## Implementation boundary

The identity resolver was extracted from `world.lua` into
`world_identity.lua`. This keeps world adaptation separate from canonical
identity policy and lowers `world.lua` rather than growing it. The source-size
gate now requires and budgets that module.

The anchored identity is valid everywhere an existing node can appear:

- an added edge's canonical endpoint;
- a node removal during a split, replacement, or bulldoze;
- an event-edge endpoint used by a later edit;
- PREPARE inspection, ownership authorization, binding, and native replay.

## Automated evidence

The new adversarial Lua case builds two local topology views with different
native IDs, two co-located nodes, and distinct incident road/rail edges. It
proves that:

- the nodes receive different portable identities;
- lookup does not mutate the origin registry before consensus;
- a compound add/remove proposal contains no local IDs;
- endpoint and removal references map to the correct remote nodes;
- both pre-existing and event-created anchor edges work;
- an anchor whose endpoints do not match the claimed fingerprint is rejected.

Python independently accepts the anchored node in endpoint and removal fields,
recomputes its proposal digest, and still rejects an edge ID substituted for a
node ID.

The complete repository gate passes with 95/95 core Lua tests, 75 economy
parity scenarios, all Lua/game-script/hot-seat/network/GUI integrations, the
1,024-event replay, 108 Python tests, syntax and architecture checks, and the
launcher boundaries.

The `20260809-015718` exact Build 35924 disposable probe also placed one normal
and one catenary track through the supported native API. Both returned one
owned `BASE_EDGE_TRACK` postcondition with the requested catenary state, while
the native hook recorded 4 wrapped calls and 4,581/4,581 queued/applied
commands with no unknown layout or tag. This refreshes the underlying engine
track-build baseline; it does not exercise the two-peer co-located-node
identity path below.

## Exact two-process ordinary-UI proof

Session `crossing-ui-20260809-0330` installed the current source tree before
launch; final evidence reports `sourceInstalledMatch=True`. The validator first
converged its two independent worlds, then left both ordinary game windows
connected with the native authority gate active. UI automation used the stock
rail toolbar, stock standard-track picker, mouse drag, and stock blue confirm
button. No game-script proposal factory was used for the tested crossing.

The drawn 74 m track crossed an existing public town road. Capture produced
proposal `crossing-ui-20260809-0330:player1:20`, including two private track
edges and the three public street edges created by the native road split. Both
peers completed it and filed the same checkpoint:

- core `af4d7487`;
- model `50e8da1d`;
- structure `a0b56ed3`;
- canonical `acc15508`;
- financial `fd683bcb`;
- convergence key `a2fd6a67`.

Only company 1 paid: its balance moved from `4,975,000` to `4,947,384`, while
company 2 remained at `4,975,000`. The origin then extended the event-created
track end through the same ordinary UI. Proposal
`crossing-ui-20260809-0330:player1:24` also converged; both peers ended at core
`ab7c1b0c`, model `7ce9da18`, canonical `fcabfb83`, financial `f66f3bbe`, and
convergence key `a82c6b56`, with company 2 still unchanged.

The independently replayed evidence is
`runtime/manual-network-evidence/crossing-ui-20260809-0330-20260809-033831/evidence.json`.
It contains 17 converged commits, four completed physical proposals, five
completed checkpoint barriers, ten checkpoints, no pending or faulted physical
work, and no session fault. The five-minute lab expired normally and cleaned up
both games and both companions.

The reusable input helper gained DPI-aware drag and wheel actions while running
this proof. Drag receipts preserve both UI-space and actual client/screen-space
endpoints, which makes future ordinary-builder regressions reproducible at a
different window size.

## Remaining acceptance

The collision-safe crossing and subsequent own-track extension are now
live-proven. The next topology lab should still:

1. extend the opposite resulting track end;
2. remove one connected segment and rebuild it;
3. issue an invalid curve and prove the immediately following valid edit still
   synchronizes;
4. cover a more complex multi-road split/join.

Those items broaden destructive/rejection recovery; they no longer block the
claim that an ordinary public-road/rail crossing synchronizes correctly.
