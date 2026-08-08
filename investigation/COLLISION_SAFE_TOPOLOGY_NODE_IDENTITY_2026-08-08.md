# Collision-safe topology node identity

Date: 2026-08-08 (Europe/Amsterdam)

Status: implemented and fully offline-tested in prototype `0.29.0-alpha`;
fresh two-process road/rail crossing proof remains required.

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

The complete repository gate passes with 90/90 core Lua tests, 75 economy
parity scenarios, all Lua/game-script/hot-seat/network/GUI integrations, the
104-event replay, 105 Python tests, syntax and architecture checks, and the
launcher boundaries.

## Live acceptance

In a fresh two-process session:

1. draw ordinary track across an existing public town road;
2. confirm one click appears on both peers and only the issuer pays;
3. extend both resulting track ends;
4. remove one connected segment and rebuild it;
5. perform another unrelated build to prove the proposal lane remains healthy;
6. export research/snapshot evidence.

Until that pass, collision-safe crossing support is implemented and simulated,
not claimed as live-proven.
