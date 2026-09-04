#pragma once

#include "tpf2mp/native_build_capture.hpp"

#include <Windows.h>

#include <cstdint>
#include <optional>
#include <string>

namespace tpf2mp::native_build_hook {

struct GateSnapshot {
  bool enabled = false;
  std::uint64_t correlation = 0;
};

using GateSnapshotProvider = GateSnapshot (*)();
using StatusNotifier = void (*)();

void Configure(HMODULE executable, GateSnapshotProvider gate_snapshot,
               StatusNotifier status_notifier);
void ResetPending();
native_build::BuildCaptureStats Stats();
std::optional<std::string> TakeEncoded();
void PromoteSuppressed(void* build_proposal);
void DiscardObserved(void* build_proposal);

void* MakeBuildProposalDetour();
void** MakeBuildProposalOriginalStorage();
void* CommandListAddDetour();
void** CommandListAddOriginalStorage();

}  // namespace tpf2mp::native_build_hook
