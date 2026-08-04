#include "tpf2mp/native_common.hpp"

#include <filesystem>
#include <iostream>

int main(int argc, char** argv) {
  static_assert(sizeof(void*) == 8, "native probe must be built for x64");
  static_assert(tpf2mp::profile::kSignatures.size() == 16);
  static_assert(tpf2mp::profile::kAuthorityCommandVisitors.size() == 23);
  static_assert(tpf2mp::profile::kSetGameSpeedValueOffset == 0);
  static_assert(tpf2mp::profile::kSetGameSpeedMinimum == 0);
  static_assert(tpf2mp::profile::kSetGameSpeedMaximum == 4);
  static_assert(tpf2mp::profile::kCreateLineLineOffset == 0x00);
  static_assert(tpf2mp::profile::kCreateLineNameOffset == 0x28);
  static_assert(tpf2mp::profile::kCreateLineColorOffset == 0x48);
  static_assert(tpf2mp::profile::kCreateLinePlayerOffset == 0x54);
  static_assert(tpf2mp::profile::kUpdateLineLineOffset == 0x08);
  static_assert(tpf2mp::profile::kSetColorTargetOffset == 0x00);
  static_assert(tpf2mp::profile::kSetColorValueOffset == 0x04);
  static_assert(tpf2mp::profile::kSetColorMinimumSize == 0x10);
  static_assert(tpf2mp::profile::kSetNameTargetOffset == 0x00);
  static_assert(tpf2mp::profile::kSetNameValueOffset == 0x08);
  static_assert(tpf2mp::profile::kSetNameMinimumSize == 0x28);
  static_assert(tpf2mp::profile::kLineStopSize == 0xA8);
  static_assert(tpf2mp::profile::kLineStopStationGroupOffset == 0x00);
  static_assert(tpf2mp::profile::kLineStopStationOffset == 0x04);
  static_assert(tpf2mp::profile::kLineStopTerminalOffset == 0x08);
  static_assert(tpf2mp::profile::kMaximumLineStops == 256);
  if (tpf2mp::profile::kSha256.size() != 64 || tpf2mp::profile::kImageSize == 0 ||
      tpf2mp::profile::kPeTimestamp == 0 ||
      tpf2mp::profile::kCommandVisitorTableRva == 0) {
    std::cerr << "invalid compile-time build profile\n";
    return 1;
  }
  std::array<bool, tpf2mp::profile::kCommandVisitorCount> visitor_tags{};
  for (const auto& visitor : tpf2mp::profile::kAuthorityCommandVisitors) {
    if (visitor.tag >= visitor_tags.size() || visitor.tag == 15 || visitor.rva == 0 ||
        visitor_tags[visitor.tag]) {
      std::cerr << "invalid authority visitor profile\n";
      return 1;
    }
    visitor_tags[visitor.tag] = true;
  }
  if (argc == 1) {
    std::cout << "pinned profile constants are internally valid\n";
    return 0;
  }
  const auto validation = tpf2mp::ValidatePinnedExecutable(std::filesystem::path(argv[1]));
  std::cout << "valid=" << (validation.valid ? "true" : "false")
            << " sha256=" << validation.sha256
            << " signatures=" << validation.signatures.size() << "\n";
  for (const auto& signature : validation.signatures) {
    std::cout << signature.name << " matches=" << signature.matches
              << " rva=0x" << std::hex << signature.observed_rva << std::dec
              << " valid=" << (signature.expected_bytes_match ? "true" : "false") << "\n";
  }
  if (!validation.valid) {
    std::cerr << validation.error << "\n";
    return 2;
  }
  if (validation.signatures.size() != tpf2mp::profile::kSignatures.size() + 1) return 3;
  return 0;
}
