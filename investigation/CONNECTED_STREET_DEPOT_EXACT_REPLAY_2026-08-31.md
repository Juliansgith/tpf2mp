# Connected street-depot exact replay

Date: 2026-08-31 (Europe/Amsterdam)

Status: superseded for depot roots by
[SELECTABLE_CONNECTED_DEPOT_HELPER_REPAIR_2026-08-31.md](SELECTABLE_CONNECTED_DEPOT_HELPER_REPAIR_2026-08-31.md).
The physical connection and purchase proof below was valid, but automation did
not open the resulting stock depot window. Relay session
`mp-2002d7bf8175d520` later proved that a typed depot root is not selection-safe
and that its native owner can be rewritten to the command issuer on each peer.
The replacement retains exact connection semantics without creating a typed
depot root.

The follow-up universalization, including electrified tram-depot and modular
street-terminal native proof, is documented in
[UNIVERSAL_CONNECTED_STREET_CONSTRUCTION_REPLAY_2026-08-31.md](UNIVERSAL_CONNECTED_STREET_CONSTRUCTION_REPLAY_2026-08-31.md).

## Reported failure chain

Player 2 could build a bus station and create a line. A road depot then appeared
on both worlds but did not connect to the road. Buying a bus did nothing, and
subsequent construction and bulldozing stopped even though the panel still
reported an active match.

These were not independent failures. Commit 44, the line operation, completed.
Commits 45/46 then ordered the road-depot proposal and held the single physical
FIFO while its native postcondition remained unsatisfied. The attempted bus
purchase and later build input could not pass that pending proposal.

The live transaction was schema 7, digest `7d97305e`, and cost `$12,726`. It
contained `depot/road_depot_era_a.con`, one new street node, and one private
entrance edge whose second endpoint was the existing canonical road node
`node:pre:410b0cf7`.

## Cause

All depots were routed through `api.cmd.make.buildConstruction`. That public
helper receives only resource name, parameters, transform, and player. It has no
argument for the transaction's explicit existing-road endpoint. Build 35924
therefore created the visible depot shell but not the captured one-node/one-edge
graph. Construction-step polling could never turn that detached shell into the
canonical result.

The panel remained `active` because the engine was still inside the bounded
physical-consensus wait. It was not evidence that the ordered input lane was
available.

## Replay boundary

Depot handling is now deliberately split:

1. Isolated street depots retain `buildConstruction`. This remains the
   live-proven selectable helper path.
2. A connected street depot is classified as an atomic exact proposal. It may
   never fall back to the detached helper path.
3. A connected rail depot remains rejected before mutation. Its typed output is
   known to crash the stock context helper when selected, so this change does
   not weaken that safety boundary.

The road-depot native factory expands its declared snap into two temporary
nodes and one edge, while the captured connected result contains one new node
and one existing road node. Exact reconciliation now permits only this tightly
bounded shape:

- exactly one surplus generated node;
- no surplus edge or edge object;
- the generated edge count must equal the captured non-zero edge count;
- at least one edge endpoint must be rewritten from that surplus node to a
  resolved canonical local node;
- no edge may still reference the surplus node; and
- removing the tail node must round-trip through the native vector.

Any mismatch rejects before the command is issued. This preserves atomicity and
prevents another detached helper shell from blocking the session.

## Native proof

The first disposable run (`depot-exact-20260831-1`) rejected before mutation
with `generated construction graph exceeds the captured exact graph`. That
localized the native factory's extra snap node and left both worlds healthy.

The final end-to-end run is:

`runtime/localhost-live/depot-bus-20260831-3--mp87164966/run-status.json`

It loaded the exact recovered starting save into two Transport Fever 2 Build
35924 processes with both native hooks active. Results:

- connected road-depot proposal: physical consensus succeeded;
- outputs: one construction, depot, edge, and node on each peer;
- replay path: `gui-build-proposal` (typed exact replay);
- depot finance: exactly `-$12,726` to Player 1 only;
- a stock `landauer_v2` bus was then bought through the new canonical depot;
- vehicle output and postcondition converged on both peers;
- bus finance: exactly `-$29,312` to Player 1 only;
- four checkpoint barriers completed with none faulted or pending;
- final core digest on both peers: `d668d9ad`;
- final structural digest on both peers: `fe731d20`; and
- audit totals: one successful physical proposal, one successful physical
  operation, zero rejections, zero faults, and zero pending physical work.

This also confirms that the reported Buy failure was downstream queue blockage,
not an independent vehicle-purchase defect.

## Regression coverage

The repository now carries the exact live transaction as a native validation
slice and continues through a real canonical bus purchase. Unit coverage proves
the routing policy, surplus-node reconciliation, complete output graph, failure
counter liveness, operation consensus, and post-operation checkpoint.

The complete suite passes: 147 Lua model/codec tests, 7 transport-network
tests, 3 alpha-readiness tests, all cross-language economy and freight parity
vectors, the 256-step freight stress replay, Lua/PowerShell syntax checks, and
225 Python companion/relay/recovery tests.

## Remaining manual acceptance

The native automation proves graph connectivity and that a bus can be created
through the depot. A fresh packaged two-computer test should still click the
connected depot in the stock UI, buy a player-selected bus, and immediately
bulldoze/build afterward. That is a UI acceptance check, not an unresolved
authority or topology dependency.
