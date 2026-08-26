# Road replay with intended building collateral

Date: 2026-08-26 (Europe/Amsterdam)

Status: native replay fix implemented and fully offline-tested after the
`0.40.9-alpha` live finding; a fresh two-computer release proof remains
required.

## Live finding

Relay session `mp-2190a9e01aa42d23` captured a Player 1 road that joined an
existing road at one end and deliberately demolished a town building at the
other. The schema-7 transaction was portable and complete:

- construction removal `construction:pre:e93527e0`;
- four new street edges and two new nodes;
- one replaced street edge;
- `standard/town_medium_new.lua` and canonical cost `33836`;
- transaction digest `5b828458`.

Both peers ordered and reconstructed the same native command. Both native
builders then reported `Collision` and rejected it. No topology or finance
mutation survived, the checkpoint converged, and the session remained usable.
Here, "reconstructed" meant that the command existed in memory; it did not
mean that the engine accepted the build.

## Cause

The vanilla GUI regards the collided building as approved collateral because
the original proposal names that building in its construction-removal vector.
The multiplayer replay path nevertheless called `api.cmd.make.buildProposal`
with `ignoreErrors = false` for every proposal. The replay therefore promoted
the vanilla soft collision warning into a rejection.

There was also no readback proof that every construction id survived assignment
to the generated C++ vector. Other generated Transport Fever 2 vectors have
previously accepted Lua indexed writes without applying the corresponding
native vector conversion, so relying on the apparent write was unsafe.

## Repair

The replay remains one atomic native `BuildProposal`; it never demolishes a
building in a preparatory command.

1. Resolve every canonical construction removal before changing the proposal.
2. Assign the complete removal list through the native whole-vector setter.
3. Read it back and require the exact count and ids. A verified indexed-vector
   fallback exists only for bindings that do not expose the setter.
4. Enable `ignoreErrors` only for the narrowly classified schema-7 topology
   transaction that explicitly carries construction collateral.
5. Inspect the processed native command and again require the exact removal
   set before granting the one-shot native authorization token.
6. Reject before native submission if either verification fails.

This restores the vanilla build decision without weakening clean road, track,
station, depot, signal, waypoint, or arbitrary-construction replay.

## Regression evidence

Dedicated tests now prove:

- whole-vector construction removals round-trip exactly;
- a vector proxy that silently drops writes fails closed;
- the processed native command cannot omit or duplicate an intended removal;
- topology-plus-building collateral preserves vanilla soft-error acceptance;
- ordinary topology replay retains strict error handling;
- removal-only town-road collateral continues to use the atomic path.

The complete repository suite passes: 140 Lua tests, 7 transport-network tests,
3 alpha-readiness tests, all economy/freight cross-language parity vectors, the
256-step deterministic freight stress trace, and the network/company integration
scenarios.

## Fresh live acceptance

Use a new build and a fresh two-computer session; the running `0.40.9-alpha`
pair cannot hot-load this Lua change.

1. Player 1 draws a road that joins an existing road and removes one house.
2. Confirm the road and house removal appear together on both peers.
3. Confirm only Player 1 pays and neither peer needs a retry.
4. Repeat through two or more houses.
5. Repeat with track and a tunnel portal through a building.
6. Test a removal-only town-road segment with an attached house.
7. Make an ordinary collision-free road and station build to confirm their
   strict paths remain unchanged.
8. Confirm the following checkpoint converges and both players can immediately
   continue building.
