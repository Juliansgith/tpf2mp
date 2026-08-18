local util = require "tpf2_mp/util"

local M = {}

local MAX_COUNT = 1000000000
local MAX_ACCUMULATOR = 1000000000000000

local function exactInteger(value, low, high)
  return type(value) == "number" and value == math.floor(value)
    and value >= low and value <= high
end

local function saturatingAdd(left, right)
  left, right = math.max(0, util.integer(left, 0)), math.max(0, util.integer(right, 0))
  return math.min(MAX_ACCUMULATOR, left + right)
end

local function identity(row)
  local result = {
    contractDigest = row.contractDigest,
    sourceIndustryCid = row.sourceIndustryCid,
    destinationIndustryCid = row.destinationIndustryCid,
    destinationStockIndex = row.destinationStockIndex,
    cargoType = row.cargoType,
  }
  if util.integer(row.transportSchema, 1) == 2 then
    result.transportSchema = 2
    result.pathDigest = row.pathDigest
    result.legIndex = row.legIndex
    result.legCount = row.legCount
    result.sourceKind = row.sourceKind
    result.destinationKind = row.destinationKind
    result.sourceStationGroupCid = row.sourceStationGroupCid
    result.destinationStationGroupCid = row.destinationStationGroupCid
  end
  return result
end

local function sameIdentity(left, right)
  for key, value in pairs(identity(left)) do
    if right[key] ~= value then return false end
  end
  return true
end

local function matchingOutput(industry, cargoType)
  for _, output in ipairs(industry.recipe and industry.recipe.outputs or {}) do
    if output.cargoType == cargoType then return true end
  end
  return false
end

local function matchingInput(industry, stockIndex, cargoType)
  for _, stock in ipairs(industry.inputStock or {}) do
    if stock.index == stockIndex and stock.cargoType == cargoType then return stock end
  end
  return nil
end

local function validateRow(state, lineCid, row)
  local schema = util.integer(type(row) == "table" and row.transportSchema, 1)
  local sourceKind = schema == 2 and row.sourceKind or "industry"
  local destinationKind = schema == 2 and row.destinationKind or "industry"
  if type(lineCid) ~= "string" or not lineCid:match("^line:")
    or type(row) ~= "table" or type(row.contractDigest) ~= "string"
    or (schema ~= 1 and schema ~= 2)
    or #row.contractDigest ~= 8 or not row.contractDigest:match("^[0-9a-f]+$")
    or type(row.sourceIndustryCid) ~= "string"
    or type(row.destinationIndustryCid) ~= "string"
    or row.sourceIndustryCid == row.destinationIndustryCid
    or type(row.cargoType) ~= "string"
    or not row.cargoType:match("^[A-Z][A-Z0-9_]*$") or #row.cargoType > 128
    or not exactInteger(row.destinationStockIndex, 0, 31)
    or not exactInteger(row.boardedUnits, 0, MAX_COUNT)
    or not exactInteger(row.deliveredUnits, 0, MAX_COUNT)
    or row.deliveredUnits > row.boardedUnits
    or (schema == 2 and (type(row.pathDigest) ~= "string"
      or #row.pathDigest ~= 8 or not row.pathDigest:match("^[0-9a-f]+$")
      or not exactInteger(row.legIndex, 0, 15)
      or not exactInteger(row.legCount, 1, 16) or row.legIndex >= row.legCount
      or (sourceKind ~= "industry" and sourceKind ~= "station")
      or (destinationKind ~= "industry" and destinationKind ~= "station")
      or type(row.sourceStationGroupCid) ~= "string"
      or type(row.destinationStationGroupCid) ~= "string")) then
    return false, "freight transport row is malformed"
  end
  local source = state.industries and state.industries[row.sourceIndustryCid] or nil
  local destination = state.industries and state.industries[row.destinationIndustryCid] or nil
  if sourceKind == "industry" and (not source or not matchingOutput(source, row.cargoType)) then
    return false, "freight transport source does not produce " .. tostring(row.cargoType)
  end
  local destinationStock = destinationKind == "industry" and destination and matchingInput(
    destination, row.destinationStockIndex, row.cargoType) or nil
  if destinationKind == "industry" and not destinationStock then
    return false, "freight transport destination stock does not accept " .. tostring(row.cargoType)
  end
  local cursor = state.transportCursors[lineCid]
  local persistCursor = cursor ~= nil or row.boardedUnits > 0 or row.deliveredUnits > 0
  if cursor and not sameIdentity(row, cursor) then
    return false, "freight transport contract changed after movement"
  end
  if not cursor then
    cursor = identity(row)
    cursor.boardedUnits, cursor.deliveredUnits = 0, 0
  end
  if row.boardedUnits < cursor.boardedUnits
    or row.deliveredUnits < cursor.deliveredUnits then
    return false, "freight transport cursor moved backwards"
  end
  local boarded = row.boardedUnits - cursor.boardedUnits
  local delivered = row.deliveredUnits - cursor.deliveredUnits
  local available = sourceKind == "industry" and math.max(0, util.integer(
    source.outputStock and source.outputStock[row.cargoType], 0)) or MAX_COUNT
  if sourceKind == "industry" and boarded > available then
    return false, "freight transport withdrew more output than the source holds"
  end
  return true, {
    source = sourceKind == "industry" and source or nil,
    destinationStock = destinationStock,
    sourceKind = sourceKind, destinationKind = destinationKind,
    cursor = cursor, persistCursor = persistCursor,
    boarded = boarded, delivered = delivered,
  }
