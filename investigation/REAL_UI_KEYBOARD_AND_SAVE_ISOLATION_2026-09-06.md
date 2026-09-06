# Physical UI driver validation, 2026-09-06

## Independent recovery input interrupted a flight

`localhost-ui-20260906-060549-c60537`: automatic recovery began its stock save
fallback for P1 at 06:21:29 local, boundary 57. The `01-maximize.json` receipt
under the session recovery directory proves the unexpected resize was our
helper. The UI runner detected the maximized window and stopped the fixture.
Both games and companions were cleaned up; no qualifying flight receipt was
produced. The native flight itself reached the second airport on both peers.

UI fixtures now pass `--automatic-recovery-interval 0` to the host and
`-DisableUiSaveFallback` to each watcher. Watchers may still collect evidence
and observe saves, but cannot introduce independent UI input. Ordinary
multiplayer recovery defaults are unchanged. These fixtures do not qualify
saving/recovery functionality; that needs explicit separate UI scenarios.

## Letter keys lacked scan codes

`localhost-ui-20260906-062944-f1df77`: four harbor preview observations, with
six M key presses between each, all retained the exact same native transform.
The unchanged-world assertions passed; no placement/rotation coverage was
claimed. No native construction command was submitted.

The physical driver passed zero as `keybd_event`'s hardware scan code, including
letters and Ctrl modifiers. It now maps each allowlisted virtual key using
`MapVirtualKeyW(..., MAPVK_VK_TO_VSC_EX)`, forwards the scan byte, and preserves
extended-key and release flags. Missing/unsupported mappings reject input.
Four new unit tests cover M, extended Delete, interrupted holds, and bad maps.
Live revalidation is required; this is not yet a proven harbor placement fix.

Revalidation `localhost-ui-20260906-063510-f0eec6` still retained the snapped
harbor angle while M was pressed. Do not attribute the earlier invalid shore
previews to keyboard delivery. The next shoreline calibration found valid blue
previews and built two harbors without any rotation keys. Native auto-snapping
can control the orientation ([official construction controls](https://wiki.transportfever2.com/doku.php?id=gamemanual%3Astationsdepots)).

The driver also supports bounded per-step Shift/C modifiers and comma/period
height keys. Modifiers enclose the cursor movement as well as the click/key,
and release in `finally`. This enables slope and disconnected-placement
recipes without injecting construction commands; it does not by itself
qualify those scenarios.

API contracts: [keybd_event](https://learn.microsoft.com/en-us/windows/win32/api/winuser/nf-winuser-keybd_event),
[MapVirtualKeyW](https://learn.microsoft.com/en-us/windows/win32/api/winuser/nf-winuser-mapvirtualkeyw).

The full offline gate before the scan-code edit passed (295 Python tests,
Lua/PowerShell/native checks, 1,024 replay events); focused UI tests after it:
58 passed. Evidence: `runtime/live-ui-static-20260906-0626.log`.
