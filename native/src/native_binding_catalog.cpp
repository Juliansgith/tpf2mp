#include "tpf2mp/native_binding_catalog.hpp"

#include <algorithm>
#include <array>

namespace tpf2mp::native_binding {
namespace {

constexpr int kRegistryBase = -0x54504800;
constexpr std::array<std::string_view, 42> kBindings{
    "sendCommand", "setGameSpeed", "setCalendarSpeed", "updateLogo", "createLine",
    "deleteLine", "updateLine", "setLine", "reverseVehicle", "setUserStopped",
    "setVehicleTargetMaintenanceState", "setVehicleShouldDepart", "sendToDepot", "sellVehicle",
    "buyVehicle", "replaceVehicle", "buildProposal", "removeField", "createTowns", "removeTown",
    "developTown", "setTownInfo", "instantlyUpdateTownCargoNeeds", "connectTownsAndIndustries",
    "setSimBuildingManualDevelopment", "setSimBuildingClosureTimeStamp", "replaceTerrain", "setDate",
    "saveGame", "setColor", "setName", "setVehicleManualDeparture", "bookJournalEntry",
    "sendScriptEvent", "setNoCosts", "setAnimalState", "spawnAnimal", "debugSetSimPersonState",
    "simPersonSystem", "simPersonAtTerminalSystem", "simCargoSystem", "simCargoAtTerminalSystem"};
static_assert(kBindings.size() <= 64);

}  // namespace

int Index(const char* key) {
  if (key == nullptr) return -1;
  const auto found = std::find(kBindings.begin(), kBindings.end(), key);
  return found == kBindings.end() ? -1 : static_cast<int>(std::distance(kBindings.begin(), found));
}

bool IsInteresting(const char* key) { return Index(key) >= 0; }
int RegistrySlot(const std::size_t index) { return kRegistryBase - static_cast<int>(index); }
std::string GlobalName(const std::string_view name) {
  return "tpf2mp_native_binding_" + std::string(name);
}
std::size_t Count() { return kBindings.size(); }
std::string_view At(const std::size_t index) { return kBindings.at(index); }

}  // namespace tpf2mp::native_binding
