#include "tpf2mp/native_command_codec.hpp"

#include "tpf2mp/build_profile.hpp"

#include <algorithm>
#include <cmath>
#include <cstdint>
#include <cstring>
#include <sstream>

namespace tpf2mp::native_command {
namespace {

template <typename Value>
bool ReadValue(const std::uint8_t* base, const std::size_t offset, Value& output) {
  if (base == nullptr || !IsReadableRange(base + offset, sizeof(Value))) return false;
  std::memcpy(&output, base + offset, sizeof(Value));
  return true;
}

bool DecodeTargetOnly(const std::uint8_t* data, const std::size_t minimum_size,
                      const std::size_t target_offset, SuppressedVehicleCommand& output) {
  output.secondary = 0;
  output.value = 0;
  return IsReadableRange(data, minimum_size) &&
         ReadValue(data, target_offset, output.target) && output.target >= 0;
}

bool DecodeTargetBoolean(const std::uint8_t* data, const std::size_t minimum_size,
                         const std::size_t target_offset, const std::size_t value_offset,
                         SuppressedVehicleCommand& output) {
  std::uint8_t value = 0;
  output.secondary = 0;
  if (!IsReadableRange(data, minimum_size) ||
      !ReadValue(data, target_offset, output.target) ||
      !ReadValue(data, value_offset, value) || output.target < 0 || value > 1) {
    return false;
  }
  output.value = value;
  return true;
}

bool DecodeSaleTargets(const std::uint8_t* data, SuppressedVehicleCommand& output) {
  NativeVectorLayout layout{};
  if (!IsReadableRange(data, tpf2mp::profile::kSellVehicleMinimumSize) ||
      !ReadValue(data, tpf2mp::profile::kSellVehicleTargetsOffset, layout)) {
    return false;
  }
  const auto begin = reinterpret_cast<std::uintptr_t>(layout.begin);
  const auto end = reinterpret_cast<std::uintptr_t>(layout.end);
  const auto capacity = reinterpret_cast<std::uintptr_t>(layout.capacity);
  if (begin == 0 || end == 0 || capacity == 0 || begin > end || end > capacity) {
    return false;
  }
  const auto used_bytes = end - begin;
  const auto capacity_bytes = capacity - begin;
  if (used_bytes % tpf2mp::profile::kSellVehicleTargetSize != 0 ||
      capacity_bytes % tpf2mp::profile::kSellVehicleTargetSize != 0) {
    return false;
  }
  const auto count = used_bytes / tpf2mp::profile::kSellVehicleTargetSize;
  const auto capacity_count = capacity_bytes / tpf2mp::profile::kSellVehicleTargetSize;
  if (count == 0 || count > tpf2mp::profile::kMaximumSellVehicleTargets ||
      capacity_count > tpf2mp::profile::kMaximumSellVehicleTargetCapacity ||
      !IsReadableRange(layout.begin, used_bytes)) {
    return false;
  }
  for (std::size_t index = 0; index < count; ++index) {
    std::int32_t target = -1;
    std::memcpy(&target,
                layout.begin + index * tpf2mp::profile::kSellVehicleTargetSize,
                sizeof(target));
    if (target < 0) return false;
    if (index == 0) output.target = target;
  }
  output.secondary = static_cast<std::int32_t>(count);
  output.value = 0;
  return true;
}

}  // namespace

bool DecodeSuppressedVehicleCommand(const int tag, const void* command_data,
                                    SuppressedVehicleCommand& output) {
  const auto* data = static_cast<const std::uint8_t*>(command_data);
  output = SuppressedVehicleCommand{};
  output.tag = tag;
  if (tag == 6) {
    return IsReadableRange(data, tpf2mp::profile::kSetLineMinimumSize) &&
           ReadValue(data, tpf2mp::profile::kSetLineVehicleOffset, output.target) &&
           ReadValue(data, tpf2mp::profile::kSetLineLineOffset, output.secondary) &&
           ReadValue(data, tpf2mp::profile::kSetLineStopIndexOffset, output.value) &&
           output.target >= 0 && output.secondary >= 0 &&
           output.value >= tpf2mp::profile::kAutomaticLineStopIndex &&
           output.value < static_cast<std::int32_t>(tpf2mp::profile::kMaximumLineStops);
  }
  if (tag == 7) {
    return DecodeTargetOnly(data, tpf2mp::profile::kReverseVehicleMinimumSize,
                            tpf2mp::profile::kReverseVehicleTargetOffset, output);
  }
  if (tag == 8) {
    return DecodeTargetBoolean(data, tpf2mp::profile::kSetUserStoppedMinimumSize,
                               tpf2mp::profile::kSetUserStoppedTargetOffset,
                               tpf2mp::profile::kSetUserStoppedValueOffset, output);
  }
  if (tag == 9) {
    float value = 0.0F;
    output.secondary = 0;
    if (!IsReadableRange(data, tpf2mp::profile::kSetVehicleMaintenanceMinimumSize) ||
        !ReadValue(data, tpf2mp::profile::kSetVehicleMaintenanceTargetOffset, output.target) ||
        !ReadValue(data, tpf2mp::profile::kSetVehicleMaintenanceValueOffset, value) ||
        output.target < 0 || !std::isfinite(value) || value < 0.0F || value > 1.0F) {
      return false;
    }
    output.value = static_cast<std::int32_t>(std::lround(value * 10000.0F));
    return true;
  }
  if (tag == 10) {
    return DecodeTargetOnly(data, tpf2mp::profile::kSetVehicleShouldDepartMinimumSize,
                            tpf2mp::profile::kSetVehicleShouldDepartTargetOffset, output);
  }
  if (tag == 11) {
    return DecodeTargetBoolean(data, tpf2mp::profile::kSendToDepotMinimumSize,
                               tpf2mp::profile::kSendToDepotTargetOffset,
                               tpf2mp::profile::kSendToDepotSellOnArrivalOffset, output);
  }
  if (tag == 12) return DecodeSaleTargets(data, output);
  if (tag == 13) {
    return IsReadableRange(data, tpf2mp::profile::kBuyVehicleMinimumSize) &&
           ReadValue(data, tpf2mp::profile::kBuyVehiclePlayerOffset, output.target) &&
           ReadValue(data, tpf2mp::profile::kBuyVehicleDepotOffset, output.secondary) &&
           output.target >= 0 && output.secondary >= 0;
  }
  if (tag == 14) {
    return DecodeTargetOnly(data, tpf2mp::profile::kReplaceVehicleMinimumSize,
                            tpf2mp::profile::kReplaceVehicleTargetOffset, output);
  }
  if (tag == 30) {
    return DecodeTargetBoolean(data, tpf2mp::profile::kSetVehicleManualDepartureMinimumSize,
                               tpf2mp::profile::kSetVehicleManualDepartureTargetOffset,
                               tpf2mp::profile::kSetVehicleManualDepartureValueOffset, output);
  }
  return false;
}

std::string EncodeSuppressedVehicleCommand(const SuppressedVehicleCommand& command) {
  // V2 widens the pointer-free envelope to the pinned lifecycle scalar tags.
  std::ostringstream output;
  output << "V2|" << command.tag << '|' << command.target << '|'
         << command.secondary << '|' << command.value;
  return output.str();
}

}  // namespace tpf2mp::native_command
