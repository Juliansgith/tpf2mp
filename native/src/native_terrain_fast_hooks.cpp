// Hook-DLL side of the optional terrain fast paths: the live Host services
// (module base, guarded byte comparison, MinHook detours, a thread-frozen
// in-place patch) and the entry points tests/native_terrain_fast/ calls to
// compare the fast paths with the original machine code.

#include "tpf2mp/native_command_codec.hpp"
#include "tpf2mp/native_material_fast.hpp"
#include "tpf2mp/native_terrain_fast.hpp"

#include <MinHook.h>

#include <Windows.h>
#include <TlHelp32.h>

#include <cstring>
#include <string>
#include <vector>

namespace tpf2mp::terrain_fast {
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

// Overwrites `size` bytes in place while every other thread is suspended, and
// refuses when any suspended thread is executing inside the patched range.
// A game launched by the injector is still at startup when the hook arms, but
// attaching to a running process must be just as safe.
int LivePatchBytes(void* context, std::uintptr_t rva, const std::uint8_t* bytes, std::size_t size) {
  const std::uintptr_t address = LiveModuleBase(context) + rva;
  const auto pointer = reinterpret_cast<std::uint8_t*>(address);
  if (!tpf2mp::native_command::IsReadableRange(pointer, size)) return 0;
  const HANDLE snapshot = CreateToolhelp32Snapshot(TH32CS_SNAPTHREAD, 0);
  if (snapshot == INVALID_HANDLE_VALUE) return 0;
  std::vector<HANDLE> suspended;
  bool conflict = false;
  const DWORD process_id = GetCurrentProcessId();
  const DWORD self = GetCurrentThreadId();
  THREADENTRY32 entry{};
  entry.dwSize = sizeof entry;
  if (Thread32First(snapshot, &entry)) {
    do {
      if (entry.th32OwnerProcessID != process_id || entry.th32ThreadID == self) continue;
      const HANDLE thread = OpenThread(
          THREAD_SUSPEND_RESUME | THREAD_GET_CONTEXT | THREAD_QUERY_INFORMATION, FALSE,
          entry.th32ThreadID);
      if (thread == nullptr) continue;
      if (SuspendThread(thread) == static_cast<DWORD>(-1)) {
        CloseHandle(thread);
        continue;
      }
      suspended.push_back(thread);
      CONTEXT registers{};
      registers.ContextFlags = CONTEXT_CONTROL;
      if (GetThreadContext(thread, &registers) && registers.Rip >= address &&
          registers.Rip < address + size) {
        conflict = true;
      }
    } while (Thread32Next(snapshot, &entry));
  }
  CloseHandle(snapshot);
  bool written = false;
  if (!conflict) {
    DWORD previous = 0;
    if (VirtualProtect(pointer, size, PAGE_EXECUTE_READWRITE, &previous)) {
      std::memcpy(pointer, bytes, size);
      DWORD ignored = 0;
      VirtualProtect(pointer, size, previous, &ignored);
      FlushInstructionCache(GetCurrentProcess(), pointer, size);
      written = true;
    }
  }
  for (const HANDLE thread : suspended) {
    ResumeThread(thread);
    CloseHandle(thread);
  }
  return written ? 1 : 0;
}

Host LiveHost(HMODULE executable) {
  Host host;
  host.context = executable;
  host.module_base = LiveModuleBase;
  host.verify_bytes = LiveVerifyBytes;
  host.install_hook = LiveInstallHook;
  host.patch_bytes = LivePatchBytes;
  return host;
}

}  // namespace

Status InstallFromEnvironment(HMODULE executable) {
  wchar_t value[256]{};
  const DWORD length = GetEnvironmentVariableW(L"TPF2MP_NATIVE_TERRAIN_FAST", value,
                                               static_cast<DWORD>(std::size(value)));
  Request request;
  if (length == 0 || length >= std::size(value)) {
    request = ParseRequest(L"");
    if (length >= std::size(value)) request.error = "value longer than 255 characters";
  } else {
    request = ParseRequest(std::wstring_view(value, length));
  }
  return Install(LiveHost(executable), request);
}

}  // namespace tpf2mp::terrain_fast

