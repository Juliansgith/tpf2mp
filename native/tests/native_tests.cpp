#include "tpf2mp/native_common.hpp"
#include "tpf2mp/native_command_codec.hpp"
#include "tpf2mp/native_hook_status.hpp"

#include <array>
#include <cstring>
#include <filesystem>
#include <iostream>
#include <limits>

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
  static_assert(tpf2mp::profile::kLineStopAlternativeTerminalsOffset == 0x10);
  static_assert(tpf2mp::profile::kStationTerminalSize == 0x08);
  static_assert(tpf2mp::profile::kSetUserStoppedValueOffset == 0x04);
  static_assert(tpf2mp::profile::kSetVehicleMaintenanceValueOffset == 0x04);
  static_assert(tpf2mp::profile::kSendToDepotSellOnArrivalOffset == 0x04);
  static_assert(tpf2mp::profile::kSetVehicleManualDepartureValueOffset == 0x04);
  static_assert(tpf2mp::profile::kReplaceVehicleTargetOffset == 0x00);
  static_assert(tpf2mp::profile::kSellVehicleMinimumSize == 0x18);
  static_assert(tpf2mp::profile::kSellVehicleTargetSize == sizeof(std::int32_t));
  static_assert(sizeof(tpf2mp::native_command::SuppressedStationTerminal) ==
                tpf2mp::profile::kStationTerminalSize);
  static_assert(tpf2mp::profile::kMaximumAlternativeTerminalsPerStop == 64);
  static_assert(tpf2mp::profile::kMaximumLineStops == 256);
  static_assert(tpf2mp::profile::kSetLineVehicleOffset == 0x00);
  static_assert(tpf2mp::profile::kSetLineLineOffset == 0x04);
  static_assert(tpf2mp::profile::kSetLineStopIndexOffset == 0x08);
  static_assert(tpf2mp::profile::kAutomaticLineStopIndex == -1);
  static_assert(tpf2mp::profile::kBuyVehiclePlayerOffset == 0x00);
  static_assert(tpf2mp::profile::kBuyVehicleDepotOffset == 0x04);
  static_assert(tpf2mp::profile::kBuyVehicleConfigOffset == 0x08);
  static_assert(tpf2mp::profile::kBuyVehicleResultOffset == 0x38);
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
      "L3|29|42|-1|0|0|0|41|0|") {
    std::cerr << "pointer-free line command encoder is invalid\n";
    return 1;
  }
  std::array<std::uint8_t, tpf2mp::profile::kLineStopSize> native_stop{};
  const std::int32_t station_group = 901;
  const std::int32_t station = 1;
  const std::int32_t terminal = 2;
  std::array<tpf2mp::native_command::SuppressedStationTerminal, 2> alternatives{{
      {3, 5}, {4, 6},
  }};
  std::memcpy(native_stop.data() + tpf2mp::profile::kLineStopStationGroupOffset,
              &station_group, sizeof(station_group));
  std::memcpy(native_stop.data() + tpf2mp::profile::kLineStopStationOffset,
              &station, sizeof(station));
  std::memcpy(native_stop.data() + tpf2mp::profile::kLineStopTerminalOffset,
              &terminal, sizeof(terminal));
  tpf2mp::native_command::NativeVectorLayout alternative_layout{
      reinterpret_cast<std::uint8_t*>(alternatives.data()),
      reinterpret_cast<std::uint8_t*>(alternatives.data() + alternatives.size()),
      reinterpret_cast<std::uint8_t*>(alternatives.data() + alternatives.size()),
  };
  std::memcpy(
      native_stop.data() + tpf2mp::profile::kLineStopAlternativeTerminalsOffset,
      &alternative_layout, sizeof(alternative_layout));
  tpf2mp::native_command::NativeVectorLayout stop_layout{
      native_stop.data(), native_stop.data() + native_stop.size(),
      native_stop.data() + native_stop.size(),
  };
  std::array<std::uint8_t, tpf2mp::profile::kUpdateLineMinimumSize> update_command{};
  std::memcpy(update_command.data() + tpf2mp::profile::kUpdateLineTargetOffset,
              &expected_line, sizeof(expected_line));
  std::memcpy(update_command.data() + tpf2mp::profile::kUpdateLineLineOffset,
              &stop_layout, sizeof(stop_layout));
  tpf2mp::native_command::SuppressedLineCommand decoded_update;
  if (!tpf2mp::native_command::DecodeSuppressedLineCommand(
          5, update_command.data(), decoded_update) ||
      decoded_update.stops.size() != 1 ||
      decoded_update.stops[0].alternative_terminals !=
          std::vector<tpf2mp::native_command::SuppressedStationTerminal>({
              {3, 5}, {4, 6},
          }) ||
      tpf2mp::native_command::EncodeSuppressedLineCommand(decoded_update) !=
          "L3|5|42|-1|0|0|0||1|901,1,2,3.5:4.6") {
    std::cerr << "bounded alternative-terminal line decoder is invalid\n";
    return 1;
  }
  std::array<std::uint8_t, tpf2mp::profile::kSetLineMinimumSize> set_line_command{};
  const std::int32_t expected_vehicle = 71;
  const std::int32_t expected_stop = tpf2mp::profile::kAutomaticLineStopIndex;
  std::memcpy(set_line_command.data() + tpf2mp::profile::kSetLineVehicleOffset,
              &expected_vehicle, sizeof(expected_vehicle));
  std::memcpy(set_line_command.data() + tpf2mp::profile::kSetLineLineOffset,
              &expected_line, sizeof(expected_line));
  std::memcpy(set_line_command.data() + tpf2mp::profile::kSetLineStopIndexOffset,
              &expected_stop, sizeof(expected_stop));
  tpf2mp::native_command::SuppressedVehicleCommand decoded_set_line;
  if (!tpf2mp::native_command::DecodeSuppressedVehicleCommand(
          6, set_line_command.data(), decoded_set_line) ||
      decoded_set_line.target != expected_vehicle ||
      decoded_set_line.secondary != expected_line ||
      decoded_set_line.value != expected_stop ||
      tpf2mp::native_command::EncodeSuppressedVehicleCommand(decoded_set_line) !=
          "V2|6|71|42|-1") {
    std::cerr << "pointer-free automatic-stop SetLine vehicle codec is invalid\n";
    return 1;
  }
  const std::int32_t explicit_stop = 3;
  std::memcpy(set_line_command.data() + tpf2mp::profile::kSetLineStopIndexOffset,
              &explicit_stop, sizeof(explicit_stop));
  if (!tpf2mp::native_command::DecodeSuppressedVehicleCommand(
          6, set_line_command.data(), decoded_set_line) ||
      decoded_set_line.value != explicit_stop ||
      tpf2mp::native_command::EncodeSuppressedVehicleCommand(decoded_set_line) !=
          "V2|6|71|42|3") {
    std::cerr << "pointer-free explicit-stop SetLine vehicle codec is invalid\n";
    return 1;
  }
  const std::int32_t invalid_stop = -2;
  std::memcpy(set_line_command.data() + tpf2mp::profile::kSetLineStopIndexOffset,
              &invalid_stop, sizeof(invalid_stop));
  if (tpf2mp::native_command::DecodeSuppressedVehicleCommand(
          6, set_line_command.data(), decoded_set_line)) {
    std::cerr << "SetLine vehicle codec admitted an invalid negative stop index\n";
    return 1;
  }
  const std::int32_t excessive_stop =
      static_cast<std::int32_t>(tpf2mp::profile::kMaximumLineStops);
  std::memcpy(set_line_command.data() + tpf2mp::profile::kSetLineStopIndexOffset,
              &excessive_stop, sizeof(excessive_stop));
  if (tpf2mp::native_command::DecodeSuppressedVehicleCommand(
          6, set_line_command.data(), decoded_set_line)) {
    std::cerr << "SetLine vehicle codec admitted an out-of-range stop index\n";
    return 1;
  }
  std::array<std::uint8_t, tpf2mp::profile::kBuyVehicleMinimumSize> buy_command{};
  const std::int32_t expected_player = 9;
  const std::int32_t expected_depot = 88;
  std::memcpy(buy_command.data() + tpf2mp::profile::kBuyVehiclePlayerOffset,
              &expected_player, sizeof(expected_player));
  std::memcpy(buy_command.data() + tpf2mp::profile::kBuyVehicleDepotOffset,
              &expected_depot, sizeof(expected_depot));
  tpf2mp::native_command::SuppressedVehicleCommand decoded_buy;
  if (!tpf2mp::native_command::DecodeSuppressedVehicleCommand(
          13, buy_command.data(), decoded_buy) ||
      tpf2mp::native_command::EncodeSuppressedVehicleCommand(decoded_buy) !=
          "V2|13|9|88|0") {
    std::cerr << "pointer-free BuyVehicle scalar codec is invalid\n";
    return 1;
  }
  auto vehicle_codec_matches = [](const int tag, const void* data,
                                  const std::int32_t target,
                                  const std::int32_t secondary,
                                  const std::int32_t value,
                                  const std::string_view envelope) {
    tpf2mp::native_command::SuppressedVehicleCommand decoded;
    return tpf2mp::native_command::DecodeSuppressedVehicleCommand(tag, data, decoded) &&
           decoded.target == target && decoded.secondary == secondary &&
           decoded.value == value &&
           tpf2mp::native_command::EncodeSuppressedVehicleCommand(decoded) == envelope;
  };
  std::array<std::uint8_t, tpf2mp::profile::kReverseVehicleMinimumSize> reverse_command{};
  std::memcpy(reverse_command.data() + tpf2mp::profile::kReverseVehicleTargetOffset,
              &expected_vehicle, sizeof(expected_vehicle));
  if (!vehicle_codec_matches(7, reverse_command.data(), expected_vehicle, 0, 0,
                             "V2|7|71|0|0")) {
    std::cerr << "Reverse vehicle scalar codec is invalid\n";
    return 1;
  }
  std::array<std::uint8_t, tpf2mp::profile::kSetUserStoppedMinimumSize> stop_command{};
  const std::uint8_t enabled = 1;
  std::memcpy(stop_command.data() + tpf2mp::profile::kSetUserStoppedTargetOffset,
              &expected_vehicle, sizeof(expected_vehicle));
  std::memcpy(stop_command.data() + tpf2mp::profile::kSetUserStoppedValueOffset,
              &enabled, sizeof(enabled));
  if (!vehicle_codec_matches(8, stop_command.data(), expected_vehicle, 0, 1,
                             "V2|8|71|0|1")) {
    std::cerr << "SetUserStopped vehicle scalar codec is invalid\n";
    return 1;
  }
  const std::uint8_t invalid_boolean = 2;
  std::memcpy(stop_command.data() + tpf2mp::profile::kSetUserStoppedValueOffset,
              &invalid_boolean, sizeof(invalid_boolean));
  tpf2mp::native_command::SuppressedVehicleCommand invalid_vehicle;
  if (tpf2mp::native_command::DecodeSuppressedVehicleCommand(
          8, stop_command.data(), invalid_vehicle)) {
    std::cerr << "SetUserStopped codec admitted a non-boolean byte\n";
    return 1;
  }
  std::array<std::uint8_t, tpf2mp::profile::kSetVehicleMaintenanceMinimumSize>
      maintenance_command{};
  const float expected_maintenance = 0.625F;
  std::memcpy(maintenance_command.data() +
                  tpf2mp::profile::kSetVehicleMaintenanceTargetOffset,
              &expected_vehicle, sizeof(expected_vehicle));
  std::memcpy(maintenance_command.data() +
                  tpf2mp::profile::kSetVehicleMaintenanceValueOffset,
              &expected_maintenance, sizeof(expected_maintenance));
  if (!vehicle_codec_matches(9, maintenance_command.data(), expected_vehicle, 0, 6250,
                             "V2|9|71|0|6250")) {
    std::cerr << "maintenance vehicle scalar codec is invalid\n";
    return 1;
  }
  for (const float invalid_maintenance : {
           std::numeric_limits<float>::quiet_NaN(), -0.01F, 1.01F,
           std::numeric_limits<float>::infinity()}) {
    std::memcpy(maintenance_command.data() +
                    tpf2mp::profile::kSetVehicleMaintenanceValueOffset,
                &invalid_maintenance, sizeof(invalid_maintenance));
    if (tpf2mp::native_command::DecodeSuppressedVehicleCommand(
            9, maintenance_command.data(), invalid_vehicle)) {
      std::cerr << "maintenance codec admitted a non-finite or out-of-range value\n";
      return 1;
    }
  }
  std::array<std::uint8_t, tpf2mp::profile::kSetVehicleShouldDepartMinimumSize>
      depart_command{};
  std::memcpy(depart_command.data() +
                  tpf2mp::profile::kSetVehicleShouldDepartTargetOffset,
              &expected_vehicle, sizeof(expected_vehicle));
  if (!vehicle_codec_matches(10, depart_command.data(), expected_vehicle, 0, 0,
                             "V2|10|71|0|0")) {
    std::cerr << "SetVehicleShouldDepart scalar codec is invalid\n";
    return 1;
  }
  std::array<std::uint8_t, tpf2mp::profile::kSendToDepotMinimumSize> depot_command{};
  std::memcpy(depot_command.data() + tpf2mp::profile::kSendToDepotTargetOffset,
              &expected_vehicle, sizeof(expected_vehicle));
  std::memcpy(depot_command.data() +
                  tpf2mp::profile::kSendToDepotSellOnArrivalOffset,
              &enabled, sizeof(enabled));
  if (!vehicle_codec_matches(11, depot_command.data(), expected_vehicle, 0, 1,
                             "V2|11|71|0|1")) {
    std::cerr << "SendToDepot scalar codec is invalid\n";
    return 1;
  }
  std::array<std::int32_t, 1> sale_targets{expected_vehicle};
  tpf2mp::native_command::NativeVectorLayout sale_layout{
      reinterpret_cast<std::uint8_t*>(sale_targets.data()),
      reinterpret_cast<std::uint8_t*>(sale_targets.data() + sale_targets.size()),
      reinterpret_cast<std::uint8_t*>(sale_targets.data() + sale_targets.size()),
  };
  std::array<std::uint8_t, tpf2mp::profile::kSellVehicleMinimumSize> sale_command{};
  std::memcpy(sale_command.data() + tpf2mp::profile::kSellVehicleTargetsOffset,
              &sale_layout, sizeof(sale_layout));
  if (!vehicle_codec_matches(12, sale_command.data(), expected_vehicle, 1, 0,
                             "V2|12|71|1|0")) {
    std::cerr << "single SellVehicle vector codec is invalid\n";
    return 1;
  }
  std::array<std::int32_t, 2> sale_batch{expected_vehicle, 72};
  sale_layout = {
      reinterpret_cast<std::uint8_t*>(sale_batch.data()),
      reinterpret_cast<std::uint8_t*>(sale_batch.data() + sale_batch.size()),
      reinterpret_cast<std::uint8_t*>(sale_batch.data() + sale_batch.size()),
  };
  std::memcpy(sale_command.data() + tpf2mp::profile::kSellVehicleTargetsOffset,
              &sale_layout, sizeof(sale_layout));
  if (!vehicle_codec_matches(12, sale_command.data(), expected_vehicle, 2, 0,
                             "V2|12|71|2|0")) {
    std::cerr << "multi SellVehicle vector metadata codec is invalid\n";
    return 1;
  }
  sale_batch[1] = -1;
  if (tpf2mp::native_command::DecodeSuppressedVehicleCommand(
          12, sale_command.data(), invalid_vehicle)) {
    std::cerr << "SellVehicle codec admitted a negative entity in its vector\n";
    return 1;
  }
  sale_layout.end = sale_layout.begin;
  std::memcpy(sale_command.data() + tpf2mp::profile::kSellVehicleTargetsOffset,
              &sale_layout, sizeof(sale_layout));
  if (tpf2mp::native_command::DecodeSuppressedVehicleCommand(
          12, sale_command.data(), invalid_vehicle)) {
    std::cerr << "SellVehicle codec admitted an empty selection\n";
    return 1;
  }
  std::array<std::uint8_t, tpf2mp::profile::kReplaceVehicleMinimumSize>
      replace_command{};
  std::memcpy(replace_command.data() + tpf2mp::profile::kReplaceVehicleTargetOffset,
              &expected_vehicle, sizeof(expected_vehicle));
  if (!vehicle_codec_matches(14, replace_command.data(), expected_vehicle, 0, 0,
                             "V2|14|71|0|0")) {
    std::cerr << "ReplaceVehicle scalar correlation codec is invalid\n";
    return 1;
  }
  std::array<std::uint8_t, tpf2mp::profile::kSetVehicleManualDepartureMinimumSize>
      manual_departure_command{};
  std::memcpy(manual_departure_command.data() +
                  tpf2mp::profile::kSetVehicleManualDepartureTargetOffset,
              &expected_vehicle, sizeof(expected_vehicle));
  std::memcpy(manual_departure_command.data() +
                  tpf2mp::profile::kSetVehicleManualDepartureValueOffset,
              &enabled, sizeof(enabled));
  if (!vehicle_codec_matches(30, manual_departure_command.data(), expected_vehicle, 0, 1,
                             "V2|30|71|0|1")) {
    std::cerr << "SetVehicleManualDeparture scalar codec is invalid\n";
    return 1;
  }
  const std::int32_t invalid_vehicle_id = -1;
  std::memcpy(reverse_command.data() + tpf2mp::profile::kReverseVehicleTargetOffset,
              &invalid_vehicle_id, sizeof(invalid_vehicle_id));
  if (tpf2mp::native_command::DecodeSuppressedVehicleCommand(
          7, reverse_command.data(), invalid_vehicle)) {
    std::cerr << "lifecycle codec admitted a negative vehicle id\n";
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
