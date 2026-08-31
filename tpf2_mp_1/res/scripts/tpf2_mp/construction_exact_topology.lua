local M = {}

local function field(value, key)
  if type(value) ~= "table" and type(value) ~= "userdata" then return nil end
  local ok, result = pcall(function() return value[key] end)
  return ok and result or nil
end

local function assign(value, key, replacement, label)
  local ok, err = pcall(function() value[key] = replacement end)
  if not ok then return nil, label .. " assignment failed: " .. tostring(err) end
  return true
end

local function length(value, label)
  local ok, result = pcall(function() return #value end)
  result = ok and tonumber(result) or nil
  if not result or result < 0 or result ~= math.floor(result) then
    return nil, label .. " length is unavailable"
  end
  return result
end

local function findVector(owner, names, label)
  for _, name in ipairs(names) do
    local value = field(owner, name)
    if value ~= nil then
      local count, countError = length(value, label)
      if count then return value, count end
      return nil, nil, countError
    end
  end
  return nil, nil, label .. " vector is unavailable"
end

local function number(value)
  local result = tonumber(value)
  return result and result == math.floor(result) and result or nil
end

local function scalar(left, right)
  if left == right then return true end
  local a, b = tonumber(left), tonumber(right)
  return a ~= nil and b ~= nil and a == b
end

local function key(value)
  return tostring(tonumber(value) or value)
end

local function freshAllocator(vectors)
  local lowest = 0
  for _, vector in ipairs(vectors) do
    local count = length(vector, "topology") or 0
    for index = 1, count do
      local entity = number(field(field(vector, index), "entity"))
      if entity and entity < lowest then lowest = entity end
    end
  end
  return function() lowest = lowest - 1; return lowest end
end

local function append(vector, count, value, label)
  local ok, err = pcall(function() vector[count + 1] = value end)
  if not ok then return nil, label .. " append failed: " .. tostring(err) end
  local after, afterError = length(vector, label)
  if not after or after ~= count + 1 then
    return nil, afterError or (label .. " append did not round-trip")
  end
  return after
end

local function trimTail(vector, count, target, label)
  for index = count, target + 1, -1 do
    local ok, err = assign(vector, index, nil, label .. " removal")
    if not ok then return nil, err end
    local after, afterError = length(vector, label)
    if not after or after ~= index - 1 then
      return nil, afterError or (label .. " removal did not round-trip")
    end
  end
  return target
end

local function remap(value, mapping)
  local replacement = mapping[key(value)]
  return replacement ~= nil and replacement or value
end

local function rewriteNode(observed, expected)
  local observedComp, expectedComp = field(observed, "comp"), field(expected, "comp")
  if observedComp == nil or expectedComp == nil then return nil, "generated node component is unavailable" end
  return assign(observedComp, "position", field(expectedComp, "position"), "generated node position")
end

local function carrierCompatible(observed, expected)
  if not scalar(field(observed, "type"), field(expected, "type")) then return false end
  local observedStreet, expectedStreet = field(observed, "streetEdge"), field(expected, "streetEdge")
  local observedTrack, expectedTrack = field(observed, "trackEdge"), field(expected, "trackEdge")
  if expectedStreet ~= nil then
    return observedStreet ~= nil and scalar(field(observedStreet, "streetType"),
      field(expectedStreet, "streetType"))
  end
  if expectedTrack ~= nil then
    return observedTrack ~= nil and scalar(field(observedTrack, "trackType"),
      field(expectedTrack, "trackType"))
      and field(observedTrack, "catenary") == field(expectedTrack, "catenary")
  end
  return observedStreet == nil and observedTrack == nil
end

local function rewriteEdge(observed, expected, nodeMap, disposableNodes)
  local observedComp, expectedComp = field(observed, "comp"), field(expected, "comp")
  if observedComp == nil or expectedComp == nil then return nil, "generated edge component is unavailable" end
  local node0 = remap(field(expectedComp, "node0"), nodeMap)
  local node1 = remap(field(expectedComp, "node1"), nodeMap)
  if not carrierCompatible(observed, expected) then
    return nil, "generated construction topology does not match the captured graph prefix"
  end
  local replacements = 0
  for _, pair in ipairs({ { "node0", node0 }, { "node1", node1 } }) do
    local observedNode = field(observedComp, pair[1])
    if not scalar(observedNode, pair[2]) then
      if not disposableNodes[key(observedNode)] or disposableNodes[key(pair[2])] then
        return nil, "generated construction topology does not match the captured graph prefix"
      end
      replacements = replacements + 1
    end
  end
  for _, item in ipairs({
      { "node0", node0 }, { "node1", node1 },
      { "tangent0", field(expectedComp, "tangent0") },
      { "tangent1", field(expectedComp, "tangent1") },
      { "type", field(expectedComp, "type") },
      { "typeIndex", field(expectedComp, "typeIndex") },
      { "objects", field(expectedComp, "objects") },
    }) do
    if item[2] ~= nil then
      local ok, err = assign(observedComp, item[1], item[2], "generated edge " .. item[1])
      if not ok then return nil, err end
    end
  end
  local expectedStreet, expectedTrack = field(expected, "streetEdge"), field(expected, "trackEdge")
  if expectedStreet then
    local ok, err = assign(field(observed, "streetEdge"), "streetType",
      field(expectedStreet, "streetType"), "generated street type")
    if not ok then return nil, err end
  elseif expectedTrack then
    for _, name in ipairs({ "trackType", "catenary" }) do
      local ok, err = assign(field(observed, "trackEdge"), name,
        field(expectedTrack, name), "generated track " .. name)
      if not ok then return nil, err end
    end
  end
  return true, nil, replacements
end

local function referencesAnyNode(edges, count, nodes)
  for index = 1, count do
    local comp = field(field(edges, index), "comp")
    if comp and (nodes[key(field(comp, "node0"))]
      or nodes[key(field(comp, "node1"))]) then return true end
  end
  return false
end

local function prepareExtraEdge(value, nodeMap, allocate)
  local comp = field(value, "comp")
  if comp == nil then return nil, "captured edge component is unavailable" end
  for _, name in ipairs({ "node0", "node1" }) do
    local ok, err = assign(comp, name, remap(field(comp, name), nodeMap), "captured edge " .. name)
    if not ok then return nil, err end
  end
  return assign(value, "entity", allocate(), "captured edge entity")
end

local function rewriteObject(observed, expected, edgeMap)
  local mappedEdge = remap(field(expected, "edgeEntity"), edgeMap)
  if not scalar(field(observed, "edgeEntity"), mappedEdge) then
    return nil, "generated edge-object topology does not match the captured graph prefix"
  end
  for _, name in ipairs({ "edgeEntity", "param", "oneWay", "left", "model", "playerEntity", "name" }) do
    local value = name == "edgeEntity" and mappedEdge or field(expected, name)
    if value ~= nil then
      local ok, err = assign(observed, name, value, "generated edge object " .. name)
      if not ok then return nil, err end
    end
  end
  return true
end

function M.applyProcessed(command, exact, safeField)
  safeField = type(safeField) == "function" and safeField or field
  local processed = safeField(command, "proposal")
  local street = processed and (safeField(processed, "proposal")
    or safeField(processed, "streetProposal")) or nil
  if street == nil or type(exact) ~= "table" then
    return nil, "processed construction topology is unavailable"
  end
  local nodes, generatedNodes, nodeError = findVector(street,
    { "addedNodes", "nodesToAdd" }, "processed nodes")
  if not nodes then return nil, nodeError end
  local edges, generatedEdges, edgeError = findVector(street,
    { "addedSegments", "edgesToAdd" }, "processed edges")
  if not edges then return nil, edgeError end
  local objects, generatedObjects, objectError = findVector(street,
    { "edgeObjectsToAdd" }, "processed edge objects")
  if not objects then return nil, objectError end
  local exactNodeCount, exactEdgeCount = #(exact.nodes or {}), #(exact.edges or {})
  local disposableNodeCount = generatedNodes - exactNodeCount
  if generatedEdges > exactEdgeCount or generatedObjects > #(exact.objects or {})
      or disposableNodeCount > 1
      or (disposableNodeCount > 0 and (exactEdgeCount == 0
        or generatedEdges ~= exactEdgeCount)) then
    return nil, "generated construction graph exceeds the captured exact graph"
  end

  local disposableNodes = {}
  for index = exactNodeCount + 1, generatedNodes do
    disposableNodes[key(field(field(nodes, index), "entity"))] = true
  end

  local allocate = freshAllocator({ nodes, edges })
  local nodeMap, nodeCount = {}, generatedNodes
  for index, expected in ipairs(exact.nodes or {}) do
    local originalEntity = field(expected, "entity")
    if index <= generatedNodes then
      local observed = field(nodes, index)
      local ok, err = rewriteNode(observed, expected)
      if not ok then return nil, err end
      nodeMap[key(originalEntity)] = field(observed, "entity")
    else
      local fresh = allocate()
      local ok, err = assign(expected, "entity", fresh, "captured node entity")
      if not ok then return nil, err end
      nodeMap[key(originalEntity)] = fresh
      nodeCount, err = append(nodes, nodeCount, expected, "processed nodes")
      if not nodeCount then return nil, err end
    end
  end

  local edgeMap, edgeCount, snapReplacements = {}, generatedEdges, 0
  for index, expected in ipairs(exact.edges or {}) do
    local originalEntity = field(expected, "entity")
    if index <= generatedEdges then
      local observed = field(edges, index)
      local ok, err, replacements = rewriteEdge(observed, expected, nodeMap, disposableNodes)
      if not ok then return nil, err end
      snapReplacements = snapReplacements + (replacements or 0)
      edgeMap[key(originalEntity)] = field(observed, "entity")
    else
      local ok, err = prepareExtraEdge(expected, nodeMap, allocate)
      if not ok then return nil, err end
      edgeMap[key(originalEntity)] = field(expected, "entity")
      edgeCount, err = append(edges, edgeCount, expected, "processed edges")
      if not edgeCount then return nil, err end
    end
  end

  if disposableNodeCount > 0 then
    if snapReplacements < 1 or referencesAnyNode(edges, edgeCount, disposableNodes) then
      return nil, "generated construction snap node could not be replaced safely"
    end
    local trimmed, trimError = trimTail(nodes, nodeCount, exactNodeCount, "processed nodes")
    if not trimmed then return nil, trimError end
    nodeCount = trimmed
  end

  local objectCount = generatedObjects
  for index, expected in ipairs(exact.objects or {}) do
    if index <= generatedObjects then
      local ok, err = rewriteObject(field(objects, index), expected, edgeMap)
      if not ok then return nil, err end
    else
      local ok, err = assign(expected, "edgeEntity",
        remap(field(expected, "edgeEntity"), edgeMap), "captured edge object reference")
      if not ok then return nil, err end
      objectCount, err = append(objects, objectCount, expected, "processed edge objects")
      if not objectCount then return nil, err end
    end
  end
  return {
    strategy = "post-expansion-exact-graph",
    generated = { nodes = generatedNodes, edges = generatedEdges, edgeObjects = generatedObjects },
    appended = { nodes = math.max(0, nodeCount - generatedNodes), edges = edgeCount - generatedEdges,
      edgeObjects = objectCount - generatedObjects },
    discarded = { nodes = disposableNodeCount },
  }
end

return M
