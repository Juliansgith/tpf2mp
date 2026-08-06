# GUI PLAYER entity load crash — 2026-08-06

## Outcome

The deterministic two-peer crash immediately after match initialisation is
fixed.  Build 35924's GUI-side game-script state no longer asks the native
entity view for newly created company `PLAYER` entities while processing
`script.load`.  That projection now uses the already-serialized canonical
network accounts.  Native-account observation remains enabled by default for
the established engine/GUI capture paths that only inspect visible entities.

The full Lua/Python/integration suite passes, the native hook rebuild and both
native tests pass, all 17 executable signatures still match, and the exact
development tree was reinstalled.  Replacement localhost session
`vehicle-clean-buy34-20260806-0002` passed ordered bootstrap and checkpoint 1;
both real game processes remained responsive and displayed the initialized
world beyond the former failure point.

## Failure evidence

Session `vehicle-clean-buy33-20260805-2345` loaded the same frozen starting
save in two exact Build 35924 processes.  Neither user issued a gameplay
action.  Both processes displayed stock `An error just occurred` dialogs at
`2026-08-05 23:46:08` after match bootstrap and the initial checkpoint.

The companion path was healthy at failure: both peers were connected,
checkpoint 1 had converged, no proposal or operation was pending, and neither
the protocol nor native gate reported a session fault.  The two engine dumps
were:

- `16dfc1e7-60b0-4681-8dc4-6ca18b4bb00b.dmp`;
- `d16657b5-b595-44cd-b6ad-7e301b90d5f7.dmp`.

Both recorded the same `EXCEPTION_ACCESS_VIOLATION` at executable RVA
`0x000D0984`, reached from return RVA `0x000C5BD8`.  The crashing threads also
held the same local entity ID, `25`.  The associated traces attributed the
failure to `game/res/gameScript/tpf2_mp.lua_load()`.

Disassembly at RVA `0x000D0920` shows an entity-view sparse/dense lookup.  The
faulting read uses a slot that is not valid for the GUI view yet.  Entity 25 is
the first company `PLAYER` freshly created and bound during
`match.initialise`.  Serialized mod state can reach GUI-side `script.load`
before that separate view admits the new entity.  On this exact build,
`game.interface.getEntity(25)` does not reliably return `nil` or raise a
catchable Lua error in that interval; it can dereference the invalid native
slot and terminate the process.

## Implemented boundary

`public_snapshot.publicSnapshot(options)` now accepts
`allowNativeAccounts=false`.  In that mode it performs no `balanceOf` or
`accountOf` calls for company players or the control player.  Network company
balances continue to come from canonical accounts, so the GUI receives the
same authoritative values without touching a peer-local native entity.

The GUI branch of `script.load` always uses this safe mode.  Other callers keep
the prior default because native proposal/vehicle capture sometimes needs an
already-visible native account.  This is intentionally a narrow lifecycle
fix, not a blanket removal of native finance diagnostics.

A runtime regression constructs canonical companies whose native IDs are 25
and 26, makes both native-read functions throw if invoked, and verifies that a
GUI-safe snapshot performs zero native reads while publishing both canonical
50,000,000 balances.

## Verification

- Full `tools/run_tests.ps1`: passed (55 Lua/runtime cases and 46 Python
  companion cases, plus integration, replay, parity, launcher, and syntax
  checks).
- `tools/build_native_hook.ps1`: passed; native tests 2/2 and all 17 Build
  35924 signatures matched.
- `tools/install.ps1`: installed the exact tested source tree.
- Replacement P1 process `46664` and P2 process `12376`: both responsive,
  native hook stage `active`, companion connected, checkpoint 1 agreed,
  session fault `null`, and no init error dialog.

Three dumps produced during replacement process creation/save-selection are
not recurrences: their exception records are zero-address
`EXCEPTION_NONCONTINUABLE_EXCEPTION` diagnostics, two align exactly with the
launcher's native `click-load-game` timestamps, and both live processes
continued normally.  The fatal RVA `0x000D0984` access violation did not
reappear.

## Remaining live gate

The fix closes the pre-action init crash only.  The open product test is still
the ordinary-UI train lifecycle: build two stations and a connected depot,
create a two-stop line, buy one consist on P1, require it to appear on P2,
assign it with the stock selector, and then run it through a complete trip.
Each physical operation and checkpoint must converge before advancing.
