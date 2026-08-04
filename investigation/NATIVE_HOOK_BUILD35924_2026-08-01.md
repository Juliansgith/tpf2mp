# Native hook investigation — Build 35924 — 2026-08-01

## 2026-08-02 hook 0.7 authority update

Hook `0.7.0` supersedes the BuildProposal-only authority boundary described below. It additionally validates the exact 37-entry dispatch table and detours 23 pinned consequential-command visitors covering speed/calendar, line, vehicle, field/terrain, date, color/name, no-costs, and debug-person actions. The generic gate is default-off in standalone play, mandatory alongside the BuildProposal gate in network mode, and exposes one-shot per-tag authorization. Missing hooks, inactive gates, or visitor/tag mismatches make network authority unavailable.

Post-hardening run `runtime/supported-api-probe/20260802-075034` live-proved normal rejection and admission callbacks with tag 0: one unauthorized command returned `success=false`, one authorized retry returned `success=true`, and counters ended at 23 hooked, one suppressed, one allowed, zero pending, and zero mismatches. Full run `runtime/live-validation/20260802-075533` passed 39/39 with all new visitors transparent in standalone mode and zero authority mismatches. The exact table and selected tags are documented in [CONSEQUENTIAL_COMMAND_GATES_BUILD35924_2026-08-02.md](CONSEQUENTIAL_COMMAND_GATES_BUILD35924_2026-08-02.md).

The gates stop unsupported commands before mutation; they do not serialize or replicate them. Category-specific canonical codecs and replay remain the next implementation tier.

## Outcome

The repository now contains a working, fail-closed Windows x64 native layer for the exact local Transport Fever 2 Build 35924 executable. It proves stable observer and BuildProposal-gate tiers:

- executable/build validation before mutation;
- signature-scanned Lua and command-interface anchors;
- Lua-state and binding discovery;
- atomic PID-specific diagnostics callable from Lua;
- transparent, deferred wrapping of `api.cmd.sendCommand`;
- an opt-in same-state pre-issue Lua callback receiving the original command;
- same-state mirrors of callable command bindings;
- native queue and universal apply observation with a 37-tag map;
- a default-off pre-mutation `BuildProposal` gate with one-shot authorization;
- automated and live-game verification.

It is **not** yet network construction authority. It can stop `BuildProposal` before local mutation and observe every tested apply, including native C++ and direct engine-state paths. It does not yet decode/serialize proposal payloads, connect the gate to host commits, inject a host-approved command, capture/bind result slots, or gate the other command categories.

## Pinned executable profile

- Executable: `F:\SteamLibrary\steamapps\common\Transport Fever 2\TransportFever2.exe`
- Architecture: Windows x64
- Runtime build: `Build 35924 Windows 64-bit`
- File size: `72,843,280` bytes
- SHA-256: `782b904a8f7bbdac1f7a18528f1a5c778691e5aa3087c37c351bf6912585175c`
- PE timestamp: `0x675ABCC6`
- PE image size: `0x46CE000`

The injector validates the target before changing it. The DLL independently validates the loaded process again. Both require the complete hash/PE/architecture profile. The DLL then scans all 17 expected code signatures, requires exactly one match for every signature, verifies the expected bytes, and installs hooks at the scanned addresses—not at blindly trusted offsets. Any mismatch leaves the process unhooked and emits a loud error.

The signatures cover `SetupCommandInterface`; `CommandList::Swap`; `ApplyCommand`; the tag-15 `BuildProposal` visitor; and the Lua primitives required for safe observation/call-through. Expected RVAs remain in the profile as review metadata and test assertions.

## Implementation

The code is under `native/`:

- `tpf2mp_injector.exe` validates a running or explicitly launched target and loads only the pinned DLL;
- `tpf2mp_hook_build35924.dll` performs in-process validation, installs hooks, and writes status;
- `native_common` owns hashing, PE inspection, signature scanning, path handling, and atomic status writes;
- `native_tests` validates the exact game profile and failure cases;
- `dll_load_test` proves an unpinned host process is rejected safely;
- MinHook v1.3.4 is vendored at upstream tag commit `c3fcafdc10146beb5919319d0683e44e3c30d537` with its BSD-2-Clause license and an explicit pin file.

`SetupCommandInterface` is the high-level Lua anchor. During that binding routine, the `lua_setfield` observer sees `sendCommand` and the command constructors. It preserves the original sender, lets sol2 complete its assignments untouched, then installs the wrapper and same-state binding mirrors only after setup returns on the Lua-owning thread. The wrapper records count/argument-count/thread evidence, invokes an optional registry-rooted callback with the original command before issue, invokes the original closure with unchanged arguments, and returns all original results.

`CommandList::Swap` observes queued batches and `ApplyCommand` observes the common execution boundary. The pinned `Command` layout exposes a variant tag at `CommandData + 0xB18` and success at `Command + 0x30`. Queue/apply pairing, direct-apply accounting, tag histograms, and filtered timelines are written to native status. The tag-15 visitor can reject before mutation or consume one authorization and call the original. The full recovered layout and tag map are in [NATIVE_COMMAND_PIPELINE_BUILD35924_2026-08-01.md](NATIVE_COMMAND_PIPELINE_BUILD35924_2026-08-01.md).

The DLL also registers:

- `tpf2mp_native_status()` — returns current status JSON;
- `tpf2mp_native_set_command_observer(callback)` — installs a no-throw pre-issue callback in that exact Lua state;
- `tpf2mp_native_mark_context(name)` — labels a Lua state, used for engine/GUI evidence.
- `tpf2mp_native_enable_build_gate()` / `tpf2mp_native_disable_build_gate()` — default-off local gate controls;
- `tpf2mp_native_authorize_build()` — admits exactly one BuildProposal while gated.

