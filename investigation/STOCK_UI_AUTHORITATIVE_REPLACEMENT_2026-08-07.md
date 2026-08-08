# Authoritative replacement of standard game UI

Date: 2026-08-07 (Europe/Amsterdam)

Status: safe existing-leaf projection is implemented and live-tested in
prototype `0.29.0-alpha`.

Cadence and revenue wording in this report is superseded by
[Five-minute delivered economy](FIVE_MINUTE_DELIVERED_ECONOMY_2026-08-07.md).
The GUI replacement inventory itself remains current.

Safety correction, 2026-08-08: the original generic-Component strips and
15-frame native-tree scan caused a live Build 35924 `UI::ContentView` assertion
while opening a depot. A native A/B pass proved that bare TextView leaves are
also unsafe in retained stock manager layouts. All custom stock-layout children
and fallback rows were therefore removed; event refresh is deferred three
frames, discovery is event-driven with a 240-frame safety pass, and GUI state/
snapshot projection is throttled. See
[Depot-open UI hang and GUI performance correction](DEPOT_UI_HANG_AND_GUI_PERFORMANCE_2026-08-08.md).

## Decision

The standard UI remains the primary surface where an existing native leaf can
be rewritten safely. Detailed synchronized facts stay in the isolated
Multiplayer window where TPF2MP owns the whole layout. No public `api.gui`
widget is grafted into a stock layout: Build 35924's hidden-window selector
cannot safely retain it. If a stable stock ID is missing, projection fails soft.

The adapter is presentation-only. It consumes the public snapshot and never
enters canonical state, checkpoints, finance, or command authority.

## Replacement matrix

| Standard surface | TPF2MP behavior |
|---|---|
| Top account balance | Replaced with the active canonical company balance. |
| Top earnings | Replaced with net revenue for the latest authored hour. |
| Top passenger total | Replaced with cumulative authored boardings; the tooltip also shows exact aboard and waiting totals. |
| Top cargo total | Suppressed as `--` until an authoritative cargo ledger exists. |
| Vehicle window | Native load is hidden and transported/finance history is labelled cosmetic. Its native window tooltip points to synchronized context; full load/cost details are in Multiplayer. |
| Line window | Native transported history is labelled cosmetic and the window receives authoritative context in its tooltip; full fare/share/net details are in Multiplayer. |
| Station window | The native agent board is hidden and the window tooltip identifies synchronized endpoint queues; full per-service queues are in Multiplayer. |
| Line and vehicle managers | Native layouts remain intact. Stable controls receive synchronized-context tooltips; full fleet/service summaries are in Multiplayer. |
| Company finances | Canonical balance is projected into the top account. The incompatible native body remains visible as cosmetic history and is not replaced in-place. |
| Line, vehicle, and station statistics | Native tables remain visible but receive a cosmetic-history tooltip; authoritative summaries are in Multiplayer. |
| Buy/detail price and annual maintenance | Preserved. These are the exact post-modifier native values that purchase consensus records and the custom economy consumes. |
| World-space arrival-income popup | Not replaceable through the documented GUI component tree. It can still flash, but is cosmetic and continuous reconciliation prevents it from affecting competitive cash. |

This is intentionally not a blanket style hack. A native value remains visible
only when it is already an exact input to authored economics or when the engine
does not expose a stable supported component to replace.

## GUI lifecycle and safety

`gui_stock_presentation.lua` resolves stock components by stable ID on demand;
it never retains native GUI userdata across frames. Relevant events schedule a
refresh after the native callback returns; a slow 240-frame pass is only a
safety net. Entity windows are found from
`temp.view.entity_<local id>` and manager windows from their stable child IDs.

No child is inserted into a stock window. Existing conflicting widgets are
hidden or relabelled only when their stable IDs/native names are found. Missing
IDs and API failures leave stock UI intact. Cargo is shown as unknown rather
than promoting native scenery to competitive truth.

## Evidence boundary

The GUI harness constructs the real hierarchy shape and verifies toolbar/account
replacement, zero custom stock children, deferred selected-object refresh,
native load/station hiding, preserved manager/statistics layouts, cosmetic
history labels, and authoritative tooltips. Source-boundary tests keep the
adapter below its size budget.

The exact populated crash save has passed five native depot/Vehicle Manager
open-close cycles on both live processes. A later presentation-polish pass can:

1. compare both top bars after a five-minute settlement;
2. select the same line, station, and train on both peers;
3. confirm the Multiplayer detail view agrees while native history is clearly
   cosmetic;
4. buy a modded or vanilla consist and compare its unchanged stock annual
   maintenance with the authoritative ledger.

The supported UI extension points and component lookup API are documented by
Urban Games:

- https://www.transportfever2.com/wiki/doku.php?id=modding%3Auserinterface
- https://wiki.transportfever2.com/api/modules/api.gui.html
