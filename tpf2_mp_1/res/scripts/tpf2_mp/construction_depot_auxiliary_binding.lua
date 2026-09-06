local canonical = require "tpf2_mp/canonical"
local connectionGraph = require "tpf2_mp/construction_depot_connection_graph"

local M = {}

-- The stock depot helper owns a short entrance edge and its external
-- snap node, both of which remain attached to the construction. The canonical
-- proposal edge is the appended connector beyond them. Bind both helper
-- entities as explicit derived outputs so later operations can address the
-- actual junction and structural probes cannot rediscover unjournaled state.
function M.apply(state, record, bound, ownerOf, worldAdapter)
  if type(record) ~= "table" or record.replayPath ~= "helper-connected-depot" then
    return bound
  end
  -- A nearby captured road split is coalesced onto the helper snap node. In
  -- that shape the helper node and edge already *are* canonical node/edge
  -- slots from the user's proposal, rather than additional derived outputs.
  if connectionGraph.coalesces(record) then return bound end
  local pending = record.constructionPending
  local repair = type(pending) == "table" and pending.depotConnectionRepair or nil
  local edgeIds = type(repair) == "table" and repair.helperEdgeIds or nil
  local nodeIds = type(repair) == "table" and repair.helperNodeIds or nil
  if type(edgeIds) ~= "table" or #edgeIds ~= 1
    or type(nodeIds) ~= "table" or #nodeIds ~= 1 then
    return nil, "connected depot helper topology is unavailable for canonical binding"
  end
  local edgeId, nodeId = tonumber(edgeIds[1]), tonumber(nodeIds[1])
  if not edgeId or not nodeId then return nil, "connected depot helper entity id is invalid" end
  if canonical.resolveCanonical(state.canonical, "edge", edgeId) then
    return nil, "connected depot helper edge was bound before proposal finalisation"
  end
  if canonical.resolveCanonical(state.canonical, "node", nodeId) then
    return nil, "connected depot helper node was bound before proposal finalisation"
  end

  local sourceEdge = type(record.transaction.edges) == "table"
    and record.transaction.edges[1] or nil
  local carrier = type(sourceEdge) == "table" and sourceEdge.carrier or nil
  if carrier ~= "street" and carrier ~= "track" then
    return nil, "connected depot helper carrier is unavailable for canonical binding"
  end

  local nodeSlot = "node:helper:1"
  local nodeCid = canonical.createdId("node", record.eventId .. ":helper", 1)
  local nodeOk, nodeError = canonical.bind(state.canonical, nodeCid, "node", nodeId, {
    owner = record.companyCid,
    private = true,
    auxiliary = "construction-helper-snap",
    proposalDigest = record.transaction.digest,
    outputSlot = nodeSlot,
    fingerprint = worldAdapter and worldAdapter.fingerprint(nodeId, "node") or nil,
    topologyFingerprint = worldAdapter and worldAdapter.topologyFingerprint(nodeId, "node", {
      registry = state.canonical, worldState = state.world, ownerCid = record.companyCid,
    }) or nil,
    topologyNeighbourFingerprint = worldAdapter
      and worldAdapter.topologyNeighbourFingerprint(nodeId, "node", {
        registry = state.canonical, worldState = state.world, ownerCid = record.companyCid,
      }) or nil,
  })
  if not nodeOk then return nil, nodeError end
  state.world.logicalOwners[tostring(nodeId)] = record.companyCid
  bound[#bound + 1] = { kind = "node", cid = nodeCid,
    localId = nodeId, slot = nodeSlot }

  local slot = "edge:helper:1"
  local cid = canonical.createdId("edge", record.eventId .. ":helper", 1)
  local ok, bindError = canonical.bind(state.canonical, cid, "edge", edgeId, {
    owner = record.companyCid,
    carrier = carrier,
    private = true,
    auxiliary = "construction-helper-entrance",
    proposalDigest = record.transaction.digest,
    outputSlot = slot,
    fingerprint = worldAdapter and worldAdapter.fingerprint(edgeId, "edge") or nil,
    topologyFingerprint = worldAdapter and worldAdapter.topologyFingerprint(edgeId, "edge", {
      registry = state.canonical, worldState = state.world, ownerCid = record.companyCid,
    }) or nil,
    topologyNeighbourFingerprint = worldAdapter
      and worldAdapter.topologyNeighbourFingerprint(edgeId, "edge", {
        registry = state.canonical, worldState = state.world, ownerCid = record.companyCid,
      }) or nil,
  })
  if not ok then return nil, bindError end

  local key = tostring(edgeId)
  state.world.logicalOwners[key] = record.companyCid
  state.world.pinnedCustody[key] = {
    cid = cid,
    kind = "edge",
    logicalOwnerCid = record.companyCid,
    nativePlayerId = ownerOf(edgeId) or record.nativeOwnerPlayerId,
    requestedPlayerId = state.companies[record.companyCid].playerId,
    reason = "canonical-construction-helper-entrance",
  }
  bound[#bound + 1] = { kind = "edge", cid = cid, localId = edgeId, slot = slot }
  return bound
end

return M
