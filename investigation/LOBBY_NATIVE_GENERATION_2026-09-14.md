# Lobby and native new-world investigation — 2026-09-14

Initial pre-live research record. Later implementation and live evidence
supersede its next steps: see LOBBY_NATIVE_ACCEPTANCE_2026-09-15.md and
docs/LOBBY_DEVELOPMENT.md.

## Scope and safety

Implement the launcher lobby/new-world workflow without changing gameplay
authority or requiring manual save preparation. Work is local and uncommitted.
No relay deployment, production binary patch, installation, game launch or
personal save write was performed in this slice.

## Verified software evidence

- Companion: nine new lobby unit tests; complete Python suite **411 tests,
  one existing skip**, success.
- Relay: **43 tests passed**, including authenticated lobby HTTP routes,
  bounded payloads, role authorization, stale revisions, presence expiration,
  immutable settings after Start, existing-save identity checks and bounded
  rejection of malformed/deep JSON and oversized integers.
- `tests/lobby_loopback.py`: real HTTP between the companion lobby client and
  temporary relay, with separate host/join mod directories. Passed mismatched
  content rejection, Ready, configuration-change invalidation, stale Start
  rejection, Start phase/digest propagation and cancellation.
- WinForms preview: host and join smoke passed on Windows PowerShell 5.1,
  including an empty peer map. No visual/live interaction claim.

## Build 35924 native findings

Read-only PE reference search, x64 unwind ranges and Ghidra decompilation of the
installed executable (SHA256
`782b904a8f7bbdac1f7a18528f1a5c778691e5aa3087c37c351bf6912585175c`).
Addresses below are **RVAs**. These are research observations, not qualified
hook signatures or permission to invoke a function with guessed structures.

| RVA | Observation |
| --- | --- |
| `0x677d00` | `CMenuUI::StartNewGame`; identified by its initialization-active diagnostic. Checks `this+0x1988`, switches menu page, consumes several native structures and a prepared world/map object. |
| `0x655cb0` | Normal menu callback calls StartNewGame with captured settings and `menu+0x518`, then releases that prepared object. Ownership and lifetime matter. |
| `0xc16210` | Registers application Lua bindings, including `startGame`. |
| `0xc14ba0` | Application test-start implementation also calls StartNewGame. Creates test defaults, has an explicit date initialization with `0x7c6` (=1990), and constructs empty vectors at the call site. Not a general settings-taking API. |
| `0x66c2b0` | Normal new-game setup page builder, 19,361-byte unwind range. Decompiled for tracing setting bindings and generation job ownership next. |

The earlier benchmark's `app.startGame()` call from a script update reproduced
`UI::CComponent::Render: !m_childMutex`. The presence of a StartNewGame function
does not resolve the safe call boundary, resource loading or native ownership.
Do not replace the normal launcher with this test shortcut.

The other project's local `docs/re/GAME_LOOP_AND_UI.md` describes scheduling
save loads after `CMenuUI::Update` (RVA `0x672b10`). That is a useful research
lead, not independent verification that fresh generation is safe there. No
third-party implementation was copied into the runtime.

Local evidence (ignored runtime files): `runtime/lobby-native-targets.json`,
`runtime/lobby-newgame-callers.json`, `runtime/lobby-generation-targets.json`,
`runtime/lobby-native-decompile/`, and the corresponding Ghidra console logs.
Ghidra ran with `-readOnly`; database changes were discarded and no PE was changed.

## Next qualification target

Trace the normal map-generation submission from the new-game page, preserving
the native selected-mod vector, generator settings and prepared-map ownership.
Build a disposable generator job and prove requested year/seed/settings/mods in
its output, before connecting the lobby's Start transition to any game process.
Then qualify save bundle transfer and both peers' initialized authority gates.

See `docs/LOBBY_DEVELOPMENT.md` for implementation limits and repeatable checks.
