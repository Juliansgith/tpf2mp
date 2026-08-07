local util = require "tpf2_mp/util"

local M = {}

-- Station groups and towns are separate engine entities.  Resolve their
-- relationship through the station API instead of assuming that the engine's
-- station-to-town collection is always a plain Lua table.
function M.new(deps)
  deps = deps or {}
  local getApi = assert(deps.getApi, "getApi dependency is required")
  local entityNumber = assert(deps.entityNumber, "entityNumber dependency is required")

  local function stationGroupTown(groupId)
    local wanted = entityNumber(groupId)
    if not wanted or wanted < 0 then return nil, "invalid station-group entity" end

    local gameApi = getApi() or {}
    local engine = gameApi.engine or {}
    local systems = engine.system or {}
    local stationSystem = systems.stationSystem or {}
    local groupSystem = systems.stationGroupSystem or {}
    if not util.isCallable(groupSystem.getStationGroup) then
      return nil, "station-group lookup API is unavailable"
    end

    local found, examined, matched, townReadFailures = nil, 0, 0, 0
    local seenStations, matchedStations = {}, {}
    local function inspect(rawStationId, hintedTownId)
      if found then return end
      local stationId = entityNumber(rawStationId)
      if not stationId or stationId < 0 then return end
      if not seenStations[stationId] then
        seenStations[stationId], examined = true, examined + 1
      end
      local okGroup, rawGroup = pcall(groupSystem.getStationGroup, stationId)
      if not okGroup or entityNumber(rawGroup) ~= wanted then return end
      if not matchedStations[stationId] then
        matchedStations[stationId], matched = true, matched + 1
      end

      local townId
      if util.isCallable(stationSystem.getTown) then
        local okTown, rawTown = pcall(stationSystem.getTown, stationId)
        townId = okTown and entityNumber(rawTown) or nil
        if not okTown then townReadFailures = townReadFailures + 1 end
      end
      townId = townId or entityNumber(hintedTownId)
      if townId and townId >= 0 then found = townId end
    end

    local stationForEachOk
    if util.isCallable(stationSystem.forEach) then
      stationForEachOk = pcall(stationSystem.forEach, function(stationId)
        inspect(stationId)
      end)
      if found then return found, "stationSystem.forEach/getTown" end
    end

    local componentForEachOk
    local stationType = gameApi.type and gameApi.type.ComponentType
      and gameApi.type.ComponentType.STATION or nil
    if stationType and util.isCallable(engine.forEachEntityWithComponent) then
      componentForEachOk = pcall(engine.forEachEntityWithComponent, function(stationId)
        inspect(stationId)
      end, stationType)
      if found then return found, "station component/getTown" end
    end

    local mapType, mapEntries = "unavailable", 0
    if util.isCallable(stationSystem.getStation2TownMap) then
      local okMap, stationMap = pcall(stationSystem.getStation2TownMap)
      mapType = okMap and type(stationMap) or "error"
      if okMap and stationMap ~= nil then
        local iterated = pcall(function()
          for stationId, townId in pairs(stationMap) do
            mapEntries = mapEntries + 1
            inspect(stationId, townId)
          end
        end)
        if not iterated then mapType = mapType .. "-noniterable" end
      end
      if found then return found, "station-to-town map" end
    end

    return nil, string.format(
      "group=%d examined=%d matched=%d townReadFailures=%d stationForEach=%s componentForEach=%s map=%s/%d",
      wanted, examined, matched, townReadFailures, tostring(stationForEachOk),
      tostring(componentForEachOk), mapType, mapEntries)
  end

  return { stationGroupTown = stationGroupTown }
end

return M
