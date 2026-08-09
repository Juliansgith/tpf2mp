local util = require "tpf2_mp/util"
local hash = require "tpf2_mp/hash"

local M = {
  SCHEMA_VERSION = 4,
  STATION_TERMINAL_SCHEMA_VERSION = 3,
  FLAT_ALTERNATIVE_SCHEMA_VERSION = 2,
  LEGACY_SCHEMA_VERSION = 1,
  MAX_STOPS = 256,
  MAX_ALTERNATIVE_TERMINALS = 64,
  MAX_ALTERNATIVE_TERMINALS_TOTAL = 1024,
  MAX_VEHICLE_PARTS = 128,
  MAX_VEHICLE_BATCH = 256,
}

local SPECS = {
  ["line.create"] = { tag = 3, factory = "createLine", outputKind = "line" },
  ["line.delete"] = { tag = 4, factory = "deleteLine", targetKind = "line" },
  ["line.update"] = { tag = 5, factory = "updateLine", targetKind = "line" },
  ["vehicle.assign"] = { tag = 6, factory = "setLine", targetKind = "vehicle" },
  ["vehicle.reverse"] = { tag = 7, factory = "reverseVehicle", targetKind = "vehicle" },
  ["vehicle.stop"] = { tag = 8, factory = "setUserStopped", targetKind = "vehicle" },
  ["vehicle.maintenance"] = { tag = 9, factory = "setVehicleTargetMaintenanceState", targetKind = "vehicle" },
  ["vehicle.depart"] = { tag = 10, factory = "setVehicleShouldDepart", targetKind = "vehicle" },
  ["vehicle.send_to_depot"] = { tag = 11, factory = "sendToDepot", targetKind = "vehicle" },
  ["vehicle.sell"] = { tag = 12, factory = "sellVehicle", targetKind = "vehicle" },
  ["vehicle.sell_batch"] = { tag = 12, factory = "sellVehicle", targetKind = "vehicle", batch = true },
  ["vehicle.buy"] = { tag = 13, factory = "buyVehicle", outputKind = "vehicle" },
  ["vehicle.replace"] = { tag = 14, factory = "replaceVehicle", targetKind = "vehicle" },
  ["entity.color"] = { tag = 28, factory = "setColor", targetKind = "entity" },
  ["entity.name"] = { tag = 29, factory = "setName", targetKind = "entity" },
  ["vehicle.manual_departure"] = { tag = 30, factory = "setVehicleManualDeparture", targetKind = "vehicle" },
}

local function exactFields(value, names)
  if type(value) ~= "table" then return false end
  local expected = {}
  for _, name in ipairs(names) do expected[name] = true end
  for key in pairs(value) do if not expected[key] then return false end end
  for key in pairs(expected) do if value[key] == nil then return false end end
  return true
end

local function array(value, allowEmpty)
  if type(value) ~= "table" then return false, 0 end
  if next(value) == nil then return allowEmpty == true, 0 end
  return util.isArray(value)
end

