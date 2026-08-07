# Authoritative replacement of standard game UI

Date: 2026-08-07 (Europe/Amsterdam)

Status: implemented and offline-tested in prototype `0.26.0-alpha`; a fresh
two-process visual pass remains required.

Cadence and revenue wording in this report is superseded by
[Five-minute delivered economy](FIVE_MINUTE_DELIVERED_ECONOMY_2026-08-07.md).
The GUI replacement inventory itself remains current.

## Decision

Competitive facts must not live in a second dashboard while the normal game UI
continues to present contradictory native-simulation values. The standard UI is
therefore the primary presentation surface for every authored value that has a
stable, supported GUI attachment point. The old `TPF2MP ECO` and `TPF2MP PAX`
rows remain only as fail-soft fallbacks if a stock component cannot be found.

The adapter is presentation-only. It consumes the public snapshot and never
enters canonical state, checkpoints, finance, or command authority.

## Replacement matrix

| Standard surface | TPF2MP behavior |
|---|---|
| Top account balance | Replaced with the active canonical company balance. |
| Top earnings | Replaced with net revenue for the latest authored hour. |
| Top passenger total | Replaced with cumulative authored boardings; the tooltip also shows exact aboard and waiting totals. |
| Top cargo total | Suppressed as `--` until an authoritative cargo ledger exists. |
| Vehicle window | Adds exact authored load/capacity, endpoint leg, line, purchase price, annual/hourly upkeep, and line gross/net. Native load is hidden; transported/finance history is labelled cosmetic. |
| Line window | Adds fare, speed, journey, headway, capacity, allocation, waiting, share, gross, fleet cost, and net. Native transported history is labelled cosmetic. |
| Station window | Adds exact authored waiting and epoch throughput per service. The native agent board is hidden. |
| Line and vehicle managers | Add an authoritative selected-object view or a bounded company service/fleet summary. |
| Company finances | Replaces the incompatible native finance body with canonical balance and latest/cumulative gross-cost-net. |
| Line, vehicle, and station statistics | Replaces native tables with bounded authored service, fleet, and station summaries. |
| Buy/detail price and annual maintenance | Preserved. These are the exact post-modifier native values that purchase consensus records and the custom economy consumes. |
| World-space arrival-income popup | Not replaceable through the documented GUI component tree. It can still flash, but is cosmetic and continuous reconciliation prevents it from affecting competitive cash. |

This is intentionally not a blanket style hack. A native value remains visible
only when it is already an exact input to authored economics or when the engine
does not expose a stable supported component to replace.

## GUI lifecycle and safety

`gui_stock_presentation.lua` resolves stock components by stable ID on demand;
it never retains native GUI userdata across frames. It scans at a bounded
15-frame cadence and on relevant manager events. Entity windows are found from
`temp.view.entity_<local id>` and manager windows from their stable child IDs.

An authoritative strip is inserted directly below the stock window title. A
conflicting native widget is hidden only after that replacement strip attaches
successfully. Missing IDs and API failures therefore leave stock UI intact and
activate the legacy TPF2MP rows instead of producing a blank window. Cargo is
shown as unknown rather than promoting native scenery to competitive truth.

## Evidence boundary

The GUI harness constructs the real hierarchy shape and verifies toolbar/account
replacement, all seven window adapters, selected-object refresh, fallback-HUD
suppression, native load/station/finance/statistics hiding, and cosmetic history
labels. Source-boundary tests require the adapter and keep both new modules below
their size budgets.

The remaining human acceptance pass is deliberately visual:

1. initialize a fresh two-process match and settle one authored hour;
2. compare both top bars and finance windows;
3. select the same line, station, and train on both peers;
4. confirm authored load/queue/net values agree and no conflicting stock board
   or history is presented as authoritative;
5. buy a modded or vanilla consist and confirm the unchanged stock annual
   maintenance equals the authoritative vehicle panel.

The supported UI extension points and component lookup API are documented by
Urban Games:

- https://www.transportfever2.com/wiki/doku.php?id=modding%3Auserinterface
- https://wiki.transportfever2.com/api/modules/api.gui.html
