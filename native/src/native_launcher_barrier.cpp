#include "tpf2mp/native_launcher_barrier.hpp"

#include <Windows.h>

#include <atomic>
#include <filesystem>
#include <fstream>
#include <iterator>
#include <string>
#include <string_view>

namespace {

std::atomic<tpf2mp::launcher::LuaPushLString> g_push_string{nullptr};
std::atomic<tpf2mp::launcher::LuaRawGetI> g_raw_get_i{nullptr};
std::atomic<tpf2mp::launcher::LuaInsert> g_insert{nullptr};
std::atomic<tpf2mp::launcher::LuaCallK> g_call_k{nullptr};
std::atomic<tpf2mp::launcher::LuaGetTop> g_get_top{nullptr};
std::atomic<tpf2mp::launcher::LuaSetTop> g_set_top{nullptr};
std::atomic<lua_State*> g_pump_target{nullptr};
std::atomic<int> g_script_event_slot{0};
std::atomic<int> g_send_command_slot{0};
std::atomic<std::uint32_t> g_pump_thread{0};
constexpr int kLuaRegistryIndex = -1001000;
constexpr int kUnsetRegistrySlot = -0x54504C50;

bool BootstrapReady() {
  std::wstring bridge_root(32768, L'\0');
  const DWORD length = GetEnvironmentVariableW(
      L"TPF2MP_BRIDGE_DIR", bridge_root.data(),
      static_cast<DWORD>(bridge_root.size()));
  if (length == 0 || length >= bridge_root.size()) return false;
  bridge_root.resize(length);
  const auto marker = std::filesystem::path(bridge_root) /
                      L"launcher" / L"manual-bootstrap-ready";
  std::ifstream input(marker, std::ios::binary);
  if (!input) return false;
  std::string value((std::istreambuf_iterator<char>(input)),
                    std::istreambuf_iterator<char>());
  while (!value.empty() &&
         (value.back() == '\r' || value.back() == '\n' ||
          value.back() == ' ' || value.back() == '\t')) {
    value.pop_back();
  }
  const auto first = value.find_first_not_of(" \t\r\n");
  return first != std::string::npos && value.substr(first) == "ready";
}

int NativeBootstrapReady(lua_State* state) {
  constexpr std::string_view ready = "ready";
  constexpr std::string_view waiting = "waiting";
  const auto value = BootstrapReady() ? ready : waiting;
  const auto push_string = g_push_string.load();
  if (push_string == nullptr) return 0;
  push_string(state, value.data(), value.size());
  return 1;
}

int PushResult(lua_State* state, const std::string_view value) {
  const auto push_string = g_push_string.load();
  if (push_string == nullptr) return 0;
  push_string(state, value.data(), value.size());
  return 1;
}

int NativePump(lua_State* caller) {
  auto* target = g_pump_target.load(std::memory_order_acquire);
  if (target == nullptr || target == caller) return PushResult(caller, "F1|target-unavailable");
  if (g_pump_thread.load(std::memory_order_acquire) != GetCurrentThreadId()) {
    return PushResult(caller, "F1|wrong-thread");
  }
  const auto raw_get_i = g_raw_get_i.load();
  const auto insert = g_insert.load();
  const auto call_k = g_call_k.load();
  const auto get_top = g_get_top.load();
  const auto set_top = g_set_top.load();
  const auto push_string = g_push_string.load();
  const int event_slot = g_script_event_slot.load();
  const int send_slot = g_send_command_slot.load();
  if (raw_get_i == nullptr || insert == nullptr || call_k == nullptr ||
      get_top == nullptr || set_top == nullptr || push_string == nullptr ||
      event_slot == 0 || send_slot == 0) {
    return PushResult(caller, "F1|api-unavailable");
  }

  const int original_top = get_top(target);
  raw_get_i(target, kLuaRegistryIndex, event_slot);
  constexpr std::string_view script = "tpf2_mp.lua";
  constexpr std::string_view channel = "tpf2mp";
  constexpr std::string_view event = "launcher.heartbeat";
  push_string(target, script.data(), script.size());
  push_string(target, channel.data(), channel.size());
  push_string(target, event.data(), event.size());
  raw_get_i(target, kLuaRegistryIndex, kUnsetRegistrySlot);  // explicit nil payload
  call_k(target, 4, 1, 0, nullptr);
  raw_get_i(target, kLuaRegistryIndex, send_slot);
  insert(target, -2);
  call_k(target, 1, 0, 0, nullptr);
  set_top(target, original_top);
  return PushResult(caller, "A1|script-event");
}

}  // namespace

namespace tpf2mp::launcher {

void RegisterBootstrapApi(lua_State* state, const LuaPushLString push_string,
                          const LuaPushCClosure push_closure,
                          const LuaRawSet raw_set, const LuaRawGetI raw_get_i,
                          const LuaInsert insert, const LuaCallK call_k,
                          const LuaGetTop get_top, const LuaSetTop set_top) {
  g_push_string.store(push_string);
  g_raw_get_i.store(raw_get_i);
  g_insert.store(insert);
  g_call_k.store(call_k);
  g_get_top.store(get_top);
  g_set_top.store(set_top);
  constexpr std::string_view ready_name = "tpf2mp_native_launcher_bootstrap_ready";
  push_string(state, ready_name.data(), ready_name.size());
  push_closure(state, NativeBootstrapReady, 0);
  raw_set(state, -3);
  constexpr std::string_view pump_name = "tpf2mp_native_launcher_pump";
  push_string(state, pump_name.data(), pump_name.size());
  push_closure(state, NativePump, 0);
  raw_set(state, -3);
}

void SetPumpTarget(lua_State* state, const int script_event_registry_slot,
                   const int send_command_registry_slot,
                   const std::uint32_t owning_thread) {
  g_script_event_slot.store(script_event_registry_slot);
  g_send_command_slot.store(send_command_registry_slot);
  g_pump_thread.store(owning_thread, std::memory_order_release);
  g_pump_target.store(state, std::memory_order_release);
}

void ObserveContext(lua_State* state, const std::string_view context,
                    const int script_event_registry_slot,
                    const int send_command_registry_slot) {
  if (context == "gui") {
    SetPumpTarget(state, script_event_registry_slot, send_command_registry_slot,
                  GetCurrentThreadId());
  }
}

}  // namespace tpf2mp::launcher
