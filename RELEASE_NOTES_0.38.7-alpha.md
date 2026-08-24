# TPF2MP 0.38.7-alpha

This release removes render-cadence multiplayer work that made station and
bulldozer tools disproportionately slow on the issuing player.

## Build-tool performance

- Native hook `0.19.0` adds a constant-size build-gate sample; hover previews
  no longer serialize complete native command/gate histories.
- Normal network hover no longer hashes/copies an uncommitted proposal or emits
  paired event/telemetry audit records. Exact work moves to the click boundary.
- Change and ownership scans avoid recursively walking full station graphs,
  while bounded fallbacks preserve unfamiliar mod proposal wrappers.
- Idle native command capture polling is sampled without delaying pending local
  vehicle/line correlation.

## Resident launcher performance

- The in-game bootstrap samples launcher/companion files once per second rather
  than once per render frame.
- Loaded worlds no longer walk hidden title-menu save rows or rewrite launcher
  status at uncapped FPS.

## Safety and compatibility

- Every suppressed native build now carries a process-monotonic generation and
  the exact GUI preview correlation token armed before its visitor. A bounded
  64-event FIFO preserves bursts from the modular station editor; missing,
  reordered, stale, cross-company, cross-tool, or overflowed events reject
  visibly and never substitute the newest cached preview.
- Construction templates are immutable. Click-time rebase works on a private
  copy, and cache state is invalidated on tool/family changes, cancellation,
  panel closure, access rejection, bulldozer completion, canonical replay,
  company change, network-mode change, and session change.
- A semantic guard prevents a track/road builder from serializing a station or
  other construction payload. Ambiguity produces no network submission.
- The resident menu pump now retries native API registration on every bounded
  wall-clock sample until it succeeds. Its registration is no longer coupled
  to an exact render-frame multiple.
- Source and release launchers bind the required native hook version. A stale
  DLL is rejected immediately after injection and before the launcher opens or
  loads a world; current release manifests record the exact hook version.
- Failed pre-authority launches explicitly record when launcher safety cleanup
  closed the partial game, distinguishing that action from a game crash.
- Rival-owner vetoes, host ordering, all-peer physical consensus, finance
  reconciliation, and checkpoints are unchanged.
- Invalid compact native samples fail closed. Hook `0.18.0` has a counter-only compatibility
  fallback for source development, but the signed release requires `0.19.0`.
- The 42-entry native Lua-binding catalog now has its own source/test boundary.
- Release packaging builds in a separate native output root, so a running old
  source test can no longer lock the DLL needed to compile the next package.
- Read-only update checks may run during a match; only the actual install is
  blocked until every Transport Fever 2 process closes.

## Live launcher regression proof

A fresh pinned-save host smoke run reached `hosting-world-ready` with hook
`0.19.0`, three native-enabled Lua states, `nativePresent=true`, and a
generation-matched `native-cross-state-script-event` wake receipt. The
disposable process and companion were closed after evidence capture.

## Updating

Close every Transport Fever 2 instance, then use **CHECK / INSTALL UPDATE** in
the multiplayer launcher or run `%LOCALAPPDATA%\TPF2MP\UPDATE_TPF2MP.cmd`.
Start a fresh session; a running game cannot load the new hook or GUI runtime.
