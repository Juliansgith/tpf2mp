local json = require "tpf2_mp/json"
local wrapperSelector = require "tpf2_mp/proposal_wrapper_selector"
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
  -- Captures produced before the Add fallback was introduced had no source
  -- discriminator. They can only be the factory form, whose options and
  -- caller RVA were independently observed.
  capture.captureSource = capture.captureSource or "factory"
  if capture.optionFieldsKnown == nil and capture.captureSource == "factory" then
    capture.optionFieldsKnown = true
  end
  local factoryCallerRva = integer(capture.factoryCallerRva)
  local addCallerRva = integer(capture.addCallerRva)
  if not addCallerRva or addCallerRva <= 0
    or (capture.captureSource == "factory"
      and (not factoryCallerRva or factoryCallerRva <= 0 or capture.optionFieldsKnown ~= true))
    or (capture.captureSource == "command-list-add"
      and (factoryCallerRva ~= 0 or capture.optionFieldsKnown ~= false))
    or (capture.captureSource ~= "factory" and capture.captureSource ~= "command-list-add") then
    return nil, "native proposal capture source/caller contract is invalid"
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
  return wrapperSelector.select(snapshot)
end

local function semanticEdges(snapshot, names)
  local proposal, selectorError = streetProposal(snapshot)
  if not proposal then return nil, selectorError end
  for _, name in ipairs(names) do
    local values = indexedValues(proposal[name])
    if values and #values > 0 then return values end
  end
  return {}
end

-- SegmentAndEntity owns a nested vector of edge-object references.  The
-- pinned native scalar decoder deliberately does not walk that STL vector:
-- the independently projected GUI envelope already exposes it without ABI
-- guesses.  Preserve those semantic references on the native-attested edge,
-- matching by temporary entity identity rather than vector position.
local function mergeEdgeObjectReferences(nativeEdges, semanticValues)
  local semanticByEntity = {}
  for _, value in ipairs(semanticValues or {}) do
    local entity = semanticEntity(value)
    if entity ~= nil and semanticByEntity[entity] == nil then
      semanticByEntity[entity] = value
    end
  end
  for _, value in ipairs(nativeEdges or {}) do
    local semantic = semanticByEntity[semanticEntity(value)]
    if semantic then
      local semanticComp = type(semantic.comp) == "table" and semantic.comp or semantic
      local objects = semanticComp.objects
      if type(objects) == "table" then value.comp.objects = util.deepCopy(objects) end
    end
  end
end

local function constructionAdditions(snapshot)
  local values = indexedValues(snapshot.__constructionAdditions)
  if values and #values > 0 then return values, "__constructionAdditions" end
  values = indexedValues(snapshot.constructionsToAdd or snapshot.toAdd)
  return values, "constructionsToAdd"
end

local function constructionRemovals(snapshot)
  local values = indexedValues(snapshot.__constructionRemovals)
  if values == nil then return nil, "semantic construction removals are malformed" end
  if #values > 0 then return values, "__constructionRemovals" end
  values = indexedValues(snapshot.constructionsToRemove or snapshot.toRemove)
  if values == nil then return nil, "semantic construction removals are malformed" end
  return values, "constructionsToRemove"
end

local function constructionRemovalIdentity(value, label)
  local direct = integer(value)
  if direct ~= nil then
    if direct < 0 then return nil, label .. " has a temporary entity id" end
    return direct
  end
  if type(value) ~= "table" then return nil, label .. " has no existing entity id" end
  local identity
  for _, field in ipairs({ "entity", "entityId", "id", "localId" }) do
    if value[field] ~= nil then
      local candidate = integer(value[field])
      if candidate == nil or candidate < 0 then
        return nil, label .. " has an invalid existing entity id"
      end
      if identity ~= nil and identity ~= candidate then
        return nil, label .. " contains conflicting entity ids"
      end
      identity = candidate
    end
  end
  if identity == nil then return nil, label .. " has no existing entity id" end
  return identity
end

