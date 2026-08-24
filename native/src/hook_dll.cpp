#include "tpf2mp/native_common.hpp"
#include "tpf2mp/native_async_bridge.hpp"
#include "tpf2mp/native_binding_catalog.hpp"
#include "tpf2mp/native_build_correlation.hpp"
#include "tpf2mp/native_command_codec.hpp"
#include "tpf2mp/native_hook_status.hpp"
#include "tpf2mp/native_launcher_barrier.hpp"

#include <MinHook.h>

#include <Windows.h>

#include <array>
#include <atomic>
#include <cmath>
#include <cstdint>
#include <cstdlib>
#include <cstring>
#include <cwchar>
#include <deque>
#include <filesystem>
#include <map>
#include <optional>
#include <set>
#include <sstream>
#include <string>
#include <string_view>
#include <utility>
#include <vector>

namespace {
using LuaCFunction = int (*)(lua_State*);
using LuaPrint = int (*)(lua_State*);
using LuaSetField = void (*)(lua_State*, int, const char*);
using LuaPushCClosure = void (*)(lua_State*, LuaCFunction, int);
using LuaPushValue = void (*)(lua_State*, int);
using LuaInsert = void (*)(lua_State*, int);
using LuaCallK = void (*)(lua_State*, int, int, int, LuaCFunction);
using LuaGetTop = int (*)(lua_State*);
using LuaSetTop = void (*)(lua_State*, int);
using LuaRawGetI = void (*)(lua_State*, int, int);
using LuaRawSetI = void (*)(lua_State*, int, int);
using LuaRawSet = void (*)(lua_State*, int);
using LuaPushLString = const char* (*)(lua_State*, const char*, std::size_t);
using LuaToLString = const char* (*)(lua_State*, int, std::size_t*);
using SetupCommandInterface = std::uintptr_t (*)(void*, void*, void*, void*);
using CommandListSwap = void (*)(void*, void*);
using ApplyCommand = void (*)(void*, void*);
using BuildProposalVisitor = bool (*)(void*, void*);
using AuthorityCommandVisitor = bool (*)(void*, void*);

constexpr int kLuaRegistryIndex = -1001000;
constexpr int kLuaGlobalsRegistryIndex = 2;
constexpr int kLuaMultiReturn = -1;
constexpr int kFirstUpvalueIndex = kLuaRegistryIndex - 1;
constexpr int kPendingSendCommandTable = -0x54504631;
constexpr int kPendingSendCommandFunction = -0x54504632;
constexpr int kCommandObserverFunction = -0x54504633;
constexpr std::size_t kNativeCommandSize = 0x38;
constexpr std::size_t kNativeCommandSuccessOffset = 0x30;
constexpr std::size_t kNativeCommandTypeCount = tpf2mp::native_command::kCommandTypeCount;
constexpr std::size_t kNativeCommandEventLimit = 256;
constexpr std::size_t kNativeRecentCommandEventLimit = 64;
// One ordered town-development action admits up to 512 towns x 8 calls. Keep
// that full protocol burst representable while retaining a hard finite cap.
constexpr std::uint64_t kCommandAuthorizationLimit = 8192;
using tpf2mp::native_command::CommandTypeName;
using tpf2mp::native_command::DecodeSuppressedLineCommand;
using tpf2mp::native_command::DecodeSuppressedVehicleCommand;
using tpf2mp::native_command::EncodeSuppressedLineCommand;
using tpf2mp::native_command::EncodeSuppressedVehicleCommand;
using tpf2mp::native_command::IsReadableRange;
using tpf2mp::native_command::NativeCommandDataTag;
using tpf2mp::native_command::NativeCommandTag;
using tpf2mp::native_command::NativeVectorLayout;
using tpf2mp::native_command::SumTagCounts;
using tpf2mp::native_command::SuppressedLineCommand;
using tpf2mp::native_command::SuppressedLineStop;
using tpf2mp::native_command::WriteTagCounts;
using tpf2mp::native_status::CompletedNativeCommand;
using tpf2mp::native_status::HookFlags;
using tpf2mp::native_status::HookStatusView;
using tpf2mp::native_status::LuaStateObservation;
using tpf2mp::native_status::PendingNativeCommand;
using tpf2mp::native_status::SerializeHookStatus;

HMODULE g_dll = nullptr;
std::atomic<bool> g_stop{false};
std::atomic<bool> g_status_dirty{true};
HANDLE g_status_event = nullptr;
SRWLOCK g_state_lock = SRWLOCK_INIT;
std::string g_stage = "loading";
std::string g_last_error;
std::filesystem::path g_dll_path;
tpf2mp::ValidationResult g_validation;
HookFlags g_hooks;
std::map<void*, LuaStateObservation> g_states;
std::uint64_t g_setup_calls = 0;
DWORD g_setup_last_thread = 0;
std::array<std::string, 4> g_setup_last_args{};
std::uint64_t g_command_swap_calls = 0;
std::uint64_t g_command_nonempty_batches = 0;
std::uint64_t g_command_queued = 0;
std::uint64_t g_command_invalid_layouts = 0;
std::uint64_t g_command_unknown_tags = 0;
std::uint64_t g_command_last_batch = 0;
std::uint64_t g_command_last_batch_id = 0;
std::uint64_t g_command_next_batch_id = 1;
std::uint64_t g_command_next_local_sequence = 1;
std::uint64_t g_command_pending_overwrites = 0;
DWORD g_command_swap_last_thread = 0;
std::array<std::uint64_t, kNativeCommandTypeCount> g_queued_tags{};
std::map<const void*, PendingNativeCommand> g_pending_commands;
std::deque<CompletedNativeCommand> g_completed_commands;
std::deque<CompletedNativeCommand> g_recent_completed_commands;
std::uint64_t g_apply_calls = 0;
std::uint64_t g_apply_succeeded = 0;
std::uint64_t g_apply_failed = 0;
std::uint64_t g_apply_unknown = 0;
std::uint64_t g_apply_unknown_tags = 0;
std::uint64_t g_apply_direct = 0;
std::uint64_t g_apply_tag_mismatches = 0;
std::uint64_t g_apply_filtered_script_events = 0;
int g_apply_last_tag = -1;
DWORD g_apply_last_thread = 0;
std::array<std::uint64_t, kNativeCommandTypeCount> g_applied_tags{};
bool g_build_gate_enabled = false;
std::uint64_t g_build_gate_authorizations = 0;
std::uint64_t g_build_gate_allowed = 0;
std::uint64_t g_build_gate_suppressed = 0;
std::uint64_t g_build_gate_calls = 0;
std::uint64_t g_build_gate_tag_mismatches = 0;
int g_build_gate_last_tag = -1;
DWORD g_build_gate_last_thread = 0;
tpf2mp::native_build::SuppressedBuildQueue g_suppressed_builds{64};
bool g_command_gate_enabled = false;
std::array<std::uint64_t, kNativeCommandTypeCount> g_command_gate_authorizations{};
std::array<std::uint64_t, kNativeCommandTypeCount> g_command_gate_allowed{};
std::array<std::uint64_t, kNativeCommandTypeCount> g_command_gate_suppressed{};
std::array<std::uint64_t, kNativeCommandTypeCount> g_command_gate_passthrough{};
std::array<std::uint64_t, kNativeCommandTypeCount> g_command_gate_calls{};
std::uint64_t g_command_gate_tag_mismatches = 0;
constexpr std::size_t kSuppressedGameSpeedQueueLimit = 32;
std::deque<std::int32_t> g_suppressed_game_speeds;
std::uint64_t g_suppressed_game_speed_captured = 0;
std::uint64_t g_suppressed_game_speed_consumed = 0;
std::uint64_t g_suppressed_game_speed_invalid = 0;
std::uint64_t g_suppressed_game_speed_dropped = 0;
int g_suppressed_game_speed_last = -1;
constexpr std::size_t kSuppressedLineCommandQueueLimit = 32;
std::deque<SuppressedLineCommand> g_suppressed_line_commands;
std::uint64_t g_suppressed_line_command_captured = 0;
std::uint64_t g_suppressed_line_command_consumed = 0;
std::uint64_t g_suppressed_line_command_invalid = 0;
std::uint64_t g_suppressed_line_command_dropped = 0;
std::uint64_t g_suppressed_line_command_drops_reported = 0;
int g_suppressed_line_command_last_tag = -1;
std::int32_t g_suppressed_line_command_last_target = -1;
std::size_t g_suppressed_line_command_last_stop_count = 0;
constexpr std::size_t kSuppressedVehicleCommandQueueLimit = 32;
std::deque<tpf2mp::native_command::SuppressedVehicleCommand> g_suppressed_vehicle_commands;
std::uint64_t g_suppressed_vehicle_command_captured = 0, g_suppressed_vehicle_command_consumed = 0;
std::uint64_t g_suppressed_vehicle_command_invalid = 0, g_suppressed_vehicle_command_dropped = 0,
              g_suppressed_vehicle_command_drops_reported = 0;
int g_suppressed_vehicle_command_last_tag = -1;
std::int32_t g_suppressed_vehicle_command_last_target = -1, g_suppressed_vehicle_command_last_secondary = -1;
LuaPrint g_original_print = nullptr; LuaSetField g_original_setfield = nullptr;
SetupCommandInterface g_original_setup_command = nullptr;
CommandListSwap g_original_command_list_swap = nullptr;
ApplyCommand g_original_apply_command = nullptr;
BuildProposalVisitor g_original_build_proposal_visitor = nullptr;
std::array<AuthorityCommandVisitor, kNativeCommandTypeCount> g_original_authority_visitors{};
LuaPushCClosure g_lua_pushcclosure = nullptr;
LuaPushValue g_lua_pushvalue = nullptr;
LuaInsert g_lua_insert = nullptr;
LuaCallK g_lua_callk = nullptr;
LuaGetTop g_lua_gettop = nullptr;
LuaSetTop g_lua_settop = nullptr;
LuaRawGetI g_lua_rawgeti = nullptr;
LuaRawSetI g_lua_rawseti = nullptr;
LuaRawSet g_lua_rawset = nullptr;
LuaPushLString g_lua_pushlstring = nullptr;
LuaToLString g_lua_tolstring = nullptr;

thread_local bool g_native_registration = false;
thread_local int g_setup_command_depth = 0;
thread_local lua_State* g_pending_send_command_state = nullptr;
thread_local lua_State* g_pending_binding_state = nullptr;
thread_local std::uint64_t g_pending_binding_mask = 0;

class StateLock final {
 public:
  StateLock() { AcquireSRWLockExclusive(&g_state_lock); }
  ~StateLock() { ReleaseSRWLockExclusive(&g_state_lock); }
  StateLock(const StateLock&) = delete;
  StateLock& operator=(const StateLock&) = delete;
};

void BootTrace(const char* stage) {
  // Deliberately Win32-only so it is safe before/inside CRT-backed worker
  // startup. This tiny trace distinguishes DLL mapping from worker failures.
  wchar_t temp[32768]{};
  const DWORD length = GetTempPathW(static_cast<DWORD>(std::size(temp)), temp);
  if (length == 0 || length >= std::size(temp)) return;
  wchar_t directory[32768]{};
  if (swprintf_s(directory, L"%stpf2mp_native", temp) < 0) return;
  CreateDirectoryW(directory, nullptr);
  wchar_t path[32768]{};
  if (swprintf_s(path, L"%s\\boot-%lu.log", directory, GetCurrentProcessId()) < 0) return;
  HANDLE file = CreateFileW(path, FILE_APPEND_DATA, FILE_SHARE_READ | FILE_SHARE_WRITE, nullptr,
                            OPEN_ALWAYS, FILE_ATTRIBUTE_NORMAL, nullptr);
  if (file == INVALID_HANDLE_VALUE) return;
  DWORD written = 0;
  WriteFile(file, stage, static_cast<DWORD>(strlen(stage)), &written, nullptr);
  WriteFile(file, "\r\n", 2, &written, nullptr);
  CloseHandle(file);
}

LuaStateObservation& ObserveStateLocked(lua_State* state) {
  auto [iterator, inserted] = g_states.try_emplace(state);
  auto& value = iterator->second;
  if (inserted) {
    value.pointer = tpf2mp::HexPointer(state);
    value.first_thread = GetCurrentThreadId();
  }
  value.last_thread = GetCurrentThreadId();
  return value;
}

void RequestStatusWrite() {
  g_status_dirty.store(true, std::memory_order_release);
  if (g_status_event != nullptr) {
    SetEvent(g_status_event);
  }
}

bool IsAuthorityCommandTag(const int tag) {
  return std::any_of(
      tpf2mp::profile::kAuthorityCommandVisitors.begin(),
      tpf2mp::profile::kAuthorityCommandVisitors.end(),
      [tag](const tpf2mp::profile::CommandVisitor& visitor) { return visitor.tag == tag; });
}

std::string StatusJson() {
  StateLock lock;
  return SerializeHookStatus(HookStatusView{
      .process_id = GetCurrentProcessId(),
      .stage = g_stage,
      .last_error = g_last_error,
      .dll_path = g_dll_path,
      .validation = g_validation,
      .hooks = g_hooks,
      .setup_calls = g_setup_calls,
      .setup_last_thread = g_setup_last_thread,
      .setup_last_args = g_setup_last_args,
      .command_swap_calls = g_command_swap_calls,
      .command_nonempty_batches = g_command_nonempty_batches,
      .command_queued = g_command_queued,
      .command_invalid_layouts = g_command_invalid_layouts,
      .command_unknown_tags = g_command_unknown_tags,
      .command_last_batch = g_command_last_batch,
      .command_last_batch_id = g_command_last_batch_id,
      .pending_commands = g_pending_commands.size(),
      .command_pending_overwrites = g_command_pending_overwrites,
      .command_swap_last_thread = g_command_swap_last_thread,
      .queued_tags = g_queued_tags,
      .apply_calls = g_apply_calls,
      .apply_succeeded = g_apply_succeeded,
      .apply_failed = g_apply_failed,
      .apply_unknown = g_apply_unknown,
      .apply_unknown_tags = g_apply_unknown_tags,
      .apply_direct = g_apply_direct,
      .apply_tag_mismatches = g_apply_tag_mismatches,
      .apply_filtered_script_events = g_apply_filtered_script_events,
      .apply_last_tag = g_apply_last_tag,
      .apply_last_thread = g_apply_last_thread,
      .applied_tags = g_applied_tags,
      .completed_commands = g_completed_commands,
      .recent_completed_commands = g_recent_completed_commands,
      .build_gate_enabled = g_build_gate_enabled,
      .build_gate_authorizations = g_build_gate_authorizations,
      .build_gate_allowed = g_build_gate_allowed,
      .build_gate_suppressed = g_build_gate_suppressed,
      .build_gate_calls = g_build_gate_calls,
      .build_gate_tag_mismatches = g_build_gate_tag_mismatches,
      .build_gate_last_tag = g_build_gate_last_tag,
      .build_gate_last_thread = g_build_gate_last_thread,
      .suppressed_build_queued = g_suppressed_builds.queued(),
      .suppressed_build_captured = g_suppressed_builds.captured(),
      .suppressed_build_consumed = g_suppressed_builds.consumed(),
      .suppressed_build_dropped = g_suppressed_builds.dropped(),
      .suppressed_build_last_generation = g_suppressed_builds.last_generation(),
      .suppressed_build_armed_correlation = g_suppressed_builds.armed_correlation(),
      .suppressed_build_last_correlation = g_suppressed_builds.last_correlation(),
      .command_gate_enabled = g_command_gate_enabled,
      .command_gate_tag_mismatches = g_command_gate_tag_mismatches,
      .command_gate_authorizations = g_command_gate_authorizations,
      .command_gate_allowed = g_command_gate_allowed,
      .command_gate_suppressed = g_command_gate_suppressed,
      .command_gate_passthrough = g_command_gate_passthrough,
      .command_gate_calls = g_command_gate_calls,
      .suppressed_game_speed_queued = g_suppressed_game_speeds.size(),
      .suppressed_game_speed_captured = g_suppressed_game_speed_captured,
      .suppressed_game_speed_consumed = g_suppressed_game_speed_consumed,
      .suppressed_game_speed_invalid = g_suppressed_game_speed_invalid,
      .suppressed_game_speed_dropped = g_suppressed_game_speed_dropped,
      .suppressed_game_speed_last = g_suppressed_game_speed_last,
      .suppressed_line_command_queued = g_suppressed_line_commands.size(),
      .suppressed_line_command_captured = g_suppressed_line_command_captured,
      .suppressed_line_command_consumed = g_suppressed_line_command_consumed,
      .suppressed_line_command_invalid = g_suppressed_line_command_invalid,
      .suppressed_line_command_dropped = g_suppressed_line_command_dropped,
      .suppressed_line_command_last_tag = g_suppressed_line_command_last_tag,
      .suppressed_line_command_last_target = g_suppressed_line_command_last_target,
      .suppressed_line_command_last_stop_count = g_suppressed_line_command_last_stop_count,
      .suppressed_vehicle_command_queued = g_suppressed_vehicle_commands.size(),
      .suppressed_vehicle_command_captured = g_suppressed_vehicle_command_captured,
      .suppressed_vehicle_command_consumed = g_suppressed_vehicle_command_consumed,
      .suppressed_vehicle_command_invalid = g_suppressed_vehicle_command_invalid,
      .suppressed_vehicle_command_dropped = g_suppressed_vehicle_command_dropped,
      .suppressed_vehicle_command_last_tag = g_suppressed_vehicle_command_last_tag,
      .suppressed_vehicle_command_last_target = g_suppressed_vehicle_command_last_target,
      .suppressed_vehicle_command_last_secondary = g_suppressed_vehicle_command_last_secondary,
      .states = g_states,
  });
}

void WriteStatusFiles() {
  const auto json = StatusJson();
  std::string error;
  if (!tpf2mp::AtomicWriteUtf8(tpf2mp::NativeStatusPath(GetCurrentProcessId()), json, error, false)) {
    StateLock lock;
    g_last_error = error;
    return;
  }
  // latest.json is intentionally only a convenience for single-process local
  // testing. The PID-specific file is authoritative when multiple instances run.
  std::string ignored;
  tpf2mp::AtomicWriteUtf8(tpf2mp::NativeStatusDirectory() / "latest.json", json, ignored, false);
}

int NativeStatus(lua_State* state) {
  const auto json = StatusJson();
  g_lua_pushlstring(state, json.data(), json.size());
  return 1;
}

int NativeMarkContext(lua_State* state) {
  std::size_t length = 0;
  const char* raw = g_lua_tolstring(state, 1, &length);
  if (raw != nullptr && length <= 64) {
    StateLock lock;
    ObserveStateLocked(state).context.assign(raw, length);
    tpf2mp::launcher::ObserveContext(state, std::string_view(raw, length), tpf2mp::native_binding::RegistrySlot(static_cast<std::size_t>(tpf2mp::native_binding::Index("sendScriptEvent"))), kPendingSendCommandFunction);
  }
  RequestStatusWrite();
  return 0;
}

int NativeEnableBuildGate(lua_State*) {
  {
    StateLock lock;
    g_build_gate_enabled = true;
    g_build_gate_authorizations = 0;
    g_suppressed_builds.ResetPending();
  }
  RequestStatusWrite();
  return 0;
}

int NativeDisableBuildGate(lua_State*) {
  {
    StateLock lock;
    g_build_gate_enabled = false;
    g_build_gate_authorizations = 0;
    g_suppressed_builds.ResetPending();
  }
  RequestStatusWrite();
  return 0;
}

int NativeAuthorizeBuild(lua_State*) {
  {
    StateLock lock;
    if (g_build_gate_enabled && g_build_gate_authorizations < 1024) {
      ++g_build_gate_authorizations;
    }
  }
  RequestStatusWrite();
  return 0;
}

// GUI proposal previews need only three scalar gate values. Serializing the
// complete hook status (including command histories and per-tag counters) on
// every mouse-move callback was substantially more expensive than the game
// preview itself. Keep this ABI deliberately tiny and versioned.
int NativeBuildGateSample(lua_State* state) {
  bool enabled = false;
  std::uint64_t suppressed = 0;
  std::uint64_t tag_mismatches = 0;
  std::uint64_t last_generation = 0;
  std::size_t queued = 0;
  std::uint64_t dropped = 0;
  std::uint64_t armed_correlation = 0;
  {
    StateLock lock;
    enabled = g_build_gate_enabled;
    suppressed = g_build_gate_suppressed;
    tag_mismatches = g_build_gate_tag_mismatches;
    last_generation = g_suppressed_builds.last_generation();
    queued = g_suppressed_builds.queued();
    dropped = g_suppressed_builds.dropped();
    armed_correlation = g_suppressed_builds.armed_correlation();
  }
  const std::string encoded = "B2|" + std::string(enabled ? "1" : "0") + "|" +
                              std::to_string(suppressed) + "|" +
                              std::to_string(tag_mismatches) + "|" +
                              std::to_string(last_generation) + "|" +
                              std::to_string(queued) + "|" +
                              std::to_string(dropped) + "|" +
                              std::to_string(armed_correlation);
  g_lua_pushlstring(state, encoded.data(), encoded.size());
  return 1;
}

int NativeArmBuildCorrelation(lua_State* state) {
  std::size_t length = 0;
  const char* raw = g_lua_tolstring(state, 1, &length);
  std::uint64_t correlation = 0;
  if (raw == nullptr || !tpf2mp::native_build::ParseCorrelationToken(
                            std::string_view(raw, length), correlation)) {
    correlation = 0;
  }
  {
    StateLock lock;
    g_suppressed_builds.Arm(correlation);
  }
  return 0;
}

int NativeTakeSuppressedBuildEvent(lua_State* state) {
  std::optional<std::string> encoded;
  {
    StateLock lock;
    encoded = g_suppressed_builds.TakeEncoded();
  }
  if (!encoded.has_value()) return 0;
  g_lua_pushlstring(state, encoded->data(), encoded->size());
  RequestStatusWrite();
  return 1;
}

// Line records are captured only after their visitor applied, so clearing the
// queue discards mutations this world already has. Counting them as drops
// makes the sticky F1 sentinel report the loss to Lua, which faults closed.
int SetCommandGate(bool enabled) {
  {
    StateLock lock;
    g_command_gate_enabled = enabled;
    g_command_gate_authorizations.fill(0);
    g_suppressed_game_speeds.clear();
    g_suppressed_line_command_dropped += g_suppressed_line_commands.size();
    g_suppressed_line_commands.clear();
    g_suppressed_vehicle_command_dropped += g_suppressed_vehicle_commands.size();
    g_suppressed_vehicle_commands.clear();
  }
  RequestStatusWrite();
  return 0;
}

int NativeEnableCommandGate(lua_State*) { return SetCommandGate(true); }
int NativeDisableCommandGate(lua_State*) { return SetCommandGate(false); }

bool ParseAuthorityCommandTag(lua_State* state, std::size_t& tag) {
  if (g_lua_gettop(state) < 1) return false;
  std::size_t length = 0;
  const char* raw = g_lua_tolstring(state, 1, &length);
  if (raw == nullptr || length == 0 || length > 8) return false;
  std::string value(raw, length);
  char* end = nullptr;
  const long parsed = std::strtol(value.c_str(), &end, 10);
  if (end == value.c_str() || *end != '\0' || parsed < 0 ||
      parsed >= static_cast<long>(kNativeCommandTypeCount) ||
      !IsAuthorityCommandTag(static_cast<int>(parsed))) {
    return false;
  }
  tag = static_cast<std::size_t>(parsed);
  return true;
}

int NativeAuthorizeCommand(lua_State* state) {
  std::size_t tag = 0;
  if (!ParseAuthorityCommandTag(state, tag)) return 0;
  {
    StateLock lock;
    auto& tokens = g_command_gate_authorizations[tag];
    if (g_command_gate_enabled && tokens < kCommandAuthorizationLimit) ++tokens;
  }
  RequestStatusWrite();
  return 0;
}

int NativeRevokeCommand(lua_State* state) {
  std::size_t tag = 0;
  if (!ParseAuthorityCommandTag(state, tag)) return 0;
  {
    StateLock lock;
    auto& tokens = g_command_gate_authorizations[tag];
    if (g_command_gate_enabled && tokens > 0) --tokens;
  }
  RequestStatusWrite();
  return 0;
}

int NativeSetCommandObserver(lua_State* state) {
  if (g_lua_gettop(state) < 1) return 0;
  // Keep the callback in the registry belonging to this exact Lua state. The
  // mod supplies a no-throw callback; avoiding a cross-state/global pointer is
  // essential because Transport Fever 2 owns separate GUI and engine states.
  g_lua_pushvalue(state, 1);
  g_lua_rawseti(state, kLuaRegistryIndex, kCommandObserverFunction);
  {
    StateLock lock;
    ObserveStateLocked(state).command_observer_registered = true;
  }
  RequestStatusWrite();
  return 0;
}

int NativeTakeSuppressedGameSpeed(lua_State* state) {
  std::int32_t speed = -1;
  {
    StateLock lock;
    if (g_suppressed_game_speeds.empty()) return 0;
    speed = g_suppressed_game_speeds.front();
    g_suppressed_game_speeds.pop_front();
    ++g_suppressed_game_speed_consumed;
  }
  const auto text = std::to_string(speed);
  g_lua_pushlstring(state, text.data(), text.size());
  RequestStatusWrite();
  return 1;
}

int NativeTakeSuppressedLineCommand(lua_State* state) {
  std::string encoded;
  {
    StateLock lock;
    if (g_suppressed_line_command_drops_reported < g_suppressed_line_command_dropped) {
      g_suppressed_line_command_drops_reported = g_suppressed_line_command_dropped;
      encoded = "F1|queue-overflow|" + std::to_string(g_suppressed_line_command_dropped);
    } else {
      if (g_suppressed_line_commands.empty()) return 0;
      encoded = EncodeSuppressedLineCommand(g_suppressed_line_commands.front());
      g_suppressed_line_commands.pop_front();
      ++g_suppressed_line_command_consumed;
    }
  }
  g_lua_pushlstring(state, encoded.data(), encoded.size());
  RequestStatusWrite();
  return 1;
}

int NativeTakeSuppressedVehicleCommand(lua_State* state) {
  std::string encoded;
  {
    StateLock lock;
    if (g_suppressed_vehicle_command_drops_reported < g_suppressed_vehicle_command_dropped) {
      g_suppressed_vehicle_command_drops_reported =
          g_suppressed_vehicle_command_dropped;
      encoded = "F1|queue-overflow|" +
                std::to_string(g_suppressed_vehicle_command_dropped);
    } else {
      if (g_suppressed_vehicle_commands.empty()) return 0;
      encoded = EncodeSuppressedVehicleCommand(
          g_suppressed_vehicle_commands.front());
      g_suppressed_vehicle_commands.pop_front();
      ++g_suppressed_vehicle_command_consumed;
    }
  }
  g_lua_pushlstring(state, encoded.data(), encoded.size());
  RequestStatusWrite();
  return 1;
}

int NativeSuppressedPendingMask(lua_State* state) {
  std::uint32_t mask = 0;
  {
    StateLock lock;
    if (!g_suppressed_game_speeds.empty()) mask |= 1;
    if (!g_suppressed_line_commands.empty() || g_suppressed_line_command_drops_reported < g_suppressed_line_command_dropped) mask |= 2;
    if (!g_suppressed_vehicle_commands.empty() || g_suppressed_vehicle_command_drops_reported < g_suppressed_vehicle_command_dropped) mask |= 4;
    if (g_suppressed_builds.has_pending()) mask |= 8;
  }
  if (mask == 0) return 0; const auto text = std::to_string(mask);
  g_lua_pushlstring(state, text.data(), text.size()); return 1;
}

void RegisterNativeFunction(lua_State* state, const char* name, LuaCFunction function) {
  g_lua_pushlstring(state, name, std::strlen(name));
  g_lua_pushcclosure(state, function, 0);
  g_lua_rawset(state, -3);
}

void RegisterNativeApi(lua_State* state) {
  {
    StateLock lock;
    auto& observed = ObserveStateLocked(state);
    if (observed.native_api_registered) return;
    observed.native_api_registered = true;
  }
  g_native_registration = true;
  g_lua_rawgeti(state, kLuaRegistryIndex, kLuaGlobalsRegistryIndex);
  RegisterNativeFunction(state, "tpf2mp_native_status", NativeStatus);
  tpf2mp::async_bridge::RegisterLuaApi(state, g_lua_pushlstring, g_lua_tolstring, g_lua_gettop, g_lua_pushcclosure, g_lua_rawset);
  tpf2mp::launcher::RegisterBootstrapApi(state, g_lua_pushlstring, g_lua_pushcclosure, g_lua_rawset, g_lua_rawgeti, g_lua_insert, g_lua_callk, g_lua_gettop, g_lua_settop);
  RegisterNativeFunction(state, "tpf2mp_native_mark_context", NativeMarkContext); RegisterNativeFunction(state, "tpf2mp_native_enable_build_gate", NativeEnableBuildGate);
  RegisterNativeFunction(state, "tpf2mp_native_disable_build_gate", NativeDisableBuildGate); RegisterNativeFunction(state, "tpf2mp_native_authorize_build", NativeAuthorizeBuild);
  RegisterNativeFunction(state, "tpf2mp_native_build_gate_sample", NativeBuildGateSample);
  RegisterNativeFunction(state, "tpf2mp_native_arm_build_correlation", NativeArmBuildCorrelation); RegisterNativeFunction(state, "tpf2mp_native_take_suppressed_build", NativeTakeSuppressedBuildEvent);
  RegisterNativeFunction(state, "tpf2mp_native_enable_command_gate", NativeEnableCommandGate); RegisterNativeFunction(state, "tpf2mp_native_disable_command_gate", NativeDisableCommandGate);
  RegisterNativeFunction(state, "tpf2mp_native_authorize_command", NativeAuthorizeCommand); RegisterNativeFunction(state, "tpf2mp_native_revoke_command", NativeRevokeCommand);
  RegisterNativeFunction(state, "tpf2mp_native_set_command_observer", NativeSetCommandObserver); RegisterNativeFunction(state, "tpf2mp_native_take_suppressed_game_speed", NativeTakeSuppressedGameSpeed);
  RegisterNativeFunction(state, "tpf2mp_native_take_suppressed_line_command", NativeTakeSuppressedLineCommand); RegisterNativeFunction(state, "tpf2mp_native_take_suppressed_vehicle_command", NativeTakeSuppressedVehicleCommand);
  RegisterNativeFunction(state, "tpf2mp_native_suppressed_pending_mask", NativeSuppressedPendingMask);
  // Keep the old optimistic-line symbol for rolling-development compatibility.
  RegisterNativeFunction(state, "tpf2mp_native_take_line_command", NativeTakeSuppressedLineCommand);
  g_lua_settop(state, -2); // pop the global table; restore caller stack
  g_native_registration = false;
  RequestStatusWrite();
}

int SendCommandObserver(lua_State* state) {
  BootTrace("send-command-called");
  const int argument_count = g_lua_gettop(state);
  {
    StateLock lock;
    auto& observation = ObserveStateLocked(state);
    ++observation.command_calls;
    observation.last_command_argument_count = argument_count;
    observation.last_command_thread = GetCurrentThreadId();
  }
  RequestStatusWrite();

  bool notify_observer = false;
  {
    StateLock lock;
    notify_observer = ObserveStateLocked(state).command_observer_registered;
  }
  if (notify_observer && argument_count >= 1) {
    // The callback sees the original command before api.cmd.sendCommand can
    // enqueue or commit it. It must not throw; the Lua side wraps all capture
    // work in pcall and never calls sendCommand recursively.
    g_lua_rawgeti(state, kLuaRegistryIndex, kCommandObserverFunction);
    g_lua_pushvalue(state, 1);
    g_lua_callk(state, 1, 0, 0, nullptr);
  }

  // The original Lua/sol closure is upvalue 1. Move it below all arguments,
  // call it normally, and return exactly the values it returned.
  g_lua_pushvalue(state, kFirstUpvalueIndex);
  g_lua_insert(state, 1);
  g_lua_callk(state, argument_count, kLuaMultiReturn, 0, nullptr);
  return g_lua_gettop(state);
}

int DetourLuaPrint(lua_State* state) {
  {
    StateLock lock;
    ++ObserveStateLocked(state).print_calls;
  }
  const int result = g_original_print(state);
  RegisterNativeApi(state);
  RequestStatusWrite();
  return result;
}

void DetourLuaSetField(lua_State* state, int index, const char* key) {
  const int binding_index = tpf2mp::native_binding::Index(key);
  const bool has_stack_value = g_lua_gettop(state) >= 1;
  const bool capture_binding = binding_index > 0 && !g_native_registration &&
                               g_setup_command_depth > 0 && has_stack_value;
  const bool capture_send_command = binding_index == 0 && !g_native_registration &&
                                    g_setup_command_depth > 0 && has_stack_value;
  {
    StateLock lock;
    auto& observed = ObserveStateLocked(state);
    ++observed.setfield_calls;
    if (binding_index >= 0) observed.interesting_bindings.emplace(key);
  }
  if (capture_binding) {
    // Root a copy in this Lua state's registry while sol2 is constructing the
    // API table. It is mirrored into a namespaced global only after the full
    // setup routine returns, avoiding the binding-library re-entrancy that an
    // immediate table replacement caused in the first prototype.
    g_lua_pushvalue(state, -1);
    g_lua_rawseti(state, kLuaRegistryIndex,
                  tpf2mp::native_binding::RegistrySlot(static_cast<std::size_t>(binding_index)));
    g_pending_binding_state = state;
    g_pending_binding_mask |= std::uint64_t{1} << static_cast<unsigned>(binding_index);
  }
  if (capture_send_command) {
    // sol2 examines the closure while SetupCommandInterface is still building
    // the API table. Preserve both values in this state's registry, let the
    // original assignment complete untouched, and replace it only after the
    // entire setup routine has returned on the same owning thread.
    const int top = g_lua_gettop(state);
    int absolute_index = index;
    if (index < 0 && index > kLuaRegistryIndex) absolute_index = top + index + 1;
    g_lua_pushvalue(state, -1);
    g_lua_rawseti(state, kLuaRegistryIndex, kPendingSendCommandFunction);
    g_lua_pushvalue(state, absolute_index);
    g_lua_rawseti(state, kLuaRegistryIndex, kPendingSendCommandTable);
    g_pending_send_command_state = state;
    g_original_setfield(state, index, key);
    BootTrace("send-command-captured");
    RequestStatusWrite();
    return;
  }
  g_original_setfield(state, index, key);
  if (binding_index >= 0) RequestStatusWrite();
}

void InstallDeferredNativeBindings() {
  lua_State* state = g_pending_binding_state;
  const std::uint64_t mask = g_pending_binding_mask;
  g_pending_binding_state = nullptr;
  g_pending_binding_mask = 0;
  if (state == nullptr || mask == 0) return;

  const int original_top = g_lua_gettop(state);
  g_lua_rawgeti(state, kLuaRegistryIndex, kLuaGlobalsRegistryIndex);
  std::vector<std::string> mirrored;
  for (std::size_t index = 1; index < tpf2mp::native_binding::Count(); ++index) {
    if ((mask & (std::uint64_t{1} << index)) == 0) continue;
    const auto global_name = tpf2mp::native_binding::GlobalName(tpf2mp::native_binding::At(index));
    g_lua_pushlstring(state, global_name.data(), global_name.size());
    g_lua_rawgeti(state, kLuaRegistryIndex, tpf2mp::native_binding::RegistrySlot(index));
    g_lua_rawset(state, -3);
    mirrored.emplace_back(tpf2mp::native_binding::At(index));
  }
  g_lua_settop(state, original_top);
  {
    StateLock lock;
    auto& observation = ObserveStateLocked(state);
    observation.mirrored_bindings.insert(mirrored.begin(), mirrored.end());
  }
  BootTrace("native-bindings-mirrored-deferred");
  RequestStatusWrite();
}

void InstallDeferredSendCommandWrapper() {
  lua_State* state = g_pending_send_command_state;
  g_pending_send_command_state = nullptr;
  if (state == nullptr) return;

  const int original_top = g_lua_gettop(state);
  g_lua_rawgeti(state, kLuaRegistryIndex, kPendingSendCommandTable);
  g_lua_rawgeti(state, kLuaRegistryIndex, kPendingSendCommandFunction);
  g_lua_pushcclosure(state, SendCommandObserver, 1); // consumes original function
  g_original_setfield(state, -2, "sendCommand");   // consumes wrapper
  g_lua_settop(state, original_top);
  {
    StateLock lock;
    ObserveStateLocked(state).send_command_wrapped = true;
  }
  BootTrace("send-command-wrapped-deferred");
  RequestStatusWrite();
}

std::uintptr_t DetourSetupCommandInterface(void* first, void* second, void* third, void* fourth) {
  {
    StateLock lock;
    ++g_setup_calls;
    g_setup_last_thread = GetCurrentThreadId();
    g_setup_last_args = {tpf2mp::HexPointer(first), tpf2mp::HexPointer(second),
                         tpf2mp::HexPointer(third), tpf2mp::HexPointer(fourth)};
  }
  RequestStatusWrite();
  ++g_setup_command_depth;
  const auto result = g_original_setup_command(first, second, third, fourth);
  --g_setup_command_depth;
  BootTrace("setup-command-returned");
  if (g_setup_command_depth == 0) {
    InstallDeferredSendCommandWrapper();
    InstallDeferredNativeBindings();
  }
  return result;
}

void DetourCommandListSwap(void* owner, void* raw_output) {
  g_original_command_list_swap(owner, raw_output);

  std::uint64_t batch_count = 0;
  std::uint64_t unknown_tags = 0;
  bool valid_layout = IsReadableRange(raw_output, sizeof(NativeVectorLayout));
  std::array<std::uint64_t, kNativeCommandTypeCount> local_tags{};
  std::vector<std::pair<const void*, int>> local_commands;
  if (valid_layout) {
    const auto layout = *static_cast<const NativeVectorLayout*>(raw_output);
    const auto begin = reinterpret_cast<std::uintptr_t>(layout.begin);
    const auto end = reinterpret_cast<std::uintptr_t>(layout.end);
    const auto capacity = reinterpret_cast<std::uintptr_t>(layout.capacity);
    if (begin == 0 && end == 0 && capacity == 0) {
      batch_count = 0;
    } else if (begin == 0 || end < begin || capacity < end ||
               (end - begin) % kNativeCommandSize != 0) {
      valid_layout = false;
    } else {
      batch_count = (end - begin) / kNativeCommandSize;
      // A player-command queue should be tiny. This guard prevents a bad
      // reverse-engineered layout from turning into a long memory walk.
      if (batch_count > 100'000 ||
          !IsReadableRange(layout.begin, static_cast<std::size_t>(end - begin))) {
        valid_layout = false;
        batch_count = 0;
      } else {
        local_commands.reserve(static_cast<std::size_t>(batch_count));
        for (std::uint64_t index = 0; index < batch_count; ++index) {
          const auto* command = layout.begin + index * kNativeCommandSize;
          const int tag = NativeCommandTag(command);
          local_commands.emplace_back(command, tag);
          if (tag >= 0) {
            ++local_tags[static_cast<std::size_t>(tag)];
          } else {
            ++unknown_tags;
          }
        }
      }
    }
  }

  {
    StateLock lock;
    ++g_command_swap_calls;
    g_command_swap_last_thread = GetCurrentThreadId();
    g_command_last_batch = batch_count;
    if (!valid_layout) {
      ++g_command_invalid_layouts;
    } else {
      if (batch_count != 0) ++g_command_nonempty_batches;
      g_command_queued += batch_count;
      g_command_unknown_tags += unknown_tags;
      if (batch_count != 0) {
        const auto batch_id = g_command_next_batch_id++;
        g_command_last_batch_id = batch_id;
        for (std::size_t index = 0; index < local_commands.size(); ++index) {
          const auto [command, tag] = local_commands[index];
          PendingNativeCommand pending{
              g_command_next_local_sequence++, batch_id, index, tag, GetCurrentThreadId()};
          const auto [_, inserted] = g_pending_commands.insert_or_assign(command, pending);
          if (!inserted) ++g_command_pending_overwrites;
        }
      }
      for (std::size_t tag = 0; tag < local_tags.size(); ++tag) {
        g_queued_tags[tag] += local_tags[tag];
      }
    }
  }
  if (batch_count != 0 || !valid_layout || unknown_tags != 0) RequestStatusWrite();
}

void DetourApplyCommand(void* context, void* command) {
  const int tag = NativeCommandTag(command);
  PendingNativeCommand pending{};
  {
    StateLock lock;
    const auto found = g_pending_commands.find(command);
    if (found == g_pending_commands.end()) {
      pending = {g_command_next_local_sequence++, 0, 0, tag, 0};
      ++g_apply_direct;
    } else {
      pending = found->second;
      g_pending_commands.erase(found);
      if (pending.tag != tag) ++g_apply_tag_mismatches;
    }
  }
  g_original_apply_command(context, command);

  int success = -1;
  if (command != nullptr) {
    const auto* success_pointer = static_cast<const std::uint8_t*>(command) +
                                  kNativeCommandSuccessOffset;
    if (IsReadableRange(success_pointer, sizeof(std::uint8_t))) {
      success = *success_pointer == 0 ? 0 : 1;
    }
  }
  bool wake_status_writer = false;
  {
    StateLock lock;
    ++g_apply_calls;
    wake_status_writer = g_apply_calls <= 4 || (g_apply_calls % 64) == 0;
    g_apply_last_tag = tag;
    g_apply_last_thread = GetCurrentThreadId();
    if (tag >= 0) {
      ++g_applied_tags[static_cast<std::size_t>(tag)];
    } else {
      ++g_apply_unknown_tags;
    }
    if (success > 0) {
      ++g_apply_succeeded;
    } else if (success == 0) {
      ++g_apply_failed;
    } else {
      ++g_apply_unknown;
    }
    const CompletedNativeCommand completed{pending, GetCurrentThreadId(), success};
    g_recent_completed_commands.push_back(completed);
    while (g_recent_completed_commands.size() > kNativeRecentCommandEventLimit) {
      g_recent_completed_commands.pop_front();
    }
    if (pending.tag == 32) {
      ++g_apply_filtered_script_events;
    } else {
      g_completed_commands.push_back(completed);
      while (g_completed_commands.size() > kNativeCommandEventLimit) {
        g_completed_commands.pop_front();
      }
    }
  }
  // Preserve the final burst counter; only the expensive wake-up is sampled.
  g_status_dirty.store(true, std::memory_order_release); if (wake_status_writer && g_status_event != nullptr) SetEvent(g_status_event);
}

bool DetourBuildProposalVisitor(void* visitor_context, void* build_proposal) {
  bool suppress = false;
  {
    StateLock lock;
    ++g_build_gate_calls;
    g_build_gate_last_thread = GetCurrentThreadId();
    g_build_gate_last_tag = NativeCommandDataTag(build_proposal);
    const bool tag_mismatch = g_build_gate_last_tag != 15;
    if (tag_mismatch) {
      ++g_build_gate_tag_mismatches;
      g_last_error = "BuildProposal visitor tag mismatch; expected 15, observed " +
                     std::to_string(g_build_gate_last_tag);
    }
    if (g_build_gate_enabled) {
      if (tag_mismatch) {
        ++g_build_gate_suppressed;
        g_suppressed_builds.Capture(g_build_gate_last_tag);
        suppress = true;
      } else if (g_build_gate_authorizations > 0) {
        --g_build_gate_authorizations;
        ++g_build_gate_allowed;
      } else {
        ++g_build_gate_suppressed;
        g_suppressed_builds.Capture(g_build_gate_last_tag);
        suppress = true;
      }
    }
  }
  RequestStatusWrite();
  if (suppress) return false;
  return g_original_build_proposal_visitor(visitor_context, build_proposal);
}

template <std::size_t Tag>
bool DetourAuthorityCommandVisitor(void* visitor_context, void* command_data) {
  static_assert(Tag < kNativeCommandTypeCount);
  bool suppress = false;
  bool gate_observed = false;
  bool optimistic_line_passthrough = false;
  SuppressedLineCommand optimistic_line_command;
  {
    StateLock lock;
    ++g_command_gate_calls[Tag];
    const bool tag_mismatch =
        NativeCommandDataTag(command_data) != static_cast<int>(Tag);
    if (tag_mismatch) {
      ++g_command_gate_tag_mismatches;
      g_last_error = "authority command visitor tag mismatch at visitor " +
                     std::to_string(Tag);
    }
    gate_observed = g_command_gate_enabled;
    if (g_command_gate_enabled) {
      if (tag_mismatch) {
        ++g_command_gate_suppressed[Tag];
        suppress = true;
      } else if (g_command_gate_authorizations[Tag] > 0) {
        --g_command_gate_authorizations[Tag];
        ++g_command_gate_allowed[Tag];
      } else {
        if constexpr ((Tag >= 3 && Tag <= 5) || Tag == 28 || Tag == 29) {
          // Vanilla's Line Manager callback immediately dereferences the
          // command result (notably the entity created by New Line). Returning
          // false here does not merely reject the click: Build 35924 feeds an
          // invalid EntityRev into that callback and asserts. Decode first and
          // allow only exact pinned-layout line/name/color commands to complete locally;
          // Lua binds the local result to the ordered canonical operation and
          // the other peer replays it with a normal one-shot authorization.
          if (!tag_mismatch && DecodeSuppressedLineCommand(
                static_cast<int>(Tag), command_data, optimistic_line_command)) {
            optimistic_line_passthrough = true;
            ++g_command_gate_passthrough[Tag];
          } else {
            ++g_command_gate_suppressed[Tag];
            ++g_suppressed_line_command_invalid;
            g_last_error = "optimistic " + std::string(CommandTypeName(static_cast<int>(Tag))) +
                           " payload did not match the pinned Build 35924 layout";
            suppress = true;
          }
        } else {
          ++g_command_gate_suppressed[Tag];
          suppress = true;
        }
      }
      if constexpr (Tag == 0) {
        if (suppress && !tag_mismatch) {
          const auto* value = static_cast<const std::uint8_t*>(command_data) +
                              tpf2mp::profile::kSetGameSpeedValueOffset;
          if (IsReadableRange(value, sizeof(std::int32_t))) {
            std::int32_t speed = -1;
            std::memcpy(&speed, value, sizeof(speed));
            if (speed >= tpf2mp::profile::kSetGameSpeedMinimum &&
                speed <= tpf2mp::profile::kSetGameSpeedMaximum) {
              if (g_suppressed_game_speeds.size() >= kSuppressedGameSpeedQueueLimit) {
                g_suppressed_game_speeds.pop_front();
                ++g_suppressed_game_speed_dropped;
              }
              g_suppressed_game_speeds.push_back(speed);
              g_suppressed_game_speed_last = speed;
              ++g_suppressed_game_speed_captured;
            } else {
              ++g_suppressed_game_speed_invalid;
            }
          } else {
            ++g_suppressed_game_speed_invalid;
          }
        }
      }
      if constexpr (Tag == 6 || Tag == 7 || Tag == 8 || Tag == 9 || Tag == 10 ||
                    Tag == 11 || Tag == 12 || Tag == 13 || Tag == 14 || Tag == 30) {
        if (suppress && !tag_mismatch) {
          tpf2mp::native_command::SuppressedVehicleCommand command;
          if (DecodeSuppressedVehicleCommand(static_cast<int>(Tag), command_data, command)) {
            if (g_suppressed_vehicle_commands.size() >=
                kSuppressedVehicleCommandQueueLimit) {
              g_suppressed_vehicle_commands.pop_front();
              ++g_suppressed_vehicle_command_dropped;
            }
            g_suppressed_vehicle_command_last_tag = command.tag;
            g_suppressed_vehicle_command_last_target = command.target;
            g_suppressed_vehicle_command_last_secondary = command.secondary;
            g_suppressed_vehicle_commands.push_back(command);
            ++g_suppressed_vehicle_command_captured;
          } else {
            ++g_suppressed_vehicle_command_invalid;
            g_last_error = "suppressed " +
                           std::string(CommandTypeName(static_cast<int>(Tag))) +
                           " payload did not match the pinned Build 35924 layout";
          }
        }
      }
    }
  }
  if (gate_observed) RequestStatusWrite();
  if (suppress) return false;
  const auto original = g_original_authority_visitors[Tag];
  if (original == nullptr) {
    StateLock lock;
    g_last_error = "authority command visitor original is unavailable for tag " +
                   std::to_string(Tag);
    return false;
  }
  const bool result = original(visitor_context, command_data);
  if (optimistic_line_passthrough && result) {
    {
      StateLock lock;
      if (g_suppressed_line_commands.size() >= kSuppressedLineCommandQueueLimit) {
        g_suppressed_line_commands.pop_front();
        ++g_suppressed_line_command_dropped;
      }
      g_suppressed_line_command_last_tag = optimistic_line_command.tag;
      g_suppressed_line_command_last_target = optimistic_line_command.target;
      g_suppressed_line_command_last_stop_count = optimistic_line_command.stops.size();
      g_suppressed_line_commands.push_back(std::move(optimistic_line_command));
      ++g_suppressed_line_command_captured;
    }
    RequestStatusWrite();
  }
  return result;
}

AuthorityCommandVisitor AuthorityDetourForTag(const int tag) {
  switch (tag) {
    case 0: return DetourAuthorityCommandVisitor<0>;
    case 1: return DetourAuthorityCommandVisitor<1>;
    case 2: return DetourAuthorityCommandVisitor<2>;
    case 3: return DetourAuthorityCommandVisitor<3>;
    case 4: return DetourAuthorityCommandVisitor<4>;
    case 5: return DetourAuthorityCommandVisitor<5>;
    case 6: return DetourAuthorityCommandVisitor<6>;
    case 7: return DetourAuthorityCommandVisitor<7>;
    case 8: return DetourAuthorityCommandVisitor<8>;
    case 9: return DetourAuthorityCommandVisitor<9>;
    case 10: return DetourAuthorityCommandVisitor<10>;
    case 11: return DetourAuthorityCommandVisitor<11>;
    case 12: return DetourAuthorityCommandVisitor<12>;
    case 13: return DetourAuthorityCommandVisitor<13>;
    case 14: return DetourAuthorityCommandVisitor<14>;
    case 16: return DetourAuthorityCommandVisitor<16>;
    case 17: return DetourAuthorityCommandVisitor<17>;
    case 18: return DetourAuthorityCommandVisitor<18>;
    case 19: return DetourAuthorityCommandVisitor<19>;
    case 20: return DetourAuthorityCommandVisitor<20>;
    case 21: return DetourAuthorityCommandVisitor<21>;
    case 22: return DetourAuthorityCommandVisitor<22>;
    case 23: return DetourAuthorityCommandVisitor<23>;
    case 24: return DetourAuthorityCommandVisitor<24>;
    case 25: return DetourAuthorityCommandVisitor<25>;
    case 26: return DetourAuthorityCommandVisitor<26>;
    case 28: return DetourAuthorityCommandVisitor<28>;
    case 29: return DetourAuthorityCommandVisitor<29>;
    case 30: return DetourAuthorityCommandVisitor<30>;
    case 33: return DetourAuthorityCommandVisitor<33>;
    case 36: return DetourAuthorityCommandVisitor<36>;
    default: return nullptr;
  }
}

template <typename Function>
Function AtRva(HMODULE module, const std::uint32_t rva) {
  return reinterpret_cast<Function>(reinterpret_cast<std::uint8_t*>(module) + rva);
}

std::uint32_t ValidatedRva(const std::string_view name) {
  for (const auto& signature : g_validation.signatures) {
    if (signature.name == name && signature.matches == 1 && signature.expected_bytes_match) {
      return signature.observed_rva;
    }
  }
  return 0;
}

bool CreateHook(void* target, void* detour, void** original, bool& flag, const char* name) {
  const auto status = MH_CreateHook(target, detour, original);
  if (status != MH_OK) {
    StateLock lock;
    g_last_error = std::string("MH_CreateHook(") + name + ") failed: " + MH_StatusToString(status);
    return false;
  }
  flag = true;
  return true;
}

bool ValidateAuthorityVisitorTable(HMODULE executable) {
  const auto table = AtRva<AuthorityCommandVisitor*>(
      executable, tpf2mp::profile::kCommandVisitorTableRva);
  if (!IsReadableRange(table,
                       sizeof(AuthorityCommandVisitor) *
                           tpf2mp::profile::kCommandVisitorCount)) {
    StateLock lock;
    g_last_error = "command visitor table is unreadable";
    return false;
  }
  for (const auto& visitor : tpf2mp::profile::kAuthorityCommandVisitors) {
    if (visitor.tag >= tpf2mp::profile::kCommandVisitorCount ||
        table[visitor.tag] != AtRva<AuthorityCommandVisitor>(executable, visitor.rva)) {
      StateLock lock;
      g_last_error = "command visitor table mismatch for tag " +
                     std::to_string(visitor.tag);
      return false;
    }
  }
  return true;
}

bool InstallHooks(HMODULE executable) {
  constexpr std::array<std::string_view, 17> required_signatures{
      "luaB_print",          "lua_setfield", "SetupCommandInterface", "lua_pushcclosure",
      "lua_pushvalue",       "lua_insert",   "lua_callk",              "lua_gettop",
      "lua_settop",          "lua_rawgeti",  "lua_rawseti",            "lua_rawset",
      "lua_pushlstring",     "lua_tolstring", "CommandList::Swap",      "ApplyCommand",
      "BuildProposalVisitor",
  };
  for (const auto name : required_signatures) {
    if (ValidatedRva(name) == 0) {
      StateLock lock;
      g_last_error = "validated signature is unavailable: " + std::string(name);
      return false;
    }
  }
  if (!ValidateAuthorityVisitorTable(executable)) return false;
  const auto status = MH_Initialize();
  if (status != MH_OK) {
    StateLock lock;
    g_last_error = std::string("MH_Initialize failed: ") + MH_StatusToString(status);
    return false;
  }
  g_hooks.minhook_initialised = true;

  const auto print_target = AtRva<void*>(executable, ValidatedRva("luaB_print"));
  const auto setfield_target = AtRva<void*>(executable, ValidatedRva("lua_setfield"));
  const auto setup_target = AtRva<void*>(executable, ValidatedRva("SetupCommandInterface"));
  const auto command_list_swap_target =
      AtRva<void*>(executable, ValidatedRva("CommandList::Swap"));
  const auto apply_command_target = AtRva<void*>(executable, ValidatedRva("ApplyCommand"));
  const auto build_proposal_visitor_target =
      AtRva<void*>(executable, ValidatedRva("BuildProposalVisitor"));
  if (!CreateHook(print_target, reinterpret_cast<void*>(DetourLuaPrint),
                  reinterpret_cast<void**>(&g_original_print), g_hooks.lua_print_created, "luaB_print") ||
      !CreateHook(setfield_target, reinterpret_cast<void*>(DetourLuaSetField),
                  reinterpret_cast<void**>(&g_original_setfield), g_hooks.lua_setfield_created, "lua_setfield") ||
      !CreateHook(setup_target, reinterpret_cast<void*>(DetourSetupCommandInterface),
                  reinterpret_cast<void**>(&g_original_setup_command), g_hooks.setup_command_created,
                  "SetupCommandInterface") ||
      !CreateHook(command_list_swap_target, reinterpret_cast<void*>(DetourCommandListSwap),
                  reinterpret_cast<void**>(&g_original_command_list_swap),
                  g_hooks.command_list_swap_created, "CommandList::Swap") ||
      !CreateHook(apply_command_target, reinterpret_cast<void*>(DetourApplyCommand),
                  reinterpret_cast<void**>(&g_original_apply_command),
                  g_hooks.apply_command_created, "ApplyCommand") ||
      !CreateHook(build_proposal_visitor_target,
                  reinterpret_cast<void*>(DetourBuildProposalVisitor),
                  reinterpret_cast<void**>(&g_original_build_proposal_visitor),
                  g_hooks.build_proposal_visitor_created, "BuildProposalVisitor")) {
    MH_Uninitialize();
    return false;
  }

  for (const auto& visitor : tpf2mp::profile::kAuthorityCommandVisitors) {
    const auto detour = AuthorityDetourForTag(visitor.tag);
    bool created = false;
    const auto hook_name = std::string("CommandVisitor[") + std::to_string(visitor.tag) + "]";
    if (detour == nullptr ||
        !CreateHook(AtRva<void*>(executable, visitor.rva),
                    reinterpret_cast<void*>(detour),
                    reinterpret_cast<void**>(&g_original_authority_visitors[visitor.tag]),
                    created, hook_name.c_str())) {
      MH_Uninitialize();
      return false;
    }
    if (created) ++g_hooks.authority_command_visitors_created;
  }

  g_lua_pushcclosure = AtRva<LuaPushCClosure>(executable, ValidatedRva("lua_pushcclosure"));
  g_lua_pushvalue = AtRva<LuaPushValue>(executable, ValidatedRva("lua_pushvalue"));
  g_lua_insert = AtRva<LuaInsert>(executable, ValidatedRva("lua_insert"));
  g_lua_callk = AtRva<LuaCallK>(executable, ValidatedRva("lua_callk"));
  g_lua_gettop = AtRva<LuaGetTop>(executable, ValidatedRva("lua_gettop"));
  g_lua_settop = AtRva<LuaSetTop>(executable, ValidatedRva("lua_settop"));
  g_lua_rawgeti = AtRva<LuaRawGetI>(executable, ValidatedRva("lua_rawgeti"));
  g_lua_rawseti = AtRva<LuaRawSetI>(executable, ValidatedRva("lua_rawseti"));
  g_lua_rawset = AtRva<LuaRawSet>(executable, ValidatedRva("lua_rawset"));
  g_lua_pushlstring = AtRva<LuaPushLString>(executable, ValidatedRva("lua_pushlstring"));
  g_lua_tolstring = AtRva<LuaToLString>(executable, ValidatedRva("lua_tolstring"));

  MH_QueueEnableHook(print_target);
  MH_QueueEnableHook(setfield_target);
  MH_QueueEnableHook(setup_target);
  MH_QueueEnableHook(command_list_swap_target);
  MH_QueueEnableHook(apply_command_target);
  MH_QueueEnableHook(build_proposal_visitor_target);
  for (const auto& visitor : tpf2mp::profile::kAuthorityCommandVisitors) {
    MH_QueueEnableHook(AtRva<void*>(executable, visitor.rva));
  }
  const auto apply = MH_ApplyQueued();
  if (apply != MH_OK) {
    StateLock lock;
    g_last_error = std::string("MH_ApplyQueued failed: ") + MH_StatusToString(apply);
    MH_Uninitialize();
    return false;
  }
  g_hooks.enabled = true;
  return true;
}

DWORD WINAPI Worker(void*) {
  BootTrace("worker-enter");
  // A LoadLibrary worker can be scheduled while the process is still leaving
  // its initial loader phase. Keep the first CRT-heavy work out of that window.
  Sleep(250);
  BootTrace("worker-after-startup-delay");
  {
    BootTrace("worker-before-state-lock");
    StateLock lock;
    wchar_t dll_path[32768]{};
    const DWORD dll_path_length =
        GetModuleFileNameW(g_dll, dll_path, static_cast<DWORD>(std::size(dll_path)));
    if (dll_path_length > 0 && dll_path_length < std::size(dll_path)) {
      g_dll_path = std::wstring(dll_path, dll_path_length);
    }
    g_stage = "validating";
  }
  BootTrace("worker-before-initial-status");
  WriteStatusFiles();
  BootTrace("worker-validating");

  HMODULE executable = GetModuleHandleW(nullptr);
  auto validation = tpf2mp::ValidatePinnedModule(executable);
  {
    StateLock lock;
    g_validation = std::move(validation);
    if (!g_validation.valid) {
      g_stage = "rejected";
      g_last_error = g_validation.error;
    }
  }
  if (!g_validation.valid) {
    WriteStatusFiles();
    BootTrace("worker-rejected");
    return 2;
  }

  if (!InstallHooks(executable)) {
    {
      StateLock lock;
      g_stage = "hook-error";
    }
    WriteStatusFiles();
    BootTrace("worker-hook-error");
    return 3;
  }
  {
    StateLock lock;
    g_stage = "active";
  }
  WriteStatusFiles();
  BootTrace("worker-active");

  while (!g_stop.load(std::memory_order_acquire)) {
    WaitForSingleObject(g_status_event, 10);
    tpf2mp::async_bridge::Global().Pump();
    static ULONGLONG last_status_write = 0;
    const auto now = GetTickCount64();
    if (g_status_dirty.load(std::memory_order_acquire) && now - last_status_write >= 1000) {
      g_status_dirty.store(false, std::memory_order_release); WriteStatusFiles();
      last_status_write = now;
    }
  }
  return 0;
}

} // namespace

extern "C" __declspec(dllexport) const char* TPF2MP_HookProfile() {
  return "Transport Fever 2 Build 35924 / tpf2mp native hook 0.19.0";
}

BOOL WINAPI DllMain(HINSTANCE instance, DWORD reason, LPVOID) {
  if (reason == DLL_PROCESS_ATTACH) {
    BootTrace("dllmain-attach");
    g_dll = instance;
    DisableThreadLibraryCalls(instance);
    g_status_event = CreateEventW(nullptr, FALSE, FALSE, nullptr);
    if (g_status_event == nullptr) return FALSE;
    HANDLE worker = CreateThread(nullptr, 0, Worker, nullptr, 0, nullptr);
    if (worker == nullptr) {
      CloseHandle(g_status_event);
      g_status_event = nullptr;
      return FALSE;
    }
    CloseHandle(worker);
  } else if (reason == DLL_PROCESS_DETACH) {
    g_stop.store(true, std::memory_order_release);
    if (g_status_event != nullptr) SetEvent(g_status_event);
    // The injector never unloads the DLL. During normal process termination,
    // Windows is already tearing down every thread/module, so doing MinHook or
    // CRT cleanup under the loader lock would be less safe than leaving it.
  }
  return TRUE;
}
