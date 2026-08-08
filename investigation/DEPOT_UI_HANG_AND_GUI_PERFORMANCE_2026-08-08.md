# Depot-open UI hang and GUI performance correction

Date: 2026-08-08 (Europe/Amsterdam)

Status: root cause confirmed from a live Build 35924 crash trace and two native
A/B failures; the corrected path passes repeated depot open/close cycles in the
exact populated crash save on two processes.

## Incident

In session `economy-v7-easy-20260808-020935`, Player 1 built a long intercity
rail route and line, then became permanently unresponsive when the depot was
opened. Player 2 and both companions remained responsive. The last ordered
physical operation had already completed at checkpoint boundary 153; no
proposal, operation, or checkpoint was pending when the click occurred.

The game emitted this exact native assertion:

```text
UI::ContentView * downcast(UI::ILayoutItem *):
Assertion `dynamic_cast<Target>(x) == x' failed.
```

The crash callback then identified the blocked GUI thread in
`tpf2_mp.lua_guiHandleEvent()` with `id = "tpf2mp.passengerHud"` and
`name = "destroy"`. Writing the automatic crash save took 204.643 seconds,
which explains the long `Not responding` state. The game-generated minidump is
`2bc80551-e938-4df1-bb3a-d5f84d368a96`; an additional full diagnostic dump was
preserved as `runtime/hang-dumps/depot-open-hang-p1-40044-20260808.dmp`.

## Root cause

There were two cooperating defects in the authoritative stock-UI adapter:

1. Passenger/economy rows and authoritative strips inserted public `api.gui`
   children into stock layouts. The generic Component wrapper was definitely
   invalid, but a native A/B run proved that replacing it with a bare TextView
   was still invalid: Build 35924 later rebuilds retained hidden manager windows
   through `UI::CSelector` and checked-downcasts every layout item to a private
   `ContentView` implementation. Public Component and TextView userdata are
   valid `ILayoutItem`s but fail that cast. Removing only the game-info fallback
   rows also failed; removing every mod-created stock-window child passed.
2. `gui_stock_presentation.handleEvent()` immediately traversed and mutated the
   native window hierarchy from inside the same native widget callback.
   `queueAction()` could reach the same code through synchronous `renderGui()`.
   Opening a depot was therefore also a renderer-reentrancy boundary.

The low FPS had three identifiable script-side contributors:

- up to 768 native widgets were walked every 15 GUI frames;
- the full state migration was rerun on every GUI-side engine-state transfer;
- the public snapshot, including model projections and digests, was rebuilt on
  every transfer rather than at display cadence.

The developed route did not create a stuck network barrier and the depot command
never entered ordered capture. The evidence therefore does not support a
network, pathfinding, or depot-ownership cause for this incident.

## Correction

- No mod-created child is inserted into any stock layout. The adapter mutates
  existing native leaves only: account/earnings/passenger totals are replaced,
  misleading history/load labels are hidden or relabelled, and native manager
  controls receive explanatory tooltips. Full figures remain in the isolated
  Multiplayer window.
- The unsafe passenger/economy fallback-row modules were removed, so a future
  stock-ID miss fails soft instead of rebuilding the hazardous layout path.
- Stock presentation is no longer invoked by synchronous `renderGui()`.
- Native GUI events only update selection state and schedule a refresh three
  GUI frames later. No native hierarchy traversal occurs on the originating
  callback stack.
- Toolbar projection is capped at every 15 frames. Window discovery is dirty-
  event driven with a 240-frame fallback rather than a 15-frame full scan.
- A window walk is capped at 192 items and 16 levels. Event-parameter entity
  discovery is separately capped at 256 inspected values and five levels.
- GUI-side current-schema transfers use the already-migrated engine state.
  Public display snapshots refresh every 30 frames, with immediate refresh for
  initialization, company, session, mode, and error changes.
- The load/projection policy was extracted to `gui_load_runtime.lua`; source-
  boundary budgets prevent it from silently returning to the main entry point.

## Automated evidence

The complete repository gate passes after the correction:

- 89/89 Lua model/codec tests;
- GUI tests proving zero `tpf2mp.stock` child insertion and a deferred, single
  existing-leaf refresh;
- current-schema/migration/cadence tests for the extracted GUI load runtime;
- full network-company mapping and proposal lifecycle integration;
- 75 cross-language economy parity scenarios;
- 104 Python protocol, consensus, recovery, and socket integration tests;
- source-size, syntax, packaging prerequisites, and replay verification.

## Native A/B closure

All three runs loaded the same pinned crash save and exact Build 35924 binary:

- `gui-fix-crashsave-smoke-20260808-024540`: replacing wrappers with TextView
  leaves still reproduced the `UI::ContentView` assertion.
- `gui-fix-no-fallback-smoke-20260808-025126`: removing the game-info fallback
  rows still reproduced it, ruling those rows out as the final trigger.
- `gui-fix-no-stock-insert-20260808-025423`: with all custom stock-window child
  insertion removed, clicking the saved `Northfleet Train depot` opened the
  real Vehicle Manager. Five open/close cycles completed with both exact game
  processes responsive, one agreed checkpoint, no pending physical proposal,
  and a valid companion audit.

The on-screen debug counter read approximately 135 FPS on Player 1 with the
Vehicle Manager open, 163 FPS after closing it, and 159 FPS on the idle Player
2 view. Over a ten-second idle sample the two processes used 2.469 and 3.016 CPU
seconds and about 1.17 GiB working set each. This is not a moving-world hardware
benchmark, but it directly refutes the previous persistent 3-10 FPS mod-side
failure in the same developed view. Two renderers and large native stations can
still be GPU/CPU-bound independently of the mod.

Evidence lives under
`runtime/localhost-live/gui-fix-no-stock-insert-20260808-025423`; the bundled
manual-network evidence is
`runtime/manual-network-evidence/gui-fix-no-stock-insert-20260808-025423-20260808-025822`.
The launcher removed both exact games, recovery watchers, and companions after
collection.
