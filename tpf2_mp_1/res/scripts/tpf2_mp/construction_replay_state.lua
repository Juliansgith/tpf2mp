local util = require "tpf2_mp/util"
local constructionDeltaAttestation = require "tpf2_mp/construction_delta_attestation"
local constructionReplayPolicy = require "tpf2_mp/construction_replay_policy"
local constructionCollateralReplay = require "tpf2_mp/construction_collateral_replay"
local constructionModuleHydration = require "tpf2_mp/construction_module_hydration"

local M = {
  isExact = constructionReplayPolicy.isExact,
  isStagedExact = constructionReplayPolicy.isStagedExact,
  isGuiExact = constructionReplayPolicy.isGuiExact,
  guiOwns = constructionReplayPolicy.guiOwns,
  requiresAtomic = constructionReplayPolicy.requiresAtomic,
  hasExistingStreetEndpoint = constructionReplayPolicy.connection.hasExistingStreetEndpoint,
  isConnectedStreetDepot = constructionReplayPolicy.connection.isConnectedStreetDepot,
  collateralInputs = constructionReplayPolicy.collateralInputs,
  stageAfterCollateral = constructionCollateralReplay.stage,
  advanceCollateral = constructionCollateralReplay.advance,
}

function M.prepare(record, deps)
  local spec, specError = deps.codec.materialiseConstruction(record.transaction); local helperSafe, helperError = constructionReplayPolicy.helperSafe(record)
  if not spec or not helperSafe then return nil, tostring(specError or helperError) end
  local before, captureError = deps.verification.snapshot()
  if not before then return nil, tostring(captureError) end
  local beforeFingerprints = {}
  if spec.mode == "upgrade" then
    beforeFingerprints = deps.verification.captureUpgradeFingerprints(
      before, spec, deps.fingerprint)
  end
  return {
    rootEntity = nil,
    sourceRootEntity = spec.mode ~= "build" and tonumber(
      record.localRefs and record.localRefs[spec.sourceCid]) or nil,
    spec = util.deepCopy(spec),
    before = before,
    beforeFingerprints = beforeFingerprints,
    startedTick = deps.tick,
    deadlineTick = deps.tick + deps.timeoutTicks,
    stableSinceTick = nil,
    lastSignature = nil,
    lastReadySignature = nil,
    nextVerificationTick = deps.tick + deps.firstVerifyDelayTicks,
    verificationScans = 0,
  }
end

function M.preflightModules(record, pending, deps)
  if not constructionReplayPolicy.isStagedExact(record, deps.codec) then return true end
  local params = util.deepCopy(pending and pending.spec and pending.spec.params or {})
  return constructionModuleHydration.apply(params, deps.api)
end

function M.prime(record, pending)
  pending.phase = "awaiting-gui-build"
  record.constructionPending = pending
  record.replayPath = "gui-build-proposal"
end

function M.fallback(record)
  record.constructionPending = nil
  record.replayPath = "helper-fallback"
  record.status = "queued"
  return { helperFallback = true, proposalId = record.proposalId }
end

function M.accept(record, payload, tick, firstVerifyDelayTicks, maximumOutputs)
  local pending = record.constructionPending
  if type(pending) ~= "table" or pending.phase ~= "awaiting-gui-build" then
    return nil, "exact construction replay state is unavailable"
  end
  pending.phase = "settling-gui-build"
  local delta, deltaError = constructionDeltaAttestation.normalise(
    payload.constructionDelta, maximumOutputs)
  if not delta then return nil, deltaError end
  pending.guiDelta = delta
  if pending.spec.mode ~= "build" then pending.rootEntity = pending.sourceRootEntity end
  pending.nextVerificationTick = tick + firstVerifyDelayTicks
  record.status = "building-construction"
  return { constructionVerificationPending = true, guiAttested = true,
    proposalId = record.proposalId }
end

function M.identifyBuiltRoot(pending, added, rootKind)
  if pending.spec.mode == "build" and pending.rootEntity == nil
    and #(added[rootKind] or {}) == 1 then pending.rootEntity = added[rootKind][1] end
end

return M
