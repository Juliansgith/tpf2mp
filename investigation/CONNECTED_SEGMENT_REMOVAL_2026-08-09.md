# Removal-only connected road and track segments

Date: 2026-08-09 (Europe/Amsterdam)

Prototype: `0.32.0-alpha`

Status: implemented and fully automated; fresh ordinary-UI two-process proof
remains required.

## Finding

The live `station-collateralfix-20260807-111035` run captured two exact
bulldozer attempts at ticks 5527 and 5557 with snapshot digest `d3323fc4`.
Both were rejected as:

`proposal has no supported street/track edges or construction change`

The capture source was the bulldozer, the native BuildProposal was suppressed
before mutation, and the diagnostic showed no edge addition or construction
change. The codec already extracted and materialized `removedSegments` /
`edgesToRemove` and `removedNodes` / `nodesToRemove`, while schema 5 and the
Python validator already admitted a removal as a world change. An earlier Lua
normalization guard nevertheless rejected any transaction with zero added
edges before it reached those removal lists. This was an admission-order bug,
not a missing replay representation.

The historical diagnostic did not count edge/node removals, so the old bundle
cannot by itself prove their exact cardinality. The corrected diagnostic now
reports both counts; the live acceptance step must retain those new facts.

## Implemented boundary

Normalization now reaches the existing canonical removal extraction before
the schema validator decides whether the proposal is empty. A removal-only
schema-5 transaction may contain canonical edge, node, and edge-object
removals, but no additions or retained edge objects. It uses the same strict
all-peer prepare and ownership checks as replacement proposals.

Both language validators require every removal list to be contiguous,
canonically sorted, and unique. Native replay resolves each canonical identity
locally and fills the stock `SimpleProposal` removal vectors. A successful
callback alone is insufficient: before canonical bindings, logical ownership,
or pinned custody are retired, every explicitly removed edge, node, and edge
object must no longer exist with its original component kind. A retained input
fails the physical proposal closed.

This postcondition is intentionally limited to removal-only proposals.
Replacement and upgrade commands can reuse the removed numeric entity ID for a
new output of the same kind, so they remain on geometric output matching and
atomic rebind logic.

## Automated evidence

The codec test reproduces a pointer-free bulldozer proposal with two edges, one
junction node, and one edge object. It proves deterministic canonical sorting,
zero-output materialization, diagnostic counts, exact local replay vectors,
empty output matching, and hostile unsorted-list rejection.

The network company-mapping integration orders removal of an owned connected
edge after an upgrade, resolves its canonical input on the other peer, removes
the physical component, reports no outputs, retires canonical/logical/pinned
custody, completes issuer finance, and closes physical and checkpoint
consensus. A separate runtime test proves a false-success callback cannot
retire an edge that remains in the world.

The complete repository gate passes 118 core Lua tests, 75 economy parity
scenarios, two focused plus 256 stressed freight parity steps, 127 Python
tests, all game/GUI/network/replay integrations, source boundaries, syntax,
release-manifest, fault-watcher, and native-install checks.

## Deliberate remaining limit

A native bulldozer operation that implicitly creates replacement topology not
represented by the capture will be rejected after replay as unexpected output.
That is safer than guessing split/join lineage after mutation. The next human
run should first prove a final connected spur segment and a public road segment,
then preserve evidence for any junction deletion that produces a different
native shape.

## 2026-08-10 collateral extension

The next live run exposed a second removal-only shape: one town-road edge, one
node, and two attached autonomous constructions in schema 7, with no replacement
topology. It was incorrectly sent through the standalone construction helper
and faulted the session after both native calls rejected. Generic construction
collateral accompanying explicit edge/node removal now stays in one atomic
topology proposal, while station/depot graph retirement remains asynchronous.
Verified unchanged rejection also rolls back command-local lazy bindings so a
failed bulldoze cannot block the following station. Full evidence is in
[the follow-up investigation](REMOVAL_ONLY_TOWN_ROAD_COLLATERAL_2026-08-10.md).
