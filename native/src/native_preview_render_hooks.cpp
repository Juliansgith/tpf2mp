// Hook-DLL side of the vanilla builder-ghost previews: the live Host services
// (module base, guarded byte comparison, MinHook detours) and the environment
// entry point the hook calls once MinHook is initialised. The installer
// itself lives in native_preview_render.cpp so tests can drive it against a
// mapped image with fake hooks.

#include "tpf2mp/native_command_codec.hpp"
#include "tpf2mp/native_preview_render.hpp"

#include <MinHook.h>

#include <Windows.h>

#include <cstring>
#include <iterator>
#include <string>

namespace tpf2mp::preview_render {
namespace {

// SEH needs a frame without C++ objects that require unwinding.
int CompareGuarded(const void* pointer, const std::uint8_t* expected, std::size_t size) {
  __try {
    return std::memcmp(pointer, expected, size) == 0 ? 1 : 0;
  } __except (EXCEPTION_EXECUTE_HANDLER) {
    return 0;
  }
}

std::uintptr_t LiveModuleBase(void* context) {
  return reinterpret_cast<std::uintptr_t>(static_cast<HMODULE>(context));
}

int LiveVerifyBytes(void* context, std::uintptr_t rva, const std::uint8_t* expected,
                    std::size_t size) {
  const auto pointer = reinterpret_cast<const std::uint8_t*>(LiveModuleBase(context) + rva);
  if (!tpf2mp::native_command::IsReadableRange(pointer, size)) return 0;
  return CompareGuarded(pointer, expected, size);
}

int LiveInstallHook(void*, std::uintptr_t target, void* detour, void** original) {
  const auto address = reinterpret_cast<LPVOID>(target);
  if (MH_CreateHook(address, detour, original) != MH_OK) return 0;
  if (MH_EnableHook(address) != MH_OK) {
    MH_RemoveHook(address);
    *original = nullptr;
    return 0;
  }
  return 1;
}

Host LiveHost(HMODULE executable) {
  Host host;
  host.context = executable;
  host.module_base = LiveModuleBase;
  host.verify_bytes = LiveVerifyBytes;
  host.install_hook = LiveInstallHook;
  return host;
}

}  // namespace

Status InstallFromEnvironment(HMODULE executable, void (*status_write_request)()) {
  SetStatusWriteRequest(status_write_request);
  wchar_t value[64]{};
  const DWORD length = GetEnvironmentVariableW(L"TPF2MP_NATIVE_PREVIEW", value,
                                               static_cast<DWORD>(std::size(value)));
  Request request;
  if (length == 0 || length >= std::size(value)) {
    request = ParseRequest(L"");
    if (length >= std::size(value)) request.error = "value longer than 63 characters";
  } else {
    request = ParseRequest(std::wstring_view(value, length));
  }
  if (!request.error.empty()) request.enabled = false;
  return Install(LiveHost(executable), request);
}

}  // namespace tpf2mp::preview_render
