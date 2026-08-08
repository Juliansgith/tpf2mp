# Build 35924 native hook

This directory contains the first pinned native authority component for the
TPF2MP research prototype. It is an x64 Windows DLL plus a fail-closed
injector. It supports exactly the locally installed Transport Fever 2 Build
35924 executable:

- SHA-256: `782b904a8f7bbdac1f7a18528f1a5c778691e5aa3087c37c351bf6912585175c`
- PE timestamp: `0x675ABCC6`
- image size: `0x046CE000`
- machine: `AMD64`

The injector and DLL both validate that complete profile. The DLL additionally
requires 17 unique code signatures at their pinned locations, verifies the
same bytes in memory, and checks 23 selected entries in the 37-command visitor
table before MinHook is initialized. A mismatch produces a `rejected` status
and no game hook is enabled.

## What is implemented

The DLL observes the high-level command-interface setup routine, `lua_setfield`
binding registration, Lua's base `print` function, `CommandList::Swap`,
`ApplyCommand`, the tag-15 `BuildProposal` visitor, and 23 additional
consequential-command visitors. When sol2 registers
`api.cmd.sendCommand`, the DLL preserves the original closure without modifying
it. After the complete command-interface setup routine returns on the same Lua
thread, it installs a Lua C closure which:

1. records the call, argument count, Lua state, and thread;
2. invokes an optional callback registered in that exact Lua state's registry
   with the original command argument before issue;
3. moves the preserved original closure below the unchanged arguments;
4. calls the original with `LUA_MULTRET`;
5. returns exactly the original result stack.

Deferring replacement is required. Replacing the sol2 closure while its table
was still under construction produced a repeatable Lua panic; the live probe
captures that investigation history. The completed setup also mirrors the
callable command bindings into `tpf2mp_native_binding_<name>` globals in that
same state. Public Build 35924 command factories are callable Lua tables, so the
mod prefers `api.cmd.make.*` and uses the mirror only as a same-state fallback.

The native command observers decode the `Command`/variant discriminator,
classify all 37 tags, pair queued commands with their `ApplyCommand` result, and
  record direct applies which bypass `CommandList::Swap`. Hook 0.14.0 retains this
  accounting path and adds pinned scalar capture for suppressed SetLine,
  BuyVehicle, lifecycle controls, and ReplaceVehicle before mutation. Reference
  run `runtime/live-validation/20260802-075533` passed
all 39 checks, registered one
GUI pre-issue observer state, and closed the queue/apply/direct conservation
equation with zero unknown tags/applies, invalid layouts, pending overwrites,
queue/apply mismatches, or authority-visitor mismatches.

The print observer raw-registers diagnostic functions in each observed Lua
global table, bypassing Transport Fever 2's guard against ordinary creation of
globals:

- `tpf2mp_native_status()` returns the current JSON status string;
- `tpf2mp_native_launcher_bootstrap_ready()` returns `ready` only when the
  process-specific launcher barrier contains that exact value, using native
  filesystem I/O so Build 35924's Lua file cache cannot stale the handoff;
- `tpf2mp_native_mark_context(name)` labels that Lua state for diagnostics.
- `tpf2mp_native_enable_build_gate()` suppresses BuildProposal visitors by default;
- `tpf2mp_native_authorize_build()` authorizes exactly one visitor while gated;
- `tpf2mp_native_disable_build_gate()` disables the gate and clears authorizations.
- `tpf2mp_native_enable_command_gate()` enables rejection for 23 selected tags;
- `tpf2mp_native_authorize_command(tag)` authorizes one matching visitor;
- `tpf2mp_native_disable_command_gate()` disables that gate and clears its tokens;
- `tpf2mp_native_take_suppressed_game_speed()` consumes the oldest valid normal
  UI speed request captured while the tag-0 gate suppressed it;
- `tpf2mp_native_take_suppressed_line_command()` consumes the oldest typed
  CreateLine/DeleteLine/UpdateLine/SetColor/SetName payload captured while tags
  3-5/28-29 are suppressed. The returned `L3` envelope contains no native
  pointers;
