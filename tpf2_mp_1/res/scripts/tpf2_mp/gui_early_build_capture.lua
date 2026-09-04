local json = require "tpf2_mp/json"
local util = require "tpf2_mp/util"

local M = {}

local function integer(value)
  value = tonumber(value)
  if not value or value ~= math.floor(value) then return nil end
  return value
end

local function finite(value)
  value = tonumber(value)
  if not value or value ~= value or value == math.huge or value == -math.huge then return nil end
  return value
end

local function dense(value, maximum)
  if type(value) ~= "table" or #value > maximum then return nil end
  for index = 1, #value do if value[index] == nil then return nil end end
  return value
end

local function vec3(value)
  if type(value) ~= "table" then return nil end
  local x, y, z = finite(value[1]), finite(value[2]), finite(value[3])
  if not x or not y or not z then return nil end
  return { x = x, y = y, z = z }
end

local function validateCapture(capture)
  if type(capture) ~= "table" or integer(capture.schemaVersion) ~= 1 then
    return nil, "native factory capture schema is invalid"
  end
  local correlation = integer(capture.correlation)
  local generation = integer(capture.generation)
  if not correlation or correlation <= 0 or not generation or generation <= 0 then
    return nil, "native factory capture identity is invalid"
  end
  if capture.valid ~= true then
    return nil, "native factory decoder rejected the proposal: " .. tostring(capture.error)
  end
  for _, descriptor in ipairs({
    { "addedNodes", 16384 }, { "removedNodes", 16384 },
    { "addedEdges", 16384 }, { "removedEdges", 16384 },
    { "edgeObjectsToAdd", 4096 }, { "edgeObjectsToRemove", 4096 },
    { "constructionsToAdd", 1024 }, { "constructionsToRemove", 1024 },
    { "frozenNodeIndices", 32768 }, { "segmentTags", 16384 },
  }) do
    if not dense(capture[descriptor[1]], descriptor[2]) then
      return nil, "native factory capture " .. descriptor[1] .. " is not a bounded array"
    end
  end
  local factoryThread, addThread = integer(capture.factoryThread), integer(capture.addThread)
  if not factoryThread or factoryThread <= 0 or not addThread or addThread <= 0 then
    return nil, "native factory/Add thread correlation is invalid"
  end
  if type(capture.withCost) ~= "boolean" or type(capture.ignoreErrors) ~= "boolean" then
    return nil, "native factory command options are invalid"
  end
  for index, construction in ipairs(capture.constructionsToAdd) do
    if type(construction) ~= "table" or type(construction.fileName) ~= "string"
      or construction.fileName == "" or not dense(construction.transform, 16)
      or #construction.transform ~= 16 or not dense(construction.frozenNodes, 32768)
      or integer(construction.segmentsBefore) == nil then
      return nil, "native factory construction " .. tostring(index) .. " is invalid"
    end
    for _, value in ipairs(construction.transform) do
      if finite(value) == nil then
        return nil, "native factory construction transform is not finite"
      end
    end
  end
  return capture
end

local function node(value)
  if type(value) ~= "table" then return nil end
  local entity = integer(value.e)
  local x, y, z = finite(value.x), finite(value.y), finite(value.z)
  if not entity or not x or not y or not z then return nil end
  return {
    entity = entity,
    comp = {
      position = { x = x, y = y, z = z },
      type = integer(value.t) or 0,
      flags = integer(value.f) or 0,
    },
  }
end

local function edge(value)
  if type(value) ~= "table" then return nil end
  local entity, node0, node1 = integer(value.e), integer(value.n0), integer(value.n1)
  local tangent0, tangent1 = vec3(value.t0), vec3(value.t1)
  local carrier = integer(value.carrier)
  if not entity or not node0 or not node1 or not tangent0 or not tangent1
    or (carrier ~= 0 and carrier ~= 1) then return nil end
  local result = {
    entity = entity,
    type = carrier,
    comp = {
      node0 = node0,
      node1 = node1,
      tangent0 = tangent0,
      tangent1 = tangent1,
      type = integer(value.w28) or 0,
      typeIndex = integer(value.w2c) or (carrier == 1 and -1 or 0),
    },
  }
  local player = integer(value.player)
  local owned = integer(value.owned)
  if owned and owned ~= 0 and player and player >= 0 then
    result.playerOwned = { player = player }
  end
  if carrier == 0 then
    local streetType = integer(value.streetType)
    if not streetType or streetType < 0 then return nil end
    result.streetEdge = {
      streetType = streetType,
      bus = (integer(value.w50) or 0) % 256 ~= 0,
      tramTrackType = integer(value.tramTrackType) or 0,
    }
  else
    local trackType = integer(value.trackType)
    if not trackType or trackType < 0 then return nil end
    result.trackEdge = {
      trackType = trackType,
      catenary = (integer(value.f64) or 0) % 256 ~= 0,
    }
  end
  return result
end

local function project(values, projector, label)
  local result = {}
  for index, value in ipairs(values) do
    local projected = projector(value)
    if not projected then return nil, label .. " record " .. tostring(index) .. " is invalid" end
    result[index] = projected
  end
  return result
