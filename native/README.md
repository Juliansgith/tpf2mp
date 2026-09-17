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
requires 19 unique code signatures at their pinned locations, verifies the
same bytes in memory, and checks 31 selected entries in the 37-command visitor
table before MinHook is initialized. A mismatch produces a `rejected` status
and no game hook is enabled.

## What is implemented

The DLL observes the high-level command-interface setup routine, `lua_setfield`
binding registration, Lua's base `print` function, `CommandList::Swap`,
`ApplyCommand`, `make_cmd::BuildProposal`, `CommandList::Add`, the tag-15
`BuildProposal` visitor, and 23 additional
consequential-command visitors plus eight autonomous town/industry visitors.
When sol2 registers
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
record direct applies which bypass `CommandList::Swap`. Hook 0.20.0 retains this
accounting path and adds pinned scalar capture for suppressed SetLine,
BuyVehicle, lifecycle controls, and ReplaceVehicle plus a complete bounded
SellVehicle vector before mutation. Reference run
`runtime/live-validation/20260802-075533` passed
all 39 checks, registered one
GUI pre-issue observer state, and closed the queue/apply/direct conservation
equation with zero unknown tags/applies, invalid layouts, pending overwrites,
queue/apply mismatches, or authority-visitor mismatches.

The print observer raw-registers diagnostic functions in each observed Lua
global table, bypassing Transport Fever 2's guard against ordinary creation of
globals:

- `tpf2mp_native_status()` returns the current JSON status string;
- `tpf2mp_native_bridge_configure(root, outSeq, inSeq)` binds a process-owned
  bounded transport to a child of `%TEMP%\tpf2mp_bridge` and returns the first
  immutable output sequence available;
- `tpf2mp_native_bridge_emit(seq, bytes)` enqueues one already-signed envelope
  without performing file I/O on the Lua/simulation thread;
- `tpf2mp_native_bridge_take()` returns the next inbound envelope already read
  by the native worker, preserving exact sequence order;
- `tpf2mp_native_bridge_status()` reports bounded queue depth, bytes,
  accepted/written/read/taken/rejected counters, and the last transport error;
- `tpf2mp_native_monotonic_us()` exposes the process monotonic performance clock
  used only for local task timings;
- `tpf2mp_native_launcher_bootstrap_ready()` returns `ready` only when the
  process-specific launcher barrier contains that exact value, using native
  filesystem I/O so Build 35924's Lua file cache cannot stale the handoff;
- `tpf2mp_native_mark_context(name)` labels that Lua state for diagnostics.
- `tpf2mp_native_enable_build_gate()` suppresses BuildProposal visitors by default;
- `tpf2mp_native_authorize_build()` authorizes exactly one visitor while gated;
- `tpf2mp_native_disable_build_gate()` disables the gate and clears authorizations.
- `tpf2mp_native_arm_build_correlation(token)` arms the generation-bound GUI
  preview token that the next suppressed visitor must carry. Token `0` disarms;
- `tpf2mp_native_take_suppressed_build()` consumes the oldest pointer-free
  `S1|generation|correlation|tag` event. Its 64-entry FIFO faults with a sticky
  `F1` record and discards the ambiguous prefix on overflow;
- `tpf2mp_native_take_build_factory_capture()` returns the oldest bounded,
  pointer-free proposal captured at the named factory or synchronously at the
  pre-queue `CommandList::Add` fallback, and whose exact command-data pointer
  reached the suppressed tag-15 visitor;
- `tpf2mp_native_build_gate_sample()` returns the versioned constant-size
  `B3|enabled|suppressed|tagMismatches|lastGeneration|queued|dropped|armedCorrelation|factoryReady|factoryDropped`
  sample used by render-cadence proposal capture without serializing complete
  hook history;
- `tpf2mp_native_enable_command_gate()` enables rejection for 31 selected tags;
- `tpf2mp_native_authorize_command(tag)` authorizes one matching visitor;
- `tpf2mp_native_revoke_command(tag)` withdraws one unused authorization after
  a Lua submission failure, preventing a later vanilla command from inheriting
  the token;
- `tpf2mp_native_disable_command_gate()` disables that gate and clears its tokens;
- `tpf2mp_native_take_suppressed_game_speed()` consumes the oldest valid normal
  UI speed request captured while the tag-0 gate suppressed it;
- `tpf2mp_native_take_suppressed_line_command()` consumes the oldest typed
  CreateLine/DeleteLine/UpdateLine/SetColor/SetName payload captured while tags
  3-5/28-29 are suppressed. The returned `L3` envelope contains no native
  pointers;
