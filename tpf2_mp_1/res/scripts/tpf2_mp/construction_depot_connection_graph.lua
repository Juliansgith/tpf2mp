local util = require "tpf2_mp/util"

local M = {}
local EXTERNAL_CID = "node:repair:depot-external"
local MAX_JUNCTION_COALESCE_DISTANCE = 4

local function reindexRetainedNodes(nodes)
  local byOriginalSlot = {}
  for index, node in ipairs(nodes) do
    local originalSlot = tostring(node.slot or "")
    if originalSlot == "" or byOriginalSlot[originalSlot] then
      return nil, "connected depot retained an invalid or duplicate node slot"
    end
    local physicalSlot = "node:" .. tostring(index)
    byOriginalSlot[originalSlot] = physicalSlot
    node.slot = physicalSlot
  end
  return byOriginalSlot
end

local function reindexRetainedEdges(edges)
  local byOriginalSlot = {}
  for index, edge in ipairs(edges) do
    local originalSlot = tostring(edge.slot or "")
    if originalSlot == "" or byOriginalSlot[originalSlot] then
      return nil, "connected depot retained an invalid or duplicate edge slot"
    end
    local physicalSlot = "edge:" .. tostring(index)
    byOriginalSlot[originalSlot] = physicalSlot
    edge.slot = physicalSlot
  end
  return byOriginalSlot
end

local function finiteInteger(value)
  local number = tonumber(value)
  if not number or number ~= number or number == math.huge or number == -math.huge
    or number < 0 or number ~= math.floor(number) then return nil end
  return number
end

local function finitePosition(value)
  if type(value) ~= "table" then return nil end
  for _, key in ipairs({ "x", "y", "z" }) do
    local number = tonumber(value[key])
    if not number or number ~= number or number == math.huge or number == -math.huge
      or math.abs(number) > 10000000 then return nil end
  end
  return true
end

local function remapNodeReference(reference, byOriginalSlot)
  if type(reference) ~= "table" or reference.slot == nil then return true end
  local physicalSlot = byOriginalSlot[tostring(reference.slot)]
  if not physicalSlot then
    return nil, "depot connection edge references a removed or unknown node slot"
  end
  reference.slot = physicalSlot
  return true
end

local function vector(a, b, scale)
  return {
    x = (tonumber(a.x) or 0) + scale * (tonumber(b.x) or 0),
    y = (tonumber(a.y) or 0) + scale * (tonumber(b.y) or 0),
    z = (tonumber(a.z) or 0) + scale * (tonumber(b.z) or 0),
  }
end

local function referenceTouches(reference, slot)
  return type(reference) == "table" and reference.slot == slot
end

local function squaredDistance(a, b)
  if not finitePosition(a) or not finitePosition(b) then return nil end
  local x = tonumber(a.x) - tonumber(b.x)
  local y = tonumber(a.y) - tonumber(b.y)
  local z = tonumber(a.z) - tonumber(b.z)
  return x * x + y * y + z * z
end

local function nearbySplitJunction(transaction, repair)
  local entrance, junctionSlot
  for _, edge in ipairs(transaction.edges or {}) do
    local first = referenceTouches(edge.node0, repair.internalNodeSlot)
    local second = referenceTouches(edge.node1, repair.internalNodeSlot)
    if first or second then
      if entrance or (first and second) then return nil end
      local other = first and edge.node1 or edge.node0
      if type(other) ~= "table" or type(other.slot) ~= "string" then return nil end
      entrance, junctionSlot = edge, other.slot
    end
  end
  if not entrance then return nil end
  local junction
  for _, node in ipairs(transaction.nodes or {}) do
    if node.slot == junctionSlot then junction = node; break end
  end
  local distance = junction and squaredDistance(junction.position,
    repair.helperExternalPosition) or nil
  if not distance or distance > MAX_JUNCTION_COALESCE_DISTANCE ^ 2 then return nil end
  local branches = 0
  for _, edge in ipairs(transaction.edges or {}) do
    if edge.slot ~= entrance.slot and (referenceTouches(edge.node0, junctionSlot)
        or referenceTouches(edge.node1, junctionSlot)) then
      if edge.carrier ~= entrance.carrier then return nil end
      branches = branches + 1
    end
  end
  if branches < 2 then return nil end
  return { entranceSlot = entrance.slot, junctionSlot = junctionSlot,
    distance = math.sqrt(distance) }
end

