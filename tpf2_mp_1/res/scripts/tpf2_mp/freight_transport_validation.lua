local util = require "tpf2_mp/util"
local historyModule = require "tpf2_mp/freight_transport_history"

local M = {}
local MAX_COUNT = 1000000000
local MAX_ACCUMULATOR = 1000000000000000

local function exact(value, maximum)
  return type(value) == "number" and value == math.floor(value)
    and value >= 0 and value <= maximum
end

local function cargoType(value)
  return type(value) == "string" and #value <= 128
    and value:match("^[A-Z][A-Z0-9_]*$") ~= nil
end

local function matchingOutput(industry, cargo)
  for _, output in ipairs(industry and industry.recipe and industry.recipe.outputs or {}) do
    if output.cargoType == cargo then return true end
  end
  return false
end

local function matchingInput(industry, stockIndex, cargo)
  for _, stock in ipairs(industry and industry.inputStock or {}) do
    if stock.index == stockIndex and stock.cargoType == cargo then return true end
  end
  return false
end

local function counterMap(value, label)
  if type(value) ~= "table" then return nil, label .. " is not a map" end
  local result = {}
  for key, count in pairs(value) do
    if not cargoType(key) or not exact(count, MAX_ACCUMULATOR) then
      return nil, label .. " contains an invalid cargo counter"
    end
    result[key] = count
  end
  return result
end

local function add(map, key, amount)
  map[key] = math.min(MAX_ACCUMULATOR, (map[key] or 0) + amount)
end

local function sameCounters(left, right)
  for key, value in pairs(left) do if right[key] ~= value then return false end end
  for key, value in pairs(right) do if left[key] ~= value then return false end end
  return true
end

