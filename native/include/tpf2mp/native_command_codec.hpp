#pragma once

#include <array>
#include <cstddef>
#include <cstdint>
#include <iosfwd>
#include <string>
#include <string_view>
#include <vector>

namespace tpf2mp::native_command {

constexpr std::size_t kCommandTypeCount = 37;
constexpr std::size_t kCommandTagOffset = 0xB18;

struct NativeVectorLayout {
  std::uint8_t* begin{};
  std::uint8_t* end{};
  std::uint8_t* capacity{};
};

struct SuppressedLineStop {
  std::int32_t station_group{-1};
  std::int32_t station{};
  std::int32_t terminal{};
};

struct SuppressedLineCommand {
  int tag{-1};
  std::int32_t target{-1};
  std::int32_t player{-1};
  std::array<std::int32_t, 3> color{};
  std::string name;
  std::vector<SuppressedLineStop> stops;
};

using TagCounts = std::array<std::uint64_t, kCommandTypeCount>;

std::string_view CommandTypeName(int tag);
bool IsReadableRange(const void* pointer, std::size_t size);
bool DecodeSuppressedLineCommand(int tag, const void* command_data,
                                 SuppressedLineCommand& output);
std::string EncodeSuppressedLineCommand(const SuppressedLineCommand& command);
int NativeCommandDataTag(const void* data);
int NativeCommandTag(const void* command);
std::uint64_t SumTagCounts(const TagCounts& counts);
void WriteTagCounts(std::ostream& output, const TagCounts& counts);

}  // namespace tpf2mp::native_command
