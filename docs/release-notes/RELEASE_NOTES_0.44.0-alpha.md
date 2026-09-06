# TPF2MP 0.44.0-alpha

Experimental construction and transport testing release.

This release contains substantial construction-capture and transport fixes,
plus a repeatable two-instance test harness that uses ordinary game widgets.
It is intended for trusted alpha testers, not as a claim of complete stability.

## Important testing limits

- Complex placement combining building demolition, road/rail attachment and
  terrain changes is not fully revalidated and may fail or fault the session.
  Ordinary bulldozing is not declared universally broken; coverage of combined
  operations and variants is incomplete.
- Large/cargo airports, cargo ships, every station/depot size/module, long
  bridge/tunnel traversal and arbitrary Workshop constructions do not have
  complete current real-UI qualification.
- The new complete automated railway route is unfinished. Train purchasing
  and selected rail construction cases passed; this is not a full rail
  operating-workflow acceptance claim.
- The truck journey proves empty-vehicle travel, not freight loading, delivery
  or revenue. Positive freight and multi-hop accounting still need broader live
  tests on this candidate.
- Save/load, ownership/finance persistence and paired recovery are implemented
  but not freshly requalified end-to-end on these latest changes. Back up saves
  and prefer a disposable test world. Do not rely on downgrading a save written
  by this release; retain its original backup.
- Intermittent native Load Game screen stalls remain under investigation.
- Passing development runs are tied to their recorded source revisions. They
  are not a full physical-UI PASS for the final versioned package. Release
  preparation does not repeat the complete matrix or run foreground automation.

## Construction and native replay

- Earlier pre-mutation native BuildProposal capture, correlated with command
  insertion and the processed preview, feeds existing canonical authorization
  and ordered replay. No authorization checks are waived for convenience.
- One machine-readable command-safety registry and unique-only geometry/
  topology rebinding make capture and replay boundaries explicit and testable.
- Fix stationary build previews expiring at high render rates.
- Fix mixed rail/public-road crossing capture using the full correlated
  processed topology before ordering.
- Harden connected-depot topology, collateral replay, preview selection and
  line registration/checkpoint ordering.
- Fix airfield edge-object capture, placement transforms and materialization.
  Preserve bounded native construction names so opening a newly built hangar
  does not hit the reproduced missing-NAME assertion.
- Fix left/right roadside bus, tram and unloading-stop reference enums.
- Inventory attached native edge objects explicitly; partial reads cannot
  masquerade as complete empty inventories. Native fingerprints supplement
  canonical checkpoints rather than replacing them.
- Harden empty-array bridge serialization and recovery/checkpoint scheduling.

## Real-game evidence collected during development

Normal UI placement, purchase, line creation, assignment and native motion/
arrivals at both stops passed on both clients for these fixed scenarios:

| Scenario | Verified boundary |
| --- | --- |
| Bus | Road-snapped depot, both curb-side stops and complete passenger-bus journey |
| Electric tram | Connected depot, native road electrification, both curb-side stops and complete journey |
| Truck | Road-snapped depot, unload stops and complete empty-truck journey |
| Passenger aircraft | Two small airfields, hangar access, purchase, taxi, flight and arrivals |
| Passenger ship | Two passenger harbors, shipyard, purchase and arrivals |
| Depot terrain | Actual sampled ground-height changes, matching between peers |

The successful fixed runs passed final ownership/finance checks, converged
checkpoints, settled shutdown and exact-process cleanup. Separate cases passed
free stations and depots, train purchase/replication, free track and a public
road crossing. The reference fixture included Urban Games' Legacy Vehicle Pack;
this does not certify every official or third-party mod combination.

See [the dated qualification](../../investigation/TRANSPORT_UI_QUALIFICATION_2026-09-06.md)
for source fingerprints, failed attempts and precise remaining coverage.

## Repeatable regression testing

- The final release-source offline gate passed 367 Python tests, Lua/native/
  PowerShell checks and the 1,024-event cross-language replay. These are code
  and protocol tests, not 367 live game scenarios.
- Stock-widget input, screenshots and read-only observations of both native
  worlds; equal checkpoints alone cannot pass a build that placed nothing.
- Explicit owner, buyer debit, native vehicle model, movement, distinct stops,
  terrain and station geometry assertions where applicable.
- Source-bound reports, per-case results and final audit/cleanup requirements.
  Failed launches, missing coverage and calibration are not successful proof.
- The full coverage gate remains incomplete; declared scenarios and offline
  corpus counts must not be presented as thousands of live placements.
- Current input automation uses the foreground mouse/keyboard. It is not a
  contained background runner and must not be used while someone needs the PC.

## Updating and reporting

Both players must install **0.44.0-alpha**, close the old session and create a
new one. Supported platform remains exactly two trusted Windows x64 players on
Transport Fever 2 Build 35924. Native hook identity remains `0.20.0`; the exact
release/content checks still require matching installations.

Edge proposals advance to schema 6, constructions use 8/9 (named outputs), and
attached-edge-object inventory uses schema 3. State schema 35, checkpoint format
5 and operation schema 4 are unchanged. This is not a mixed-version session or
blanket old-save compatibility promise.

Update through the launcher or install the release ZIP. The previous release
remains available for rollback with backed-up saves. Report the action, player,
approximate time and non-secret `mp-...` session ID in Discord **#bugs-logs**.
Never post the secret join code. If a session faults, stop issuing gameplay
commands and use an available verified recovery point or a backed-up save.
