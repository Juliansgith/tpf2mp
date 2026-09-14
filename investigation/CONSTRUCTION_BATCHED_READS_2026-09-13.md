# Construction capture: batched memory validation

## Change

`native/src/native_build_capture.cpp` now decodes nodes and edges from fixed-size
local record snapshots after `ReadVectorLayout` validates the entire used vector.
`ReadRecordAt` enforces each field's bounds at compile time. Removed 21 redundant
`IsReadableRange` calls per edge and six per node, for both added and removed
vectors. Actual `VirtualQuery` calls still depend on the number of memory regions.

Full range validation still walks every region, rejects inaccessible/guard pages,
and checks layout alignment, count limits and pointer ordering. Finite-value checks,
wire encoding, ownership fields, capture correlation and replay are unchanged.
Strings, construction records and nested pointers retain their existing checks.
No permission cache persists across records/commands. No gameplay checks removed.

Lifetime assumption: native proposal storage remains valid during synchronous
capture on the calling thread. This was already required by the old decoder and
the existing checked-vector memcpy in `ReadIntVector`. Neither implementation can
make concurrent freeing/protection changes safe merely by calling VirtualQuery;
the capture queue lock alone is not a native allocator lock.

## Verification

Added native tests covering added/removed node and edge records across page
boundaries; differing readable page protections; PAGE_NOACCESS and PAGE_GUARD;
permissions restored on a later decode; a forbidden interior page; NaN rejection;
partially null, reversed, misaligned and inaccessible vector layouts; maximum
16,384-edge vectors with geometry and ownership checks.

Ran the standalone native test executable against the pinned stock game binary:
all assertions passed, including all 19 signature checks. This is a real Windows
native process test, not a mocked VirtualQuery implementation.

MSVC/SDK is absent after reinstall. For this test only, downloaded hash-verified
portable Zig 0.15.2 from the official ziglang.org download index into ignored
runtime/toolchains and compiled the native test target and all support sources
using its C++ compiler, C++20, -O2 and -fms-extensions. An initial compiler-cache
failure was resolved with a fresh ZIG_GLOBAL_CACHE_DIR. Native common's output
stream now explicitly wraps its wide filename in std::filesystem::path (same
Windows path semantics, avoids an MSVC-only stream constructor extension).

Artifacts: runtime/construction-read-tests/native_tests.exe and result.txt.
The production MSVC hook build/DLL acceptance test and live game latency test
remain outstanding. No hook installed, game launched, save modified, commit or
release made. No FPS improvement is claimed from the check-count reduction.

## Subsequent user-requested local installation

Installed Microsoft Visual Studio 2022 Build Tools 17.14.40 (VCTools and Windows
SDK) through winget's verified Microsoft installer. Built Release with the normal
MSVC/CMake workflow into `runtime/native-build-batched-reads`. Both CTest tests
passed (native regressions and DLL rejection in an unpinned process); direct
stock-executable tests and injector verification passed all 19 signatures.
Log: `runtime/construction-read-tests/production-build.txt`.

Copied the verified production hook and injector to the development launcher's
`runtime/native-build/Release` selection and verified matching hashes. Previous
files are backed up in
`runtime/construction-read-tests/previous-native-20260913-152908`.
Installed the development Lua mod with `tools/install.ps1` into the Steam profile's
local/mods/tpf2_mp_1 directory (previously absent). No bridge reset, game launch,
save edit or release publication. The hook is used by the repository launcher,
not by ordinary unhooked single-player launches.

Installed hook SHA256:
`25ef79d207a40443572e7340c8d5b7d1268d9393cc4a37195eea4a0cc4f0b0ab`.
Live latency measurements remain outstanding.
