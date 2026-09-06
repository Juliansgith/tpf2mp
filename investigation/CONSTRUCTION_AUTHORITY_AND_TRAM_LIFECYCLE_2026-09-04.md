# Construction authority and electric-tram lifecycle

Date: 2026-09-04 (Europe/Amsterdam)  
Status: implemented, regression-tested, and stock-GUI early capture live-proven

## Outcome

This pass moved construction capture ahead of world mutation, made command-family safety policy machine-readable, added topology-based recovery for stale local IDs, introduced a repeatable construction corpus, and added a cheap native drift tier alongside full structural checkpoints.

The connected electric-tram lifecycle now passes end to end in two real Transport Fever 2 Build 35924 processes. Both peers created two tram terminals, a connected electric road with stops, a connected electric tram depot, a line, and a tram; the tram was bought and assigned successfully.

## Native capture boundary

The hook now correlates three observations:

1. `make_cmd::BuildProposal` preferably captures the native proposal before
   application.
2. `CommandList::Add` identifies the concrete queued command instance, or
   performs the same synchronous decode when a caller bypasses the factory.
3. `BuildProposalVisitor` remains the suppression and post-issue observation point.

The captured native portion includes street/track nodes, tangents, edge topology and carrier flags, removals, edge objects, frozen nodes, segment tags, and construction resource/transform changes. Existing GUI capture supplies semantic construction parameters, quoted cost, edge-object semantics, and terrain/alignment fields that are not independently decoded from the Build 35924 layout. Factory-only option arguments are attested only on the factory branch; the Add fallback marks them unavailable. The result is intentionally hybrid; it is not a claim that every native terrain payload field is decoded.

Late manual regression testing exposed four invalid assumptions in the first
merge implementation: segment tags are sparse rather than edge-parallel;
shallow GUI aliases can coexist with the exact apply payload; the GUI view may
omit collateral construction removals; and the first edge-object record scalar
is not a portable temporary identity for every builder. Those assumptions
rejected crossings, road terminals/depots, edge objects, and build-plus-
demolition clicks before mutation. The corrected design puts decoded topology
in an explicit `__nativeTopology` envelope, retains GUI-only edge-object and
parameter semantics, takes the validated identity union of native and exact-
GUI collateral removals, and
falls back to the exact generation-bound GUI path for an explicitly unsupported
optional decode. Correlation loss, replay, overflow, or contradictory resource
identity still fail closed.

The exact executable profile now verifies 19 runtime signatures, including:

- `make_cmd::BuildProposal` at RVA `0x9dc750`
- `CommandList::Add` at RVA `0x9d2a00`
- `BuildProposalVisitor` at RVA `0x9d6440`

Unsupported executable hashes remain fail-closed.

## Command safety registry

`content/native-command-safety-v1.json` is the source of truth for all 37 known native command tags. Generated C++ and Lua views bind visitor behavior and one-shot authorization to the same data. Tests check registry/visitor completeness in both directions and bind supported operation codecs to their declared replay paths.

The registry's suppression and callback fields are mechanically enforced. Its ownership, cost, replay, and postcondition descriptions are policy metadata backed by targeted codec/runtime tests; they are not all executable dispatch fields yet.

## Binding recovery and rollback

Canonical IDs remain primary. When an existing local binding is stale or missing, the runtime may recover it only from a unique fingerprint composed from portable identity facts such as resource, transform, endpoints/tangents, carrier type, owner, and neighbouring topology. Zero or multiple matches fail closed.

PREPARE and COMMIT resolve the same candidate. Canonical maps, ownership, pinned custody, and revision are snapshotted before rebinding and restored atomically on any later failure. Exact construction callbacks also carry portable identities for compound construction outputs, which makes save/load and replacement recovery less dependent on local creation IDs.

## Drift tiers

- The cheap tier fingerprints canonical bindings and bound edge/construction/vehicle identities after physical operations and periodically during play.
- The full structural tier inventories the native world and remains the authority for detecting extra unbound entities and complete town/industry drift.

Cheap samples deliberately do not reuse a prior full inventory; stale evidence cannot make a later sample appear complete.

## Construction corpus

The corpus declares 13 families and expands to 2,848 static cases. It covers long/curved/graded rail and road geometry, slopes, bridges, tunnels, crossings, demolition, station/depot variants and orientations, modules/upgrades, signals/waypoints, official content, and selected mod-content compatibility declarations. Live-required cases are explicitly distinct from static codec/fixture cases.

## Tram defect and fix

The earlier relocated tram depot failed because its captured connector tangent stayed approximately 90 degrees from the generated route. The repair now rigidly rotates the construction transform, internal offset, connector tangents, and placement behind the route endpoint, and verifies collinearity before submission.

Two additional Build 35924 facts were corrected:

- street transit capability is exposed by `hasBus`, not `bus`;
- tram types are `NONE = 0`, `PLAIN = 1`, and `ELECTRIC = 2`.

The synthetic route and depot are therefore both electric. Proposal materialization is exception-safe so an invalid fixture fails as a normal rejected operation instead of terminating the script callback.

## Verification receipt

Static and cross-language regression suite:

- 158/158 Lua scenarios passed under the pinned faithful Lua 5.1 runner;
- native hook build and CTest passed, with all 19 Build 35924 signatures verified;
- Python companion, replay, recovery, launcher, packaging, documentation, and source-boundary suites passed;
- construction corpus validation passed all declared static cases;
- final result: `All TPF2MP tests passed.`

Live run: `runtime/localhost-live/localhost-tram-route-20260904z19--tram-electric-lifecycle-e2e`

- physical proposals: 4 complete, 0 rejected, 0 faulted, 0 pending;
- physical operations: 3 complete, 0 rejected, 0 faulted, 0 pending;
- checkpoint barriers: 10 complete, 0 faulted, 0 pending;
- commits: 24/24 converged;
- checkpoints: 20;
- final core digest: `555cf386` on both peers;
- final structural digest: `db21d780` on both peers;
- games and companions were terminated by the disposable harness after success.

An immediately preceding run (`z18`) failed before authority because Player 2's stock Load Game page did not open within 45 seconds. No proposal was submitted, both disposable processes were closed, and the fresh `z19` retry passed.

## Stock GUI early-capture receipt

Disposable run `runtime/supported-api-probe/20260904-203543` used physical
mouse input to select the vanilla rail-signal category, select the first stock
signal, and apply it to a generated track. The observed capture was:

- source: `factory`;
- generation/correlation: `1` / `900000001`;
- factory/Add caller RVAs: `4591115` / `4591145`;
- one removed edge, one replacement edge, and one added edge object;
- matching factory/Add thread `2332`;
- one decoded, added, suppressed, and consumed capture;
- zero invalid, suppressed-miss, ready-drop, pending, or residual-ready items.

This closes the missing real stock-click proof for the signal path. It does not
claim every stock construction palette or arbitrary mod callback follows the
same factory caller. The synchronous Add fallback has native unit coverage but
was not selected by this signal click. Terrain-heavy and scripted-content
builders therefore remain focused compatibility tests, while the successful
tram run separately proves replay, output binding, connected topology, vehicle
lifecycle, and two-peer convergence.