Hook 0.7 additionally registers `tpf2mp_native_enable_command_gate()`, `tpf2mp_native_disable_command_gate()`, and `tpf2mp_native_authorize_command(tag)` for the selected visitors.

The mod compacts native status before persistence. Process IDs, pointers, and thread IDs remain local diagnostic evidence and do not enter network/checkpoint digests.

## Failures found while developing it

Three failures materially changed the design:

1. Replacing `sendCommand` inside the observed `lua_setfield` call caused a reproducible Lua panic while sol2 was still constructing/checking its binding. Preserving the original assignment and deferring replacement until the complete setup routine returned fixed the crash.
2. Registering diagnostics through normal global assignment triggered the game's explicit guard against creating globals by assignment. Raw global-table assignment/registry operations fixed it without disabling the guard.
3. The first BuildProposal visitor detour forwarded only RCX and crashed in `20260801-162841`. Per-function disassembly proved the real ABI is `bool(void* context, void* proposal)`, with the payload in RDX. Forwarding both arguments passed transparently in `20260801-163114` and under gating in `20260801-163359`.

Directly launching the executable also exits through Steam bootstrap behavior on this installation. The test launcher therefore starts app 1066780 through Steam, watches for the exact new game process, then attaches immediately. It never attaches to an already-running unrelated process.

## Live evidence

### Corrected command and gate proofs

The earlier `20260801-150839` run proved the wrapper but incorrectly classified callable command tables as absent. Corrected runs prove:

- `20260801-161030`: public and native-mirrored `buildProposal` and `sendScriptEvent` are callable tables;
- `20260801-162057`: a documented road BuildProposal succeeded and appeared as tag 15;
- `20260801-163114`: the corrected two-argument visitor detour passed transparently;
- `20260801-163359`: one proposal was suppressed, two one-shot-authorized proposals entered the original visitor, and the final one succeeded;
- final gate counters were `suppressed=1`, `allowed=2`, with tag-15 callback outcomes `false, false, true` and no mismatches or leaks.

### Full mod integration

The earlier queue/gate baseline `runtime/live-validation/20260801-164040` passed:

- all 30 in-game checks at tick 270;
- core/model/structural digests `ef1598bf` / `7eee0ab0` / `1be6e32a`;
- all 17 signatures unique and all native hooks active;
- 40 Lua states observed, three wrapped and mirrored;
- 19 real mod commands forwarded, last call with one argument;
- engine and GUI states identified;
- 11,293 queued commands and 11,312 applies, with the 19-command difference classified as direct engine-state applies;
- zero invalid command layouts, unknown tags, pending overwrites, pending commands, or queue/apply tag mismatches;
- corrected GUI/engine capability matrices recognize the callable command tables;
- checkpoint replay and cleanup passed;
- source and installed mod trees matched exactly.

The hook-enabled result matches the earlier unhooked guarded baseline. That is strong evidence for transparent behavior over the tested path, not a blanket proof for every game command.

Hook 0.6.0 run `runtime/live-validation/20260801-183544` then passed the same 30 checks with one GUI observer state registered, 21 wrapped calls, 10,721 queued commands, 10,695 completed applies, 47 pending queue entries at capture, and 21 direct applies. The conservation equation closed exactly and every layout/tag/mismatch counter remained zero. Capability-only run `runtime/supported-api-probe/20260801-183428` independently proved the new registration API callable in a live Build 35924 Lua state.

## Reproduce

Build, profile-check, and run native tests:

```powershell
.\tools\build_native_hook.ps1
```

Run the isolated disposable proof:

```powershell
.\tools\run_native_hook_probe.ps1 -SkipBuild
```

Run a real road proposal and then the pre-mutation gate test:

```powershell
.\tools\run_supported_api_build_probe.ps1 -NativeHook -SkipNativeBuild
.\tools\run_supported_api_build_probe.ps1 -NativeHook -SkipNativeBuild -BuildGateTest
.\tools\run_supported_api_build_probe.ps1 -NativeHook -SkipNativeBuild -CommandGateTest
```

Run the complete disposable validator:

```powershell
.\tools\run_unattended_live_validation.ps1 -NativeHook -SkipNativeBuild
```

Start a manual disposable-world session:

```powershell
.\tools\start_native_hook_test.ps1 -NoBuild
.\tools\get_native_hook_status.ps1
```

Transport Fever 2 must be closed first. Steam must be logged in and available to launch this game. Do not open a valued save for native-hook experiments.

## Precise next target

The queue/apply/BuildProposal gate has been identified and live-proven. The next tier must prove, in order:

1. normalized tag-15 payload observation without pointers/local IDs;
2. host acceptance/rejection round trip while the local action remains suppressed;
3. accepted-command construction/injection on both instances;
4. callback/result capture;
5. deterministic output-slot-to-local-entity binding and postcondition comparison;
6. equivalent visitor gates and payload handling for the remaining MVP command tags.

Only after that slice passes should tick coordination, RNG scoping, save-serializer integration, or passenger/cargo mutation be promoted from conditional research to implementation work.

## Primary references

- [Transport Fever 2 `api.cmd` reference](https://wiki.transportfever2.com/api/modules/api.cmd.html)
- [Transport Fever 2 engine systems reference](https://wiki.transportfever2.com/api/modules/api.engine.html)
- [Lua 5.2 reference manual](https://www.lua.org/manual/5.2/manual.html)
- [Lua 5.2 source](https://www.lua.org/source/5.2/)
- [MinHook upstream repository](https://github.com/TsudaKageyu/minhook)
- [MinHook license](https://github.com/TsudaKageyu/minhook/blob/master/LICENSE.txt)
