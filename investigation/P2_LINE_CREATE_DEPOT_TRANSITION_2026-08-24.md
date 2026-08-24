# P2 line-create / depot-transition failure, 2026-08-24

## Live evidence

The physical two-computer session `match-20260824-1350` failed immediately
after player 2 created an empty vanilla line and opened the depot UI.

- Host order 55 carried `line.create`, origin token
  `player2:operation-origin:1`, transaction digest `83402d0d`.
- Player 1 replayed it successfully as
  `line:event:match-20260824-1350:player2:55:1`, core digest `032a81e0`.
- Player 2 returned `native-operation-failed`, no output, core digest
  `c9436ebb`; the companion then ordered `peer-native-operation-failed`.
- Player 2 disconnected about eight seconds later. Player 1 remained alive,
  paused, and fault-fenced. Its later reconnect timeout was a consequence, not
  the initiating failure.

The 0.38.8 completion envelope retained only the generic error code, so the
audit cannot distinguish the final local exception. The unequal origin core
digest and code path constrain the failure to the optimistic output boundary:
the already-created local line was either discovered under `line:pre:*` before
event binding, or the stock manager retired the empty line before ordered
finalisation.

## Correction

The 0.38.9 source handles both admissible races without relaxing consensus.

1. An exact, unreferenced, non-manifest `line:pre:*` binding for the captured
   local output is retired before the event-derived identity is bound.
2. A manifest-bound line, registered service, delivery cursor, vehicle
   reference, departure reservation, or pending operation makes adoption fail
   closed.
3. The GUI proves an optimistic output through its typed LINE component as
   well as generic entity existence. This prevents a one-frame entity-table
   lag from creating a duplicate.
4. If the exact captured empty line is genuinely absent, the origin uses the
   ordinary authorized `CreateLine` replay path exactly once. Its result is
   marked `originReplayed`, so finalisation uses the strict replay
   postcondition instead of optimistic attestation.
5. Failed operation completions now carry a bounded, non-digested
   `errorDetail`. It is preserved in the audit but cannot influence consensus
   result equality.

## Automated regression boundary

- Runtime tests prove provisional adoption converges to the same canonical
  digest as a clean replay peer.
- Manifest-bound and already-authored provisional lines remain protected.
- GUI tests prove a live optimistic line is not duplicated.
- GUI tests prove a vanished optimistic line is recreated once and carries the
  strict-finalisation marker.
- Companion tests prove diagnostic details are bounded, control-character
  free, rejected on successful completions, and excluded from the physical
  result digest.

## Remaining physical acceptance

On the next signed release, create a new empty line from player 2 and
immediately open a depot. Both peers must retain the line, produce identical
successful operation completions/checkpoint cores, and remain connected. Then
repeat from player 1. A failure should now expose the exact local reason in the
host audit rather than only `native-operation-failed`.
