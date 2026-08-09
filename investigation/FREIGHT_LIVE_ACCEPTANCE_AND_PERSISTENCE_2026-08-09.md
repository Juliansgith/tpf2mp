# Freight live acceptance and cargo-bearing persistence

Date: 2026-08-09
Prototype: `0.32.0-alpha`
State/checkpoint schemas: `29` / `5`

## Outcome

The next human cargo run now has a machine-verifiable pass condition instead
of a visual checklist alone. The companion command `freight-live-report`
validates the complete audit first, selects only successful two-peer format-5
checkpoint boundaries, and summarizes cumulative authoritative freight stages:

`ready -> service -> waiting -> aboard -> delivered -> settled`

The strict default requires non-zero cargo in the economy delivery cursor and
non-zero authored cargo revenue. It also requires matching peer convergence
keys, no fatal consensus outcome, and no unresolved proposal, operation, or
checkpoint barrier. `--require-observed-aboard` additionally requires a
checkpoint captured while a synchronized vehicle had a non-zero exact load.
An incomplete ordinary commit acknowledgement is reported for diagnosis but is
not confused with a failed physical/checkpoint barrier.

The PowerShell entry points are:

```powershell
.\tools\start_freight_live_acceptance.ps1 -RequireObservedAboard
.\tools\analyze_freight_live_evidence.ps1 -Session <session> `
  -RequireStage settled -RequireObservedAboard
```

The launcher wrapper uses the clean manual-network path: two fresh companies
receive 50M each, both peers pass match-start checkpoint consensus, and no
synthetic validator construction pollutes the playable world. It then hands
both connected windows to the player, collects evidence when either window
closes, replays the host audit, and runs the freight-specific gate. That final
gate proves exact loaded-industry consensus and deterministic freight bootstrap
from the audit; it does not claim a pass when only a native cargo icon moved.

## Automatic settlement checkpoint

Every ordered five-minute `economy.settle` now opens the same two-peer
checkpoint consensus used by match start and physical outcomes. This is one
round per economy boundary, not one round per station visit. It captures the
post-settlement stock, production, transport, queue/load/delivery, finance, and
revenue state automatically and blocks later authored work until both peers
agree. Host restart reconstructs the `economy-settlement` tracker from audit.

This closes an observability gap: a successful delivery no longer depends on a
human remembering to export a checkpoint after the next settlement. A manual
checkpoint is no longer required for direct aboard evidence either. The first
host-side `vehicle.sync_release` that leaves authoritative cargo aboard queues
one ordered `freight.milestone` action. Both peers independently verify the
same line/vehicle identity and non-zero ledger load, then automatically export
the `freight-milestone:aboard` checkpoint. This happens once per match rather
than at every station visit.

## Save/load invariant

Cargo ScriptSave migration now aligns every existing cargo ledger with the
persisted synchronized-vehicle rounds and validates it against the current
economy service and freight cursor. Validation includes:

- exact line and vehicle conservation;
- capacity and non-negative bounded counters;
- company, line, route, source/destination, cargo, and contract identity;
- vehicle round/stop agreement with `vehicleSync`;
- freight cursor identity and the rule that settled transport cannot be ahead
  of the presentation ledger;
- economy delivery/payment cursors that cannot be ahead of exact delivered
  units or earned presentation revenue.

The functional Lua fixture boards 40 `GRAIN`, migrates the save with all 40
aboard, delivers the same units after load, applies the stock transfer and
revenue cursor, then migrates again. Both presentation digests and all 40
delivered units survive. A one-unit aboard tamper violates conservation and is
surfaced as a migration error. A payment cursor advanced by one unearned unit
is rejected independently.

## Refactoring and regression coverage

The work stayed inside repository size budgets by extracting:

- `companion/tpf2mp/audit_replay.py` from the central CLI;
- `cargo_presentation_validation.lua` from the presentation state machine;
- `freight_live_report.py` as the semantic audit/report owner.

The current complete gate passes 117 core Lua tests, 75 cross-language economy
scenarios, two focused and 256 stressed freight parity boundaries, 126 Python
tests, runtime/game/GUI/network integration, 1,024-event replay, 107 mod Lua
syntax checks, 42 PowerShell syntax checks, release-manifest checks, launcher
smoke, fault-bundle fixtures, and native-load boundaries.

## Remaining evidence boundary

This is still automated implementation proof. A human cargo-positive
two-process session has not yet produced a report with non-zero waiting,
aboard, delivered, and settled revenue. Save/reload is proven at the authored
state-migration layer, but the native two-window Save dialog/reload path still
needs the corresponding live receipt. Mod cargo and non-rail carriers also
remain live-unproven.
