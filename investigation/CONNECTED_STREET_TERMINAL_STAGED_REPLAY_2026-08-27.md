# Connected street-terminal staged replay - 2026-08-27

> The staged state machine remains in use, but this document's original
> correction was incomplete: construction topology is expanded only inside
> the native command factory. The final post-expansion fix and exact live proof
> are recorded in
> [Exact connected-terminal topology replay](EXACT_CONNECTED_TERMINAL_TOPOLOGY_REPLAY_2026-08-29.md).

## Live result

Relay session `mp-e6cf454422150229` ran the `0.41.7-alpha` crash
containment against a stock modular passenger terminal. Player 1 placed the
terminal over two town buildings and snapped its entrance to a town road. The
terminal appeared once on both peers and the two buildings retired, proving
that the helper containment avoided the earlier native table-converter crash.

The visible result was nevertheless wrong: the terminal entrance ended beside
the road without a routable connection. Proposal
`mp-e6cf454422150229:player1:8`, digest `c3f0d489`, quoted cost `$90,150`,
contained the exact missing graph:

- two collateral construction roots;
- removal of town road `edge:pre:72fc11f4`;
- two replacement nodes;
- two `standard/town_medium_new.lua` road halves; and
- one private `street_station/entrance_new.lua` access edge.

The helper created the construction root and internal entrance geometry, but it
did not reproduce the captured split of the existing road. Both peers then
waited for a three-edge postcondition which that helper path could never
create. Commit 9 correctly faulted closed as
`native-rejection-mutated-prepared-core`; the live session is not resumable as
an unchanged rejection because its physical world already changed.

## Cause

`0.41.7-alpha` deliberately excluded every collateral build from typed
`ConstructionEntity` replay. That was sufficient to prevent the Build 35924
access violation, but too broad for connected stations. The public
`buildConstruction` helper accepts a construction file, parameters, and an
absolute transform; it does not accept the original `SimpleStreetProposal`
which removed and split the road. Geometry that belongs to the construction
resource appeared, while topology that belongs to the player's complete click
did not.

The native crash and the missing connection therefore require two different
boundaries:

1. live construction roots must not cross the typed Lua-table converter beside
   module-bearing construction data;
2. the final station and its road/track replacement graph must still cross the
   exact native `BuildProposal` path.

## Correction

Collateral construction replay is now a bounded two-stage state machine:

1. Engine state bulldozes only the explicitly captured construction/asset
   roots and waits until those roots are absent. Replacement road/track inputs
   are excluded from this barrier.
2. A fresh structural snapshot becomes the attestation baseline. GUI state
   materializes the original typed construction and its road/track topology,
   but deliberately emits an empty construction-removal vector for the roots
   already retired in stage one.
3. The unchanged topology removal remains in `streetProposal`; the native
   command therefore splits the old road and creates the station entrance in
   the same second-stage command.
4. The proposal is requeued through the monotonic work generation so neither
   the GUI nor engine work index can sleep past the second stage.

Failure semantics remain strict. Once stage one has removed collateral, a
materialization failure or native rejection cannot claim that the original
PREPARE world is unchanged and cannot take the lazy-binding rollback path. It
faults for verified restore instead of laundering a partial build into a
recoverable rejection.

The state machine and GUI-specific policy were extracted into
`construction_collateral_replay.lua` and `gui_construction_replay.lua`; both
have explicit source-size budgets. `proposal_runtime.lua` and
`gui_replay_runtime.lua` remain below their existing architecture limits.

## Automated proof

The reconstructed live proposal proves that:

- collateral builds remain excluded from immediate typed conversion;
- they become eligible for exact typed replay only after collateral absence;
- staged materialization contains zero construction removals;
- the captured town-road removal remains present;
- the typed terminal and hydrated module data remain present;
- the post-collateral snapshot replaces the pre-demolition delta baseline;
- the second stage increments the proposal work generation;
- GUI replay recognizes the staged path and retains vanilla soft-error
  behavior; and
- a staged failure cannot advertise PREPARE-world rollback safety.

The complete repository test suite passes, including `143/143` Lua model/codec
tests, runtime and GUI/native integration, two-company mapping, transport and
economy cross-language parity, recovery, relay, launcher, packaging, and
source-boundary checks.

## Remaining live gate

Use a fresh two-peer session containing this correction. Place a large bus or
tram terminal so it both removes one or more buildings and snaps to a town
road. It must appear once on both peers, replace the same road edge on both,
and expose a real native road path into the terminal. Repeat with a truck
terminal. Confirm one finance settlement, a healthy checkpoint, and no delayed
duplicate construction.
