#pragma once

#include <array>
#include <cstddef>
#include <cstdint>
#include <string_view>

namespace tpf2mp::profile {

inline constexpr std::string_view kProfileName = "Transport Fever 2 Build 35924 (Windows x64)";
inline constexpr std::string_view kExecutableName = "TransportFever2.exe";
inline constexpr std::string_view kSha256 =
    "782b904a8f7bbdac1f7a18528f1a5c778691e5aa3087c37c351bf6912585175c";
inline constexpr std::uint32_t kPeTimestamp = 0x675ABCC6;
inline constexpr std::uint32_t kImageSize = 0x046CE000;
inline constexpr std::uint16_t kMachine = 0x8664; // IMAGE_FILE_MACHINE_AMD64

struct Signature {
  std::string_view name;
  std::uint32_t rva;
  const std::uint8_t* bytes;
  std::size_t size;
};

struct CommandVisitor {
  std::uint8_t tag;
  std::uint32_t rva;
};

inline constexpr std::uint32_t kCommandVisitorTableRva = 0x030B10C0;
inline constexpr std::size_t kCommandVisitorCount = 37;
// SetGameSpeedVisitor at RVA 0x009D57C0 loads the requested engine speed with
// `mov r8d, dword ptr [rdx]`. The visitor receives rdx as command_data.
inline constexpr std::size_t kSetGameSpeedValueOffset = 0;
inline constexpr std::int32_t kSetGameSpeedMinimum = 0;
inline constexpr std::int32_t kSetGameSpeedMaximum = 4;

// Native line-command payloads in Build 35924.  These offsets were recovered
// from the exact visitor implementations pinned below:
//
//   CreateLine -> 0x009D76A0
//   DeleteLine -> 0x009D5570
//   UpdateLine -> 0x009D9FD0
//
// CreateLine stores Line, Name, Color, PlayerOwned, and its result entity in
// that order.  UpdateLine stores the target entity followed by Line.  A Line
// begins with std::vector<Line::Stop>; the vector assignment at 0x001BB2A0
// proves the 0xA8 stop stride, while its element copy at 0x001D8140 copies the
// station-group/station/terminal tuple from the first twelve bytes.
inline constexpr std::size_t kCreateLineLineOffset = 0x00;
inline constexpr std::size_t kCreateLineNameOffset = 0x28;
inline constexpr std::size_t kCreateLineColorOffset = 0x48;
inline constexpr std::size_t kCreateLinePlayerOffset = 0x54;
inline constexpr std::size_t kCreateLineMinimumSize = 0x58;
inline constexpr std::size_t kDeleteLineTargetOffset = 0x00;
inline constexpr std::size_t kDeleteLineMinimumSize = 0x04;
inline constexpr std::size_t kUpdateLineTargetOffset = 0x00;
inline constexpr std::size_t kUpdateLineLineOffset = 0x08;
inline constexpr std::size_t kUpdateLineMinimumSize = 0x30;
// SetColor's pinned visitor at 0x009D98A0 reads the target from +0x00 and
// copies three floats beginning at +0x04. SetName's visitor at 0x009D9C40
// reads the same target and an aligned x64 MSVC std::string at +0x08.
inline constexpr std::size_t kSetColorTargetOffset = 0x00;
inline constexpr std::size_t kSetColorValueOffset = 0x04;
inline constexpr std::size_t kSetColorMinimumSize = 0x10;
inline constexpr std::size_t kSetNameTargetOffset = 0x00;
inline constexpr std::size_t kSetNameValueOffset = 0x08;
inline constexpr std::size_t kSetNameMinimumSize = 0x28;
inline constexpr std::size_t kLineStopsBeginOffset = 0x00;
inline constexpr std::size_t kLineStopsEndOffset = 0x08;
inline constexpr std::size_t kLineStopsCapacityOffset = 0x10;
inline constexpr std::size_t kLineStopSize = 0xA8;
inline constexpr std::size_t kLineStopStationGroupOffset = 0x00;
inline constexpr std::size_t kLineStopStationOffset = 0x04;
inline constexpr std::size_t kLineStopTerminalOffset = 0x08;
inline constexpr std::size_t kMaximumLineStops = 256;

// Build 35924 vehicle-command payloads recovered from the exact visitor
// implementations pinned below. SetLine's implementation at 0x009D9B10 reads
// vehicle/line/stop-index from +0/+4/+8. BuyVehicle's implementation at
// 0x009D6280 reads player/depot from +0/+4, passes the TransportVehicleConfig
// beginning at +8, and writes the created entity at +0x38. The native hook
// deliberately serializes only the scalar identity fields; the bounded
// consist is correlated with the stock vehicle-manager event in Lua. Stock
// SetLine uses -1 for "choose the initial stop automatically"; non-negative
// values select an explicit zero-based stop.
inline constexpr std::size_t kSetLineVehicleOffset = 0x00;
inline constexpr std::size_t kSetLineLineOffset = 0x04;
inline constexpr std::size_t kSetLineStopIndexOffset = 0x08;
inline constexpr std::size_t kSetLineMinimumSize = 0x0C;
inline constexpr std::int32_t kAutomaticLineStopIndex = -1;
inline constexpr std::size_t kBuyVehiclePlayerOffset = 0x00;
inline constexpr std::size_t kBuyVehicleDepotOffset = 0x04;
inline constexpr std::size_t kBuyVehicleConfigOffset = 0x08;
inline constexpr std::size_t kBuyVehicleResultOffset = 0x38;
inline constexpr std::size_t kBuyVehicleMinimumSize = 0x3C;

// These categories are consequential but do not yet have canonical payload
// codecs. Network mode therefore rejects them at their exact pre-mutation
// visitors unless a future authoritative replay consumes a one-shot token.
// BuildProposal (tag 15) retains its dedicated payload-aware visitor hook.
inline constexpr std::array<CommandVisitor, 23> kAuthorityCommandVisitors{{
    {0, 0x009D57C0},   // SetGameSpeed
    {1, 0x009D5470},   // SetCalendarSpeed
    {2, 0x009D54A0},   // UpdateLogo
    {3, 0x009D5560},   // CreateLine
    {4, 0x009D5570},   // DeleteLine
    {5, 0x009D5600},   // UpdateLine
    {6, 0x009D5610},   // SetLine
    {7, 0x009D5620},   // Reverse
    {8, 0x009D5710},   // SetUserStopped
    {9, 0x009D5720},   // SetVehicleTargetMaintenanceState
    {10, 0x009D5770},  // SetVehicleShouldDepart
    {11, 0x009D6260},  // SendToDepot
    {12, 0x009D6270},  // SellVehicle
    {13, 0x009D6280},  // BuyVehicle
    {14, 0x009D6430},  // ReplaceVehicle
    {16, 0x009D57F0},  // RemoveField
    {25, 0x009D5DD0},  // ReplaceTerrain
    {26, 0x009D5E60},  // SetDate
    {28, 0x009D5EE0},  // SetColor
    {29, 0x009D5EF0},  // SetName
    {30, 0x009D5F00},  // SetVehicleManualDeparture
    {33, 0x009D6050},  // SetNoCosts
    {36, 0x009D6250},  // Debug_SetSimPersonState
}};

inline constexpr std::array<std::uint8_t, 21> kLuaPrint{
    0x48, 0x89, 0x5C, 0x24, 0x08, 0x48, 0x89, 0x6C, 0x24, 0x18, 0x56,
    0x57, 0x41, 0x56, 0x48, 0x83, 0xEC, 0x30, 0x48, 0x8B, 0xF9};
inline constexpr std::array<std::uint8_t, 24> kLuaSetField{
    0x48, 0x89, 0x5C, 0x24, 0x08, 0x48, 0x89, 0x74, 0x24, 0x10, 0x57, 0x48,
    0x83, 0xEC, 0x20, 0x4D, 0x8B, 0xD0, 0x48, 0x8B, 0xF1, 0xE8, 0xD6, 0xEC};
inline constexpr std::array<std::uint8_t, 22> kSetupCommandInterface{
    0x40, 0x55, 0x53, 0x56, 0x57, 0x41, 0x56, 0x48, 0x8D, 0xAC, 0x24,
    0x00, 0xFE, 0xFF, 0xFF, 0x48, 0x81, 0xEC, 0x00, 0x03, 0x00, 0x00};
inline constexpr std::array<std::uint8_t, 24> kLuaPushCClosure{
    0x48, 0x89, 0x5C, 0x24, 0x08, 0x48, 0x89, 0x74, 0x24, 0x10, 0x57, 0x48,
    0x83, 0xEC, 0x20, 0x49, 0x63, 0xF8, 0x48, 0x8B, 0xF2, 0x48, 0x8B, 0xD9};
inline constexpr std::array<std::uint8_t, 24> kLuaPushValue{
    0x48, 0x83, 0xEC, 0x28, 0x4C, 0x8B, 0xD1, 0xE8, 0x74, 0xF0, 0xFF, 0xFF,
    0x4D, 0x8B, 0x42, 0x10, 0x48, 0x8B, 0x10, 0x49, 0x89, 0x10, 0x8B, 0x40};
inline constexpr std::array<std::uint8_t, 24> kLuaInsert{
    0x48, 0x83, 0xEC, 0x28, 0x4C, 0x8B, 0xD9, 0xE8, 0xE4, 0xF6, 0xFF, 0xFF,
    0x49, 0x8B, 0x53, 0x10, 0x4C, 0x8B, 0xD0, 0x48, 0x3B, 0xD0, 0x76, 0x25};
inline constexpr std::array<std::uint8_t, 24> kLuaCallK{
    0x48, 0x89, 0x5C, 0x24, 0x08, 0x57, 0x48, 0x83, 0xEC, 0x20, 0x8D, 0x42,
    0x01, 0x48, 0x8B, 0xD9, 0x48, 0x8B, 0x49, 0x10, 0x41, 0x8B, 0xF8, 0x48};
inline constexpr std::array<std::uint8_t, 24> kLuaGetTop{
    0x48, 0x8B, 0x41, 0x20, 0x48, 0x8B, 0x51, 0x10, 0x48, 0x2B, 0x10, 0x48,
    0x8D, 0x42, 0xF0, 0x48, 0xC1, 0xF8, 0x04, 0xC3, 0xCC, 0xCC, 0xCC, 0xCC};
inline constexpr std::array<std::uint8_t, 24> kLuaSetTop{
    0x85, 0xD2, 0x78, 0x34, 0x48, 0x8B, 0x41, 0x20, 0x48, 0x63, 0xD2, 0x48,
    0xFF, 0xC2, 0x48, 0xC1, 0xE2, 0x04, 0x48, 0x03, 0x10, 0x48, 0x39, 0x51};
inline constexpr std::array<std::uint8_t, 24> kLuaRawGetI{
    0x40, 0x53, 0x48, 0x83, 0xEC, 0x20, 0x45, 0x8B, 0xD0, 0x48, 0x8B, 0xD9,
    0xE8, 0x4F, 0xEF, 0xFF, 0xFF, 0x41, 0x8B, 0xD2, 0x48, 0x8B, 0x08, 0xE8};
inline constexpr std::array<std::uint8_t, 24> kLuaRawSetI{
    0x48, 0x89, 0x5C, 0x24, 0x08, 0x57, 0x48, 0x83, 0xEC, 0x20, 0x45, 0x8B,
    0xD0, 0x48, 0x8B, 0xD9, 0xE8, 0x1B, 0xEE, 0xFF, 0xFF, 0x4C, 0x8B, 0x4B};
inline constexpr std::array<std::uint8_t, 24> kLuaRawSet{
    0x48, 0x89, 0x5C, 0x24, 0x08, 0x48, 0x89, 0x74, 0x24, 0x10, 0x57, 0x48,
    0x83, 0xEC, 0x20, 0x48, 0x8B, 0xF9, 0xE8, 0xB9, 0xEE, 0xFF, 0xFF, 0x48};
inline constexpr std::array<std::uint8_t, 40> kLuaPushLString{
    0x48, 0x89, 0x5C, 0x24, 0x08, 0x48, 0x89, 0x74, 0x24, 0x10, 0x57, 0x48,
    0x83, 0xEC, 0x20, 0x48, 0x8B, 0x41, 0x18, 0x49, 0x8B, 0xF8, 0x48, 0x8B,
    0xF2, 0x48, 0x8B, 0xD9, 0x48, 0x83, 0x78, 0x18, 0x00, 0x7E, 0x05, 0xE8,
    0x18, 0xBB, 0x00, 0x00};
inline constexpr std::array<std::uint8_t, 24> kLuaToLString{
    0x48, 0x89, 0x5C, 0x24, 0x08, 0x48, 0x89, 0x74, 0x24, 0x10, 0x57, 0x48,
    0x83, 0xEC, 0x20, 0x49, 0x8B, 0xD8, 0x8B, 0xF2, 0x48, 0x8B, 0xF9, 0xE8};
inline constexpr std::array<std::uint8_t, 28> kCommandListSwap{
    0x48, 0x89, 0x7C, 0x24, 0x18, 0x41, 0x56, 0x48, 0x83, 0xEC, 0x20, 0x4C,
    0x8B, 0xF1, 0x48, 0x8B, 0xFA, 0x48, 0x8B, 0x09, 0x48, 0x3B, 0xD1, 0x0F,
    0x84, 0xA3, 0x00, 0x00};
inline constexpr std::array<std::uint8_t, 56> kApplyCommand{
    0x48, 0x8B, 0xC4, 0x55, 0x57, 0x41, 0x54, 0x41, 0x56, 0x41, 0x57, 0x48,
    0x8D, 0x68, 0xA1, 0x48, 0x81, 0xEC, 0x90, 0x00, 0x00, 0x00, 0x48, 0xC7,
    0x45, 0xC7, 0xFE, 0xFF, 0xFF, 0xFF, 0x48, 0x89, 0x58, 0x08, 0x48, 0x89,
    0x70, 0x18, 0x4C, 0x8B, 0xF2, 0x4C, 0x8B, 0xF9, 0x48, 0x8D, 0x0D, 0x65,
    0x6B, 0x6D, 0x02, 0xE8, 0x18, 0x5E, 0x69, 0xFF};
inline constexpr std::array<std::uint8_t, 16> kBuildProposalVisitorThunk{
    0xE9, 0xDB, 0x09, 0x00, 0x00, 0xCC, 0xCC, 0xCC,
    0xCC, 0xCC, 0xCC, 0xCC, 0xCC, 0xCC, 0xCC, 0xCC};

inline constexpr std::array<Signature, 16> kSignatures{{
    {"luaB_print", 0x00074F70, kLuaPrint.data(), kLuaPrint.size()},
    {"lua_setfield", 0x000721A0, kLuaSetField.data(), kLuaSetField.size()},
    {"SetupCommandInterface", 0x00D042E0, kSetupCommandInterface.data(), kSetupCommandInterface.size()},
    {"lua_pushcclosure", 0x00071B40, kLuaPushCClosure.data(), kLuaPushCClosure.size()},
    {"lua_pushvalue", 0x00071E10, kLuaPushValue.data(), kLuaPushValue.size()},
    {"lua_insert", 0x000717A0, kLuaInsert.data(), kLuaInsert.size()},
    {"lua_callk", 0x00070F50, kLuaCallK.data(), kLuaCallK.size()},
    {"lua_gettop", 0x00071690, kLuaGetTop.data(), kLuaGetTop.size()},
    {"lua_settop", 0x000723A0, kLuaSetTop.data(), kLuaSetTop.size()},
    {"lua_rawgeti", 0x00071F30, kLuaRawGetI.data(), kLuaRawGetI.size()},
    {"lua_rawseti", 0x00072060, kLuaRawSetI.data(), kLuaRawSetI.size()},
    {"lua_rawset", 0x00071FC0, kLuaRawSet.data(), kLuaRawSet.size()},
    {"lua_pushlstring", 0x00071C90, kLuaPushLString.data(), kLuaPushLString.size()},
    {"CommandList::Swap", 0x009D2CF0, kCommandListSwap.data(), kCommandListSwap.size()},
    {"ApplyCommand", 0x009DA290, kApplyCommand.data(), kApplyCommand.size()},
    {"BuildProposalVisitor", 0x009D6440, kBuildProposalVisitorThunk.data(),
     kBuildProposalVisitorThunk.size()},
}};

inline constexpr Signature kLuaToLStringSignature{
    "lua_tolstring", 0x00072620, kLuaToLString.data(), kLuaToLString.size()};

} // namespace tpf2mp::profile
