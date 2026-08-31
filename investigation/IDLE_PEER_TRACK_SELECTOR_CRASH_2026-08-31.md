# Idle-peer track selector crash - 2026-08-31

## Outcome

Relay session `mp-00776ff0f75951f1` failed while Player 1 extended a newly
built electrified track and Player 2 was idle. The relay and both companions
remained paired. Player 2's game process, rather than the transport, stopped
inside the stock native `UI::CSelector`.

The failed transaction was ordered proposal
`mp-00776ff0f75951f1:player1:178`, digest `42e3d5e4`: three standard catenary
track edges, three new nodes, no removals and no edge objects. Its first edge
attached to `node:event:mp-00776ff0f75951f1:player1:174:3`. Proposal 174 had
already completed on both peers and crossed checkpoint sequence 176.

Player 1 applied proposal 178, verified its six outputs, booked `-25817`, and
published core digest `93991aa5`. Player 2 accepted commit 178 at tick 6061 but
never published a native completion. The host later raised
`proposal-completion-timeout:player2`.

## Native evidence

Player 2 reported:

```text
Assertion `it != components.end()` failed
Entity: -1
Notified Entity: -1
Component Type Index: 21
Uncaught exception while in class UI::CSelector
Minidump: c036e5ba-7a6e-4ab8-be98-ea2a8a09e554
```

The canonical materializer follows Urban Games' documented SimpleProposal
numbering: new edges are `-1`, `-2`, ... and new nodes follow them. Therefore
the asserted entity is exactly proposal 178's first temporary track edge, not
the already committed attachment node. The stock API documentation also notes
that negative IDs remain temporary until insertion into the engine.

Several earlier build clicks were rejected before mutation because their
suppressed native call had no generation-bound preview. They did not cause this
failure. Proposals 166, 170 and 174 subsequently completed on both peers.

## Failure mechanism

The existing replay quarantine protected Lua from stale builder proposal
userdata, but it began and issued `BuildProposal` in the same GUI update. It did
not suspend the stock main-view selector. An idle receiving peer could therefore
hit-test the new edge while it still had temporary ID `-1` and before its full
component set was installed. `CSelector` then used a checked component lookup
and terminated the game.

The exact cursor-dependent trigger cannot be reproduced by the Lua-only test
harness, but the entity identity, handler class, command timing and successful
origin replay all converge on this native boundary. The correction treats it
as unsafe regardless of cursor position.

## Correction

Every GUI-owned canonical proposal now crosses a selector fence:

1. disable `mainView` interaction and clear build correlation;
2. wait one complete GUI update before materializing or issuing the proposal;
3. keep selection disabled through the native callback and three further GUI
   updates, by which time temporary entities have their final positive IDs;
4. restore the view independently of the longer finance/result quarantine, and
   also restore it on rejection, reset or result completion.

Immediately before materialization, every canonical endpoint used by a new
edge is also revalidated as an existing peer-local entity with `BASE_NODE`.
A stale binding is now rejected before native mutation rather than passed to
Build 35924.

## Automated boundary

The GUI integration test now proves that:

- the native command is not created in the selector-suspension frame;
- `mainView` remains disabled through the three-frame native settle window;
- normal interaction resumes while the finance quarantine can continue;
- a live canonical `BASE_NODE` passes last-moment preflight;
- a disappeared attachment node fails before materialization;
- result completion and explicit reset always restore interaction.

This session cannot be requalified in place: Player 1 contains proposal 178
and Player 2 crashed before applying it. Resume from the last common recovery
boundary or start a fresh session for live acceptance.
