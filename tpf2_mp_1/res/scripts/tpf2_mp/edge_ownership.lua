local util = require "tpf2_mp/util"
local canonical = require "tpf2_mp/canonical"

local M = {}

local function available(value)
  return value ~= nil and (type(value) == "function" or type(value) == "table" or type(value) == "userdata")
end

local function sortedNumbers(values)
  local result, seen = {}, {}
  for key, value in pairs(values or {}) do
    local candidate = type(key) == "number" and value or key
    local number = tonumber(candidate)
    if number and number >= 0 and not seen[number] then
      seen[number] = true
      result[#result + 1] = number
    end
  end
  table.sort(result)
  return result
end

function M.capabilities()
  local componentType = api and api.type and api.type.ComponentType or {}
  return {
    simpleProposal = api and api.type and available(api.type.SimpleProposal) or false,
    segmentAndEntity = api and api.type and available(api.type.SegmentAndEntity) or false,
    playerOwned = api and api.type and available(api.type.PlayerOwned) or false,
    baseEdge = componentType.BASE_EDGE ~= nil,
    baseEdgeStreet = componentType.BASE_EDGE_STREET ~= nil,
    baseEdgeTrack = componentType.BASE_EDGE_TRACK ~= nil,
    enumerateEntities = api and api.engine and available(api.engine.forEachEntityWithComponent) or false,
    getComponent = api and api.engine and available(api.engine.getComponent) or false,
    buildProposal = api and api.cmd and api.cmd.make and available(api.cmd.make.buildProposal) or false,
    sendCommand = api and api.cmd and available(api.cmd.sendCommand) or false,
  }
end

function M.supported()
  local capabilities = M.capabilities()
  for _, key in ipairs({
    "simpleProposal", "segmentAndEntity", "playerOwned", "baseEdge", "baseEdgeStreet",
    "baseEdgeTrack", "enumerateEntities", "getComponent", "buildProposal", "sendCommand",
  }) do
    if not capabilities[key] then return false, key .. " unavailable", capabilities end
  end
  return true, nil, capabilities
end

function M.ownerOf(entity)
  local componentType = api and api.type and api.type.ComponentType
  if not (api and api.engine and available(api.engine.getComponent)
    and componentType and componentType.PLAYER_OWNED) then return nil end
  local ok, owned = pcall(api.engine.getComponent, entity, componentType.PLAYER_OWNED)
  if not ok or not owned then return nil end
  return tonumber(owned.player or owned.playerEntity)
end

function M.captureBaseEdges()
  local result = {}
  local componentType = api and api.type and api.type.ComponentType
  if not (api and api.engine and available(api.engine.forEachEntityWithComponent)
    and componentType and componentType.BASE_EDGE) then
    return nil, "BASE_EDGE enumeration unavailable"
  end
  local ok, err = pcall(function()
    api.engine.forEachEntityWithComponent(function(entity)
      entity = tonumber(entity)
      if entity then result[entity] = true end
    end, componentType.BASE_EDGE)
  end)
  if not ok then return nil, tostring(err) end
  return result
end

function M.resultIds(result)
  local ids, seen = {}, {}
  if result == nil then return ids end
  for _, field in ipairs({ "resultEntities", "entities" }) do
    local readable, values = pcall(function() return result[field] end)
    if readable and (type(values) == "table" or type(values) == "userdata") then
      local candidates = {}
      if type(values) == "table" then
        for _, value in pairs(values) do candidates[#candidates + 1] = value end
      else
        local lengthOk, length = pcall(function() return #values end)
        if lengthOk and type(length) == "number" then
          for index = 1, math.min(math.max(0, math.floor(length)), 512) do
            local itemOk, value = pcall(function() return values[index] end)
            if itemOk then candidates[#candidates + 1] = value end
          end
        end
      end
      for _, value in ipairs(candidates) do
        local entity = tonumber(value)
        if not entity and (type(value) == "table" or type(value) == "userdata") then
          local entityOk, nested = pcall(function() return value.entity or value.id or value.entityId end)
          if entityOk then entity = tonumber(nested) end
        end
        if entity and entity >= 0 and not seen[entity] then
          seen[entity] = true
          ids[#ids + 1] = entity
        end
      end
    end
  end
  table.sort(ids)
  return ids
end

local function projectedEntries(value)
  local result = {}
  if type(value) ~= "table" then return result end
  for key, item in pairs(value) do
    if type(item) == "table" then
      result[#result + 1] = {
        order = tonumber(key) or math.huge,
        key = tostring(key),
        value = item,
      }
    end
  end
  table.sort(result, function(a, b)
    if a.order ~= b.order then return a.order < b.order end
    return a.key < b.key
  end)
  return result
end

local function segmentContainer(snapshot, fieldNames)
  if type(snapshot) ~= "table" then return nil end
  local candidates, seen = {}, {}
  local function add(value)
    if type(value) == "table" and not seen[value] then
      seen[value] = true
      candidates[#candidates + 1] = value
    end
  end
  add(snapshot)
  add(snapshot.proposal)
  add(snapshot.streetProposal)
  add(snapshot.proposal and snapshot.proposal.streetProposal)
  add(snapshot.proposal and snapshot.proposal.proposal)
  add(snapshot.proposal and snapshot.proposal.proposal and snapshot.proposal.proposal.streetProposal)
  for _, candidate in ipairs(candidates) do
    for _, field in ipairs(fieldNames) do
      if type(candidate[field]) == "table" then return candidate[field], field end
    end
  end
  return nil
end

local function segmentRecords(snapshot, fieldNames)
  local container = segmentContainer(snapshot, fieldNames)
  local result = {}
  for _, entry in ipairs(projectedEntries(container)) do
    local segment = entry.value
    local entity = tonumber(segment.entity or segment.entityId or segment.id)
    local comp = type(segment.comp) == "table" and segment.comp or {}
    local playerOwned = type(segment.playerOwned) == "table" and segment.playerOwned or {}
    local node0, node1 = tonumber(comp.node0), tonumber(comp.node1)
    local carrier = tonumber(segment.type)
    result[#result + 1] = {
      entity = entity,
      node0 = node0,
      node1 = node1,
      carrier = carrier,
      nativePlayerId = tonumber(playerOwned.player or playerOwned.playerEntity),
      order = entry.order,
    }
  end
  return result
end

-- A builder proposal represents edits to existing infrastructure both by
-- removing entities and by attaching newly drawn edges to existing nodes.
-- The latter is especially important for track expansion: it can contain no
-- removed edge at all, while a positive node0/node1 still grants access to an
-- existing network. Newly drawn preview entities use negative IDs, so only
-- non-negative IDs can name an existing asset whose logical owner must be
-- consulted.
local PROPOSAL_SOURCE_FIELDS = {
  removedSegments = true,
  edgesToRemove = true,
  removedNodes = true,
  nodesToRemove = true,
  -- Signals/waypoints attach to an existing edge without replacing it.  The
  -- positive edgeEntity in the addition is therefore just as much an access
  -- source as an edge listed for removal.
  edgeObjectsToAdd = true,
  edgeObjectsToRemove = true,
  -- Construction upgrades/edits are represented as remove+add pairs.  GUI
  -- projection preserves an explicit deep copy as well as the engine field,
  -- so cover both shapes at the pre-commit boundary.
  constructionsToRemove = true,
  __constructionRemovals = true,
  toRemove = true,
}

local function proposalSourceIds(snapshot)
  local result, seenIds, seenTables = {}, {}, {}

  local function add(raw)
    local id = tonumber(raw)
    if id and id >= 0 and id == math.floor(id) and not seenIds[id] then
      seenIds[id] = true
      result[#result + 1] = id
    end
  end

  local function addItem(item)
    if type(item) == "number" or type(item) == "string" then
      add(item)
      return
    end
    if type(item) ~= "table" then return end
    -- Do not use an `or` chain here: an edge-object addition commonly carries
    -- a negative temporary object entity *and* a positive committed edgeEntity.
    -- The former is ignored while the latter must still be ownership-checked.
    add(item.entity)
    add(item.entityId)
    add(item.id)
    add(item.segmentEntity)
    add(item.edgeEntity)
    add(item.constructionEntity)
    add(item.sourceEntity)
    add(item.targetEntity)
  end

  local function addContainer(container)
    if type(container) ~= "table" then return end
    addItem(container)
    for key, item in pairs(container) do
      if key ~= "__type" and key ~= "__truncated" then addItem(item) end
    end
  end

  local function walk(value, depth)
    if type(value) ~= "table" or seenTables[value] or depth > 12 then return end
    seenTables[value] = true
    for key, nested in pairs(value) do
      if PROPOSAL_SOURCE_FIELDS[tostring(key)] then
        addContainer(nested)
      else
        walk(nested, depth + 1)
      end
    end
  end

  walk(snapshot, 0)
  -- An extension normally adds an edge whose one endpoint is a positive,
  -- already-committed BASE_NODE and whose other endpoint is a temporary
  -- negative node. Treat the positive endpoint as an ownership source even
  -- though the proposal does not remove or replace the adjoining edge.
  for _, segment in ipairs(segmentRecords(snapshot, { "addedSegments", "edgesToAdd" })) do
    add(segment.node0)
    add(segment.node1)
  end
  table.sort(result)
  return result
end

function M.proposalSourceIds(snapshot)
  return proposalSourceIds(snapshot)
end

-- Build 35924 cannot safely move BASE_EDGE ownership with the legacy setter,
-- so proxy matches enforce company isolation against the logical ownership
-- map. Most tracked edges stay on the shared turn desk; a depot or station
-- construction transfer may instead cascade an attached edge to its rightful
-- native company. Unknown IDs are public/untracked and remain usable; a
-- tracked rival source fails closed regardless of its current native holder.
function M.checkProposalAccess(worldState, snapshot, activeCompanyCid)
  local result = {
    allowed = true,
    activeCompanyCid = activeCompanyCid,
    sourceIds = proposalSourceIds(snapshot),
    tracked = {},
    blocked = {},
  }
  if type(activeCompanyCid) ~= "string" or activeCompanyCid == "" then
    result.allowed = false
    result.error = "active company is unavailable"
    return result
  end

  local logicalOwners = worldState and worldState.logicalOwners or {}
  local pinnedCustody = worldState and worldState.pinnedCustody or {}
  for _, localId in ipairs(result.sourceIds) do
    local key = tostring(localId)
    local custody = pinnedCustody[key]
    local logicalOwnerCid = logicalOwners[key]
      or (type(custody) == "table" and custody.logicalOwnerCid or nil)
    if logicalOwnerCid or type(custody) == "table" then
      local record = {
        localId = localId,
        logicalOwnerCid = logicalOwnerCid,
        canonicalId = type(custody) == "table" and custody.cid or nil,
      }
      result.tracked[#result.tracked + 1] = record
      if not logicalOwnerCid or logicalOwnerCid ~= activeCompanyCid then
        result.blocked[#result.blocked + 1] = util.deepCopy(record)
      end
    end
  end
  result.allowed = #result.blocked == 0
  if not result.allowed then result.error = "proposal modifies rival-owned infrastructure" end
  return result
end

local function topologyKey(segment)
  if not (segment and segment.node0 and segment.node1) then return nil end
  local first, second = segment.node0, segment.node1
  if second < first then first, second = second, first end
  return table.concat({ tostring(segment.carrier or "?"), tostring(first), tostring(second) }, ":")
end

-- GUI builder previews retain the committed source IDs, while builder.apply
-- exposes the replacement IDs. Match them by unchanged edge topology. This is
-- intentionally conservative: splits, joins, or ambiguous parallel mappings
-- remain unmatched so the engine can fail closed instead of guessing.
function M.matchBuilderReplacements(beforeSnapshot, appliedSnapshot)
  local allSources = segmentRecords(beforeSnapshot, { "removedSegments", "edgesToRemove" })
  local allTargets = segmentRecords(appliedSnapshot, { "addedSegments", "edgesToAdd" })
  local sources, targets = {}, {}
  for _, source in ipairs(allSources) do
    if source.entity and source.entity >= 0 then sources[#sources + 1] = source end
  end
  for _, target in ipairs(allTargets) do
    if target.entity and target.entity >= 0 then targets[#targets + 1] = target end
  end

  local sourceBuckets, targetBuckets, keys = {}, {}, {}
  local function bucket(values, buckets)
    for _, value in ipairs(values) do
      local key = topologyKey(value)
      if key then
        buckets[key] = buckets[key] or {}
        buckets[key][#buckets[key] + 1] = value
        keys[key] = true
      end
    end
  end
  bucket(sources, sourceBuckets)
  bucket(targets, targetBuckets)

  local result = {
    pairs = {},
    unmatchedSources = {},
    unmatchedTargets = {},
    ambiguous = {},
    sourceCount = #sources,
    targetCount = #targets,
  }
  local matchedSources, matchedTargets = {}, {}
  local sortedKeys = {}
  for key in pairs(keys) do sortedKeys[#sortedKeys + 1] = key end
  table.sort(sortedKeys)
  for _, key in ipairs(sortedKeys) do
    local sourceValues = sourceBuckets[key] or {}
    local targetValues = targetBuckets[key] or {}
    if #sourceValues == 1 and #targetValues == 1 then
      local source, target = sourceValues[1], targetValues[1]
      matchedSources[source] = true
      matchedTargets[target] = true
      result.pairs[#result.pairs + 1] = {
        oldLocalId = source.entity,
        newLocalId = target.entity,
        carrier = source.carrier,
        node0 = source.node0,
        node1 = source.node1,
        appliedNativePlayerId = target.nativePlayerId,
      }
    elseif #sourceValues > 0 and #targetValues > 0 then
      result.ambiguous[#result.ambiguous + 1] = {
        topology = key,
        sourceCount = #sourceValues,
        targetCount = #targetValues,
      }
    end
  end
  for _, source in ipairs(sources) do
    if not matchedSources[source] then result.unmatchedSources[#result.unmatchedSources + 1] = source end
  end
  for _, target in ipairs(targets) do
    if not matchedTargets[target] then result.unmatchedTargets[#result.unmatchedTargets + 1] = target end
  end
  table.sort(result.pairs, function(a, b) return a.oldLocalId < b.oldLocalId end)
  return result
end

local function trackedEdge(worldState, registry, localId)
  local cid = canonical.resolveCanonical(registry, "edge", localId)
  local custody = worldState and worldState.pinnedCustody
    and worldState.pinnedCustody[tostring(localId)] or nil
  local binding = cid and registry.byCanonical[cid] or nil
  local logicalOwner = worldState and worldState.logicalOwners
    and worldState.logicalOwners[tostring(localId)] or nil
  logicalOwner = logicalOwner or (custody and custody.logicalOwnerCid)
    or (binding and binding.metadata and binding.metadata.owner)
  return cid, logicalOwner, custody
end

function M.rebindObserved(worldState, registry, observation, nativePlayerId)
  observation = type(observation) == "table" and observation or {}
  local result = {
    observed = #(observation.pairs or {}),
    rebound = {},
    skipped = {},
    failed = {},
    unmatchedSources = util.deepCopy(observation.unmatchedSources or {}),
    unmatchedTargets = util.deepCopy(observation.unmatchedTargets or {}),
    ambiguous = util.deepCopy(observation.ambiguous or {}),
  }
  if not (worldState and registry and registry.byCanonical and registry.byLocal) then
    result.failed[#result.failed + 1] = { error = "world and canonical registry are required" }
    return result
  end

  -- Any tracked source without a unique target makes the whole observation
  -- unsafe. Do not migrate only part of a multi-edge builder transaction.
  for _, source in ipairs(observation.unmatchedSources or {}) do
    local oldLocalId = tonumber(source.entity or source.oldLocalId)
    local cid, logicalOwner = nil, nil
    if oldLocalId then cid, logicalOwner = trackedEdge(worldState, registry, oldLocalId) end
    if cid or logicalOwner then
      result.failed[#result.failed + 1] = {
        oldLocalId = oldLocalId,
        canonicalId = cid,
        logicalOwnerCid = logicalOwner,
        error = "tracked edge has no unique replacement",
      }
    end
  end

  local plans, seenOld, seenNew = {}, {}, {}
  for _, replacement in ipairs(observation.pairs or {}) do
    local oldLocalId, newLocalId = tonumber(replacement.oldLocalId), tonumber(replacement.newLocalId)
    local appliedNativePlayerId = tonumber(replacement.appliedNativePlayerId)
    local cid, logicalOwner, custody = nil, nil, nil
    if oldLocalId then cid, logicalOwner, custody = trackedEdge(worldState, registry, oldLocalId) end
    if not cid and not logicalOwner and not custody then
      result.skipped[#result.skipped + 1] = {
        oldLocalId = oldLocalId,
        newLocalId = newLocalId,
        reason = "source edge is not canonically tracked",
      }
    elseif not (oldLocalId and newLocalId and oldLocalId >= 0 and newLocalId >= 0) then
      result.failed[#result.failed + 1] = {
        oldLocalId = oldLocalId,
        newLocalId = newLocalId,
        error = "replacement IDs must be non-negative",
      }
    elseif seenOld[oldLocalId] or seenNew[newLocalId] then
      result.failed[#result.failed + 1] = {
        oldLocalId = oldLocalId,
        newLocalId = newLocalId,
        error = "replacement observation contains duplicate IDs",
      }
    elseif not cid or not logicalOwner then
      result.failed[#result.failed + 1] = {
        oldLocalId = oldLocalId,
        newLocalId = newLocalId,
        canonicalId = cid,
        logicalOwnerCid = logicalOwner,
        error = "tracked edge is missing canonical or logical ownership",
      }
    else
      seenOld[oldLocalId], seenNew[newLocalId] = true, true
      local occupiedBy = canonical.resolveCanonical(registry, "edge", newLocalId)
      if occupiedBy and occupiedBy ~= cid then
        result.failed[#result.failed + 1] = {
          oldLocalId = oldLocalId,
          newLocalId = newLocalId,
          canonicalId = cid,
          error = "replacement local ID is already bound to " .. tostring(occupiedBy),
        }
      else
        local observedOwner = M.ownerOf(newLocalId)
        local resolvedNativeOwner, ownerEvidence = observedOwner, "engine-component"
        if nativePlayerId ~= nil and observedOwner == nil
          and tonumber(appliedNativePlayerId) == tonumber(nativePlayerId) then
          -- builder.apply is emitted from the committed GUI result. On Build
          -- 35924 its replacement IDs can reach the engine script-event
          -- handler one update before PLAYER_OWNED becomes readable there.
          -- Use the committed result only for that transient absence; a real
          -- engine-observed mismatch below still fails closed.
          resolvedNativeOwner = appliedNativePlayerId
          ownerEvidence = "builder.apply-playerOwned"
        end
        if nativePlayerId ~= nil and tonumber(resolvedNativeOwner) ~= tonumber(nativePlayerId) then
          result.failed[#result.failed + 1] = {
            oldLocalId = oldLocalId,
            newLocalId = newLocalId,
            canonicalId = cid,
            expectedNativeOwner = nativePlayerId,
            observedNativeOwner = observedOwner,
            appliedNativeOwner = appliedNativePlayerId,
            error = "replacement edge native owner does not match the turn desk",
          }
        else
          plans[#plans + 1] = {
            oldLocalId = oldLocalId,
            newLocalId = newLocalId,
            canonicalId = cid,
            logicalOwnerCid = logicalOwner,
            nativePlayerId = resolvedNativeOwner or nativePlayerId,
            ownerEvidence = ownerEvidence,
          }
        end
      end
    end
  end
  if #result.failed > 0 or #plans == 0 then return result end

  local backup = {
    byCanonical = util.deepCopy(registry.byCanonical),
    byLocal = util.deepCopy(registry.byLocal),
    revisions = registry.revisions,
    logicalOwners = util.deepCopy(worldState.logicalOwners or {}),
    pinnedCustody = util.deepCopy(worldState.pinnedCustody or {}),
  }
  for _, plan in ipairs(plans) do
    local ok, bindingOrError = M.rebind(
      worldState, registry, plan.canonicalId, plan.oldLocalId, plan.newLocalId,
      plan.logicalOwnerCid, plan.nativePlayerId
    )
    if not ok then
      registry.byCanonical = backup.byCanonical
      registry.byLocal = backup.byLocal
      registry.revisions = backup.revisions
      worldState.logicalOwners = backup.logicalOwners
      worldState.pinnedCustody = backup.pinnedCustody
      result.rebound = {}
      result.failed[#result.failed + 1] = {
        oldLocalId = plan.oldLocalId,
        newLocalId = plan.newLocalId,
        canonicalId = plan.canonicalId,
        error = tostring(bindingOrError),
        rolledBack = true,
      }
      return result
    end
    result.rebound[#result.rebound + 1] = {
      oldLocalId = plan.oldLocalId,
      newLocalId = plan.newLocalId,
      canonicalId = plan.canonicalId,
      logicalOwnerCid = plan.logicalOwnerCid,
      nativePlayerId = plan.nativePlayerId,
      ownerEvidence = plan.ownerEvidence,
    }
  end
  return result
end

function M.validatePinnedCustody(worldState, expectedNativePlayerId, companies)
  local result = { verified = {}, failed = {} }
  local pinned = worldState and worldState.pinnedCustody or {}
  for _, key in ipairs(util.sortedKeys(pinned)) do
    local custody = pinned[key]
    local localId = tonumber(type(custody) == "table" and custody.localId or nil)
      or tonumber(key)
    local expectedOwner = tonumber(expectedNativePlayerId)
      or tonumber(type(custody) == "table" and custody.nativePlayerId or nil)
    local logicalOwnerCid = type(custody) == "table" and custody.logicalOwnerCid or nil
    local logicalCompany = logicalOwnerCid and type(companies) == "table"
      and companies[logicalOwnerCid] or nil
    local logicalNativeOwner = tonumber(type(logicalCompany) == "table"
      and logicalCompany.playerId or nil)
    local allowedOwners, allowedLookup = {}, {}
    local function allow(owner)
      owner = tonumber(owner)
      if owner ~= nil and not allowedLookup[owner] then
        allowedLookup[owner] = true
        allowedOwners[#allowedOwners + 1] = owner
      end
    end
    allow(expectedOwner)
    allow(logicalNativeOwner)
    table.sort(allowedOwners)
    local observedOwner = localId and M.ownerOf(localId) or nil
    local record = {
      localId = localId,
      canonicalId = type(custody) == "table" and custody.cid or nil,
      logicalOwnerCid = logicalOwnerCid,
      expectedNativeOwner = expectedOwner,
      logicalNativeOwner = logicalNativeOwner,
      allowedNativeOwners = allowedOwners,
      observedNativeOwner = observedOwner,
    }
    if not localId then
      record.error = "pinned edge has no valid local entity ID"
      result.failed[#result.failed + 1] = record
    elseif observedOwner == nil then
      record.error = "pinned edge native owner is not observable"
      result.failed[#result.failed + 1] = record
    elseif #allowedOwners == 0 then
      record.error = "pinned edge has no permitted native owner"
      result.failed[#result.failed + 1] = record
    elseif not allowedLookup[tonumber(observedOwner)] then
      record.error = "pinned edge is not owned by the turn desk or its logical company"
      result.failed[#result.failed + 1] = record
    else
      result.verified[#result.verified + 1] = record
    end
  end
  return result
end

function M.makeProposal(edgeEntity, playerEntity)
  local supported, supportError = M.supported()
  if not supported then return nil, supportError end
  edgeEntity, playerEntity = tonumber(edgeEntity), tonumber(playerEntity)
  if not edgeEntity or edgeEntity < 0 then return nil, "valid edge entity required" end
  if not playerEntity or playerEntity < 0 then return nil, "valid player entity required" end

  local componentType = api.type.ComponentType
  local baseOk, baseEdge = pcall(api.engine.getComponent, edgeEntity, componentType.BASE_EDGE)
  local streetOk, streetEdge = pcall(api.engine.getComponent, edgeEntity, componentType.BASE_EDGE_STREET)
  local trackOk, trackEdge = pcall(api.engine.getComponent, edgeEntity, componentType.BASE_EDGE_TRACK)
  if not baseOk or not baseEdge then return nil, "BASE_EDGE component is unavailable" end
  if not (streetOk and streetEdge) and not (trackOk and trackEdge) then
    return nil, "edge has neither BASE_EDGE_STREET nor BASE_EDGE_TRACK"
  end

  local ok, proposalOrError = pcall(function()
    local proposal = api.type.SimpleProposal.new()
    local segment = api.type.SegmentAndEntity.new()
    local playerOwned = api.type.PlayerOwned.new()
    playerOwned.player = playerEntity
    segment.entity = -1
    segment.comp = baseEdge
    segment.playerOwned = playerOwned
    if streetOk and streetEdge then
      segment.type = 0
      segment.streetEdge = streetEdge
    else
      segment.type = 1
      segment.trackEdge = trackEdge
    end
    proposal.streetProposal.edgesToRemove[1] = edgeEntity
    proposal.streetProposal.edgesToAdd[1] = segment
    return proposal
  end)
  if not ok then return nil, tostring(proposalOrError) end
  return proposalOrError, nil, {
    previousEntity = edgeEntity,
    targetPlayer = playerEntity,
    carrier = streetOk and streetEdge and "street" or "track",
  }
end

function M.findReplacement(beforeEdges, previousEntity, result, expectedOwner)
  local afterEdges, enumerationError = M.captureBaseEdges()
  if not afterEdges then return nil, {}, enumerationError end
  local candidates, seen = {}, {}
  local function consider(entity)
    entity = tonumber(entity)
    if entity and afterEdges[entity] and not seen[entity]
      and tonumber(M.ownerOf(entity)) == tonumber(expectedOwner) then
      seen[entity] = true
      candidates[#candidates + 1] = entity
    end
  end
  for _, entity in ipairs(M.resultIds(result)) do consider(entity) end
  for entity in pairs(afterEdges) do
    if not beforeEdges[entity] then consider(entity) end
  end
  consider(previousEntity)
  table.sort(candidates)
  if #candidates == 0 then return nil, candidates, "no replacement BASE_EDGE with the expected owner" end
  if #candidates > 1 then return nil, candidates, "replacement BASE_EDGE is ambiguous" end
  return candidates[1], candidates
end

function M.rebind(worldState, registry, canonicalId, oldLocalId, newLocalId, logicalOwnerCid, nativePlayerId)
  if not registry or not registry.byCanonical then return false, "canonical registry required" end
  if not worldState then return false, "world state required" end
  local binding = registry.byCanonical[canonicalId]
  if not binding or binding.kind ~= "edge" or tonumber(binding.localId) ~= tonumber(oldLocalId) then
    return false, "edge canonical binding does not match the retired local entity"
  end
  local rebound, bindingOrError = canonical.rebindLocal(registry, canonicalId, newLocalId, {
    owner = logicalOwnerCid,
    nativePlayerId = nativePlayerId,
    replacementOf = oldLocalId,
  })
  if not rebound then return false, bindingOrError end

  worldState.logicalOwners = worldState.logicalOwners or {}
  worldState.logicalOwners[tostring(oldLocalId)] = nil
  worldState.logicalOwners[tostring(newLocalId)] = logicalOwnerCid
  worldState.pinnedCustody = worldState.pinnedCustody or {}
  local custody = worldState.pinnedCustody[tostring(oldLocalId)] or {}
  worldState.pinnedCustody[tostring(oldLocalId)] = nil
  custody.cid = canonicalId
  custody.kind = "edge"
  custody.localId = newLocalId
  custody.logicalOwnerCid = logicalOwnerCid
  custody.nativePlayerId = nativePlayerId
  custody.requestedPlayerId = custody.requestedPlayerId or nativePlayerId
  custody.reason = "build35924-proposal-replacement"
  worldState.pinnedCustody[tostring(newLocalId)] = custody
  return true, bindingOrError
end

function M.send(edgeEntity, playerEntity, callback)
  callback = callback or function() end
  local beforeEdges, enumerationError = M.captureBaseEdges()
  if not beforeEdges then return false, enumerationError end
  local proposal, proposalError, proposalInfo = M.makeProposal(edgeEntity, playerEntity)
  if not proposal then return false, proposalError end
  local commandOk, commandOrError = pcall(api.cmd.make.buildProposal, proposal, nil, false)
  if not commandOk then return false, tostring(commandOrError) end
  local sendOk, sendError = util.sendCommand(commandOrError, function(result, success)
    local replacement, candidates, replacementError = nil, {}, nil
    local callbackError = "BuildProposal callback returned success=false"
    if success == true then
      replacement, candidates, replacementError = M.findReplacement(
        beforeEdges, edgeEntity, result, playerEntity
      )
      callbackError = replacementError
    end
    callback({
      success = success == true and replacement ~= nil,
      commandSuccess = success == true,
      previousEntity = edgeEntity,
      replacementEntity = replacement,
      targetPlayer = playerEntity,
      candidates = candidates,
      resultIds = M.resultIds(result),
      proposalInfo = proposalInfo,
      error = callbackError,
      rawResult = result,
    })
  end, "mod.ownership.replace-edge")
  if not sendOk then return false, tostring(sendError) end
  return true, proposalInfo
end

return M
