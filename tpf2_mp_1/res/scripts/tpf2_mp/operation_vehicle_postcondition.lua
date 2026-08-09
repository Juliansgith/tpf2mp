local util = require "tpf2_mp/util"
local hash = require "tpf2_mp/hash"

local M = {}

local function safeField(value, key)
  local valueType = type(value)
  if valueType ~= "table" and valueType ~= "userdata" then return nil end
  local ok, result = pcall(function() return value[key] end)
  return ok and result or nil
end

local function vectorValues(value, maximum)
  local result = {}
  local valueType = type(value)
  if valueType ~= "table" and valueType ~= "userdata" then return result end
  local lengthOk, length = pcall(function() return #value end)
  length = lengthOk and tonumber(length) or nil
  if length and length >= 0 and length == math.floor(length) then
    for index = 1, math.min(length, maximum) do
      local item = safeField(value, index)
      if item ~= nil then result[#result + 1] = item end
    end
  end
  return result
end

local function modelName(gameApi, modelId)
  local repository = gameApi and gameApi.res and gameApi.res.modelRep
  local getName = repository and repository.getName
  if not util.isCallable(getName) then return nil end
  local ok, value = pcall(getName, tonumber(modelId) or -1)
  if not ok or value == nil or tostring(value) == "" then return nil end
  return tostring(value)
end

function M.project(transportVehicle, gameApi)
  local config = safeField(transportVehicle, "transportVehicleConfig")
  local wrappers = vectorValues(safeField(config, "vehicles"), 128)
  local result = {
    vehicleParts = #wrappers,
    vehicleConfig = { vehicles = {} },
    targetMaintenanceBasisPoints = {},
    vehicleConfigKnown = config ~= nil,
    targetMaintenanceKnown = config ~= nil,
  }
  for index, wrapper in ipairs(wrappers) do
    local part = safeField(wrapper, "part") or wrapper
    local name = modelName(gameApi, safeField(part, "modelId"))
    local loadConfig = vectorValues(safeField(part, "loadConfig"), 64)
    if not name or #loadConfig < 1 then result.vehicleConfigKnown = false end
    result.vehicleConfig.vehicles[index] = {
      model = name or "<unavailable>",
      reversed = safeField(part, "reversed") == true,
      loadConfig = loadConfig,
    }
    local target = tonumber(safeField(wrapper, "targetMaintenanceState"))
    if not target or target ~= target or target < 0 or target > 1 then
      result.targetMaintenanceKnown = false
    else
      result.targetMaintenanceBasisPoints[index] = math.floor(target * 10000 + 0.5)
    end
  end
  if #wrappers < 1 then
    result.vehicleConfigKnown = false
    result.targetMaintenanceKnown = false
  end
  return result
end

local function expectedConfig(config)
  local result = { vehicles = {} }
  for index, part in ipairs(config and config.vehicles or {}) do
    result.vehicles[index] = {
      model = tostring(part.model),
      reversed = part.reversed == true,
      loadConfig = util.deepCopy(part.loadConfig),
    }
  end
  return result
end

function M.validate(transaction, observed)
  if type(transaction) ~= "table" or type(transaction.data) ~= "table"
    or type(observed) ~= "table" then
    return false, "vehicle postcondition requires a transaction and native observation"
  end
  local kind, data = transaction.kind, transaction.data
  if kind == "vehicle.buy" or kind == "vehicle.replace" then
    if observed.vehicleConfigKnown ~= true
      or type(observed.vehicleConfig) ~= "table"
      or hash.value(observed.vehicleConfig) ~= hash.value(expectedConfig(data.config)) then
      return false, "native vehicle config does not match the ordered transaction"
    end
  elseif kind == "vehicle.reverse" then
    if observed.vehicleConfigKnown ~= true or type(observed.vehicleConfig) ~= "table" then
      return false, "native reversed vehicle config is unavailable"
    end
  elseif kind == "vehicle.stop" then
    if observed.userStopped ~= data.stopped then
      return false, "native userStopped does not match the ordered transaction"
    end
  elseif kind == "vehicle.maintenance" then
    local targets = observed.targetMaintenanceBasisPoints
    if observed.targetMaintenanceKnown ~= true or type(targets) ~= "table"
      or #targets ~= tonumber(observed.vehicleParts) or #targets < 1 then
      return false, "native maintenance targets are unavailable"
    end
    for _, target in ipairs(targets) do
      if target ~= data.valueBasisPoints then
        return false, "native maintenance target does not match the ordered transaction"
      end
    end
  elseif kind == "vehicle.send_to_depot" then
    if observed.sellOnArrival ~= data.sellOnArrival then
      return false, "native sellOnArrival does not match the ordered transaction"
    end
  elseif kind == "vehicle.assign" then
    if observed.lineCid ~= data.lineCid then
      return false, "native vehicle line does not match the ordered transaction"
    end
  end
  return true
end

return M
