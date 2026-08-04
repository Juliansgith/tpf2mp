# Consequential command visitor gates on Build 35924

Date: 2026-08-02  
Prototype/native hook: `0.14` / `0.7.0`  
Executable SHA-256: `782b904a8f7bbdac1f7a18528f1a5c778691e5aa3087c37c351bf6912585175c`

## Result

Network mode now fails closed for 23 consequential native command categories that do not yet have canonical payload codecs. An action reaches the original engine visitor only when the gate is disabled or one matching tag authorization is consumed. Rejection happens inside `ApplyCommand`'s normal variant dispatch, so the engine writes `success=false` and completes the ordinary callback path without mutating the world.

This closes a safety hole: line, vehicle, naming, terrain, speed, date, and cheat commands can no longer silently mutate only one peer merely because their replication codecs are unfinished. It does **not** make those actions network-playable; it deliberately makes them unavailable until each gains capture, canonical validation, ordered replay, and physical postconditions.

## Pinned dispatch layout

Static disassembly of `ApplyCommand` at RVA `0x009DA290` shows:

1. command data is read from the command wrapper;
2. the signed variant byte is read at command-data offset `0xB18`;
3. the tag selects one of 37 boolean visitors through the table at RVA `0x030B10C0`;
4. the visitor return value is written to command offset `0x30`;
5. normal result/error and callback processing continues.

The DLL validates the exact executable hash and existing 17 code signatures, then checks every selected table entry against its pinned runtime RVA before installing any hook. A mismatch aborts hook activation.

## Gated tags

| Tag | Command | Current network rule |
|---:|---|---|
| 0 | `SetGameSpeed` | reject unless authorized |
| 1 | `SetCalendarSpeed` | reject unless authorized |
| 2 | `UpdateLogo` | reject unless authorized |
| 3–5 | `CreateLine`, `DeleteLine`, `UpdateLine` | reject unless authorized |
| 6–14 | vehicle assignment/control/buy/sell/replace commands | reject unless authorized |
| 16 | `RemoveField` | reject unless authorized |
| 25 | `ReplaceTerrain` | reject unless authorized |
| 26 | `SetDate` | reject unless authorized |
| 28–30 | `SetColor`, `SetName`, `SetVehicleManualDeparture` | reject unless authorized |
| 33 | `SetNoCosts` | reject unless authorized |
| 36 | `Debug_SetSimPersonState` | reject unless authorized |

`BuildProposal` remains on its dedicated tag-15 visitor because it already has payload capture and one canonical road/track replay slice. `Book` and `SendScriptEvent` remain available to the mod's finance and UI/engine bridge. Save commands remain local. Autonomous town/industry commands are not claimed by this gate; they still require the separate own-or-freeze programme.

## Lua/native control surface

- `tpf2mp_native_enable_command_gate()` enables all 23 visitors and clears stale tokens.
- `tpf2mp_native_authorize_command(tag)` adds one bounded token for one gated tag.
- `tpf2mp_native_disable_command_gate()` disables the gate and clears tokens.

The mod enables both the BuildProposal gate and this command gate when network mode starts. It then requires an active hook, valid exact-build status, the BuildProposal visitor, exactly 23 selected visitors, both gates enabled, and zero visitor/tag mismatches. Any failed condition marks network authority unready and refuses both outgoing and incoming gameplay traffic. A mismatch observed while gated is suppressed without consuming its authorization token. Manual authorization through the mod is prohibited in network mode. Raw DLL APIs are diagnostic primitives, not hostile-client security; peer authentication remains future work.

## Automated and live evidence

The offline suite verifies that both gate families are enabled on network startup and that a missing command gate prevents a gameplay intent from reaching the bridge.

Post-hardening live run `runtime/supported-api-probe/20260802-075034` exercised tag 0 in a disposable Build 35924 world:

- unauthorized `SetGameSpeed`: callback `success=false`;
- one tag-0 authorization: callback `success=true`;
- final counters: hooked `23`, allowed `1`, suppressed `1`, pending `0`, tag mismatches `0`;
- command conservation: queued `4,261`, applied `4,261`;
- game stopped and temporary base resources removed.

Full run `runtime/live-validation/20260802-075533` then passed all 39 in-game checks at tick 376 with hook `0.7.0`. It observed `12,886` queued commands and `12,912` applies, including 26 direct applies, with zero invalid layouts, unknown tags, pending overwrites, apply mismatches, or authority-visitor tag mismatches. Three selected visitors ran transparently while the standalone gate was disabled.

## Remaining boundary

The visitors provide pre-mutation denial and future one-shot release points. Each category still needs its own canonical codec, peer/company authorization, dependency translation, native materializer, result binding, finance treatment, and two-peer postcondition consensus before it can be enabled as gameplay. Unknown or autonomous mutation paths also need explicit analysis; 23 hooks are a fail-closed MVP set, not proof that every native world mutation is controlled.