- `tpf2mp_native_take_suppressed_vehicle_command()` consumes the oldest
  pre-mutation vehicle envelope. Scalar tags 6-11, 13-14, and 30 use `V2` and
  contain only bounded vehicle, line, boolean, basis-point, player, or depot
  values. No `TransportVehicleConfig` pointer or native model ID crosses this
  boundary: Lua correlates BuyVehicle and ReplaceVehicle with the bounded stock
  GUI consist by FIFO and treats the visitor identities as authoritative. Tag
  12 uses `V3`, validates and copies every member of a 1-256 target native
  vector, and rejects negatives, duplicates, malformed lists, count mismatch,
  or truncation before mutation. Lua maps one target to the legacy sale and a
  larger selection to one canonical schema-4 batch. V1 is accepted only for
  old tag-6/tag-13 envelopes;
- `tpf2mp_native_set_command_observer(callback)` roots an opt-in no-throw Lua
  callback in that exact state and invokes it with the original command before
  `api.cmd.sendCommand` calls through.

The same status is atomically written to
`%TEMP%\tpf2mp_native\status-<pid>.json`. `latest.json` is only a convenience;
the PID-specific file is authoritative when multiple game instances exist.
Status publication is coalesced to at most four writes per second. The bridge
worker wakes every 10 ms, processes at most 32 outputs and 32 inputs per pass,
and is bounded to 4,096 messages, 64 MiB queued, and 8 MiB per message. It
transports opaque UTF-8 only and never touches engine entities, GUI objects,
Lua state, or commands from the worker thread.
The exact visitor set, disassembly boundary, and live suppress/authorize proof
are documented in
`investigation/CONSEQUENTIAL_COMMAND_GATES_BUILD35924_2026-08-02.md`.

## Important boundary

This DLL is a proven universal apply observer, a payload-aware pre-mutation
gate for `BuildProposal`, and a fail-closed pre-mutation gate for 31 selected
consequential and autonomous tags. It observes native C++ and Lua-issued command paths even
when a command bypasses the queued list. It also supplies the same-state Lua
pre-issue callback and one-shot authorization used by the mod.

Tags 17 through 24 close the pinned native CreateTowns, RemoveTown,
DevelopTown, SetTownInfo, InstantlyUpdateTownCargoNeeds,
ConnectTownsAndIndustries, SetSimBuildingManualDevelopment, and
SetSimBuildingClosureTimeStamp surface. The authored runtime consumes exact
one-shot tokens only for DevelopTown (19), SetTownInfo (20), and manual industry
development (23). The other five have no gameplay authorization path. A helper
revokes an unused token if Lua command submission throws before reaching the
visitor, so an unrelated later command cannot inherit it.

The DLL now decodes a bounded, pointer-free geometric/topological proposal at
`make_cmd::BuildProposal` entry, before queueing or simulation mutation. A
stock path that bypasses this named factory is decoded synchronously from the
tag-15 command data at `CommandList::Add`, still before the original Add can
queue it. It captures nodes, edges/tangents, carrier/resource and ownership scalars,
removals, edge-object entity lists, frozen indices, segment tags, construction
resource names/transforms, and caller/thread evidence. Factory options are
attested on the factory branch and explicitly marked unavailable on the Add
fallback. The
same native command must then pass `CommandList::Add` and the suppressed
visitor correlation before Lua can consume it. Construction parameter trees,
edge-object model semantics, quoted cost, and remaining terrain/alignment
semantics still come from the correlated bounded GUI projection; they are not
claimed as independently native-decoded fields. Segment tags are sparse native
metadata and are not required to have one entry per added edge. Likewise, an
edge-object record scalar is not treated as a portable temporary identity. An
explicitly invalid optional decode may fall back to the exact GUI payload only
while retaining the same factory/Add/visitor correlation and generation;
malformed identity or FIFO loss still fails closed.

Unreleased development implements road/track/node plus named edge-object codec
schema 6 and portable construction codec schema 8, canonical translation,
GUI-state reconstruction, geometric/compound output binding, unique-only
topology fallback, supported private-ownership correction, peer-local company
mapping, and two-peer physical completion plus canonical-account checkpoint
consensus in Lua/Python above this layer. The combined stack passed a one-machine canonical
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