- `tpf2mp_native_take_suppressed_vehicle_command()` consumes the oldest
  pre-mutation `V2` envelope. Tags 6-11 and 30 contain only bounded vehicle,
  line, boolean, or basis-point scalars. Tag 13 contains native-player/depot;
  tag 14 contains the replacement target. No `TransportVehicleConfig` pointer
  or native model ID crosses this boundary: Lua correlates BuyVehicle and
  ReplaceVehicle with the bounded stock GUI consist by FIFO and treats the
  visitor identities as authoritative. Tag 12 validates a bounded native
  entity vector and carries first-target/selection-count; Lua admits count one
  and visibly blocks multi-selection before mutation. V1 is accepted only for
  old tag-6/tag-13 envelopes;
- `tpf2mp_native_set_command_observer(callback)` roots an opt-in no-throw Lua
  callback in that exact state and invokes it with the original command before
  `api.cmd.sendCommand` calls through.

The same status is atomically written to
`%TEMP%\tpf2mp_native\status-<pid>.json`. `latest.json` is only a convenience;
the PID-specific file is authoritative when multiple game instances exist.
The exact visitor set, disassembly boundary, and live suppress/authorize proof
are documented in
`investigation/CONSEQUENTIAL_COMMAND_GATES_BUILD35924_2026-08-02.md`.

## Important boundary

This DLL is a proven universal apply observer, a payload-aware pre-mutation
gate for `BuildProposal`, and a fail-closed pre-mutation gate for 23 selected
consequential tags. It observes native C++ and Lua-issued command paths even
when a command bypasses the queued list. It also supplies the same-state Lua
pre-issue callback and one-shot authorization used by the mod.

The DLL itself deliberately does not understand semantic proposal payloads.
Prototype 0.21 implements road/track/node plus named edge-object codec schema 5
and portable construction codec schema 7, canonical translation, GUI-state
reconstruction, geometric/compound output binding, supported private-ownership
correction, peer-local company mapping, and two-peer physical completion plus
canonical-account checkpoint consensus in Lua/Python above this layer. The
proposal carries the builder's quoted cost; state schema 19 treats native
wallets as reconciled peer-local caches while making shared-save pre-existing
ownership canonical rather than peer-local. Signal add/remove and the engine
primitives for depot/station/asset build, station edit, custody, and removal now
also have single-process live receipts; full ordinary-UI two-process coverage
is still the next authority gate. The
combined stack passed a one-machine canonical
electrified-track replay in `runtime/live-validation/20260802-075533` and a
bidirectional two-real-process localhost replay/checkpoint/600-tick-soak run in
`runtime/localhost-live/localhost-20260802-175636`.

The stronger populated proof is
`runtime/localhost-live/populated-network-ownershipfix-20260803`: two exact
processes loaded the same populated save, converged pre-existing ownership,
replayed one track transaction from each peer, and finished with identical
core/model/structure/mobility digests. Its final 300-tick validator soak was
paused and autonomy-frozen, so it does not establish running-simulation
lockstep. See
`investigation/POPULATED_NETWORK_RECOVERY_AND_MENU_2026-08-03.md`.

It is still not finished simultaneous construction multiplayer: the human
vanilla-UI capture path has not been proven between two computers, and
unsupported proposal categories have no codec. A commit acknowledgement is
provisional: the host blocks dependent work until both pinned peers report the
same canonical physical result, then emits an ordered success outcome or faults
the session closed. Success then opens an all-peer format-2 checkpoint barrier
before another intent may commit. That protocol now passes over real localhost
TCP and two live game processes. Most newly gated non-build commands have no
canonical payload/replay tier and therefore remain unavailable in network mode.
Tag-0 speed is one bounded exception: the hook captures the pinned int32 payload
at offset zero after suppression, and Lua submits it through the host-ordered
shared-clock protocol. Tags 3-5/28-29 are now the second: hook 0.12 copies the exact
Build 35924 line payload into a bounded native queue before suppression returns.
CreateLine contributes name, color, player, and its complete `Line`; UpdateLine
contributes target plus `Line`; DeleteLine contributes its target; SetName and
SetColor contribute a line target plus bounded value. Every stop retains
station-group, station, and terminal. The decoded payload is canonicalized
and replayed through the existing line-operation consensus. The focused
`runtime/localhost-live/line-manager-replay-20260804-1428` run proves
CreateLine/UpdateLine/DeleteLine from both player origins across two independent
processes with matching physical results and checkpoints. Later stock-widget
runs `vanilla-lines-final-v12-20260804` and
`vanilla-line-stops-v12-20260804` add visual create/rename/color/delete and
populated Add Station/remove-stop proof; all invalid/mismatch counters remained
zero.
Replay calls the bounded command-factory arities explicitly because Build
35924's global `unpack` throws on its engine-owned `Line`/`Vec3f` userdata.
Unlisted/autonomous mutation paths, ticks/RNG, and native passenger/cargo agents
remain separate authority gaps.

