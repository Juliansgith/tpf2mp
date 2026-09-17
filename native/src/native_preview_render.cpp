// Independent cosmetic BuilderRenderers for the other player's unconfirmed
// build (Build 35924). Ported from silver2127's tpf2-multiplayer preview
// plugin; see tpf2mp/native_preview_render.hpp and
// native/third_party/tpf2-multiplayer/TPF2MP_PIN.txt.
//
// The receiving GUI Lua state constructs a proposal solely so the engine runs
// scripting::Convert. It never sends the command. This module reads the
// converted proposal, evaluates it and uploads preview buffers; it has no
// command-dispatch or applyProposal entry point.

#include "tpf2mp/native_preview_render.hpp"

#include <intrin.h>

#include <algorithm>
#include <atomic>
#include <cmath>
#include <cstdio>
#include <cstring>
#include <mutex>
#include <string>
#include <unordered_map>
#include <utility>
#include <vector>

namespace tpf2mp::preview_render {
namespace {

// ----------------------------------------------------------------- engine ABI
using FactoryFn = void* (*)(void*);
using AddFn = void (*)(void*, void*);
using DtorFn = void (*)(void*);
using ConvertFn = void* (*)(void*, void*, void*);
using ClearFn = void (*)(void*, bool, bool);
using HeightFn = void (*)(void*, void*, bool);
using ResetHeightFn = void (*)(void*, bool);
using ErrorColorFn = void (*)(void*, bool);
using RenderFn = void (*)(void*, void*, void*, void*);
using ContextInitFn = void (*)(void*, int);
using ProposalDataFn = void (*)(void*, void*, void*, void*, void*, void*);
using AddToRendererFn = void (*)(void*, void*, void*, const float*, const void*, bool, bool, bool);
using RendererDeleteFn = void* (*)(void*, unsigned);
using LuaLoadFn = int (*)(lua_State*);

// BuilderRenderer / proposal layout, all Build 35924.
constexpr std::size_t kRendererVtableOffset = 0;
constexpr std::size_t kRendererTerrainOffset = 0x50;
constexpr std::size_t kRendererHeightEnabledOffset = 0xf0;
constexpr std::size_t kRendererHeightErrorOffset = 0xf4;
constexpr std::size_t kRendererPaletteOffset = 0x118;
constexpr std::size_t kRendererStateOffset = 0x1b8;
constexpr std::size_t kStateHeightFirstOffset = 0x16b0;
constexpr std::size_t kStateHeightLastOffset = 0x16b8;
constexpr std::size_t kPaletteSize = 0x80;
constexpr std::size_t kPaletteHalf = 0x40;
constexpr std::size_t kFactorySize = 0xd8;
constexpr std::size_t kFactoryCallableOffset = 0xb8;
constexpr std::size_t kFactoryInlineOffset = 0x80;
constexpr std::size_t kNodesOffset = 0;
constexpr std::size_t kNodeSize = 24;
constexpr std::size_t kNodeEntityOffset = 0x14;
constexpr std::size_t kEdgesOffset = 0x18;
constexpr std::size_t kEdgeSize = 120;
constexpr std::size_t kConstructionsOffset = 0x1f8;
constexpr std::size_t kConstructionSize = 0x8e0;
constexpr std::size_t kConstructionTransformOffset = 0x728;
constexpr std::size_t kContextSize = 0x70;
constexpr std::size_t kContextDestructorOffset = 0x18;
constexpr std::size_t kProposalDataSize = 0x790;
constexpr std::size_t kRenderSlots = 7;
// Nodes/edges accepted for a plain route, and with one construction whose
// template generates temporary street pieces.
constexpr std::size_t kMaxNodes = 48;
constexpr std::size_t kMaxEdges = 24;
constexpr std::size_t kMaxConstructionNodes = 384;
constexpr std::size_t kMaxConstructionEdges = 192;

template <class T>
T& Field(void* pointer, const std::size_t offset) {
  return *reinterpret_cast<T*>(static_cast<char*>(pointer) + offset);
}
template <class T>
const T& Field(const void* pointer, const std::size_t offset) {
  return *reinterpret_cast<const T*>(static_cast<const char*>(pointer) + offset);
}

// -------------------------------------------------------------------- state
std::uintptr_t g_base;
Status g_status;
bool g_active;      // every detour passes straight through until this is set
bool g_installed;   // Install() ran to completion once

FactoryFn g_original_factory;
AddFn g_original_add;
DtorFn g_original_scene_destructor;
ConvertFn g_original_convert;
ClearFn g_original_clear;
DtorFn g_original_end_height;
DtorFn g_original_renderer_destructor;

AddFn g_remove_renderable;
RendererDeleteFn g_renderer_delete;
ContextInitFn g_context_init;
DtorFn g_context_destructor;
ProposalDataFn g_create_proposal_data;
DtorFn g_proposal_data_destructor;
AddToRendererFn g_add_to_renderer;
HeightFn g_upload_height;
ResetHeightFn g_reset_height;
ErrorColorFn g_set_error_color;
LuaLoadFn g_lua_load;
std::uint64_t (*g_clock)();

void* g_preview_vtable[kRenderSlots];
alignas(16) unsigned char g_factory[kFactorySize];
bool g_factory_live;

struct Peer {
  char origin[9]{};
  void* renderer{};
  std::uint64_t seen{};
  unsigned char original_palette[kPaletteSize]{};
};
Peer g_peers[kMaxPeers];

void* g_scene;
void* g_terrain_target;
DWORD g_gui_thread;
std::uint64_t g_session;
std::uint64_t g_scene_generation;
bool g_editing_remote;
bool g_disposing;
// Height uploads are global to the UI terrain, unlike the model renderers.
// Local descriptors remain owned by their BuilderRenderer until Clear/destroy.
std::vector<void*> g_local_height_renderers;

void* g_sender_color_renderer;
int g_sender_error_color = -1;

std::mutex g_request_mutex;
struct Armed {
  bool armed{};
  char origin[9]{};
  char mode[8]{};
  std::uint64_t tick{};
};
Armed g_armed;
enum class ResultState { Idle, Pending, Ok, Error };
ResultState g_result_state = ResultState::Idle;
std::atomic<std::uint64_t> g_requests{0};
std::atomic<std::uint64_t> g_drawn{0};
std::atomic<std::uint64_t> g_errors{0};

LuaApi g_lua;

std::uint64_t Now() { return g_clock != nullptr ? g_clock() : GetTickCount64(); }

// ------------------------------------------------------------------ palette
// Only this peer's cosmetic renderer is changed. The receiver's own
// evaluation, and every error or warning in its ProposalData, stays intact.
void ErrorColorImpl(void* renderer, bool invalid) {
  if (renderer == g_sender_color_renderer && g_sender_error_color >= 0) {
    invalid = g_sender_error_color != 0;
  }
  if (g_set_error_color != nullptr) g_set_error_color(renderer, invalid);
}

// The remote preview must look exactly like the local builder ghost, so only
// "drawbad" overrides anything: it selects the stock error colour the sender
// is seeing. "draw" and "drawok" keep the receiver's own evaluation.
void ApplySenderModeImpl(void* renderer, const char* mode) {
  g_sender_color_renderer = renderer;
  g_sender_error_color = std::strcmp(mode, "drawbad") == 0 ? 1 : -1;
}

void ApplySenderPaletteImpl(Peer& peer, const int invalid) {
  if (peer.renderer == nullptr) return;
  auto* palette = static_cast<unsigned char*>(peer.renderer) + kRendererPaletteOffset;
  std::memcpy(palette, peer.original_palette, kPaletteSize);
  // Four matching RGBA pairs: per-segment error selection must use the
  // sender's palette as well as the renderer-wide/terrain error flag.
  if (invalid == 0) {
    std::memcpy(palette + kPaletteHalf, peer.original_palette, kPaletteHalf);
  } else if (invalid == 1) {
    std::memcpy(palette, peer.original_palette + kPaletteHalf, kPaletteHalf);
  }
}

// ------------------------------------------------------------------- peers
bool PeerActive(const Peer& peer) {
  return peer.seen != 0 && Now() - peer.seen <= kPeerLifetimeMs;
}

bool IsPeerRenderer(const void* renderer) {
  for (const auto& peer : g_peers) {
    if (peer.renderer == renderer) return true;
  }
  return false;
}

bool HasRemoteTerrain() {
  for (const auto& peer : g_peers) {
    if (peer.renderer != nullptr && peer.seen != 0) return true;
  }
  return false;
}

void ClearPeer(Peer& peer) {
  peer.seen = 0;
  if (peer.renderer != nullptr && g_original_clear != nullptr) {
    g_original_clear(peer.renderer, true, false);
  }
}

bool ExpirePeersImpl() {
  bool changed = false;
  for (auto& peer : g_peers) {
    if (peer.seen != 0 && !PeerActive(peer)) {
      ClearPeer(peer);
      changed = true;
    }
  }
  return changed;
}

Peer* FindPeer(const char* origin) {
  for (auto& peer : g_peers) {
    if (std::strcmp(peer.origin, origin) == 0) return &peer;
  }
  return nullptr;
}

Peer* AcquirePeer(const char* origin) {
  if (Peer* existing = FindPeer(origin)) return existing;
  for (auto& peer : g_peers) {
    if (peer.origin[0] != '\0' && peer.seen != 0 && Now() - peer.seen <= kPeerLifetimeMs) continue;
    ClearPeer(peer);
    strcpy_s(peer.origin, origin);
    if (peer.renderer == nullptr) {
      if (g_original_factory == nullptr || g_scene == nullptr) return nullptr;
      peer.renderer = g_original_factory(g_factory);
      if (peer.renderer == nullptr) {
        peer.origin[0] = '\0';
        return nullptr;
      }
      std::memcpy(peer.original_palette,
                  static_cast<char*>(peer.renderer) + kRendererPaletteOffset, kPaletteSize);
      Field<void**>(peer.renderer, kRendererVtableOffset) = g_preview_vtable;
      g_original_add(g_scene, peer.renderer);
    }
    return &peer;
  }
  return nullptr;
}

// ----------------------------------------------------------------- terrain
void UploadRendererHeight(void* renderer) {
  if (renderer == nullptr || Field<void*>(renderer, kRendererTerrainOffset) != g_terrain_target ||
      !Field<bool>(renderer, kRendererHeightEnabledOffset)) {
    return;
  }
  auto* state = Field<unsigned char*>(renderer, kRendererStateOffset);
  if (Field<void*>(state, kStateHeightFirstOffset) != Field<void*>(state, kStateHeightLastOffset)) {
    g_upload_height(g_terrain_target, state + kStateHeightFirstOffset,
                    Field<bool>(renderer, kRendererHeightErrorOffset));
  }
}

void ComposeTerrainImpl() {
  if (g_terrain_target == nullptr || g_disposing || g_reset_height == nullptr) return;
  g_reset_height(g_terrain_target, true);
  // Remote uploads first; one's own tool keeps priority where areas overlap.
  for (const auto& peer : g_peers) {
    if (PeerActive(peer)) UploadRendererHeight(peer.renderer);
  }
  for (void* renderer : g_local_height_renderers) UploadRendererHeight(renderer);
}

void ForgetLocalHeight(void* renderer) {
  g_local_height_renderers.erase(
      std::remove(g_local_height_renderers.begin(), g_local_height_renderers.end(), renderer),
      g_local_height_renderers.end());
}

// ------------------------------------------------------------------ detours
void ClearDetour(void* renderer, bool models, bool terrain) {
  if (!g_active) {
    g_original_clear(renderer, models, terrain);
    return;
  }
  ForgetLocalHeight(renderer);
  g_original_clear(renderer, models, terrain);
  if (!g_editing_remote && !g_disposing && g_scene != nullptr &&
      GetCurrentThreadId() == g_gui_thread && HasRemoteTerrain()) {
    ComposeTerrainImpl();
  }
}

void EndHeightDetour(void* renderer) {
  if (!g_active) {
    g_original_end_height(renderer);
    return;
  }
  const bool remote = IsPeerRenderer(renderer);
  const bool enabled = Field<bool>(renderer, kRendererHeightEnabledOffset);
  // AddHeightMod writes the error flag directly, bypassing the setter.
  // Restore the sender's colour before EndHeightMod bakes its tinted overlay.
  if (remote && renderer == g_sender_color_renderer && g_sender_error_color >= 0) {
    ErrorColorImpl(renderer, false);
  }
  // Keep the native mesh generation, but publish remote terrain as a group.
  if (remote) Field<bool>(renderer, kRendererHeightEnabledOffset) = false;
  g_original_end_height(renderer);
  if (remote) {
    Field<bool>(renderer, kRendererHeightEnabledOffset) = enabled;
  } else if (g_scene != nullptr && enabled && GetCurrentThreadId() == g_gui_thread) {
    if (std::find(g_local_height_renderers.begin(), g_local_height_renderers.end(), renderer) ==
        g_local_height_renderers.end()) {
      g_local_height_renderers.push_back(renderer);
    }
  }
}

void RendererDestructorDetour(void* renderer) {
  if (!g_active) {
    g_original_renderer_destructor(renderer);
    return;
  }
  ForgetLocalHeight(renderer);
  if (!g_disposing && !g_editing_remote && g_scene != nullptr &&
      GetCurrentThreadId() == g_gui_thread && HasRemoteTerrain()) {
    ComposeTerrainImpl();
  }
  g_original_renderer_destructor(renderer);
}

// Native render passes take this, the renderer component and a render helper.
// Forward the fourth register too; short methods ignore the extra arguments.
template <int Slot>
void RenderPass(void* self, void* first, void* second, void* third) {
  if constexpr (Slot == 1) {
    if (GetCurrentThreadId() == g_gui_thread && ExpirePeersImpl()) ComposeTerrainImpl();
  }
  for (const auto& peer : g_peers) {
    if (peer.renderer != self) continue;
    if (PeerActive(peer)) {
      reinterpret_cast<RenderFn*>(g_base + kBuilderRendererVtableRva)[Slot](self, first, second,
                                                                           third);
    }
    return;
  }
}

void Dispose() {
  g_disposing = true;
  if (g_terrain_target != nullptr && g_reset_height != nullptr) {
    g_reset_height(g_terrain_target, true);
  }
  g_local_height_renderers.clear();
  for (auto& peer : g_peers) {
    if (peer.renderer != nullptr) {
      if (g_scene != nullptr) g_remove_renderable(g_scene, peer.renderer);
      ClearPeer(peer);
      g_renderer_delete(peer.renderer, 1);
    }
    peer = Peer{};
  }
  g_scene = nullptr;
  g_terrain_target = nullptr;
  g_disposing = false;
  g_session = 0;
  {
    std::lock_guard<std::mutex> lock(g_request_mutex);
    g_armed = Armed{};
    g_result_state = ResultState::Idle;
  }
  if (g_factory_live) {
    void* callable = Field<void*>(g_factory, kFactoryCallableOffset);
    if (callable != nullptr) {
      reinterpret_cast<void (*)(void*, bool)>(Field<void**>(callable, 0)[4])(
          callable, callable != g_factory + kFactoryInlineOffset);
    }
    g_factory_live = false;
  }
}

void* FactoryDetour(void* source) {
  void* result = g_original_factory(source);
  // The first street builder during CGameUI construction supplies a complete
  // live factory. Copy its native std::function with its own clone operation.
  if (g_active && !g_factory_live &&
      reinterpret_cast<std::uintptr_t>(_ReturnAddress()) - g_base == kGameUiFactoryReturnRva) {
    std::memcpy(g_factory, source, kFactorySize);
    Field<void*>(g_factory, kFactoryCallableOffset) = nullptr;
    void* callable = Field<void*>(source, kFactoryCallableOffset);
    if (callable != nullptr) {
      Field<void*>(g_factory, kFactoryCallableOffset) =
          reinterpret_cast<void* (*)(void*, void*)>(Field<void**>(callable, 0)[0])(
              callable, g_factory + kFactoryInlineOffset);
    }
    g_factory_live = true;
  }
  return result;
}

void AddRenderableDetour(void* target, void* object) {
  g_original_add(target, object);
  if (g_active && g_factory_live && g_scene == nullptr &&
      reinterpret_cast<std::uintptr_t>(_ReturnAddress()) - g_base == kMainSceneAddReturnRva) {
    g_scene = target;
    g_gui_thread = GetCurrentThreadId();
    g_session = ++g_scene_generation;
  }
}

void SceneDestructorDetour(void* target) {
  if (g_active && target == g_scene) Dispose();
  g_original_scene_destructor(target);
}

// ------------------------------------------------------------ input checks
std::size_t Count(const void* proposal, const std::size_t offset, const std::size_t stride) {
  const auto begin = Field<std::uintptr_t>(proposal, offset);
  const auto end = Field<std::uintptr_t>(proposal, offset + 8);
  if (end < begin || (end - begin) % stride != 0 || (end != begin && begin == 0)) {
    return static_cast<std::size_t>(-1);
  }
  return (end - begin) / stride;
}

bool SafeConstruction(const void* proposal) {
  const auto* construction = Field<const unsigned char*>(proposal, kConstructionsOffset);
  const auto& file = Field<std::string>(construction, 0);
  if (file.empty() || file.size() > 180 || file.front() == '/' ||
      file.find("..") != std::string::npos ||
      file.find_first_not_of("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_./-") !=
          std::string::npos ||
      file.size() < 4 || file.substr(file.size() - 4) != ".con") {
    return false;
  }
  const auto* transform = reinterpret_cast<const float*>(construction + kConstructionTransformOffset);
  for (std::size_t index = 0; index < 16; ++index) {
    const double limit = (index >= 12 && index <= 14) ? 1000000.0 : 100.0;
    if (!std::isfinite(transform[index]) || std::fabs(transform[index]) > limit) return false;
  }
  if (std::fabs(transform[3]) + std::fabs(transform[7]) + std::fabs(transform[11]) +
          std::fabs(transform[15] - 1.0f) >
      0.001) {
    return false;
  }
  const double determinant =
      transform[0] * (double(transform[5]) * transform[10] - double(transform[6]) * transform[9]) -
      transform[4] * (double(transform[1]) * transform[10] - double(transform[2]) * transform[9]) +
      transform[8] * (double(transform[1]) * transform[6] - double(transform[2]) * transform[5]);
  return std::fabs(determinant) >= 0.000001 && std::fabs(determinant) <= 1000.0;
}

// Bounds the converted proposal before anything is evaluated: temporary ids
// only, no removals, no edge objects, finite vectors, and at most one
// independently converted construction with its generated street pieces.
bool SafeProposalImpl(const void* proposal) {
  const std::size_t nodes = Count(proposal, kNodesOffset, kNodeSize);
  const std::size_t edges = Count(proposal, kEdgesOffset, kEdgeSize);
  const std::size_t constructions = Count(proposal, kConstructionsOffset, kConstructionSize);
  if (constructions > 1 || nodes > (constructions != 0 ? kMaxConstructionNodes : kMaxNodes) ||
      edges > (constructions != 0 ? kMaxConstructionEdges : kMaxEdges) ||
      (edges != 0 && nodes == 0)) {
    return false;
  }
  // Accept one converted construction, never a replacement or demolition.
  for (const std::size_t offset : {std::size_t(0x30), std::size_t(0x48), std::size_t(0xe0),
                                   std::size_t(0xf8), std::size_t(0x1e0)}) {
    if (Field<const void*>(proposal, offset) != Field<const void*>(proposal, offset + 8)) {
      return false;
    }
  }
  if (constructions != 0 && !SafeConstruction(proposal)) return false;
  const auto* node_data = Field<const unsigned char*>(proposal, kNodesOffset);
  const auto* edge_data = Field<const unsigned char*>(proposal, kEdgesOffset);
  for (std::size_t index = 0; index < nodes; ++index) {
    const auto* node = node_data + index * kNodeSize;
    if (Field<int>(node, kNodeEntityOffset) >= 0) return false;
    for (std::size_t axis = 0; axis < 3; ++axis) {
      const float value = Field<float>(node, axis * 4);
      if (!std::isfinite(value) || std::fabs(value) > 1000000.0f) return false;
    }
  }
  for (std::size_t index = 0; index < edges; ++index) {
    const auto* edge = edge_data + index * kEdgeSize;
    if (Field<int>(edge, 0) >= 0 || Field<unsigned>(edge, 0x48) > 1 ||
        Field<unsigned>(edge, 0x28) > 2) {
      return false;
    }
    for (const std::size_t offset : {std::size_t(8), std::size_t(12)}) {
      const int id = Field<int>(edge, offset);
      bool found = false;
      for (std::size_t node = 0; node < nodes; ++node) {
        if (Field<int>(node_data + node * kNodeSize, kNodeEntityOffset) == id) found = true;
      }
      if (!found) return false;
    }
    for (std::size_t component = 0; component < 6; ++component) {
      const float value = Field<float>(edge, 0x10 + component * 4);
      if (!std::isfinite(value) || std::fabs(value) > 1000000.0f) return false;
    }
    for (const std::size_t offset : {std::size_t(0x10), std::size_t(0x1c)}) {
      double norm = 0;
      for (std::size_t axis = 0; axis < 3; ++axis) {
        norm += double(Field<float>(edge, offset + axis * 4)) * Field<float>(edge, offset + axis * 4);
      }
      if (norm < 0.0001) return false;
    }
    if (Field<const void*>(edge, 0x30) != Field<const void*>(edge, 0x38)) return false;
  }
  return true;
}

// ------------------------------------------------------------ request state
bool ValidOrigin(const char* origin) {
  if (origin == nullptr) return false;
  const std::size_t length = std::strlen(origin);
  if (length == 0 || length > 8) return false;
  for (std::size_t index = 0; index < length; ++index) {
    const char value = origin[index];
    const bool lower = value >= 'a' && value <= 'z';
    const bool digit = value >= '0' && value <= '9';
    if (!lower && !digit) return false;
  }
  return true;
}

bool ValidMode(const char* mode) {
  if (mode == nullptr) return false;
  for (const char* known : {"draw", "drawok", "drawbad", "keep", "clear"}) {
    if (std::strcmp(mode, known) == 0) return true;
  }
  return false;
}

bool IsDrawMode(const char* mode) { return std::strncmp(mode, "draw", 4) == 0; }

void CompleteRequest(const bool ok) {
  std::lock_guard<std::mutex> lock(g_request_mutex);
  g_result_state = ok ? ResultState::Ok : ResultState::Error;
  (ok ? g_drawn : g_errors).fetch_add(1, std::memory_order_relaxed);
}

// True when a still-valid draw request was armed; it is consumed either way.
bool TakeArmedRequest(char (&origin)[9], char (&mode)[8]) {
  std::lock_guard<std::mutex> lock(g_request_mutex);
  if (!g_armed.armed) return false;
  const bool expired = Now() - g_armed.tick > kRequestLifetimeMs;
  std::memcpy(origin, g_armed.origin, sizeof origin);
  std::memcpy(mode, g_armed.mode, sizeof mode);
  g_armed = Armed{};
  if (expired) {
    g_result_state = ResultState::Error;
    g_errors.fetch_add(1, std::memory_order_relaxed);
  }
  return !expired;
}

bool DrawPeer(const char* origin, const char* mode, void* toolkit, void* converted) {
  if (!SafeProposalImpl(converted)) return false;
  if (Count(converted, kEdgesOffset, kEdgeSize) == 0 &&
      Count(converted, kConstructionsOffset, kConstructionSize) == 0) {
    return false;
  }
  Peer* peer = AcquirePeer(origin);
  if (peer == nullptr) return false;
  alignas(16) unsigned char context[kContextSize]{};
  alignas(16) unsigned char data[kProposalDataSize]{};
  g_context_init(context, -1);
  g_create_proposal_data(data, toolkit, nullptr, converted, nullptr, context);
  ClearPeer(*peer);
  g_terrain_target = Field<void*>(peer->renderer, kRendererTerrainOffset);
  const float offset[3]{};
  const std::unordered_map<int, std::pair<int, float>> empty;
  // The tint is consumed while the buffers are generated, not only at render
  // time, so it is selected before the upload and released afterwards.
  ApplySenderModeImpl(peer->renderer, mode);
  ApplySenderPaletteImpl(*peer, g_sender_error_color);
  g_add_to_renderer(toolkit, peer->renderer, data, offset, &empty, false, false, true);
  if (g_sender_error_color >= 0) ErrorColorImpl(peer->renderer, false);
  g_sender_color_renderer = nullptr;
  g_sender_error_color = -1;
  g_proposal_data_destructor(data);
  g_context_destructor(context + kContextDestructorOffset);
  peer->seen = Now();
  return true;
}

void* ConvertDetour(void* result, void* toolkit, void* proposal) {
  void* converted = g_original_convert(result, toolkit, proposal);
  if (!g_active || g_scene == nullptr || GetCurrentThreadId() != g_gui_thread) return converted;
  char origin[9]{};
  char mode[8]{};
  if (!TakeArmedRequest(origin, mode)) return converted;
  bool terrain_changed = ExpirePeersImpl();
  g_editing_remote = true;
  const bool ok = DrawPeer(origin, mode, toolkit, converted);
  g_editing_remote = false;
  if (ok) terrain_changed = true;
  if (terrain_changed) ComposeTerrainImpl();
  CompleteRequest(ok);
  return converted;
}

// "keep" and "clear" touch peer state directly and therefore run on the GUI
// thread, where every other renderer mutation happens.
bool RunImmediate(const char* origin, const char* mode) {
  bool terrain_changed = ExpirePeersImpl();
  bool ok = false;
  g_editing_remote = true;
  if (std::strcmp(mode, "clear") == 0) {
    if (Peer* peer = FindPeer(origin)) {
      ClearPeer(*peer);
      terrain_changed = true;
    }
    ok = true;
  } else if (Peer* peer = FindPeer(origin)) {
    // Expiry cleared the buffers. Reject keep so Lua resends the geometry.
    if (peer->seen != 0) {
      peer->seen = Now();
      ok = true;
    }
  }
  g_editing_remote = false;
  if (terrain_changed) ComposeTerrainImpl();
  return ok;
}

bool BeginImpl(const char* origin, const char* mode) {
  if (!ValidOrigin(origin) || !ValidMode(mode)) return false;
  if (!UnavailableReason().empty()) return false;
  if (!IsDrawMode(mode)) {
    if (GetCurrentThreadId() != g_gui_thread) return false;
    return RunImmediate(origin, mode);
  }
  std::lock_guard<std::mutex> lock(g_request_mutex);
  g_armed = Armed{};
  g_armed.armed = true;
  strcpy_s(g_armed.origin, origin);
  strcpy_s(g_armed.mode, mode);
  g_armed.tick = Now();
  g_result_state = ResultState::Pending;
  g_requests.fetch_add(1, std::memory_order_relaxed);
  return true;
}

const char* ResultImpl() {
  std::lock_guard<std::mutex> lock(g_request_mutex);
  if (g_armed.armed && Now() - g_armed.tick > kRequestLifetimeMs) {
    g_armed = Armed{};
    g_result_state = ResultState::Error;
    g_errors.fetch_add(1, std::memory_order_relaxed);
  }
  switch (g_result_state) {
    case ResultState::Ok:
      g_result_state = ResultState::Idle;
      return "ok";
    case ResultState::Error:
      g_result_state = ResultState::Idle;
      return "error";
    case ResultState::Pending:
      return "pending";
    default:
      return "idle";
  }
}

// ---------------------------------------------------------------- Lua glue
// The Lua C API the hook resolves has no table or boolean push, so the two
// calls that must return one build it through the base library's own load().
// The chunks use no globals and no string-to-number coercion: the counters
// are written into the chunk as decimal literals and only the two strings
// this module controls are passed as arguments.
constexpr char kBooleanChunk[] =
    "local a=...\n"
    "return a==\"1\"\n";
constexpr char kChunkName[] = "=tpf2mp_native_preview";

void PushText(lua_State* state, const std::string& text) {
  g_lua.push_string(state, text.data(), text.size());
}

bool PushChunkFunction(lua_State* state, const char* chunk, const std::size_t size) {
  if (g_lua_load == nullptr || g_lua.push_closure == nullptr || g_lua.push_string == nullptr ||
      g_lua.call_k == nullptr) {
    return false;
  }
  g_lua.push_closure(state, g_lua_load, 0);
  g_lua.push_string(state, chunk, size);
  g_lua.push_string(state, kChunkName, sizeof kChunkName - 1);
  g_lua.call_k(state, 2, 1, 0, nullptr);
  return true;
}

bool ReadArgument(lua_State* state, const int index, char* out, const std::size_t capacity) {
  if (g_lua.get_top == nullptr || g_lua.to_string == nullptr) return false;
  if (g_lua.get_top(state) < index) return false;
  std::size_t length = 0;
  const char* text = g_lua.to_string(state, index, &length);
  if (text == nullptr || length == 0 || length >= capacity) return false;
  std::memcpy(out, text, length);
  out[length] = '\0';
  return true;
}

int NativePreviewStatus(lua_State* state) {
  const Counters counters = Snapshot();
  const std::string reason = UnavailableReason();
  const std::string chunk =
      "local a,b=...\n"
      "local r\n"
      "if b~=\"\" then r=b end\n"
      "return {available=a==\"1\",reason=r,session=" +
      std::to_string(counters.session) + ",peers=" + std::to_string(counters.peers) +
      ",drawn=" + std::to_string(counters.drawn) + "}\n";
  if (!PushChunkFunction(state, chunk.data(), chunk.size())) return 0;
  PushText(state, reason.empty() ? "1" : "0");
  PushText(state, reason);
  g_lua.call_k(state, 2, 1, 0, nullptr);
  return 1;
}

int NativePreviewBegin(lua_State* state) {
  char origin[16]{};
  char mode[16]{};
  const bool ok = ReadArgument(state, 1, origin, sizeof origin) &&
                  ReadArgument(state, 2, mode, sizeof mode) && BeginImpl(origin, mode);
  if (!PushChunkFunction(state, kBooleanChunk, sizeof kBooleanChunk - 1)) return 0;
  PushText(state, ok ? "1" : "0");
  g_lua.call_k(state, 1, 1, 0, nullptr);
  return 1;
}

int NativePreviewResult(lua_State* state) {
  const char* text = ResultImpl();
  g_lua.push_string(state, text, std::strlen(text));
  return 1;
}

void Register(lua_State* state, const char* name, LuaCFunction function) {
  g_lua.push_string(state, name, std::strlen(name));
  g_lua.push_closure(state, function, 0);
  g_lua.raw_set(state, -3);
}

// ------------------------------------------------------------- installation
struct PinnedRegion {
  std::uintptr_t rva;
  const char* name;
  const std::uint8_t* bytes;
  std::size_t size;
};

constexpr std::uint8_t kFactoryBytes[] = {0x48, 0x89, 0x4c, 0x24, 0x08, 0x53, 0x55, 0x56,
                                          0x57, 0x41, 0x54, 0x41, 0x55, 0x41, 0x56};
constexpr std::uint8_t kAddRenderableBytes[] = {0x48, 0x89, 0x54, 0x24, 0x10, 0x48, 0x83, 0xec,
                                                0x28, 0x4c, 0x8b, 0x81, 0xc8, 0x04, 0x00, 0x00};
constexpr std::uint8_t kSceneDestructorBytes[] = {0x48, 0x89, 0x4c, 0x24, 0x08, 0x57, 0x48,
                                                  0x83, 0xec, 0x30, 0x48, 0xc7, 0x44, 0x24,
                                                  0x20, 0xfe, 0xff, 0xff, 0xff};
constexpr std::uint8_t kConvertBytes[] = {0x40, 0x55, 0x56, 0x57, 0x41, 0x54, 0x41,
                                          0x55, 0x41, 0x56, 0x41, 0x57, 0x48, 0x8d,
                                          0xac, 0x24, 0x00, 0xfc, 0xff, 0xff};
constexpr std::uint8_t kClearBytes[] = {0x48, 0x8b, 0xc4, 0x55, 0x57, 0x41, 0x54, 0x41,
                                        0x56, 0x41, 0x57, 0x48, 0x8d, 0x68, 0xa1};
constexpr std::uint8_t kEndHeightBytes[] = {0x48, 0x8b, 0xc4, 0x55, 0x41, 0x54, 0x41, 0x55, 0x41,
                                            0x56, 0x41, 0x57, 0x48, 0x8d, 0x6c, 0x24, 0x80};
constexpr std::uint8_t kRendererDestructorBytes[] = {0x48, 0x8b, 0xc4, 0x55, 0x57, 0x41, 0x56,
                                                     0x48, 0x8d, 0x6c, 0x24, 0x80, 0x48, 0x81,
                                                     0xec, 0x80, 0x01, 0x00, 0x00};
constexpr std::uint8_t kRemoveRenderableBytes[] = {0x40, 0x53, 0x48, 0x83, 0xec, 0x20, 0x4c, 0x8b,
                                                   0x81, 0xc8, 0x04, 0x00, 0x00, 0x48, 0x8b, 0xd9};
constexpr std::uint8_t kRendererDeleteBytes[] = {0x48, 0x89, 0x5c, 0x24, 0x08, 0x57, 0x48, 0x83,
                                                 0xec, 0x20, 0x8b, 0xda, 0x48, 0x8b, 0xf9, 0xe8};
constexpr std::uint8_t kContextInitBytes[] = {0x48, 0x89, 0x4c, 0x24, 0x08, 0x56, 0x57, 0x41,
                                              0x56, 0x48, 0x83, 0xec, 0x30, 0x48, 0xc7, 0x44};
constexpr std::uint8_t kContextDestructorBytes[] = {0x40, 0x53, 0x48, 0x83, 0xec, 0x20, 0x48, 0x8b,
                                                    0xd9, 0x48, 0x8b, 0x49, 0x18, 0x48, 0x85, 0xc9};
constexpr std::uint8_t kCreateProposalDataBytes[] = {0x40, 0x53, 0x56, 0x57, 0x41, 0x54,
                                                     0x41, 0x55, 0x41, 0x56, 0x41, 0x57,
                                                     0x48, 0x81, 0xec, 0xf0};
constexpr std::uint8_t kProposalDataDestructorBytes[] = {0x40, 0x57, 0x48, 0x83, 0xec, 0x30,
                                                         0x48, 0xc7, 0x44, 0x24, 0x20, 0xfe,
                                                         0xff, 0xff, 0xff, 0x48};
constexpr std::uint8_t kAddToRendererBytes[] = {0x48, 0x8b, 0xc4, 0x55, 0x56, 0x57, 0x41,
                                                0x54, 0x41, 0x55, 0x41, 0x56, 0x41, 0x57,
                                                0x48, 0x8d, 0xa8, 0x88, 0xfb, 0xff};
constexpr std::uint8_t kUploadHeightBytes[] = {0x48, 0x8b, 0xc4, 0x55, 0x56, 0x57, 0x41,
                                               0x54, 0x41, 0x55, 0x41, 0x56, 0x41, 0x57,
                                               0x48, 0x8d, 0xa8, 0xc8, 0xfe, 0xff};
constexpr std::uint8_t kResetHeightBytes[] = {0x88, 0x54, 0x24, 0x10, 0x55, 0x53, 0x56, 0x57,
                                              0x41, 0x54, 0x41, 0x55, 0x41, 0x56, 0x41, 0x57};
// The complete Build 35924 setter: renderer state +0x1504 holds the error tint.
constexpr std::uint8_t kErrorColorBytes[] = {0x48, 0x8b, 0x81, 0xb8, 0x01, 0x00, 0x00,
                                             0x88, 0x90, 0x04, 0x15, 0x00, 0x00, 0xc3};
constexpr std::uint8_t kLuaLoadBytes[] = {0x48, 0x89, 0x5c, 0x24, 0x08, 0x48, 0x89, 0x6c,
                                          0x24, 0x18, 0x56, 0x57, 0x41, 0x56, 0x48, 0x83};

constexpr PinnedRegion kPinnedRegions[] = {
    {kRendererFactoryRva, "renderer factory", kFactoryBytes, sizeof kFactoryBytes},
    {kSceneAddRenderableRva, "Scene::AddRenderable", kAddRenderableBytes,
     sizeof kAddRenderableBytes},
    {kSceneDestructorRva, "scene destructor", kSceneDestructorBytes, sizeof kSceneDestructorBytes},
    {kScriptingConvertRva, "scripting::Convert", kConvertBytes, sizeof kConvertBytes},
    {kBuilderRendererClearRva, "BuilderRenderer::Clear", kClearBytes, sizeof kClearBytes},
    {kEndHeightModRva, "EndHeightMod", kEndHeightBytes, sizeof kEndHeightBytes},
    {kBuilderRendererDestructorRva, "renderer destructor", kRendererDestructorBytes,
     sizeof kRendererDestructorBytes},
    {kSceneRemoveRenderableRva, "Scene::RemoveRenderable", kRemoveRenderableBytes,
     sizeof kRemoveRenderableBytes},
    {kRendererDeleteRva, "renderer deleting destructor", kRendererDeleteBytes,
     sizeof kRendererDeleteBytes},
    {kConvertContextInitRva, "convert context", kContextInitBytes, sizeof kContextInitBytes},
    {kConvertContextDestructorRva, "convert context destructor", kContextDestructorBytes,
     sizeof kContextDestructorBytes},
    {kCreateProposalDataRva, "CreateProposalData", kCreateProposalDataBytes,
     sizeof kCreateProposalDataBytes},
    {kProposalDataDestructorRva, "ProposalData destructor", kProposalDataDestructorBytes,
     sizeof kProposalDataDestructorBytes},
    {kAddToRendererRva, "AddToRenderer", kAddToRendererBytes, sizeof kAddToRendererBytes},
    {kUploadHeightRva, "upload UI terrain heights", kUploadHeightBytes, sizeof kUploadHeightBytes},
    {kResetHeightRva, "reset UI terrain heights", kResetHeightBytes, sizeof kResetHeightBytes},
    {kErrorColorRva, "error colour setter", kErrorColorBytes, sizeof kErrorColorBytes},
    {kLuaLoadRva, "luaB_load", kLuaLoadBytes, sizeof kLuaLoadBytes},
};

template <class T>
T At(const std::uintptr_t rva) {
  return reinterpret_cast<T>(g_base + rva);
}

// Stands in for luaB_load in tests; nothing in the tests calls Lua.
int TestChunkLoader(lua_State*) { return 0; }

std::string Hex(const std::uintptr_t value) {
  char buffer[24]{};
  sprintf_s(buffer, "0x%llx", static_cast<unsigned long long>(value));
  return buffer;
}

}  // namespace

// ------------------------------------------------------------------- public
Request ParseRequest(const std::wstring_view value) {
  Request request;
  std::string text;
  for (const wchar_t character : value) {
    if (character > 127) {
      text.push_back('?');
    } else {
      text.push_back(static_cast<char>(
          character >= L'A' && character <= L'Z' ? character - L'A' + L'a' : character));
    }
  }
  while (!text.empty() && (text.front() == ' ' || text.front() == '\t')) text.erase(text.begin());
  while (!text.empty() && (text.back() == ' ' || text.back() == '\t')) text.pop_back();
  request.raw = text.empty() ? "(default: on)" : text;
  if (text.empty() || text == "1" || text == "on" || text == "true" || text == "all") {
    request.enabled = true;
  } else if (text == "0" || text == "off" || text == "false" || text == "none" || text == "stock") {
    request.enabled = false;
  } else {
    request.error = "unknown value '" + text + "'";  // fail closed
  }
  return request;
}

Status Install(const Host& host, const Request& request) {
  Status status;
  status.requested = request.raw;
  status.enabled = request.enabled && request.error.empty();
  if (!request.error.empty()) {
    status.reason = "request: " + request.error;
  } else if (g_installed) {
    return g_status;  // one process installs these detours once
  } else if (!request.enabled) {
    status.reason = "disabled by TPF2MP_NATIVE_PREVIEW";
  } else if (host.module_base == nullptr || host.verify_bytes == nullptr ||
             host.install_hook == nullptr) {
    status.reason = "host services are incomplete";
  }
  if (!status.reason.empty()) {
    g_status = status;
    return status;
  }
  const std::uintptr_t base = host.module_base(host.context);
  if (base == 0) {
    status.reason = "module base unavailable";
    g_status = status;
    return status;
  }
  for (const auto& region : kPinnedRegions) {
    if (host.verify_bytes(host.context, region.rva, region.bytes, region.size) == 0) {
      status.reason = std::string("pinned bytes differ: ") + region.name + " at " + Hex(region.rva);
      g_status = status;
      return status;
    }
  }
  const auto* vtable = reinterpret_cast<void* const*>(base + kBuilderRendererVtableRva);
  if (reinterpret_cast<std::uintptr_t>(vtable[0]) != base + kRendererDeleteRva) {
    status.reason = "builder renderer vtable does not start with the pinned destructor";
    g_status = status;
    return status;
  }

  g_base = base;
  g_remove_renderable = At<AddFn>(kSceneRemoveRenderableRva);
  g_renderer_delete = At<RendererDeleteFn>(kRendererDeleteRva);
  g_context_init = At<ContextInitFn>(kConvertContextInitRva);
  g_context_destructor = At<DtorFn>(kConvertContextDestructorRva);
  g_create_proposal_data = At<ProposalDataFn>(kCreateProposalDataRva);
  g_proposal_data_destructor = At<DtorFn>(kProposalDataDestructorRva);
  g_add_to_renderer = At<AddToRendererFn>(kAddToRendererRva);
  g_upload_height = At<HeightFn>(kUploadHeightRva);
  g_reset_height = At<ResetHeightFn>(kResetHeightRva);
  g_set_error_color = At<ErrorColorFn>(kErrorColorRva);
  g_lua_load = At<LuaLoadFn>(kLuaLoadRva);
  std::memcpy(g_preview_vtable, vtable, sizeof g_preview_vtable);
  g_preview_vtable[1] = reinterpret_cast<void*>(&RenderPass<1>);
  g_preview_vtable[2] = reinterpret_cast<void*>(&RenderPass<2>);
  g_preview_vtable[3] = reinterpret_cast<void*>(&RenderPass<3>);
  g_preview_vtable[4] = reinterpret_cast<void*>(&RenderPass<4>);
  g_preview_vtable[5] = reinterpret_cast<void*>(&RenderPass<5>);
  g_preview_vtable[6] = reinterpret_cast<void*>(&RenderPass<6>);

  struct HookSpec {
    std::uintptr_t rva;
    const char* name;
    void* detour;
    void** original;
  };
  const HookSpec hooks[kHookCount] = {
      {kRendererFactoryRva, "renderer factory", reinterpret_cast<void*>(&FactoryDetour),
       reinterpret_cast<void**>(&g_original_factory)},
      {kSceneAddRenderableRva, "Scene::AddRenderable", reinterpret_cast<void*>(&AddRenderableDetour),
       reinterpret_cast<void**>(&g_original_add)},
      {kSceneDestructorRva, "scene destructor", reinterpret_cast<void*>(&SceneDestructorDetour),
       reinterpret_cast<void**>(&g_original_scene_destructor)},
      {kScriptingConvertRva, "scripting::Convert", reinterpret_cast<void*>(&ConvertDetour),
       reinterpret_cast<void**>(&g_original_convert)},
      {kBuilderRendererClearRva, "BuilderRenderer::Clear", reinterpret_cast<void*>(&ClearDetour),
       reinterpret_cast<void**>(&g_original_clear)},
      {kEndHeightModRva, "EndHeightMod", reinterpret_cast<void*>(&EndHeightDetour),
       reinterpret_cast<void**>(&g_original_end_height)},
      {kBuilderRendererDestructorRva, "renderer destructor",
       reinterpret_cast<void*>(&RendererDestructorDetour),
       reinterpret_cast<void**>(&g_original_renderer_destructor)},
  };
  // Detours installed before the last one stay inert: every one of them
  // forwards to the original until g_active is set.
  for (const auto& hook : hooks) {
    if (host.install_hook(host.context, base + hook.rva, hook.detour, hook.original) == 0) {
      status.reason = std::string("hook failed: ") + hook.name + " at " + Hex(hook.rva);
      g_status = status;
      return status;
    }
  }
  g_installed = true;
  status.installed = true;
  g_status = status;
  g_active = true;
  return status;
}

Counters Snapshot() {
  Counters counters;
  counters.session = g_session;
  counters.requests = g_requests.load(std::memory_order_relaxed);
  counters.drawn = g_drawn.load(std::memory_order_relaxed);
  counters.errors = g_errors.load(std::memory_order_relaxed);
  counters.scene = g_scene != nullptr;
  const std::uint64_t now = Now();
  for (const auto& peer : g_peers) {
    if (peer.seen != 0 && now - peer.seen <= kPeerLifetimeMs) ++counters.peers;
  }
  return counters;
}

std::string UnavailableReason() {
  if (!g_status.installed) return g_status.reason.empty() ? "not installed" : g_status.reason;
  if (g_lua_load == nullptr) return "lua chunk loader unavailable";
  if (g_scene == nullptr) return "no scene";
  return {};
}

void RegisterLuaApi(lua_State* state, const LuaApi& api) {
  g_lua = api;
  if (api.push_string == nullptr || api.push_closure == nullptr || api.raw_set == nullptr) return;
  Register(state, "tpf2mp_native_preview_status", NativePreviewStatus);
  Register(state, "tpf2mp_native_preview_begin", NativePreviewBegin);
  Register(state, "tpf2mp_native_preview_result", NativePreviewResult);
}

// --------------------------------------------------------------- test seam
namespace testing {

void Reset() {
  g_base = 0;
  g_status = Status{};
  g_active = false;
  g_installed = false;
  g_original_factory = nullptr;
  g_original_add = nullptr;
  g_original_scene_destructor = nullptr;
  g_original_convert = nullptr;
  g_original_clear = nullptr;
  g_original_end_height = nullptr;
  g_original_renderer_destructor = nullptr;
  g_remove_renderable = nullptr;
  g_renderer_delete = nullptr;
  g_context_init = nullptr;
  g_context_destructor = nullptr;
  g_create_proposal_data = nullptr;
  g_proposal_data_destructor = nullptr;
  g_add_to_renderer = nullptr;
  g_upload_height = nullptr;
  g_reset_height = nullptr;
  g_set_error_color = nullptr;
  g_lua_load = nullptr;
  g_clock = nullptr;
  g_factory_live = false;
  for (auto& peer : g_peers) peer = Peer{};
  g_scene = nullptr;
  g_terrain_target = nullptr;
  g_gui_thread = 0;
  g_session = 0;
  g_scene_generation = 0;
  g_editing_remote = false;
  g_disposing = false;
  g_local_height_renderers.clear();
  g_sender_color_renderer = nullptr;
  g_sender_error_color = -1;
  std::lock_guard<std::mutex> lock(g_request_mutex);
  g_armed = Armed{};
  g_result_state = ResultState::Idle;
  g_requests = 0;
  g_drawn = 0;
  g_errors = 0;
}

void SetStubs(const Stubs& stubs) {
  g_original_convert = stubs.convert;
  g_original_clear = stubs.clear;
  g_original_end_height = stubs.end_height;
  g_original_renderer_destructor = stubs.renderer_destructor;
  g_reset_height = stubs.reset_height;
  g_upload_height = stubs.upload_height;
  g_set_error_color = stubs.error_color;
  g_clock = stubs.now;
  g_context_init = stubs.context_init;
  g_context_destructor = stubs.context_destructor;
  g_create_proposal_data = stubs.create_proposal_data;
  g_proposal_data_destructor = stubs.proposal_data_destructor;
  g_add_to_renderer = stubs.add_to_renderer;
}

void SetScene(void* scene, void* terrain) {
  g_scene = scene;
  g_terrain_target = terrain;
  g_gui_thread = GetCurrentThreadId();
  if (scene != nullptr && g_session == 0) g_session = ++g_scene_generation;
  // Report the same availability an installed hook with a live scene does.
  // The Lua entry points are never called from the tests, so the chunk loader
  // only has to be non-null.
  g_status.installed = scene != nullptr;
  g_active = scene != nullptr;
  g_lua_load = scene != nullptr ? &TestChunkLoader : nullptr;
}

void SetPeer(const std::size_t index, const char* origin, void* renderer,
             const std::uint64_t seen) {
  if (index >= kMaxPeers) return;
  Peer& peer = g_peers[index];
  peer = Peer{};
  if (origin != nullptr) strcpy_s(peer.origin, origin);
  peer.renderer = renderer;
  peer.seen = seen;
}

void SetPeerPalette(const std::size_t index, const unsigned char* palette, const std::size_t size) {
  if (index >= kMaxPeers || palette == nullptr) return;
  std::memcpy(g_peers[index].original_palette, palette, size < kPaletteSize ? size : kPaletteSize);
}

std::uint64_t PeerSeen(const std::size_t index) {
  return index < kMaxPeers ? g_peers[index].seen : 0;
}

void ApplySenderPalette(const std::size_t index, const int invalid) {
  if (index < kMaxPeers) ApplySenderPaletteImpl(g_peers[index], invalid);
}

void ApplySenderMode(void* renderer, const char* mode) { ApplySenderModeImpl(renderer, mode); }

void ErrorColor(void* renderer, const bool invalid) { ErrorColorImpl(renderer, invalid); }

bool SafeProposal(const void* proposal) { return SafeProposalImpl(proposal); }

void* Convert(void* result, void* toolkit, void* proposal) {
  return ConvertDetour(result, toolkit, proposal);
}

void ClearRenderer(void* renderer, const bool models, const bool terrain) {
  ClearDetour(renderer, models, terrain);
}

void EndHeightMod(void* renderer) { EndHeightDetour(renderer); }

void ComposeTerrain() { ComposeTerrainImpl(); }

bool ExpirePeers() { return ExpirePeersImpl(); }

bool Begin(const char* origin, const char* mode) { return BeginImpl(origin, mode); }

const char* Result() { return ResultImpl(); }

}  // namespace testing

}  // namespace tpf2mp::preview_render
