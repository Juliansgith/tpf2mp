// Offline checks for the vanilla builder-ghost previews: request parsing, the
// installer's fail-closed decisions, the bounded proposal guard, the one-shot
// request state machine with its expiry, the per-mode palette policy and the
// shared UI terrain composition. Fake renderer memory and stub engine
// routines stand in for the game; no game process, no hooks, no rendering.
//
// With a path argument the same binary maps the pinned Build 35924
// executable, relocates it and runs the real installer against it, so every
// pinned prologue this module hooks or calls is compared with the shipped
// machine code. tools/build_native_hook.ps1 passes the game executable.

#include "tpf2mp/native_preview_render.hpp"

#include <Windows.h>

#include <cmath>
#include <cstdint>
#include <cstring>
#include <fstream>
#include <iostream>
#include <iterator>
#include <new>
#include <string>
#include <vector>

namespace {

using namespace tpf2mp::preview_render;

bool Fail(const char* message) {
  std::cerr << "preview renderer: " << message << "\n";
  return false;
}

template <class T>
T Peek(const void* pointer, const std::size_t offset) {
  T value{};
  std::memcpy(&value, static_cast<const unsigned char*>(pointer) + offset, sizeof value);
  return value;
}
template <class T>
void Poke(void* pointer, const std::size_t offset, const T value) {
  std::memcpy(static_cast<unsigned char*>(pointer) + offset, &value, sizeof value);
}

// ------------------------------------------------------------------ fixtures
constexpr std::size_t kPaletteOffset = 0x118;
constexpr std::size_t kPaletteSize = 0x80;
constexpr std::size_t kStateOffset = 0x1b8;
constexpr std::size_t kHeightFirstOffset = 0x16b0;
constexpr std::size_t kHeightLastOffset = 0x16b8;
constexpr std::size_t kErrorFlagOffset = 0x1504;

struct TestRenderer {
  alignas(16) unsigned char renderer[0x1d0]{};
  alignas(16) unsigned char state[0x1750]{};
  int grid[6]{};
  TestRenderer(const int id, void* terrain) {
    grid[0] = id;
    Poke<void*>(renderer, 0x50, terrain);
    Poke<bool>(renderer, 0xf0, true);
    Poke<bool>(renderer, 0xf4, true);
    Poke<void*>(renderer, kStateOffset, state);
    Poke<void*>(state, kHeightFirstOffset, grid);
    Poke<void*>(state, kHeightLastOffset, grid + 6);
    for (std::size_t index = 0; index < kPaletteSize; ++index) {
      renderer[kPaletteOffset + index] = static_cast<unsigned char>(index);
    }
  }
};

std::uint64_t g_now = 100000;
std::uint64_t FakeNow() { return g_now; }

std::vector<int> g_height_calls;
void FakeResetHeight(void*, bool) { g_height_calls.push_back(-1); }
void FakeUploadHeight(void*, void* grids, bool) {
  g_height_calls.push_back(**reinterpret_cast<int**>(grids));
}
void FakeClear(void* renderer, bool, bool) {
  auto* state = Peek<unsigned char*>(renderer, kStateOffset);
  Poke<void*>(state, kHeightLastOffset, Peek<void*>(state, kHeightFirstOffset));
}
bool g_end_height_error;
void FakeEndHeight(void* renderer) {
  g_end_height_error = Peek<bool>(Peek<void*>(renderer, kStateOffset), kErrorFlagOffset);
}
void* g_color_target;
bool g_color_error;
unsigned g_color_calls;
void FakeErrorColor(void* renderer, const bool error) {
  g_color_target = renderer;
  g_color_error = error;
  ++g_color_calls;
  Poke<bool>(Peek<void*>(renderer, kStateOffset), kErrorFlagOffset, error);
}
void* FakeConvert(void* result, void*, void*) { return result; }
void FakeRendererDestructor(void*) {}
unsigned g_context_calls;
unsigned g_proposal_data_calls;
void FakeContextInit(void*, int) { ++g_context_calls; }
void FakeContextDestructor(void*) {}
void FakeCreateProposalData(void*, void*, void*, void*, void*, void*) { ++g_proposal_data_calls; }
void FakeProposalDataDestructor(void*) {}
struct UploadRecord {
  void* renderer{};
  unsigned char palette[kPaletteSize]{};
  unsigned calls{};
};
UploadRecord g_upload;
void FakeAddToRenderer(void*, void* renderer, void*, const float*, const void*, bool, bool, bool) {
  g_upload.renderer = renderer;
  std::memcpy(g_upload.palette, static_cast<unsigned char*>(renderer) + kPaletteOffset,
              kPaletteSize);
  ++g_upload.calls;
  auto* state = Peek<unsigned char*>(renderer, kStateOffset);
  Poke<unsigned char*>(state, kHeightLastOffset,
                       Peek<unsigned char*>(state, kHeightFirstOffset) + 6 * sizeof(int));
}

testing::Stubs FullStubs() {
  testing::Stubs stubs;
  stubs.convert = FakeConvert;
  stubs.clear = FakeClear;
  stubs.end_height = FakeEndHeight;
  stubs.renderer_destructor = FakeRendererDestructor;
  stubs.reset_height = FakeResetHeight;
  stubs.upload_height = FakeUploadHeight;
  stubs.error_color = FakeErrorColor;
  stubs.now = FakeNow;
  stubs.context_init = FakeContextInit;
  stubs.context_destructor = FakeContextDestructor;
  stubs.create_proposal_data = FakeCreateProposalData;
  stubs.proposal_data_destructor = FakeProposalDataDestructor;
  stubs.add_to_renderer = FakeAddToRenderer;
  return stubs;
}

// One temporary two-node, one-edge route, laid out exactly like a converted
// SimpleProposal's node and edge vectors.
struct RouteProposal {
  unsigned char proposal[0x2f8]{};
  unsigned char nodes[2 * 24]{};
  unsigned char edges[120]{};
  RouteProposal() {
    for (int index = 0; index < 2; ++index) {
      unsigned char* node = nodes + index * 24;
      Poke<float>(node, 0, static_cast<float>(index) * 10.0f);
      Poke<float>(node, 4, 0.0f);
      Poke<float>(node, 8, 0.0f);
      Poke<int>(node, 0x14, -1 - index);
    }
    Poke<int>(edges, 0, -10);
    Poke<int>(edges, 8, -1);
    Poke<int>(edges, 12, -2);
    Poke<float>(edges, 0x10, 1.0f);
    Poke<float>(edges, 0x1c, 1.0f);
    Poke<void*>(proposal, 0x00, nodes);
    Poke<void*>(proposal, 0x08, nodes + sizeof nodes);
    Poke<void*>(proposal, 0x18, edges);
    Poke<void*>(proposal, 0x20, edges + sizeof edges);
  }
};

// ------------------------------------------------------------------ requests
bool RequestParsingValid() {
  const Request unset = ParseRequest(L"");
  if (!unset.enabled || !unset.error.empty()) return Fail("an unset variable must enable previews");
  const Request off = ParseRequest(L"OFF");
  if (off.enabled || !off.error.empty()) return Fail("off must disable previews");
  for (const wchar_t* text : {L"0", L"false", L"none", L"stock"}) {
    if (ParseRequest(text).enabled) return Fail("every off spelling must disable previews");
  }
  for (const wchar_t* text : {L"1", L"on", L" True ", L"all"}) {
    if (!ParseRequest(text).enabled) return Fail("every on spelling must enable previews");
  }
  const Request unknown = ParseRequest(L"ghost");
  if (unknown.enabled || unknown.error.empty()) return Fail("unknown text must fail closed");
  return true;
}

// ----------------------------------------------------------------- installer
struct FakeHost {
  std::vector<std::uintptr_t> installed;
  std::vector<std::uintptr_t> verified;
  bool verify_result{true};
};
FakeHost* g_fake_host;

std::uintptr_t FakeModuleBase(void*) { return 0x10000; }
int FakeVerifyBytes(void*, const std::uintptr_t rva, const std::uint8_t*, const std::size_t) {
  g_fake_host->verified.push_back(rva);
  return g_fake_host->verify_result ? 1 : 0;
}
int FakeInstallHook(void*, const std::uintptr_t target, void*, void** original) {
  g_fake_host->installed.push_back(target);
  *original = reinterpret_cast<void*>(target);
  return 1;
}

bool InstallerValid() {
  FakeHost fake;
  g_fake_host = &fake;
  Host host;
  host.module_base = FakeModuleBase;
  host.verify_bytes = FakeVerifyBytes;
  host.install_hook = FakeInstallHook;

  testing::Reset();
  Request disabled = ParseRequest(L"off");
  Status status = Install(host, disabled);
  if (status.installed || status.enabled || status.reason.empty() || !fake.installed.empty()) {
    return Fail("a disabled request must not verify or patch anything");
  }
  if (UnavailableReason().empty()) return Fail("a disabled module must report a reason");

  testing::Reset();
  Request bad = ParseRequest(L"ghost");
  status = Install(host, bad);
  if (status.installed || status.reason.find("request") == std::string::npos) {
    return Fail("an unparsable request must be refused with its own reason");
  }

  testing::Reset();
  fake.verify_result = false;
  fake.verified.clear();
  status = Install(host, ParseRequest(L""));
  if (status.installed || !fake.installed.empty() ||
      status.reason.find("pinned bytes differ") == std::string::npos) {
    return Fail("a byte mismatch must refuse before any hook is installed");
  }
  if (fake.verified.size() != 1 || fake.verified.front() != kRendererFactoryRva) {
    return Fail("verification must stop at the first mismatch");
  }

  testing::Reset();
  Host incomplete;
  incomplete.module_base = FakeModuleBase;
  status = Install(incomplete, ParseRequest(L""));
  if (status.installed || status.reason.find("host services") == std::string::npos) {
    return Fail("incomplete host services must be refused");
  }
  testing::Reset();
  g_fake_host = nullptr;
  return true;
}

// ------------------------------------------------------------ proposal guard
bool ProposalGuardValid() {
  // Construction-only previews must pass without street pieces; malformed
  // transforms, paths and any removal must fail before native evaluation.
  alignas(16) unsigned char proposal[0x2f8]{};
  alignas(16) unsigned char construction[0x8e0]{};
  new (construction) std::string("station/rail/modular_station/modular_station.con");
  Poke<void*>(proposal, 0x1f8, construction);
  Poke<void*>(proposal, 0x200, construction + sizeof construction);
  for (const std::size_t index : {std::size_t(0), std::size_t(5), std::size_t(10), std::size_t(15)}) {
    Poke<float>(construction, 0x728 + index * 4, 1.0f);
  }
  bool ok = testing::SafeProposal(proposal);
  Poke<void*>(proposal, 0x1e8, construction);
  ok = ok && !testing::SafeProposal(proposal);
  Poke<void*>(proposal, 0x1e8, nullptr);
  Poke<float>(construction, 0x728, 0.0f);
  ok = ok && !testing::SafeProposal(proposal);
  Poke<float>(construction, 0x728, 1.0f);
  Poke<float>(construction, 0x728 + 12 * 4, INFINITY);
  ok = ok && !testing::SafeProposal(proposal);
  Poke<float>(construction, 0x728 + 12 * 4, 0.0f);
  *reinterpret_cast<std::string*>(construction) = "../bad.con";
  ok = ok && !testing::SafeProposal(proposal);
  *reinterpret_cast<std::string*>(construction) = "road/x.con";
  ok = ok && testing::SafeProposal(proposal);
  reinterpret_cast<std::string*>(construction)->~basic_string();
  if (!ok) return Fail("construction guard");

  RouteProposal route;
  if (!testing::SafeProposal(route.proposal)) return Fail("a plain two-node route must pass");
  // A non-temporary node id, an unresolved edge endpoint, a degenerate
  // tangent, an edge object and an oversized route must all be rejected.
  Poke<int>(route.nodes, 0x14, 7);
  if (testing::SafeProposal(route.proposal)) return Fail("positive entity ids must be rejected");
  Poke<int>(route.nodes, 0x14, -1);
  Poke<int>(route.edges, 12, -9);
  if (testing::SafeProposal(route.proposal)) return Fail("unresolved endpoints must be rejected");
  Poke<int>(route.edges, 12, -2);
  Poke<float>(route.edges, 0x1c, 0.0f);
  if (testing::SafeProposal(route.proposal)) return Fail("degenerate tangents must be rejected");
  Poke<float>(route.edges, 0x1c, 1.0f);
  Poke<void*>(route.edges, 0x38, route.edges + 1);
  if (testing::SafeProposal(route.proposal)) return Fail("edge objects must be rejected");
  Poke<void*>(route.edges, 0x38, nullptr);
  Poke<void*>(route.proposal, 0x20, route.edges + 120 * 25);
  if (testing::SafeProposal(route.proposal)) return Fail("oversized routes must be rejected");
  Poke<void*>(route.proposal, 0x20, route.edges + 120);
  Poke<void*>(route.proposal, 0x38, route.edges);
  if (testing::SafeProposal(route.proposal)) return Fail("removals must be rejected");
  Poke<void*>(route.proposal, 0x38, nullptr);
  if (!testing::SafeProposal(route.proposal)) return Fail("the route fixture must still pass");
  return true;
}

// ------------------------------------------------------- request lifecycle
bool ResultIs(const char* expected) { return std::strcmp(testing::Result(), expected) == 0; }

bool RequestLifecycleValid() {
  testing::Reset();
  if (!ResultIs("idle")) return Fail("a fresh module is idle");
  if (testing::Begin("player1", "draw")) return Fail("previews without a scene must be refused");

  int scene = 0;
  int terrain = 0;
  testing::SetStubs(FullStubs());
  testing::SetScene(&scene, &terrain);
  TestRenderer peer(1, &terrain);
  testing::SetPeer(0, "player1", peer.renderer, 0);
  RouteProposal route;
  int toolkit = 0;

  if (testing::Begin("Player1", "draw") || testing::Begin("player_1", "draw") ||
      testing::Begin("", "draw") || testing::Begin("123456789", "draw") ||
      testing::Begin("player1", "paint")) {
    return Fail("origin and mode validation");
  }
  if (!testing::Begin("player1", "draw")) return Fail("a draw request must arm");
  if (!ResultIs("pending")) return Fail("an armed request is pending");
  if (testing::Convert(route.proposal, &toolkit, nullptr) != route.proposal) {
    return Fail("the conversion result must be forwarded unchanged");
  }
  if (!ResultIs("ok")) return Fail("a consumed draw request reports ok");
  if (!ResultIs("idle")) return Fail("a terminal result is reported once");
  if (g_upload.calls != 1 || g_upload.renderer != peer.renderer || g_context_calls != 1 ||
      g_proposal_data_calls != 1) {
    return Fail("the draw must reach the peer's own renderer exactly once");
  }
  if (testing::PeerSeen(0) != g_now) return Fail("a drawn peer is stamped");

  // An unconsumed request expires; nothing is uploaded afterwards.
  if (!testing::Begin("player1", "draw")) return Fail("re-arming");
  g_now += kRequestLifetimeMs + 1;
  if (!ResultIs("error")) return Fail("an unconsumed request expires as an error");
  if (!ResultIs("idle")) return Fail("expiry is reported once");
  const unsigned uploads = g_upload.calls;
  testing::Convert(route.proposal, &toolkit, nullptr);
  if (g_upload.calls != uploads) return Fail("an expired request must not draw");

  // A replacement request supersedes the armed one without a terminal result.
  if (!testing::Begin("player1", "draw") || !testing::Begin("player1", "drawbad")) {
    return Fail("a new request replaces the armed one");
  }
  if (!ResultIs("pending")) return Fail("the replacement stays pending");
  testing::Convert(route.proposal, &toolkit, nullptr);
  if (!ResultIs("ok") || g_upload.calls != uploads + 1) return Fail("the replacement is drawn");

  // keep refreshes the stamp while the peer lives, and is refused once the
  // four-second window has passed, so Lua resends the geometry.
  g_now += 1000;
  if (!testing::Begin("player1", "keep") || testing::PeerSeen(0) != g_now) {
    return Fail("keep refreshes a live preview");
  }
  g_now += kPeerLifetimeMs + 1;
  if (testing::Begin("player1", "keep")) return Fail("keep must fail once the preview expired");
  if (!testing::Begin("player1", "clear")) return Fail("clear always succeeds");
  if (testing::PeerSeen(0) != 0) return Fail("clear drops the peer's stamp");

  // A rejected proposal is a terminal error, not a silent no-op.
  Poke<int>(route.nodes, 0x14, 11);
  if (!testing::Begin("player1", "draw")) return Fail("arming before a rejected proposal");
  testing::Convert(route.proposal, &toolkit, nullptr);
  if (!ResultIs("error")) return Fail("a rejected proposal reports an error");
  Poke<int>(route.nodes, 0x14, -1);

  const Counters counters = Snapshot();
  if (counters.requests != 5 || counters.drawn != 2 || counters.errors != 2) {
    return Fail("the status counters must follow the request log");
  }
  if (counters.session == 0 || !counters.scene) return Fail("an adopted scene has a session");
  return true;
}

// ----------------------------------------------------------------- appearance
bool AppearanceValid() {
  testing::Reset();
  int scene = 0;
  int terrain = 0;
  testing::SetStubs(FullStubs());
  testing::SetScene(&scene, &terrain);
  TestRenderer peer(1, &terrain);
  TestRenderer other(2, &terrain);
  testing::SetPeer(0, "player1", peer.renderer, 0);
  unsigned char palette[kPaletteSize]{};
  for (std::size_t index = 0; index < kPaletteSize; ++index) {
    palette[index] = static_cast<unsigned char>(index);
  }
  testing::SetPeerPalette(0, palette, sizeof palette);

  // The stock palette has four normal/error RGBA pairs. Unknown status keeps
  // it untouched, an error selection promotes the error half over both.
  for (const int status : {0, 1, -1}) {
    testing::ApplySenderPalette(0, status);
    for (std::size_t index = 0; index < kPaletteSize; ++index) {
      const unsigned expected = status == 0   ? static_cast<unsigned>(index % 0x40)
                                : status == 1 ? static_cast<unsigned>(0x40 + index % 0x40)
                                              : static_cast<unsigned>(index);
      if (peer.renderer[kPaletteOffset + index] != expected) return Fail("palette selection");
    }
    if (other.renderer[kPaletteOffset] != 0) return Fail("only the sender's renderer changes");
  }

  RouteProposal route;
  int toolkit = 0;
  // draw and drawok must upload the renderer's stock palette, so an accepted
  // remote preview is indistinguishable from the local builder ghost.
  for (const char* mode : {"draw", "drawok"}) {
    g_color_calls = 0;
    if (!testing::Begin("player1", mode)) return Fail("arming a stock-palette draw");
    testing::Convert(route.proposal, &toolkit, nullptr);
    if (std::memcmp(g_upload.palette, palette, kPaletteSize) != 0) {
      return Fail("draw and drawok must not tint the preview");
    }
    if (g_color_calls != 0) return Fail("draw and drawok must not touch the error colour");
  }
  // drawbad shows what the sender sees: the stock error palette, and the
  // renderer-wide error flag that the terrain overlay reads.
  g_color_calls = 0;
  if (!testing::Begin("player1", "drawbad")) return Fail("arming drawbad");
  testing::Convert(route.proposal, &toolkit, nullptr);
  for (std::size_t index = 0; index < kPaletteSize; ++index) {
    if (g_upload.palette[index] != palette[0x40 + index % 0x40]) {
      return Fail("drawbad must upload the stock error palette");
    }
  }
  if (g_color_calls != 1 || g_color_target != peer.renderer || !g_color_error) {
    return Fail("drawbad must select the error colour after the upload");
  }
  // The override ends with the upload: a later local evaluation is its own.
  g_color_calls = 0;
  testing::ErrorColor(other.renderer, false);
  if (g_color_calls != 1 || g_color_error) return Fail("the tint override must not outlive a draw");
  // A following stock draw restores the original palette on the same peer.
  if (!testing::Begin("player1", "draw")) return Fail("arming the restoring draw");
  testing::Convert(route.proposal, &toolkit, nullptr);
  if (std::memcmp(g_upload.palette, palette, kPaletteSize) != 0) {
    return Fail("a stock draw must restore the original palette");
  }

  // AddHeightMod writes the error flag directly, bypassing the setter, so
  // EndHeightMod restores a drawbad preview's status before the terrain
  // overlay is baked and leaves every other preview's evaluation alone.
  testing::ApplySenderMode(peer.renderer, "drawbad");
  Poke<bool>(peer.state, kErrorFlagOffset, false);
  testing::EndHeightMod(peer.renderer);
  if (!g_end_height_error) return Fail("drawbad must bake the sender's error status");
  testing::ApplySenderMode(peer.renderer, "drawok");
  Poke<bool>(peer.state, kErrorFlagOffset, true);
  testing::EndHeightMod(peer.renderer);
  if (!g_end_height_error) return Fail("drawok must keep the receiver's own evaluation");
  if (!Peek<bool>(peer.renderer, 0xf0)) return Fail("remote upload suppression is temporary");
  return true;
}

// -------------------------------------------------------------- shared terrain
bool TerrainCompositionValid() {
  testing::Reset();
  int scene = 0;
  int terrain = 0;
  testing::SetStubs(FullStubs());
  testing::SetScene(&scene, &terrain);
  TestRenderer remote1(1, &terrain);
  TestRenderer remote2(2, &terrain);
  TestRenderer local(3, &terrain);
  int other_world = 0;
  TestRenderer foreign(4, &other_world);
  testing::SetPeer(0, "a", remote1.renderer, g_now);
  testing::SetPeer(1, "b", remote2.renderer, g_now);

  testing::EndHeightMod(local.renderer);
  testing::EndHeightMod(local.renderer);  // registered only once
  testing::EndHeightMod(foreign.renderer);
  g_height_calls.clear();
  testing::ComposeTerrain();
  if (g_height_calls != std::vector<int>{-1, 1, 2, 3}) {
    return Fail("remote buffers first, the local builder last");
  }
  g_height_calls.clear();
  testing::ClearRenderer(local.renderer, true, true);
  if (g_height_calls != std::vector<int>{-1, 1, 2}) {
    return Fail("a local reset must keep every remote preview");
  }
  TestRenderer local_again(5, &terrain);
  testing::EndHeightMod(local_again.renderer);
  g_height_calls.clear();
  if (!testing::Begin("a", "clear")) return Fail("clearing one remote preview");
  if (g_height_calls != std::vector<int>{-1, 2, 5}) {
    return Fail("a remote cancel must keep the other preview and the local tool");
  }
  g_height_calls.clear();
  g_now += kPeerLifetimeMs + 1;
  if (!testing::ExpirePeers()) return Fail("a stale preview must expire");
  testing::ComposeTerrain();
  if (g_height_calls != std::vector<int>{-1, 5}) return Fail("expiry keeps the local tool");
  if (testing::ExpirePeers()) return Fail("expiry is reported once");
  return true;
}

// --------------------------------------------------------- pinned executable
// Maps the shipped executable into this process the way the loader would,
// applies its base relocations and runs the real installer against it.
struct MappedImage {
  std::vector<unsigned char> bytes;
  std::uintptr_t base{};
};

bool MapPinnedImage(const char* path, MappedImage& image) {
  std::ifstream file(path, std::ios::binary);
  if (!file) return Fail("the pinned executable could not be opened");
  const std::vector<unsigned char> raw((std::istreambuf_iterator<char>(file)),
                                       std::istreambuf_iterator<char>());
  if (raw.size() < sizeof(IMAGE_DOS_HEADER)) return Fail("the pinned executable is truncated");
  const auto* dos = reinterpret_cast<const IMAGE_DOS_HEADER*>(raw.data());
  if (dos->e_magic != IMAGE_DOS_SIGNATURE ||
      static_cast<std::size_t>(dos->e_lfanew) + sizeof(IMAGE_NT_HEADERS64) > raw.size()) {
    return Fail("the pinned executable is not a PE image");
  }
  const auto* nt = reinterpret_cast<const IMAGE_NT_HEADERS64*>(raw.data() + dos->e_lfanew);
  if (nt->Signature != IMAGE_NT_SIGNATURE ||
      nt->FileHeader.Machine != IMAGE_FILE_MACHINE_AMD64) {
    return Fail("the pinned executable is not an x64 PE image");
  }
  image.bytes.assign(nt->OptionalHeader.SizeOfImage, 0);
  std::memcpy(image.bytes.data(), raw.data(), nt->OptionalHeader.SizeOfHeaders);
  const auto* section = IMAGE_FIRST_SECTION(nt);
  for (unsigned index = 0; index < nt->FileHeader.NumberOfSections; ++index, ++section) {
    if (section->SizeOfRawData == 0) continue;
    if (static_cast<std::size_t>(section->PointerToRawData) + section->SizeOfRawData > raw.size() ||
        static_cast<std::size_t>(section->VirtualAddress) + section->SizeOfRawData >
            image.bytes.size()) {
      return Fail("a section of the pinned executable is out of range");
    }
    std::memcpy(image.bytes.data() + section->VirtualAddress, raw.data() + section->PointerToRawData,
                section->SizeOfRawData);
  }
  image.base = reinterpret_cast<std::uintptr_t>(image.bytes.data());
  const std::uintptr_t delta = image.base - nt->OptionalHeader.ImageBase;
  const auto& directory =
      nt->OptionalHeader.DataDirectory[IMAGE_DIRECTORY_ENTRY_BASERELOC];
  std::size_t offset = directory.VirtualAddress;
  const std::size_t end = offset + directory.Size;
  while (offset + sizeof(IMAGE_BASE_RELOCATION) <= end && end <= image.bytes.size()) {
    const auto* block =
        reinterpret_cast<const IMAGE_BASE_RELOCATION*>(image.bytes.data() + offset);
    if (block->SizeOfBlock < sizeof(IMAGE_BASE_RELOCATION)) break;
    const std::size_t count =
        (block->SizeOfBlock - sizeof(IMAGE_BASE_RELOCATION)) / sizeof(std::uint16_t);
    const auto* entries =
        reinterpret_cast<const std::uint16_t*>(block + 1);
    for (std::size_t index = 0; index < count; ++index) {
      if ((entries[index] >> 12) != IMAGE_REL_BASED_DIR64) continue;
      const std::size_t target = block->VirtualAddress + (entries[index] & 0x0fff);
      if (target + sizeof(std::uintptr_t) > image.bytes.size()) continue;
      std::uintptr_t value = 0;
      std::memcpy(&value, image.bytes.data() + target, sizeof value);
      value += delta;
      std::memcpy(image.bytes.data() + target, &value, sizeof value);
    }
    offset += block->SizeOfBlock;
  }
  return true;
}

MappedImage* g_image;
std::uintptr_t ImageBase(void*) { return g_image->base; }
int ImageVerifyBytes(void*, const std::uintptr_t rva, const std::uint8_t* expected,
                     const std::size_t size) {
  if (rva + size > g_image->bytes.size()) return 0;
  const bool matches = std::memcmp(g_image->bytes.data() + rva, expected, size) == 0;
  if (matches) g_fake_host->verified.push_back(rva);
  return matches ? 1 : 0;
}

bool PinnedImageValid(const char* path) {
  MappedImage image;
  if (!MapPinnedImage(path, image)) return false;
  g_image = &image;
  FakeHost fake;
  g_fake_host = &fake;
  Host host;
  host.module_base = ImageBase;
  host.verify_bytes = ImageVerifyBytes;
  host.install_hook = FakeInstallHook;

  // A single changed byte at a hooked prologue must refuse the installation.
  testing::Reset();
  unsigned char& first = image.bytes[kScriptingConvertRva];
  const unsigned char original = first;
  first = static_cast<unsigned char>(original ^ 0xff);
  Status status = Install(host, ParseRequest(L""));
  if (status.installed || status.reason.find("scripting::Convert") == std::string::npos ||
      !fake.installed.empty()) {
    return Fail("a changed prologue must refuse the installation");
  }
  first = original;

  testing::Reset();
  fake.installed.clear();
  fake.verified.clear();
  status = Install(host, ParseRequest(L""));
  if (!status.installed || !status.reason.empty()) {
    return Fail(("the pinned executable must install: " + status.reason).c_str());
  }
  const std::uintptr_t expected[kHookCount] = {
      kRendererFactoryRva,   kSceneAddRenderableRva,     kSceneDestructorRva,
      kScriptingConvertRva,  kBuilderRendererClearRva,   kEndHeightModRva,
      kBuilderRendererDestructorRva};
  if (fake.installed.size() != kHookCount) return Fail("seven detours must be installed");
  for (std::size_t index = 0; index < kHookCount; ++index) {
    if (fake.installed[index] != image.base + expected[index]) {
      return Fail("a detour was installed at the wrong address");
    }
  }
  std::cout << "pinned prologues verified (" << fake.verified.size() << "):";
  for (const std::uintptr_t rva : fake.verified) std::cout << " 0x" << std::hex << rva << std::dec;
  std::cout << "\nhooks installed: " << fake.installed.size() << "\n";
  testing::Reset();
  g_fake_host = nullptr;
  g_image = nullptr;
  return true;
}

}  // namespace

int main(int argc, char** argv) {
  static_assert(sizeof(void*) == 8, "the preview renderer is x64 only");
  if (!RequestParsingValid() || !InstallerValid() || !ProposalGuardValid() ||
      !RequestLifecycleValid() || !AppearanceValid() || !TerrainCompositionValid()) {
    return 1;
  }
  if (argc > 1 && !PinnedImageValid(argv[1])) return 1;
  std::cout << "native preview render contracts passed"
            << (argc > 1 ? " against the pinned executable\n" : "\n");
  return 0;
}
