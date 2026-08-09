local M = {}

local function read(value, key)
  local ok, result = pcall(function() return value and value[key] end)
  if ok then return result end
  return nil
end

function M.new(deps)
  local getApi = assert(deps.getApi, "getApi dependency is required")
  local entityNumber = assert(deps.entityNumber, "entityNumber dependency is required")

  local function component(gameApi, id, kind)
    if not (kind and gameApi.engine and gameApi.engine.getComponent) then return nil end
    local ok, value = pcall(gameApi.engine.getComponent, id, kind)
    return ok and value or nil
  end

  local function stationIds(gameApi, groupId, group)
    local types = gameApi.type and gameApi.type.ComponentType or {}
    local result, seen = {}, {}
    local function add(raw)
      local id = entityNumber(raw)
      if id and id >= 0 and not seen[id] and component(gameApi, id, types.STATION) then
        seen[id], result[#result + 1] = true, id
      end
    end
    for _, field in ipairs({ "stations", "stationEntities" }) do
      local values = read(group, field)
      if values then pcall(function() for _, value in pairs(values) do add(value) end end) end
    end
    local systems = gameApi.engine and gameApi.engine.system or {}
    local stationSystem, groupSystem = systems.stationSystem or {}, systems.stationGroupSystem or {}
    if stationSystem.forEach and groupSystem.getStationGroup then
      pcall(stationSystem.forEach, function(stationId)
        local ok, rawGroup = pcall(groupSystem.getStationGroup, stationId)
        if ok and entityNumber(rawGroup) == groupId then add(stationId) end
      end)
    end
    table.sort(result)
    return result
  end

  local function stationCargo(gameApi, stationId)
    local types = gameApi.type and gameApi.type.ComponentType or {}
    local station = component(gameApi, stationId, types.STATION)
    local cargo = read(station, "cargo")
    if type(cargo) == "boolean" then return cargo end
    return nil
  end

  local function stopKind(gameApi, stop)
    local types = gameApi.type and gameApi.type.ComponentType or {}
    local groupId = entityNumber(read(stop, "stationGroup") or read(stop, "group"))
    if not groupId then return nil, "stop has no station group" end
    local group = component(gameApi, groupId, types.STATION_GROUP)
    if not group then return nil, "station group component is unavailable" end
    local ids = stationIds(gameApi, groupId, group)
    if #ids == 0 then return nil, "station group contains no readable stations" end

    -- Line.Stop.station is a zero-based index into StationGroup.stations on
    -- Build 35924. Preserve the component's native order when it is exposed;
    -- pure groups can still be classified safely through the fallback scan.
    local rawStations = read(group, "stations") or read(group, "stationEntities")
    local stationIndex = entityNumber(read(stop, "station"))
    if rawStations and stationIndex and stationIndex >= 0 then
      -- Lua tables produced by the engine are normally one-based even though
      -- Line.Stop.station is zero-based. Some userdata/proxy containers expose
      -- their native zero-based keys directly. Probe key zero once and choose
      -- exactly one convention; trying both can silently select the adjacent
      -- platform in a mixed station group.
      local containerIsZeroBased = read(rawStations, 0) ~= nil
      local index = containerIsZeroBased and stationIndex or (stationIndex + 1)
      local stationId = entityNumber(read(rawStations, index))
      local cargo
      if stationId then cargo = stationCargo(gameApi, stationId) end
      if cargo ~= nil then return cargo and "cargo" or "passenger", "indexed station" end
    end

    local observed
    for _, stationId in ipairs(ids) do
      local cargo = stationCargo(gameApi, stationId)
      if cargo == nil then return nil, "station cargo flag is unavailable" end
      local kind = cargo and "cargo" or "passenger"
      if observed and observed ~= kind then return nil, "station group is mixed and stop index is unreadable" end
      observed = kind
    end
    return observed, "uniform station group"
  end

  local function lineServiceKind(lineId)
    local gameApi = getApi() or {}
    local types = gameApi.type and gameApi.type.ComponentType or {}
    local line = component(gameApi, entityNumber(lineId), types.LINE)
    if not line then return nil, "line component is unavailable" end
    local stops = read(line, "stops")
    if not stops then return nil, "line stops are unavailable" end
    local observed, count, lastSource = nil, 0, nil
    local ok, failure = pcall(function()
      for _, stop in pairs(stops) do
        local kind, source = stopKind(gameApi, stop)
        if not kind then error(source) end
        count, lastSource = count + 1, source
        if observed and observed ~= kind then observed = "mixed" else observed = observed or kind end
      end
    end)
    if not ok then return nil, tostring(failure) end
    if count == 0 then return nil, "line has no readable stops" end
    return observed, lastSource
  end

  local function stationGroupKind(groupId, stationIndex)
    local gameApi = getApi() or {}
    return stopKind(gameApi, {
      stationGroup = entityNumber(groupId),
      station = entityNumber(stationIndex) or 0,
    })
  end

  return {
    lineServiceKind = lineServiceKind,
    stationGroupKind = stationGroupKind,
  }
end

return M
