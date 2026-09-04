local canonical = require "tpf2_mp/canonical"
local constructionOutputOrder = require "tpf2_mp/construction_output_order"
local bindingMetadata = require "tpf2_mp/proposal_binding_metadata"

local M = {}

-- Bind the compound outputs of one construction result. Exact GUI deltas may
-- contain identity captured while fresh Build 35924 child components are safe
-- to inspect in that Lua state; ordinary engine-side results are decorated by
-- reading the settled world. The caller owns a wider proposal-binding snapshot
-- and rolls this whole function back if any child cannot be bound.
function M.bind(state, record, existing, delta, pending, world)
  local bound = existing or {}
  local construction = record.transaction.constructions[1]
  local rootEntity = pending and tonumber(pending.rootEntity) or nil
  local rootKind = construction.kind == "asset" and "asset" or "construction"
  if construction.mode == "upgrade" then
    if not rootEntity then return nil, "upgraded construction root is unavailable" end
    local cid = construction.sourceCid
    local ok, bindError = canonical.bind(state.canonical, cid, rootKind, rootEntity,
      bindingMetadata.decorate({
      owner = record.companyCid,
      private = true,
      proposalDigest = record.transaction.digest,
      outputSlot = construction.slot,
      upgraded = true,
    }, rootEntity, rootKind, state, world, record.companyCid, pending.guiDelta == nil))
    if not ok then return nil, bindError end
    state.world.logicalOwners[tostring(rootEntity)] = record.companyCid
    state.world.pinnedCustody[tostring(rootEntity)] = {
      cid = cid, kind = rootKind, logicalOwnerCid = record.companyCid,
      nativePlayerId = world.ownerOf(rootEntity) or record.nativeOwnerPlayerId,
      requestedPlayerId = state.companies[record.companyCid].playerId,
      reason = "canonical-construction-upgrade",
    }
    bound[#bound + 1] = {
      kind = rootKind, cid = cid, localId = rootEntity, slot = construction.slot,
    }
  end
  for _, descriptor in ipairs({
    { kind = "construction", values = delta.construction },
    { kind = "station", values = delta.station },
    { kind = "station_group", values = delta.station_group },
    { kind = "depot", values = delta.depot },
    { kind = "asset", values = delta.asset },
  }) do
    local values = {}
    for _, localId in ipairs(descriptor.values or {}) do
      if not (construction.mode == "upgrade" and descriptor.kind == rootKind
        and tonumber(localId) == rootEntity) then values[#values + 1] = localId end
    end
    local rows, rowsError = constructionOutputOrder.rows(descriptor.kind, values, {
      exact = pending.guiDelta ~= nil, proposalDigest = record.transaction.digest,
      fingerprint = world.fingerprint,
    })
    if not rows then return nil, rowsError end
    for index, row in ipairs(rows) do
      local localId = row.localId
      local slot = descriptor.kind .. ":" .. tostring(index)
      local cid = canonical.createdId(descriptor.kind, record.eventId, index)
      local expectedOutputTopology = descriptor.kind == "construction"
        and type(world.expectedConstructionTopologyFingerprint) == "function"
        and world.expectedConstructionTopologyFingerprint(
          construction, record.companyCid) or nil
      local capturedIdentity = pending.guiDelta
        and pending.guiDelta.identities
        and pending.guiDelta.identities[descriptor.kind]
        and pending.guiDelta.identities[descriptor.kind][tostring(localId)] or nil
      local portableFingerprint = capturedIdentity
        and capturedIdentity.fingerprint or nil
      local portableTopology = expectedOutputTopology
        or (capturedIdentity and capturedIdentity.topologyFingerprint) or nil
      local portableNeighbours = capturedIdentity
        and capturedIdentity.topologyNeighbourFingerprint or nil
      local ok, bindError = canonical.bind(state.canonical, cid, descriptor.kind, localId,
        bindingMetadata.decorate({
        owner = record.companyCid,
        private = true,
        proposalDigest = record.transaction.digest,
        outputSlot = slot,
        proposalOutputFingerprint = row.fingerprint,
        fingerprint = portableFingerprint,
        topologyFingerprint = portableTopology,
        topologyNeighbourFingerprint = portableNeighbours,
        topologyFingerprintVersion = portableTopology and 1 or nil,
        portableRebind = portableFingerprint ~= nil or portableTopology ~= nil,
        portableRebindUnavailable = portableFingerprint == nil
          and portableTopology == nil and pending.guiDelta ~= nil or nil,
        -- The GUI delta and proposal-derived fingerprint are authoritative for
        -- fresh outputs which the engine game-script state cannot safely read.
        nativeReadUnsafe = pending.guiDelta ~= nil,
      }, localId, descriptor.kind, state, world, record.companyCid,
        pending.guiDelta == nil))
      if not ok then return nil, bindError end
      state.world.logicalOwners[tostring(localId)] = record.companyCid
      state.world.pinnedCustody[tostring(localId)] = {
        cid = cid,
        kind = descriptor.kind,
        logicalOwnerCid = record.companyCid,
        nativePlayerId = pending.guiDelta and record.nativeOwnerPlayerId
          or world.ownerOf(localId) or record.nativeOwnerPlayerId,
        requestedPlayerId = state.companies[record.companyCid].playerId,
        reason = "canonical-construction-replay",
      }
      bound[#bound + 1] = {
        kind = descriptor.kind, cid = cid, localId = localId, slot = slot,
      }
    end
  end
  return bound
end

return M