Simultaneous construction remains deliberately bounded rather than universal:
supported vanilla-UI capture has been exercised across localhost and physical
two-computer relay sessions, while opaque/script-heavy proposal categories
remain unavailable. A commit acknowledgement is
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
- capturing native BuildProposal topology at factory entry or the pre-queue
  Add fallback and correlating it with the suppressed visitor and GUI semantic
  preview;
- observing all queued and direct native command applies by exact tag;
- suppressing or one-shot-authorizing a disposable BuildProposal before mutation;
- suppressing or tag-authorizing selected speed, line, vehicle, terrain, date,
  naming, cheat/debug, and autonomous town/industry commands through their
  ordinary engine completion path;
- safely exposing suppressed vanilla pause/speed requests to the shared clock;
- safely exposing suppressed vanilla line-manager create/update/delete/name/color requests
  to the canonical operation protocol;
- feeding exact live capability evidence to the Lua research UI;
- enforcing the pre-mutation boundary used by the canonical road/track replay
  slice.

It does not make every possible network construction authoritative by itself.
The earlier factory-negative probe was corrected: `api.cmd.make.*` factories
are callable tables in Build 35924, and documented road and track proposals
succeeded. The mod now supplies remote/canonical reconstruction for the bounded
schema-6/schema-8 slice, fail-closed all-peer completion consensus, and
checksummed restart planning from the latest agreed checkpoint. Hybrid
native/GUI capture, two-computer relay use, and automatic paired save recovery
are implemented; multi-hour certification and arbitrary scripted-content
compatibility remain open.

## Terrain fast paths (on by default, bit-identical)

`native_terrain_fast.cpp` carries three bit-identical replacements for stock
terrain routines that dominate the terrain phase of a save or world load,
ported from silver2127's tpf2-bigmap plugin (MIT; see
`third_party/tpf2-bigmap/TPF2MP_PIN.txt`):

- `align`: `terrain_alignment_util::CalculateHeightMod` (RVA `0x3b3470`)
  with pooled rasterisation targets and an SSE2 blend; the stock rasteriser
  still draws every triangle;
- `refine`: `sub_terrain_util::InternBicubicRefine` (RVA `0x3ac6c0`) with
  per-call constants and a four-wide Hermite evaluation in the stock operation
  order;
- `minmax`: an SSE2 replacement for the inlined `CalcMinMaxHeight` scan
  inside terrain publication (69 bytes at RVA `0x33cec1`) plus a per-row
  `memcpy` for the uint16 height block copy (RVA `0x30a540`);
- `material` (`native_material_fast.cpp`): the `MaterialIndexManager` pixel
  selection (RVA `0x315f20`) visited pixel-major instead of once per batch of
  eight layers, with the same overlap, precedence, sentinel and interpolation
  order.

All four paths are active whenever the hook arms.
`TPF2MP_NATIVE_TERRAIN_FAST` in the game process's environment changes that:
`off` (or `stock`) restores the stock code, a comma-separated subset of
`align`, `refine`, `minmax`, `material` selects paths, and `timing` adds
per-call wall-clock accounting to the status JSON (`stock,timing` measures
the originals through pass-through detours). Whether `material` is part of
the default is `kMaterialDefaultOn` in `native_terrain_fast.hpp`.
The launcher and injector pass the environment through. Every site is
byte-verified first (prologues, whole function bodies, constants and both
predicate vtables). A mismatch, an unparseable request, or a hook failure
leaves that fast path off and records the reason; the rest of the hook arms
normally. The status JSON reports the outcome under `hooks.terrainFast`.

