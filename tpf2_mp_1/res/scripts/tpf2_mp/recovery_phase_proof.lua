local util = require "tpf2_mp/util"

local M = {}

local function exactFields(value, expected)
  if type(value) ~= "table" then return false end
  for key in pairs(value) do
    if not expected[key] then return false end
  end
  for key in pairs(expected) do
    if value[key] == nil then return false end
  end
  return true
end

function M.normalise(value)
  if not exactFields(value, {
    schemaVersion = true, sampleKeys = true, vehiclePhaseDigest = true,
    vehicleRounds = true,
  }) or util.integer(value.schemaVersion, 0) ~= 1 then
    return nil, "native vehicle phase proof is malformed"
  end
  local digest = tostring(value.vehiclePhaseDigest or "")
  if #digest ~= 8 or not digest:match("^[0-9a-f]+$") then
    return nil, "native vehicle phase proof digest is invalid"
  end
  local source = value.sampleKeys
  if type(source) ~= "table" or #source ~= 2 then
    return nil, "native vehicle phase proof requires two samples"
  end
  for key in pairs(source) do
    if type(key) ~= "number" or key < 1 or key > 2 or key ~= math.floor(key) then
      return nil, "native vehicle phase proof samples are not a two-item array"
    end
  end
  local samples, seen = {}, {}
  for index = 1, 2 do
    local sample = tostring(source[index] or "")
    if #sample < 1 or #sample > 160
      or not sample:match("^[%w][%w_.:%-]*$") or seen[sample] then
      return nil, "native vehicle phase proof sample key is invalid"
    end
    seen[sample], samples[index] = true, sample
  end
  local rounds, previous = {}, ""
  if type(value.vehicleRounds) ~= "table" then
    return nil, "native vehicle phase proof rounds are malformed"
  end
  local roundCount = 0
  for key in pairs(value.vehicleRounds) do
    if type(key) ~= "number" or key < 1 or key ~= math.floor(key) then
      return nil, "native vehicle phase proof rounds are not an array"
    end
    roundCount = math.max(roundCount, key)
  end
  if roundCount > 4096 or roundCount ~= util.tableCount(value.vehicleRounds) then
    return nil, "native vehicle phase proof rounds are malformed"
  end
  for index = 1, roundCount do
    local item = value.vehicleRounds[index]
    if not exactFields(item, {
      vehicleCid = true, lineCid = true, lastAuthorizedRound = true,
    }) then return nil, "native vehicle phase proof round is malformed" end
    local vehicleCid, lineCid = item.vehicleCid, item.lineCid
    local round = item.lastAuthorizedRound
    if type(vehicleCid) ~= "string" or vehicleCid:sub(1, 8) ~= "vehicle:"
      or #vehicleCid > 160 or not vehicleCid:match("^[%w][%w_.:%-]*$")
      or vehicleCid <= previous or type(lineCid) ~= "string"
      or lineCid:sub(1, 5) ~= "line:" or #lineCid > 160
      or not lineCid:match("^[%w][%w_.:%-]*$") or type(round) ~= "number"
      or round ~= math.floor(round) or round < 0 or round > 1000000000 then
      return nil, "native vehicle phase proof round is invalid"
    end
    previous = vehicleCid
    rounds[index] = {
      vehicleCid = vehicleCid, lineCid = lineCid, lastAuthorizedRound = round,
    }
  end
  return {
    schemaVersion = 1,
    sampleKeys = samples,
    vehiclePhaseDigest = digest,
    vehicleRounds = rounds,
  }
end

return M
