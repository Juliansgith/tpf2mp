local proposalResultCapture = require "tpf2_mp/gui_proposal_result_capture"

local M = {}

local function outputIdentity(world, kind, id, ownerCid)
  return {
    fingerprint = world.fingerprint(id, kind, { componentOnly = true }),
    topologyFingerprint = world.topologyFingerprint(id, kind, {
      ownerCid = ownerCid,
    }),
    topologyNeighbourFingerprint = world.topologyNeighbourFingerprint(id, kind, {
      ownerCid = ownerCid,
    }),
  }
end

-- Settle at most one pending capture per GUI update. The queue owns delayed
-- native-result failure projection; the sampler remains a pure single-record
-- state transition.
function M.takeSettled(pendingCaptures, frame, deps)
  deps.captureOutputIdentity = function(kind, id, ownerCid)
    return outputIdentity(deps.world, kind, id, ownerCid)
  end
  for index = #pendingCaptures, 1, -1 do
    local pending = pendingCaptures[index]
    local payload, captureError = proposalResultCapture.sample(pending, frame, deps)
    if captureError then
      payload = { proposalId = pending.proposalId, success = false,
        error = captureError, worldUnchanged = false }
    end
    if payload then
      table.remove(pendingCaptures, index)
      return payload
    end
  end
  return nil
end

return M
