local stationModule = require "tpf2_mp/validation_station_proposal"
local roadDepotModule = require "tpf2_mp/validation_connected_road_depot_runtime"
local secondStationModule = require "tpf2_mp/validation_second_station_runtime"

local M = {}

function M.new(deps)
  local station = stationModule.new(deps)
  local roadDepot = roadDepotModule.new(deps)
  local secondStation = secondStationModule.new(deps)
  local tramDeps = {}
  for key, value in pairs(deps) do tramDeps[key] = value end
  tramDeps.validationKey = "connectedTramDepot"
  tramDeps.stagePrefix = "connected-tram-depot"
  tramDeps.fixtureOptions = {
    fileName = "depot/tram_depot_era_a.con",
    params = { tramCatenary = 1 },
  }
  tramDeps.afterCheckpoint = function(_, _, boundarySeq) deps.finish(boundarySeq) end
  local tramDepot = roadDepotModule.new(tramDeps)
  return {
    begin = station.begin,
    beginSlice = function(name)
      if name == "connected-terminal" then station.beginConnected(); return true end
      if name == "connected-road-depot" then roadDepot.begin(); return true end
      if name == "connected-tram-depot" then tramDepot.begin(); return true end
      if name == "second-station" then secondStation.begin(); return true end
      return false
    end,
    maintain = function(stage)
      return roadDepot.maintain(stage) or tramDepot.maintain(stage)
        or secondStation.maintain(stage) or station.maintain(stage)
    end,
  }
end

return M
