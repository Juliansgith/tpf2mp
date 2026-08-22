local util = require "tpf2_mp/util"

local M = {}

local MAPPINGS = {
  { kind = "construction", set = "constructions" },
  { kind = "station", set = "stations" },
  { kind = "station_group", set = "stationGroups" },
  { kind = "depot", set = "depots" },
  { kind = "asset", set = "assets" },
  { kind = "edge_object", set = "edgeObjects" },
  { kind = "node", set = "nodes" },
  { kind = "edge", set = "edges" },
}

local function normaliseIds(value, limit, label)
  if type(value) ~= "table" then return nil, label .. " is not an array" end
  if #value > limit then return nil, label .. " exceeds the output limit" end
  local result, seen = {}, {}
  for index, raw in ipairs(value) do
    local id = tonumber(raw)
    if not id or id ~= math.floor(id) or id < 0 or seen[id] then
      return nil, label .. " contains an invalid entity id at " .. tostring(index)
    end
    seen[id], result[#result + 1] = true, id
  end
  table.sort(result)
  return result
end

function M.captureDescriptors(types, expanded)
  local result = {
    { name = "edges", component = types.BASE_EDGE, required = true },
    { name = "nodes", component = types.BASE_NODE, required = true },
    { name = "constructions", component = types.CONSTRUCTION, required = false },
    { name = "assets", component = types.ASSET_GROUP, required = false },
  }
  if expanded then
    result[#result + 1] = { name = "stations", component = types.STATION, required = false }
    result[#result + 1] = { name = "stationGroups", component = types.STATION_GROUP, required = false }
    result[#result + 1] = { name = "depots", component = types.VEHICLE_DEPOT, required = false }
    result[#result + 1] = { name = "edgeObjects", component = types.SIGNAL_LIST, required = false }
  end
  return result
end

function M.fromWorlds(beforeWorld, afterWorld)
  local delta = { schemaVersion = 1, added = {}, removed = {} }
  local before, after = beforeWorld.sets or {}, afterWorld.sets or {}
  for _, mapping in ipairs(MAPPINGS) do
    delta.added[mapping.kind] = util.setDifference(after[mapping.set], before[mapping.set])
    delta.removed[mapping.kind] = util.setDifference(before[mapping.set], after[mapping.set])
  end
  return delta
end

function M.encode(delta)
  local rows = { "v1" }
  for _, mapping in ipairs(MAPPINGS) do
    rows[#rows + 1] = mapping.kind .. ":"
      .. table.concat(delta.added[mapping.kind] or {}, ",") .. ":"
      .. table.concat(delta.removed[mapping.kind] or {}, ",")
  end
  return table.concat(rows, "|")
end

local function decode(value)
  local rows = {}
  for row in string.gmatch(value .. "|", "(.-)|") do rows[#rows + 1] = row end
  if rows[1] ~= "v1" or #rows ~= #MAPPINGS + 1 then return nil end
  local result = { schemaVersion = 1, added = {}, removed = {} }
  local function ids(encoded)
    local values = {}
    for id in string.gmatch(encoded, "[^,]+") do values[#values + 1] = id end
    return values
  end
  for index, mapping in ipairs(MAPPINGS) do
    local kind, added, removed = rows[index + 1]:match("^([%a_]+):([%d,]*):([%d,]*)$")
    if kind ~= mapping.kind then return nil end
    result.added[kind], result.removed[kind] = ids(added), ids(removed)
  end
  return result
end

function M.normalise(value, limit)
  if type(value) == "string" then value = decode(value) end
  if type(value) ~= "table" or value.schemaVersion ~= 1
    or type(value.added) ~= "table" or type(value.removed) ~= "table" then
    return nil, "exact construction delta attestation is missing or malformed"
  end
  limit = math.max(1, math.floor(tonumber(limit) or 1))
  local result = { schemaVersion = 1, added = {}, removed = {} }
  for _, mapping in ipairs(MAPPINGS) do
    local added, addError = normaliseIds(value.added[mapping.kind], limit,
      "added " .. mapping.kind)
    if not added then return nil, addError end
    local removed, removeError = normaliseIds(value.removed[mapping.kind], limit,
      "removed " .. mapping.kind)
    if not removed then return nil, removeError end
    local seen = {}
    for _, id in ipairs(added) do seen[id] = true end
    for _, id in ipairs(removed) do
      if seen[id] then return nil, mapping.kind .. " is both added and removed" end
    end
    result.added[mapping.kind], result.removed[mapping.kind] = added, removed
  end
  return result
end

function M.apply(before, delta)
  local after = {}
  for _, mapping in ipairs(MAPPINGS) do
    local kind, values = mapping.kind, {}
    for id in pairs(before[kind] or {}) do values[id] = true end
    for _, id in ipairs(delta.removed[kind]) do values[id] = nil end
    for _, id in ipairs(delta.added[kind]) do values[id] = true end
    after[kind] = values
  end
  return after
end

return M
