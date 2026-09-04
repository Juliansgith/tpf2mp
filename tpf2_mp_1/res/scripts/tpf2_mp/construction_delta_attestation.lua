local util = require "tpf2_mp/util"
local deltaIdentity = require "tpf2_mp/construction_delta_identity"

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
  local count = 0
  for key in pairs(value) do
    if type(key) ~= "number" or key < 1 or key ~= math.floor(key) then
      return nil, label .. " contains a non-array key"
    end
    count = count + 1
  end
  if count > limit then return nil, label .. " exceeds the output limit" end
  local result, seen = {}, {}
  for index = 1, count do
    local raw = value[index]
    if raw == nil then return nil, label .. " is sparse at " .. tostring(index) end
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
  local delta = { schemaVersion = 2, added = {}, removed = {}, identities = {} }
  local before, after = beforeWorld.sets or {}, afterWorld.sets or {}
  for _, mapping in ipairs(MAPPINGS) do
    delta.added[mapping.kind] = util.setDifference(after[mapping.set], before[mapping.set])
    delta.removed[mapping.kind] = util.setDifference(before[mapping.set], after[mapping.set])
  end
  return delta
end

-- Fresh STATION/DEPOT child components are unsafe to inspect later from the
-- engine game-script state on Build 35924. Capture their portable identity in
-- the GUI state after the native callback has settled, while the exact local
-- output delta is still known. A failed optional read does not invalidate the
-- physical result; it merely leaves that child fail-closed on future rebind.
function M.captureIdentities(delta, capture)
  return deltaIdentity.capture(delta, capture, MAPPINGS)
end

function M.encode(delta)
  local rows = { "v2" }
  for _, mapping in ipairs(MAPPINGS) do
    rows[#rows + 1] = mapping.kind .. ":"
      .. table.concat(delta.added[mapping.kind] or {}, ",") .. ":"
      .. table.concat(delta.removed[mapping.kind] or {}, ",")
  end
  deltaIdentity.appendEncoded(rows, delta, MAPPINGS)
  return table.concat(rows, "|")
end

local function decode(value)
  local rows = {}
  for row in string.gmatch(value .. "|", "(.-)|") do rows[#rows + 1] = row end
  local version = rows[1]
  if (version ~= "v1" and version ~= "v2")
      or #rows ~= (version == "v2" and #MAPPINGS * 2 + 1 or #MAPPINGS + 1) then
    return nil
  end
  local result = {
    schemaVersion = version == "v2" and 2 or 1,
    added = {}, removed = {}, identities = {},
  }
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
  if version == "v2" then
    if not deltaIdentity.decodeRows(rows, MAPPINGS, result) then return nil end
  end
  return result
end

function M.normalise(value, limit)
  if type(value) == "string" then value = decode(value) end
  if type(value) ~= "table" or (value.schemaVersion ~= 1 and value.schemaVersion ~= 2)
    or type(value.added) ~= "table" or type(value.removed) ~= "table" then
    return nil, "exact construction delta attestation is missing or malformed"
  end
  limit = math.max(1, math.floor(tonumber(limit) or 1))
  local result = {
    schemaVersion = value.schemaVersion, added = {}, removed = {}, identities = {},
  }
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
    local identities, identityError = deltaIdentity.normaliseKind(
      value.identities, mapping.kind, added)
    if not identities then return nil, identityError end
    result.identities[mapping.kind] = identities
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
