#include "tpf2mp/native_common.hpp"
#include "tpf2mp/native_command_codec.hpp"
#include "tpf2mp/native_hook_status.hpp"

#include <array>
#include <cstring>
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
  if (tpf2mp::native_command::CommandTypeName(3) != "CreateLine" ||
      tpf2mp::native_command::CommandTypeName(99) != "unknown") {
    std::cerr << "native command tag names are invalid\n";
    return 1;
  }
  std::array<std::uint8_t, tpf2mp::profile::kDeleteLineMinimumSize> delete_command{};
  const std::int32_t expected_line = 42;
  std::memcpy(
      delete_command.data() + tpf2mp::profile::kDeleteLineTargetOffset,
      &expected_line,
      sizeof(expected_line));
  tpf2mp::native_command::SuppressedLineCommand decoded_delete;
  if (!tpf2mp::native_command::DecodeSuppressedLineCommand(
          4, delete_command.data(), decoded_delete) ||
      decoded_delete.tag != 4 || decoded_delete.target != expected_line) {
    std::cerr << "bounded DeleteLine decoder is invalid\n";
    return 1;
  }
  tpf2mp::native_command::SuppressedLineCommand encoded_line;
  encoded_line.tag = 29;
  encoded_line.target = expected_line;
  encoded_line.name = "A";
  if (tpf2mp::native_command::EncodeSuppressedLineCommand(encoded_line) !=
      "L1|29|42|-1|0|0|0|41|0|") {
    std::cerr << "pointer-free line command encoder is invalid\n";
    return 1;
  }
  const std::string status_stage = "test";
  const std::string status_error;
  const std::filesystem::path status_dll = L"test.dll";
  tpf2mp::ValidationResult status_validation;
  tpf2mp::native_status::HookFlags status_hooks;
  std::array<std::string, 4> status_args{};
  tpf2mp::native_command::TagCounts status_tags{};
  std::deque<tpf2mp::native_status::CompletedNativeCommand> status_events;
  std::map<void*, tpf2mp::native_status::LuaStateObservation> status_states;
  const auto status_json = tpf2mp::native_status::SerializeHookStatus(
      tpf2mp::native_status::HookStatusView{
          .process_id = 7,
          .stage = status_stage,
          .last_error = status_error,
          .dll_path = status_dll,
          .validation = status_validation,
          .hooks = status_hooks,
          .setup_last_args = status_args,
          .queued_tags = status_tags,
          .applied_tags = status_tags,
          .completed_commands = status_events,
          .recent_completed_commands = status_events,
          .command_gate_authorizations = status_tags,
          .command_gate_allowed = status_tags,
          .command_gate_suppressed = status_tags,
          .command_gate_passthrough = status_tags,
          .command_gate_calls = status_tags,
          .states = status_states,
      });
  if (status_json.find("\"schemaVersion\":1") == std::string::npos ||
      status_json.find("\"processId\":7") == std::string::npos ||
      status_json.find("\"stage\":\"test\"") == std::string::npos) {
    std::cerr << "native hook status serializer is invalid\n";
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
