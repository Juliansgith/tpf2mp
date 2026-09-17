#pragma once

// Bit-identical replacement for the Build 35924 MaterialIndexManager pixel
// selection (RVA 0x315f20), the routine the world-entry profile in
// tpf2-bigmap found as the largest game-code bucket after InitGame. Ported
// from that plugin's src/material_index.h (MIT; see
// native/third_party/tpf2-bigmap/TPF2MP_PIN.txt). It is a loop interchange
// only: the same 8-layer batches with their 9-layer overlap, the same
// overlay/mask precedence, the 0xe9 sentinel, the fallback material and the
// exact scalar interpolation order, visited pixel-major so the per-pixel
// interpolation coordinates and dither threshold are computed once. It is
// installed by tpf2mp::terrain_fast::Install through the same Host seam.

#include "tpf2mp/native_terrain_fast.hpp"

#include <cstdint>
#include <string>

namespace tpf2mp::material_fast {

constexpr std::uintptr_t kMaterialIndexRva = 0x315f20;
constexpr std::uintptr_t kMaterialIndexEndRva = 0x3163ba;
constexpr std::uintptr_t kDitherTableRva = 0x2f87d20;  // 63 x 63 floats
constexpr std::uintptr_t kQuarterConstantRva = 0x2f20a14;

using MaterialIndexFn = void (*)(std::uint64_t, std::uint64_t, std::uint64_t, std::uint64_t,
                                 const std::uintptr_t*, const std::uint8_t*, const std::int32_t*,
                                 const std::uintptr_t*, const std::uintptr_t*);

// The pure replacement. `dither` is the game's 63 x 63 threshold table.
void MaterialIndex(MaterialIndexFn original, const float* dither, std::uint64_t block,
                   std::uint64_t tile, std::uint64_t job, std::uint64_t origin,
                   const std::uintptr_t* overlay, const std::uint8_t* layers,
                   const std::int32_t* cell, const std::uintptr_t* baseVector,
                   const std::uintptr_t* outputVector);

// Verifies the prologue, the whole function body and the 0.25f constant, then
// hooks the routine when `fast` or `timing` is wanted. Returns true when the
// hook exists; `active` reports whether the fast path (not just timing) is on.
bool Install(const terrain_fast::Host& host, std::uintptr_t base, bool fast, bool timing,
             bool& active, std::string& error);

struct TimingSnapshot {
  std::uint64_t calls{};
  double seconds{};
};
TimingSnapshot Timing();

}  // namespace tpf2mp::material_fast
