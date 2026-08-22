local constructionDeltaAttestation = require "tpf2_mp/construction_delta_attestation"

local M = {}

function M.sample(pending, frame, deps)
  if frame < pending.minimumFrame then return nil end
  local issuerBalance = deps.balanceOf(pending.issuerPlayerId)
  local nativeOwnerBalance = deps.balanceOf(pending.nativeOwnerPlayerId)
  local balanceMutationReady = not pending.requireBalanceMutation
    or issuerBalance ~= pending.issuerBalanceBefore
    or nativeOwnerBalance ~= pending.nativeOwnerBalanceBefore
  if balanceMutationReady and issuerBalance == pending.lastIssuerBalance
    and nativeOwnerBalance == pending.lastNativeOwnerBalance then
    pending.stableFrames = pending.stableFrames + 1
  else
    pending.lastIssuerBalance, pending.lastNativeOwnerBalance = issuerBalance, nativeOwnerBalance
    pending.stableFrames = 0
  end
  if pending.stableFrames < 3 and frame < pending.maximumFrame then return nil end

  local constructionDelta
  if pending.exactConstruction then
    local afterWorld, captureError = deps.captureWorld(
      deps.componentTypes(), pending.issuerPlayerId, pending.nativeOwnerPlayerId, true)
    if not afterWorld then return nil, tostring(captureError) end
    constructionDelta = constructionDeltaAttestation.encode(
      constructionDeltaAttestation.fromWorlds(pending.beforeWorld, afterWorld))
  end
  return {
    proposalId = pending.proposalId, success = true,
    createdEdgeIds = pending.createdEdgeIds, createdNodeIds = pending.createdNodeIds,
    issuerBalanceBefore = pending.issuerBalanceBefore, issuerBalanceAfter = issuerBalance,
    nativeOwnerBalanceBefore = pending.nativeOwnerBalanceBefore,
    nativeOwnerBalanceAfter = nativeOwnerBalance, constructionDelta = constructionDelta,
  }
end

return M
