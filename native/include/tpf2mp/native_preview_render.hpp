#pragma once

// The other player's unconfirmed build, drawn by the game's own builder ghost.
//
// Ported from silver2127's tpf2-multiplayer preview plugin (MIT; see
// native/third_party/tpf2-multiplayer/TPF2MP_PIN.txt and
// docs/THIRD_PARTY_NOTICES.md). Instead of flat ground ribbons, the receiving
// client rebuilds the remote proposal in a private native BuilderRenderer, so
// the remote preview carries the stock materials, bridges, tunnels and terrain
// deformation of the vanilla preview.
//
// How it works. The receiving GUI Lua state rebuilds a SimpleProposal with
// negative temporary entity ids and calls api.cmd.make.buildProposal(sp, nil,
// false) purely so the engine runs scripting::Convert; the command itself is
// never sent (see the Lua contract at the bottom of this header). The DLL
// hooks Convert on the GUI thread, sees the request this module armed, builds
// ProposalData with the engine's own CreateProposalData and uploads it with
// AddToRenderer into a per-peer BuilderRenderer minted from the game's cloned
// renderer factory. The peer renderer carries a swapped vtable that gates its
// render passes, the global UI terrain height buffers are recomposed with the
// local builder last (so one's own tool keeps priority where areas overlap),
// peers expire after four seconds, and scene destruction removes and destroys
// everything before the stock destructor runs.
//
// Seven prologue-verified inline hooks (Build 35924): the renderer factory,
// Scene::AddRenderable, the scene destructor, scripting::Convert,
// BuilderRenderer::Clear, EndHeightMod and the renderer destructor. Every
// other pinned entry point this module calls is prologue-verified too.
// TPF2MP_NATIVE_PREVIEW=off skips installation; the default is on. A byte
// mismatch or a hook failure leaves previews off while the rest of the hook
// arms normally, exactly like the terrain fast paths.
//
// Appearance: draw and drawok use the renderer's stock palette and the
// receiver's own evaluation, so an accepted remote preview is
// indistinguishable from the local builder ghost. Only drawbad forces the
// stock error (red) palette, which is what the sender is seeing.

#include <Windows.h>

#include <cstddef>
#include <cstdint>
#include <string>
#include <string_view>
#include <vector>

struct lua_State;

