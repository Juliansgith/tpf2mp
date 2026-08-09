# Passenger-feeder live acceptance

Date: 2026-08-09 (Europe/Amsterdam)
Implementation target: prototype `0.35.0-alpha`, state schema `29`, checkpoint format `5`

## Outcome

The local bus/tram slice now has a machine-verifiable two-peer acceptance gate,
not only a visual checklist. The companion command
`passenger-feeder-live-report` verifies the complete signed audit and accepts
only successful current-format checkpoints from both pinned peers. It then
requires the following authored chain in one converged boundary:

`model v8 -> local ROAD/TRAM service -> intercity corridor -> positive feeder benefit -> completed local trip -> settled local revenue`

The default `settled` verdict cannot be satisfied by merely registering a line.
The local service must be enabled and have:

- at least two distinct canonical station groups;
- a same-town local market and matching endpoint-town metadata;
- at least one registered and passenger-presented vehicle;
- positive service capacity;
- current passenger-presentation state.

The corridor must be operational, serve two different towns, belong to the same
company, and actually contain positive `feederAccessCents` and
`feederAccessEndpoints` in the settled model result. The local presentation
must show completed passengers and revenue, and the economy delivery cursor
must show the same category has crossed an accounting boundary.

## One consensus definition

The physical/audit scanner formerly embedded in the freight report now lives
in `companion/tpf2mp/live_evidence.py`. Freight and passenger-feeder reports use
the same rules for:

- contiguous ordered commit/control sequence numbers;
- proposal-prepare, proposal, operation, and checkpoint outcomes;
- fatal session faults and unresolved barriers;
- current checkpoint format;
- complete pinned-peer roster;
- matching reason, convergence key, core/model/canonical/financial digests;
- exact equality of authored model, canonical, vehicle-synchronization, and
  financial payloads across peers.

Incomplete commit acknowledgements remain visible in the report but are not by
themselves a failed historical run: closing either disposable game can leave a
final non-barrier intent unacknowledged. Conflicting acknowledgement digests do
fail. Any unresolved physical or checkpoint barrier also fails.

## Adversarial fixtures

The deterministic companion tests prove a positive ROAD feeder with one linked
rail corridor, passengers aboard, completed local travel, and exactly-once
settled revenue. Separate valid checkpoint fixtures are rejected when they try
to pass with:

- a zero feeder benefit;
- a corridor owned by the rival company;
- zero registered local vehicles;
- zero local capacity;
- completed presentation data but a stale zero settlement cursor;
- a pre-v8 model carrying forged feeder-like fields;
- a positive or overpaid settlement cursor without a completed linked feeder
  trip;
- one peer changing the access benefit while the other retains the original.

Carrier filtering also proves that ROAD evidence cannot satisfy a requested
TRAM run. Missing-peer and pending-checkpoint audits fail explicitly. Existing
freight report regressions still pass after the shared-scanner extraction.

## Operator commands

With every game process closed, the complete disposable localhost flow is:

```powershell
.\tools\start_feeder_live_acceptance.ps1 -Carrier ROAD
```

Use `-Carrier TRAM` for a tram-specific receipt, or leave the default `ANY` to
accept either. The wrapper supplies `$200m` to remove setup capital as a test
variable, starts two connected exact-game processes, and tells the player to
build one company-owned intercity passenger corridor plus one same-town local
feeder. Closing either game collects the audit and runs the strict report.

An existing audit can be checked independently:

```powershell
.\tools\analyze_feeder_live_evidence.ps1 `
  -Session feeder-live-YYYYMMDD-HHMM `
  -RequireStage settled -Carrier ROAD
```

`-RequireObservedAboard` additionally requires a converged checkpoint while a
local vehicle carries passengers. Unlike freight's one-time automatic aboard
milestone, this optional passenger snapshot currently requires an explicit
checkpoint during the loaded leg; completed and settled evidence is automatic
at the five-minute economy boundary.

## Evidence boundary

No game was launched for this tooling slice. The analyzers, current-format
fixtures, false-positive attacks, CLI wiring, PowerShell syntax, packaging, and
the repository test suite are automated evidence. The complete gate passes 122
core Lua tests, 108 Lua/Python economy scenarios, 131 Python tests, 108 mod Lua
syntax checks, and 44 PowerShell syntax checks. They do not constitute the
still-open ordinary-UI bus/tram two-process receipt. The live run must still
prove purchase/assignment capture for a real non-rail vehicle, endpoint-only
station barriers, native movement, HUD projection, and acceptable performance.

## Release verification

The exact `0.35.0-alpha` release was built after the full suite passed. The
package contains 278 files and is 7,764,260 bytes:

`SHA-256 607A1655E461C98BA256D5919406EC77BC12F248A5C709F3DDAB60946D6D47D9`

Packaging completed its isolated install/verify/uninstall round trip. The same
release directory was then installed into the normal Steam userdata mod path
and local support-version path. Verification accepted all 108 manifest-bound
mod files, companion `0.9.0`, prototype `0.35.0-alpha`, state schema `29`,
checkpoint format `5`, passenger schema `2`, cargo schema `1`, freight schema
`2`, and the exact Transport Fever 2 Build 35924 native-hook profile.
