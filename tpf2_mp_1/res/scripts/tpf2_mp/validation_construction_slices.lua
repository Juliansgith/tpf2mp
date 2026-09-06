local stationModule = require "tpf2_mp/validation_station_proposal"
local depotSlicesModule = require "tpf2_mp/validation_connected_depot_slices"
local secondStationModule = require "tpf2_mp/validation_second_station_runtime"
local transportSlicesModule = require "tpf2_mp/validation_transport_slices"

local M = {}

function M.new(deps)
  local station = stationModule.new(deps)
  local depotSlices = depotSlicesModule.new(deps)
  local secondStation = secondStationModule.new(deps)
  local transport = transportSlicesModule.new(deps)
  return {
    begin = station.begin,
    beginSlice = function(name)
      if name == "connected-terminal" then station.beginConnected(); return true end
      if depotSlices.begin(name) then return true end
      if name == "second-station" then secondStation.begin(); return true end
      if transport.begin(name) then return true end
      return false
    end,
    maintain = function(stage)
      return depotSlices.maintain(stage) or secondStation.maintain(stage)
        or transport.maintain(stage)
        or station.maintain(stage)
    end,
  }
end

return M
