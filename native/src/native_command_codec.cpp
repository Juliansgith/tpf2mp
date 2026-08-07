#include "tpf2mp/native_command_codec.hpp"

#include "tpf2mp/build_profile.hpp"

#include <Windows.h>

#include <algorithm>
#include <array>
#include <cmath>
#include <cstdint>
#include <cstring>
#include <ostream>
#include <sstream>

namespace tpf2mp::native_command {

std::string_view CommandTypeName(const int tag) {
  static constexpr std::array<std::string_view, kCommandTypeCount> names{
      "SetGameSpeed", "SetCalendarSpeed", "UpdateLogo", "CreateLine", "DeleteLine",
      "UpdateLine", "SetLine", "Reverse", "SetUserStopped",
      "SetVehicleTargetMaintenanceState", "SetVehicleShouldDepart", "SendToDepot",
      "SellVehicle", "BuyVehicle", "ReplaceVehicle", "BuildProposal", "RemoveField",
      "CreateTowns", "RemoveTown", "DevelopTown", "SetTownInfo",
      "InstantlyUpdateTownCargoNeeds", "ConnectTownsAndIndustries",
      "SetSimBuildingManualDevelopment", "SetSimBuildingClosureTimeStamp", "ReplaceTerrain",
      "SetDate", "SaveGame", "SetColor", "SetName", "SetVehicleManualDeparture", "Book",
      "SendScriptEvent", "SetNoCosts", "SetAnimalState", "SpawnAnimal",
      "Debug_SetSimPersonState"};
  if (tag < 0 || static_cast<std::size_t>(tag) >= names.size()) return "unknown";
  return names[static_cast<std::size_t>(tag)];
}

bool IsReadableRange(const void* pointer, const std::size_t size) {
  if (pointer == nullptr || size == 0) return false;
  const auto start = reinterpret_cast<std::uintptr_t>(pointer);
  if (start > UINTPTR_MAX - size) return false;
  const auto end = start + size;
  auto cursor = start;
  while (cursor < end) {
    MEMORY_BASIC_INFORMATION information{};
    if (VirtualQuery(reinterpret_cast<const void*>(cursor), &information, sizeof(information)) == 0 ||
        information.State != MEM_COMMIT || (information.Protect & PAGE_GUARD) != 0) {
      return false;
    }
    const DWORD access = information.Protect & 0xFF;
    if (access != PAGE_READONLY && access != PAGE_READWRITE && access != PAGE_WRITECOPY &&
        access != PAGE_EXECUTE_READ && access != PAGE_EXECUTE_READWRITE &&
        access != PAGE_EXECUTE_WRITECOPY) {
      return false;
    }
    const auto region_start = reinterpret_cast<std::uintptr_t>(information.BaseAddress);
    if (region_start > UINTPTR_MAX - information.RegionSize) return false;
    const auto region_end = region_start + information.RegionSize;
    if (region_end <= cursor) return false;
    cursor = std::min(end, region_end);
  }
  return true;
}

template <typename Value>
bool ReadNativeValue(const std::uint8_t* base, const std::size_t offset, Value& output) {
  if (base == nullptr || !IsReadableRange(base + offset, sizeof(Value))) return false;
  std::memcpy(&output, base + offset, sizeof(Value));
  return true;
}

bool DecodeNativeString(const std::uint8_t* value, std::string& output) {
  // Build 35924 is linked against the x64 MSVC std::string layout: a 16-byte
  // SSO union followed by size and capacity.  Keep this exact-profile decoder
  // bounded and fail closed before dereferencing an external allocation.
  constexpr std::size_t kStringSizeOffset = 0x10;
  constexpr std::size_t kStringCapacityOffset = 0x18;
  constexpr std::size_t kSmallStringCapacity = 15;
  constexpr std::size_t kMaximumCapturedName = 160;
  std::uint64_t size = 0;
  std::uint64_t capacity = 0;
  if (!ReadNativeValue(value, kStringSizeOffset, size) ||
      !ReadNativeValue(value, kStringCapacityOffset, capacity) ||
      size > kMaximumCapturedName || capacity < size) {
    return false;
  }
  const char* characters = reinterpret_cast<const char*>(value);
  if (capacity > kSmallStringCapacity) {
    const char* external = nullptr;
    if (!ReadNativeValue(value, 0, external) ||
        (size > 0 && !IsReadableRange(external, static_cast<std::size_t>(size)))) {
      return false;
    }
    characters = external;
  } else if (size > 0 && !IsReadableRange(characters, static_cast<std::size_t>(size))) {
    return false;
  }
  if (size == 0) output.clear();
  else output.assign(characters, static_cast<std::size_t>(size));
  return output.find('\0') == std::string::npos;
}

bool DecodeAlternativeTerminals(
    const std::uint8_t* stop, std::vector<SuppressedStationTerminal>& output) {
  NativeVectorLayout layout{};
  if (!ReadNativeValue(
          stop, tpf2mp::profile::kLineStopAlternativeTerminalsOffset, layout)) {
    return false;
  }
  const auto begin = reinterpret_cast<std::uintptr_t>(layout.begin);
  const auto end = reinterpret_cast<std::uintptr_t>(layout.end);
  const auto capacity = reinterpret_cast<std::uintptr_t>(layout.capacity);
  if (begin == 0 || end == 0 || capacity == 0) {
    if (begin == 0 && end == 0 && capacity == 0) {
      output.clear();
      return true;
    }
    return false;
  }
  if (begin > end || end > capacity) return false;
  const auto used_bytes = end - begin;
  const auto capacity_bytes = capacity - begin;
  if (used_bytes % tpf2mp::profile::kStationTerminalSize != 0 ||
      capacity_bytes % tpf2mp::profile::kStationTerminalSize != 0) {
    return false;
  }
  const auto count = used_bytes / tpf2mp::profile::kStationTerminalSize;
  const auto capacity_count = capacity_bytes / tpf2mp::profile::kStationTerminalSize;
  if (count > tpf2mp::profile::kMaximumAlternativeTerminalsPerStop ||
      capacity_count > tpf2mp::profile::kMaximumAlternativeTerminalCapacity ||
      (used_bytes > 0 && !IsReadableRange(layout.begin, used_bytes))) {
    return false;
  }
  output.resize(static_cast<std::size_t>(count));
  if (used_bytes > 0) std::memcpy(output.data(), layout.begin, used_bytes);
  return std::all_of(output.begin(), output.end(), [](const SuppressedStationTerminal& value) {
    return value.station >= 0 && value.station <= 4095 &&
           value.terminal >= 0 && value.terminal <= 4095;
  });
}

bool DecodeLineStops(const std::uint8_t* line, std::vector<SuppressedLineStop>& output) {
  std::uintptr_t begin = 0;
  std::uintptr_t end = 0;
  std::uintptr_t capacity = 0;
  if (!ReadNativeValue(line, tpf2mp::profile::kLineStopsBeginOffset, begin) ||
      !ReadNativeValue(line, tpf2mp::profile::kLineStopsEndOffset, end) ||
      !ReadNativeValue(line, tpf2mp::profile::kLineStopsCapacityOffset, capacity)) {
    return false;
  }
  if (begin == 0 || end == 0 || capacity == 0) {
    if (begin == 0 && end == 0 && capacity == 0) {
      output.clear();
      return true;
    }
    return false;
  }
  if (begin > end || end > capacity) return false;
  const auto used_bytes = end - begin;
  const auto capacity_bytes = capacity - begin;
  if (used_bytes % tpf2mp::profile::kLineStopSize != 0 ||
      capacity_bytes % tpf2mp::profile::kLineStopSize != 0) {
    return false;
  }
  const auto count = used_bytes / tpf2mp::profile::kLineStopSize;
  const auto capacity_count = capacity_bytes / tpf2mp::profile::kLineStopSize;
  if (count > tpf2mp::profile::kMaximumLineStops ||
      capacity_count > tpf2mp::profile::kMaximumLineStops ||
      (used_bytes > 0 && !IsReadableRange(reinterpret_cast<const void*>(begin), used_bytes))) {
    return false;
  }
  output.clear();
  output.reserve(static_cast<std::size_t>(count));
  std::size_t alternative_count = 0;
  for (std::size_t index = 0; index < count; ++index) {
    const auto* stop = reinterpret_cast<const std::uint8_t*>(begin) +
                       index * tpf2mp::profile::kLineStopSize;
    SuppressedLineStop decoded;
    if (!ReadNativeValue(stop, tpf2mp::profile::kLineStopStationGroupOffset,
                         decoded.station_group) ||
        !ReadNativeValue(stop, tpf2mp::profile::kLineStopStationOffset,
                         decoded.station) ||
        !ReadNativeValue(stop, tpf2mp::profile::kLineStopTerminalOffset,
                         decoded.terminal) ||
        !DecodeAlternativeTerminals(stop, decoded.alternative_terminals) ||
        decoded.station_group < 0 || decoded.station < 0 || decoded.station > 4095 ||
        decoded.terminal < 0 || decoded.terminal > 4095) {
      output.clear();
      return false;
    }
    alternative_count += decoded.alternative_terminals.size();
    if (alternative_count > tpf2mp::profile::kMaximumAlternativeTerminalsTotal) {
      output.clear();
      return false;
    }
    output.push_back(decoded);
  }
  return true;
}

std::int32_t ColorBasisPoints(const float value) {
  if (!std::isfinite(value) || value < -0.001F || value > 1.001F) return -1;
  return static_cast<std::int32_t>(std::lround(std::clamp(value, 0.0F, 1.0F) * 1000.0F));
}

bool DecodeSuppressedLineCommand(const int tag, const void* command_data,
                                 SuppressedLineCommand& output) {
  const auto* data = static_cast<const std::uint8_t*>(command_data);
  output = SuppressedLineCommand{};
  output.tag = tag;
  if (tag == 3) {
    if (!IsReadableRange(data, tpf2mp::profile::kCreateLineMinimumSize) ||
        !DecodeLineStops(data + tpf2mp::profile::kCreateLineLineOffset, output.stops) ||
        !DecodeNativeString(data + tpf2mp::profile::kCreateLineNameOffset, output.name) ||
        !ReadNativeValue(data, tpf2mp::profile::kCreateLinePlayerOffset, output.player)) {
      return false;
    }
    std::array<float, 3> color{};
    if (!ReadNativeValue(data, tpf2mp::profile::kCreateLineColorOffset, color)) return false;
    for (std::size_t index = 0; index < color.size(); ++index) {
      output.color[index] = ColorBasisPoints(color[index]);
      if (output.color[index] < 0) return false;
    }
    return output.player >= 0;
  }
  if (tag == 4) {
    return IsReadableRange(data, tpf2mp::profile::kDeleteLineMinimumSize) &&
           ReadNativeValue(data, tpf2mp::profile::kDeleteLineTargetOffset, output.target) &&
           output.target >= 0;
  }
  if (tag == 5) {
    return IsReadableRange(data, tpf2mp::profile::kUpdateLineMinimumSize) &&
           ReadNativeValue(data, tpf2mp::profile::kUpdateLineTargetOffset, output.target) &&
           output.target >= 0 &&
           DecodeLineStops(data + tpf2mp::profile::kUpdateLineLineOffset, output.stops);
  }
  if (tag == 28) {
    if (!IsReadableRange(data, tpf2mp::profile::kSetColorMinimumSize) ||
        !ReadNativeValue(data, tpf2mp::profile::kSetColorTargetOffset, output.target) ||
        output.target < 0) {
      return false;
    }
    std::array<float, 3> color{};
    if (!ReadNativeValue(data, tpf2mp::profile::kSetColorValueOffset, color)) return false;
    for (std::size_t index = 0; index < color.size(); ++index) {
      output.color[index] = ColorBasisPoints(color[index]);
      if (output.color[index] < 0) return false;
    }
    return true;
  }
  if (tag == 29) {
    return IsReadableRange(data, tpf2mp::profile::kSetNameMinimumSize) &&
           ReadNativeValue(data, tpf2mp::profile::kSetNameTargetOffset, output.target) &&
           output.target >= 0 &&
           DecodeNativeString(data + tpf2mp::profile::kSetNameValueOffset, output.name);
  }
  return false;
}

std::string HexEncode(const std::string_view value) {
  static constexpr char digits[] = "0123456789abcdef";
  std::string output;
  output.reserve(value.size() * 2);
  for (const auto character : value) {
    const auto byte = static_cast<std::uint8_t>(character);
    output.push_back(digits[byte >> 4]);
    output.push_back(digits[byte & 0x0F]);
  }
  return output;
}

std::string EncodeSuppressedLineCommand(const SuppressedLineCommand& command) {
  // Delimiter protocol L3 is intentionally tiny and pointer-free. Names are
  // hex encoded; each alternative is the bounded StationTerminal pair S.T.
  std::ostringstream output;
  output << "L3|" << command.tag << '|' << command.target << '|' << command.player << '|'
         << command.color[0] << '|' << command.color[1] << '|' << command.color[2] << '|'
         << HexEncode(command.name) << '|' << command.stops.size() << '|';
  for (std::size_t index = 0; index < command.stops.size(); ++index) {
    if (index != 0) output << ';';
    const auto& stop = command.stops[index];
    output << stop.station_group << ',' << stop.station << ',' << stop.terminal << ',';
    for (std::size_t terminal_index = 0;
         terminal_index < stop.alternative_terminals.size(); ++terminal_index) {
      if (terminal_index != 0) output << ':';
      const auto& alternative = stop.alternative_terminals[terminal_index];
      output << alternative.station << '.' << alternative.terminal;
    }
  }
  return output.str();
}

bool DecodeSuppressedVehicleCommand(const int tag, const void* command_data,
                                    SuppressedVehicleCommand& output) {
  const auto* data = static_cast<const std::uint8_t*>(command_data);
  output = SuppressedVehicleCommand{};
  output.tag = tag;
  if (tag == 6) {
    return IsReadableRange(data, tpf2mp::profile::kSetLineMinimumSize) &&
           ReadNativeValue(data, tpf2mp::profile::kSetLineVehicleOffset, output.target) &&
           ReadNativeValue(data, tpf2mp::profile::kSetLineLineOffset, output.secondary) &&
           ReadNativeValue(data, tpf2mp::profile::kSetLineStopIndexOffset, output.value) &&
           output.target >= 0 && output.secondary >= 0 &&
           output.value >= tpf2mp::profile::kAutomaticLineStopIndex &&
           output.value < static_cast<std::int32_t>(tpf2mp::profile::kMaximumLineStops);
  }
  if (tag == 13) {
    return IsReadableRange(data, tpf2mp::profile::kBuyVehicleMinimumSize) &&
           ReadNativeValue(data, tpf2mp::profile::kBuyVehiclePlayerOffset, output.target) &&
           ReadNativeValue(data, tpf2mp::profile::kBuyVehicleDepotOffset, output.secondary) &&
           output.target >= 0 && output.secondary >= 0;
  }
  return false;
}

std::string EncodeSuppressedVehicleCommand(const SuppressedVehicleCommand& command) {
  // V1 contains no pointers or native object bytes, only bounded integers.
  std::ostringstream output;
  output << "V1|" << command.tag << '|' << command.target << '|'
         << command.secondary << '|' << command.value;
  return output.str();
}

int NativeCommandDataTag(const void* data) {
  if (data == nullptr) return -1;
  const auto tag_pointer = static_cast<const std::uint8_t*>(data) + kCommandTagOffset;
  if (!IsReadableRange(tag_pointer, sizeof(std::int8_t))) return -1;
  const int tag = *reinterpret_cast<const std::int8_t*>(tag_pointer);
  return tag >= 0 && static_cast<std::size_t>(tag) < kCommandTypeCount ? tag : -1;
}

int NativeCommandTag(const void* command) {
  if (!IsReadableRange(command, sizeof(void*))) return -1;
  return NativeCommandDataTag(*reinterpret_cast<void* const*>(command));
}

std::uint64_t SumTagCounts(
    const std::array<std::uint64_t, kCommandTypeCount>& counts) {
  std::uint64_t result = 0;
  for (const auto count : counts) result += count;
  return result;
}

void WriteTagCounts(std::ostream& output,
                    const std::array<std::uint64_t, kCommandTypeCount>& counts) {
  output << '[';
  bool first = true;
  for (std::size_t tag = 0; tag < counts.size(); ++tag) {
    if (counts[tag] == 0) continue;
    if (!first) output << ',';
    first = false;
    output << "{\"tag\":" << tag << ",\"name\":\"" << CommandTypeName(static_cast<int>(tag))
           << "\",\"count\":" << counts[tag] << '}';
  }
  output << ']';
}

}  // namespace tpf2mp::native_command
