local util = require "tpf2_mp/util"

local M = {}
local MAX_ACCUMULATOR = 1000000000000000

local function add(left, right)
  return math.min(MAX_ACCUMULATOR,
    math.max(0, util.integer(left, 0)) + math.max(0, util.integer(right, 0)))
end

function M.view(state, schemaVersion, defaultState)
  state = type(state) == "table" and state or defaultState
  local inputUnits, outputUnits = 0, 0
  for _, industry in pairs(state.industries or {}) do
    for _, stock in ipairs(industry.inputStock or {}) do
      inputUnits = add(inputUnits, stock.amount)
    end
    for _, amount in pairs(industry.outputStock or {}) do outputUnits = add(outputUnits, amount) end
  end
  return {
    schemaVersion = schemaVersion,
    ready = state.ready == true,
    contentDigest = state.contentDigest,
    bootstrapDigest = state.bootstrapDigest,
    productionEpoch = math.max(0, math.floor(tonumber(state.productionEpoch) or 0)),
    industryCount = #util.sortedKeys(state.industries or {}),
    inputUnits = inputUnits,
    outputUnits = outputUnits,
    totalProduced = util.deepCopy(state.totalProduced or {}),
    totalConsumed = util.deepCopy(state.totalConsumed or {}),
    totalTransported = util.deepCopy(state.totalTransported or {}),
    totalDelivered = util.deepCopy(state.totalDelivered or {}),
    lastTransport = util.deepCopy(state.lastTransport),
    lastAdvance = util.deepCopy(state.lastAdvance),
    migrationError = state.migrationError,
  }
end

return M
