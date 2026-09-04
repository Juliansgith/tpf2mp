local M = {}

-- Every canonical output binding records the same portable native identity.
-- Keep that policy in one place so construction, edge, and child-output paths
-- cannot quietly acquire different recovery semantics.
function M.decorate(metadata, localId, kind, state, world, ownerCid, enabled)
  if enabled == false then return metadata end
  if metadata.fingerprint == nil then
    metadata.fingerprint = world.fingerprint(localId, kind)
  end
  local context = {
    registry = state.canonical, worldState = state.world, ownerCid = ownerCid,
  }
  metadata.topologyFingerprint = world.topologyFingerprint(localId, kind, context)
  metadata.topologyNeighbourFingerprint =
    world.topologyNeighbourFingerprint(localId, kind, context)
  return metadata
end

return M
