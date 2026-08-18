local util = require "tpf2_mp/util"

local M = {}
local MAX_ACCUMULATOR = 1000000000000000

local function add(map, cargoType, amount)
  map[cargoType] = math.min(MAX_ACCUMULATOR,
    math.max(0, util.integer(map[cargoType], 0))
      + math.max(0, util.integer(amount, 0)))
end

function M.retireLine(state, lineCid)
  if type(state) ~= "table" or type(state.transportCursors) ~= "table" then
    return false, "freight transport state is malformed"
  end
  if type(lineCid) ~= "string" or not lineCid:match("^line:") then
    return false, "freight transport line id is invalid"
  end
  local cursor = state.transportCursors[lineCid]
  if not cursor then return true, { lineCid = lineCid, retired = false } end
  state.retiredTransported = type(state.retiredTransported) == "table"
    and state.retiredTransported or {}
  state.retiredDelivered = type(state.retiredDelivered) == "table"
    and state.retiredDelivered or {}
  add(state.retiredTransported, cursor.cargoType, cursor.boardedUnits)
  local destinationKind = util.integer(cursor.transportSchema, 1) == 2
    and cursor.destinationKind or "industry"
  if destinationKind == "industry" then
    add(state.retiredDelivered, cursor.cargoType, cursor.deliveredUnits)
  end
  state.transportCursors[lineCid] = nil
  -- The last delta described a now-retired cursor. Lifetime totals remain in
  -- the explicit history maps; do not leave an impossible active-line summary.
  state.lastTransport = nil
  return true, { lineCid = lineCid, retired = true,
    cargoType = cursor.cargoType, boardedUnits = cursor.boardedUnits,
    deliveredUnits = destinationKind == "industry" and cursor.deliveredUnits or 0 }
end

return M
