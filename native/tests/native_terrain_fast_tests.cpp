// Offline checks for the optional terrain fast paths: request parsing, the
// installer's fail-closed decisions against a fake host, and the SSE2 paths
// against scalar transcriptions of the same arithmetic. Equivalence with the
// game's original machine code is proved separately by
// tests/native_terrain_fast/ against the pinned executable.

#include "tpf2mp/native_material_fast.hpp"
#include "tpf2mp/native_terrain_fast.hpp"

#include <algorithm>
#include <cmath>
#include <cstdint>
#include <cstring>
#include <iostream>
#include <random>
#include <string>
#include <vector>

namespace {

using namespace tpf2mp::terrain_fast;

bool Fail(const char* message) {
  std::cerr << "terrain fast paths: " << message << "\n";
  return false;
}

// ------------------------------------------------------------------ request
bool RequestParsingValid() {
  const Request unset = ParseRequest(L"");
  if (!unset.align || !unset.refine || !unset.minmax || unset.timing || !unset.error.empty()) {
    return Fail("an unset variable must default to every fast path");
  }
  const Request off = ParseRequest(L"OFF");
  if (off.align || off.refine || off.minmax || off.timing || !off.error.empty()) return Fail("off request");
  const Request stock = ParseRequest(L"stock");
  if (stock.align || stock.refine || stock.minmax || stock.timing) return Fail("stock request");
  const Request all = ParseRequest(L"all");
  if (!all.align || !all.refine || !all.minmax || all.timing) return Fail("all request");
  const Request one = ParseRequest(L"1");
  if (!one.align || !one.refine || !one.minmax) return Fail("1 request");
  const Request list = ParseRequest(L" Align, minmax ");
  if (!list.align || list.refine || !list.minmax || list.timing || !list.error.empty()) return Fail("list request");
  const Request timed = ParseRequest(L"stock,timing");
  if (timed.align || timed.refine || timed.minmax || !timed.timing || !timed.error.empty()) {
    return Fail("stock,timing must time the originals only");
  }
  const Request timed_all = ParseRequest(L"timing");
  if (!timed_all.align || !timed_all.refine || !timed_all.minmax || !timed_all.timing) {
    return Fail("timing alone keeps the default fast paths");
  }
  const Request unknown = ParseRequest(L"align,turbo");
  if (unknown.align || unknown.refine || unknown.minmax || unknown.timing || unknown.error.empty()) {
    return Fail("unknown token must fail closed");
  }
  if (unset.material != kMaterialDefaultOn || all.material != kMaterialDefaultOn) {
    return Fail("the material path follows its default policy");
  }
  const Request material = ParseRequest(L"material");
  if (material.align || material.refine || material.minmax || !material.material) {
    return Fail("material alone requests only the material path");
  }
  const Request material_all = ParseRequest(L"all,material");
  if (!material_all.align || !material_all.refine || !material_all.minmax || !material_all.material) {
    return Fail("all,material adds the material path to the defaults");
  }
  const Request mask = RequestFromMask(kFeatureRefine | kFeatureMinMax | kFeatureTiming | kFeatureMaterial);
  if (mask.align || !mask.refine || !mask.minmax || !mask.timing || !mask.material) return Fail("mask request");
  Status status;
  status.align = true;
  status.block_copy = true;
  status.timing = true;
  status.material = true;
  if (StatusMask(status) != (kStatusAlign | kStatusBlockCopy | kStatusTiming | kStatusMaterial)) {
    return Fail("status mask");
  }
  return true;
}

// ---------------------------------------------------------------- installer
struct FakeHost {
  std::uintptr_t base = 0x140000000ull;
  std::uintptr_t failing_rva = 0;
  bool hook_fails = false;
  bool patch_fails = false;
  std::vector<std::uintptr_t> verified;
  std::vector<std::uintptr_t> hooked;
  std::vector<std::uintptr_t> patched;
  std::size_t patch_size = 0;
};

std::uintptr_t FakeModuleBase(void* context) { return static_cast<FakeHost*>(context)->base; }
int FakeVerify(void* context, std::uintptr_t rva, const std::uint8_t*, std::size_t) {
  auto* host = static_cast<FakeHost*>(context);
  host->verified.push_back(rva);
  return rva == host->failing_rva ? 0 : 1;
}
int FakeHook(void* context, std::uintptr_t target, void*, void** original) {
  auto* host = static_cast<FakeHost*>(context);
  host->hooked.push_back(target);
  if (host->hook_fails) return 0;
  *original = reinterpret_cast<void*>(target);
  return 1;
}
int FakePatch(void* context, std::uintptr_t rva, const std::uint8_t*, std::size_t size) {
  auto* host = static_cast<FakeHost*>(context);
  host->patched.push_back(rva);
  host->patch_size = size;
  return host->patch_fails ? 0 : 1;
}
Host HostFor(FakeHost& fake) {
  Host host;
  host.context = &fake;
  host.module_base = FakeModuleBase;
  host.verify_bytes = FakeVerify;
  host.install_hook = FakeHook;
  host.patch_bytes = FakePatch;
  return host;
}
bool Contains(const std::vector<std::uintptr_t>& values, std::uintptr_t value) {
  for (const auto candidate : values) {
    if (candidate == value) return true;
  }
  return false;
}

bool InstallerValid() {
  {
    FakeHost fake;
    const Status status = Install(HostFor(fake), RequestFromMask(0));
    if (StatusMask(status) != 0 || !fake.verified.empty() || !fake.hooked.empty() ||
        !fake.patched.empty() || !status.error.empty()) {
      return Fail("an empty request must touch nothing");
    }
  }
  {
    FakeHost fake;
    const Status status = Install(HostFor(fake), RequestFromMask(kFeatureAlign | kFeatureRefine | kFeatureMinMax));
    if (StatusMask(status) != (kStatusAlign | kStatusRefine | kStatusMinMaxScan | kStatusBlockCopy)) {
      return Fail("all fast paths must install against a verifying host");
    }
    if (!status.error.empty()) return Fail("no error expected on a full install");
    if (!Contains(fake.hooked, fake.base + kCalculateHeightModRva) ||
        !Contains(fake.hooked, fake.base + kBicubicRefineRva) ||
        !Contains(fake.hooked, fake.base + kBlockCopyRva) || fake.hooked.size() != 3) {
      return Fail("hooks must land on the three pinned entry points");
    }
    if (fake.patched.size() != 1 || fake.patched[0] != kMinMaxScanRva ||
        fake.patch_size != kMinMaxPatchSize) {
      return Fail("the scan patch must be applied once at its RVA");
    }
    if (!Contains(fake.verified, kCalculateHeightModRva) || !Contains(fake.verified, kBicubicRefineRva) ||
        !Contains(fake.verified, 0x3af850) || !Contains(fake.verified, 0x2fadc0) ||
        !Contains(fake.verified, 0x33ce80) || !Contains(fake.verified, 0x33cfe6) ||
        !Contains(fake.verified, kBlockCopyRva) || !Contains(fake.verified, 0x2fb64c0)) {
      return Fail("every pinned region must be verified before patching");
    }
  }
  {
    FakeHost fake;
    fake.failing_rva = 0x3b0190;  // the alignment target constructor
    const Status status = Install(HostFor(fake), RequestFromMask(kFeatureAlign | kFeatureRefine));
    if (status.align || !status.refine || status.error.find("align: byte mismatch at 0x3b0190") == std::string::npos) {
      return Fail("a mismatching alignment region must refuse only the alignment path");
    }
    if (Contains(fake.hooked, fake.base + kCalculateHeightModRva)) {
      return Fail("a refused path must not hook");
    }
  }
  {
    FakeHost fake;
    fake.failing_rva = kBicubicRefineRva;
    const Status status = Install(HostFor(fake), RequestFromMask(kFeatureRefine));
    if (status.refine || status.error.find("refine: prologue mismatch") == std::string::npos) {
      return Fail("a mismatching refine prologue must refuse the refine path");
    }
  }
  {
    FakeHost fake;
    fake.failing_rva = kBlockCopyRva;
    const Status status = Install(HostFor(fake), RequestFromMask(kFeatureMinMax));
    if (status.minmax_scan || status.block_copy || !fake.patched.empty() || !fake.hooked.empty()) {
      return Fail("a minmax mismatch must refuse both halves before touching memory");
    }
  }
  {
    FakeHost fake;
    fake.patch_fails = true;
    const Status status = Install(HostFor(fake), RequestFromMask(kFeatureMinMax));
    if (status.minmax_scan || !status.block_copy ||
        status.error.find("minmax: scan patch failed") == std::string::npos) {
      return Fail("a failed scan patch must leave the block copy half installed");
    }
  }
  {
    FakeHost fake;
    fake.hook_fails = true;
    const Status status = Install(HostFor(fake), RequestFromMask(kFeatureAlign | kFeatureRefine));
    if (status.align || status.refine || status.error.find("align: hook failed") == std::string::npos ||
        status.error.find("refine: hook failed") == std::string::npos) {
      return Fail("hook failures must be reported per path");
    }
  }
  {
    FakeHost fake;
    fake.base = 0;
    const Status status = Install(HostFor(fake), RequestFromMask(kFeatureAlign));
    if (status.align || status.error.find("module base unavailable") == std::string::npos) {
      return Fail("a missing module base must refuse");
    }
  }
  {
    Request request = ParseRequest(L"align,bogus");
    FakeHost fake;
    const Status status = Install(HostFor(fake), request);
    if (StatusMask(status) != 0 || status.error.find("request: unknown token 'bogus'") == std::string::npos) {
      return Fail("an unparseable request must install nothing and say why");
    }
  }
  {
    // "stock,timing" hooks the three entry points as pass-through timers and
    // leaves the inline scan alone.
    FakeHost fake;
    const Status status = Install(HostFor(fake), ParseRequest(L"stock,timing"));
    if (StatusMask(status) != kStatusTiming || fake.hooked.size() != 4 || !fake.patched.empty() ||
        !status.error.empty()) {
      return Fail("stock timing must hook without enabling any fast path");
    }
    const auto timing = Timing();
    if (timing.align_calls != 0 || timing.scan_calls != 0) return Fail("timing counters start at zero");
  }
  {
    // Timing hooks every entry point (the others as pass-through timers), but
    // only the requested fast path is reported active and only it patches.
    FakeHost fake;
    const Status status = Install(HostFor(fake), ParseRequest(L"minmax,timing"));
    if (StatusMask(status) != (kStatusMinMaxScan | kStatusBlockCopy | kStatusTiming) ||
        fake.patched.size() != 1 || fake.hooked.size() != 4) {
      return Fail("minmax with timing patches the scan, hooks all four entry points, reports only minmax");
    }
  }
  {
    FakeHost fake;
    const Status status = Install(HostFor(fake), ParseRequest(L"align"));
    if (StatusMask(status) != kStatusAlign || fake.hooked.size() != 1 || !fake.patched.empty()) {
      return Fail("a single fast path without timing hooks only its own entry point");
    }
  }
  {
    FakeHost fake;
    const Status status = Install(HostFor(fake), ParseRequest(L"material"));
    if (StatusMask(status) != kStatusMaterial || fake.hooked.size() != 1 ||
        !Contains(fake.hooked, fake.base + tpf2mp::material_fast::kMaterialIndexRva) ||
        !Contains(fake.verified, tpf2mp::material_fast::kQuarterConstantRva) || !status.error.empty()) {
      return Fail("the material path verifies its body and constant, then hooks its entry point");
    }
  }
  {
    FakeHost fake;
    fake.failing_rva = tpf2mp::material_fast::kMaterialIndexRva;
    const Status status = Install(HostFor(fake), ParseRequest(L"material"));
    if (status.material || !fake.hooked.empty() || status.error.find("material: prologue mismatch") == std::string::npos) {
      return Fail("a material byte mismatch must refuse the material path");
    }
  }
  {
    // "stock,timing" also times the material routine as a pass-through.
    FakeHost fake;
    const Status status = Install(HostFor(fake), ParseRequest(L"stock,timing"));
    if (StatusMask(status) != kStatusTiming || fake.hooked.size() != 4) {
      return Fail("stock timing must hook the material routine too");
    }
  }
  return true;
}

// ----------------------------------------------------------------- material
int g_material_original_calls = 0;
void StubMaterialOriginal(std::uint64_t, std::uint64_t, std::uint64_t, std::uint64_t, const std::uintptr_t*,
                          const std::uint8_t*, const std::int32_t*, const std::uintptr_t*, const std::uintptr_t*) {
  ++g_material_original_calls;
}

bool MaterialValid() {
  using tpf2mp::material_fast::MaterialIndex;
  // One layer whose heights sit above every dither threshold selects that
  // layer for every unresolved pixel; heights below them select the fallback.
  std::vector<float> dither(63 * 63, 0.5f);
  std::vector<float> heights(8192, 100.0f);
  const float* map[1] = {heights.data()};
  std::uint8_t entry[24]{};
  const float* const* map_pointer = map;
  std::memcpy(entry, &map_pointer, sizeof map_pointer);
  entry[12] = 7;  // material id
  std::uint8_t layers[48]{};
  const std::uint8_t* entries = entry;
  std::memcpy(layers, &entries, sizeof entries);
  layers[24] = 3;  // fallback material
  const int stride = 66, count = 1;
  std::memcpy(layers + 36, &stride, sizeof stride);
  std::memcpy(layers + 40, &count, sizeof count);
  const std::int32_t cell[2] = {0, 0};
  const int w = 32, h = 16;
  std::vector<std::uint8_t> base(static_cast<std::size_t>(w) * h, 0);
  base[5] = 9;  // a pre-resolved pixel keeps its base material
  std::vector<std::uint8_t> output(65536, 0xaa);
  const std::uintptr_t overlay[4] = {0, 0, 0, 0};
  const std::uintptr_t baseVector[3] = {reinterpret_cast<std::uintptr_t>(base.data()), 0, 0};
  const std::uintptr_t outputVector[3] = {reinterpret_cast<std::uintptr_t>(output.data()), 0, 0};
  const auto pack = [](int lo, int hi) {
    return static_cast<std::uint64_t>(static_cast<std::uint32_t>(lo)) |
           (static_cast<std::uint64_t>(static_cast<std::uint32_t>(hi)) << 32);
  };
  g_material_original_calls = 0;
  MaterialIndex(StubMaterialOriginal, dither.data(), pack(w, h), pack(3, 4), pack(2, 1), pack(1, 2), overlay,
                layers, cell, baseVector, outputVector);
  if (g_material_original_calls != 0) return Fail("a measured material geometry must stay on the fast path");
  for (int y = h; y < 2 * h; ++y) {
    for (int x = 2 * w; x < 3 * w; ++x) {
      const std::uint8_t expected = (y == h && x == 2 * w + 5) ? 9 : 7;
      if (output[y * 256 + x] != expected) return Fail("material selection above the threshold");
    }
  }
  if (output[0] != 0xaa || output[(2 * h) * 256 + 2 * w] != 0xaa) return Fail("material writes stay inside the region");
  std::fill(heights.begin(), heights.end(), -100.0f);
  MaterialIndex(StubMaterialOriginal, dither.data(), pack(w, h), pack(3, 4), pack(2, 1), pack(1, 2), overlay,
                layers, cell, baseVector, outputVector);
  if (output[(h + 1) * 256 + 2 * w + 1] != 3) return Fail("material fallback below the threshold");
  // Unmeasured geometry and overlapping storage use the original.
  g_material_original_calls = 0;
  MaterialIndex(StubMaterialOriginal, dither.data(), pack(0, h), pack(3, 4), pack(2, 1), pack(1, 2), overlay,
                layers, cell, baseVector, outputVector);
  MaterialIndex(StubMaterialOriginal, dither.data(), pack(300, h), pack(3, 4), pack(0, 0), pack(1, 2), overlay,
                layers, cell, baseVector, outputVector);
  MaterialIndex(StubMaterialOriginal, dither.data(), pack(w, h), pack(3, 4), pack(2, 1), pack(4, 2), overlay,
                layers, cell, baseVector, outputVector);  // dx < 0
  const std::uintptr_t aliased[3] = {reinterpret_cast<std::uintptr_t>(output.data()) + 16, 0, 0};
  MaterialIndex(StubMaterialOriginal, dither.data(), pack(w, h), pack(3, 4), pack(2, 1), pack(1, 2), overlay,
                layers, cell, aliased, outputVector);
  if (g_material_original_calls != 4) return Fail("material fallbacks must use the original");
  const int none = 0;
  std::memcpy(layers + 40, &none, sizeof none);
  g_material_original_calls = 0;
  MaterialIndex(StubMaterialOriginal, dither.data(), pack(w, h), pack(3, 4), pack(2, 1), pack(1, 2), overlay,
                layers, cell, baseVector, outputVector);
  if (g_material_original_calls != 0) return Fail("an empty layer list returns like the original");
  return true;
}

// ------------------------------------------------------------------- minmax
std::uint32_t ReferenceMinMax(const std::uint16_t* begin, const std::uint16_t* end) {
  const std::uintptr_t b = reinterpret_cast<std::uintptr_t>(begin);
  const std::uintptr_t e = reinterpret_cast<std::uintptr_t>(end);
  const std::size_t n = b > e ? 0 : static_cast<std::size_t>((e - b + 1) >> 1);
  unsigned lo = begin[0], hi = begin[0];
  for (std::size_t i = 0; i < n; ++i) {
    const unsigned v = begin[i];
    if (v < lo) {
      lo = v;
    } else if (v > hi) {
      hi = v;
    }
  }
  return lo | (hi << 16);
}

bool MinMaxValid() {
  std::mt19937 rng(0x5eed);
  std::vector<std::uint16_t> values(400);
  for (int round = 0; round < 200; ++round) {
    const std::size_t n = 1 + rng() % 300;
    const int pattern = round % 4;
    for (std::size_t i = 0; i < n; ++i) {
      values[i] = pattern == 0   ? static_cast<std::uint16_t>(rng())
                  : pattern == 1 ? static_cast<std::uint16_t>(0x8000 + (rng() % 7))
                  : pattern == 2 ? static_cast<std::uint16_t>(0x1234)
                                 : static_cast<std::uint16_t>(rng() % 2 ? 0xffff : 0);
    }
    if (pattern == 3 && n > 3) {
      values[n / 2] = 0x8000;  // straddles the signed/unsigned bias
    }
    const std::uint16_t* begin = values.data();
    const std::uint16_t* end = begin + n;
    if (MinMaxScan(begin, end) != ReferenceMinMax(begin, end)) return Fail("minmax scan mismatch");
    // The stock count formula rounds an odd byte length up: end + 1 byte.
    const auto* odd_end = reinterpret_cast<const std::uint16_t*>(reinterpret_cast<const std::uint8_t*>(end) - 1);
    if (MinMaxScan(begin, odd_end) != ReferenceMinMax(begin, odd_end)) return Fail("minmax odd-length mismatch");
  }
  // begin > end scans nothing but still reads begin[0], like stock.
  values[1] = 0x4242;
  if (MinMaxScan(values.data() + 1, values.data()) != (0x4242u | (0x4242u << 16))) {
    return Fail("minmax reversed range");
  }
  std::uint8_t patch[kMinMaxPatchSize];
  const std::uintptr_t scan = 0x1122334455667788ull;
  BuildMinMaxPatch(patch, scan);
  const std::uint8_t head[] = {0x48, 0x89, 0xd1, 0x48, 0x89, 0xf2, 0x4c, 0x89, 0xde, 0x48, 0xb8};
  const std::uint8_t tail[] = {0xff, 0xd0, 0x49, 0x89, 0xf3, 0xf3, 0x41, 0x0f, 0x10, 0x56, 0x34,
                               0x44, 0x0f, 0xb7, 0xd0, 0xc1, 0xe8, 0x10, 0x89, 0xc1, 0xeb, 0x1c};
  std::uintptr_t embedded = 0;
  std::memcpy(&embedded, patch + sizeof head, sizeof embedded);
  if (std::memcmp(patch, head, sizeof head) != 0 || embedded != scan ||
      std::memcmp(patch + sizeof head + sizeof embedded, tail, sizeof tail) != 0) {
    return Fail("minmax patch layout");
  }
  for (std::size_t i = sizeof head + sizeof embedded + sizeof tail; i < kMinMaxPatchSize; ++i) {
    if (patch[i] != 0xcc) return Fail("minmax patch padding");
  }
  return true;
}

// --------------------------------------------------------------- block copy
int g_block_copy_original_calls = 0;
void ReferenceBlockCopy(const std::uint16_t* src, std::uint16_t* dst, int srcStride, int dstStride,
                        int srcX, int srcY, int w, int h, int dstX, int dstY) {
  ++g_block_copy_original_calls;
  if (h <= 0) return;
  const std::int64_t s0 =
      static_cast<std::int32_t>(static_cast<std::uint32_t>(srcStride) * static_cast<std::uint32_t>(srcY)) +
      static_cast<std::int64_t>(srcX);
  const std::int64_t d0 =
      static_cast<std::int32_t>(static_cast<std::uint32_t>(dstStride) * static_cast<std::uint32_t>(dstY)) +
      static_cast<std::int64_t>(dstX);
  for (std::int64_t r = 0; r < h; ++r) {
    for (std::int64_t i = 0; i < w; ++i) {
      dst[d0 + r * dstStride + i] = src[s0 + r * srcStride + i];
    }
  }
}

bool BlockCopyValid() {
  std::mt19937 rng(0xb10c);
  for (int round = 0; round < 300; ++round) {
    const int srcStride = 8 + static_cast<int>(rng() % 300);
    const int dstStride = 8 + static_cast<int>(rng() % 300);
    const int w = 1 + static_cast<int>(rng() % 8);
    const int h = 1 + static_cast<int>(rng() % 8);
    const int srcX = static_cast<int>(rng() % (srcStride - w + 1));
    const int dstX = static_cast<int>(rng() % (dstStride - w + 1));
    const int srcY = static_cast<int>(rng() % 5);
    const int dstY = static_cast<int>(rng() % 5);
    std::vector<std::uint16_t> source(static_cast<std::size_t>(srcStride) * (srcY + h + 1));
    for (auto& value : source) value = static_cast<std::uint16_t>(rng());
    std::vector<std::uint16_t> expected(static_cast<std::size_t>(dstStride) * (dstY + h + 1), 0x7777);
    std::vector<std::uint16_t> actual = expected;
    g_block_copy_original_calls = 0;
    ReferenceBlockCopy(source.data(), expected.data(), srcStride, dstStride, srcX, srcY, w, h, dstX, dstY);
    g_block_copy_original_calls = 0;
    BlockCopy(ReferenceBlockCopy, source.data(), actual.data(), srcStride, dstStride, srcX, srcY, w, h,
              dstX, dstY);
    if (actual != expected) return Fail("block copy mismatch");
    if (g_block_copy_original_calls != 0) return Fail("disjoint block copy must not fall back");
  }
  // Overlapping source and destination fall back to the original.
  std::vector<std::uint16_t> shared(64 * 8);
  for (auto& value : shared) value = static_cast<std::uint16_t>(rng());
  std::vector<std::uint16_t> expected = shared;
  ReferenceBlockCopy(expected.data(), expected.data(), 64, 64, 0, 0, 8, 4, 3, 1);
  g_block_copy_original_calls = 0;
  BlockCopy(ReferenceBlockCopy, shared.data(), shared.data(), 64, 64, 0, 0, 8, 4, 3, 1);
  if (g_block_copy_original_calls != 1 || shared != expected) return Fail("overlap must use the original");
  // Empty geometry touches nothing and calls nothing, even with null buffers.
  g_block_copy_original_calls = 0;
  BlockCopy(ReferenceBlockCopy, nullptr, nullptr, 64, 64, 0, 0, 0, 4, 0, 0);
  BlockCopy(ReferenceBlockCopy, nullptr, nullptr, 64, 64, 0, 0, 4, 0, 0, 0);
  if (g_block_copy_original_calls != 0) return Fail("empty block copy");
  return true;
}

// ------------------------------------------------------------------- refine
int g_refine_original_calls = 0;
void StubRefine(int, const ConstU16Vector*, int, int, int, int, int, const float*, std::uint16_t*,
                int, int, int) {
  ++g_refine_original_calls;
}

std::uint16_t Low16Truncated(float value) {
  if (!(value > -2147483648.0f && value < 2147483648.0f)) return 0;  // integer indefinite
  return static_cast<std::uint16_t>(static_cast<std::int32_t>(value));
}

// Scalar transcription of the stock operation order (see the port report).
void ReferenceRefine(int k, const std::uint16_t* src, int srcDim, int x0, int y0, int x1, int y1,
                     std::uint16_t* out, int stride, int dx, int dy) {
  std::vector<float> t1(k), t2(k), t3(k);
  for (int i = 0; i < k; ++i) {
    t1[i] = static_cast<float>(i) / static_cast<float>(k);
    t2[i] = t1[i] * t1[i];
    t3[i] = t2[i] * t1[i];
  }
  const int half = k >> 1;
  for (int y = y0; y < y1 - 1; ++y) {
    for (int x = x0; x < x1 - 1; ++x) {
      float a[3][3];
      for (int r = 0; r < 3; ++r) {
        for (int c = 0; c < 3; ++c) a[r][c] = static_cast<float>(src[(y + r) * srcDim + x + c]);
      }
      float s[4], h[4], xx[4], v[4];
      const float tl[4] = {a[0][0], a[0][1], a[1][0], a[1][1]};
      const float tr[4] = {a[0][1], a[0][2], a[1][1], a[1][2]};
      const float bl[4] = {a[1][0], a[1][1], a[2][0], a[2][1]};
      const float br[4] = {a[1][1], a[1][2], a[2][1], a[2][2]};
      for (int l = 0; l < 4; ++l) {
        s[l] = (((tr[l] + tl[l]) + bl[l]) + br[l]) * 0.25f;
        const float hTop = tr[l] - tl[l], hBottom = br[l] - bl[l];
        h[l] = (hTop + hBottom) * 0.5f;
        xx[l] = hBottom - hTop;
        v[l] = ((bl[l] - tl[l]) + (br[l] - tr[l])) * 0.5f;
      }
      // G rows: lane r of g0..g3.
      const float g0[4] = {s[0], s[2], v[0], v[2]};
      const float g1[4] = {s[1], s[3], v[1], v[3]};
      const float g2[4] = {h[0], h[2], xx[0], xx[2]};
      const float g3[4] = {h[1], h[3], xx[1], xx[3]};
      float t[4][4];  // T[r][c]
      for (int r = 0; r < 4; ++r) {
        t[r][0] = g0[r];
        t[r][1] = g2[r];
        t[r][2] = ((g0[r] * -3.0f + g1[r] * 3.0f) + g2[r] * -2.0f) - g3[r];
        t[r][3] = ((g0[r] * 2.0f + g1[r] * -2.0f) + g2[r]) + g3[r];
      }
      float c[4][4];  // C[r][c]
      for (int col = 0; col < 4; ++col) {
        c[0][col] = t[0][col];
        c[1][col] = t[2][col];
        c[2][col] = ((t[0][col] * -3.0f + t[1][col] * 3.0f) + t[2][col] * -2.0f) - t[3][col];
        c[3][col] = ((t[0][col] * 2.0f + t[1][col] * -2.0f) + t[2][col]) + t[3][col];
      }
      for (int i = 0; i < k; ++i) {
        float p[4];
        for (int col = 0; col < 4; ++col) {
          p[col] = ((c[1][col] * t1[i] + c[0][col]) + t2[i] * c[2][col]) + c[3][col] * t3[i];
        }
        const int row = (k * (y - y0) + half + dy) + i;
        for (int j = 0; j < k; ++j) {
          const float value = ((p[1] * t1[j] + p[0]) + t2[j] * p[2]) + p[3] * t3[j];
          out[row * stride + k * (x - x0) + half + dx + j] = Low16Truncated(value);
        }
      }
    }
  }
}

bool RefineValid() {
  std::mt19937 rng(0xbc1c);
  const int factors[] = {2, 4, 8, 16};
  for (int round = 0; round < 120; ++round) {
    const int k = factors[round % 4];
    const int srcDim = 4 + static_cast<int>(rng() % 12);
    const int x0 = static_cast<int>(rng() % (srcDim - 2));
    const int y0 = static_cast<int>(rng() % (srcDim - 2));
    const int x1 = x0 + 2 + static_cast<int>(rng() % (srcDim - x0 - 1));
    const int y1 = y0 + 2 + static_cast<int>(rng() % (srcDim - y0 - 1));
    const int dx = static_cast<int>(rng() % 3), dy = static_cast<int>(rng() % 3);
    const int half = k >> 1;
    const int stride = k * (x1 - x0 - 1) + half + dx + k + static_cast<int>(rng() % 5);
    const int rows = k * (y1 - y0 - 1) + half + dy + k;
    std::vector<std::uint16_t> source(static_cast<std::size_t>(srcDim) * (srcDim + 2));
    const int amplitude = round % 3 == 0 ? 0xffff : round % 3 == 1 ? 4096 : 64;
    for (auto& value : source) value = static_cast<std::uint16_t>(rng() % (amplitude + 1));
    std::vector<std::uint16_t> expected(static_cast<std::size_t>(rows) * stride, 0xabcd);
    std::vector<std::uint16_t> actual = expected;
    ReferenceRefine(k, source.data(), srcDim, x0, y0, x1, y1, expected.data(), stride, dx, dy);
    const ConstU16Vector vector{source.data(), source.data() + source.size(), source.data() + source.size()};
    const float scale = 1.0f;
    g_refine_original_calls = 0;
    BicubicRefine(StubRefine, k, &vector, srcDim, x0, y0, x1, y1, &scale, actual.data(), stride, dx, dy);
    if (g_refine_original_calls != 0) return Fail("valid refine input must stay on the fast path");
    if (actual != expected) return Fail("refine mismatch against the scalar transcription");
  }
  // Stock assert conditions and k > 64 forward to the original untouched.
  std::vector<std::uint16_t> source(64), out(4096, 1);
  const ConstU16Vector vector{source.data(), source.data() + 64, source.data() + 64};
  const float scale = 1.0f;
  const int bad[][7] = {{3, 8, 0, 0, 4, 4, 0}, {0, 8, 0, 0, 4, 4, 0}, {4, 8, -1, 0, 4, 4, 0},
                        {4, 8, 0, -1, 4, 4, 0}, {4, 8, 0, 0, 9, 4, 0}, {4, 8, 3, 0, 2, 4, 0},
                        {4, 8, 0, 3, 4, 2, 0}, {128, 8, 0, 0, 4, 4, 0}};
  for (const auto& parameters : bad) {
    g_refine_original_calls = 0;
    std::vector<std::uint16_t> before = out;
    BicubicRefine(StubRefine, parameters[0], &vector, parameters[1], parameters[2], parameters[3],
                  parameters[4], parameters[5], &scale, out.data(), 32, 0, 0);
    if (g_refine_original_calls != 1 || out != before) return Fail("refine assert inputs must use the original");
  }
  g_refine_original_calls = 0;
  BicubicRefine(StubRefine, 4, &vector, 8, 2, 2, 3, 3, &scale, out.data(), 32, 0, 0);  // zero-iteration loops
  if (g_refine_original_calls != 0) return Fail("degenerate refine ranges run nothing");
  return true;
}

// -------------------------------------------------------------------- align
struct AlignFixture {
  std::int32_t sizeX{}, sizeY{};
  std::vector<std::uint16_t> heights[3];
  std::vector<std::uint16_t> weights[3];
  std::vector<float> triangles_seen;
  void* rasterizers[3]{};  // targets 0 and 1 share a vtable: identify by init order
  int init_calls = 0;
  int triangle_calls = 0;
  std::mt19937 rng{0xa11e};
};
AlignFixture* g_align_fixture = nullptr;
int g_align_original_calls = 0;

void StubOriginalHeightMod(const float*, const std::int32_t*, float, float, const PointerVector*, U16Vector*) {
  ++g_align_original_calls;
}

// The stub rasteriser records the target in the rasterizer memory, then
// paints a deterministic pattern per triangle into the target's pooled
// vectors and mirrors it into the fixture for the reference blend.
void* StubRasterInit(void* rasterizer, void* target, const float*, const float*, const std::int32_t*, std::uint8_t) {
  std::memcpy(rasterizer, &target, sizeof target);
  if (g_align_fixture->init_calls < 3) g_align_fixture->rasterizers[g_align_fixture->init_calls] = rasterizer;
  ++g_align_fixture->init_calls;
  return rasterizer;
}

std::uint8_t StubRasterTriangle(void* rasterizer, std::uint64_t, std::uint64_t, std::uint64_t) {
  std::uint8_t* target = nullptr;
  std::memcpy(&target, rasterizer, sizeof target);
  int type = 0;
  for (int index = 0; index < 3; ++index) {
    if (g_align_fixture->rasterizers[index] == rasterizer) type = index;
  }
  std::uintptr_t vtable = 0;
  std::memcpy(&vtable, target, sizeof vtable);
  if ((type == 2) != (vtable == 0x2222)) return 0;  // the target's vtable must match its slot
  std::uint16_t* heights = nullptr;
  std::uint16_t* weights = nullptr;
  std::memcpy(&heights, target + 0x50, sizeof heights);
  std::memcpy(&weights, target + 0x68, sizeof weights);
  float triangle[12];
  std::memcpy(triangle, target + 0x08, sizeof triangle);
  for (const float value : triangle) g_align_fixture->triangles_seen.push_back(value);
  auto& fixture = *g_align_fixture;
  const std::size_t samples = static_cast<std::size_t>(fixture.sizeX) * fixture.sizeY;
  const std::size_t step = 1 + fixture.rng() % 5;
  for (std::size_t n = fixture.rng() % 3; n < samples; n += step) {
    const std::uint16_t height = static_cast<std::uint16_t>(fixture.rng());
    const int roll = static_cast<int>(fixture.rng() % 8);
    const std::uint16_t weight = roll == 0 ? 0xffff : roll == 1 ? 0 : static_cast<std::uint16_t>(fixture.rng());
    heights[n] = height;
    weights[n] = weight;
    fixture.heights[type][n] = height;
    fixture.weights[type][n] = weight;
  }
  ++fixture.triangle_calls;
  return 1;
}

std::int32_t FloorToInt32(float value) {
  std::int32_t truncated = INT32_MIN;
  if (value > -2147483648.0f && value < 2147483648.0f) truncated = static_cast<std::int32_t>(value);
  if (truncated != INT32_MIN && value < static_cast<float>(truncated)) --truncated;
  return truncated;
}

// Scalar transcription of the stock blend (docs: terrain-alignment-speed).
bool ReferenceBlend(const AlignFixture& fixture, float scale, float offset, std::vector<std::uint16_t>& result) {
  const float invScale = 1.0f / scale;
  const std::size_t samples = static_cast<std::size_t>(fixture.sizeX) * fixture.sizeY;
  for (std::size_t n = 0; n < samples; ++n) {
    const std::uint16_t wA = fixture.weights[0][n], wB = fixture.weights[1][n], wC = fixture.weights[2][n];
    if ((wA | wB | wC) == 0) continue;
    const float heightR = static_cast<float>(result[n]) * scale + offset;
    const float hA = static_cast<float>(fixture.heights[0][n]) * scale + offset;
    const float hB = static_cast<float>(fixture.heights[1][n]) * scale + offset;
    const float hC = static_cast<float>(fixture.heights[2][n]) * scale + offset;
    const float fA = static_cast<float>(wA) / 65535.0f;
    float fB = static_cast<float>(wB) / 65535.0f;
    float fC = static_cast<float>(wC) / 65535.0f;
    float lower = (fC > 0.0f && hC > heightR) ? hC : heightR;
    lower = lower > hB ? hB : lower;
    float higher = (fB > 0.0f && heightR > hB) ? hB : heightR;
    higher = hC > higher ? hC : higher;
    fB = lower == hB ? fB : 0.0f;
    fC = higher == hC ? fC : 0.0f;
    const float sum = (fB + fA) + fC;
    if (sum == 0.0f) continue;
    const bool oneA = fA == 1.0f, oneB = fB == 1.0f, oneC = fC == 1.0f;
    if (oneA && oneB) fB = 0.0f;
    if (oneC && (oneA || oneB)) fC = 0.0f;
    const float restA = 1.0f - fA, restB = 1.0f - fB, restC = 1.0f - fC;
    const float weightA = (restB * fA) * restC;
    const float weightB = (restA * fB) * restC;
    const float weightC = (restA * restB) * fC;
    const float total = (weightB + weightA) + weightC;
    if (!(total > 0.0f)) return false;
    float value = ((lower * weightB + weightA * hA) + higher * weightC) / total;
    value = (value - offset) * invScale + 0.5f;
    result[n] = static_cast<std::uint16_t>(FloorToInt32(value));
  }
  return true;
}

struct AlignmentBlob {
  std::vector<float> triangles;
  std::vector<float> weights;
  std::uint8_t bytes[0x38]{};
  void Build(int triangle_count, bool with_weights, std::int32_t type, std::mt19937& rng) {
    triangles.resize(static_cast<std::size_t>(triangle_count) * 9);
    for (auto& value : triangles) value = static_cast<float>(rng() % 1000) * 0.25f;
    weights.clear();
    if (with_weights) {
      weights.resize(static_cast<std::size_t>(triangle_count) * 3);
      for (auto& value : weights) value = static_cast<float>(rng() % 100) * 0.01f;
    }
    const std::uintptr_t first = reinterpret_cast<std::uintptr_t>(triangles.data());
    const std::uintptr_t last = first + triangles.size() * sizeof(float);
    std::memcpy(bytes + 0x00, &first, 8);
    std::memcpy(bytes + 0x08, &last, 8);
    std::memcpy(bytes + 0x10, &last, 8);
    const std::uintptr_t wfirst = with_weights ? reinterpret_cast<std::uintptr_t>(weights.data()) : 0;
    const std::uintptr_t wlast = with_weights ? wfirst + weights.size() * sizeof(float) : 0;
    std::memcpy(bytes + 0x18, &wfirst, 8);
    std::memcpy(bytes + 0x20, &wlast, 8);
    std::memcpy(bytes + 0x28, &wlast, 8);
    std::memcpy(bytes + 0x30, &type, 4);
  }
};

bool AlignValid() {
  AlignEngine engine{};
  engine.raster_init = StubRasterInit;
  engine.raster_triangle = StubRasterTriangle;
  engine.vtable_less_equal = 0x1111;
  engine.vtable_greater_equal = 0x2222;
  std::mt19937 rng(0x7a1d);
  const int shapes[][2] = {{2, 2}, {5, 3}, {8, 8}, {9, 7}, {17, 17}, {65, 65}, {257, 257}};
  for (int round = 0; round < 40; ++round) {
    AlignFixture fixture;
    g_align_fixture = &fixture;
    const auto& shape = shapes[round % 7];
    fixture.sizeX = shape[0];
    fixture.sizeY = shape[1];
    const std::size_t samples = static_cast<std::size_t>(fixture.sizeX) * fixture.sizeY;
    for (int t = 0; t < 3; ++t) {
      fixture.heights[t].assign(samples, t == 2 ? 0 : 0xffff);
      fixture.weights[t].assign(samples, 0);
    }
    std::vector<std::uint16_t> result(samples);
    for (auto& value : result) value = static_cast<std::uint16_t>(rng());
    std::vector<std::uint16_t> expected = result;
    AlignmentBlob blobs[4];
    const std::uint8_t* pointers[4];
    for (int b = 0; b < 4; ++b) {
      blobs[b].Build(1 + static_cast<int>(rng() % 3), b % 2 == 0, b == 3 ? 2 : b % 2, rng);
      pointers[b] = blobs[b].bytes;
    }
    const PointerVector list{pointers, pointers + 4, pointers + 4};
    const float scale = round % 2 ? 0.05f : 0.25f;
    const float offset = round % 3 ? -100.0f : 12.5f;
    const float box[4] = {0.0f, 0.0f, 64.0f, 64.0f};
    const std::int32_t size[2] = {fixture.sizeX, fixture.sizeY};
    U16Vector vector{result.data(), result.data() + samples, result.data() + samples};
    g_align_original_calls = 0;
    CalculateHeightMod(StubOriginalHeightMod, engine, box, size, scale, offset, &list, &vector);
    if (g_align_original_calls != 0) return Fail("a supported alignment call must stay on the fast path");
    if (fixture.init_calls != 3) return Fail("three rasterisation targets must be initialised");
    if (!ReferenceBlend(fixture, scale, offset, expected)) return Fail("reference blend hit the unreachable assert");
    if (result != expected) return Fail("alignment blend mismatch against the scalar transcription");
  }
  // Weightless alignments rasterise with the stock (1,1,1) weights.
  {
    AlignFixture fixture;
    g_align_fixture = &fixture;
    fixture.sizeX = fixture.sizeY = 4;
    for (int t = 0; t < 3; ++t) {
      fixture.heights[t].assign(16, 0);
      fixture.weights[t].assign(16, 0);
    }
    AlignmentBlob blob;
    blob.Build(1, false, 0, rng);
    const std::uint8_t* pointer = blob.bytes;
    const PointerVector list{&pointer, &pointer + 1, &pointer + 1};
    std::vector<std::uint16_t> result(16, 7);
    U16Vector vector{result.data(), result.data() + 16, result.data() + 16};
    const float box[4] = {0.0f, 0.0f, 4.0f, 4.0f};
    const std::int32_t size[2] = {4, 4};
    CalculateHeightMod(StubOriginalHeightMod, engine, box, size, 1.0f, 0.0f, &list, &vector);
    if (fixture.triangles_seen.size() != 12 || fixture.triangles_seen[9] != 1.0f ||
        fixture.triangles_seen[10] != 1.0f || fixture.triangles_seen[11] != 1.0f) {
      return Fail("weightless alignments must rasterise with unit weights");
    }
    // Vertex order is reversed into the target: vertex 2 first.
    if (fixture.triangles_seen[0] != blob.triangles[6] || fixture.triangles_seen[6] != blob.triangles[0]) {
      return Fail("triangle vertices must be copied in stock field order");
    }
  }
  // Fallbacks: the stock assert, small sides, oversized blocks, malformed
  // lists and unindexable types run the original with untouched arguments.
  {
    AlignFixture fixture;
    g_align_fixture = &fixture;
    fixture.sizeX = fixture.sizeY = 4;
    std::vector<std::uint16_t> result(16, 9);
    const std::vector<std::uint16_t> untouched = result;
    U16Vector vector{result.data(), result.data() + 16, result.data() + 16};
    const float box[4] = {0.0f, 0.0f, 4.0f, 4.0f};
    AlignmentBlob good, bad;
    good.Build(1, true, 1, rng);
    bad.Build(1, true, 5, rng);
    const std::uint8_t* good_pointer = good.bytes;
    const std::uint8_t* bad_pointer = bad.bytes;
    const PointerVector good_list{&good_pointer, &good_pointer + 1, &good_pointer + 1};
    const PointerVector bad_list{&bad_pointer, &bad_pointer + 1, &bad_pointer + 1};
    const PointerVector reversed{&good_pointer + 1, &good_pointer, &good_pointer};
    const std::int32_t mismatch[2] = {4, 5};
    const std::int32_t thin[2] = {1, 16};
    const std::int32_t ok[2] = {4, 4};
    struct Case { const std::int32_t* size; const PointerVector* list; const AlignEngine* engine; };
    AlignEngine no_engine{};
    const Case cases[] = {{mismatch, &good_list, &engine}, {thin, &good_list, &engine},
                          {ok, &reversed, &engine}, {ok, &bad_list, &engine}, {ok, &good_list, &no_engine}};
    for (const auto& c : cases) {
      g_align_original_calls = 0;
      CalculateHeightMod(StubOriginalHeightMod, *c.engine, box, c.size, 1.0f, 0.0f, c.list, &vector);
      if (g_align_original_calls != 1 || result != untouched) return Fail("alignment fallback must use the original");
    }
    // An unindexable type on an empty triangle vector is never read by stock: fast path.
    AlignmentBlob empty;
    empty.Build(0, true, 5, rng);
    const std::uint8_t* empty_pointer = empty.bytes;
    const PointerVector empty_list{&empty_pointer, &empty_pointer + 1, &empty_pointer + 1};
    for (int t = 0; t < 3; ++t) {
      fixture.heights[t].assign(16, 0);
      fixture.weights[t].assign(16, 0);
    }
    g_align_original_calls = 0;
    CalculateHeightMod(StubOriginalHeightMod, engine, box, ok, 1.0f, 0.0f, &empty_list, &vector);
    if (g_align_original_calls != 0 || fixture.triangle_calls != 0) return Fail("empty triangle vectors stay fast");
  }
  {
    // 1025 x 1025 exceeds the 1<<20 sample bound.
    AlignFixture fixture;
    g_align_fixture = &fixture;
    const std::size_t samples = 1025u * 1025u;
    std::vector<std::uint16_t> result(samples, 1);
    U16Vector vector{result.data(), result.data() + samples, result.data() + samples};
    const float box[4] = {0.0f, 0.0f, 4.0f, 4.0f};
    const std::int32_t size[2] = {1025, 1025};
    const PointerVector list{nullptr, nullptr, nullptr};
    g_align_original_calls = 0;
    CalculateHeightMod(StubOriginalHeightMod, engine, box, size, 1.0f, 0.0f, &list, &vector);
    if (g_align_original_calls != 1) return Fail("oversized blocks must use the original");
  }
  g_align_fixture = nullptr;
  return true;
}

}  // namespace

bool TerrainFastPathsValid() {
  return RequestParsingValid() && InstallerValid() && MinMaxValid() && BlockCopyValid() &&
         RefineValid() && AlignValid() && MaterialValid();
}
