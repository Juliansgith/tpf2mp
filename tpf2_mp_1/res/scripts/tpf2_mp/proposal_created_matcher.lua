local M = {}

local function finite(value)
  value = tonumber(value)
  if not value or value ~= value or value == math.huge or value == -math.huge then return nil end
  return value
end

local function integer(value)
  value = finite(value)
  if not value or value ~= math.floor(value) then return nil end
  return value
end

local function squaredDistance(a, b)
  local dx, dy, dz = a.x - b.x, a.y - b.y, a.z - b.z
  return dx * dx + dy * dy + dz * dz
end

-- Match native callback/world outputs to portable slots by geometry rather
-- than creation order. Build 35924 returns an empty result-entity vector for
-- live street/track builds, so callers supply inspected before/after records.
function M.match(transaction, createdNodes, createdEdges, tolerance,
    resolveNodePosition, resolveLocal, validate)
  local valid, validationError = validate(transaction)
  if not valid then return nil, validationError end
  tolerance = finite(tolerance) or 0.35
  local limit = tolerance * tolerance
  local result = {
    nodes = {}, edges = {}, edgeObjects = {},
    unmatchedNodes = {}, unmatchedEdges = {}, unmatchedEdgeObjects = {},
  }
  local usedNodes, usedEdges = {}, {}
  for _, expected in ipairs(transaction.nodes) do
    local matches = {}
    for _, observed in ipairs(createdNodes or {}) do
      if not usedNodes[observed.localId] and type(observed.position) == "table"
        and squaredDistance(expected.position, observed.position) <= limit then
        matches[#matches + 1] = observed
      end
    end
    if #matches ~= 1 then
      return nil, "node output slot " .. expected.slot .. " did not have one geometric match"
    end
    usedNodes[matches[1].localId] = true
    result.nodes[expected.slot] = matches[1].localId
  end

  local expectedNodePositions = {}
  for _, node in ipairs(transaction.nodes) do expectedNodePositions[node.slot] = node.position end
  local function expectedPosition(reference)
    if reference.slot then return expectedNodePositions[reference.slot] end
    if reference.cid and type(resolveNodePosition) == "function" then
      local ok, position = pcall(resolveNodePosition, reference.cid)
      if ok then return position end
    end
    return nil
  end

  for _, expected in ipairs(transaction.edges) do
    local expected0 = expectedPosition(expected.node0)
    local expected1 = expectedPosition(expected.node1)
    if not expected0 or not expected1 then
      return nil, "edge output slot " .. expected.slot .. " has an unresolved endpoint position"
    end
    local matches = {}
    for _, observed in ipairs(createdEdges or {}) do
      if not usedEdges[observed.localId] and observed.carrier == expected.carrier then
        local resourceMatches = observed.resourceIndex == nil
          or tonumber(observed.resourceIndex) == tonumber(expected.resource and expected.resource.index)
        local catenaryMatches = expected.carrier ~= "track" or observed.catenary == nil
          or observed.catenary == expected.catenary
        local busMatches = expected.carrier ~= "street" or observed.bus == nil
          or observed.bus == expected.bus
        local tramMatches = expected.carrier ~= "street" or observed.tramTrackType == nil
          or tonumber(observed.tramTrackType) == tonumber(expected.tramTrackType)
        local observed0, observed1 = observed.node0Position, observed.node1Position
        local direct = observed0 and observed1
          and squaredDistance(expected0, observed0) <= limit
          and squaredDistance(expected1, observed1) <= limit
        local reversed = observed0 and observed1
          and squaredDistance(expected0, observed1) <= limit
          and squaredDistance(expected1, observed0) <= limit
        if resourceMatches and catenaryMatches and busMatches and tramMatches
          and (direct or reversed) then matches[#matches + 1] = observed end
      end
    end
    if #matches ~= 1 then
      return nil, "edge output slot " .. expected.slot .. " did not have one geometric match"
    end
    usedEdges[matches[1].localId] = true
    result.edges[expected.slot] = matches[1].localId
  end

  for _, observed in ipairs(createdNodes or {}) do
    if not usedNodes[observed.localId] then
      result.unmatchedNodes[#result.unmatchedNodes + 1] = observed.localId
    end
  end
  for _, observed in ipairs(createdEdges or {}) do
    if not usedEdges[observed.localId] then
      result.unmatchedEdges[#result.unmatchedEdges + 1] = observed.localId
    end
  end

  local usedObjects = {}
  for _, retained in ipairs(transaction.edgeObjects and transaction.edgeObjects.retain or {}) do
    local expectedEdgeId = retained.edge.slot and result.edges[retained.edge.slot] or nil
    if not expectedEdgeId then return nil, "retained edge object has an unresolved edge" end
    local retainedId
    if type(resolveLocal) == "function" then
      local ok, value = pcall(resolveLocal, retained.cid)
      if ok then retainedId = integer(value) end
    end
    if retainedId == nil then
      return nil, "retained edge object is not mapped locally: " .. tostring(retained.cid)
    end
    local found = false
    for _, candidate in ipairs(createdEdges or {}) do
      if candidate.localId == expectedEdgeId then
        for _, object in ipairs(candidate.objects or {}) do
          if integer(object.localId) == retainedId and integer(object.category) == retained.category then
            found = true
            usedObjects[retainedId] = true
            break
          end
        end
      end
      if found then break end
    end
    if not found then
      return nil, "retained edge object was not preserved on its replacement edge"
    end
  end

  for _, expected in ipairs(transaction.edgeObjects and transaction.edgeObjects.add or {}) do
    local expectedEdgeId = expected.edge.slot and result.edges[expected.edge.slot] or nil
    if not expectedEdgeId then
      return nil, "edge-object output slot " .. expected.slot .. " has an unresolved edge"
    end
    local observedEdge
    for _, candidate in ipairs(createdEdges or {}) do
      if candidate.localId == expectedEdgeId then observedEdge = candidate; break end
    end
    local matches = {}
    for _, object in ipairs(observedEdge and observedEdge.objects or {}) do
      if not usedObjects[object.localId] and integer(object.category) == expected.category then
        matches[#matches + 1] = object
      end
    end
    if #matches ~= 1 then
      return nil, "edge-object output slot " .. expected.slot .. " did not have one edge/category match"
    end
    usedObjects[matches[1].localId] = true
    result.edgeObjects[expected.slot] = matches[1].localId
  end
  for _, observed in ipairs(createdEdges or {}) do
    for _, object in ipairs(observed.objects or {}) do
      if not usedObjects[object.localId] then
        result.unmatchedEdgeObjects[#result.unmatchedEdgeObjects + 1] = object.localId
      end
    end
  end
  table.sort(result.unmatchedNodes)
  table.sort(result.unmatchedEdges)
  table.sort(result.unmatchedEdgeObjects)
  return result
end

return M
