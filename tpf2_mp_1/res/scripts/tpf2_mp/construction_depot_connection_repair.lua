local util = require "tpf2_mp/util"
local connectionReplay = require "tpf2_mp/construction_connection_replay"
local connectionGraph = require "tpf2_mp/construction_depot_connection_graph"

local M = {}

local function squaredDistance(a, b)
  if type(a) ~= "table" or type(b) ~= "table" then return nil end
  local ax, ay, az = tonumber(a.x), tonumber(a.y), tonumber(a.z)
  local bx, by, bz = tonumber(b.x), tonumber(b.y), tonumber(b.z)
  if not ax or not ay or not az or not bx or not by or not bz then return nil end
  local x, y, z = ax - bx, ay - by, az - bz
  return x * x + y * y + z * z
end

local function shape(record)
  local transaction = type(record) == "table" and record.transaction or nil
  local construction = type(transaction) == "table"
    and type(transaction.constructions) == "table" and transaction.constructions[1] or nil
  if not M.isRepairableTransaction(transaction, construction) then
    return nil, nil
  end
  return transaction, construction
end

function M.isRepairableTransaction(transaction, construction)
  if not connectionReplay.isConnectedStreetDepot(transaction, construction) then return false end
  local objects = type(transaction.edgeObjects) == "table" and transaction.edgeObjects or {}
  if #(objects.add or {}) > 0 or #(objects.retain or {}) > 0
    or #(objects.remove or {}) > 0 then return false end
  if #(transaction.nodes or {}) < 1 or #(transaction.edges or {}) < 1 then return false end
  for _, edge in ipairs(transaction.edges) do
    for _, reference in ipairs({ edge.node0, edge.node1 }) do
      if type(reference) == "table" and type(reference.slot) == "string" then return true end
    end
  end
  return false
end

function M.helperSafe(record)
  local transaction = type(record) == "table" and record.transaction or nil
  local construction = type(transaction) == "table" and transaction.constructions
    and transaction.constructions[1] or nil
  if connectionReplay.isConnectedStreetDepot(transaction, construction)
    and not M.isRepairableTransaction(transaction, construction) then
    return false, "connected street depot graph is outside the safe helper-repair boundary"
  end
  return true
end