end

function M.apply(state, cargoLines)
  if type(state) ~= "table" or state.ready ~= true then
    return true, { skipped = "not-ready", lines = 0, boarded = {}, delivered = {} }
  end
  if type(cargoLines) ~= "table" then return false, "freight transport snapshot is malformed" end
  state.transportCursors = type(state.transportCursors) == "table"
    and state.transportCursors or {}
  local staged, withdrawals = {}, {}
  for _, lineCid in ipairs(util.sortedKeys(cargoLines)) do
    local ok, rowOrError = validateRow(state, lineCid, cargoLines[lineCid])
    if not ok then return false, rowOrError end
    staged[lineCid] = rowOrError
    local row = cargoLines[lineCid]
    if rowOrError.sourceKind == "industry" then
      local key = row.sourceIndustryCid .. "\0" .. row.cargoType
      local aggregate = (withdrawals[key] or 0) + rowOrError.boarded
      local available = math.max(0, util.integer(
        rowOrError.source.outputStock and rowOrError.source.outputStock[row.cargoType], 0))
      if aggregate > available then
        return false, "freight transport aggregate exceeds source output stock"
      end
      withdrawals[key] = aggregate
    end
  end
  local summary = { lines = 0, boarded = {}, delivered = {}, transferred = {} }
  for _, lineCid in ipairs(util.sortedKeys(staged)) do
    local row, item = cargoLines[lineCid], staged[lineCid]
    if item.sourceKind == "industry" then
      item.source.outputStock[row.cargoType] = math.max(0,
        util.integer(item.source.outputStock[row.cargoType], 0) - item.boarded)
    end
    if item.destinationKind == "industry" then
      item.destinationStock.amount = saturatingAdd(
        item.destinationStock.amount, item.delivered)
    end
    item.cursor.boardedUnits = row.boardedUnits
    item.cursor.deliveredUnits = row.deliveredUnits
    if item.persistCursor then state.transportCursors[lineCid] = item.cursor end
    state.totalTransported[row.cargoType] = saturatingAdd(
      state.totalTransported[row.cargoType], item.boarded)
    if item.destinationKind == "industry" then
      state.totalDelivered[row.cargoType] = saturatingAdd(
        state.totalDelivered[row.cargoType], item.delivered)
    end
    if item.persistCursor then summary.lines = summary.lines + 1 end
    summary.boarded[row.cargoType] = saturatingAdd(
      summary.boarded[row.cargoType], item.boarded)
    local target = item.destinationKind == "industry"
      and summary.delivered or summary.transferred
    target[row.cargoType] = saturatingAdd(target[row.cargoType], item.delivered)
  end
  state.lastTransport = util.deepCopy(summary)
  return true, summary
end

return M
