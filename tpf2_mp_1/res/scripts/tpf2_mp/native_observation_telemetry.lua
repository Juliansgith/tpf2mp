local hash = require "tpf2_mp/hash"
local util = require "tpf2_mp/util"

local M = {}
local NODE_LIMIT = 8192

local function shapeSummary(value)
  local summary = {
    tables = 0, scalars = 0, keys = 0, stringBytes = 0,
    maxDepth = 0, truncated = false,
  }
  local seen, remaining = {}, NODE_LIMIT
  local function visit(item, depth)
    if remaining <= 0 then summary.truncated = true; return end
    remaining = remaining - 1
    summary.maxDepth = math.max(summary.maxDepth, depth)
    if type(item) ~= "table" then
      summary.scalars = summary.scalars + 1
      if type(item) == "string" then summary.stringBytes = summary.stringBytes + #item end
      return
    end
    if seen[item] then return end
    seen[item] = true
    summary.tables = summary.tables + 1
    for key, nested in pairs(item) do
      summary.keys = summary.keys + 1
      if type(key) == "string" then summary.stringBytes = summary.stringBytes + #key end
      visit(nested, depth + 1)
      if remaining <= 0 then break end
    end
  end
  visit(value, 0)
  summary.nodes = NODE_LIMIT - remaining
  return summary
end

function M.compact(action)
  local shape = type(action) == "table" and action.eventShape or nil
  local result = {
    type = "native-observation",
    observation = type(action) == "table" and action.observation or nil,
    ids = util.deepCopy(type(action) == "table" and action.ids or {}),
    captureId = type(action) == "table" and action.captureId or nil,
    eventShapeDigest = hash.value(shape or {}),
    eventShapeSummary = shapeSummary(shape or {}),
    note = "full reverse-engineering envelope retained only in bounded local research",
  }
  return result
end

return M
