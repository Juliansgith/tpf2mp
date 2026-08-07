# Native startup and launcher hardening

Date: 2026-08-07 (Europe/Amsterdam)  
Scope: duplicate game-script startup, stale native-hook status, fatal-dialog
detection, and reliable fresh-world automation on Build 35924.

## Duplicate ScriptSave assertion

Two diagnostic sessions, `startup-save-diag-20260807` and
`startup-probe-diag-20260807`, failed at the same exact engine assertion:

```text
CGame::StartGameSim:
m_data->gameStates[1]->ScriptSave() == m_data->gameStates[0]->ScriptSave()
```

Build 35924 creates and compares duplicate game-script states while starting a
world. The original startup pause path read process-local native clock state and
issued callbacks during initialization. One duplicate could therefore persist
a different `startupPause` record even though both loaded identical authored
state.

## Fix

`network_clock_runtime.lua` keeps the rearm need in module-local
`nativeRearmPending`; it is intentionally absent from ScriptSave and every
digest. `init()` only arms the process-local flag. The first ordinary
`update()`—after the duplicate-state equality boundary—resets the authored
pause/calendar observation and issues the authorized native tag-0/tag-1
commands. A second update confirms speed zero by readback.

The regression creates the two startup calls with different native pre-pause
conditions and proves their serialized records remain identical. The complete
live rerun `startup-rearm-fix-20260807` passed:

- player1: 39 checks;
- player2: 30 checks;
- identical core `5ce6acaa`, model `d0066077`, structure `bab876a4`;
- 11/11 commit convergences, two complete physical proposals, three complete
  checkpoint barriers, and no pending/faulted work.

## Stale PID hook status

Windows can reuse a game PID after an earlier hook or DLL-load test. The
injector previously trusted `status-<pid>.json` before the freshly injected DLL
could replace it, so a stale rejected status could fail a valid launch.

Before injection, `injector.cpp` now removes that exact PID's status unless the
target process already has the requested DLL loaded. Existing live hook status
is preserved for idempotent reinjection; unrelated status files are untouched.
The Release build and DLL rejection test pass after this change.

## Fatal-dialog detection

Waiting only for process exit is insufficient: Transport Fever can display a
modal **Fatal error** window while the process remains alive. Native-world
waits now inspect the exact process's top-level dialogs and fail immediately
with the dialog title. This caught the literal-zero `PersonCapacity` assertion,
allowed the log/dump evidence to be retained, and guaranteed cleanup instead
of parking the launcher until timeout.

## Fresh-world stock wizard

For policy testing, `app.startGame()` was rejected as evidence because it can
bypass active mod data modifiers. `-NativeFreshWorld` is restricted to the
observer-only operational lab and drives **Free Game → Next → Start** through
the stock menu. It cannot be combined with a starting save or restore plan.
The launcher records click diagnostics and the menu component tree, waits for
the active mod world, and restores settings/bootstrap/overlay files in
`finally`.

## Safety boundary

- Native automation targets exact verified PIDs and the pinned executable.
- Temporary base-resource overlays are installed only when their targets are
  absent or already recognized as managed files.
- Fatal or successful runs both restore settings and remove temporary
  bootstrap, game-script, library, and staged-save artifacts.
- Fresh policy worlds are labeled independent observation worlds; they do not
  satisfy the two-computer multiplayer gate.

