// Bit-identical MaterialIndexManager pixel selection for Build 35924, ported
// from silver2127's tpf2-bigmap plugin, commit 4f0de6f (MIT), src/material_index.h.
// The stock routine visits a rectangular tile region once per batch of eight
// material layers (with a nine-layer inclusive scan and a one-layer overlap),
// recomputing the interpolation coordinates and the dither threshold for every
// pixel on every pass. This replacement completes those batches per pixel. It
// preserves the overlap, layer priority, overlay and mask precedence, the 0xe9
// sentinel, the fallback material and the scalar float interpolation order, so
// the output bytes are identical. Unsupported region geometry and overlapping
// output/base/overlay/mask storage fall back to the original function.

#include "tpf2mp/native_material_fast.hpp"

#include <Windows.h>

#include <atomic>
#include <cstring>
#include <string>
#include <vector>

namespace tpf2mp::material_fast {
namespace {

MaterialIndexFn g_original = nullptr;
const float* g_dither = nullptr;
bool g_fast = false;
bool g_timing = false;
std::atomic<std::uint64_t> g_calls{0}, g_ticks{0};

std::int32_t Lo(std::uint64_t a) { return static_cast<std::int32_t>(a); }
std::int32_t Hi(std::uint64_t a) { return static_cast<std::int32_t>(a >> 32); }
bool Overlap(std::uintptr_t a, std::size_t an, std::uintptr_t b, std::size_t bn) {
  return an && bn && (a < b ? b - a < an : a - b < bn);
}

void Detour(std::uint64_t block, std::uint64_t tile, std::uint64_t job, std::uint64_t origin,
            const std::uintptr_t* overlay, const std::uint8_t* layers, const std::int32_t* cell,
            const std::uintptr_t* baseVector, const std::uintptr_t* outputVector) {
  LARGE_INTEGER start{};
  if (g_timing) QueryPerformanceCounter(&start);
  if (g_fast) {
    MaterialIndex(g_original, g_dither, block, tile, job, origin, overlay, layers, cell, baseVector,
                  outputVector);
  } else {
    g_original(block, tile, job, origin, overlay, layers, cell, baseVector, outputVector);
  }
  if (g_timing) {
    LARGE_INTEGER end{};
    QueryPerformanceCounter(&end);
    g_ticks.fetch_add(static_cast<std::uint64_t>(end.QuadPart - start.QuadPart), std::memory_order_relaxed);
    g_calls.fetch_add(1, std::memory_order_relaxed);
  }
}

constexpr std::uint8_t kPrologue[16] = {0x48, 0x89, 0x4c, 0x24, 0x08, 0x55, 0x56, 0x57,
                                        0x41, 0x54, 0x41, 0x55, 0x41, 0x56, 0x41, 0x57};
// The whole self-contained function (no calls; two RIP-relative loads: the
// 0.25f constant and the dither table), generated from the Steam 35924
// executable. tests/native_terrain_fast/material_proof.py checks every byte.
constexpr std::uint32_t kBodySize = 1178;
const char* const kBodyHex =
    "48894c240855565741544155415641574881eca0000000488bb42400010000448bea4c8bb42408010000452be94c8ba424200100004c8bd249c1e920488bd1488b46088bf945"
    "8b5e28488b2e4889442448498bc048c1e82048c1ea20448bf849c1ea20452bd1440faffa4c8b8c241001000041c1e50841c1e208410faff8458b0941c1e10644894c24184533"
    "c9ffc048896c24580fafc24489ac24f00000004c899424e8000000897c240c44897c241c4863d0418d40010fafc1488954243844894c241044895c24144863d0488954244045"
    "85db0f8ead03000048899c24980000000f29b42480000000f30f103502aac0024d63c70f297c24700f57ff4c894424600f1f400066660f1f840000000000418d5908418bd74c"
    "8b4c2438418bc3895c2408899424f80000004d3bc10f8d290300008bdf41c1e708452bfdf7db4d8bd844897c240449c1e308498bf9492bf84c895c242848897c2430891c240f"
    "1f00458d0412660f6eea0f5bedf30f59eef3440f2ccd0f2fef418d41ff440f42c8b88320088241f7e866410f6ec10f5bc04103d0c1fa058bc2c1e81f03d0f30f5ce86bc23f48"
    "6354240c442bc04963c04c8bc2486bc03f4889442450488b8424100100008b4004c1e006ffc04403c8488b442440450faf4e2444898c2408010000483bd00f8d22020000448b"
    "5424104403ea4863cb488bf8492bcb4a8d1c1a482bfa48897c2420498b04244585d27406803c03e9eb7dc60403e9488d1419488b8424180100004532c0488b00440fb61c0248"
    "3b6c24487446488b060fb6140384d2743b4180fbff7335498b0424881403438d042f4c8b461848984c8bc8241f49c1e9050fb6d0438b04880fa3d00f8257010000448b8c2408"
    "01000041b0014584db740d498b042444881c03e93a0100004584c00f8531010000448b7c2418418bc52b8424f0000000660f6ed80f5bdbf30f59def30f2cd30f2fdf8d42ff0f"
    "42d041ffc74403fab8832008824503f94963ef660f6ec241f7ed0f5bc04103d5c1fa05f30f5cd88bc2c1e81f03d06bc23f418bd52bd04863c2488d15041bc7024803442450f3"
    "0f102482418b4628412bc28d70f7448d48ff85f64963d1b8000000000f4ef04c8d1c5249c1e3030f1f8000000000443bce7c64498b3e498b043b4c8b00418b46244103c74863"
    "d0f3410f1054a804f3410f5c14a8f3410f104c9004f3410f5c0c90f30f59d3f30f59cbf3410f5814a8f3410f580c90f30f5ccaf30f59cdf30f58ca0f2fcc770941ffc94983eb"
    "18eb9f410fb6443b0ceb11448b5c241444395c24087c0c410fb64618498b1424880413488b7c2420488bb42400010000448b7c2404488b6c2458448b8c240801000041ffc548"
    "ffc34883ef0148897c24200f8520feffff488b8c24e00000004c8b9424e80000004c8b5c24288b1c24488b7c2430448bac24f00000008b9424f800000003d9ffc2891c244181"
    "c700010000899424f80000004981c30001000044897c24044883ef014c895c242848897c24300f851afdffff418b46288b5c24088b7c240c4c8b442460448b7c241c895c2410"
    "448bcb89442414448bd83bd80f8c9efcffff0f287c24700f28b42480000000488b9c24980000004881c4a0000000415f415e415d415c5f5e5dc3";
constexpr std::uint8_t kQuarter[4] = {0x00, 0x00, 0x80, 0x3e};

bool VerifyBody(const terrain_fast::Host& host) {
  if (std::strlen(kBodyHex) != static_cast<std::size_t>(kBodySize) * 2) return false;
  std::vector<std::uint8_t> bytes(kBodySize, 0);
  for (std::uint32_t index = 0; index < kBodySize; ++index) {
    int value = 0;
    for (int nibble = 0; nibble < 2; ++nibble) {
      const char c = kBodyHex[2 * index + nibble];
      const int digit = c >= '0' && c <= '9' ? c - '0' : c >= 'a' && c <= 'f' ? c - 'a' + 10 : -256;
      value = value * 16 + digit;
    }
    if (value < 0) return false;
    bytes[index] = static_cast<std::uint8_t>(value);
  }
  return host.verify_bytes(host.context, kMaterialIndexRva, bytes.data(), bytes.size()) != 0;
}

}  // namespace

void MaterialIndex(MaterialIndexFn original, const float* dither, std::uint64_t block,
                   std::uint64_t tile, std::uint64_t job, std::uint64_t origin,
                   const std::uintptr_t* overlay, const std::uint8_t* layers,
                   const std::int32_t* cell, const std::uintptr_t* baseVector,
                   const std::uintptr_t* outputVector) {
  const int count = *reinterpret_cast<const int*>(layers + 40);
  if (count <= 0) return;  // original leaves output untouched
  const int w = Lo(block), h = Hi(block);
  const int jx = Lo(job), jy = Hi(job);
  const std::int64_t dx = static_cast<std::int64_t>(Lo(tile)) - Lo(origin);
  const std::int64_t dy = static_cast<std::int64_t>(Hi(tile)) - Hi(origin);
  // The measured path processes rectangular subregions of a 256x256 tile.
  // Preserve stock behaviour for an unmeasured call geometry.
  if (w <= 0 || h <= 0 || w > 256 || h > 256 || jx < 0 || jy < 0 ||
      (static_cast<std::int64_t>(jx) + 1) * w > 256 || (static_cast<std::int64_t>(jy) + 1) * h > 256 ||
      dx < 0 || dy < 0 || dx > 0x7fffff || dy > 0x7fffff) {
    original(block, tile, job, origin, overlay, layers, cell, baseVector, outputVector);
    return;
  }
  if (Overlap(outputVector[0], 65536, baseVector[0], static_cast<std::size_t>(w) * h) ||
      (overlay[0] != overlay[1] &&
       (Overlap(outputVector[0], 65536, overlay[0], 65536) ||
        Overlap(outputVector[0], 65536, overlay[3], 8192)))) {
    original(block, tile, job, origin, overlay, layers, cell, baseVector, outputVector);
    return;
  }
  const int x0 = jx * w, y0 = jy * h;
  const auto entries = *reinterpret_cast<const std::uint8_t* const*>(layers);
  const int stride = *reinterpret_cast<const int*>(layers + 36);
  const std::uint8_t fallback = layers[24];
  const auto base = reinterpret_cast<const std::uint8_t*>(baseVector[0]);
  const auto extra = reinterpret_cast<const std::uint8_t*>(overlay[0]);
  const auto mask = reinterpret_cast<const std::uint32_t*>(overlay[3]);
  auto output = reinterpret_cast<std::uint8_t*>(outputVector[0]);
  for (int y = y0; y < y0 + h; ++y) {
    const float fy = static_cast<float>(y) * 0.25f;
    const int iy = static_cast<int>(fy);
    const float ty = fy - static_cast<float>(iy);
    const int ditherRow = static_cast<int>((dy * 256 + y) % 63) * 63;
    for (int x = x0; x < x0 + w; ++x) {
      const int pixel = y * 256 + x;
      const std::uint8_t b = base[(y - y0) * w + x - x0];
      std::uint8_t value = 0xe9;
      bool evaluate = false;
      if (overlay[0] != overlay[1] && extra[pixel] != 0 && b != 0xff) {
        value = extra[pixel];
        if (((mask[pixel >> 5] >> (pixel & 31)) & 1) == 0 && b != 0) value = b;
      } else if (b != 0) {
        value = b;
      } else {
        evaluate = true;
      }
      // Calculate interpolation coordinates only for unresolved pixels. A
      // reserved 0xe9 value can become unresolved in a later batch; preserve
      // that behaviour too instead of treating it as a final ID.
      if (evaluate || (value == 0xe9 && count > 8)) {
        const float fx = static_cast<float>(x) * 0.25f;
        const int ix = static_cast<int>(fx);
        const float tx = fx - static_cast<float>(ix);
        const int index = cell[0] * 64 + 1 + ix + (iy + cell[1] * 64 + 1) * stride;
        const float threshold = dither[ditherRow + static_cast<int>((dx * 256 + x) % 63)];
        for (int batch = 0; batch < count; batch += 8) {
          if (batch ? value != 0xe9 : !evaluate) continue;
          int last = count - batch - 9;
          if (last < 0) last = 0;
          bool found = false;
          for (int k = count - batch - 1; k >= last; --k) {
            const std::uint8_t* e = entries + static_cast<std::size_t>(k) * 24;
            const auto map = *reinterpret_cast<const std::uintptr_t* const*>(e);
            const auto heights = reinterpret_cast<const float*>(map[0]);
            const float top = (heights[index + 1] - heights[index]) * tx + heights[index];
            const float bottom =
                (heights[index + stride + 1] - heights[index + stride]) * tx + heights[index + stride];
            if (threshold < (bottom - top) * ty + top) {
              value = e[12];
              found = true;
              break;
            }
          }
          if (!found && count <= batch + 8) value = fallback;
          if (value != 0xe9) break;
        }
      }
      output[pixel] = value;
    }
  }
}

bool Install(const terrain_fast::Host& host, std::uintptr_t base, bool fast, bool timing,
             bool& active, std::string& error) {
  active = false;
  if (!fast && !timing) return false;
  if (!host.verify_bytes(host.context, kMaterialIndexRva, kPrologue, sizeof kPrologue)) {
    error = "material: prologue mismatch at 0x315f20";
    return false;
  }
  if (!VerifyBody(host)) {
    error = "material: byte mismatch in the function body at 0x315f20";
    return false;
  }
  if (!host.verify_bytes(host.context, kQuarterConstantRva, kQuarter, sizeof kQuarter)) {
    error = "material: constant mismatch at 0x2f20a14";
    return false;
  }
  void* original = nullptr;
  if (!host.install_hook(host.context, base + kMaterialIndexRva, reinterpret_cast<void*>(&Detour),
                         &original)) {
    error = "material: hook failed";
    return false;
  }
  g_original = reinterpret_cast<MaterialIndexFn>(original);
  g_dither = reinterpret_cast<const float*>(base + kDitherTableRva);
  g_fast = fast;
  g_timing = timing;
  active = fast;
  return true;
}

TimingSnapshot Timing() {
  TimingSnapshot snapshot;
  snapshot.calls = g_calls.load(std::memory_order_relaxed);
  LARGE_INTEGER frequency{};
  QueryPerformanceFrequency(&frequency);
  const auto ticks = g_ticks.load(std::memory_order_relaxed);
  snapshot.seconds =
      frequency.QuadPart > 0 ? static_cast<double>(ticks) / static_cast<double>(frequency.QuadPart) : 0.0;
  return snapshot;
}

}  // namespace tpf2mp::material_fast