Accordingly, the hook is useful now for:

- proving command-interface and per-state capability anchors;
- observing mod-issued command calls without changing their semantics;
- capturing an original Lua `BuildProposal` envelope before issue when the mod
  opts into the callback;
- observing all queued and direct native command applies by exact tag;
- suppressing or one-shot-authorizing a disposable BuildProposal before mutation;
- suppressing or tag-authorizing selected speed, line, vehicle, terrain, date,
  naming, and cheat commands through their ordinary engine completion path;
- safely exposing suppressed vanilla pause/speed requests to the shared clock;
- safely exposing suppressed vanilla line-manager create/update/delete/name/color requests
  to the canonical operation protocol;
- feeding exact live capability evidence to the Lua research UI;
- enforcing the pre-mutation boundary used by the canonical road/track replay
  slice.

It does not make network construction authoritative by itself.
The earlier factory-negative probe was corrected: `api.cmd.make.*` factories
are callable tables in Build 35924, and documented road and track proposals
succeeded. The mod now supplies remote/canonical reconstruction for the bounded
schema-3 slice, fail-closed all-peer completion consensus, and checksummed
restart planning from the latest agreed checkpoint. Broad semantic capture,
two-computer human usability, and automatic save recovery remain open.

## Build and verify

From the project root in PowerShell:

```powershell
.\tools\build_native_hook.ps1
```

This configures CMake, builds Release binaries, runs CTest (including a DLL
load into an unpinned helper process which must reject safely), and verifies
the installed game executable and every unique signature. Outputs are below
`runtime\native-build\Release`.

To rerun the disposable-world live proof:

```powershell
.\tools\run_native_hook_probe.ps1 -SkipBuild
```

The probe launches through Steam, injects as soon as the real game process is
visible, creates only an unsaved disposable world, proves status registration
and command observation, captures evidence, stops that process, and removes its
verified temporary resources. It never loads an existing save.

To issue a real documented road proposal and then exercise the default-off
visitor gate:

```powershell
.\tools\run_supported_api_build_probe.ps1 -NativeHook -SkipNativeBuild
.\tools\run_supported_api_build_probe.ps1 -NativeHook -SkipNativeBuild -BuildGateTest
.\tools\run_supported_api_build_probe.ps1 -NativeHook -SkipNativeBuild -CommandGateTest
```

For a personal main-menu/manual test:

```powershell
.\tools\start_native_hook_test.ps1
.\tools\get_native_hook_status.ps1
```

Close other Steam games before launch. Use only a disposable Transport Fever 2
world while this component is experimental.

## Source and dependencies

- `include/tpf2mp/build_profile.hpp`: exact build/signature profile.
- `src/native_common.cpp`: PE, SHA-256, signature, and atomic-status support.
- `src/injector.cpp`: exact-profile verification and remote `LoadLibraryW`.
- `src/hook_dll.cpp`: fail-closed Lua/command hooks, timelines, mirrors, BuildProposal gate, and 23-tag consequential-command gate.
- `tests/`: profile and fail-closed-load tests.
- `third_party/minhook`: official MinHook v1.3.4 at commit
  `c3fcafdc10146beb5919319d0683e44e3c30d537`, BSD-2-Clause.

Lua ABI assumptions are pinned to the embedded Lua 5.2.2 implementation and
validated through the executable signatures; they are not claimed for another
Transport Fever 2 build.
