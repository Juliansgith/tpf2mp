#include "tpf2mp/native_build_hook_bridge.hpp"

#include "tpf2mp/native_command_codec.hpp"

#include <Windows.h>
#include <intrin.h>

#include <cstdint>
#include <cstring>
#include <optional>
#include <utility>

namespace tpf2mp::native_build_hook {
namespace {

using MakeBuildProposal = void* (*)(void*, void*, void*, void*, bool, bool);
using CommandListAdd = void (*)(void*, void*, void*, void*, void*);

SRWLOCK g_lock = SRWLOCK_INIT;
HMODULE g_executable = nullptr;
GateSnapshotProvider g_gate_snapshot = nullptr;
StatusNotifier g_status_notifier = nullptr;
native_build::BuildFactoryCaptureQueue g_captures{32, 16};
MakeBuildProposal g_original_make_build_proposal = nullptr;
CommandListAdd g_original_command_list_add = nullptr;

class Lock final {
 public:
  Lock() { AcquireSRWLockExclusive(&g_lock); }
  ~Lock() { ReleaseSRWLockExclusive(&g_lock); }
  Lock(const Lock&) = delete;
  Lock& operator=(const Lock&) = delete;
};

std::uint32_t CallerRva(const void* return_address) {
  const auto caller = reinterpret_cast<std::uintptr_t>(return_address);
  const auto base = reinterpret_cast<std::uintptr_t>(g_executable);
  if (base == 0 || caller < base || caller - base > UINT32_MAX) return 0;
  return static_cast<std::uint32_t>(caller - base);
}

void Notify() {
  if (g_status_notifier != nullptr) g_status_notifier();
}

void* DetourMakeBuildProposal(void* output, void* engine, void* proposal,
                              void* context, const bool with_cost,
                              const bool ignore_errors) {
  const auto gate = g_gate_snapshot != nullptr ? g_gate_snapshot() : GateSnapshot{};
  std::optional<native_build::BuildFactoryCapture> capture;
  if (gate.enabled && gate.correlation != 0) {
    Lock lock;
    capture = g_captures.Decode(proposal, gate.correlation,
                                CallerRva(_ReturnAddress()),
                                GetCurrentThreadId(), with_cost, ignore_errors);
  }
  void* command = g_original_make_build_proposal(
      output, engine, proposal, context, with_cost, ignore_errors);
  if (capture.has_value()) {
    const void* command_data = nullptr;
    if (native_command::IsReadableRange(command, sizeof(void*))) {
      std::memcpy(&command_data, command, sizeof(command_data));
    }
    {
      Lock lock;
      g_captures.Commit(std::move(*capture), command, command_data);
    }
    Notify();
  }
  return command;
}

void DetourCommandListAdd(void* list, void* output, void* command,
                          void* callback, void* tail) {
  if (native_command::NativeCommandTag(command) == 15) {
    {
      Lock lock;
      g_captures.ObserveAdd(command, CallerRva(_ReturnAddress()),
                            GetCurrentThreadId());
    }
    Notify();
  }
  g_original_command_list_add(list, output, command, callback, tail);
}

}  // namespace

void Configure(HMODULE executable, GateSnapshotProvider gate_snapshot,
               StatusNotifier status_notifier) {
  g_executable = executable;
  g_gate_snapshot = gate_snapshot;
  g_status_notifier = status_notifier;
}

void ResetPending() {
  Lock lock;
  g_captures.ResetPending();
}

native_build::BuildCaptureStats Stats() {
  Lock lock;
  return g_captures.stats();
}

std::optional<std::string> TakeEncoded() {
  Lock lock;
  return g_captures.TakeEncoded();
}

void PromoteSuppressed(void* build_proposal) {
  Lock lock;
  g_captures.PromoteSuppressed(build_proposal);
}

void DiscardObserved(void* build_proposal) {
  Lock lock;
  g_captures.DiscardObserved(build_proposal);
}

void* MakeBuildProposalDetour() {
  return reinterpret_cast<void*>(DetourMakeBuildProposal);
}
void** MakeBuildProposalOriginalStorage() {
  return reinterpret_cast<void**>(&g_original_make_build_proposal);
}
void* CommandListAddDetour() {
  return reinterpret_cast<void*>(DetourCommandListAdd);
}
void** CommandListAddOriginalStorage() {
  return reinterpret_cast<void**>(&g_original_command_list_add);
}

}  // namespace tpf2mp::native_build_hook