end

local function indexedValues(value)
  if type(value) ~= "table" then return {} end
  local indexed, maximum = {}, 0
  for key, item in pairs(value) do
    local index = integer(key)
    if index and index >= 1 then
      if indexed[index] ~= nil then return nil, "duplicate numeric index " .. tostring(index) end
      indexed[index] = item
      if index > maximum then maximum = index end
    end
  end
  local result = {}
  for index = 1, maximum do
    if indexed[index] == nil then return nil, "sparse numeric sequence at " .. tostring(index) end
    result[index] = indexed[index]
  end
  return result
end

local function semanticEntity(value)
  if integer(value) ~= nil then return integer(value) end
  if type(value) ~= "table" then return nil end
  return integer(value.entity or value.entityId or value.id or value.localId)
end

local function normalResourceName(value)
  if type(value) ~= "string" then return nil end
  return string.lower((value:gsub("\\", "/")))
end

local function streetProposal(snapshot)
  if type(snapshot.streetProposal) == "table" then return snapshot.streetProposal end
  if type(snapshot.proposal) == "table" then
    if type(snapshot.proposal.streetProposal) == "table" then
      return snapshot.proposal.streetProposal
    end
    return snapshot.proposal
  end
  return snapshot
end

local function constructionAdditions(snapshot)
  local values = indexedValues(snapshot.__constructionAdditions)
  if values and #values > 0 then return values, "__constructionAdditions" end
  values = indexedValues(snapshot.constructionsToAdd or snapshot.toAdd)
  return values, "constructionsToAdd"
end

local function constructionRemovals(snapshot)
  local values = indexedValues(snapshot.__constructionRemovals)
  if values and #values > 0 then return values end
  return indexedValues(snapshot.constructionsToRemove or snapshot.toRemove)
end

local function assertEntitySequence(nativeValues, semanticValues, label)
  if #nativeValues ~= #semanticValues then
    return nil, label .. " count differs between native and semantic captures"
  end
  for index, nativeValue in ipairs(nativeValues) do
    if integer(nativeValue) ~= semanticEntity(semanticValues[index]) then
      return nil, label .. " entity differs at index " .. tostring(index)
    end
  end
  return true
end

local function copyNativeTransform(construction)
  local result = {}
  for index, value in ipairs(construction.transform) do result[index] = finite(value) end
  return result
end

local function mergeConstructionSemantics(result, capture)
  local semantic, source = constructionAdditions(result)
  if not semantic then return nil, "semantic construction additions are malformed" end
  if #semantic ~= #capture.constructionsToAdd then
    return nil, "construction-add count differs between native and semantic captures"
  end
  local merged = {}
  for index, native in ipairs(capture.constructionsToAdd) do
    local value = semantic[index]
    if type(value) ~= "table" then
      return nil, "semantic construction " .. tostring(index) .. " is unavailable"
    end
    local semanticName = normalResourceName(value.fileName or value.name)
    if semanticName ~= normalResourceName(native.fileName) then
      return nil, "construction resource differs between native and semantic captures at index "
        .. tostring(index)
    end
    value = util.deepCopy(value)
    value.fileName = native.fileName
    value.transf = copyNativeTransform(native)
    value.transform = nil
    merged[index] = value
  end
  result.__constructionAdditions = util.deepCopy(merged)
  if source == "constructionsToAdd" or result.constructionsToAdd ~= nil then
    result.constructionsToAdd = util.deepCopy(merged)
  end
  if result.toAdd ~= nil then result.toAdd = util.deepCopy(merged) end

  local removals = constructionRemovals(result)
  if not removals then return nil, "semantic construction removals are malformed" end
  local removalOk, removalError = assertEntitySequence(
    capture.constructionsToRemove, removals, "construction-remove")
  if not removalOk then return nil, removalError end
  result.__constructionRemovals = #capture.constructionsToRemove > 0
    and util.deepCopy(capture.constructionsToRemove) or nil
  result.constructionsToRemove = util.deepCopy(capture.constructionsToRemove)
  if result.toRemove ~= nil then result.toRemove = util.deepCopy(capture.constructionsToRemove) end
  return true
end