local function internalNode(transaction, construction)
  local transform = construction.transform or {}
  local origin = { x = transform[13], y = transform[14], z = transform[15] }
  local ranked = {}
  for _, node in ipairs(transaction.nodes or {}) do
    local distance = squaredDistance(node.position, origin)
    if distance then ranked[#ranked + 1] = { node = node, distance = distance } end
  end
  table.sort(ranked, function(a, b)
    if a.distance ~= b.distance then return a.distance < b.distance end
    return tostring(a.node.slot) < tostring(b.node.slot)
  end)
  if #ranked < 1 then return nil, "connected depot has no measurable internal node" end
  if ranked[2] and math.abs(ranked[2].distance - ranked[1].distance) < 0.000001 then
    return nil, "connected depot internal node is geometrically ambiguous"
  end
  return ranked[1].node
end

local function findObservedNode(expected, observed)
  local matches = {}
  for _, node in ipairs(observed or {}) do
    local distance = squaredDistance(expected.position, node.position)
    if distance and distance <= 0.25 then matches[#matches + 1] = node end
  end
  if #matches ~= 1 then
    return nil, "helper depot did not expose one construction-internal node"
  end
  return matches[1]
end

local function edgeTouches(edge, position)
  local first = squaredDistance(edge.node0Position, position)
  local second = squaredDistance(edge.node1Position, position)
  return (first and first <= 0.25) or (second and second <= 0.25)
end

function M.isRepairable(record)
  return shape(record) ~= nil
end

function M.stage(record, pending, deps)
  local transaction, construction = shape(record)
  if not transaction or type(pending) ~= "table" or pending.phase ~= "settling-build" then
    return nil, "connected depot helper repair state is unavailable"
  end
  local nodes, edges = deps.inspectNodes(deps.candidateNodes), deps.inspectEdges(deps.candidateEdges)
  local counts = deps.counts or {}
  local complete = deps.rootReady == true and counts.construction == 1
    and counts.depot == 1 and #nodes == 2 and #edges == 1
    and (counts.edge_object or 0) == 0
  if not complete then
    pending.depotHelperSignature, pending.depotHelperStableSinceTick = nil, nil
    return { waiting = true, phase = "settling-helper-depot" }
  end
  if edges[1].carrier ~= "street" then
    return nil, "connected street depot helper generated a non-street edge"
  end
  local expectedInternal, internalError = internalNode(transaction, construction)
  if not expectedInternal then return nil, internalError end
  local observedInternal, observedError = findObservedNode(expectedInternal, nodes)
  if not observedInternal then return nil, observedError end
  if not edgeTouches(edges[1], observedInternal.position) then
    return nil, "helper depot edge is detached from its construction-internal node"
  end
  local signature = tostring(deps.signature or "")
  if pending.depotHelperSignature ~= signature then
    pending.depotHelperSignature = signature
    pending.depotHelperStableSinceTick = deps.tick
    return { waiting = true, phase = "stabilizing-helper-depot" }
  end
  if deps.tick - (pending.depotHelperStableSinceTick or deps.tick) < deps.stableTicks then
    return { waiting = true, phase = "stabilizing-helper-depot" }
  end
  local disposableNodes = {}
  for _, node in ipairs(nodes) do
    if tonumber(node.localId) ~= tonumber(observedInternal.localId) then
      disposableNodes[#disposableNodes + 1] = tonumber(node.localId)
    end
  end
  if #disposableNodes ~= 1 then return nil, "helper depot snap-node set is ambiguous" end
  pending.depotConnectionRepair = {
    internalNodeSlot = expectedInternal.slot,
    internalNodeId = tonumber(observedInternal.localId),
    helperInternalPosition = util.deepCopy(observedInternal.position),
    helperExternalPosition = util.deepCopy((function()
      for _, node in ipairs(nodes) do
        if tonumber(node.localId) == disposableNodes[1] then return node.position end
      end
    end)()),
    helperEdgeIds = { tonumber(edges[1].localId) },
    helperNodeIds = disposableNodes,
  }
  pending.phase = "awaiting-gui-depot-connection"
  pending.nextVerificationTick = deps.tick
  pending.stableSinceTick, pending.lastReadySignature = nil, nil
  record.replayPath = "helper-depot-connection"
  record.status = "queued"
  deps.proposals.queued = (deps.proposals.queued or 0) + 1
  return { stagedDepotConnection = true, proposalId = record.proposalId }
end

function M.advance(record, pending, deps)
  if type(pending) ~= "table" or pending.phase ~= "settling-build"
    or not M.isRepairable(record) then return false end
  local staged, stageError = M.stage(record, pending, deps)
  if not staged then return true, nil, stageError end
  if staged.stagedDepotConnection then return true, staged end
  if deps.tick < pending.deadlineTick then
    pending.nextVerificationTick = deps.tick + deps.pendingRescanTicks
    return true, staged
  end
  return true, nil, {
    error = "helper depot did not stabilize before connection repair",
    counts = deps.counts, removedCounts = deps.removedCounts,
  }
end

function M.materialise(record, codec, apiValue)
  local result, localRefs, graphError = connectionGraph.build(record, codec)
  if not result then return nil, graphError end
  local proposal, materialisation = codec.materialise(result, {
    api = apiValue,
    nativePlayerId = record.nativeOwnerPlayerId,
    resolveLocal = function(cid) return localRefs[cid] end,
  })
  if not proposal then return nil, materialisation end
  return proposal, {
    transaction = result,
    materialisation = materialisation,
    expectedNodes = #(result.nodes or {}),
    expectedEdges = #(result.edges or {}),
  }
end

function M.canonicalCandidates(record, nodes, edges)
  return connectionGraph.filter(record, nodes, edges)
end

function M.expectedCounts(record, codec, nodes, edges)
  return connectionGraph.expected(record, codec, nodes, edges)
end

function M.match(record, codec, nodes, edges, deps)
  return connectionGraph.match(record, codec, nodes, edges, deps)
end

function M.accept(record, payload, tick)
  local pending = record and record.constructionPending or nil
  local repair = type(pending) == "table" and pending.depotConnectionRepair or nil
  if type(repair) ~= "table" or pending.phase ~= "awaiting-gui-depot-connection" then
    return nil, "connected depot GUI repair state is unavailable"
  end
  local createdNodes = type(payload.createdNodeIds) == "table" and payload.createdNodeIds or {}
  local createdEdges = type(payload.createdEdgeIds) == "table" and payload.createdEdgeIds or {}
  if #createdNodes ~= tonumber(payload.repairExpectedNodes)
    or #createdEdges ~= tonumber(payload.repairExpectedEdges) then
    return nil, "connected depot topology repair produced an unexpected graph"
  end
  pending.phase = "settling-helper-depot-connection"
  pending.nextVerificationTick = tick
  pending.stableSinceTick, pending.lastReadySignature = nil, nil
  record.replayPath = "helper-connected-depot"
  record.status = "building-construction"
  return { constructionVerificationPending = true,
    helperDepotConnection = true, proposalId = record.proposalId }
end

return M