local function repairOf(record)
  local pending = type(record) == "table" and record.constructionPending or nil
  local repair = type(pending) == "table" and pending.depotConnectionRepair or nil
  if type(repair) ~= "table" or type(repair.internalNodeSlot) ~= "string"
    or not repair.internalNodeSlot:match("^node:%d+$")
    or finiteInteger(repair.internalNodeId) == nil
    or #(repair.helperNodeIds or {}) ~= 1
    or finiteInteger(repair.helperNodeIds[1]) == nil
    or #(repair.helperEdgeIds or {}) ~= 1
    or finiteInteger(repair.helperEdgeIds[1]) == nil
    or not finitePosition(repair.helperInternalPosition)
    or not finitePosition(repair.helperExternalPosition)
    or tonumber(repair.internalNodeId) == tonumber(repair.helperNodeIds[1]) then
    return nil, "connected depot helper graph is unavailable"
  end
  return repair
end

function M.build(record, codec)
  local transaction = type(record) == "table" and record.transaction or nil
  local repair, repairError = repairOf(record)
  if type(transaction) ~= "table" or not repair then
    return nil, nil, repairError or "connected depot transaction is unavailable"
  end
  -- This path can resume from persisted transient state. Never rely only on
  -- PREPARE having validated the source in an earlier process: a stale or
  -- partially migrated repair record must be rejected before the GUI issues
  -- api.cmd.make.buildProposal and changes the native world.
  local sourceValid, sourceError = codec.validate(transaction)
  if not sourceValid then
    return nil, nil, "connected depot source transaction is invalid: "
      .. tostring(sourceError)
  end
  local coalesced = nearbySplitJunction(transaction, repair)
  local nodes = {}
  local internalNodes = 0
  for _, node in ipairs(transaction.nodes or {}) do
    if node.slot == repair.internalNodeSlot then
      internalNodes = internalNodes + 1
    elseif coalesced and node.slot == coalesced.junctionSlot then
      -- The helper's existing external snap node becomes the road junction.
      -- Keeping the captured node as well would require a rejected micro-edge.
    else
      nodes[#nodes + 1] = util.deepCopy(node)
    end
  end
  if internalNodes ~= 1 then
    return nil, nil, "connected depot repair does not name exactly one source internal node"
  end
  -- Removing the helper-owned internal node may leave a dense Lua array whose
  -- canonical labels begin at node:2 (or contain another gap).  The wire codec
  -- quite correctly rejects that shape later.  Reindex the derived physical
  -- graph now, before api.cmd.make.buildProposal can mutate the native world,
  -- and retain the inverse association for canonical result matching.
  local physicalSlotByOriginal, reindexError = reindexRetainedNodes(nodes)
  if not physicalSlotByOriginal then return nil, nil, reindexError end
  local delta = vector(repair.helperExternalPosition, repair.helperInternalPosition, -1)
  local sourceInternal = finitePosition(repair.sourceInternalPosition)
    and repair.sourceInternalPosition or repair.helperInternalPosition
  local sourceCorrection = vector(sourceInternal, repair.helperInternalPosition, -1)
  local edges, shifted = {}, 0
  for _, source in ipairs(transaction.edges or {}) do
    if coalesced and source.slot == coalesced.entranceSlot then
      shifted = shifted + 1
    else
    local edge = util.deepCopy(source)
    local first = referenceTouches(source.node0, repair.internalNodeSlot)
    local second = referenceTouches(source.node1, repair.internalNodeSlot)
    if first and second then return nil, nil, "depot connection edge loops through its internal node" end
    if coalesced and (referenceTouches(source.node0, coalesced.junctionSlot)
        or referenceTouches(source.node1, coalesced.junctionSlot)) then
      if first or second then
        return nil, nil, "connected depot junction coalescing found a second internal edge"
      end
      if referenceTouches(source.node0, coalesced.junctionSlot) then
        edge.node0 = { cid = EXTERNAL_CID }
      end
      if referenceTouches(source.node1, coalesced.junctionSlot) then
        edge.node1 = { cid = EXTERNAL_CID }
      end
    elseif first then
      edge.node0 = { cid = EXTERNAL_CID }
      edge.tangent0 = vector(vector(source.tangent0, delta, -1), sourceCorrection, 1)
      edge.tangent1 = vector(vector(source.tangent1, delta, -1), sourceCorrection, 1)
      shifted = shifted + 1
    elseif second then
      edge.node1 = { cid = EXTERNAL_CID }
      edge.tangent0 = vector(vector(source.tangent0, delta, 1), sourceCorrection, -1)
      edge.tangent1 = vector(vector(source.tangent1, delta, 1), sourceCorrection, -1)
      shifted = shifted + 1
    end
    local firstOk, firstError = remapNodeReference(edge.node0, physicalSlotByOriginal)
    if not firstOk then return nil, nil, firstError end
    local secondOk, secondError = remapNodeReference(edge.node1, physicalSlotByOriginal)
    if not secondOk then return nil, nil, secondError end
    edges[#edges + 1] = edge
    end
  end
  if shifted ~= 1 then
    return nil, nil, "connected depot must expose exactly one entrance edge"
  end
  local physicalEdgeByOriginal, edgeReindexError = reindexRetainedEdges(edges)
  if not physicalEdgeByOriginal then return nil, nil, edgeReindexError end
  local physical = {
    schemaVersion = codec.SCHEMA_VERSION,
    companyCid = transaction.companyCid,
    cost = 0,
    nodes = nodes,
    edges = edges,
    edgeObjects = { add = {}, retain = {}, remove = {} },
    remove = util.deepCopy(transaction.remove or { edges = {}, nodes = {} }),
  }
  physical.digest = codec.digest(physical)
  physical.transactionId = "proposal:" .. physical.digest
  -- The source proposal has already crossed the mode-appropriate portable
  -- gate.  Validate the derived graph structurally here without making this
  -- shared helper reject legacy standalone captures that retain local-only
  -- resource indices.
  local valid, validationError = codec.validate(physical)
  if not valid then
    return nil, nil, "derived depot connection graph is invalid: " .. tostring(validationError)
  end
  local localRefs = util.deepCopy(record.localRefs or {})
  localRefs[EXTERNAL_CID] = repair.helperNodeIds[1]
  return physical, localRefs, nil, {
    physicalSlotByOriginal = physicalSlotByOriginal,
    physicalEdgeByOriginal = physicalEdgeByOriginal,
    coalesced = coalesced,
  }
end

function M.coalesces(record)
  local transaction = type(record) == "table" and record.transaction or nil
  local repair = repairOf(record)
  return transaction and repair and nearbySplitJunction(transaction, repair) ~= nil
end

function M.filter(record, nodes, edges)
  local repair = repairOf(record)
  if record and record.replayPath == "helper-connected-depot" and repair then
    local ignoredNodes = { [tonumber(repair.internalNodeId)] = true }
    for _, value in ipairs(repair.helperNodeIds or {}) do ignoredNodes[tonumber(value)] = true end
    local ignoredEdges = {}
    for _, value in ipairs(repair.helperEdgeIds or {}) do ignoredEdges[tonumber(value)] = true end
    local filteredNodes, filteredEdges = {}, {}
    for _, value in ipairs(nodes or {}) do
      if not ignoredNodes[tonumber(value)] then filteredNodes[#filteredNodes + 1] = value end
    end
    for _, value in ipairs(edges or {}) do
      if not ignoredEdges[tonumber(value)] then filteredEdges[#filteredEdges + 1] = value end
    end
    return filteredNodes, filteredEdges
  end
  return nodes, edges
end

function M.expected(record, codec, defaultNodes, defaultEdges)
  if record and record.replayPath == "helper-connected-depot" then
    local physical = M.build(record, codec)
    if physical then return #(physical.nodes or {}), #(physical.edges or {}) end
  end
  return defaultNodes, defaultEdges
end

function M.match(record, codec, nodes, edges, deps)
  local physical, _, physicalError, slotPlan = M.build(record, codec)
  if not physical then return nil, physicalError end
  local repair = assert(repairOf(record))
  local function resolvePosition(cid)
    if cid == EXTERNAL_CID then return repair.helperExternalPosition end
    return deps.resolvePosition(cid)
  end
  local function resolveLocal(cid)
    if cid == EXTERNAL_CID then return repair.helperNodeIds[1] end
    return deps.resolveLocal(cid)
  end
  local matched, matchError = codec.matchCreated(
    physical, deps.inspectNodes(nodes), deps.inspectEdges(edges), 0.5,
    resolvePosition, resolveLocal)
  if not matched or #matched.unmatchedNodes > 0 or #matched.unmatchedEdges > 0
    or #matched.unmatchedEdgeObjects > 0 then
    return nil, matchError or "connected depot repair created unexpected topology"
  end
  local canonical = { nodes = {}, edges = {}, edgeObjects = matched.edgeObjects,
    unmatchedNodes = {}, unmatchedEdges = {}, unmatchedEdgeObjects = {} }
  for _, node in ipairs(record.transaction.nodes or {}) do
    canonical.nodes[node.slot] = node.slot == repair.internalNodeSlot
      and repair.internalNodeId
      or (slotPlan.coalesced and node.slot == slotPlan.coalesced.junctionSlot
        and repair.helperNodeIds[1])
      or matched.nodes[slotPlan.physicalSlotByOriginal[node.slot]]
  end
  for _, edge in ipairs(record.transaction.edges or {}) do
    canonical.edges[edge.slot] = slotPlan.coalesced
      and edge.slot == slotPlan.coalesced.entranceSlot and repair.helperEdgeIds[1]
      or matched.edges[slotPlan.physicalEdgeByOriginal[edge.slot]]
  end
  return canonical
end

return M
