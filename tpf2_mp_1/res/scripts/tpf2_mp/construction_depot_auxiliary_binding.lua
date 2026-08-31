local canonical = require "tpf2_mp/canonical"

local M = {}

-- The stock street-depot helper owns a short entrance edge which must remain
-- attached to the construction.  The canonical proposal edge is the appended
-- connector beyond it.  Bind that helper edge as an explicit derived output so
-- later structural probes cannot discover it as an unjournaled pre-existing
-- object and change the checkpoint digest between ordered events.
function M.apply(state, record, bound, ownerOf)
  if type(record) ~= "table" or record.replayPath ~= "helper-connected-depot" then
    return bound
  end
  local pending = record.constructionPending
  local repair = type(pending) == "table" and pending.depotConnectionRepair or nil
  local edgeIds = type(repair) == "table" and repair.helperEdgeIds or nil
  if type(edgeIds) ~= "table" or #edgeIds ~= 1 then
    return nil, "connected depot helper edge is unavailable for canonical binding"
  end
  local localId = tonumber(edgeIds[1])
  if not localId then return nil, "connected depot helper edge id is invalid" end
  if canonical.resolveCanonical(state.canonical, "edge", localId) then
    return nil, "connected depot helper edge was bound before proposal finalisation"
  end

  local slot = "edge:helper:1"
  local cid = canonical.createdId("edge", record.eventId .. ":helper", 1)
  local ok, bindError = canonical.bind(state.canonical, cid, "edge", localId, {
    owner = record.companyCid,
    carrier = "street",
    private = true,
    auxiliary = "construction-helper-entrance",
    proposalDigest = record.transaction.digest,
    outputSlot = slot,
  })
  if not ok then return nil, bindError end

  local key = tostring(localId)
  state.world.logicalOwners[key] = record.companyCid
  state.world.pinnedCustody[key] = {
    cid = cid,
    kind = "edge",
    logicalOwnerCid = record.companyCid,
    nativePlayerId = ownerOf(localId) or record.nativeOwnerPlayerId,
    requestedPlayerId = state.companies[record.companyCid].playerId,
    reason = "canonical-construction-helper-entrance",
  }
  bound[#bound + 1] = { kind = "edge", cid = cid, localId = localId, slot = slot }
  return bound
end

return M
