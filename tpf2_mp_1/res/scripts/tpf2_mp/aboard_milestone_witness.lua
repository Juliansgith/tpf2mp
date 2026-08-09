local util = require "tpf2_mp/util"

local M = {}
local MAX_SAFE_INTEGER = 9007199254740991

local function validCid(value, prefix)
  return type(value) == "string" and #value <= 240
    and value:sub(1, #prefix + 1) == prefix .. ":"
    and not value:find("[%z\1-\31]")
end

local function exactCount(value, minimum)
  return type(value) == "number" and value == math.floor(value)
    and value >= minimum and value <= MAX_SAFE_INTEGER
end

function M.normalise(action, actionType, label)
  if type(action) ~= "table" then
    return nil, label .. " milestone must be a table"
  end
  local allowed = {
    type = true, stage = true, lineCid = true, vehicleCid = true,
    observedRound = true, boardedTotal = true, aboard = true,
  }
  for key in pairs(action) do
    if not allowed[key] then
      return nil, label .. " milestone has an unknown field: " .. tostring(key)
    end
  end
  if action.type ~= actionType or action.stage ~= "aboard"
    or not validCid(action.lineCid, "line")
    or not validCid(action.vehicleCid, "vehicle") then
    return nil, label .. " aboard milestone has invalid canonical identity"
  end
  local hasWitness = action.observedRound ~= nil or action.boardedTotal ~= nil
    or action.aboard ~= nil
  if hasWitness and (not exactCount(action.observedRound, 1)
    or not exactCount(action.aboard, 1)
    or not exactCount(action.boardedTotal, action.aboard)) then
    return nil, label .. " aboard milestone has an invalid load witness"
  end
  local result = {
    type = actionType, stage = "aboard",
    lineCid = action.lineCid, vehicleCid = action.vehicleCid,
  }
  if hasWitness then
    result.observedRound = action.observedRound
    result.boardedTotal = action.boardedTotal
    result.aboard = action.aboard
  end
  return result
end

function M.capture(vehicle)
  if not vehicle or not validCid(vehicle.lineCid, "line") then return nil end
  local witness = {
    observedRound = util.integer(vehicle.lastRound, 0),
    boardedTotal = util.integer(vehicle.boardedTotal, 0),
    aboard = util.integer(vehicle.aboard, 0),
  }
  if not exactCount(witness.observedRound, 1)
    or not exactCount(witness.aboard, 1)
    or not exactCount(witness.boardedTotal, witness.aboard) then return nil end
  return witness
end

function M.verify(action, vehicle, line, eligible)
  local currentAboard = util.integer(vehicle and vehicle.aboard, 0)
  local verified = vehicle and vehicle.lineCid == action.lineCid and line
    and eligible(vehicle, line)
  if verified and action.observedRound ~= nil then
    verified = util.integer(vehicle.lastRound, 0) >= action.observedRound
      and util.integer(vehicle.boardedTotal, 0) >= action.boardedTotal
      and util.integer(line.boardedTotal, 0) >= action.boardedTotal
  elseif verified then
    verified = currentAboard > 0
  end
  return verified == true, currentAboard
end

return M
