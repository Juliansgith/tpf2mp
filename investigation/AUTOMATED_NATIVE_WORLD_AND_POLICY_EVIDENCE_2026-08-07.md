# Automated native-world and presentation-policy evidence

Date: 2026-08-07 (Europe/Amsterdam)  
Pinned executable: Transport Fever 2 Build 35924, SHA-256
`782b904a8f7bbdac1f7a18528f1a5c778691e5aa3087c37c351bf6912585175c`

## Result

The launcher can now create real fresh modded worlds without human input, and
the crowd-policy experiment has an exact positive/negative/control result:

- skeleton construction scaling runs in fresh worlds;
- vanilla worlds retain materially larger town capacity per construction;
- literal zero person capacity crashes Build 35924 during world generation;
- the corrected minimum-safe policy passes on both worlds;
- policy and physical-town-growth choices are bound into the match manifest;
- three rounds of ordered native town development converge structurally on two
  exact game processes.

These policy worlds are independent local observation worlds. They are not
presented as multiplayer consensus. The separate town-development run is the
connected two-process convergence experiment.

## Why a new launcher path was required

`app.startGame()` is useful for disposable engine-shape probes, but Build 35924
does not reliably apply the selected mod's data modifiers on that path. It
cannot prove `loadConstruction` capacity scaling.

`run_localhost_live_validation.ps1 -OperationalCaptureLab -NativeFreshWorld`
instead follows the stock menu:

1. maximize the exact game window;
2. click **Free Game**;
3. read the wizard component tree;
4. click bottom **Next**;
5. click bottom **Start**;
6. wait for the native world and active mod script;
7. capture operational evidence and close both exact PIDs in `finally`.

The menu bootstrap publishes semantic rectangles (`nextGameRect` and
`startGameRect`) with text fallbacks. The title-bar **Play map** control is not
treated as the wizard start button.

## Fresh-world policy results

| Policy/session | Peer | Constructions | Town capacity | Persons | Capacity/construction |
|---|---|---:|---:|---:|---:|
| skeleton / `round3-skeleton-native-fresh-v4-20260807` | player1 | 584 | 563 | 267 | 0.96 |
| skeleton | player2 | 409 | 388 | 190 | 0.95 |
| vanilla / `round3-vanilla-native-fresh-20260807` | player1 | 374 | 1263 | 428 | 3.38 |
| vanilla | player2 | 493 | 1857 | 628 | 3.77 |
| minimum safe / `round3-minimum-native-fresh-20260807` | player1 | 429 | 408 | 208 | 0.95 |
| minimum safe | player2 | 410 | 389 | 193 | 0.95 |

Every passing capture remained stable across its samples: no model, core,
structural, mobility, autonomy, account, or native non-script mutation drift.
The minimum-safe run explicitly reports `mode=empty`,
`constructionScalingActive=true`, `runtimeScalingWorks=false`, and fingerprint
`agents:empty:1:1000000000:1:pinned:0:0` on both peers. Runtime scaling is false
by design: existing-world `setTownInfo` mutation is disabled after its negative
readback experiment.

The skeleton run predates adding the policy object to every operational
envelope, so its selected mode is established by the run status and launcher
configuration rather than a retroactively invented readback. New captures put
the policy object beside native counts, and the analyzer now publishes it.

## Literal-zero negative

Evidence: `runtime/localhost-live/round3-empty-native-fresh-20260807`.

Build 35924 opened a fatal dialog during world initialization. The game log
names entity `20061`, component `PersonCapacity`, and assertion
`ComponentManager::GetComponentTypeIndex: it != m_compType2index.end()`.
Crash dump id: `5d1f7ac5-ac61-4b64-ac43-e298caf2ce76`.

This is not a flaky timeout: the launcher detected the native fatal window,
captured the exact assertion, marked the run failed, restored settings and
temporary resources, and stopped both processes. The shipped `empty` key now
means a denominator of one billion with a floor of one for positive-capacity
buildings. Zero-native buildings remain zero.

## Match-content binding

Agent policy and town-development mode affect the physical world and therefore
cannot be peer-local preferences. Both normal Host/Join and localhost launchers
write byte-stable JSON:

```json
{"schemaVersion":1,"agentMode":"skeleton","townDevelopment":false}
```

That file is a manifest input. Two peers with different policy/growth choices
therefore receive different match fingerprints before either world starts.
The short-lived launcher config also carries both settings and takes precedence
over stale in-game mod parameters.

## Connected physical-town result

Evidence:
`runtime/localhost-live/round3-town-construction-pos-20260807/run-status.json`.

Both peers began at structural digest `1ef990cc` and Northfleet capacity 633.
Three batches of eight native calls produced the same per-round state:

| Round | Capacity | Structural digest |
|---:|---:|---|
| 1 | 657 | `4f3b90dd` |
| 2 | 687 | `4c6390e2` |
| 3 | 704 | `2de890d4` |

The final ordered structural checkpoint was boundary 22. Both peers ended at
core `b418e90f`, model `ca0582b4`, and structure `2de890d4`; the host passed 52
checks and the client 39. This proves a physical change and exact convergence,
not merely two identical no-ops.

## Automation and regression status

- Full repository gate: 71 core Lua tests, 73 cross-language economy vectors,
  all game/GUI/launcher integrations, 99 Python tests, and long replay checks.
- Native Release build: both CTest cases pass; all 17 pinned signatures resolve
  uniquely at their expected RVAs.
- Operational analysis now includes construction count, total town capacity,
  direct person count, and first/last agent-policy readback.

## Remaining human gates

- Inspect several towns after dozens of authored buildings and tune the
  400-carried-passenger threshold.
- Run the same growth/policy configuration on two physical computers.
- Decide whether the minimum-safe compatibility key should be renamed in a
  future schema; renaming it now would break existing launcher/settings input.

