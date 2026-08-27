local constructionDeltaAttestation = require "tpf2_mp/construction_delta_attestation"

local M = {}

-- Network consensus owns the signed construction cost. Allow twice the longest
-- observed native-journal delay before using it, while retaining the historical
-- hard deadline for unavailable or continuously changing wallet samples.
M.NETWORK_FINANCE_GRACE_FRAMES = 90
M.HARD_DEADLINE_FRAMES = 360

function M.sample(pending, frame, deps)
  if frame < pending.minimumFrame then return nil end
  local issuerBalance = deps.balanceOf(pending.issuerPlayerId)
  local nativeOwnerBalance = deps.balanceOf(pending.nativeOwnerPlayerId)
  local balanceMutationObserved = issuerBalance ~= pending.issuerBalanceBefore
    or nativeOwnerBalance ~= pending.nativeOwnerBalanceBefore
  if issuerBalance == pending.lastIssuerBalance
    and nativeOwnerBalance == pending.lastNativeOwnerBalance then
    pending.stableFrames = pending.stableFrames + 1
  else
    pending.lastIssuerBalance, pending.lastNativeOwnerBalance = issuerBalance, nativeOwnerBalance
    pending.stableFrames = 0
  end
  local stable = pending.stableFrames >= 3
  local mutationReady = not pending.requireBalanceMutation or balanceMutationObserved
  local fallbackFrame = tonumber(pending.canonicalFinanceFallbackFrame)
  local canonicalFallbackReady = pending.requireBalanceMutation
    and issuerBalance ~= nil and nativeOwnerBalance ~= nil
    and fallbackFrame ~= nil and frame >= fallbackFrame
  local hardDeadlineReached = frame >= pending.maximumFrame
  if not (stable and (mutationReady or canonicalFallbackReady))
    and not hardDeadlineReached then return nil end

  local constructionDelta
  if pending.captureEntityDelta or pending.exactConstruction then
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
    financeMutationObserved = balanceMutationObserved,
    financeFallbackUsed = stable and canonicalFallbackReady
      and not balanceMutationObserved,
    financeHardDeadlineUsed = hardDeadlineReached
      and not (stable and (mutationReady or canonicalFallbackReady)),
    settlementFrames = math.max(0,
      frame - (tonumber(pending.captureStartedFrame) or frame)),
  }
end

return M
