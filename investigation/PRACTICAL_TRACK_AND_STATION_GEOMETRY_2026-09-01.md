# Practical track and station geometry qualification

Date: 2026-09-01 (Europe/Amsterdam)

Target: Transport Fever 2 Windows x64 build `35924`, development tree after
`0.42.5-alpha`, construction proposal schema `7`, native hook `0.19.0`.

## Outcome

Long drags and mixed terrain/topology cases are now covered explicitly rather
than inferred from short, flat construction tests. A disposable native world
completed all nine submitted cases, removed every created entity, and then
completed the normal 39-check live validator and native-hook integration gate.

The matrix includes a single atomic transaction that simultaneously:

- removes a persistent `CONSTRUCTION` obstruction;
- removes the source public road edge;
- creates the two replacement public-road halves and their crossing node; and
- creates the two crossing rail edges.

That is the important codec/replay shape behind “drag track across a road while
bulldozing a building.” The disposable obstruction was a validation-owned
construction, not a generated residence. Separate ordinary-GUI captures prove
the same removal vector against one and seven real city buildings during
station placement.

No production behavior was weakened to make the matrix pass. Invalid synthetic
duplicate-track and hand-authored bridge proposals were removed from the runner
after Build 35924 demonstrated that repeatedly feeding native-invalid geometry
can assert inside the engine. Real GUI bridge transactions are pinned instead.

## Native matrix

Authoritative receipt:
[`run-status.json`](../runtime/live-validation/20260901-104429/run-status.json)

| Case | Native result | Exact observations |
|---|---|---|
| Long straight rail | Pass | 990 m, 10 nodes, 9 edges, 17.60 m vertical span |
| Long curved rail | Pass | 1,023.9 m, 10 nodes, 9 edges, 16.92 m vertical span |
| Terrain-following grade | Pass | 665 m, 8 nodes, 7 edges, 14.00 m vertical span, 5.84% maximum sampled grade |
| Tunnel transition | Pass | 900 m, 11 nodes, 10 tunnel edges, 26.95 m vertical span |
| Track across public road | Pass | source road removed; 2 public replacements + 2 rail edges + 3 new nodes |
| Track across road plus collateral | Pass | road split and obstruction removal in one soft-error-authorized native command |
| Track through construction collateral | Pass | obstruction removed, 2 rail edges materialised |
| Rail station on uneven terrain | Pass | 116.45 m sampled terrain span; station root/group/track created; station graph level to 0.05 m tolerance |
| Sequential build recovery | Pass | build/remove/build/remove; both cleanup boundaries exact |

Successful cases, including cleanup, took about 0.36–0.60 seconds apiece in the
disposable local run. Every topology cleanup returned to the pre-case entity
set. The combined crossing/collateral case succeeded on its fourth clear-map
candidate; failed staging candidates were retired before the next attempt.

The probe is implemented in
[`live_geometry_probe.lua`](live_geometry_probe.lua) and is launched with:

```powershell
powershell -ExecutionPolicy Bypass -File .\tools\run_unattended_live_validation.ps1 -RunGeometryStressProbe -NativeHook -SkipTests -SkipNativeBuild
```

## Exact ordinary-GUI evidence

The native stress probe is deliberately complemented by player-origin capture
evidence. The compact facts live in
[`practical_geometry_evidence.lua`](../tests/fixtures/practical_geometry_evidence.lua)
and are checked by the Lua regression suite.

| GUI case | Source identity | Pinned facts |
|---|---|---|
| Rail crosses town road | session `crossing-ui-20260809-0330`, sequence 20, digest `ae34d9d9` | 74 m rail; 2 private rail edges; 3 public road edges; 2 old road edges and 1 node removed |
| Long bridge span | session `station-collateralfix-20260807-111035`, digest `5e25400a` | 11 nodes, 11 edges, 9 bridge edges, about 839.9 m connected length, bridge resource index 4 |
| Bridge extension | same session, digest `5f1fa1fe` | 12 nodes, 12 edges, 9 bridge edges, about 890.7 m connected length, bridge resource index 4 |
| City station | same session, digest `190d9104` | 50 nodes, 48 edges, 1 collateral building |
| City station | same session, digest `0bd6ec9b` | 50 nodes, 48 edges, 7 collateral buildings |
| City station | same session, digest `6e5fed2e` | 50 nodes, 48 edges, 7 collateral buildings |

The historical crossing digest is retained as source identity. The same
transaction projects to `aa7ad9d8` under the current codec because the
canonical projection has evolved; the current projection validates and is
pinned too.

## Ownership boundary

Direct console-origin `BuildProposal` rails materialise as native player `-1`
in this probe. The report therefore distinguishes:

- `ownershipObserved=false`: expected limitation of direct console issuance;
- `ownershipAcceptable=true`: geometry and cleanup can still be qualified; and
- ordinary-GUI evidence: the production path's private rail ownership proof.

This is not treated as evidence that unowned production rails are acceptable.
The production GUI captures retain `private=true` and
`logicalOwnerCid=company:1`, and the existing ownership/replay tests remain
fail-closed.

## Limits that remain human-facing

The matrix proves native materialisation, exact deltas, portable projection,
and cleanup. It does not claim that every possible mouse preview is equivalent.
The remaining practical test surface is:

1. actual GUI drags combining a generated residence, a town road, a bridge or
   tunnel transition, and station snapping in one preview;
2. construction at map borders or at the native maximum grade/radius limits;
3. arbitrary third-party construction callbacks whose evaluated resources are
   not part of the stock manifest; and
4. the same cases over two physical PCs, where latency and preview freshness
   are additional variables.

Those are alpha acceptance cases, not unnamed gaps in the codec. Stock resource
coverage, exact GUI captures, and this native geometry matrix now provide a
repeatable regression floor for them.