local function canonicalId(value, kind)
  if type(value) ~= "string" or value == "" or #value > 240 then return false end
  if kind and value:sub(1, #kind + 1) ~= kind .. ":" then return false end
  return value:find("[%z\1-\31]") == nil
end

local function boundedString(value, maximum, allowEmpty)
  return type(value) == "string" and #value <= maximum
    and (allowEmpty == true or value ~= "") and value:find("[%z\1-\31]") == nil
end

-- BuyVehicle and ReplaceVehicle use the same typed config for every carrier.
-- Keep resource identity portable without freezing the codec to the stock
-- train/waggon folders: buses, trucks, trams, ships, aircraft, and mod-added
-- vehicle namespaces all live below vehicle/.  Repository lookup during
-- materialisation remains the final proof that a named model exists locally.
local function vehicleModelResource(value)
  return boundedString(value, 240, false)
    and value:sub(1, 8) == "vehicle/"
    and value:sub(-4) == ".mdl"
    and not value:find("..", 1, true)
    and not value:find("\\", 1, true)
end

-- The stock vehicle manager exposes its selected consist through a GUI event,
-- while the native visitor contributes the authoritative depot/target.  Keep
-- this extractor carrier-neutral: buses, trucks, trams, ships, aircraft, and
-- data-only mod vehicles use the same BuyVehicle/ReplaceVehicle command.
-- Traversal is bounded because GUI payloads are not an authored wire format.
function M.vehicleModelNames(value)
  local output, seen = {}, {}
  local budget = 2048
  local function walk(current, depth)
    if budget <= 0 then return false, "vehicle GUI payload exceeds traversal budget" end
    if depth > 16 then return false, "vehicle GUI payload exceeds nesting limit" end
    budget = budget - 1
    if type(current) == "string" then
      local normalized = current:gsub("\\", "/")
      if vehicleModelResource(normalized) then
        output[#output + 1] = normalized
        if #output > M.MAX_VEHICLE_PARTS then
          return false, "vehicle GUI payload exceeds maximum part count"
        end
      end
    elseif type(current) == "table" and not seen[current] then
      seen[current] = true
      for _, key in ipairs(util.sortedKeys(current)) do
        local ok, err = walk(current[key], depth + 1)
        if not ok then seen[current] = nil; return false, err end
      end
      seen[current] = nil
    end
    return true
  end
  local ok, err = walk(value, 0)
  if not ok then return nil, err end
  return output
end

-- Retain the old symbol for old helper scripts, but do not preserve its
-- railway-only semantics.  New call sites should use vehicleModelNames.
M.railwayModelNames = M.vehicleModelNames

local function boundedInteger(value, low, high)
  return type(value) == "number" and value == math.floor(value)
    and value >= low and value <= high
end

local function validateColor(value)
  if not exactFields(value, { "r", "g", "b" }) then return false end
  return boundedInteger(value.r, 0, 1000)
    and boundedInteger(value.g, 0, 1000)
    and boundedInteger(value.b, 0, 1000)
end

local function validateLine(value, schemaVersion)
  if not exactFields(value, { "stops" }) then return false, "line must contain only stops" end
  -- The vanilla line manager commits an empty CreateLine first and then one
  -- UpdateLine per added/removed stop.  Empty and one-stop routes are valid
  -- editor states even though they cannot yet carry a service.
  local isArray, count = array(value.stops, true)
  if not isArray or count > M.MAX_STOPS then
    return false, "line requires between 0 and " .. M.MAX_STOPS .. " stops"
  end
  local totalAlternatives = 0
  for index, stop in ipairs(value.stops) do
    local fields = schemaVersion == M.LEGACY_SCHEMA_VERSION
      and { "stationGroupCid", "station", "terminal" }
      or { "stationGroupCid", "station", "terminal", "alternativeTerminals" }
    if not exactFields(stop, fields) then
      return false, "line stop " .. index .. " has unknown or missing fields"
    end
    if not canonicalId(stop.stationGroupCid, "station_group") then
      return false, "line stop " .. index .. " has an invalid stationGroupCid"
    end
    if not boundedInteger(stop.station, 0, 4095)
      or not boundedInteger(stop.terminal, 0, 4095) then
      return false, "line stop " .. index .. " has an invalid station/terminal"
    end
    if schemaVersion ~= M.LEGACY_SCHEMA_VERSION then
      local alternatives, alternativeCount = array(stop.alternativeTerminals, true)
      local logicalCount = schemaVersion == M.FLAT_ALTERNATIVE_SCHEMA_VERSION
        and alternativeCount / 2 or alternativeCount
      if not alternatives or logicalCount ~= math.floor(logicalCount)
        or logicalCount > M.MAX_ALTERNATIVE_TERMINALS then
        return false, "line stop " .. index .. " has invalid alternative terminals"
      end
      totalAlternatives = totalAlternatives + logicalCount
      if totalAlternatives > M.MAX_ALTERNATIVE_TERMINALS_TOTAL then
        return false, "line contains too many alternative terminals"
      end
      for _, alternative in ipairs(stop.alternativeTerminals) do
        if schemaVersion == M.FLAT_ALTERNATIVE_SCHEMA_VERSION then
          if not boundedInteger(alternative, 0, 4095) then
            return false, "line stop " .. index .. " has an invalid flat alternative terminal"
          end
        elseif not exactFields(alternative, { "station", "terminal" })
          or not boundedInteger(alternative.station, 0, 4095)
          or not boundedInteger(alternative.terminal, 0, 4095) then
          return false, "line stop " .. index .. " has an invalid StationTerminal pair"
        end
      end
    end
  end
  return true
end

local function validateVehicleConfig(value)
  if not exactFields(value, { "vehicles", "vehicleGroups" }) then
    return false, "vehicle config has unknown or missing fields"
  end
  local vehiclesArray, vehicleCount = array(value.vehicles, false)
  if not vehiclesArray or vehicleCount < 1 or vehicleCount > M.MAX_VEHICLE_PARTS then
    return false, "vehicle config has an invalid part count"
  end
  for index, part in ipairs(value.vehicles) do
    if not exactFields(part, { "model", "reversed", "loadConfig", "color", "logo" }) then
      return false, "vehicle part " .. index .. " has unknown or missing fields"
    end
    if not vehicleModelResource(part.model) then
      return false, "vehicle part " .. index .. " is not a portable vehicle model resource"
    end
    if type(part.reversed) ~= "boolean" or not validateColor(part.color)
      or not boundedString(part.logo, 240, true) then
      return false, "vehicle part " .. index .. " has invalid settings"
    end
    local loadArray, loadCount = array(part.loadConfig, false)
    if not loadArray or loadCount < 1 or loadCount > 64 then
      return false, "vehicle part loadConfig must contain one entry per model compartment"
    end
    for _, selection in ipairs(part.loadConfig) do
      if not boundedInteger(selection, 0, 255) then
        return false, "vehicle loadConfig selection is invalid"
      end
    end
  end
  local groupsArray, groupCount = array(value.vehicleGroups, false)
  if not groupsArray or groupCount > vehicleCount then return false, "vehicleGroups is invalid" end
  local total = 0
  for _, group in ipairs(value.vehicleGroups) do
    if not boundedInteger(group, 1, vehicleCount) then return false, "vehicleGroups entry is invalid" end
    total = total + group
  end
  if total ~= vehicleCount then return false, "vehicleGroups does not cover every vehicle part" end
  return true
end

local function contentView(transaction)
  return {
    schemaVersion = transaction.schemaVersion,
    kind = transaction.kind,
    companyCid = transaction.companyCid,
    data = util.deepCopy(transaction.data),
  }
end

function M.validate(transaction)
  if not exactFields(transaction, {
    "schemaVersion", "kind", "companyCid", "data", "digest", "transactionId",
  }) then return false, "operation transaction has unknown or missing fields" end
  if transaction.schemaVersion ~= M.SCHEMA_VERSION
    and transaction.schemaVersion ~= M.STATION_TERMINAL_SCHEMA_VERSION
    and transaction.schemaVersion ~= M.FLAT_ALTERNATIVE_SCHEMA_VERSION
    and transaction.schemaVersion ~= M.LEGACY_SCHEMA_VERSION then
    return false, "unsupported operation schemaVersion"
  end
  local spec = SPECS[transaction.kind]
  if not spec then return false, "unsupported canonical operation kind" end
  if not canonicalId(transaction.companyCid, "company") then return false, "operation has an invalid companyCid" end
  local data = transaction.data
  if type(data) ~= "table" then return false, "operation data must be a table" end

  local kind = transaction.kind
  local ok, err = true, nil
  if kind == "line.create" then
    ok = exactFields(data, { "name", "color", "line" })
      and boundedString(data.name, 160, false) and validateColor(data.color)
    if ok then ok, err = validateLine(data.line, transaction.schemaVersion) end
  elseif kind == "line.update" then
    ok = exactFields(data, { "targetCid", "line" }) and canonicalId(data.targetCid, "line")
    if ok then ok, err = validateLine(data.line, transaction.schemaVersion) end
  elseif kind == "line.delete" then
    ok = exactFields(data, { "targetCid" }) and canonicalId(data.targetCid, "line")
  elseif kind == "vehicle.buy" then
    ok = exactFields(data, { "depotCid", "config" }) and canonicalId(data.depotCid, "depot")
    if ok then ok, err = validateVehicleConfig(data.config) end
  elseif kind == "vehicle.replace" then
    ok = exactFields(data, { "targetCid", "config" }) and canonicalId(data.targetCid, "vehicle")
    if ok then ok, err = validateVehicleConfig(data.config) end
  elseif kind == "vehicle.assign" then
    ok = exactFields(data, { "targetCid", "lineCid", "stopIndex" })
      and canonicalId(data.targetCid, "vehicle") and canonicalId(data.lineCid, "line")
      and boundedInteger(data.stopIndex, -1, M.MAX_STOPS - 1)
  elseif kind == "vehicle.stop" then
    ok = exactFields(data, { "targetCid", "stopped" })
      and canonicalId(data.targetCid, "vehicle") and type(data.stopped) == "boolean"
  elseif kind == "vehicle.send_to_depot" then
    ok = exactFields(data, { "targetCid", "sellOnArrival" })
      and canonicalId(data.targetCid, "vehicle") and type(data.sellOnArrival) == "boolean"
  elseif kind == "vehicle.maintenance" then
    ok = exactFields(data, { "targetCid", "valueBasisPoints" })
      and canonicalId(data.targetCid, "vehicle")
      and boundedInteger(data.valueBasisPoints, 0, 10000)
  elseif kind == "entity.name" then
    ok = exactFields(data, { "targetCid", "name" }) and canonicalId(data.targetCid)
      and boundedString(data.name, 160, true)
  elseif kind == "entity.color" then
    ok = exactFields(data, { "targetCid", "color" }) and canonicalId(data.targetCid)
      and validateColor(data.color)
  elseif kind == "vehicle.manual_departure" then
    ok = exactFields(data, { "targetCid", "manual" })
      and canonicalId(data.targetCid, "vehicle") and type(data.manual) == "boolean"
  elseif kind == "vehicle.reverse" or kind == "vehicle.sell" or kind == "vehicle.depart" then
    ok = exactFields(data, { "targetCid" }) and canonicalId(data.targetCid, "vehicle")
  elseif kind == "vehicle.sell_batch" then
    local targets, count = array(data.targetCids, false)
    ok = transaction.schemaVersion == M.SCHEMA_VERSION
      and exactFields(data, { "targetCids" }) and targets
      and count >= 2 and count <= M.MAX_VEHICLE_BATCH
    local previous
    for _, targetCid in ipairs(ok and data.targetCids or {}) do
      if not canonicalId(targetCid, "vehicle")
        or (previous and targetCid <= previous) then ok = false; break end
      previous = targetCid
    end
  else
    ok = false
  end
  if not ok then return false, err or ("invalid data for " .. tostring(kind)) end

  local expected = hash.value(contentView(transaction))
  if transaction.digest ~= expected then return false, "operation transaction digest mismatch" end
  if transaction.transactionId ~= "operation:" .. expected then
    return false, "operation transactionId mismatch"
  end
  return true
end

function M.make(kind, companyCid, data)
  local transaction = {
    schemaVersion = M.SCHEMA_VERSION,
    kind = tostring(kind or ""),
    companyCid = tostring(companyCid or ""),
    data = util.deepCopy(data or {}),
  }
  if transaction.kind == "vehicle.sell_batch"
    and type(transaction.data.targetCids) == "table" then
    table.sort(transaction.data.targetCids)
  end
  local line = transaction.data and transaction.data.line
  for _, stop in ipairs(type(line) == "table" and line.stops or {}) do
    if type(stop) == "table" and stop.alternativeTerminals == nil then
      stop.alternativeTerminals = {}
    end
  end
  transaction.digest = hash.value(contentView(transaction))
  transaction.transactionId = "operation:" .. transaction.digest
  local ok, err = M.validate(transaction)
  if not ok then return nil, err end
  return transaction
end

function M.spec(kind)
  return SPECS[kind] and util.deepCopy(SPECS[kind]) or nil
end

function M.defaultLine(stationGroupCids)
  local stops = {}
  for _, cid in ipairs(stationGroupCids or {}) do
    stops[#stops + 1] = {
      stationGroupCid = cid, station = 0, terminal = 0, alternativeTerminals = {},
    }
  end
  return { stops = stops }
end

local function safeField(value, key)
  local valueType = type(value)
  if valueType ~= "table" and valueType ~= "userdata" then return nil end
  local ok, nested = pcall(function() return value[key] end)
  return ok and nested or nil
end

local function vectorLength(value)
  local valueType = type(value)
  if valueType ~= "table" and valueType ~= "userdata" then return nil end
  local ok, length = pcall(function() return #value end)
  length = ok and tonumber(length) or nil
  if not length or length < 0 or length ~= math.floor(length) then return nil end
  return length
end

local function repositoryModelId(gameApi, name)
  local rep = gameApi and gameApi.res and gameApi.res.modelRep
  if not rep then return nil, "model repository is unavailable" end
  for _, method in ipairs({ "find", "getIndex" }) do
    if util.isCallable(rep[method]) then
      local ok, value = pcall(rep[method], name)
      value = ok and tonumber(value) or nil
      if value and value >= 0 then return value end
    end
  end
  return nil, "vehicle model is unavailable locally: " .. tostring(name)
end

local function modelCompartmentLayout(gameApi, name, knownModelId)
  local rep = gameApi and gameApi.res and gameApi.res.modelRep
  if not rep or not util.isCallable(rep.get) then
    return nil, "model metadata repository is unavailable"
  end
  local id, idError = knownModelId, nil
  if id == nil then id, idError = repositoryModelId(gameApi, name) end
  if id == nil then return nil, idError end
  local modelOk, model = pcall(rep.get, id)
  if not modelOk or model == nil then
    return nil, "cannot read vehicle model metadata: " .. tostring(name)
  end
  local metadata = safeField(model, "metadata")
  local transportVehicle = safeField(metadata, "transportVehicle")
  local compartments = safeField(transportVehicle, "compartments")
  local count = vectorLength(compartments)
  if not count or count < 1 or count > 64 then
    return nil, "vehicle model has no valid transport compartments: " .. tostring(name)
  end
  local layout = {}
  for index = 1, count do
    local compartment = safeField(compartments, index)
    local loadConfigs = safeField(compartment, "loadConfigs")
    local loadConfigCount = vectorLength(loadConfigs)
    if not loadConfigCount or loadConfigCount < 1 or loadConfigCount > 256 then
      return nil, "vehicle model compartment has no valid load configurations: "
        .. tostring(name) .. "#" .. tostring(index)
    end
    layout[index] = loadConfigCount
  end
  return layout, nil, id
end

function M.defaultVehicleConfig(modelNames, gameApi)
  local vehicles, groups = {}, {}
  for _, name in ipairs(modelNames or {}) do
    name = tostring(name)
    local layout, layoutError = modelCompartmentLayout(gameApi, name)
    if not layout then return nil, layoutError end
    local loadConfig = {}
    for compartment = 1, #layout do
      -- BuyVehicle on Build 35924 requires a concrete zero-based selection;
      -- passing the API-documented automatic sentinel (-1) reaches native
      -- assertions before the command can commit.  Keep automatic cargo
      -- switching enabled on TransportVehiclePart.autoLoadConfig instead.
      loadConfig[compartment] = 0
    end
    vehicles[#vehicles + 1] = {
      model = name,
      reversed = false,
      loadConfig = loadConfig,
      color = { r = 1000, g = 1000, b = 1000 },
      logo = "",
    }
    groups[#groups + 1] = 1
  end
  return { vehicles = vehicles, vehicleGroups = groups }
end

local function newType(gameApi, path)
  local value = gameApi and gameApi.type
  for part in tostring(path):gmatch("[^.]+") do
    if value == nil then break end
    local ok, nested = pcall(function() return value[part] end)
    value = ok and nested or nil
  end
  local constructor = value and value.new
  if util.isCallable(constructor) then
    local ok, result = pcall(constructor)
    if ok and result ~= nil then return result end
  end
  return {}
end

local function newStationTerminal(gameApi, station, terminal)
  local value = gameApi and gameApi.type and gameApi.type.StationTerminal
  local constructor = value and value.new
  if not util.isCallable(constructor) then
    return nil, "StationTerminal constructor is unavailable"
  end
  local errors = {}
  for attempt = 1, 2 do
    local ok, result
    if attempt == 1 then ok, result = pcall(constructor, station, terminal)
    else ok, result = pcall(constructor) end
    if ok and result ~= nil then
      local fieldsOk, fieldsError = pcall(function()
        result.station = station
        result.terminal = terminal
      end)
      if fieldsOk then return result end
      errors[#errors + 1] = tostring(fieldsError)
    else
      errors[#errors + 1] = tostring(result)
    end
  end
  return nil, "cannot construct StationTerminal userdata: " .. table.concat(errors, " | ")
end

local function vec3(gameApi, color)
  local r, g, b = color.r / 1000, color.g / 1000, color.b / 1000
  if gameApi and gameApi.type and gameApi.type.Vec3f
    and util.isCallable(gameApi.type.Vec3f.new) then
    return gameApi.type.Vec3f.new(r, g, b)
  end
  return { r, g, b }
end

local function resolve(options, cid, expectedKind)
  local value, err = options.resolveLocal(cid, expectedKind)
  value = tonumber(value)
  if not value or value < 0 then return nil, err or ("canonical object is not mapped locally: " .. cid) end
  return value
end

function M.normaliseLineStops(transaction)
  local source = transaction and transaction.data and transaction.data.line
    and transaction.data.line.stops or {}
  local result = {}
  for index, stop in ipairs(source) do
    local normalised = {
      stationGroupCid = stop.stationGroupCid,
      station = stop.station,
      terminal = stop.terminal,
      alternativeTerminals = {},
    }
    if transaction.schemaVersion == M.FLAT_ALTERNATIVE_SCHEMA_VERSION then
      for alternativeIndex = 1, #(stop.alternativeTerminals or {}), 2 do
        normalised.alternativeTerminals[#normalised.alternativeTerminals + 1] = {
          station = stop.alternativeTerminals[alternativeIndex],
          terminal = stop.alternativeTerminals[alternativeIndex + 1],
        }
      end
    elseif transaction.schemaVersion ~= M.LEGACY_SCHEMA_VERSION then
      normalised.alternativeTerminals = util.deepCopy(stop.alternativeTerminals or {})
    end
    result[index] = normalised
  end
  return result
end

local function materialiseLine(transaction, options)
  local line = newType(options.api, "Line")
  line.stops = {}
  for index, encoded in ipairs(M.normaliseLineStops(transaction)) do
    local stationGroup, err = resolve(options, encoded.stationGroupCid, "station_group")
    if not stationGroup then return nil, err end
    local stop = newType(options.api, "Line.Stop")
    stop.stationGroup = stationGroup
    stop.station = encoded.station
    stop.terminal = encoded.terminal
    -- In Build 35924 this field is exposed as a native
    -- std::vector<StationTerminal> proxy.  Assigning a populated Lua table
    -- asks sol2 to convert each owning StationTerminal userdata to the
    -- pointer userdata returned by component reads and fails at runtime.
    -- Initialising the vector empty and assigning each element through the
    -- proxy performs the intended value copy.
    stop.alternativeTerminals = {}
    for alternativeIndex, sourceAlternative in ipairs(encoded.alternativeTerminals) do
      local alternative, alternativeError = newStationTerminal(
        options.api, sourceAlternative.station, sourceAlternative.terminal)
      if not alternative then return nil, alternativeError end
      stop.alternativeTerminals[alternativeIndex] = alternative
    end
    stop.loadMode = 0
    stop.minWaitingTime = 0
    stop.maxWaitingTime = 0
    stop.waypoints = {}
    line.stops[index] = stop
  end
  return line
end

local function modelId(options, name)
  return repositoryModelId(options.api, name)
end

local function materialiseVehicleConfig(encoded, options)
  local config = newType(options.api, "TransportVehicleConfig")
  config.vehicles, config.vehicleGroups = {}, util.deepCopy(encoded.vehicleGroups)
  for index, source in ipairs(encoded.vehicles) do
    local id, err = modelId(options, source.model)
    if not id then return nil, err end
    local layout; layout, err = modelCompartmentLayout(options.api, source.model, id)
    if not layout then return nil, err end
    if #source.loadConfig ~= #layout then
      return nil, "vehicle loadConfig/model compartment mismatch: " .. tostring(source.model)
    end
    for compartment, selection in ipairs(source.loadConfig) do
      if selection < 0 or selection >= layout[compartment] then
        return nil, "vehicle loadConfig selection is unavailable in model compartment: "
          .. tostring(source.model) .. "#" .. tostring(compartment)
      end
    end
    local part = newType(options.api, "VehiclePart")
    part.modelId = id
    part.reversed = source.reversed
    -- A newly constructed VehiclePart owns an empty generated vector. Build
    -- 35924 only marshals it into BuyVehicle correctly when the complete Lua
    -- array is assigned; indexed writes are suitable for an existing,
    -- pre-sized config but leave a fresh command value unusable.
    part.loadConfig = util.deepCopy(source.loadConfig)
    part.color = vec3(options.api, source.color)
    part.logo = source.logo
    -- TransportVehicleConfig.vehicles contains TransportVehiclePart values,
    -- not bare VehiclePart values.  The latter is the immutable consist
    -- description nested in `.part`; the wrapper also carries the native
    -- purchase/maintenance/autoload state.  Build 35924 accepts zero as the
    -- purchase time for newly bought parts and fills the actual time when the
    -- BuyVehicle command commits.  Replacement uses the same public shape.
    local vehicle = newType(options.api, "TransportVehiclePart")
    vehicle.part = part
    vehicle.purchaseTime = 0
    vehicle.maintenanceState = 1
    vehicle.targetMaintenanceState = 1
    local autoLoadConfig = {}
    for compartment = 1, #source.loadConfig do
      -- Build 35924's generated type stores an automatic-selection flag per
      -- compartment separately from VehiclePart.loadConfig. Stock purchases
      -- are automatic; the public API's replacement example uses the same 1.
      autoLoadConfig[compartment] = 1
    end
    vehicle.autoLoadConfig = autoLoadConfig
    config.vehicles[index] = vehicle
  end
  return config
end

function M.materialise(transaction, options)
  local valid, validationError = M.validate(transaction)
  if not valid then return nil, validationError end
  options = options or {}
  if type(options.resolveLocal) ~= "function" then return nil, "resolveLocal callback is required" end
  local spec = SPECS[transaction.kind]
  local factory = options.factory and options.factory(spec.factory) or util.commandFactory(spec.factory)
  if not factory then return nil, "command factory is unavailable: " .. spec.factory end
  local data, args = transaction.data, nil
  if transaction.kind == "line.create" then
    local line, err = materialiseLine(transaction, options)
    if not line then return nil, err end
    local playerId = tonumber(options.nativePlayerId)
    if not playerId then return nil, "line.create requires a native player mapping" end
    args = { data.name, vec3(options.api, data.color), playerId, line }
  elseif transaction.kind == "line.update" then
    local target, err = resolve(options, data.targetCid, "line")
    if not target then return nil, err end
    local line; line, err = materialiseLine(transaction, options)
    if not line then return nil, err end
    args = { target, line }
  elseif transaction.kind == "line.delete" then
    local target, err = resolve(options, data.targetCid, "line")
    if not target then return nil, err end
    args = { target }
  elseif transaction.kind == "vehicle.buy" then
    local depot, err = resolve(options, data.depotCid, "depot")
    if not depot then return nil, err end
    local config; config, err = materialiseVehicleConfig(data.config, options)
    if not config then return nil, err end
    local playerId = tonumber(options.nativePlayerId)
    if not playerId then return nil, "vehicle.buy requires a native player mapping" end
    args = { playerId, depot, config }
  elseif transaction.kind == "vehicle.replace" then
    local target, err = resolve(options, data.targetCid, "vehicle")
    if not target then return nil, err end
    local config; config, err = materialiseVehicleConfig(data.config, options)
    if not config then return nil, err end
    args = { target, config }
  elseif transaction.kind == "vehicle.assign" then
    local target, err = resolve(options, data.targetCid, "vehicle")
    if not target then return nil, err end
    local line; line, err = resolve(options, data.lineCid, "line")
    if not line then return nil, err end
    args = { target, line, data.stopIndex }
  elseif transaction.kind == "vehicle.sell_batch" then
    local batchArgs = {}
    for _, targetCid in ipairs(data.targetCids) do
      local target, err = resolve(options, targetCid, "vehicle")
      if not target then return nil, err end
      batchArgs[#batchArgs + 1] = { target }
    end
    return {
      factory = factory,
      factoryName = spec.factory,
      tag = spec.tag,
      batchArgs = batchArgs,
      outputKind = spec.outputKind,
    }
  elseif transaction.kind == "vehicle.stop" then
    local target, err = resolve(options, data.targetCid, "vehicle")
    if not target then return nil, err end
    args = { target, data.stopped }
  elseif transaction.kind == "vehicle.send_to_depot" then
    local target, err = resolve(options, data.targetCid, "vehicle")
    if not target then return nil, err end
    args = { target, data.sellOnArrival }
  elseif transaction.kind == "vehicle.maintenance" then
    local target, err = resolve(options, data.targetCid, "vehicle")
    if not target then return nil, err end
    args = { target, data.valueBasisPoints / 10000 }
  elseif transaction.kind == "entity.name" then
    local target, err = resolve(options, data.targetCid, "entity")
    if not target then return nil, err end
    args = { target, data.name }
  elseif transaction.kind == "entity.color" then
    local target, err = resolve(options, data.targetCid, "entity")
    if not target then return nil, err end
    args = { target, vec3(options.api, data.color) }
  elseif transaction.kind == "vehicle.manual_departure" then
    local target, err = resolve(options, data.targetCid, "vehicle")
    if not target then return nil, err end
    args = { target, data.manual }
  else
    local target, err = resolve(options, data.targetCid, "vehicle")
    if not target then return nil, err end
    args = { target }
  end
  return {
    factory = factory,
    factoryName = spec.factory,
    tag = spec.tag,
    args = args,
    outputKind = spec.outputKind,
  }
end

return M
