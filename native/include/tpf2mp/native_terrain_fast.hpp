#pragma once

// Optional, bit-identical terrain fast paths for Build 35924 save/world loads.
//
// Ported from silver2127's tpf2-bigmap plugin (MIT; see
// native/third_party/tpf2-bigmap/TPF2MP_PIN.txt and
// docs/THIRD_PARTY_NOTICES.md). Three stock terrain routines that dominate the
// terrain phase of a load are replaced by implementations that produce the
// same bytes for every input the stock code accepts:
//
//   * terrain_alignment_util::CalculateHeightMod (RVA 0x3b3470): pooled
//     rasterisation targets and an SSE2 blend; the stock rasteriser is still
//     called for every triangle;
//   * sub_terrain_util::InternBicubicRefine (RVA 0x3ac6c0): per-call constants
//     and an SSE2 Hermite evaluation in the stock operation order;
//   * the inlined CalcMinMaxHeight scan inside terrain publication (RVA
//     0x33cec1) and the uint16 height block copy (RVA 0x30a540).
//
// All three are on by default. TPF2MP_NATIVE_TERRAIN_FAST=off restores the
// stock code, a list selects a subset, and "timing" adds per-call wall-clock
// accounting (with "stock,timing" measuring the originals). Every patch site
// is byte-verified first, and any mismatch or hook failure leaves that fast
// path off while the rest of the hook arms normally. Because the outputs are
// identical, peers may run different settings without diverging; the status
// JSON records what is active.

#include <Windows.h>

#include <cstddef>
#include <cstdint>
#include <string>
#include <string_view>

