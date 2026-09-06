local runtimeModule = require "tpf2_mp/validation_connected_road_depot_runtime"

local M = {}

local function clone(deps)
  local result = {}
  for key, value in pairs(deps) do result[key] = value end
  return result
end

function M.new(deps)
  local road = runtimeModule.new(deps)
  local compoundDeps = clone(deps)
  compoundDeps.validationKey = "connectedCompoundRoadDepot"
  compoundDeps.stagePrefix = "connected-road-depot-compound"
  compoundDeps.fixtureOptions = { compoundTownRoad = true }
  compoundDeps.afterCheckpoint = function(_, _, boundarySeq)
    deps.finish(boundarySeq)
  end
  local compound = runtimeModule.new(compoundDeps)
  local tramDeps = clone(deps)
  tramDeps.validationKey = "connectedTramDepot"
  tramDeps.stagePrefix = "connected-tram-depot"
  tramDeps.fixtureOptions = { fileName = "depot/tram_depot_era_a.con",
    params = { tramCatenary = 1 } }
  tramDeps.afterCheckpoint = function(_, _, boundarySeq) deps.finish(boundarySeq) end
  local tram = runtimeModule.new(tramDeps)
  return {
    begin = function(name)
      if name == "connected-road-depot" then road.begin(); return true end
      if name == "connected-road-depot-compound" then compound.begin(); return true end
      if name == "connected-tram-depot" then tram.begin(); return true end
      return false
    end,
    maintain = function(stage)
      return road.maintain(stage) or compound.maintain(stage) or tram.maintain(stage)
    end,
  }
end

return M
