# Build-tool preview performance — 2026-08-22

Prototype source: `0.38.7-alpha`
Live evidence source: installed `0.38.6-alpha`, hook `0.17.0`
Session: `match-20260822-2033`

## Finding

The severe FPS loss while holding the station or bulldozer tools is mod work on
the issuing process, amplified by running two complete game renderers. It is
not a GPU-memory or system-RAM limit. The passive peer receives committed
actions only and does not execute the issuer's hover-preview path.

Build 35924 emits `builder.proposalCreate` at render/ghost cadence. In the live
host audit, one short tool-active sample retained 27 preview events and 27
matching telemetry records but only 10 actual `builder.apply` events. The 27
previews comprised 16 bulldozer, 6 track-builder, and 5 construction-builder
events. Eleven native suppressions became real multiplayer captures.

Before this pass, each sampled preview could perform all of the following:

- project a native proposal userdata graph (up to 65,536 general plus 32,768
  construction entries for large stations);
- recursively search that graph for change and ownership-source fields;
- hash and deep-copy the projected graph before any click existed;
- serialize and parse the complete native-hook JSON status, including command
  histories and every gate counter, sometimes twice;
- queue a `native.observed` action which generated both an event and telemetry
  audit record.

The Console-state multiplayer bootstrap remains resident after loading a
world. It was also rereading launcher/companion files on every rendered frame
and, every 30 frames, walking hidden title/save UI plus rewriting status whose
frame field always changed. At an uncapped 180 FPS that was roughly six hidden
UI scans and status writes per second per game.

## Implemented correction

- Hook `0.19.0` exposes `tpf2mp_native_build_gate_sample()`, a locked,
  constant-size `B1` scalar sample. Preview capture no longer invokes the full
  native status serializer.
- Stock proposal change predicates use constant-size known-container checks.
  Their compatibility fallback is bounded and is skipped when recognised empty
  vectors prove there is no change.
- Ownership source discovery follows known wrappers and a bounded mod-wrapper
  fallback while refusing to recurse through large added node/edge graphs.
- A detached preview is retained directly. Hashing and the one network copy are
  deferred until the native visitor proves a click.
- Routine preview and successful-capture diagnostics are disabled in ordinary
  human network play. Operational research and automatic validation retain
  them; errors and rival denials remain observable.
- A preceding suppressed click is settled before a newer ghost replaces its
  latch, using the constant-size native sample.
- Idle line/vehicle native mask polling is reduced to one read per three GUI
  frames, with pending local correlation still checked immediately.
- Once a world is loaded, the launcher bootstrap does not inspect hidden title
  save rows. Durable launcher/companion files and world status are sampled at a
  one-second wall-clock cadence.
- The native Lua-binding catalog was extracted from the full hook translation
  unit and covered by native tests, keeping the repository source boundary.
- Release compilation uses a separate native build root from source-launched
  games. Windows may keep the injected live DLL mapped, but it no longer blocks
  compiling and packaging the next hook; actual install/update remains closed-
  game only.

## Authority invariants retained

This is not optimistic local building. The native tag-15 visitor remains gated;
one suppression still requires one correlated exact/preview payload, rival
ownership is checked before submission, the host orders the intent, every peer
preflights and applies it, physical results reach consensus, and the normal
checkpoint closes the action. Malformed gate samples fail closed. The older
hook retains a heavyweight compatibility fallback, but release `0.38.7-alpha`
requires the exact `0.19.0` profile.

## Automated gate

Focused regressions cover:

- zero full-status reads and zero preview diagnostic intents for ordinary
  network hover;
- exact single capture after native suppression;
- fast-sample parsing, old-hook fallback, and malformed-sample fail closure;
- bounded unfamiliar-mod proposal and ownership wrappers;
- one native pending-mask read per three idle GUI frames with immediate local
  correlation work;
- native binding-catalog identity and unique registry slots.

Native compilation, DLL rejection on an unpinned process, the full Lua/Python
suite, packaging, installer/updater, and launcher tests are the release gate.
The live gate is a fresh two-instance `0.38.7-alpha` run: compare idle FPS, then
hold/move station and bulldozer ghosts, place once, and confirm exactly one fast
replicated result with ownership and wallet behavior unchanged.

## Launcher-throttle regression and correction

The first post-change source launch (`match-20260822-2111`) exposed a cadence
bug before the performance build was handed off. The Console-state pump was
correctly sampled once per wall-clock second, but its lazy native-registration
print still required `frames % 120 == 0`. Sampling only one arbitrary render
frame per second meant that exact frame could be missed indefinitely. The
world and native authority gates had loaded, but the Console state reported
`nativePresent=false`; the launcher timed out the wake and then deliberately
closed the partial game. Transport Fever 2 did not crash.

The registration print now runs once per bounded pump sample while the native
API is absent. A standalone Lua regression starts at frame 1, proves the API is
registered and one generation receipt is written, then proves same-second
render updates perform no additional print or pump work.

That failed launch also selected source runtime hook `0.17.0` while the working
tree required `0.19.0`. Package manifests now carry `hookVersion`; source mode
derives the same value from the exported native build identity. Immediately
after injection, the launcher verifies PID, DLL path, active stage, and exact
hook version before any world load. A mismatch is a clear pre-load failure, not
a latent authority/bootstrap error.

Fresh smoke session `wake-smoke-20260822-212422` then loaded the same pinned
starter save and reached `hosting-world-ready`. Evidence recorded hook
`0.19.0`, three native-enabled Lua states, `nativePresent=true`, pump source
`native-cross-state-script-event`, and a generation-matched wake receipt. The
disposable game and companion were closed after the check.
