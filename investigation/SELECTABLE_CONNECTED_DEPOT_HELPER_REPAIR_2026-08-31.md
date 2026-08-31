# Selectable connected-depot helper repair

Date: 2026-08-31 (Europe/Amsterdam)

Status: implemented and fully regression-tested. The road-depot path has
completed a two-process native build, connection, ownership correction, bus
purchase, physical consensus, and checkpoint-convergence run. A fresh packaged
human click test remains the final stock-window acceptance gate.

## Reported evidence

In relay session `mp-2002d7bf8175d520`, Player 1 placed three depots and created
a line. Opening a depot then produced Transport Fever 2's internal-error path on
Player 1 while Player 2 remained healthy. Player 2 also saw the depot projected
under its local native player rather than Player 1's company.

The relay was not responsible. Player 1's last ordered line update had completed
and Player 2 retained a healthy consensus state. The failing Player 1 stack was
the stock `contexthelper.lua` selection path. This is the same engine boundary
previously measured for typed rail depots: a depot root created by a typed
`ConstructionEntity` may exist and pass topology checks, yet still be unsafe for
the stock depot context window.

The ownership symptom was also real and was not caused by the later error.
Build 35924 expands a typed construction under the local command issuer. On the
remote peer that can replace the intended company representative with that
peer's local player. Rewriting fields after expansion corrects the value but
does not make the typed root safe for stock selection.

## Replacement architecture

Fresh depot roots no longer use typed construction replay.

1. `game.interface.buildConstruction` creates the stock-selectable road or tram
   depot root using the captured resource, parameters, transform, and intended
   peer-local company owner.
2. The engine-generated helper graph must stabilize to exactly one construction,
   one depot, two nodes, and one street edge. Any other shape rejects closed.
3. The helper's complete entrance remains untouched. Removing or replacing its
   construction-owned edge is rejected by Build 35924.
4. A topology-only `BuildProposal` appends the missing connection from the
   helper entrance to the captured existing road node. The original Hermite
   curve is translated to the helper endpoint by adjusting both tangents.
5. The submitted canonical node maps to the helper's internal node; the
   submitted canonical edge maps to the appended connector. The helper entrance
   edge is retained as an explicit private derived output.
6. The root, depot, canonical connector, and helper entrance are all assigned to
   the proposal company before completion. A public connector edge is replaced
   through the established safe edge-owner repair transaction.

This is graph-derived, not a vanilla filename allowlist. Stock road depots,
ordinary/electrified tram depots, and compatible mod-provided street depots
inherit the same path. Connected rail depots remain rejected before mutation;
their helper/track topology needs a separately proven stock-safe design.

## Why the helper entrance is canonical

The first successful native iteration left the stock helper edge physically in
the world but excluded it from proposal outputs. A later structural probe then
discovered it as `edge:pre:74991209`. Both peers independently reached the same
new core digest, so gameplay converged, but the change occurred outside the
ordered event journal and the recovery auditor correctly rejected it.

The entrance edge is now bound during proposal finalisation as
`edge:event:<event-id>:helper:1`, output slot `edge:helper:1`, with private
logical ownership and pinned native custody. Consequently the post-proposal
checkpoint already includes every retained player-owned edge; a read-only
structural soak cannot invent canonical state afterward.

## Native and automated proof

Development run `depot-helper-road-20260831-7` used two Transport Fever 2 Build
35924 processes with both exact native-hook profiles active. It proved:

- the stock helper root and topology-only connection both succeeded;
- the generated public connector was rebound to Player 1 on both worlds;
- the connected road depot passed its complete graph postcondition;
- a stock bus was purchased through the canonical depot on both worlds;
- proposal, operation, and checkpoint consensus completed;
- final core digest `8d0812ef` and structural digest `6cef503c` matched; and
- both game processes and companions were closed after the run.

That run's sole offline-audit rejection was the late helper-edge discovery
described above. The derived-output fix is directly regression-tested. A later
native rerun could not pass the pinned-save loader because the Windows desktop
denied foreground interaction; both disposable attempts were stopped cleanly
before world load and are not counted as gameplay evidence.

The complete repository suite passes: 147 Lua model/codec tests, 7 transport-
network tests, 3 alpha-readiness tests, all cross-language economy/freight
vectors, the 256-step freight stress replay, 1,024-event deterministic replay,
Lua/PowerShell syntax and lifecycle tests, and 225 Python companion/relay/
recovery tests.

## Remaining acceptance

In a fresh packaged two-computer room:

1. Player 1 places connected road and tram depots.
2. Player 1 opens and closes each depot before and after creating a line, then
   buys one appropriate vehicle.
3. Player 2 confirms both depots are visible but cannot manage, buy from, edit,
   or bulldoze Player 1's depots or entrance edges.
4. Both peers confirm the road/tram connection is routable and the session stays
   healthy after another unrelated build.

This manual gate checks the stock context window and rival-facing UI. The
physical construction, canonical ownership, purchase, finance, consensus, and
checkpoint paths already have automated or two-process evidence.
