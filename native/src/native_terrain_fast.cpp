// Bit-identical terrain fast paths for Build 35924. Ported from silver2127's
// tpf2-bigmap plugin, commit 4f0de6f (MIT): src/terrain_align_fast.h,
// src/terrain_refine.h and src/terrain_minmax.h, with its plugin-host calls
// replaced by the Host seam in native_terrain_fast.hpp. The arithmetic is kept
// operation for operation: every float value is produced by the same IEEE
// single-precision operation on the same operands in the same grouping as the
// stock code (no FMA, no reassociation), so the outputs are identical bytes.
// tests/native_terrain_fast/ executes the original machine code beside these
// implementations and compares complete output buffers.

#include "tpf2mp/native_terrain_fast.hpp"

#include "tpf2mp/native_material_fast.hpp"

#include <Windows.h>

#include <emmintrin.h>
#include <intrin.h>
#include <malloc.h>

#include <atomic>
#include <cstdio>
#include <cstring>
#include <string>
#include <vector>

namespace tpf2mp::terrain_fast {
namespace {

// ------------------------------------------------------------------ helpers
struct Region {
  std::uintptr_t rva;
  std::uint32_t size;
  const char* hex;
};

bool DecodeHex(const Region& region, std::vector<std::uint8_t>& bytes) {
  if (std::strlen(region.hex) != static_cast<std::size_t>(region.size) * 2) return false;
  bytes.assign(region.size, 0);
  for (std::uint32_t index = 0; index < region.size; ++index) {
    int value = 0;
    for (int nibble = 0; nibble < 2; ++nibble) {
      const char c = region.hex[2 * index + nibble];
      const int digit = c >= '0' && c <= '9' ? c - '0'
                        : c >= 'a' && c <= 'f' ? c - 'a' + 10
                                               : -256;
      value = value * 16 + digit;
    }
    if (value < 0) return false;
    bytes[index] = static_cast<std::uint8_t>(value);
  }
  return true;
}

bool VerifyRegion(const Host& host, const Region& region) {
  std::vector<std::uint8_t> bytes;
  if (!DecodeHex(region, bytes)) return false;
  return host.verify_bytes(host.context, region.rva, bytes.data(), bytes.size()) != 0;
}

void AppendError(Status& status, const std::string& message) {
  if (!status.error.empty()) status.error += "; ";
  status.error += message;
}

std::string HexRva(std::uintptr_t rva) {
  char text[32]{};
  std::snprintf(text, sizeof text, "0x%llx", static_cast<unsigned long long>(rva));
  return text;
}

// =================================================================== refine
// sub_terrain_util::InternBicubicRefine at RVA 0x3ac6c0. Called once per
// BaseGetHeightmapRefined (0x3c4620) from TerrainAlignment ThreadPool workers;
// refines the 4 m base heightmap into the 1 m/2 m cache. What changed against
// stock: i/k and j/k (and their squares/cubes) are computed once per call
// instead of per cell; the two CMat4f products (0x2fadc0) with the constant
// Hermite matrices are inlined, dropping only terms multiplied by exactly 0.0
// or 1.0 (with finite inputs that can change nothing but the sign of a zero,
// which no later +, -, * or the final truncation observes); scalar operations
// on independent values are packed four wide. Cells are visited in stock order
// and each cell reads its samples before writing its pixels, so aliasing
// buffers behave like the original. Stock asserts and k > 64 use the original.
constexpr int kBicubicRefineMaxFactor = 64;
BicubicRefineFn g_original_bicubic_refine = nullptr;

// ------------------------------------------------------- dispatch and timing
// A hooked routine runs its fast path when the matching flag is set and the
// original otherwise ("stock,timing"); with timing on, every call is wall
// clocked with QueryPerformanceCounter so a load can be attributed per routine.
bool g_align_fast = false;
bool g_refine_fast = false;
bool g_block_copy_fast = false;
bool g_timing = false;
std::atomic<std::uint64_t> g_align_calls{0}, g_align_ticks{0};
std::atomic<std::uint64_t> g_refine_calls{0}, g_refine_ticks{0};
std::atomic<std::uint64_t> g_block_copy_calls{0}, g_block_copy_ticks{0};
std::atomic<std::uint64_t> g_scan_calls{0}, g_scan_ticks{0};

struct ScopedTicks {
  std::atomic<std::uint64_t>& calls;
  std::atomic<std::uint64_t>& ticks;
  LARGE_INTEGER start{};
  ScopedTicks(std::atomic<std::uint64_t>& call_counter, std::atomic<std::uint64_t>& tick_counter)
      : calls(call_counter), ticks(tick_counter) {
    QueryPerformanceCounter(&start);
  }
  ~ScopedTicks() {
    LARGE_INTEGER end{};
    QueryPerformanceCounter(&end);
    ticks.fetch_add(static_cast<std::uint64_t>(end.QuadPart - start.QuadPart), std::memory_order_relaxed);
    calls.fetch_add(1, std::memory_order_relaxed);
  }
};

double Seconds(std::uint64_t ticks) {
  LARGE_INTEGER frequency{};
  QueryPerformanceFrequency(&frequency);
  return frequency.QuadPart > 0 ? static_cast<double>(ticks) / static_cast<double>(frequency.QuadPart) : 0.0;
}

// The scan patch calls this variant while timing is on.
std::uint32_t MinMaxScanTimed(const std::uint16_t* begin, const std::uint16_t* end) {
  ScopedTicks timer(g_scan_calls, g_scan_ticks);
  return MinMaxScan(begin, end);
}

constexpr std::uint8_t kBicubicRefinePrologue[20] = {
    0x40, 0x55, 0x53, 0x41, 0x57,                          // push rbp; push rbx; push r15
    0x48, 0x8d, 0xac, 0x24, 0xc0, 0xfd, 0xff, 0xff,        // lea rbp,[rsp-0x240]
    0x48, 0x81, 0xec, 0x40, 0x03, 0x00, 0x00               // sub rsp,0x340
};
// Everything the replacement reproduces: the function body, its CMat4f product
// and the RIP-relative constants it loads.
const Region kBicubicRefineRegions[] = {
    {0x3ac6d4, 2172,  // InternBicubicRefine body after the hook prologue
     "488b05ddfae1034833c448898560010000488b85a0020000458bd94c63bda80200008bd9448b95b802000044894c2438448b8db0020000488945b8488955b083f9010f8e8e07"
     "0000f6c3010f85850700004585db0f885b0700008b8d8002000085c90f88f20700008b8588020000413bc00f8fc2070000413bc30f8c980700008b95900200003bd10f8c6907"
     "00000f2805c7b6bf020f280de0b6bf024889bc2430030000418bfb0faffb0f2985a00000000f280584b6bf020f298db00000000f280d66b6bf02442bcf4c89a424280300000f"
     "2985c0000000448be30f2805ea43b702440fafe10f298dd00000000f280da842b7020f2985e00000000f28053a7fc002452bd40f298df00000000f280d197fc002ffca897c24"
     "4044894c243444895424300f2985000100000f298d100100003bca0f8d51060000448d50ff4889b424380300004c89ac2420030000418bc00fafc14c89b424180300000f29b4"
     "24000300000f29bc24f0020000440f298424e00200004103c3440f298c24d00200004c63e8440f299424c00200004963c048894424484803c048894424504e8d0c6d04000000"
     "440f299c24b00200008d4102410fafc0440f29a424a0020000440f29ac2490020000440f29b42480020000440f29bc24700200004103c3448954243c4c63f08d4101410fafc0"
     "4c896c24584c894c24604103c34c63c04d2bc64d2bf52bd14c8945d0488b4c24488bc2488b54245048894424684c8975c890453bda0f8dd30400004b8d0c2e498bf1488bc145"
     "8bf2492bc5492bcd4c03c04c8be94c8945c0452bf30f1f8000000000488b45b0488b100fb74416fc66440f6ec80fb74416fe450f5bc9660f6ed00fb704160f5bd266440f6ee0"
     "488d0416420fb74c40fc440f28c2488d0416450f5be4660f6ec9f3450f5cc1420fb74c40fe410f28f40f5bc9488d0416660f6ee9f30f5cf2420fb70c40488d0416f30f114c24"
     "200f5bed660f6ec1420fb74c68fc440f28f50f5bc0488d0416f3440f5cf166440f6ef9420fb74c68fe0f28e5f30f11442424f30f5ce2440f28d8488d04160f28c2f3440f5cdd"
     "f3410f58c1660f6ed9420fb70c680f5bdbf30f58c166440f6ed1410f28cc440f28ebf30f58ca0f28fbf30f10542424f30f5cfd450f5bfff30f58c5f30f58cd450f5bd2f30f59"
     "05f33fb702f3450f5ceff30f58caf3440f11542428f3440f5cd3f30f114560410f28c0f3410f58c6f30f590dc83fb702f30f5905341fb702f30f114d640f28cef3410f58cbf3"
     "0f1145680f28c5f30f58442420f30f590d111fb702f3410f58c7f30f114d6c0f28caf30f58c3f30f5905843fb702f30f114570f30f10542428f30f58cdf30f106c24244c8d45"
     "60410f28c6488d95a0000000f3410f58c5f3450f5ceef30f58cbf30f105c2420f3440f5cfb488d4dd8f30f5905af1eb702f30f58caf3440f11ad98000000f30f5cd5f30f1145"
     "78f3440f58ff0f28c3f3410f5cc1f3440f100d831eb702f30f590d073fb702f30f58d7f3450f59f9f30f114d74f30f58c4410f28cbf3410f58caf3440f11bd90000000f3410f"
     "59d1f3450f5cd3f3410f59c1f30f590d401eb702f30f118580000000410f28c6f3410f5cc0f30f119594000000f30f114d7c0f28cdf3410f5cccf3440f11959c000000f30f11"
     "8588000000f30f58ccf3410f59c9f30f118d84000000410f28cbf30f5ccef30f118d8c000000e81be2f4ff4c8d85e0000000488d9520010000488d4d180f10000f1048100f29"
     "85200100000f1040200f298d300100000f1048300f2985400100000f298d50010000e8d9e1f4ff4533c00f10000f1048100f294424700f294d800f1040200f1048300f294590"
     "0f294da085db0f8e770100004d8bd766440f6ecb4d03d28bcb450f5bc985db79038d4b01f3440f1055acf3440f105da8f3440f1065a4f3440f106da0f3440f10759cf3440f10"
     "7d98d1f9418d040c03442430410fafc703c703c1488b4db80344243448984c8d0c416690f30f106d800f57d2f30f107584410f28cdf30f107d8833c9f3440f10458c498bd1f3"
     "410f2ad0f3410f5ed10f28e2f30f59eaf30f59e2f30f586c2470f30f59f20f28c4f30f59faf30f5945900f28dcf30f58742474f30f587c2478f30f58e8f30f59da0f28c4f344"
     "0f59c2f30f594594f3440f5844247cf30f59cbf30f58f00f28c4f3410f59c7f30f58e9f3410f59e6f30f58f8410f28ccf30f59cb410f28c2f3440f58c4f30f59c3f30f58f141"
     "0f28cbf30f59cbf3440f58c0f30f58f96690660f6ec10f28d60f5bc0ffc1f3410f5ec1f30f59d00f28d8f30f59d8f30f58d50f28cbf30f59dff30f59c8410f28c0f30f58d3f3"
     "0f59c1f30f58d0f30f2cc26689024883c2023bcb7cb641ffc04d03ca443bc30f8ce7feffff4c8b45c04883c60203fb4983ee010f8583fbffff4c8b6c2458448b5c24384c8b4c"
     "2460488b442468448b54243c8b7c24404c8b75c84c8b45d0488b4c2448488b5424504c03e94c03ca4403e34c896c24584883e8014c894c246048894424680f8502fbffff440f"
     "28bc2470020000440f28b42480020000440f28ac2490020000440f28a424a0020000440f289c24b0020000440f289424c0020000440f288c24d0020000440f288424e0020000"
     "0f28bc24f00200000f28b424000300004c8bb424180300004c8bac2420030000488bb42438030000488bbc24300300004c8ba42428030000488b8d600100004833cce8b36b84"
     "024881c440030000415f5b5dc34c8d0db075c00241b858000000488d15d374c002488d0d4c75c002e847dfe601cc4c8d0d8f75c00241b856000000488d15b274c002488d0d43"
     "76c002e826dfe601cc4c8d0d6e75c00241b85d000000488d159174c002488d0d4a75c002e805dfe601cc4c8d0d4d75c00241b85c000000488d157074c002488d0d1975c002e8"
     "e4dee601cc4c8d0d2c75c00241b85a000000488d154f74c002488d0df875c002e8c3dee601cc4c8d0d0b75c00241b859000000488d152e74c002488d0daf74c002e8a2dee601"
     "cccc"},
    {0x2fadc0, 507,  // CMat4f product called twice per cell
     "4883ec28f3410f104834f3410f104024f3410f1050140f14d1f3410f104830f3410f1020f3410f10680cf30f105a080f29742410f3410f1070080f293c24f3410f1078040f14"
     "f8f3410f1040200f14faf3410f1050100f14d1f3410f1048380f14e0f3410f1040280f14e2f3410f1050180f14d1f3410f10483c0f14f0f3410f10402c0f14f2f3410f10501c"
     "0f14d1f30f104a200f14e8f30f10020f14eaf30f1052100fc6d2000f59d70fc6c0000f59c40fc6c9000f59ce0f58d00fc6db00f30f1042300fc6c0000f59c50f58d10f59dcf3"
     "0f104a240fc6c9000f59ce0f58d0f30f1042040fc6c0000f59c4f30f11110fc6d2e5f30f1151100f15d2f30f1151200f15d2f30f115130f30f1052140fc6d2000f59d70f58d0"
     "f30f1042340fc6c0000f59c50f58d10f58d0f30f1042180fc6c0000f59c7f30f1151040fc6d2e5f30f1151140f58d80f15d2f30f1151240f15d2f30f115134f30f104a28488b"
     "c1f30f104238f30f10520c0fc6c0000f59c50fc6d2000f59d40fc6c9000f59ce0f58d9f30f104a2c0fc6c9000f59ce0f287424100f58d8f30f10421c0fc6c0000f59c70f283c"
     "24f30f1159080fc6dbe50f58d0f30f115918f30f10423c0f15db0fc6c0000f59c50f58d1f30f1159280f15dbf30f1159380f58d0f30f11510c0fc6d2e5f30f11511c0f15d2f3"
     "0f11512c0f15d2f30f11513c4883c428c3"},
    {0x2f1e988, 4, "0000003f"},                          // 0.5f
    {0x2f20a14, 4, "0000803e"},                          // 0.25f
    {0x2f20a70, 16, "00000000000000000000803f00000000"}, // M2 row 1
    {0x2f20ba0, 16, "0000803f000000000000000000000000"}, // M2 row 0
    {0x2fa7e00, 32, "0000000000000000000080bf0000803f000000000000803f000000c00000803f"},  // M1 rows 3, 2
    {0x2fa7e30, 16, "0000803f00000000000040c000000040"}, // M1 row 0
    {0x2fa7e50, 16, "000000000000000000004040000000c0"}, // M1 row 1
    {0x2fb4700, 32, "00000040000000c00000803f0000803f000040c000004040000000c0000080bf"},  // M2 rows 3, 2
};

void BicubicRefineDetour(int k, const ConstU16Vector* src, int srcDim, int x0, int y0, int x1,
                         int y1, const float* scale, std::uint16_t* out, int stride, int dx,
                         int dy) {
  const auto run = [&] {
    if (g_refine_fast) {
      BicubicRefine(g_original_bicubic_refine, k, src, srcDim, x0, y0, x1, y1, scale, out, stride, dx, dy);
    } else {
      g_original_bicubic_refine(k, src, srcDim, x0, y0, x1, y1, scale, out, stride, dx, dy);
    }
  };
  if (!g_timing) {
    run();
    return;
  }
  ScopedTicks timer(g_refine_calls, g_refine_ticks);
  run();
}

// ==================================================================== minmax
// Terrain tile publication (CTerrain height update, RVA 0x33cd10) contains the
// inlined CalcMinMaxHeight scan (0x33cec1..0x33cf06, 69 bytes). Stock walks
// the tile's uint16 heights with two compares per value. The patch calls an
// SSE2 unsigned min/max and hands back exactly the stock register contract
// (r10w = min, cx = max, r11 preserved, xmm2 = [r14+0x34]); the float
// conversion, scale, assert and store that follow stay stock code. The uint16
// block copy 0x30a540 (pdata chunk 0x30a55c is its body) copies element by
// element; for non-overlapping spans a per-row memcpy writes the same values
// in the same row order. Anything else goes to the original.
BlockCopyFn g_original_block_copy = nullptr;

// The whole per-tile loop (0x33ce80..0x33cf4d): its head reloads rdx/rsi/r8/r9
// before use and its tail reads r10w, cx, xmm2 and r11. Pinning these bytes
// pins the register contract the patch relies on.
constexpr std::uint8_t kMinMaxLoopBytes[205] = {
    0x4d,0x8b,0x46,0x18,0x41,0x8b,0x13,0x41,0x2b,0x10,0x41,0x8b,0x43,0x04,0x41,0x2b,0x40,0x04,0x41,0x8b,
    0x48,0x08,0x0f,0xaf,0xc8,0x03,0xca,0x48,0x63,0xc1,0x48,0x8d,0x1c,0x80,0x49,0x8b,0x78,0x10,0x48,0x8b,
    0x44,0xdf,0x08,0xf3,0x41,0x0f,0x10,0x56,0x34,0x48,0x8b,0x70,0x08,0x48,0x8b,0x10,0x48,0x3b,0xd6,0x0f,
    0x84,0x41,0x01,0x00,0x00,0x44,0x0f,0xb7,0x12,0x41,0x0f,0xb7,0xca,0x4d,0x8b,0xc4,0x4c,0x8b,0xce,0x4c,
    0x2b,0xca,0x49,0xff,0xc1,0x49,0xd1,0xe9,0x48,0x3b,0xd6,0x4d,0x0f,0x47,0xcc,0x4d,0x85,0xc9,0x74,0x22,
    0x0f,0xb7,0x02,0x66,0x41,0x3b,0xc2,0x73,0x06,0x44,0x0f,0xb7,0xd0,0xeb,0x07,0x66,0x3b,0xc1,0x66,0x0f,
    0x47,0xc8,0x48,0x83,0xc2,0x02,0x49,0xff,0xc0,0x4d,0x3b,0xc1,0x75,0xde,0x41,0x0f,0xb7,0xc2,0x66,0x0f,
    0x6e,0xc0,0x0f,0x5b,0xc0,0xf3,0x0f,0x59,0xc2,0x0f,0xb7,0xc1,0x66,0x0f,0x6e,0xc8,0x0f,0x5b,0xc9,0xf3,
    0x0f,0x59,0xca,0x0f,0x2f,0xc8,0x0f,0x82,0xf7,0x00,0x00,0x00,0xf3,0x0f,0x11,0x44,0xdf,0x18,0xf3,0x0f,
    0x11,0x4c,0xdf,0x1c,0xff,0x44,0xdf,0x20,0x49,0x83,0xc3,0x08,0x4d,0x3b,0xdf,0x0f,0x85,0x37,0xff,0xff,
    0xff,0x4c,0x8b,0x5d,0x98
};
constexpr std::uintptr_t kMinMaxLoopRva = 0x33ce80;
// Epilogue: rsi (the patch's scratch copy of r11) is restored from the frame.
constexpr std::uint8_t kMinMaxEpilogueBytes[28] = {
    0x4c,0x8d,0x9c,0x24,0x50,0x01,0x00,0x00,0x49,0x8b,0x5b,0x40,0x49,0x8b,0x73,0x48,0x49,0x8b,0xe3,0x41,
    0x5f,0x41,0x5e,0x41,0x5c,0x5f,0x5d,0xc3
};
constexpr std::uintptr_t kMinMaxEpilogueRva = 0x33cfe6;
// void (src, dst, srcStride, dstStride, srcX, srcY, w, h, dstX, dstY), the
// whole function. Callers: 3c40c0 (publication into the tile cache), 3ac330
// GetHeightmap, 3c4620 BaseGetHeightmapRefined, 3c4a20 GetBlock, 316590, 32ea60.
constexpr std::uint8_t kBlockCopyBytes[208] = {
    0x40,0x53,0x41,0x56,0x41,0x57,0x48,0x83,0xec,0x10,0x8b,0x5c,0x24,0x68,0x4c,0x8b,0xf2,0x4c,0x8b,0xf9,
    0x85,0xdb,0x0f,0x8e,0xaa,0x00,0x00,0x00,0x48,0x89,0x6c,0x24,0x30,0x41,0x8b,0xc0,0x0f,0xaf,0x44,0x24,
    0x58,0x48,0x89,0x74,0x24,0x38,0x48,0x89,0x7c,0x24,0x40,0x48,0x63,0x7c,0x24,0x60,0x4c,0x89,0x64,0x24,
    0x08,0x4c,0x63,0x64,0x24,0x70,0x4c,0x63,0xd8,0x41,0x8b,0xc1,0x0f,0xaf,0x44,0x24,0x78,0x4c,0x89,0x2c,
    0x24,0x4c,0x63,0x6c,0x24,0x50,0x49,0x63,0xf0,0x49,0x63,0xe9,0x4c,0x63,0xd0,0x90,0x48,0x85,0xff,0x7e,
    0x3d,0x4d,0x8b,0xc3,0x4b,0x8d,0x04,0x22,0x4d,0x2b,0xc2,0x49,0x8d,0x04,0x46,0x4d,0x2b,0xc4,0x48,0x8b,
    0xd7,0x4d,0x03,0xc5,0x4f,0x8d,0x0c,0x00,0x4d,0x2b,0xce,0x4d,0x03,0xcf,0x66,0x66,0x0f,0x1f,0x84,0x00,
    0x00,0x00,0x00,0x00,0x41,0x0f,0xb7,0x0c,0x01,0x66,0x89,0x08,0x48,0x8d,0x40,0x02,0x48,0x83,0xea,0x01,
    0x75,0xee,0x4c,0x03,0xd5,0x4c,0x03,0xde,0x48,0x83,0xeb,0x01,0x75,0xb2,0x4c,0x8b,0x2c,0x24,0x4c,0x8b,
    0x64,0x24,0x08,0x48,0x8b,0x7c,0x24,0x40,0x48,0x8b,0x74,0x24,0x38,0x48,0x8b,0x6c,0x24,0x30,0x48,0x83,
    0xc4,0x10,0x41,0x5f,0x41,0x5e,0x5b,0xc3
};

void BlockCopyDetour(const std::uint16_t* src, std::uint16_t* dst, int srcStride, int dstStride,
                     int srcX, int srcY, int w, int h, int dstX, int dstY) {
  const auto run = [&] {
    if (g_block_copy_fast) {
      BlockCopy(g_original_block_copy, src, dst, srcStride, dstStride, srcX, srcY, w, h, dstX, dstY);
    } else {
      g_original_block_copy(src, dst, srcStride, dstStride, srcX, srcY, w, h, dstX, dstY);
    }
  };
  if (!g_timing) {
    run();
    return;
  }
  ScopedTicks timer(g_block_copy_calls, g_block_copy_ticks);
  run();
}

// ===================================================================== align
// terrain_alignment_util::CalculateHeightMod at RVA 0x3b3470: one call per
// height-mod block from the ecs::TerrainAlignmentSystem::UpdateSubterrains
// thread-pool workers (0xaac460) and from 0x2146540. Stock work per call:
//  * three PredHeightModRasterizable targets, each holding two
//    std::vector<uint16> of N words; 0x3b0190 (twice) and 0x3af850 (six times)
//    allocate six heap blocks and fill them one word per iteration;
//  * every alignment triangle rasterised into its target (0x2375420 /
//    0x23754b0 with the predicates 0x3b7440 and 0x3b6ee0);
//  * a scalar pass over all N samples that blends the three targets into the
//    result wherever any of the three weights is non-zero.
// What changed: the six vectors come from a pooled buffer reused across calls
// and reset with two memsets (same words, same values); triangles are still
// rasterised by the original code against targets laid out byte for byte as
// 0x3b0190 lays them out; the blend skips all-zero-weight samples eight at a
// time and evaluates the rest four lanes wide with SSE2.
constexpr std::size_t kAlignTriangles = 0x00;  // vector<CVec3f>: 3 vertices (36 bytes) per triangle
constexpr std::size_t kAlignWeights = 0x18;    // vector<CVec3f>: one weight per vertex, may be empty
constexpr std::size_t kAlignType = 0x30;       // 0, 1 or 2: which rasterisation target
constexpr std::int64_t kAlignMaxSamples = 1 << 20;

constexpr std::uintptr_t kAlignRasterInitRva = 0x2375420;
constexpr std::uintptr_t kAlignRasterTriangleRva = 0x23754b0;
constexpr std::uintptr_t kAlignAssertRva = 0x221adf0;
constexpr std::uintptr_t kAlignVtableLessEqualRva = 0x2fb64c0;     // targets 0 and 1, heights start 0xffff
constexpr std::uintptr_t kAlignVtableGreaterEqualRva = 0x2fb64d8;  // target 2, heights start 0
constexpr std::uintptr_t kAlignAssertExpressionRva = 0x2fb6658;
constexpr std::uintptr_t kAlignAssertFileRva = 0x2fb4fa0;
constexpr std::uintptr_t kAlignAssertFunctionRva = 0x2fb64f0;
constexpr std::uintptr_t kAlignPredicateDeleteRva = 0x3b09a0;
constexpr std::uintptr_t kAlignPredicateLessEqualRva = 0x3b7440;
constexpr std::uintptr_t kAlignPredicateGreaterEqualRva = 0x3b6ee0;

// PredHeightModRasterizable<...>, exactly as 0x3b0190 builds it.
struct AlignTarget {
  std::uintptr_t vtable;             // +0x00
  unsigned char triangle[0x30];      // +0x08 three vertices then three weights, zeroed by the ctor
  std::int32_t sizeX, sizeY;         // +0x38
  float scale, invScale, offset;     // +0x40
  std::uint32_t padding;             // +0x4c untouched by the ctor and unread by the predicates
  U16Vector heights;                 // +0x50
  U16Vector weights;                 // +0x68
};
static_assert(offsetof(AlignTarget, sizeX) == 0x38, "target layout");
static_assert(offsetof(AlignTarget, scale) == 0x40, "target layout");
static_assert(offsetof(AlignTarget, heights) == 0x50, "target layout");
static_assert(offsetof(AlignTarget, weights) == 0x68, "target layout");
static_assert(sizeof(AlignTarget) == 0x80, "target layout");

CalculateHeightModFn g_original_calculate_height_mod = nullptr;
AlignEngine g_align_engine{};

// One buffer of 6*N words per concurrent call: heightA, heightB, weightA,
// weightB, heightC, weightC. Pooled because the stock code's six allocations
// and their word-at-a-time fills are ~5% of a big save load. SRWLOCK only: the
// hook must never instantiate std::mutex against the game's own msvcp140.
struct AlignScratch {
  AlignScratch* next;
  std::size_t samples;
  std::uint16_t* words;
};
SRWLOCK g_align_scratch_lock = SRWLOCK_INIT;
AlignScratch* g_align_scratch_free = nullptr;

void ReleaseAlignScratch(AlignScratch* scratch) {
  AcquireSRWLockExclusive(&g_align_scratch_lock);
  scratch->next = g_align_scratch_free;
  g_align_scratch_free = scratch;
  ReleaseSRWLockExclusive(&g_align_scratch_lock);
}

AlignScratch* AcquireAlignScratch(std::size_t samples) {
  AcquireSRWLockExclusive(&g_align_scratch_lock);
  AlignScratch* scratch = g_align_scratch_free;
  if (scratch) g_align_scratch_free = scratch->next;
  ReleaseSRWLockExclusive(&g_align_scratch_lock);
  if (!scratch) {
    scratch = static_cast<AlignScratch*>(std::malloc(sizeof(AlignScratch)));
    if (!scratch) return nullptr;
    scratch->next = nullptr;
    scratch->samples = 0;
    scratch->words = nullptr;
  }
  if (scratch->samples < samples) {
    std::size_t want = samples < 66049 ? 66049 : samples;  // a 1 m tile block is 257x257
    want = (want + 0xfff) & ~static_cast<std::size_t>(0xfff);
    _aligned_free(scratch->words);
    scratch->words =
        static_cast<std::uint16_t*>(_aligned_malloc(6 * want * sizeof(std::uint16_t), 64));
    scratch->samples = scratch->words ? want : 0;
    if (!scratch->words) {
      ReleaseAlignScratch(scratch);
      return nullptr;
    }
  }
  return scratch;
}

struct AlignBlendInput {
  const std::uint16_t* result;
  const std::uint16_t* heightA;
  const std::uint16_t* heightB;
  const std::uint16_t* heightC;
  const std::uint16_t* weightA;
  const std::uint16_t* weightB;
  const std::uint16_t* weightC;
};
struct AlignBlendConstants {
  __m128 scale, offset, invScale, zero, one, half, full;
};

inline __m128 AlignWiden(__m128i words, int upper) {
  const __m128i zero = _mm_setzero_si128();
  return _mm_cvtepi32_ps(upper ? _mm_unpackhi_epi16(words, zero) : _mm_unpacklo_epi16(words, zero));
}
inline __m128 AlignSelect(__m128 mask, __m128 taken, __m128 other) {
  return _mm_or_ps(_mm_and_ps(mask, taken), _mm_andnot_ps(mask, other));
}

// Eight samples. Returns a bitmask of lanes to store; *failLane, if set, is
// the lane where the stock "totalW > .0f" assert fires (later lanes dropped).
int AlignBlendEight(const AlignBlendInput& in, const AlignBlendConstants& k, std::int32_t* values,
                    int* failLane) {
  const __m128i zero = _mm_setzero_si128();
  const __m128i wordsA = _mm_loadu_si128(reinterpret_cast<const __m128i*>(in.weightA));
  const __m128i wordsB = _mm_loadu_si128(reinterpret_cast<const __m128i*>(in.weightB));
  const __m128i wordsC = _mm_loadu_si128(reinterpret_cast<const __m128i*>(in.weightC));
  // Stock skips a sample when (int)wA + (int)wB + (int)wC == 0, i.e. all three zero.
  const int nonzero =
      ~_mm_movemask_epi8(_mm_cmpeq_epi16(_mm_or_si128(_mm_or_si128(wordsA, wordsB), wordsC), zero)) &
      0xffff;
  if (!nonzero) return 0;
  const __m128i rWords = _mm_loadu_si128(reinterpret_cast<const __m128i*>(in.result));
  const __m128i haWords = _mm_loadu_si128(reinterpret_cast<const __m128i*>(in.heightA));
  const __m128i hbWords = _mm_loadu_si128(reinterpret_cast<const __m128i*>(in.heightB));
  const __m128i hcWords = _mm_loadu_si128(reinterpret_cast<const __m128i*>(in.heightC));
  int written = 0;
  for (int upper = 0; upper < 2; ++upper) {
    int lanes = 0;
    for (int lane = 0; lane < 4; ++lane) {
      if ((nonzero >> (2 * (4 * upper + lane))) & 3) lanes |= 1 << lane;
    }
    if (!lanes) continue;
    // height = (float)word * scale + offset, as the stock cvtdq2ps/mulss/addss.
    const __m128 heightR = _mm_add_ps(_mm_mul_ps(AlignWiden(rWords, upper), k.scale), k.offset);
    const __m128 heightA = _mm_add_ps(_mm_mul_ps(AlignWiden(haWords, upper), k.scale), k.offset);
    const __m128 heightB = _mm_add_ps(_mm_mul_ps(AlignWiden(hbWords, upper), k.scale), k.offset);
    const __m128 heightC = _mm_add_ps(_mm_mul_ps(AlignWiden(hcWords, upper), k.scale), k.offset);
    const __m128 fractionA = _mm_div_ps(AlignWiden(wordsA, upper), k.full);
    __m128 fractionB = _mm_div_ps(AlignWiden(wordsB, upper), k.full);
    __m128 fractionC = _mm_div_ps(AlignWiden(wordsC, upper), k.full);
    // lower = min(fC > 0 ? max(result, C) : result, B)
    // upper = max(fB > 0 ? min(result, B) : result, C)
    __m128 lower = AlignSelect(
        _mm_and_ps(_mm_cmpgt_ps(fractionC, k.zero), _mm_cmpgt_ps(heightC, heightR)), heightC,
        heightR);
    lower = AlignSelect(_mm_cmpgt_ps(lower, heightB), heightB, lower);
    __m128 higher = AlignSelect(
        _mm_and_ps(_mm_cmpgt_ps(fractionB, k.zero), _mm_cmpgt_ps(heightR, heightB)), heightB,
        heightR);
    higher = AlignSelect(_mm_cmpgt_ps(heightC, higher), heightC, higher);
    fractionB = _mm_and_ps(_mm_cmpeq_ps(lower, heightB), fractionB);
    fractionC = _mm_and_ps(_mm_cmpeq_ps(higher, heightC), fractionC);
    const __m128 sum = _mm_add_ps(_mm_add_ps(fractionB, fractionA), fractionC);
    const int active = lanes & ~_mm_movemask_ps(_mm_cmpeq_ps(sum, k.zero));
    if (!active) continue;
    // A weight of exactly 1 in two of the three drops the later one.
    const __m128 oneA = _mm_cmpeq_ps(fractionA, k.one);
    const __m128 oneB = _mm_cmpeq_ps(fractionB, k.one);
    const __m128 oneC = _mm_cmpeq_ps(fractionC, k.one);
    fractionB = _mm_andnot_ps(_mm_and_ps(oneA, oneB), fractionB);
    fractionC = _mm_andnot_ps(_mm_and_ps(oneC, _mm_or_ps(oneA, oneB)), fractionC);
    const __m128 restA = _mm_sub_ps(k.one, fractionA);
    const __m128 restB = _mm_sub_ps(k.one, fractionB);
    const __m128 restC = _mm_sub_ps(k.one, fractionC);
    const __m128 weightA = _mm_mul_ps(_mm_mul_ps(restB, fractionA), restC);
    const __m128 weightB = _mm_mul_ps(_mm_mul_ps(restA, fractionB), restC);
    const __m128 weightC = _mm_mul_ps(_mm_mul_ps(restA, restB), fractionC);
    const __m128 total = _mm_add_ps(_mm_add_ps(weightB, weightA), weightC);
    const __m128 positive = _mm_cmpgt_ps(total, k.zero);
    const int bad = active & ~_mm_movemask_ps(positive);
    // Inactive lanes divide by 1: no stock operation is added, and an
    // unmasked divide-by-zero cannot fire where stock would not divide.
    const __m128 divisor = AlignSelect(positive, total, k.one);
    __m128 value = _mm_add_ps(_mm_add_ps(_mm_mul_ps(lower, weightB), _mm_mul_ps(weightA, heightA)),
                              _mm_mul_ps(higher, weightC));
    value = _mm_div_ps(value, divisor);
    value = _mm_add_ps(_mm_mul_ps(_mm_sub_ps(value, k.offset), k.invScale), k.half);
    // floorf then cvttss2si: truncation, minus one where truncation rounded
    // up, and the 0x80000000 "integer indefinite" of NaN and out-of-range
    // values kept as is (stock floors them to themselves).
    __m128i truncated = _mm_cvttps_epi32(value);
    const __m128i indefinite = _mm_cmpeq_epi32(truncated, _mm_set1_epi32(INT32_MIN));
    const __m128i rounded = _mm_castps_si128(_mm_cmplt_ps(value, _mm_cvtepi32_ps(truncated)));
    truncated = _mm_add_epi32(truncated, _mm_andnot_si128(indefinite, rounded));
    _mm_storeu_si128(reinterpret_cast<__m128i*>(values + 4 * upper), truncated);
    if (bad) {
      unsigned long lane = 0;
      _BitScanForward(&lane, static_cast<unsigned long>(bad));
      written |= (active & ((1 << lane) - 1)) << (4 * upper);
      *failLane = 4 * upper + static_cast<int>(lane);
      return written;
    }
    written |= active << (4 * upper);
  }
  return written;
}

// Returns the sample index where the stock assert fires, or -1.
std::int64_t AlignBlend(std::uint16_t* out, const std::uint16_t* words, std::size_t samples,
                        const AlignBlendConstants& k) {
  AlignBlendInput in{};
  const std::uint16_t* heightA = words;
  const std::uint16_t* heightB = words + samples;
  const std::uint16_t* weightA = words + 2 * samples;
  const std::uint16_t* weightB = words + 3 * samples;
  const std::uint16_t* heightC = words + 4 * samples;
  const std::uint16_t* weightC = words + 5 * samples;
  std::uint16_t tail[7][8];
  for (std::size_t i = 0; i < samples; i += 8) {
    const std::size_t count = samples - i < 8 ? samples - i : 8;
    const std::uint16_t* source[7] = {out + i,     heightA + i, heightB + i, heightC + i,
                                      weightA + i, weightB + i, weightC + i};
    if (count < 8) {
      for (int s = 0; s < 7; ++s) {
        std::memset(tail[s], 0, sizeof tail[s]);  // padding lanes: weight 0, never written
        std::memcpy(tail[s], source[s], count * sizeof(std::uint16_t));
        source[s] = tail[s];
      }
    }
    in.result = source[0];
    in.heightA = source[1];
    in.heightB = source[2];
    in.heightC = source[3];
    in.weightA = source[4];
    in.weightB = source[5];
    in.weightC = source[6];
    std::int32_t values[8];
    int failLane = -1;
    const int written = AlignBlendEight(in, k, values, &failLane);
    for (int lane = 0; lane < 8; ++lane) {
      if ((written >> lane) & 1) out[i + lane] = static_cast<std::uint16_t>(values[lane]);
    }
    if (failLane >= 0) return static_cast<std::int64_t>(i) + failLane;
  }
  return -1;
}

bool AlignListSupported(const PointerVector* list) {
  const std::uintptr_t first = reinterpret_cast<std::uintptr_t>(list->first);
  const std::uintptr_t last = reinterpret_cast<std::uintptr_t>(list->last);
  if (last < first || (last - first) % sizeof(void*)) return false;
  for (const std::uint8_t* const* item = list->first; item != list->last; ++item) {
    const std::uint8_t* alignment = *item;
    std::uintptr_t begin = 0, end = 0;
    std::memcpy(&begin, alignment + kAlignTriangles, sizeof begin);
    std::memcpy(&end, alignment + kAlignTriangles + sizeof(void*), sizeof end);
    if (end < begin) return false;
    const std::uint64_t count = (end - begin) / 36;
    if (count > 0x7fffffff) return false;
    if (count) {  // stock reads the type only when it rasterises
      std::int32_t type = 0;
      std::memcpy(&type, alignment + kAlignType, sizeof type);
      if (type < 0 || type > 2) return false;
    }
  }
  return true;
}

void CalculateHeightModDetour(const float* box, const std::int32_t* size, float scale, float offset,
                              const PointerVector* alignments, U16Vector* result) {
  const auto run = [&] {
    if (g_align_fast) {
      CalculateHeightMod(g_original_calculate_height_mod, g_align_engine, box, size, scale, offset,
                         alignments, result);
    } else {
      g_original_calculate_height_mod(box, size, scale, offset, alignments, result);
    }
  };
  if (!g_timing) {
    run();
    return;
  }
  ScopedTicks timer(g_align_calls, g_align_ticks);
  run();
}

constexpr std::uint8_t kCalculateHeightModPrologue[21] = {
    0x48, 0x8b, 0xc4,                                // mov rax, rsp
    0x55, 0x56, 0x57,                                // push rbp; push rsi; push rdi
    0x41, 0x54, 0x41, 0x55, 0x41, 0x56, 0x41, 0x57,  // push r12..r15
    0x48, 0x8d, 0xa8, 0xf8, 0xfc, 0xff, 0xff         // lea rbp,[rax-0x308]
};
// Everything the replacement reproduces: the rest of the function body (which
// also pins its call targets, vtable and constant addresses), the constructor
// that fixes the target layout and the fill values, the resize whose fill this
// replaces, the three float constants and the assert message.
const Region kTerrainAlignRegions[] = {
    {0x3b3485, 2132,  // CalculateHeightMod body after the hook prologue
     "4881ecd003000048c745d8feffffff488958180f2970b80f2978a8440f294098440f294888440f299078ffffff440f299868ffffff440f29a058ffffff440f29a848ffffff44"
     "0f29b038ffffff440f29b828ffffff488b05d78ce1034833c448898520020000440f28e3440f28ea488bfa4c8bf14c8bbd300300004c8ba5380300004c8965a0498b4c240849"
     "2b0c2448d1f9448b42048b128bc2410fafc03bc10f858d070000bbffff000066895c2428f3440f116424200f28da488d8d90010000e845ccffff9066895c2428f3440f116424"
     "20410f28dd448b47048b17488d8d00010000e822ccffff9033f666897424308b4f048b17450f57c0897424480f57c0410f14c0f20f1145788bc6898580000000897424480f57"
     "c0410f14c0f20f11858400000089858c000000897424480f57c0410f14c0f20f1185900000008985980000004889b59c00000089b5a4000000488d05fb2ec002488945708995"
     "a8000000898dac000000f3440f11adb0000000f3440f10158db3b602410f28c2f3410f5ec5f30f11442460f30f1185b4000000f3440f11a5b80000000f57c0660f7f85c00000"
     "004889b5d00000004889b5d8000000660f7f85e00000000fafd14863d2488d85c00000004889442440488d44243048894424480f28442440660f7f45804c8d4580488d8dc000"
     "0000e8dac1ffff66897424388b85ac0000000faf85a80000004863d0488d85d80000004889442440488d44243848894424480f28442440660f7f45804c8d4580488d8dd80000"
     "00e895c1ffff90488d8590010000488945a8488d8500010000488945b0488d4570488945b8c64424280148897c24204d8d4e084d8bc6488d9590010000488d4de0e8251dfc01"
     "c64424280148897c24204d8d4e084d8bc6488d9500010000488d4d10e8041dfc01c64424280148897c24204d8d4e084d8bc6488d5570488d4d40e8e61cfc01488d45e0488945"
     "c0488d4510488945c8488d4540488945d00f57c0f30f7f4424688bce48894c2478498b57084889542450498b07488944245849bbabaaaaaaaaaaaa2a4c8b542468483bc20f84"
     "f601000048bf398ee3388ee3380e6666660f1f8400000000004c8b38498d5f184c8b43084c39030f858a000000498b4f08492b0f488bc748f7e94c8bca49d1f9498bc148c1e8"
     "3f4c03c8488b4c2470492bca498bc348f7e948d1fa488bc248c1e83f4803d04c3bca764dc74424400000803fc74424440000803fc74424480000803f488d4424684889458048"
     "8d442440488945880f284580660f7f45904c8d4590498bd1488d4c2468e81bc2ffff4c8b43084c8b5424684c8d6c24684c39034c0f45eb498b4f08492b0f488bc748f7e948d1"
     "fa488bc248c1e83f4803d04c63e285d20f8ee600000049634730488b7cc5a8488b4cc5c04c8bf6488bde488bf166660f1f840000000000498b0f498b4500f3410f101c06f341"
     "0f10540604f3410f104c0608f20f10440b18f20f1147088b440b20894710f20f10440b0cf20f1147148b440b1489471cf20f10040bf20f1147208b440b08894728f30f114f2c"
     "f30f115730f30f115f34f30f104c0b04f30f10540b10f30f105c0b1cf30f10040b0f14c166490f7ec1f30f104c0b0c0f14ca66490f7ec8f30f10540b180f14d366480f7ed248"
     "8bcee87e1bfc01488d5b244d8d760c4983ec010f854cffffff4c8b54246833f648bf398ee3388ee3380e488b4424584883c0084889442458483b44245049bbabaaaaaaaaaaaa"
     "2a0f8528feffff488b4c24784c8b65a04d85d2744e492bca498bc348f7e948d1fa488bc248c1e83f4803d0488d145248c1e202498bc24881fa00100000721c4883c2274d8b52"
     "f8492bc24883c0f84883f81f7607ff15057eb502cc498bcae8e8008402498b442408492b042448d1f84863f885c00f8e27020000f3440f10358456be02f3440f103d8bafb602"
     "0f1f00498b1c240fb70473660f6ed80f5bdbf3410f59ddf3410f58dcf30f115c2450488b85f80100000fb71470488b85680100000fb70c70488b85d8000000440fb70470448b"
     "c98d040a4103c00f84b6010000488b85e00100000fb70c70450f57dbf3440f2ad9f3450f59ddf3450f58dc488b85500100000fb70c700f57c0f30f2ac1f3410f59c5f3410f58"
     "c4f30f11442458488b85c00000000fb70c700f57c9f30f2ac9f3410f59cdf3410f58ccf30f114d90450f57c9f3440f2acaf3450f5ece0f57e4f3410f2ae1f3410f5ee60f57f6"
     "f3410f2af0f3410f5ef6410f2ff07616488d442450488d4d900f2fcb480f47c1f30f1010eb030f28d30f2fd076030f28d0410f2fe07615488d442450488d4c24580f2fd8480f"
     "47c1f30f10180f2fcb76030f28d90f2ed07a027404410f28e00f2ed97a027404410f28f00f28c4f3410f58c1f30f58c6410f2ec07a060f84b5000000450f2eca7a10750e410f"
     "2ee27a10750e410f28e0eb08410f2ee27a0e750c410f2ef27a067504410f28f0410f28caf30f5ccc410f28c2f30f5cc60f28f9f3410f59f9f30f59f8410f28eaf3410f5ce944"
     "0f28cdf3440f59ccf3440f59c8f30f59e9f30f59ee410f28c1f30f58c7f30f58c5410f2fc00f86cb000000f3410f59d1f3410f59fbf30f58d7f30f59ddf30f58d3f30f5ed0f3"
     "410f5cd4f30f59542460f3410f58d70f28c2e83d2c8402f30f2cc06689047348ffc6483bf70f8ceefdffff488d4d70e8d5c8ffff90488d8d00010000e8c8c8ffff90488d8d90"
     "010000e8bbc8ffff488b8d200200004833cce8ecfd83024c8d9c24d0030000498b5b50410f2873f0410f287be0450f2843d0450f284bc0450f2853b0450f285ba0450f286390"
     "450f286b80450f28b370ffffff450f28bb60ffffff498be3415f415e415d415c5f5e5dc34c8d0d5228c00241b8d7040000488d15f512c002488d0da629c002e83971e601904c"
     "8d0d3128c00241b879040000488d15d412c002488d0d5d29c002e81871e601cc"},
    {0x3b0190, 317,  // PredHeightModRasterizable constructor: the target layout and the 0xffff/0 fills
     "4c8bdc49894b08574883ec4049c743d8feffffff49895b1049897318488bf90f57d2c7442438000000000f57c00f14c2f20f1141088b442438894110c7442438000000000f57"
     "c00f14c2f20f1141148b44243889411cc7442438000000000f57c00f14c2f20f1141208b44243889412833f64889712c897134488d05b062c0024889018951384489413cf30f"
     "115940f30f100565e7b602f30f5ec3f30f114144f30f10442470f30f1141484883c1504889314889710848897110488d5f6848893348897308488973108b473c0faf47384863"
     "d049894be8498d4330498943f00f28442430660f7f4424304d8d43e8e8cdf5ffff66897424708b473c0faf47384863d048895c2430488d44247048894424380f28442430660f"
     "7f4424304c8d442430488bcbe897f5ffff90488bc7488b5c2458488b7424604883c4405fc3"},
    {0x3af850, 504,  // vector<unsigned short>::_Resize(n, value): the fill this replaces
     "48894c240856574154415641574883ec3048c7442428feffffff48895c2470498bf8488bf24c8bf9488b5108488b01488bda482bd848d1fb488b4910482bc848d1f9483bf10f"
     "865701000049b8ffffffffffffff7f493bf00f8794010000488bd148d1ea498bc0482bc2483bc87605488bc6eb0b488d040a483bc6480f42c648894424204c8d2400498bd449"
     "3bc0760c48c7c0ffffffff488bd0eb104881fa00100000723148c7c0ffffffff488d4a27483bca480f46c8e8744184024885c0740e4c8d70274983e6e0498946f8eb1cff15ab"
     "beb502cc4885d2740d488bcae84d4184024c8bf0eb034533f64c89742478498d0c5e4c8b4708488bd6482bd37411410fb700668901488d49024883ea0175ef498b7f084c8d44"
     "2468488d542468488d4c2468e877deceff492b3f4c8bc7498b17498bcee8d36d840290498b0f4885c97433498b5710482bd148d1fa4803d24881fa0010000072184883c2274c"
     "8b41f8492bc8488d41f84883f81f772d498bc8e8f64084024d8937498d0476498947084b8d043449894710488b5c24704883c430415f415e415c5f5ec3ff15dfbdb502cc483b"
     "f3762f498b4808482bf374100fb7016689024883c2024883ee0175f049895708488b5c24704883c430415f415e415c5f5ec37408488d047049894708488b5c24704883c43041"
     "5f415e415c5f5ec3e8a990ceffcc"},
    {0x2f99078, 4, "00ff7f47"},                    // 65535.0f
    {0x2f1e98c, 4, "0000803f"},                    // 1.0f
    {0x2f1e988, 4, "0000003f"},                    // 0.5f
    {0x2fb6658, 13, "746f74616c57203e202e306600"},  // "totalW > .0f"
};

// =================================================================== install
// Each installer verifies every byte region its replacement relies on, hooks
// the entry point when the fast path or timing is wanted, and reports the
// fast path as active only when it was requested.
bool InstallAlign(const Host& host, std::uintptr_t base, const Request& request, Status& status) {
  if (!host.verify_bytes(host.context, kCalculateHeightModRva, kCalculateHeightModPrologue,
                         sizeof kCalculateHeightModPrologue)) {
    AppendError(status, "align: prologue mismatch at " + HexRva(kCalculateHeightModRva));
    return false;
  }
  for (const auto& region : kTerrainAlignRegions) {
    if (!VerifyRegion(host, region)) {
      AppendError(status, "align: byte mismatch at " + HexRva(region.rva));
      return false;
    }
  }
  // The two predicate vtables carry relocated pointers, so they are checked
  // against the running base, not against fixed bytes.
  const std::uintptr_t vtables[2][2] = {
      {base + kAlignPredicateDeleteRva, base + kAlignPredicateLessEqualRva},
      {base + kAlignPredicateDeleteRva, base + kAlignPredicateGreaterEqualRva}};
  const std::uintptr_t vtable_rvas[2] = {kAlignVtableLessEqualRva, kAlignVtableGreaterEqualRva};
  for (int index = 0; index < 2; ++index) {
    if (!host.verify_bytes(host.context, vtable_rvas[index],
                           reinterpret_cast<const std::uint8_t*>(vtables[index]),
                           sizeof vtables[index])) {
      AppendError(status, "align: predicate vtable mismatch at " + HexRva(vtable_rvas[index]));
      return false;
    }
  }
  void* original = nullptr;
  if (!host.install_hook(host.context, base + kCalculateHeightModRva,
                         reinterpret_cast<void*>(&CalculateHeightModDetour), &original)) {
    AppendError(status, "align: hook failed");
    return false;
  }
  g_original_calculate_height_mod = reinterpret_cast<CalculateHeightModFn>(original);
  g_align_engine = ResolveAlignEngine(base);
  g_align_fast = request.align;
  status.align = request.align;
  return true;
}

bool InstallRefine(const Host& host, std::uintptr_t base, const Request& request, Status& status) {
  if (!host.verify_bytes(host.context, kBicubicRefineRva, kBicubicRefinePrologue,
                         sizeof kBicubicRefinePrologue)) {
    AppendError(status, "refine: prologue mismatch at " + HexRva(kBicubicRefineRva));
    return false;
  }
  for (const auto& region : kBicubicRefineRegions) {
    if (!VerifyRegion(host, region)) {
      AppendError(status, "refine: byte mismatch at " + HexRva(region.rva));
      return false;
    }
  }
  void* original = nullptr;
  if (!host.install_hook(host.context, base + kBicubicRefineRva,
                         reinterpret_cast<void*>(&BicubicRefineDetour), &original)) {
    AppendError(status, "refine: hook failed");
    return false;
  }
  g_original_bicubic_refine = reinterpret_cast<BicubicRefineFn>(original);
  g_refine_fast = request.refine;
  status.refine = request.refine;
  return true;
}

bool InstallMinMax(const Host& host, std::uintptr_t base, const Request& request, Status& status) {
  // Preflight every site before touching anything.
  if (!host.verify_bytes(host.context, kMinMaxLoopRva, kMinMaxLoopBytes, sizeof kMinMaxLoopBytes) ||
      !host.verify_bytes(host.context, kMinMaxEpilogueRva, kMinMaxEpilogueBytes,
                         sizeof kMinMaxEpilogueBytes) ||
      !host.verify_bytes(host.context, kBlockCopyRva, kBlockCopyBytes, sizeof kBlockCopyBytes)) {
    AppendError(status, "minmax: byte mismatch");
    return false;
  }
  bool installed = false;
  // The scan is inline stock code: it is only replaced (never merely timed).
  if (request.minmax) {
    std::uint8_t patch[kMinMaxPatchSize];
    BuildMinMaxPatch(patch, reinterpret_cast<std::uintptr_t>(request.timing ? &MinMaxScanTimed : &MinMaxScan));
    status.minmax_scan = host.patch_bytes(host.context, kMinMaxScanRva, patch, sizeof patch) != 0;
    if (!status.minmax_scan) AppendError(status, "minmax: scan patch failed");
    installed |= status.minmax_scan;
  }
  // Each half is independently bit-identical, so a partial install is safe.
  void* original = nullptr;
  if (host.install_hook(host.context, base + kBlockCopyRva,
                        reinterpret_cast<void*>(&BlockCopyDetour), &original)) {
    g_original_block_copy = reinterpret_cast<BlockCopyFn>(original);
    g_block_copy_fast = request.minmax;
    status.block_copy = request.minmax;
    installed = true;
  } else {
    AppendError(status, "minmax: block copy hook failed");
  }
  return installed;
}

std::string Lower(std::wstring_view value) {
  std::string text;
  text.reserve(value.size());
  for (const wchar_t c : value) {
    if (c > 0x7f) {
      text.push_back('?');
    } else if (c >= L'A' && c <= L'Z') {
      text.push_back(static_cast<char>(c - L'A' + 'a'));
    } else {
      text.push_back(static_cast<char>(c));
    }
  }
  return text;
}

}  // namespace

// ================================================================ pure paths
void BicubicRefine(BicubicRefineFn original, int k, const ConstU16Vector* src, int srcDim, int x0,
                   int y0, int x1, int y1, const float* scale, std::uint16_t* out, int stride,
                   int dx, int dy) {
  // Stock asserts: k > 1 && k % 2 == 0, x0 >= 0, y0 >= 0, x1 <= srcDim,
  // x1 >= x0, y1 >= y0. Those inputs keep the original's assert behaviour.
  if (k < 2 || (k & 1) || x0 < 0 || y0 < 0 || x1 > srcDim || x1 < x0 || y1 < y0 ||
      k > kBicubicRefineMaxFactor) {
    original(k, src, srcDim, x0, y0, x1, y1, scale, out, stride, dx, dy);
    return;
  }
  if (y0 >= y1 - 1 || x0 >= x1 - 1) return;  // stock loops run zero times

  // t = float(i)/float(k), t*t, (t*t)*t: the stock per-row and per-pixel values.
  alignas(16) float t1[kBicubicRefineMaxFactor + 4] = {};
  alignas(16) float t2[kBicubicRefineMaxFactor + 4] = {};
  alignas(16) float t3[kBicubicRefineMaxFactor + 4] = {};
  const __m128 kf = _mm_cvtsi32_ss(_mm_setzero_ps(), k);
  for (int i = 0; i < k; ++i) {
    const __m128 t = _mm_div_ss(_mm_cvtsi32_ss(_mm_setzero_ps(), i), kf);
    const __m128 tt = _mm_mul_ss(t, t);
    _mm_store_ss(t1 + i, t);
    _mm_store_ss(t2 + i, tt);
    _mm_store_ss(t3 + i, _mm_mul_ss(tt, t));
  }

  // Stock index arithmetic, including its 32-bit products and sign extension.
  const std::uint32_t uk = static_cast<std::uint32_t>(k), half = static_cast<std::uint32_t>(k >> 1);
  const std::uint32_t rowAdjust = static_cast<std::uint32_t>(dy) - uk * static_cast<std::uint32_t>(y0);
  const std::uint32_t colAdjust = static_cast<std::uint32_t>(dx) - uk * static_cast<std::uint32_t>(x0);
  const std::int64_t base0 = static_cast<std::int32_t>(
      static_cast<std::uint32_t>(srcDim) * static_cast<std::uint32_t>(y0) + static_cast<std::uint32_t>(x0));
  const std::int64_t off1 =
      static_cast<std::int64_t>(static_cast<std::int32_t>(
          static_cast<std::uint32_t>(y0 + 1) * static_cast<std::uint32_t>(srcDim) +
          static_cast<std::uint32_t>(x0))) -
      base0;
  const std::int64_t off2 =
      static_cast<std::int64_t>(static_cast<std::int32_t>(
          static_cast<std::uint32_t>(y0 + 2) * static_cast<std::uint32_t>(srcDim) +
          static_cast<std::uint32_t>(x0))) -
      base0;
  const std::uintptr_t outStep = static_cast<std::uintptr_t>(2 * static_cast<std::int64_t>(stride));

  const __m128 quarter = _mm_set1_ps(0.25f), halfF = _mm_set1_ps(0.5f);
  const __m128 m3 = _mm_set1_ps(-3.0f), p3 = _mm_set1_ps(3.0f);
  const __m128 m2 = _mm_set1_ps(-2.0f), p2 = _mm_set1_ps(2.0f);

  for (int y = y0; y < y1 - 1; ++y) {
    const std::int64_t row = base0 + static_cast<std::int64_t>(y - y0) * static_cast<std::int64_t>(srcDim);
    const std::uint32_t rowTerm = uk * static_cast<std::uint32_t>(y) + half + rowAdjust;
    for (int x = x0; x < x1 - 1; ++x) {
      const std::uintptr_t at =
          reinterpret_cast<std::uintptr_t>(src->first) + 2 * static_cast<std::uintptr_t>(row + (x - x0));
      const auto r0 = reinterpret_cast<const std::uint16_t*>(at);
      const auto r1 = reinterpret_cast<const std::uint16_t*>(at + 2 * static_cast<std::uintptr_t>(off1));
      const auto r2 = reinterpret_cast<const std::uint16_t*>(at + 2 * static_cast<std::uintptr_t>(off2));
      const float a00 = static_cast<float>(static_cast<int>(r0[0]));
      const float a01 = static_cast<float>(static_cast<int>(r0[1]));
      const float a02 = static_cast<float>(static_cast<int>(r0[2]));
      const float a10 = static_cast<float>(static_cast<int>(r1[0]));
      const float a11 = static_cast<float>(static_cast<int>(r1[1]));
      const float a12 = static_cast<float>(static_cast<int>(r1[2]));
      const float a20 = static_cast<float>(static_cast<int>(r2[0]));
      const float a21 = static_cast<float>(static_cast<int>(r2[1]));
      const float a22 = static_cast<float>(static_cast<int>(r2[2]));

      // G (stock 0x3ac920..0x3acb98), four lanes per operation:
      // S = G0,G1,G4,G5  H = G2,G3,G6,G7  V = G8,G9,G12,G13  X = G10,G11,G14,G15
      const __m128 tl = _mm_setr_ps(a00, a01, a10, a11);
      const __m128 tr = _mm_setr_ps(a01, a02, a11, a12);
      const __m128 bl = _mm_setr_ps(a10, a11, a20, a21);
      const __m128 br = _mm_setr_ps(a11, a12, a21, a22);
      const __m128 s = _mm_mul_ps(_mm_add_ps(_mm_add_ps(_mm_add_ps(tr, tl), bl), br), quarter);
      const __m128 hTop = _mm_sub_ps(tr, tl), hBottom = _mm_sub_ps(br, bl);
      const __m128 h = _mm_mul_ps(_mm_add_ps(hTop, hBottom), halfF);
      const __m128 xx = _mm_sub_ps(hBottom, hTop);
      const __m128 v = _mm_mul_ps(_mm_add_ps(_mm_sub_ps(bl, tl), _mm_sub_ps(br, tr)), halfF);
      const __m128 g0 = _mm_shuffle_ps(s, v, _MM_SHUFFLE(2, 0, 2, 0));   // G[r][0]
      const __m128 g1 = _mm_shuffle_ps(s, v, _MM_SHUFFLE(3, 1, 3, 1));   // G[r][1]
      const __m128 g2 = _mm_shuffle_ps(h, xx, _MM_SHUFFLE(2, 0, 2, 0));  // G[r][2]
      const __m128 g3 = _mm_shuffle_ps(h, xx, _MM_SHUFFLE(3, 1, 3, 1));  // G[r][3]

      // T = G*M1: T[r][c] = ((G[r][0]M1[0][c] + G[r][1]M1[1][c]) + G[r][2]M1[2][c]) + G[r][3]M1[3][c]
      // M1 columns: c0 (1,0,0,0) c1 (0,0,1,0) c2 (-3,3,-2,-1) c3 (2,-2,1,1)
      __m128 tc0 = g0, tc1 = g2;
      __m128 tc2 = _mm_sub_ps(
          _mm_add_ps(_mm_add_ps(_mm_mul_ps(g0, m3), _mm_mul_ps(g1, p3)), _mm_mul_ps(g2, m2)), g3);
      __m128 tc3 =
          _mm_add_ps(_mm_add_ps(_mm_add_ps(_mm_mul_ps(g0, p2), _mm_mul_ps(g1, m2)), g2), g3);
      _MM_TRANSPOSE4_PS(tc0, tc1, tc2, tc3);  // now rows T[0..3][*]
      // C = M2*T: C[r][c] = ((M2[r][0]T[0][c] + M2[r][1]T[1][c]) + M2[r][2]T[2][c]) + M2[r][3]T[3][c]
      // M2 rows: (1,0,0,0) (0,0,1,0) (-3,3,-2,-1) (2,-2,1,1)
      const __m128 c0 = tc0, c1 = tc2;
      const __m128 c2 = _mm_sub_ps(
          _mm_add_ps(_mm_add_ps(_mm_mul_ps(tc0, m3), _mm_mul_ps(tc1, p3)), _mm_mul_ps(tc2, m2)),
          tc3);
      const __m128 c3 =
          _mm_add_ps(_mm_add_ps(_mm_add_ps(_mm_mul_ps(tc0, p2), _mm_mul_ps(tc1, m2)), tc2), tc3);

      const std::uint32_t pixel =
          rowTerm * static_cast<std::uint32_t>(stride) + uk * static_cast<std::uint32_t>(x) + half + colAdjust;
      std::uintptr_t dst = reinterpret_cast<std::uintptr_t>(out) +
                           2 * static_cast<std::uintptr_t>(static_cast<std::int64_t>(static_cast<std::int32_t>(pixel)));
      for (int i = 0; i < k; ++i, dst += outStep) {
        // P[c] = ((C[1][c]t + C[0][c]) + t2 C[2][c]) + C[3][c]t3
        const __m128 ti = _mm_set1_ps(t1[i]), ti2 = _mm_set1_ps(t2[i]), ti3 = _mm_set1_ps(t3[i]);
        const __m128 p = _mm_add_ps(
            _mm_add_ps(_mm_add_ps(_mm_mul_ps(c1, ti), c0), _mm_mul_ps(ti2, c2)), _mm_mul_ps(c3, ti3));
        const __m128 pp0 = _mm_shuffle_ps(p, p, _MM_SHUFFLE(0, 0, 0, 0));
        const __m128 pp1 = _mm_shuffle_ps(p, p, _MM_SHUFFLE(1, 1, 1, 1));
        const __m128 pp2 = _mm_shuffle_ps(p, p, _MM_SHUFFLE(2, 2, 2, 2));
        const __m128 pp3 = _mm_shuffle_ps(p, p, _MM_SHUFFLE(3, 3, 3, 3));
        const auto row16 = reinterpret_cast<std::uint16_t*>(dst);
        for (int j = 0; j < k; j += 4) {
          // value = ((P1 s + P0) + s2 P2) + P3 s3, stored as the low 16 bits
          // of cvttss2si (no saturation; 0x80000000 -> 0).
          const __m128 sj = _mm_load_ps(t1 + j), sj2 = _mm_load_ps(t2 + j), sj3 = _mm_load_ps(t3 + j);
          const __m128 value = _mm_add_ps(
              _mm_add_ps(_mm_add_ps(_mm_mul_ps(pp1, sj), pp0), _mm_mul_ps(sj2, pp2)),
              _mm_mul_ps(pp3, sj3));
          const __m128i n = _mm_cvttps_epi32(value);
          const __m128i wide = _mm_srai_epi32(_mm_slli_epi32(n, 16), 16);  // in int16 range
          const __m128i low = _mm_packs_epi32(wide, wide);
          if (k - j >= 4) {
            _mm_storel_epi64(reinterpret_cast<__m128i*>(row16 + j), low);
          } else {
            const std::int32_t two = _mm_cvtsi128_si32(low);  // k is even: tail is 2
            std::memcpy(row16 + j, &two, 4);
          }
        }
      }
    }
  }
}

// Stock count: begin > end ? 0 : (end - begin + 1) >> 1, 64-bit unsigned.
// min and max both start at begin[0], which stock reads unconditionally.
// Stock's "if (v < min) min = v; else if (v > max) max = v" keeps min <= max,
// so its result is the true unsigned minimum and maximum of those values.
// Reads exactly the stock byte range [begin, begin + 2*count), no more.
std::uint32_t MinMaxScan(const std::uint16_t* begin, const std::uint16_t* end) {
  const std::uintptr_t b = reinterpret_cast<std::uintptr_t>(begin);
  const std::uintptr_t e = reinterpret_cast<std::uintptr_t>(end);
  const std::size_t n = b > e ? 0 : static_cast<std::size_t>((e - b + 1) >> 1);
  unsigned lo = begin[0], hi = begin[0];
  std::size_t i = 0;
  if (n >= 32) {
    // SSE2 has only signed 16-bit min/max: bias by 0x8000 to order unsigned.
    const __m128i bias = _mm_set1_epi16(static_cast<short>(0x8000));
    __m128i vmin = _mm_set1_epi16(static_cast<short>(lo ^ 0x8000)), vmax = vmin;
    const auto load = [&](std::size_t k) {
      return _mm_xor_si128(_mm_loadu_si128(reinterpret_cast<const __m128i*>(begin + k)), bias);
    };
    for (; i + 32 <= n; i += 32) {
      const __m128i a = load(i), c = load(i + 8), d = load(i + 16), f = load(i + 24);
      vmin = _mm_min_epi16(vmin, _mm_min_epi16(_mm_min_epi16(a, c), _mm_min_epi16(d, f)));
      vmax = _mm_max_epi16(vmax, _mm_max_epi16(_mm_max_epi16(a, c), _mm_max_epi16(d, f)));
    }
    for (; i + 8 <= n; i += 8) {
      const __m128i a = load(i);
      vmin = _mm_min_epi16(vmin, a);
      vmax = _mm_max_epi16(vmax, a);
    }
    std::uint16_t mins[8], maxs[8];
    _mm_storeu_si128(reinterpret_cast<__m128i*>(mins), _mm_xor_si128(vmin, bias));
    _mm_storeu_si128(reinterpret_cast<__m128i*>(maxs), _mm_xor_si128(vmax, bias));
    for (int k = 0; k < 8; ++k) {
      if (mins[k] < lo) lo = mins[k];
      if (maxs[k] > hi) hi = maxs[k];
    }
  }
  for (; i < n; ++i) {
    const unsigned v = begin[i];
    if (v < lo) {
      lo = v;
    } else if (v > hi) {
      hi = v;
    }
  }
  return lo | (hi << 16);
}

// In: rdx = begin, rsi = end, r11 = tile iterator. The frame is fully set up
// (rsp % 16 == 0, [rsp..rsp+0x20) is the outgoing shadow area), so a plain
// call keeps the game's unwind state valid. rsi is dead until 0x33ceb1 reloads
// it and is callee-saved, so it carries r11 across the call. rax, rdx, r8, r9,
// xmm0/xmm1 are dead at 0x33cf06; xmm2 is reloaded from the same source stock
// loaded it from (0x33ceab).
void BuildMinMaxPatch(std::uint8_t* out, std::uintptr_t scan_address) {
  static const std::uint8_t head[] = {
      0x48, 0x89, 0xd1,  // mov rcx, rdx
      0x48, 0x89, 0xf2,  // mov rdx, rsi
      0x4c, 0x89, 0xde,  // mov rsi, r11
      0x48, 0xb8         // mov rax, imm64
  };
  static const std::uint8_t tail[] = {
      0xff, 0xd0,                          // call rax
      0x49, 0x89, 0xf3,                    // mov r11, rsi
      0xf3, 0x41, 0x0f, 0x10, 0x56, 0x34,  // movss xmm2, dword ptr [r14+0x34]
      0x44, 0x0f, 0xb7, 0xd0,              // movzx r10d, ax
      0xc1, 0xe8, 0x10,                    // shr eax, 16
      0x89, 0xc1,                          // mov ecx, eax
      0xeb, 0x1c                           // jmp 0x33cf06
  };
  std::memset(out, 0xcc, kMinMaxPatchSize);
  std::memcpy(out, head, sizeof head);
  std::memcpy(out + sizeof head, &scan_address, sizeof scan_address);
  std::memcpy(out + sizeof head + sizeof scan_address, tail, sizeof tail);
}

// void (src, dst, srcStride, dstStride, srcX, srcY, w, h, dstX, dstY):
//   for r < h: for i < w:
//     dst[dstY*dstStride + r*dstStride + dstX + i] = src[srcY*srcStride + r*srcStride + srcX + i]
// The Y products are 32-bit imul (wrapping) then sign-extended; everything
// else is 64-bit.
void BlockCopy(BlockCopyFn original, const std::uint16_t* src, std::uint16_t* dst, int srcStride,
               int dstStride, int srcX, int srcY, int w, int h, int dstX, int dstY) {
  // Stock touches no memory for h <= 0 (skips) or w <= 0 (empty rows).
  if (h <= 0 || w <= 0) return;
  // Bounds that keep every offset below exact in int64 (|offset| < 2^53).
  if (h > (1 << 20) || w > (1 << 20)) {
    original(src, dst, srcStride, dstStride, srcX, srcY, w, h, dstX, dstY);
    return;
  }
  const std::int64_t s0 =
      static_cast<std::int32_t>(static_cast<std::uint32_t>(srcStride) * static_cast<std::uint32_t>(srcY)) +
      static_cast<std::int64_t>(srcX);
  const std::int64_t d0 =
      static_cast<std::int32_t>(static_cast<std::uint32_t>(dstStride) * static_cast<std::uint32_t>(dstY)) +
      static_cast<std::int64_t>(dstX);
  const std::int64_t sLast = s0 + static_cast<std::int64_t>(h - 1) * srcStride;
  const std::int64_t dLast = d0 + static_cast<std::int64_t>(h - 1) * dstStride;
  const std::int64_t bytes = static_cast<std::int64_t>(w) * 2;
  const std::int64_t srcBase = static_cast<std::int64_t>(reinterpret_cast<std::uintptr_t>(src));
  const std::int64_t dstBase = static_cast<std::int64_t>(reinterpret_cast<std::uintptr_t>(dst));
  const std::int64_t srcLo = srcBase + 2 * (s0 < sLast ? s0 : sLast);
  const std::int64_t srcHi = srcBase + 2 * (s0 < sLast ? sLast : s0) + bytes;
  const std::int64_t dstLo = dstBase + 2 * (d0 < dLast ? d0 : dLast);
  const std::int64_t dstHi = dstBase + 2 * (d0 < dLast ? dLast : d0) + bytes;
  // Any shared byte (including odd alignments or row self-overlap with the
  // source) could make stock's forward element order observable: keep stock.
  if (srcLo < dstHi && dstLo < srcHi) {
    original(src, dst, srcStride, dstStride, srcX, srcY, w, h, dstX, dstY);
    return;
  }
  // Disjoint spans: every read sees the initial source, so each row writes
  // the same values; rows stay in stock order (destination rows may overlap).
  for (std::int64_t r = 0; r < h; ++r) {
    std::memcpy(reinterpret_cast<void*>(static_cast<std::uintptr_t>(dstBase) +
                                        static_cast<std::uintptr_t>(2 * (d0 + r * dstStride))),
                reinterpret_cast<const void*>(static_cast<std::uintptr_t>(srcBase) +
                                              static_cast<std::uintptr_t>(2 * (s0 + r * srcStride))),
                static_cast<std::size_t>(bytes));
  }
}

AlignEngine ResolveAlignEngine(std::uintptr_t base) {
  AlignEngine engine{};
  engine.raster_init = reinterpret_cast<AlignRasterInitFn>(base + kAlignRasterInitRva);
  engine.raster_triangle = reinterpret_cast<AlignRasterTriangleFn>(base + kAlignRasterTriangleRva);
  engine.assert_fn = reinterpret_cast<AlignAssertFn>(base + kAlignAssertRva);
  engine.vtable_less_equal = base + kAlignVtableLessEqualRva;
  engine.vtable_greater_equal = base + kAlignVtableGreaterEqualRva;
  engine.assert_expression = reinterpret_cast<const char*>(base + kAlignAssertExpressionRva);
  engine.assert_file = reinterpret_cast<const char*>(base + kAlignAssertFileRva);
  engine.assert_function = reinterpret_cast<const char*>(base + kAlignAssertFunctionRva);
  return engine;
}

void CalculateHeightMod(CalculateHeightModFn original, const AlignEngine& engine, const float* box,
                        const std::int32_t* size, float scale, float offset,
                        const PointerVector* alignments, U16Vector* result) {
  const std::int32_t sizeX = size[0], sizeY = size[1];
  const std::int64_t resultWords =
      (reinterpret_cast<std::intptr_t>(result->last) - reinterpret_cast<std::intptr_t>(result->first)) >> 1;
  if (static_cast<std::int32_t>(static_cast<std::uint32_t>(sizeX) * static_cast<std::uint32_t>(sizeY)) !=
          static_cast<std::int32_t>(resultWords) ||  // the stock assert
      sizeX < 2 || sizeY < 2 ||
      static_cast<std::int64_t>(sizeX) * static_cast<std::int64_t>(sizeY) > kAlignMaxSamples ||
      !engine.raster_init || !engine.raster_triangle || !AlignListSupported(alignments)) {
    original(box, size, scale, offset, alignments, result);
    return;
  }
  const std::size_t samples = static_cast<std::size_t>(sizeX) * static_cast<std::size_t>(sizeY);
  AlignScratch* scratch = AcquireAlignScratch(samples);
  if (!scratch) {
    original(box, size, scale, offset, alignments, result);
    return;
  }
  std::uint16_t* words = scratch->words;
  std::memset(words, 0xff, 4 * samples);             // heights of targets 0 and 1: 0xffff
  std::memset(words + 2 * samples, 0, 8 * samples);  // their weights, and target 2 entirely

  const float invScale = _mm_cvtss_f32(_mm_div_ss(_mm_set_ss(1.0f), _mm_set_ss(scale)));
  AlignTarget targets[3] = {};
  for (int t = 0; t < 3; ++t) {
    targets[t].vtable = t == 2 ? engine.vtable_greater_equal : engine.vtable_less_equal;
    targets[t].sizeX = sizeX;
    targets[t].sizeY = sizeY;
    targets[t].scale = scale;
    targets[t].invScale = invScale;
    targets[t].offset = offset;
  }
  const std::size_t slot[3][2] = {{0, 2}, {1, 3}, {4, 5}};  // heights, weights
  for (int t = 0; t < 3; ++t) {
    std::uint16_t* height = words + slot[t][0] * samples;
    std::uint16_t* weight = words + slot[t][1] * samples;
    targets[t].heights.first = height;
    targets[t].heights.last = targets[t].heights.end = height + samples;
    targets[t].weights.first = weight;
    targets[t].weights.last = targets[t].weights.end = weight + samples;
  }

  alignas(16) unsigned char rasterizers[3][0x30] = {};
  for (int t = 0; t < 3; ++t) {
    engine.raster_init(rasterizers[t], &targets[t], box, box + 2, size, 1);
  }

  static const float kDefaultWeights[3] = {1.0f, 1.0f, 1.0f};  // the stock (1,1,1) scratch vector
  for (const std::uint8_t* const* item = alignments->first; item != alignments->last; ++item) {
    const std::uint8_t* alignment = *item;
    std::uintptr_t begin = 0, end = 0, weightBegin = 0, weightEnd = 0;
    std::memcpy(&begin, alignment + kAlignTriangles, sizeof begin);
    std::memcpy(&end, alignment + kAlignTriangles + sizeof(void*), sizeof end);
    std::memcpy(&weightBegin, alignment + kAlignWeights, sizeof weightBegin);
    std::memcpy(&weightEnd, alignment + kAlignWeights + sizeof(void*), sizeof weightEnd);
    const std::int32_t count = static_cast<std::int32_t>((end - begin) / 36);
    if (count <= 0) continue;
    std::int32_t type = 0;
    std::memcpy(&type, alignment + kAlignType, sizeof type);
    AlignTarget& target = targets[type];
    void* rasterizer = rasterizers[type];
    for (std::int32_t i = 0; i < count; ++i) {
      const std::uint8_t* vertex = reinterpret_cast<const std::uint8_t*>(begin) + static_cast<std::size_t>(i) * 36;
      const std::uint8_t* weight =
          weightBegin == weightEnd
              ? reinterpret_cast<const std::uint8_t*>(kDefaultWeights)
              : reinterpret_cast<const std::uint8_t*>(weightBegin) + static_cast<std::size_t>(i) * 12;
      std::memcpy(target.triangle + 0x00, vertex + 0x18, 12);  // +0x08: vertex 2
      std::memcpy(target.triangle + 0x0c, vertex + 0x0c, 12);  // +0x14: vertex 1
      std::memcpy(target.triangle + 0x18, vertex + 0x00, 12);  // +0x20: vertex 0
      std::memcpy(target.triangle + 0x24, weight + 8, 4);      // +0x2c: weight of vertex 2
      std::memcpy(target.triangle + 0x28, weight + 4, 4);      // +0x30: weight of vertex 1
      std::memcpy(target.triangle + 0x2c, weight + 0, 4);      // +0x34: weight of vertex 0
      std::uint64_t second = 0, first = 0, zeroth = 0;
      std::memcpy(&second, vertex + 0x18, 8);
      std::memcpy(&first, vertex + 0x0c, 8);
      std::memcpy(&zeroth, vertex + 0x00, 8);
      engine.raster_triangle(rasterizer, second, first, zeroth);
    }
  }

  AlignBlendConstants k{};
  k.scale = _mm_set1_ps(scale);
  k.offset = _mm_set1_ps(offset);
  k.invScale = _mm_set1_ps(invScale);
  k.zero = _mm_setzero_ps();
  k.one = _mm_set1_ps(1.0f);
  k.half = _mm_set1_ps(0.5f);
  k.full = _mm_set1_ps(65535.0f);
  const std::int64_t failed = AlignBlend(result->first, words, samples, k);
  ReleaseAlignScratch(scratch);
  if (failed >= 0 && engine.assert_fn) {  // unreachable: see the exactness argument in the port report
    engine.assert_fn(engine.assert_expression, engine.assert_file, 0x4d7, engine.assert_function);
  }
}

// =================================================================== request
Request ParseRequest(std::wstring_view value) {
  Request request;
  const std::string text = Lower(value);
  request.raw = text.empty() ? "(default: all)" : text;
  bool any = false, all = false, none = false;
  std::string token;
  auto consume = [&](const std::string& word) {
    if (word.empty()) return;
    any = true;
    if (word == "0" || word == "off" || word == "false" || word == "none" || word == "stock") {
      none = true;
    } else if (word == "1" || word == "on" || word == "true" || word == "all") {
      all = true;
    } else if (word == "align") {
      request.align = true;
    } else if (word == "refine") {
      request.refine = true;
    } else if (word == "minmax") {
      request.minmax = true;
    } else if (word == "material") {
      request.material = true;
    } else if (word == "timing") {
      request.timing = true;
    } else {
      if (!request.error.empty()) request.error += "; ";
      request.error += "unknown token '" + word + "'";
    }
  };
  for (const char c : text) {
    if (c == ',' || c == ';' || c == ' ' || c == '\t') {
      consume(token);
      token.clear();
    } else {
      token.push_back(c);
    }
  }
  consume(token);
  if (!request.error.empty()) {
    request.align = request.refine = request.minmax = request.material = request.timing = false;
    return request;  // fail closed
  }
  const bool selected = request.align || request.refine || request.minmax || request.material;
  if (none) {
    request.align = request.refine = request.minmax = request.material = false;  // "stock" wins
  } else if (!any || all || !selected) {
    request.align = request.refine = request.minmax = true;  // unset, "all", or "timing" alone
    request.material = request.material || kMaterialDefaultOn;
  }
  return request;
}

Request RequestFromMask(int features) {
  Request request;
  request.align = (features & kFeatureAlign) != 0;
  request.refine = (features & kFeatureRefine) != 0;
  request.minmax = (features & kFeatureMinMax) != 0;
  request.material = (features & kFeatureMaterial) != 0;
  request.timing = (features & kFeatureTiming) != 0;
  request.raw = "mask:" + std::to_string(features);
  return request;
}

int StatusMask(const Status& status) {
  return (status.align ? kStatusAlign : 0) | (status.refine ? kStatusRefine : 0) |
         (status.minmax_scan ? kStatusMinMaxScan : 0) | (status.block_copy ? kStatusBlockCopy : 0) |
         (status.timing ? kStatusTiming : 0) | (status.material ? kStatusMaterial : 0);
}

TimingSnapshot Timing() {
  TimingSnapshot snapshot;
  snapshot.align_calls = g_align_calls.load(std::memory_order_relaxed);
  snapshot.refine_calls = g_refine_calls.load(std::memory_order_relaxed);
  snapshot.block_copy_calls = g_block_copy_calls.load(std::memory_order_relaxed);
  snapshot.scan_calls = g_scan_calls.load(std::memory_order_relaxed);
  snapshot.align_seconds = Seconds(g_align_ticks.load(std::memory_order_relaxed));
  snapshot.refine_seconds = Seconds(g_refine_ticks.load(std::memory_order_relaxed));
  snapshot.block_copy_seconds = Seconds(g_block_copy_ticks.load(std::memory_order_relaxed));
  snapshot.scan_seconds = Seconds(g_scan_ticks.load(std::memory_order_relaxed));
  const auto material = material_fast::Timing();
  snapshot.material_calls = material.calls;
  snapshot.material_seconds = material.seconds;
  return snapshot;
}

Status Install(const Host& host, const Request& request) {
  Status status;
  status.requested = request.raw;
  if (!request.error.empty()) {
    AppendError(status, "request: " + request.error);
    return status;
  }
  if (!request.align && !request.refine && !request.minmax && !request.material && !request.timing) {
    return status;
  }
  if (!host.module_base || !host.verify_bytes || !host.install_hook || !host.patch_bytes) {
    AppendError(status, "host services are incomplete");
    return status;
  }
  const std::uintptr_t base = host.module_base(host.context);
  if (base == 0) {
    AppendError(status, "module base unavailable");
    return status;
  }
  g_timing = request.timing;  // visible before any detour can fire
  bool hooked = false;
  if (request.align || request.timing) hooked |= InstallAlign(host, base, request, status);
  if (request.refine || request.timing) hooked |= InstallRefine(host, base, request, status);
  if (request.minmax || request.timing) hooked |= InstallMinMax(host, base, request, status);
  if (request.material || request.timing) {
    std::string error;
    bool active = false;
    hooked |= material_fast::Install(host, base, request.material, request.timing, active, error);
    status.material = active;
    if (!error.empty()) AppendError(status, error);
  }
  status.timing = request.timing && hooked;
  return status;
}

}  // namespace tpf2mp::terrain_fast
