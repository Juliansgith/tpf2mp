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

}  // namespace

namespace tpf2mp::launcher {

void RegisterBootstrapApi(lua_State* state, const LuaPushLString push_string,
                          const LuaPushCClosure push_closure,
                          const LuaRawSet raw_set) {
  g_push_string.store(push_string);
  constexpr std::string_view name = "tpf2mp_native_launcher_bootstrap_ready";
  push_string(state, name.data(), name.size());
  push_closure(state, NativeBootstrapReady, 0);
  raw_set(state, -3);
}

}  // namespace tpf2mp::launcher
