# Line-manager main-view hover crash - 2026-08-25

## Live evidence

- Release: `0.40.2-alpha`
- Relay support ID: `mp-8c18530e0ea933fd`
- Origin: Player 1 / host
- Failure time: approximately 12:53:39 Europe/Amsterdam
- Last converged checkpoint before the failure: boundary 61
- Host crash database marker: `6d49cf49-220e-4766-9d45-fd64d13fc618`
- Native minidump ID: `b9507974-d350-4ab5-bf7c-9589a8bc4975`

The line editor's ordered physical operations through sequence 60 completed on
both peers. Sequence 63 reached Player 2's native finalise successfully. Player
1 then stopped servicing the game thread before publishing its corresponding
physical result. The crash handler identified the active Lua callback as:

```text
tpf2_mp.lua - game/res/gameScript/tpf2_mp.lua_guiHandleEvent()
hints: id = "mainView", name = "hover"
```

The companions and relay remained connected, so this was not a transport or
consensus disconnect. Player 2 later rejected the incomplete operation outcome;
that rejection was a consequence of Player 1's stopped game thread.

## Root cause

`guiHandleEvent` called `guiSelectedLine(param)` for every ordinary GUI event.
`guiSelectedLine` recursively collected every numeric leaf in the event payload
and passed each value to `game.interface.getEntity` and
`api.engine.getComponent(..., LINE)`.

A `mainView.hover` payload contains coordinates, dimensions, frame counters and
other transient numeric UI values, not an entity-selection contract. During the
line-editor follow-up window those arbitrary values reached native component
lookups and triggered the game-thread failure.

## Correction

- Line-ID inspection is now limited to actual main-view selection and line
  selection/mutation events.
- The line parser accepts only explicitly named line/entity carrier fields; it
  no longer interprets every numeric leaf as an entity ID.
- The parser was extracted to `gui_line_selection.lua` so the replay runtime
  remains within its 650-line architecture budget.
- A GUI regression sends 240 coordinate-heavy `mainView.hover` events containing
  values that are also valid test line IDs and asserts that no native entity or
  line-component lookup occurs.

## Verification

- Architecture boundary checks pass.
- GUI/native integration test passes, including line ownership and line-manager
  selection retention.
- All 137 Lua model/runtime tests pass.
- Transport, parity, replay, syntax, launcher, relay, packaging, save-sync,
  recovery and restore tests reached by the live-safe suite pass.
- All 197 Python tests pass.
- Release updater and transactional installer tests pass after the live
  Transport Fever 2 instances were closed; their fail-closed process guard was
  also exercised while the games were running.
