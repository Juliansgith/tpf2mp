local util = require "tpf2_mp/util"

local M = {}

local function field(value, key)
  if value == nil then return nil end
  local ok, result = pcall(function() return value[key] end)
  return ok and result or nil
end

-- Engine vectors in Build 35924 appear as both ordinary Lua tables and
-- zero-/one-based userdata containers. Keep that uncertainty in this module;
-- the authored economy only receives the bounded counts produced below.
local function valuesOf(value, limit)
  local result = {}
  limit = math.max(1, tonumber(limit) or 100000)
  if type(value) == "table" then
    for _, item in pairs(value) do
      if #result >= limit then break end
      result[#result + 1] = item
    end
    return result
  end
  if type(value) ~= "userdata" then return result end

  local lengthOk, length = pcall(function() return #value end)
  length = lengthOk and tonumber(length) or nil
  if length and length >= 0 and length == math.floor(length) then
    for _, base in ipairs({ 0, 1 }) do
      for offset = 0, math.min(length, limit) - 1 do
        local ok, item = pcall(function() return value[base + offset] end)
        if ok and item ~= nil then result[#result + 1] = item end
      end
    end
  end
  if not length or length == 0 then
    local misses, found = 0, false
    for index = 0, math.min(limit, 4096) - 1 do
      local ok, item = pcall(function() return value[index] end)
      if ok and item ~= nil then
        result[#result + 1] = item
        misses, found = 0, true
      else
        misses = misses + 1
        if found and misses >= 8 then break end
      end
    end
  end
  return result
end

local function mapValue(map, wanted, entityNumber)
  if map == nil then return nil end
  for _, key in ipairs({ wanted, tostring(wanted) }) do
    local ok, value = pcall(function() return map[key] end)
    if ok and value ~= nil then return value end
  end
  if type(map) == "table" then
    for key, value in pairs(map) do
      if entityNumber(key) == wanted then return value end
    end
  else
    local found
    pcall(function()
      for key, value in pairs(map) do
        if entityNumber(key) == wanted then found = value; break end
      end
    end)
    if found ~= nil then return found end
  end
  return nil
end

-- catchmentAreaSystem returns vector<pair<EdgeId, int>>. The public binding
-- has exposed that pair as one- and zero-based containers across probes, so
-- prefer named fields and then inspect index zero before index one. This
-- avoids mistaking a zero-based pair's distance (index one) for an entity id.
local function edgeEntity(value, entityNumber)
  local direct = entityNumber(field(value, "entity"))
    or entityNumber(field(value, "entityId"))
    or entityNumber(field(value, "id"))
  if direct and direct >= 0 then return direct end
  for _, key in ipairs({ "edgeId", "edge", "first", "segment", 0, 1 }) do
    local candidate = field(value, key)
    local number = entityNumber(candidate)
    if number and number >= 0 then return number end
  end
  if type(value) == "number" and value >= 0 then return value end
  return nil
end

function M.new(deps)
  deps = deps or {}
  local getApi = assert(deps.getApi, "getApi dependency is required")
  local entityNumber = assert(deps.entityNumber, "entityNumber dependency is required")
  local sortedNumbers = assert(deps.sortedNumbers, "sortedNumbers dependency is required")

  local function access(groupId, townId)
    local wantedGroup, wantedTown = entityNumber(groupId), entityNumber(townId)
    local result = {
      schemaVersion = 1,
      ready = false,
      source = "native-street-catchment",
      stationCount = 0,
      catchmentEdgeCount = 0,
      townBuildingCount = 0,
      reachableBuildings = 0,
      errorCode = nil,
    }
    if not wantedGroup or wantedGroup < 0 or not wantedTown or wantedTown < 0 then
      result.errorCode = "invalid-station-or-town"
      return result
    end

    local gameApi = getApi() or {}
    local engine, types = gameApi.engine or {}, gameApi.type and gameApi.type.ComponentType or {}
    local systems = engine.system or {}
    local catchmentSystem = systems.catchmentAreaSystem or {}
    if not util.isCallable(catchmentSystem.getStation2edgesMap) then
      result.errorCode = "catchment-api-unavailable"
      return result
    end
    if not util.isCallable(engine.getComponent)
      or not util.isCallable(engine.forEachEntityWithComponent)
      or not types.STATION_GROUP or not types.TOWN_BUILDING or not types.PARCEL then
      result.errorCode = "catchment-components-unavailable"
      return result
    end

    local okGroup, group = pcall(engine.getComponent, wantedGroup, types.STATION_GROUP)
    if not okGroup or group == nil then
      result.errorCode = "station-group-unreadable"
      return result
    end
    local stationIds = sortedNumbers(field(group, "stations"))
    if #stationIds == 0 then
      result.errorCode = "station-group-empty"
      return result
    end
    result.stationCount = #stationIds

    local okMap, stationMap = pcall(catchmentSystem.getStation2edgesMap)
    if not okMap or stationMap == nil then
      result.errorCode = "catchment-map-unreadable"
      return result
    end
    local reachableEdges = {}
    for _, stationId in ipairs(stationIds) do
      local entries = mapValue(stationMap, stationId, entityNumber)
      for _, entry in ipairs(valuesOf(entries, 100000)) do
        local edgeId = edgeEntity(entry, entityNumber)
        if edgeId then reachableEdges[edgeId] = true end
      end
    end
    for _ in pairs(reachableEdges) do
      result.catchmentEdgeCount = result.catchmentEdgeCount + 1
    end

    local enumerationOk = pcall(engine.forEachEntityWithComponent, function(buildingId)
      local localId = entityNumber(buildingId)
      if not localId then return end
      local okBuilding, building = pcall(engine.getComponent, localId, types.TOWN_BUILDING)
      if not okBuilding or building == nil or entityNumber(field(building, "town")) ~= wantedTown then
        return
      end
      result.townBuildingCount = result.townBuildingCount + 1
      local reachable = false
      for _, parcelId in ipairs(sortedNumbers(field(building, "parcels"))) do
        local okParcel, parcel = pcall(engine.getComponent, parcelId, types.PARCEL)
        local streetSegment = okParcel and parcel and field(parcel, "streetSegment") or nil
        local edgeId = edgeEntity(streetSegment, entityNumber)
        if edgeId and reachableEdges[edgeId] then reachable = true; break end
      end
      if reachable then result.reachableBuildings = result.reachableBuildings + 1 end
    end, types.TOWN_BUILDING)
    if not enumerationOk then
      result.errorCode = "town-building-enumeration-failed"
      result.townBuildingCount = 0
      result.reachableBuildings = 0
      return result
    end

    result.ready = true
    return result
  end

  return { stationGroupPassengerAccess = access }
end

return M