namespace tpf2mp::preview_render {

// ---------------------------------------------------------------- host seam
// The services the installer needs, as plain C function pointers with a
// context, so the same installer runs against the live game (MinHook, native
// memory) and inside tests (a mapped image and fake hooks). Returns are int
// for ABI stability: non-zero means success.
struct Host {
  void* context{};
  std::uintptr_t (*module_base)(void* context){};
  int (*verify_bytes)(void* context, std::uintptr_t rva, const std::uint8_t* expected,
                      std::size_t size){};
  int (*install_hook)(void* context, std::uintptr_t target, void* detour, void** original){};
};

struct Request {
  bool enabled{};
  bool lua{};  // register the Lua globals ("nolua" installs the detours only)
  std::string raw;
  std::string error;  // non-empty when the text was not understood; nothing is requested then
};

// Parses TPF2MP_NATIVE_PREVIEW. Empty (unset), "1", "on", "true" or "all"
// request the previews; "0", "off", "false", "none" or "stock" request none;
// "nolua" installs the detours but registers no Lua globals, which bisects a
// live problem between the passive detours and the Lua entry points.
// Unknown text fails closed: previews stay off and the error is recorded.
Request ParseRequest(std::wstring_view value);

struct Status {
  std::string requested;
  bool enabled{};    // installation was requested
  bool installed{};  // all seven detours are live
  std::string reason;  // why previews are unavailable; empty once installed
};

// Verifies every pinned byte region first, then installs the seven detours. A
// refusal never patches memory and never disturbs the rest of the hook.
Status Install(const Host& host, const Request& request);

// Defined in native_preview_render_hooks.cpp, which only the hook DLL links:
// reads TPF2MP_NATIVE_PREVIEW and installs through MinHook. Call after
// MH_Initialize; each hook it creates is enabled immediately, so a failure
// stays confined to the previews. `status_write_request`, when given, is
// called after a new trace event so the status file carries the event log
// while a live problem is being located; it must not block.
Status InstallFromEnvironment(HMODULE executable, void (*status_write_request)() = nullptr);

// Live state for the hook status JSON and the Lua status call.
struct Counters {
  std::uint64_t session{};   // scene generation; 0 until a scene is adopted
  std::uint64_t requests{};  // draw requests armed from Lua
  std::uint64_t drawn{};     // draw requests that reached a peer renderer
  std::uint64_t errors{};    // rejected, unconsumed or expired draw requests
  int peers{};               // peers whose preview is still inside the four-second window
  bool scene{};              // a main scene is adopted
};
Counters Snapshot();

// Empty when previews are available; otherwise why they are not.
std::string UnavailableReason();

// A bounded in-process event log (the last kTraceSlots entries, oldest
// first), published as hooks.preview.trace. Every entry is one short ASCII
// line with the tick and the thread that recorded it. Recording is one-shot
// or state-change only: nothing here runs per frame once a scene is live, so
// a live stall can be located without a debugger.
std::vector<std::string> TraceSnapshot();

// Notified once per recorded trace event, outside every internal lock.
void SetStatusWriteRequest(void (*status_write_request)());

// The hooks.preview object of the hook status JSON: the install outcome
// (enabled, installed, reason) plus the live counters and the trace.
std::string StatusJson(const Status& install);

// ------------------------------------------------------------------ Lua API
// Three globals in every Lua state the hook registers into (the GUI state is
// the one that matters):
//
//   tpf2mp_native_preview_status() -> { available, reason, session, peers, drawn }
//   tpf2mp_native_preview_begin(origin, mode) -> boolean
//   tpf2mp_native_preview_result() -> "ok" | "error" | "pending" | "idle"
//
// origin matches ^[a-z0-9]{1,8}$ ("player1"/"player2"); mode is one of "draw",
// "drawok", "drawbad", "keep" or "clear". "keep" (refresh that origin's
// timestamp) and "clear" (drop that origin's renderer content) run
// immediately on the GUI thread and report their own success. "draw",
// "drawok" and "drawbad" arm a one-shot request that the next
// scripting::Convert on the GUI thread consumes; an armed request that no
// conversion consumes within two seconds expires, and a new begin replaces a
// still-armed one. The Lua side NEVER calls api.cmd.sendCommand for a
// preview: it only builds a proposal so that the engine converts it.
using LuaCFunction = int (*)(lua_State*);
using LuaPushLString = const char* (*)(lua_State*, const char*, std::size_t);
using LuaToLString = const char* (*)(lua_State*, int, std::size_t*);
using LuaGetTop = int (*)(lua_State*);
using LuaPushCClosure = void (*)(lua_State*, LuaCFunction, int);
using LuaRawSet = void (*)(lua_State*, int);
using LuaCallK = void (*)(lua_State*, int, int, int, LuaCFunction);

struct LuaApi {
  LuaPushLString push_string{};
  LuaToLString to_string{};
  LuaGetTop get_top{};
  LuaPushCClosure push_closure{};
  LuaRawSet raw_set{};
  LuaCallK call_k{};
};

// Registers the three globals into the table at the top of the caller's
// stack, the same convention the hook's other registrations use.
void RegisterLuaApi(lua_State* state, const LuaApi& api);

// --------------------------------------------------------- pinned Build 35924
// Hooked entry points.
constexpr std::uintptr_t kRendererFactoryRva = 0x859240;
constexpr std::uintptr_t kSceneAddRenderableRva = 0x6d32e0;
constexpr std::uintptr_t kSceneDestructorRva = 0x6d22d0;
constexpr std::uintptr_t kScriptingConvertRva = 0x20e72f0;
constexpr std::uintptr_t kBuilderRendererClearRva = 0x817f70;
constexpr std::uintptr_t kEndHeightModRva = 0x8191d0;
constexpr std::uintptr_t kBuilderRendererDestructorRva = 0x814b20;
constexpr std::size_t kHookCount = 7;

// Called, not hooked.
constexpr std::uintptr_t kSceneRemoveRenderableRva = 0x6d9290;
constexpr std::uintptr_t kRendererDeleteRva = 0x8163c0;
constexpr std::uintptr_t kConvertContextInitRva = 0x431560;
constexpr std::uintptr_t kConvertContextDestructorRva = 0x3e3d30;
constexpr std::uintptr_t kCreateProposalDataRva = 0xa072b0;
constexpr std::uintptr_t kProposalDataDestructorRva = 0x3e5030;
constexpr std::uintptr_t kAddToRendererRva = 0x48d8e0;
constexpr std::uintptr_t kUploadHeightRva = 0x34cd90;
constexpr std::uintptr_t kResetHeightRva = 0x34e5a0;
constexpr std::uintptr_t kErrorColorRva = 0x81df00;
constexpr std::uintptr_t kBuilderRendererVtableRva = 0x30665e0;
// luaB_load, read out of the base library's luaL_Reg table beside luaB_print
// (0x74f70, pinned in build_profile.hpp). The Lua C API the hook resolves has
// no table or boolean push, so the two Lua calls that must return a table or
// a boolean build their result from a short chunk that uses no globals.
constexpr std::uintptr_t kLuaLoadRva = 0x75890;

// Return addresses inside the game that identify the one factory and the one
// scene this module adopts. Not hooked, only compared.
constexpr std::uintptr_t kGameUiFactoryReturnRva = 0x445897;
constexpr std::uintptr_t kMainSceneAddReturnRva = 0x56a532;

constexpr std::size_t kMaxPeers = 16;
constexpr std::uint64_t kPeerLifetimeMs = 4000;
constexpr std::uint64_t kRequestLifetimeMs = 2000;
constexpr std::size_t kTraceSlots = 48;
// Local builder renderers whose height buffers are re-uploaded after a remote
// preview changed the shared UI terrain. A hard cap keeps the list bounded no
// matter what the game does.
constexpr std::size_t kMaxLocalHeightRenderers = 64;

// ------------------------------------------------------------- test seam
// tests/native_preview_render_tests.cpp drives the module with stub engine
// routines and fake renderer memory; the game never calls any of this.
namespace testing {

struct Stubs {
  void* (*convert)(void*, void*, void*){};
  void (*clear)(void*, bool, bool){};
  void (*end_height)(void*){};
  void (*renderer_destructor)(void*){};
  void (*reset_height)(void*, bool){};
  void (*upload_height)(void*, void*, bool){};
  void (*error_color)(void*, bool){};
  std::uint64_t (*now)(){};
  // The engine calls a consumed draw request makes.
  void (*context_init)(void*, int){};
  void (*context_destructor)(void*){};
  void (*create_proposal_data)(void*, void*, void*, void*, void*, void*){};
  void (*proposal_data_destructor)(void*){};
  void (*add_to_renderer)(void*, void*, void*, const float*, const void*, bool, bool, bool){};
};

void Reset();
void SetStubs(const Stubs& stubs);
// Adopts `scene` and `terrain` and records the calling thread as the GUI one.
void SetScene(void* scene, void* terrain);
void SetPeer(std::size_t index, const char* origin, void* renderer, std::uint64_t seen);
void SetPeerPalette(std::size_t index, const unsigned char* palette, std::size_t size);
std::uint64_t PeerSeen(std::size_t index);
void ApplySenderPalette(std::size_t index, int invalid);
void ApplySenderMode(void* renderer, const char* mode);
void ErrorColor(void* renderer, bool invalid);
bool SafeProposal(const void* proposal);
void* Convert(void* result, void* toolkit, void* proposal);
void ClearRenderer(void* renderer, bool models, bool terrain);
void EndHeightMod(void* renderer);
void ComposeTerrain();
bool ExpirePeers();
bool Begin(const char* origin, const char* mode);
const char* Result();

}  // namespace testing

}  // namespace tpf2mp::preview_render
