local util = require "tpf2_mp/util"
local M = {}

local function position(node)
  return type(node) == "table" and type(node.comp) == "table" and node.comp.position
end

local function samePosition(a, b)
  if type(a) ~= "table" or type(b) ~= "table" then return false end
  for _, axis in ipairs({ "x", "y", "z" }) do
    local x, y = tonumber(a[axis]), tonumber(b[axis])
    if not x or not y or x ~= x or y ~= y or math.abs(x - y) > .001 then return false end
  end
  return true
end

-- A factory capture is the raw input to native street cleanup, not always
-- its final graph. The same correlated apply callback exposes that processed
-- graph and its replacement lineage. Preserve it BEFORE canonicalization,
-- so authorization includes every additional removal and output slots name
-- entities that will actually exist. Never enable cleanup after ordering:
-- that can remove/renumber already-agreed output nodes.
function M.select(raw, street, values)
  local carriers = {}
  for _, edge in ipairs(raw.edgesToAdd) do carriers[edge.type] = true end
  if not (carriers[0] and carriers[1]) or #raw.edgeObjectsToAdd > 0
      or #raw.edgeObjectsToRemove > 0 then return raw end
  if type(street.new2oldSegments) ~= "table" then return raw end
  local result = { schemaVersion = 1, edgeObjectsToAdd = {}, edgeObjectsToRemove = {} }
  for target, source in pairs({ nodesToAdd = "addedNodes", edgesToAdd = "addedSegments",
      nodesToRemove = "removedNodes", edgesToRemove = "removedSegments" }) do
    result[target] = values(street[source])
    if not result[target] or #result[target] > 16384 then
      return nil, "processed transport " .. source .. " is unavailable or unbounded"
    end
  end
  if #result.edgesToAdd == 0 then return nil, "processed transport graph is empty" end
  local removed, reached, neighbours, queue = {}, {}, {}, {}
  local rawNodes, finalNodes, railDegree = {}, {}, {}
  for _, edge in ipairs(result.edgesToRemove) do
    if type(edge) ~= "table" or type(edge.entity) ~= "number" or edge.entity < 0
        or type(edge.comp) ~= "table" or type(edge.comp.node0) ~= "number"
        or type(edge.comp.node1) ~= "number" or removed[edge.entity] then
      return nil, "processed transport removal identity is invalid"
    end
    removed[edge.entity] = edge
    for _, id in ipairs({ edge.comp.node0, edge.comp.node1 }) do
      neighbours[id] = neighbours[id] or {}
      neighbours[id][#neighbours[id] + 1] = edge.entity
    end
  end
  for _, edge in ipairs(raw.edgesToRemove) do
    if not removed[edge.entity] then return nil, "processed transport omitted a native removal" end
    reached[edge.entity] = true
    queue[#queue + 1] = edge.entity
  end
  -- Cleanup may absorb neighbouring segments, but not an unrelated road.
  -- Full resource/ownership/removal validation still runs in the codec on
  -- both peers, including these newly declared existing entities.
  local cursor = 1
  while cursor <= #queue do
    local edge = removed[queue[cursor]]
    cursor = cursor + 1
    for _, node in ipairs({ edge.comp.node0, edge.comp.node1 }) do
      for _, id in ipairs(neighbours[node] or {}) do
        if not reached[id] then reached[id] = true; queue[#queue + 1] = id end
      end
      neighbours[node] = nil
    end
  end
  for id in pairs(removed) do
    if not reached[id] then return nil, "processed transport has an unrelated removal" end
  end
  for _, edge in ipairs(result.edgesToAdd) do
    if type(edge) ~= "table" or type(edge.entity) ~= "number" or edge.entity >= 0 then
      return nil, "processed transport addition identity is invalid"
    end
    if edge.type == 0 then
      local lineage = values(street.new2oldSegments[edge.entity]
        or street.new2oldSegments[tostring(edge.entity)])
      if not lineage or #lineage == 0 then return nil, "processed street has no removal lineage" end
      for _, id in ipairs(lineage) do
        if not removed[id] then return nil, "processed street lineage names an undeclared removal" end
      end
    elseif edge.type ~= 1 then return nil, "processed transport carrier is invalid" end
  end
  for _, node in ipairs(raw.nodesToAdd) do rawNodes[node.entity] = position(node) end
  for _, node in ipairs(result.nodesToAdd) do finalNodes[node.entity] = position(node) end
  for _, edge in ipairs(raw.edgesToAdd) do
    if edge.type == 1 then
      for _, id in ipairs({ edge.comp.node0, edge.comp.node1 }) do railDegree[id] = (railDegree[id] or 0) + 1 end
    end
  end
  for id, degree in pairs(railDegree) do
    if degree == 1 and rawNodes[id] and not samePosition(rawNodes[id], finalNodes[id]) then
      return nil, "processed transport changed a native rail endpoint"
    end
  end
  result.source = "correlated-processed-transport"
  return util.deepCopy(result)
end

return M
