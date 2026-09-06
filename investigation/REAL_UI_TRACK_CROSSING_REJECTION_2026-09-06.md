# Native UI track/public-road crossing rejection

Date: 2026-09-06, Europe/Amsterdam.

Status: underlying replay/binding mismatch reproduced and corrected; the
same physical-UI recipe now builds on both peers. Vehicle traversal and
independent public-road connectivity assertions are still outstanding.

## Evidence

- Run: `localhost-ui-20260906-024148-1395d2`.
- Recipe: `content/live-ui/track-build.json` (run retains its exact copy).
- Save SHA256: `47fbd37409d999392301a884ef3caa6297c682c58cdfda604b1f89ce79f0f5e3`.
- Two windowed Build 35924 clients; TPF2MP plus official legacy vehicles
  content. Not a two-computer or no-other-content proof.
- Physical drag followed by the visible native blue confirmation button.
  No construction injection, console or direct callback invocation.

P1 free track passed: native edges 1694 -> 1696, nodes 1667 -> 1670, two new
existing canonical edges owned by company 1, and only company 1 charged.
Shared checkpoint 9; native fingerprint `037ea22c`.

P2 crossing failed. The preview showed 155 m track and $26,221 quote. Camera
`(-2200,-1000,650,0,0.82)`; drag `(0.54,0.50)` -> `(0.65,0.50)` in the pinned
1920x1040 viewport. It crosses the public road close to an existing segment
endpoint; the split contains a roughly 3 m road piece. That proximity is a
lead, not an established cause.

Capture: `exact=true`, `family=mixed-transport`, `sourceId=trackBuilder`,
correlation 22. Transaction `a63de110`: three track edges, two replacement
street edges, four new nodes, removal of `edge:pre:582811b8`. Public replacement
edges retain `private=false`. Commit 12 reached native replay.

Both peers returned `native BuildProposal rejected` / `Construction not
possible`. No extra edges/nodes remained, P2 retained $50,000,000, and rejection
checkpoint 13 completed. No session fault. Audit: one proposal complete, one
rejected, zero pending/faulted. Both test games/companions were closed and
temporary loader/settings changes restored.

## Investigation boundary

This is not a missing click, stale-preview veto, relay delay or peer disagreement.
Failure is after capture, ordering and materialisation, at native processing.
Possible leads: processed topology being reprocessed, short split geometry,
or original command options not carried into replay. None is proven by the
generic rejection message. Bounded option readback was added to the test-only
observer for a fresh repeat; it cannot submit commands or grant authorization.

## Regression policy

The test must ultimately prove a physical crossing, preserved public road
connectivity, owned private rail, one buyer-only charge and a new bilateral
checkpoint. Counts/fingerprints alone do not prove a vehicle can traverse it.
Do not claim fully qualified crossing coverage before these checks pass.

The harness now recognizes a fresh settled native rejection immediately,
instead of spending the full convergence timeout. It never retries a failed
gameplay click or runs dependent cases on a possibly damaged fixture.

## Fresh repeat

`localhost-ui-20260906-025259-3bc20b` reproduced the same transaction digest
`a63de110` and native rejection at commit 12. P1 free track again passed,
this time with exact two-edge/owner/inventory assertions. Crossing failed
promptly in 18.86 seconds for the whole case (including UI setup/input).
This validates the failure reporting, not a crossing fix. Cleanup completed.

The engine-side retained snapshot option projection was empty on this path;
therefore it did **not** establish the original native factory option values.
Do not infer `ignoreErrors=false` from absent diagnostic fields. To pursue
that lead, capture the bounded option record at the GUI merge boundary before
its pending snapshot is consumed.

## Established cause and correction (04:31 local)

New GUI-side diagnostic evidence in `localhost-ui-20260906-034510-11f4e4`
established the original factory options: `withCost=true`,
`ignoreErrors=false`. The failed replica also used `ignoreErrors=false`,
but its default context had `cleanupStreetGraph=false`.

The factory input had four new nodes and five edges. The correlated native
apply preview contained **five nodes and six edges**, removing two old road
edges and their intermediate node. Native cleanup resegments the short road
fragment and also replaces an intermediate rail node. Our early capture
incorrectly treated the raw factory input as the final physical output graph.

An A/B experiment (`localhost-ui-20260906-041925-dab688`) enabled cleanup
during replay. Native processing then succeeded at the correct $26,221 cost,
but finalization correctly rejected the missing old output slot `node:2` and
faulted on changed physical state. That experimental replay setting was
removed; simply enabling cleanup after ordering is unsafe.

`gui_processed_transport_topology.lua` now selects the generation-correlated
processed mixed-transport graph before canonicalization when its replacement
lineage is available. It checks that native removals remain represented,
additional removals form a connected neighbourhood, each processed road
declares its old-edge lineage, and raw rail endpoints remain unchanged.
Normal canonical resource, ownership, bounds and removal validation applies
to the complete graph on both peers. Construction and edge-object replay
stay on their existing paths. There is no soft-error or authorization bypass.

`tests/fixtures/live-ui/short-road-crossing.json` retains the real captured
raw/processed pair. The new offline test exercises it and adversarial missing
lineage, unrelated removal, endpoint change, positive temporary ID, and
evidence immutability cases; the normal repository gate includes this test.

Real verification: `localhost-ui-20260906-042819-1a6bfc`, both cases PASS.
Two proposals complete, zero rejected/faulted/pending; four checkpoint
barriers complete. Source/installed match and audit valid. Both disposable
games and companions closed. This proves placement and consensus, not yet
the full road traversal or transport-journey matrix.

## Separate launcher investigation

Several fresh pairs stalled at the native Load Game transition before any UI
case. A local stack-only dump is retained for
`localhost-ui-20260906-041406-f56b4d` (P2). Its main-thread stack contains
native UI layout/style work; it is not evidence of a relay or build-codec
failure. Host-first staging alone did not eliminate the stalls. Two later
pairs loaded with the lab's bounded transition allowance increased from 45
to 120 seconds, but this does not establish a root cause or a universal fix.
The lab now retains timeout screenshots and local-only stack dumps before
exact-PID cleanup. No real-user saves were removed or hidden.