local function mergedConstructionRemovals(result, capture)
  local semantic, semanticSource = constructionRemovals(result)
  if not semantic then return nil, nil, nil, semanticSource end
  local merged, byIdentity = {}, {}
  local function append(values, source, preferValue)
    for index, value in ipairs(values) do
      local identity, identityError = constructionRemovalIdentity(
        value, source .. " construction removal " .. tostring(index))
      if identity == nil then return nil, identityError end
      local existing = byIdentity[identity]
      if existing == nil then
        merged[#merged + 1] = util.deepCopy(value)
        byIdentity[identity] = #merged
      elseif preferValue then
        -- The GUI projection can carry semantic kind information that the
        -- native vector's scalar ID cannot. Both records identify the same
        -- correlated live entity, so retain the richer representation once.
        merged[existing] = util.deepCopy(value)
      end
    end
    return true
  end
  local nativeOk, nativeError = append(
    capture.constructionsToRemove, "native", false)
  if not nativeOk then return nil, nil, nil, nativeError end
  local semanticOk, semanticError = append(semantic, "semantic", true)
  if not semanticOk then return nil, nil, nil, semanticError end
  if #merged > 1024 then return nil, nil, nil, "construction-removal union exceeds limit" end
  local source = #capture.constructionsToRemove > 0 and #semantic > 0
      and "native+semantic"
    or (#capture.constructionsToRemove > 0 and "native" or semanticSource)
  return merged, #semantic, source
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

  -- Neither projection is complete for every stock builder. The factory
  -- vector catches collateral omitted by shallow GUI envelopes, while mixed
  -- road/track clicks can expose a demolished town building only in the exact
  -- GUI callback. Because both inputs are generation/correlation-bound to the
  -- same suppressed click, retain their validated identity union.
  local removals, semanticRemovalCount, removalSource, removalError =
    mergedConstructionRemovals(result, capture)
  if not removals then return nil, removalError end
  result.__constructionRemovals = #removals > 0 and util.deepCopy(removals) or nil
  result.constructionsToRemove = util.deepCopy(removals)
  if result.toRemove ~= nil then result.toRemove = util.deepCopy(removals) end
  return true, nil, {
    semanticRemovalCount = semanticRemovalCount,
    mergedRemovalCount = #removals,
    removalSource = removalSource,
  }
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
  local street, selectorError = streetProposal(result)
  if not street then return nil, selectorError end
  local semanticAddedEdges, addedSelectorError = semanticEdges(
    result, { "edgesToAdd", "addedSegments" })
  if not semanticAddedEdges then return nil, addedSelectorError end
  local semanticRemovedEdges, removedSelectorError = semanticEdges(
    result, { "edgesToRemove", "removedSegments" })
  if not semanticRemovedEdges then return nil, removedSelectorError end
  mergeEdgeObjectReferences(addedEdges, semanticAddedEdges)
  mergeEdgeObjectReferences(removedEdges, semanticRemovedEdges)
  local processedStreet = util.deepCopy(street)
  street.nodesToAdd = addedNodes
  street.edgesToAdd = addedEdges
  street.nodesToRemove = removedNodes
  street.edgesToRemove = removedEdges

  local semanticObjectAdds = indexedValues(street.edgeObjectsToAdd)
  local semanticObjectRemovals = indexedValues(street.edgeObjectsToRemove)
  if not semanticObjectAdds or not semanticObjectRemovals then
    return nil, "semantic edge-object vectors are malformed"
  end
  -- The first scalar in Build 35924's edge-object record is not a portable
  -- object identity for every builder variant.  The native vector still
  -- attests cardinality while the correlated GUI payload supplies model,
  -- side, spline parameter and temporary identity.
  if #capture.edgeObjectsToAdd ~= #semanticObjectAdds then
    return nil, "edge-object-add count differs between native and semantic captures"
  end
  if #capture.edgeObjectsToRemove ~= #semanticObjectRemovals then
    return nil, "edge-object-remove count differs between native and semantic captures"
  end

  local constructionOk, constructionError, constructionMerge =
    mergeConstructionSemantics(result, capture)
  if not constructionOk then return nil, constructionError end
  -- Proposal normalisation used to rediscover the first recursively sorted
  -- alias in the GUI snapshot.  Compound builders often retain a shallow
  -- preview beside the exact apply payload; selecting that alias discarded
  -- native street features and removals.  This explicit envelope is the sole
  -- topology source whenever a factory capture merged successfully.
  result.__nativeTopology = {
    schemaVersion = 1,
    nodesToAdd = util.deepCopy(addedNodes),
    edgesToAdd = util.deepCopy(addedEdges),
    nodesToRemove = util.deepCopy(removedNodes),
    edgesToRemove = util.deepCopy(removedEdges),
    edgeObjectsToAdd = util.deepCopy(semanticObjectAdds),
    edgeObjectsToRemove = util.deepCopy(semanticObjectRemovals),
  }
  if #capture.constructionsToAdd == 0 and #capture.constructionsToRemove == 0 then
    local topology, topologyError = require("tpf2_mp/gui_processed_transport_topology").select(
      result.__nativeTopology, processedStreet, indexedValues)
    if not topology then return nil, topologyError end
    result.__nativeTopology = topology
  end
  local attestedWithCost, attestedIgnoreErrors
  if capture.optionFieldsKnown == true then
    attestedWithCost = capture.withCost == true
    attestedIgnoreErrors = capture.ignoreErrors == true
  end
  result.__nativeFactoryCapture = {
    schemaVersion = 1,
    generation = capture.generation,
    correlation = capture.correlation,
    factoryCallerRva = integer(capture.factoryCallerRva),
    addCallerRva = integer(capture.addCallerRva),
    callerType = tostring(capture.callerType or "unknown"),
    captureSource = capture.captureSource,
    optionFieldsKnown = capture.optionFieldsKnown == true,
    -- At the Add fallback boundary the factory-only option arguments do not
    -- exist. Keep their raw placeholders out of attested metadata; replay
    -- policy continues to come from the correlated GUI/canonical envelope.
    withCost = attestedWithCost,
    ignoreErrors = attestedIgnoreErrors,
    optionSource = capture.optionFieldsKnown == true and "native-factory" or "correlated-envelope",
    addedNodeCount = #addedNodes,
    addedEdgeCount = #addedEdges,
    removedNodeCount = #removedNodes,
    removedEdgeCount = #removedEdges,
    edgeObjectAddCount = #capture.edgeObjectsToAdd,
    edgeObjectRemoveCount = #capture.edgeObjectsToRemove,
    constructionAddCount = #capture.constructionsToAdd,
    constructionRemoveCount = #capture.constructionsToRemove,
    nativeConstructionRemoveCount = #capture.constructionsToRemove,
    semanticConstructionRemoveCount = constructionMerge.semanticRemovalCount,
    mergedConstructionRemoveCount = constructionMerge.mergedRemovalCount,
    constructionRemovalSource = constructionMerge.removalSource,
    topologySource = result.__nativeTopology.source or "native-factory-input",
    factoryThread = integer(capture.factoryThread),
    addThread = integer(capture.addThread),
    frozenNodeIndices = util.deepCopy(capture.frozenNodeIndices),
    segmentTags = util.deepCopy(capture.segmentTags),
    constructionsToAdd = util.deepCopy(capture.constructionsToAdd),
    constructionsToRemove = util.deepCopy(capture.constructionsToRemove),
    coverage = {
      native = "nodes,edges,carrier,tangents,topology-removals,construction-resource-transform",
      correlatedSemantic = "construction-params,edge-object-records,cost",
    },
  }
  return result
end

-- Attach native evidence to a pending GUI capture without ever weakening an
-- already-attested snapshot.  Preview and builder.apply callbacks are emitted
-- in either order by different builders; keeping this transition here gives
-- both orderings the same merge and metadata contract.
function M.attach(pending, rawCapture)
  if type(pending) ~= "table" or type(pending.proposalSnapshot) ~= "table" then
    return nil, "pending GUI proposal snapshot is unavailable"
  end
  if type(rawCapture) ~= "table" then
    return nil, "native factory capture is unavailable"
  end
  if pending.nativeFactoryCapture == rawCapture
    and type(pending.proposalSnapshot.__nativeTopology) == "table" then
    return pending, nil, false
  end
  local merged, mergeError = M.merge(pending.proposalSnapshot, rawCapture)
  if not merged then return nil, mergeError end
  pending.proposalSnapshot = merged
  pending.nativeFactoryCapture = rawCapture
  pending.nativeFactoryGeneration = integer(rawCapture.generation)
  pending.nativeFactoryCallerType = rawCapture.callerType
  pending.nativeFactoryCaptureError = nil
  return pending, nil, true
end

function M.new(options)
  options = options or {}
  local takeFunction
  local captures = {}
  local order = {}
  local maximumTotal = math.max(4, tonumber(options.maximumTotal) or 64)
  local maximumPerCorrelation = math.max(2,
    tonumber(options.maximumPerCorrelation) or 16)
  local maximumGenerationAge = math.max(maximumTotal,
    tonumber(options.maximumGenerationAge) or 128)
  local stats = {
    reads = 0, accepted = 0, invalid = 0, orphaned = 0,
    expired = 0, evicted = 0, overflow = 0, queued = 0,
  }

  local function removeFromCorrelation(capture)
    local key = tostring(capture.correlation)
    local queue = captures[key]
    if type(queue) ~= "table" then return false end
    for index, value in ipairs(queue) do
      if value == capture then
        table.remove(queue, index)
        if #queue == 0 then captures[key] = nil end
        stats.queued = math.max(0, stats.queued - 1)
        return true
      end
    end
    return false
  end

  local function removeFromOrder(capture)
    for index, value in ipairs(order) do
      if value == capture then table.remove(order, index); return end
    end
  end

  local function retire(capture, reason)
    if not removeFromCorrelation(capture) then return end
    removeFromOrder(capture)
    stats.orphaned = stats.orphaned + 1
    stats[reason] = (stats[reason] or 0) + 1
  end

  local function pruneAge(newestGeneration)
    while #order > 0 do
      local generation = integer(order[1].generation) or 0
      if newestGeneration - generation <= maximumGenerationAge then break end
      retire(order[1], "expired")
    end
  end

  local function enqueue(capture)
    pruneAge(integer(capture.generation) or 0)
    local key = tostring(capture.correlation)
    local queue = captures[key]
    if queue == nil then queue = {}; captures[key] = queue end
    -- One click can legitimately emit several native commands. Preserve them
    -- in factory/visitor order; an abandoned hover burst is retired locally
    -- and is not a sticky session fault.
    while #queue >= maximumPerCorrelation do retire(queue[1], "evicted") end
    while #order >= maximumTotal do retire(order[1], "evicted") end
    queue[#queue + 1] = capture
    order[#order + 1] = capture
    stats.queued = stats.queued + 1
  end

  local function drain(maximum)
    if type(takeFunction) ~= "function" then
      takeFunction = rawget(_G, "tpf2mp_native_take_build_factory_capture")
    end
    if type(takeFunction) ~= "function" then return false, "unavailable" end
    local changed = false
    local limit = math.max(1, tonumber(maximum) or 16)
    for index = 1, limit + 1 do
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
      -- Probe once past the bound so a completely full-but-drained native
      -- queue is not mistaken for backlog overflow. Native itself is bounded;
      -- a real overflow is emitted as the F1 record handled above.
      if index > limit then
        return false, "native factory capture batch exceeded its bounded drain"
      end
      local decoded, value = pcall(json.decode, raw)
      local capture, validationError
      if decoded then capture, validationError = validateCapture(value)
      else validationError = tostring(value) end
      if not capture then
        -- A correctly framed record still carries the factory/Add/visitor
        -- correlation even when one optional native sub-vector is outside our
        -- current decoder contract. Queue that record so the event runtime can
        -- fall back to the exact, generation-bound GUI payload. Malformed JSON
        -- or missing identity remains a queue-level fault.
        local correlation = decoded and integer(value and value.correlation) or nil
        local generation = decoded and integer(value and value.generation) or nil
        if not correlation or correlation <= 0 or not generation or generation <= 0 then
          stats.invalid = stats.invalid + 1
          return false, validationError
        end
        capture = value
        capture.__validationError = tostring(validationError)
        stats.invalid = stats.invalid + 1
      else
        stats.accepted = stats.accepted + 1
      end
      enqueue(capture)
      changed = true
    end
    return changed
  end

  local function take(correlation)
    local key = tostring(correlation)
    local queue = captures[key]
    if type(queue) ~= "table" or #queue == 0 then return nil end
    local value = table.remove(queue, 1)
    if #queue == 0 then captures[key] = nil end
    removeFromOrder(value)
    stats.queued = math.max(0, stats.queued - 1)
    return value
  end

  local function prune(validCorrelations)
    if not validCorrelations then return end
    local remove = {}
    for _, capture in ipairs(order) do
      if not validCorrelations[tostring(capture.correlation)] then
        remove[#remove + 1] = capture
      end
    end
    for _, capture in ipairs(remove) do retire(capture, "expired") end
  end

  return {
    drain = drain,
    take = take,
    prune = prune,
    merge = M.merge,
    attach = M.attach,
    status = function() return stats end,
  }
end

return M
