# Save/load native manager ownership repair

Date: 2026-08-06 (Europe/Amsterdam)

Implementation: prototype `0.22.0-alpha`, state schema `22`

## Symptom

Loading the populated multiplayer save preserved the visible railway, but its
stations and train appeared unowned. Company 1's stock Line Manager and Vehicle
Manager did not list the saved line or consist. Canonical snapshots still
reported one Company 1 line, one vehicle, two stations, and the correct stops,
so ordinary core/structure convergence did not expose the native UI failure.

## Root cause

The source save was last written with the old Player 2 selected. Its native
player list was `{ 9480, 5743 }`; the saved railway belonged to native player
`9480`, while selected player `5743` was persisted in the game script as
`player2`.

A fresh network bootstrap correctly reset peer-local bindings and mapped the
currently selected native player to the local canonical company. It could also
create a new representative for the remote company. It did not, however,
project manager-visible entities from their saved native owner onto those new
representatives. Canonical ownership remained Company 1 on both peers while
the stock managers filtered the entities under an obsolete native player ID.

This is an important convergence lesson: a local-ID-free canonical digest can
be correct while a required peer-local projection is absent. The projection
must be applied and read back before the first checkpoint, not merely excluded
from the portable digest.

## Repair

`native_ownership_projection.lua` now runs after fresh network company binding.
It:

1. maps the selected native player to the local canonical company;
2. reuses a valid saved native player for the remote company when possible;
3. visits logically owned constructions, station groups, stations, depots,
   assets, edge objects, lines, and vehicles in dependency order;
4. applies `game.interface.setPlayer` to the peer-local representative;
5. immediately reads `PLAYER_OWNED` back and fails match initialization if a
   required manager-visible projection did not stick.

The portable world stores only a deterministic compact summary of required
objects and retained edges. Peer-local projected/unchanged counts are returned
for diagnostics but do not enter cross-peer convergence.

`BASE_EDGE` is deliberately excluded from physical projection. Build 35924's
legacy player setter asserts on base edges; their canonical logical owner and
pinned custody remain authoritative. The projection therefore fixes native
stock-manager semantics without reopening the previously measured edge crash.

## Coverage and live evidence

The Lua regression recreates the exact old-Player-2-selected save shape. It
proves that Player 1 moves the saved Company 1 line to its current native
representative, Player 2 reuses the saved remote representative, and both peers
retain the same canonical company digest. The network mapping integration adds
a pre-existing line and vehicle, verifies both are rehomed on Player 2, and
asserts that the base edge is not touched.

`runtime/localhost-live/train-ownership-projection-state22-20260806-102759`
then loaded the exact populated save into two Build 35924 processes. Both peers
passed the train synchronization run and converged at core `1335e61d`, model
`98f01295`, structure `cbd2a375`, and mobility `8e8590e7`, with zero unresolved
audit state.

Finally, `ownership-human-state22-20260806-103252` visually confirmed the seam
automation cannot honestly inspect: Company 1's stations and depot showed
ownership, `main line` appeared with two stops in the stock Line Manager, and
the three-part train appeared assigned to it in the Vehicle Manager. Company
2 still saw the shared physical world while its company-filtered managers did
not claim Company 1's line or train.

## Remaining boundary

This repair covers save-time native player-ID churn for the enumerated
manager-visible types. A save taken during an in-flight station release,
disconnect/reconnect with binding loss, multiple pre-existing companies beyond
the two-player contract, and automatic coordinated rollback still require
their own live recovery proofs.

## Native save-row selection race

The first attempt to start session
`modal-pause-protection-20260806-1411` was correctly rejected at checkpoint.
Player 1 had reopened the preceding modified lab world (50 canonical edges,
49 nodes, three edge objects, and two vehicles), while Player 2 loaded the
pinned baseline (40 edges, 40 nodes, no edge objects, and one vehicle). Their
convergence keys differed and no play was permitted.

The pinned save name was visible and the launcher physically clicked its exact
text rectangle. The automation then wrote its `save-selected` marker and
clicked Start with no settling interval. Build 35924 processes the mouse event
asynchronously; on a slow menu frame, Start could still launch the row that
was selected when the Load Game page opened.

`Invoke-Tpf2mpPinnedSaveLoad` now waits 750 ms after the exact save-row click
before arming Start. The immediate rerun,
`modal-pause-protection-20260806-1416`, loaded the same pinned baseline on both
processes and passed checkpoint 1. This is a live-proven race reduction. A
future engine-readable selected-row assertion would be stronger than timing
alone and remains worthwhile if another wrong-row launch is observed.