Because the outputs are identical bytes, the two peers may run different
settings without diverging, and nothing here enters a digest. The hook
version stays `0.20.0`: the Lua/PowerShell contract is unchanged, as with the
0.44.3 capture optimisation. Two proofs back the claim: CTest compares the
SSE2 paths with scalar transcriptions and checks the installer's refusals
against a fake host, and `tests\native_terrain_fast\` maps the pinned
executable inside a Python process, runs the original routines as machine
code beside the DLL's replacements, and compares complete output buffers
(thousands of cases, three rounding modes). The in-game measurement that
justified the default is in
`investigation/TERRAIN_LOAD_FAST_PATHS_2026-09-17.md`; rerun it with
`tools\run_native_save_benchmark.ps1 -NativeHookDll` after touching these
paths.

## Remote build previews (on by default)

`native_preview_render.cpp` draws the other player's unconfirmed build with
the game's own builder ghost instead of a flat ground ribbon, so the remote
preview carries stock materials, bridges, tunnels and terrain deformation. It
is a port of silver2127's tpf2-multiplayer preview plugin (MIT; see
`third_party/tpf2-multiplayer/TPF2MP_PIN.txt`).

The receiving GUI Lua state rebuilds the remote geometry as a `SimpleProposal`
with negative temporary entity ids and calls
`api.cmd.make.buildProposal(sp, nil, false)` **only** so that the engine runs
`scripting::Convert`. The command is never sent: this module has no
command-dispatch or `applyProposal` path, and the Lua side must never call
`api.cmd.sendCommand` for a preview. The `Convert` detour, on the GUI thread,
consumes the request armed from Lua, bounds the converted proposal, builds
`ProposalData` with the engine's `CreateProposalData` and uploads it with
`AddToRenderer` into a per-origin `BuilderRenderer` minted from the game's
cloned renderer factory. That renderer carries a copied vtable whose render
passes are gated, so stale geometry disappears after four seconds even if Lua
stops polling. Shared UI terrain height buffers are recomposed after every
change with the local builder uploaded last, so one's own tool keeps priority
where areas overlap. Scene destruction removes and destroys every preview
renderer and the retained factory before the stock destructor runs.

Three globals are registered into every Lua state the hook reaches:

- `tpf2mp_native_preview_status()` returns
  `{ available, reason, session, peers, drawn }`; `session` changes when a new
  scene is adopted and is `0` without one.
- `tpf2mp_native_preview_begin(origin, mode)` returns a boolean. `origin`
  matches `^[a-z0-9]{1,8}$`; `mode` is `draw`, `drawok`, `drawbad`, `keep` or
  `clear`. `keep` (refresh that origin's timestamp; refused once its preview
  expired, so Lua resends the geometry) and `clear` (drop that origin's
  renderer content) run immediately on the GUI thread. The three draw modes
  arm a one-shot request for the next conversion; an unconsumed request
  expires after two seconds and a new `begin` replaces a still-armed one.
- `tpf2mp_native_preview_result()` returns `ok`, `error`, `pending` or `idle`
  for the last armed draw request; a terminal result is reported once.

`draw` and `drawok` upload the renderer's stock palette and leave the
receiver's own evaluation alone, so an accepted remote preview is
indistinguishable from the local builder ghost. Only `drawbad` selects the
stock error palette and the renderer-wide error flag that the terrain overlay
bakes, which is what the sender is seeing.

Input from the network is bounded before anything is evaluated: at most one
construction with a plausible `.con` path and transform, 48 nodes and 24 edges
(384/192 with a construction), negative entity ids only, empty removal and
edge-object vectors, and finite, non-degenerate vectors.

`TPF2MP_NATIVE_PREVIEW=off` (also `0`, `false`, `none`, `stock`) skips
installation; `nolua` installs the seven detours but registers no Lua globals,
which bisects a live problem between the passive detours and the Lua entry
points; anything unparsable fails closed. Every pinned region is byte-verified
first and the builder-renderer vtable must still start with the pinned
destructor; a mismatch or a hook failure leaves previews off, keeps all seven
detours inert, and records the reason while the rest of the hook arms
normally. The status JSON reports `hooks.preview` with `enabled`, `installed`,
`reason`, `peers`, `drawn`, `requests`, `errors`, `session` and `trace`.

Idle cost is deliberately near zero, because these detours sit on paths the
game uses constantly. Until a peer renderer has been minted in the current
scene, `BuilderRenderer::Clear`, `EndHeightMod` and the renderer destructor
forward the call and return without touching any shared state; a conversion
the game makes for its own reasons costs one atomic load in the `Convert`
detour; and the swapped vtable is only ever written onto a preview renderer
(its original vtable is kept and restored before that renderer is destroyed).
A render pass that somehow reaches a renderer this module does not know is
drawn normally through the stock slot rather than dropped. The list of local
height renderers has its own lock, is capped at 64 entries, and no engine call
is made while that lock is held.

Locks in this module are `SRWLOCK`, like the rest of the injected code. The
game ships `msvcp140.dll` 14.14 (VS 2017) beside its executable and that copy
is loaded first, so the hook binds to it; a `std::mutex` built with a current
toolset is constexpr-constructed and expects the runtime to finish
initialising it at the first lock, which 14.14 cannot do. It dereferences the
null pointer inside: the process dies with an access violation reading
address 0. `tools\check_source_boundaries.ps1` fails any `#include <mutex>`
under `native\src`.

