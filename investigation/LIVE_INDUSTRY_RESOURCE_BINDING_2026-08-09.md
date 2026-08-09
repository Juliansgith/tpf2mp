# Live industry resource binding and match attestation

Date: 2026-08-09 (Europe/Amsterdam)

Prototype: `0.30.0-alpha`

State schema: `27`

## Outcome

The first freight-authority gate is complete. Each game now derives industry
recipes from the resources it actually loaded, publishes content-addressed
facts to its own bridge, and must order an exact digest/count attestation before
a network match begins. A mismatch, ambiguity, changed claim, malformed
artifact, wrong peer/session sidecar, or missing live binding fails closed.

This is deliberately narrower than a cargo simulation. It proves what each
loaded industry can consume and produce; it does not yet author stock levels,
station queues, vehicle loads, delivery cursors, or cargo revenue from a real
chain.

## Data path

1. `mod.lua` observes `loadConstruction`, the only supported phase that still
   exposes an industry's real `updateFn`, stock list, parameters, and helper
   output.
2. Static `industryutil` variants are evaluated from their data contract.
   Bespoke callbacks are wrapped and captured only when the game invokes them;
   arbitrary mod code is never eagerly executed by the probe.
3. Each normalized resource becomes an immutable, content-addressed JSON
   artifact under that peer's `content/industry` directory.
4. The companion strictly validates and deterministically merges the artifacts,
   waits for the loader set to become quiet, and atomically publishes one
   session/peer-bound `industry_registry.json` sidecar.
5. The engine script revalidates the complete sidecar and binds each live
   `SIM_BUILDING` construction root to its portable `industry/*.con` recipe.
6. Each peer submits `content.industry_attest` through the ordinary ordered
   lane. State schema 27 digest-projects both claims and the agreed result.
7. On fresh startup, both claims must agree before `match.initialise`. The
   match-initialised checkpoint then anchors the content state together with
   canonical accounts. If content arrives after an existing match has started,
   it receives a dedicated `industry-content-ready` checkpoint.

The companion independently mirrors the ordered claims. Host status exposes
local registry readiness and host consensus separately, so a sidecar existing
on disk cannot masquerade as an agreed match rule.

## Exact loader proof

Disposable fresh-world session `industry-artifact-write-20260809-0550` ran the
loader independently in two exact Build 35924 processes. Each peer wrote 17
artifacts with the same 17 content-addressed names. Strict aggregation produced:

| Fact | Result |
|---|---:|
| Authored freight resources | 16 |
| Evaluated parameter variants | 160 |
| Ambiguous variants | 0 |
| Non-flow helper artifacts omitted from authority | 1 |
| Registry digest | `edc7a517` |

The omitted helper is `industry/extension/field.con`: it is a construction
resource but has no positive freight flow. Its artifact remains audit evidence
and cannot become an industry node.

## Exact two-process consensus proof

Strict session `industry-consensus-live-20260809-0745` seeded each peer only
from its own independently captured artifacts and required content consensus as
a pass condition. The startup order was:

1. Player 1 attestation at ordered commit 1;
2. Player 2 attestation at ordered commit 2;
3. match initialisation and a content-bearing checkpoint at commit 3;
4. the regular bidirectional construction, clock, mobility, and checkpoint
   validator.

The run finished with matching core/model/structure digests
`c3bf105f` / `4b315eeb` / `ae4f8ceb`. The independent audit verified 13
converged ordered commits, 2/0/0/0 complete/rejected/faulted/pending physical
proposals, 3/0/0 complete/faulted/pending checkpoint barriers, six peer
checkpoints, no unresolved peer digest, and no session fault. The distilled
machine-readable receipt is
[`industry_content_consensus_evidence_2026-08-09.json`](industry_content_consensus_evidence_2026-08-09.json).

The first strict run also found and fixed two startup defects:

- automatic match initialisation could race the local attestation already
  occupying the ordered lane;
- attempting a financial checkpoint before canonical accounts existed could
  leave a pending local barrier that blocked account creation.

The validator now waits for agreed content and an idle lane. Pre-match content
is anchored by the immediately following match checkpoint, and checkpoint
precondition failure cannot install a blocking boundary.

## Negative findings retained

- `game.res.getBaseConfig()` exposes typed/generated userdata in this context;
  recursively probing arbitrary keys is neither portable nor safe.
- Build 35924 repository systems such as `stockListSystem` and
  `simCargoSystem` are generated callable tables, not ordinary Lua functions.
  Capability checks use `util.isCallable` rather than `type(x) == "function"`.
- Resource loading is parallel and may revisit a construction. Registries merge
  idempotently and artifacts are immutable rather than relying on callback
  order.
- The fast `app.startGame()` validator bypasses the New Game resource-loading
  transition. Its strict freight mode therefore consumes artifacts from a
  separately proven loader run and refuses to pass without both ordered
  attestations. A normal user-created world performs the loader phase directly.

## Automated coverage

The complete repository gate passes 106/106 Lua tests, 75 cross-language
economy scenarios, 112 Python tests, runtime/game/network/GUI/launcher
integration, source-boundary budgets, and the 1,024-event replay. Dedicated
tests cover strict artifact validation, empty-Lua-array normalization,
idempotent merge, hidden callback ambiguity, live construction-root binding,
session/peer sidecar binding, matching and mismatching claims, audit reload,
startup lane deferral, and pre-account checkpoint deferral.

## Remaining freight authority

The next slice is authored state, not more recipe archaeology:

1. bind each canonical live industry to one attested recipe variant and
   production level;
2. add checkpointed input/output stock and production cursors;
3. bind cargo stations, lines, and vehicles to canonical source/sink contracts;
4. advance queue/load/completed-delivery state at ordered boundaries with
   Lua/Python parity;
5. pay competitive cargo revenue only from completed canonical deliveries;
6. project those values into the stock UI, treating native cargo entities as
   scenery wherever no safe targeted write exists;
7. prove a non-zero vanilla chain on two processes, then a data-only modded
   industry/vehicle pack.