function M.migrate(state, saved)
  local schema = saved.schemaVersion == nil and 1 or saved.schemaVersion
  if schema == 1 then return {
    transportCursors = {}, totalTransported = {}, totalDelivered = {},
    retiredTransported = {}, retiredDelivered = {}, lastTransport = nil,
  } end
  if (schema ~= 2 and schema ~= 3) or type(saved.transportCursors) ~= "table" then
    return nil, "saved freight transport schema is invalid"
  end
  local cursors, transported, delivered = {}, {}, {}
  local allowed = { contractDigest = true, sourceIndustryCid = true,
    destinationIndustryCid = true, destinationStockIndex = true,
    cargoType = true, boardedUnits = true, deliveredUnits = true,
    transportSchema = true, pathDigest = true, legIndex = true,
    legCount = true, sourceKind = true, destinationKind = true,
    sourceStationGroupCid = true, destinationStationGroupCid = true }
  local required = { "contractDigest", "sourceIndustryCid", "destinationIndustryCid",
    "destinationStockIndex", "cargoType", "boardedUnits", "deliveredUnits" }
  for _, lineCid in ipairs(util.sortedKeys(saved.transportCursors)) do
    local cursor = saved.transportCursors[lineCid]
    if type(lineCid) ~= "string" or not lineCid:match("^line:")
        or type(cursor) ~= "table" then
      return nil, "saved freight transport cursor is malformed"
    end
    for field in pairs(cursor) do
      if not allowed[field] then return nil, "saved freight transport cursor has unknown fields" end
    end
    for _, field in ipairs(required) do
      if cursor[field] == nil then return nil, "saved freight transport cursor is incomplete" end
    end
    local transportSchema = util.integer(cursor.transportSchema, 1)
    local sourceKind = transportSchema == 2 and cursor.sourceKind or "industry"
    local destinationKind = transportSchema == 2 and cursor.destinationKind or "industry"
    if transportSchema == 2 then
      for _, field in ipairs({ "pathDigest", "legIndex", "legCount",
          "sourceKind", "destinationKind", "sourceStationGroupCid",
          "destinationStationGroupCid" }) do
        if cursor[field] == nil then
          return nil, "saved freight transport cursor is incomplete"
        end
      end
    end
    local source, destination = state.industries[cursor.sourceIndustryCid],
      state.industries[cursor.destinationIndustryCid]
    if type(cursor.contractDigest) ~= "string" or #cursor.contractDigest ~= 8
        or not cursor.contractDigest:match("^[0-9a-f]+$")
        or (transportSchema ~= 1 and transportSchema ~= 2)
        or not cargoType(cursor.cargoType)
        or not exact(cursor.destinationStockIndex, 31)
        or not exact(cursor.boardedUnits, MAX_COUNT)
        or not exact(cursor.deliveredUnits, MAX_COUNT)
        or cursor.deliveredUnits > cursor.boardedUnits
        or (transportSchema == 2 and (type(cursor.pathDigest) ~= "string"
          or #cursor.pathDigest ~= 8 or not cursor.pathDigest:match("^[0-9a-f]+$")
          or not exact(cursor.legIndex, 15) or not exact(cursor.legCount, 16)
          or cursor.legCount < 1 or cursor.legIndex >= cursor.legCount
          or (sourceKind ~= "industry" and sourceKind ~= "station")
          or (destinationKind ~= "industry" and destinationKind ~= "station")
          or type(cursor.sourceStationGroupCid) ~= "string"
          or type(cursor.destinationStationGroupCid) ~= "string"))
        or (sourceKind == "industry" and not matchingOutput(source, cursor.cargoType))
        or (destinationKind == "industry" and not matchingInput(
          destination, cursor.destinationStockIndex, cursor.cargoType)) then
      return nil, "saved freight transport cursor disagrees with industry recipes"
    end
    cursors[lineCid] = util.deepCopy(cursor)
    add(transported, cursor.cargoType, cursor.boardedUnits)
    if destinationKind == "industry" then
      add(delivered, cursor.cargoType, cursor.deliveredUnits)
    end
  end
  local history, historyError = historyModule.reconcile(
    schema, saved, transported, delivered,
    { counterMap = counterMap, add = add, same = sameCounters })
  if not history then return nil, historyError end
  local savedTransported, savedDelivered =
    history.totalTransported, history.totalDelivered
  local last = saved.lastTransport
  if last ~= nil then
    if type(last) ~= "table" or not exact(last.lines, MAX_COUNT)
        or type(last.boarded) ~= "table" or type(last.delivered) ~= "table" then
      return nil, "saved last freight transport summary is malformed"
    end
    for field in pairs(last) do
      if field ~= "lines" and field ~= "boarded" and field ~= "delivered"
        and field ~= "transferred" then
        return nil, "saved last freight transport summary has unknown fields"
      end
    end
    local boarded, boardedError = counterMap(last.boarded, "saved last boarded")
    if not boarded then return nil, boardedError end
    local arrived, arrivedError = counterMap(last.delivered, "saved last delivered")
    if not arrived then return nil, arrivedError end
    local transferred, transferredError = counterMap(
      last.transferred or {}, "saved last transferred")
    if not transferred then return nil, transferredError end
    if schema >= 3 and last.lines > #util.sortedKeys(cursors) then
      return nil, "saved last freight transport line count is impossible"
    end
    local transportLimit = schema >= 3 and transported or savedTransported
    local deliveredLimit = schema >= 3 and delivered or savedDelivered
    for cargo, count in pairs(boarded) do
      if count > (transportLimit[cargo] or 0) then return nil, "saved last boarded exceeds totals" end
    end
    for cargo, count in pairs(arrived) do
      if count > (deliveredLimit[cargo] or 0) then return nil, "saved last delivered exceeds totals" end
    end
    for cargo, count in pairs(transferred) do
      if count > (transported[cargo] or 0) then
        return nil, "saved last transferred exceeds transported totals"
      end
    end
    last = { lines = last.lines, boarded = boarded, delivered = arrived, transferred = transferred }
  end
  return { transportCursors = cursors, totalTransported = savedTransported,
    totalDelivered = savedDelivered,
    retiredTransported = history.retiredTransported,
    retiredDelivered = history.retiredDelivered, lastTransport = last }
end

return M
