# Road depot attached to an existing road node — 2026-09-06

## Incident and cause

User run `localhost-manual-20260906-145621`, P1 proposal `2899460b`,
build commit 12, cost 18,987. The stock road depot snapped to existing public
node `node:pre:415c0cfc`, unlike previous road-depot UI fixtures which split
the middle of an existing road segment.

The helper creates a native-selectable depot with its own fixed entrance.
Repair then tried to connect that entrance to the captured existing node
using an approximately 0.585 m residual edge. Native replay rejected this
after creating the depot root, so both peers safety-faulted with
`native-rejection-mutated-prepared-core`. The local test supervisor then
closed both disposable games. This incident's retained evidence establishes
a rejected partial build and supervisor shutdown, not a new native crash dump.

The older fix already coalesced **new road-split junctions** onto the helper's
external node. It did not include the neighborhood of an **existing** node.
Earlier bus/truck/tram UI passes therefore did not cover this shape.

## Fix and safety boundary

`proposal_depot_junction_capture.lua` reads the complete incident road
neighborhood at the suppressed click, before `proposal.prepare`. It does
not scan every preview frame or mutate either the native world or canonical
bindings. `proposal_depot_junction.lua` authors replacement road branches,
the existing node's removal and a new junction slot into the transaction.
The usual bilateral identity, resource, ownership and removal checks now
cover the complete change before any helper is built.

Existing helper graph coalescing then uses the helper's external node as
the junction: no residual micro-edge. The original depot transform, parameters
and cost remain unchanged. Public roads stay public; bus lanes, tram type,
road resources and tangents are preserved. Resource names, not a depot/road
filename whitelist, select native content. A one-branch existing road endpoint
is supported by the same normalization.

Limits: this expansion targets one fresh street-carrier depot with one
captured internal node and one entrance attached to an existing node.
Mixed track/road neighborhoods, unreadable or excessive adjacency (>16),
attached edge objects and construction-owned/frozen infrastructure are
rejected **before** placing the helper. In particular, a second depot must
not remove a first depot's frozen entrance merely because the player owns it.
Construction ownership is queried using the documented
[Street Connector System](https://wiki.transportfever2.com/api/modules/api.engine.html#Street_Connector_System).
This does not claim every modded compound layout or demolition variant works.

## Verification

`tests/run_depot_junction_tests.lua` is part of `tools/run_tests.ps1`.
It reproduces the incident's original entrance geometry, verifies expansion,
coalescing, deterministic branch ordering, idempotence, one-branch endpoints,
unchanged cost/transform, road features and fail-closed adjacency/attachment
checks. Python oracle coverage ensures a free depot or extra micro-connector
cannot satisfy the pinned live recipe.

The fixed, non-calibration UI recipe `content/live-ui/depot-existing-node.json`
passed in `localhost-ui-20260906-164343-7adce4`: actual stock tool clicks on
the same original road node, from its opposite side. Both peers gained one
depot, exactly one net node and one net edge, with identical native geometry,
correct ownership and only P1 debited (15,409 for that placement).
Proposal `07146180` authored both original public road removals
(`edge:pre:736e11fc`, `edge:pre:7532120a`) and the old node removal before
PREPARE. All ten commits converged, the physical proposal completed, and
all three checkpoint barriers completed; no rejected/faulted/pending work.
The physical-UI report passed its supervisor/audit/cleanup gate.

That run preceded the additional frozen-infrastructure guard. The final
candidate passed the same fixed recipe again in
`localhost-ui-20260906-165104-29a35a`, source fingerprint
`a21d8a35e3ce97a32e7f669a75ec192b7bdd5cc4760a2696eef6cbb5edb879a4`.
Both cases passed (32.484 s preview/input and 24.375 s placement case, including
mouse targeting, observer sampling and checkpoint waits—not click latency).
All ten commits, one physical proposal and three checkpoint barriers completed.
The supervisor verified evidence and complete cleanup.

The bus regression rerun `localhost-ui-20260906-165541-27aa2a` was
`INFRA_BLOCKED`: P1's native Load Game page stalled before gameplay.
It did not execute a bus construction/purchase and is not a PASS.
The tram rerun `localhost-ui-20260906-165821-2873cc` hit the same P1
pre-game Load Game deadline and is also `INFRA_BLOCKED`, not a tram PASS.
The batch's overall result must retain this setup failure even though the
separate existing-node regression is proven.

The final fixed candidate is therefore live-proven for this existing public
road-node depot attachment. Re-running the older full bus/tram workflows on
this candidate remains blocked by the separate native save-menu issue;
historical passes are not silently promoted to new source-fingerprint passes.
All test games and companions were closed and all disposable settings restored.
Implementation and live verification preceded preparation of `0.44.1-alpha`.
Release metadata and packaging do not turn the blocked broader runs into passes.

Several earlier attempts stalled in native Load Game before test input.
Two preview-only calibration runs did not place anything. One attempt failed
because a follow-up directory was created before the runner's exclusive output
directory; another rejected an invalid uppercase rotation key. None count as
construction acceptance. Failed attempts remain under `runtime/localhost-live`;
see also `NATIVE_SAVE_MENU_DUMP_HANG_2026-09-06.md` for the separate loader issue.

Local evidence: `runtime/depot-junction-static-final-20260906.log`,
`runtime/depot-junction-qualification11-receipt.json`, and
`runtime/depot-junction-regressions-20260906/`.

Final offline gate: `runtime/depot-junction-final-gate-20260906.log`, exit 0,
`All TPF2MP tests passed.` This was run after the frozen-infrastructure guard
and the new Python oracle regression, with all game processes closed. It
includes the faithful Lua 5.1 suites, native/PowerShell checks, Python tests
and 1,024-event cross-language replay. `git diff --check` also passed.