-- Native geometry is authoritative for the exact click. The independently
-- projected GUI payload remains authoritative for semantic construction
-- parameters, transforms, model identities and quoted cost. Combining the two
-- is what makes this useful for modded/compound builders without putting a raw
-- pointer or an undocumented STL map on the wire.
function M.merge(snapshot, rawCapture)
  local capture, captureError = validateCapture(rawCapture)
  if not capture then return nil, captureError end
  if type(snapshot) ~= "table" then return nil, "GUI proposal snapshot is unavailable" end
  local addedNodes, nodeError = project(capture.addedNodes, node, "added node")
  if not addedNodes then return nil, nodeError end
  local removedNodes, removedNodeError = project(capture.removedNodes, node, "removed node")
  if not removedNodes then return nil, removedNodeError end
  local addedEdges, edgeError = project(capture.addedEdges, edge, "added edge")
  if not addedEdges then return nil, edgeError end
  local removedEdges, removedEdgeError = project(capture.removedEdges, edge, "removed edge")
  if not removedEdges then return nil, removedEdgeError end

  local result = util.deepCopy(snapshot)
  local street = streetProposal(result)
  street.nodesToAdd = addedNodes
  street.edgesToAdd = addedEdges
  street.nodesToRemove = removedNodes
  street.edgesToRemove = removedEdges

  local semanticObjectAdds = indexedValues(street.edgeObjectsToAdd)
  local semanticObjectRemovals = indexedValues(street.edgeObjectsToRemove)
  if not semanticObjectAdds or not semanticObjectRemovals then
    return nil, "semantic edge-object vectors are malformed"
  end
  local objectAddOk, objectAddError = assertEntitySequence(
    capture.edgeObjectsToAdd, semanticObjectAdds, "edge-object-add")
  if not objectAddOk then return nil, objectAddError end
  local objectRemoveOk, objectRemoveError = assertEntitySequence(
    capture.edgeObjectsToRemove, semanticObjectRemovals, "edge-object-remove")
  if not objectRemoveOk then return nil, objectRemoveError end
  street.edgeObjectsToRemove = util.deepCopy(capture.edgeObjectsToRemove)

  local constructionOk, constructionError = mergeConstructionSemantics(result, capture)
  if not constructionOk then return nil, constructionError end
  result.__nativeFactoryCapture = {
    schemaVersion = 1,
    generation = capture.generation,
    correlation = capture.correlation,
    factoryCallerRva = integer(capture.factoryCallerRva),
    addCallerRva = integer(capture.addCallerRva),
    callerType = tostring(capture.callerType or "unknown"),
    withCost = capture.withCost == true,
    ignoreErrors = capture.ignoreErrors == true,
    addedNodeCount = #addedNodes,
    addedEdgeCount = #addedEdges,
    removedNodeCount = #removedNodes,
    removedEdgeCount = #removedEdges,
    edgeObjectAddCount = #capture.edgeObjectsToAdd,
    edgeObjectRemoveCount = #capture.edgeObjectsToRemove,
    constructionAddCount = #capture.constructionsToAdd,
    constructionRemoveCount = #capture.constructionsToRemove,
    factoryThread = integer(capture.factoryThread),
    addThread = integer(capture.addThread),
    frozenNodeIndices = util.deepCopy(capture.frozenNodeIndices),
    segmentTags = util.deepCopy(capture.segmentTags),
    constructionsToAdd = util.deepCopy(capture.constructionsToAdd),
    constructionsToRemove = util.deepCopy(capture.constructionsToRemove),
    coverage = {
      native = "topology,carrier,tangents,removals,construction-resource-transform",
      correlatedSemantic = "construction-params,edge-object-model-flags,cost",
    },
  }
  return result
end

function M.new()
  local takeFunction
  local captures = {}
  local order = {}
  local stats = { reads = 0, accepted = 0, invalid = 0, orphaned = 0, overflow = 0 }

  local function drain(maximum)
    if type(takeFunction) ~= "function" then
      takeFunction = rawget(_G, "tpf2mp_native_take_build_factory_capture")
    end
    if type(takeFunction) ~= "function" then return false, "unavailable" end
    local changed = false
    for _ = 1, math.max(1, tonumber(maximum) or 16) do
      stats.reads = stats.reads + 1
      local ok, raw = pcall(takeFunction)
      if not ok then return false, tostring(raw) end
      if raw == nil then return changed end
      if type(raw) ~= "string" then stats.invalid = stats.invalid + 1; return false, "invalid type" end
      local fault, dropped = raw:match("^F1|([^|]+)|(%d+)$")
      if fault then
        stats.overflow = stats.overflow + (tonumber(dropped) or 1)
        return false, fault
      end
      local decoded, value = pcall(json.decode, raw)
      local capture, validationError
      if decoded then capture, validationError = validateCapture(value)
      else validationError = tostring(value) end
      if not capture then
        stats.invalid = stats.invalid + 1
        return false, validationError
      end
      local key = tostring(capture.correlation)
      local queue = captures[key]
      if queue == nil then
        queue = {}
        captures[key] = queue
        order[#order + 1] = key
      end
      queue[#queue + 1] = capture
      stats.accepted = stats.accepted + 1
      changed = true
    end
    return false, "native factory capture batch exceeded its bounded drain"
  end

  local function take(correlation)
    local key = tostring(correlation)
    local queue = captures[key]
    if type(queue) ~= "table" or #queue == 0 then return nil end
    local value = table.remove(queue, 1)
    if #queue == 0 then captures[key] = nil end
    return value
  end

  local function prune(validCorrelations)
    local retained = {}
    for _, key in ipairs(order) do
      local queue = captures[key]
      if type(queue) == "table" and #queue > 0
          and (not validCorrelations or validCorrelations[key]) then
        retained[#retained + 1] = key
      elseif type(queue) == "table" and #queue > 0 then
        captures[key] = nil
        stats.orphaned = stats.orphaned + #queue
      end
    end
    order = retained
  end

  return {
    drain = drain,
    take = take,
    prune = prune,
    merge = M.merge,
    status = function() return stats end,
  }
end

return M