// ------------------------------------------------------------ test entry points
// tests/native_terrain_fast/ maps the pinned executable inside its own process
// and runs the original routines beside these; nothing in the game calls them.
extern "C" {

__declspec(dllexport) void TPF2MP_TerrainFastTestRefine(
    tpf2mp::terrain_fast::BicubicRefineFn original, int k,
    const tpf2mp::terrain_fast::ConstU16Vector* src, int srcDim, int x0, int y0, int x1, int y1,
    const float* scale, std::uint16_t* out, int stride, int dx, int dy) {
  tpf2mp::terrain_fast::BicubicRefine(original, k, src, srcDim, x0, y0, x1, y1, scale, out, stride,
                                      dx, dy);
}

__declspec(dllexport) std::uint32_t TPF2MP_TerrainFastTestMinMaxScan(const std::uint16_t* begin,
                                                                      const std::uint16_t* end) {
  return tpf2mp::terrain_fast::MinMaxScan(begin, end);
}

__declspec(dllexport) std::uintptr_t TPF2MP_TerrainFastTestMinMaxScanAddress() {
  return reinterpret_cast<std::uintptr_t>(&tpf2mp::terrain_fast::MinMaxScan);
}

__declspec(dllexport) void TPF2MP_TerrainFastTestMinMaxPatch(std::uint8_t* out,
                                                             std::uintptr_t scan_address) {
  tpf2mp::terrain_fast::BuildMinMaxPatch(out, scan_address);
}

__declspec(dllexport) void TPF2MP_TerrainFastTestBlockCopy(
    tpf2mp::terrain_fast::BlockCopyFn original, const std::uint16_t* src, std::uint16_t* dst,
    int srcStride, int dstStride, int srcX, int srcY, int w, int h, int dstX, int dstY) {
  tpf2mp::terrain_fast::BlockCopy(original, src, dst, srcStride, dstStride, srcX, srcY, w, h,
                                  dstX, dstY);
}

__declspec(dllexport) void TPF2MP_TerrainFastTestAlign(
    tpf2mp::terrain_fast::CalculateHeightModFn original, std::uintptr_t base, const float* box,
    const std::int32_t* size, float scale, float offset,
    const tpf2mp::terrain_fast::PointerVector* alignments,
    tpf2mp::terrain_fast::U16Vector* result) {
  tpf2mp::terrain_fast::CalculateHeightMod(original, tpf2mp::terrain_fast::ResolveAlignEngine(base),
                                           box, size, scale, offset, alignments, result);
}

__declspec(dllexport) void TPF2MP_TerrainFastTestMaterial(
    tpf2mp::material_fast::MaterialIndexFn original, const float* dither, std::uint64_t block,
    std::uint64_t tile, std::uint64_t job, std::uint64_t origin, const std::uintptr_t* overlay,
    const std::uint8_t* layers, const std::int32_t* cell, const std::uintptr_t* baseVector,
    const std::uintptr_t* outputVector) {
  tpf2mp::material_fast::MaterialIndex(original, dither, block, tile, job, origin, overlay, layers,
                                       cell, baseVector, outputVector);
}

// Runs the installer against a caller-supplied Host (a mapped image and fake
// hook/patch services). `features` is a mask of kFeature*; the return value
// is a mask of kStatus*; `error` receives the refusal text.
__declspec(dllexport) int TPF2MP_TerrainFastTestInstall(const tpf2mp::terrain_fast::Host* host,
                                                        int features, char* error,
                                                        std::size_t error_size) {
  const auto status = tpf2mp::terrain_fast::Install(
      *host, tpf2mp::terrain_fast::RequestFromMask(features));
  if (error != nullptr && error_size > 0) {
    const std::size_t count = status.error.size() < error_size - 1 ? status.error.size() : error_size - 1;
    std::memcpy(error, status.error.data(), count);
    error[count] = '\0';
  }
  return tpf2mp::terrain_fast::StatusMask(status);
}

}  // extern "C"