namespace tpf2mp::terrain_fast {

// ---------------------------------------------------------------- host seam
// Services the installer needs. Plain C function pointers with a context so
// the same installer runs against the live game (MinHook, native memory) and
// inside tests (a mapped image or fakes). Returns are int for ABI stability:
// non-zero means success.
struct Host {
  void* context{};
  std::uintptr_t (*module_base)(void* context){};
  int (*verify_bytes)(void* context, std::uintptr_t rva, const std::uint8_t* expected,
                      std::size_t size){};
  int (*install_hook)(void* context, std::uintptr_t target, void* detour, void** original){};
  int (*patch_bytes)(void* context, std::uintptr_t rva, const std::uint8_t* bytes,
                     std::size_t size){};
};

struct Request {
  bool align{};
  bool refine{};
  bool minmax{};
  bool material{};    // world-entry material-index selection (native_material_fast.cpp)
  bool timing{};      // wrap the hooked routines with QueryPerformanceCounter accounting
  std::string raw;
  std::string error;  // non-empty when the text was not understood; nothing is requested then
};

// Whether "all" and an unset variable include the material-index path.
constexpr bool kMaterialDefaultOn = true;

// Parses the TPF2MP_NATIVE_TERRAIN_FAST value. Empty (unset), "1", "on",
// "true" or "all" request the default fast paths; "0", "off", "false", "none"
// or "stock" request none; otherwise a comma/space/semicolon separated list of
// "align", "refine", "minmax", "material", "stock" and "timing". "timing" may
// be combined with anything, including "stock" (the originals are then timed
// through pass-through detours). Unknown tokens fail closed: nothing is
// requested and the error is recorded.
Request ParseRequest(std::wstring_view value);

struct Status {
  std::string requested;
  bool align{};        // CalculateHeightMod detour active
  bool refine{};       // InternBicubicRefine detour active
  bool minmax_scan{};  // 69-byte CalcMinMaxHeight scan patch applied
  bool block_copy{};   // height block copy detour active
  bool material{};     // material-index selection detour active
  bool timing{};       // per-call accounting active (see Timing())
  std::string error;   // every refusal, "; " separated
};

// Live per-routine accounting, valid once Status::timing is true. Seconds are
// wall-clock inside the detour (the fast path or, under "stock", the
// original); the scan is only timed on its fast path because the stock scan
// is inline code.
struct TimingSnapshot {
  std::uint64_t align_calls{}, refine_calls{}, block_copy_calls{}, scan_calls{}, material_calls{};
  double align_seconds{}, refine_seconds{}, block_copy_seconds{}, scan_seconds{}, material_seconds{};
};
TimingSnapshot Timing();

// Verifies every byte region a requested fast path relies on, then installs
// it. A refused fast path never touches memory; the others still install.
Status Install(const Host& host, const Request& request);

// Defined in native_terrain_fast_hooks.cpp, which only the hook DLL links:
// reads TPF2MP_NATIVE_TERRAIN_FAST and installs through MinHook. Call after
// MH_Initialize; every hook it creates is enabled immediately, so a failure
// stays confined to that fast path.
Status InstallFromEnvironment(HMODULE executable);

// Feature bits shared by the test entry points.
constexpr int kFeatureAlign = 1;
constexpr int kFeatureRefine = 2;
constexpr int kFeatureMinMax = 4;
constexpr int kFeatureTiming = 8;
constexpr int kFeatureMaterial = 16;
constexpr int kStatusAlign = 1;
constexpr int kStatusRefine = 2;
constexpr int kStatusMinMaxScan = 4;
constexpr int kStatusBlockCopy = 8;
constexpr int kStatusTiming = 16;
constexpr int kStatusMaterial = 32;
Request RequestFromMask(int features);
int StatusMask(const Status& status);

// ---------------------------------------------------------------- pinned RVAs
constexpr std::uintptr_t kCalculateHeightModRva = 0x3b3470;
constexpr std::uintptr_t kBicubicRefineRva = 0x3ac6c0;
constexpr std::uintptr_t kMinMaxScanRva = 0x33cec1;
constexpr std::uintptr_t kMinMaxScanResumeRva = 0x33cf06;
constexpr std::uintptr_t kBlockCopyRva = 0x30a540;
constexpr std::size_t kMinMaxPatchSize = 69;

// ---------------------------------------------------------------- pure paths
// Exposed so tests can compare them with the original machine code.

struct ConstU16Vector {
  const std::uint16_t* first;
  const std::uint16_t* last;
  const std::uint16_t* end;
};
struct U16Vector {
  std::uint16_t* first;
  std::uint16_t* last;
  std::uint16_t* end;
};
struct PointerVector {
  const std::uint8_t* const* first;
  const std::uint8_t* const* last;
  const std::uint8_t* const* end;
};

using BicubicRefineFn = void (*)(int, const ConstU16Vector*, int, int, int, int, int, const float*,
                                 std::uint16_t*, int, int, int);
void BicubicRefine(BicubicRefineFn original, int k, const ConstU16Vector* src, int srcDim, int x0,
                   int y0, int x1, int y1, const float* scale, std::uint16_t* out, int stride,
                   int dx, int dy);

// Returns min | (max << 16) over the stock byte range [begin, begin + 2*count).
std::uint32_t MinMaxScan(const std::uint16_t* begin, const std::uint16_t* end);
void BuildMinMaxPatch(std::uint8_t* out, std::uintptr_t scan_address);

using BlockCopyFn = void (*)(const std::uint16_t*, std::uint16_t*, int, int, int, int, int, int,
                             int, int);
void BlockCopy(BlockCopyFn original, const std::uint16_t* src, std::uint16_t* dst, int srcStride,
               int dstStride, int srcX, int srcY, int w, int h, int dstX, int dstY);

using CalculateHeightModFn = void (*)(const float*, const std::int32_t*, float, float,
                                      const PointerVector*, U16Vector*);
using AlignRasterInitFn = void* (*)(void*, void*, const float*, const float*, const std::int32_t*,
                                    std::uint8_t);
using AlignRasterTriangleFn = std::uint8_t (*)(void*, std::uint64_t, std::uint64_t, std::uint64_t);
using AlignAssertFn = void (*)(const char*, const char*, int, const char*);

// The stock routines CalculateHeightMod keeps calling, resolved once from the
// module base (or supplied by a test).
struct AlignEngine {
  AlignRasterInitFn raster_init{};
  AlignRasterTriangleFn raster_triangle{};
  AlignAssertFn assert_fn{};
  std::uintptr_t vtable_less_equal{};
  std::uintptr_t vtable_greater_equal{};
  const char* assert_expression{};
  const char* assert_file{};
  const char* assert_function{};
};
AlignEngine ResolveAlignEngine(std::uintptr_t base);
void CalculateHeightMod(CalculateHeightModFn original, const AlignEngine& engine, const float* box,
                        const std::int32_t* size, float scale, float offset,
                        const PointerVector* alignments, U16Vector* result);

}  // namespace tpf2mp::terrain_fast
