local canonical = require "tpf2_mp/canonical"
local util = require "tpf2_mp/util"
local world = require "tpf2_mp/world"

local M = {}

local function safeField(value, key)
  if type(value) ~= "table" and type(value) ~= "userdata" then return nil end
  local ok, result = pcall(function() return value[key] end)
  return ok and result or nil
end

local function same(left, right)
  if type(left) ~= "table" or type(right) ~= "table" then return false end
  for key, value in pairs(left) do if right[key] ~= value then return false end end
  for key, value in pairs(right) do if left[key] ~= value then return false end end
  return true
end

local function exactFields(value, expected)
  if type(value) ~= "table" then return false end
  local remaining = util.deepCopy(expected)
  for key in pairs(value) do
    if not remaining[key] then return false end
    remaining[key] = nil
  end
  return next(remaining) == nil
end

function M.project(state, record, gameApi)
  local transaction = type(record) == "table" and record.transaction or nil
  local data = type(transaction) == "table" and transaction.data or nil
  if transaction and transaction.kind ~= "vehicle.assign" then return nil end
  local targetCid = type(data) == "table" and data.targetCid or nil
  if type(state) ~= "table" or type(targetCid) ~= "string" then return nil end
  local localId = record.localRefs and record.localRefs[targetCid]
    or canonical.resolveLocal(state.canonical, targetCid)
  local componentType = gameApi and gameApi.type and gameApi.type.ComponentType
    and gameApi.type.ComponentType.TRANSPORT_VEHICLE or nil
  if not localId or not componentType or not world.entityExists(tonumber(localId)) then return nil end
  local ok, vehicle = pcall(gameApi.engine.getComponent, tonumber(localId), componentType)
  if not ok or not vehicle then return nil end
  local lineNumber = tonumber(safeField(vehicle, "line"))
  local lineCid = ""
  if lineNumber and lineNumber >= 0 then
    lineCid = canonical.resolveCanonical(state.canonical, "line", lineNumber)
    if type(lineCid) ~= "string" or lineCid == "" then return nil end
  end
  return {
    schemaVersion = 1,
    targetCid = targetCid,
    lineCid = lineCid,
    stopIndex = util.integer(tonumber(safeField(vehicle, "stopIndex")), -1),
    userStopped = safeField(vehicle, "userStopped") == true,
    sellOnArrival = safeField(vehicle, "sellOnArrival") == true,
  }
end

function M.completion(state, record, gameApi)
  local before = type(record) == "table" and record.rejectionBaseline or nil
  local after = M.project(state, record, gameApi)
  if not same(before, after) then return {} end
  return {
    schemaVersion = 1,
    kind = "vehicle.assign.rejection",
    targetCid = record.transaction.data.targetCid,
    before = util.deepCopy(before),
    after = util.deepCopy(after),
  }
end

function M.validate(state, record, proof, gameApi)
  if type(record) ~= "table" or type(record.transaction) ~= "table"
    or record.transaction.kind ~= "vehicle.assign"
    or not exactFields(proof, {
      schemaVersion = true, kind = true, targetCid = true,
      before = true, after = true,
    }) or proof.schemaVersion ~= 1 or proof.kind ~= "vehicle.assign.rejection"
    or proof.targetCid ~= record.transaction.data.targetCid then
    return false
  end
  local fields = {
    schemaVersion = true, targetCid = true, lineCid = true,
    stopIndex = true, userStopped = true, sellOnArrival = true,
  }
  if not exactFields(proof.before, fields) or not exactFields(proof.after, fields)
    or not same(proof.before, proof.after)
    or not same(proof.before, record.rejectionBaseline)
    or not same(proof.after, M.project(state, record, gameApi)) then
    return false
  end
  return true
end

-- Older fault records predate the structured before/after witness. A fresh
-- recovery checkpoint may still requalify them, but only if the native line
-- assignment still matches the authored binding metadata locally.
function M.currentMatchesAuthored(state, record, gameApi)
  local observed = M.project(state, record, gameApi)
  local targetCid = record and record.transaction and record.transaction.data
    and record.transaction.data.targetCid or nil
  local binding = targetCid and state.canonical.byCanonical[targetCid] or nil
  local authored = binding and binding.metadata and binding.metadata.lineCid or ""
  return observed ~= nil and observed.lineCid == authored
end

return M