`hooks.preview.trace` is a bounded in-process event log (the last 48 entries,
oldest first, each with a tick and the thread that recorded it). It records
install decisions, the factory clone, scene adoption with the GUI thread id,
Lua registration, the first entry and the first return of each Lua call, the
first consumed conversion, request expiry, keep/clear, peer minting and scene
disposal. Each site fires once, so a per-frame Lua poll cannot flood the ring,
and a new event asks the hook to rewrite its status file. A live stall can be
located by reading which of those events is missing.

Pinned Build 35924 entry points (the first seven are hooked, the rest are
called, and all of them are prologue-verified):

| Entry | RVA |
|---|---|
| Renderer factory | `859240` |
| `Scene::AddRenderable` | `6d32e0` |
| Scene destructor body | `6d22d0` |
| `scripting::Convert` | `20e72f0` |
| `BuilderRenderer::Clear` | `817f70` |
| `EndHeightMod` | `8191d0` |
| Renderer destructor body | `814b20` |
| `Scene::RemoveRenderable` | `6d9290` |
| Renderer deleting destructor | `8163c0` |
| Convert context / its destructor | `431560` / `3e3d30` |
| `CreateProposalData` / its destructor | `a072b0` / `3e5030` |
| `AddToRenderer` | `48d8e0` |
| Upload / reset UI terrain heights | `34cd90` / `34e5a0` |
| Error-colour setter | `81df00` |
| `luaB_load` | `75890` |
| Builder-renderer vtable | `30665e0` |

`luaB_load` is read out of the base library's `luaL_Reg` table beside the
pinned `luaB_print`: the Lua C API the hook resolves has no table or boolean
push, so the two calls that must return one build it from a short chunk that
uses no globals and no string-to-number coercion. Factory and scene adoption
also compare the caller's return address with `445897` (CGameUI construction)
and `56a532` (the main scene) to pick exactly one factory and one scene.

`ctest` runs `preview_render_contracts`, which exercises request parsing, the
installer's refusals, the proposal guard, the request state machine with its
expiry, the per-mode palette policy and the shared terrain composition against
fake renderer memory and stub engine routines.
`tools\build_native_hook.ps1` additionally runs that binary with the game
executable, which maps and relocates the pinned image and runs the real
installer against it, comparing every pinned prologue with shipped code.
Native rendering itself still needs a live two-player check.

## Build and verify

From the project root in PowerShell:

```powershell
.\tools\build_native_hook.ps1
```

This configures CMake, builds Release binaries, runs CTest (including a DLL
load into an unpinned helper process which must reject safely), verifies the
installed game executable and every unique signature, and runs the terrain
fast-path proof against that executable (`tools\verify_native_terrain_fast.ps1`;
needs numpy, capstone and pefile in the gate's Python, or pass
`-SkipTerrainFastProof`). Outputs are below `runtime\native-build\Release`.

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

To exercise the complete early-capture chain with a physical vanilla signal
tool click in an unsaved disposable world:

```powershell
.\tools\run_supported_api_build_probe.ps1 -NativeHook -SkipNativeBuild -NativeFactoryGuiCaptureTest
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
- `src/native_binding_catalog.cpp`: the bounded Lua command-binding names and
  stable registry-slot mapping used by deferred native mirrors.
- `src/injector.cpp`: exact-profile verification and remote `LoadLibraryW`.
- `src/hook_dll.cpp`: fail-closed Lua/command hooks, timelines, mirrors,
  BuildProposal gate, and 31-tag consequential/autonomy command gate.
- `src/native_build_capture.cpp`: bounded Build 35924 proposal-layout decoder.
- `src/native_build_hook_bridge.cpp`: factory-or-Add/visitor correlation queue.
- `include/tpf2mp/native_command_safety.generated.hpp`: generated 37-tag
  suppression, UI-result, replay, ownership, cost, and postcondition policy.
- `src/native_preview_render.cpp` / `src/native_preview_render_hooks.cpp`:
  the remote builder-ghost preview renderer service and its MinHook glue.
- `tests/`: profile and fail-closed-load tests.
- `third_party/tpf2-multiplayer`: upstream MIT license and the port mapping
  for the preview renderer.
- `third_party/minhook`: official MinHook v1.3.4 at commit
  `c3fcafdc10146beb5919319d0683e44e3c30d537`, BSD-2-Clause.

Lua ABI assumptions are pinned to the embedded Lua 5.2.2 implementation and
validated through the executable signatures; they are not claimed for another
Transport Fever 2 build.
