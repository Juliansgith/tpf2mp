local policy = require "tpf2_mp/construction_replay_policy"

local M = {}

local function prime(record, pending, before, tick, timeoutTicks, firstVerifyDelayTicks)
  if type(pending) ~= "table" or pending.phase ~= "clearing-collateral" then
    return nil, "collateral construction replay state is unavailable"
  end
  if type(before) ~= "table" then
    return nil, "post-collateral construction snapshot is unavailable"
  end
  pending.before = before
  pending.beforeFingerprints = {}
  pending.guiDelta = nil
  pending.rootEntity = nil
  pending.phase = "awaiting-gui-build"
  pending.startedTick = tick
  pending.deadlineTick = tick + timeoutTicks
  pending.stableSinceTick = nil
  pending.lastSignature = nil
  pending.lastReadySignature = nil
  pending.nextVerificationTick = tick + firstVerifyDelayTicks
  pending.verificationScans = 0
  record.replayPath = "staged-gui-build-proposal"
  record.status = "queued"
  return { stagedGuiBuild = true, proposalId = record.proposalId }
end

function M.stage(record, pending, deps)
  local before, captureError = deps.verification.snapshot()
  if not before then return nil, tostring(captureError) end
  local staged, stageError = prime(
    record, pending, before, deps.tick, deps.timeoutTicks, deps.firstVerifyDelayTicks)
  if not staged then return nil, stageError end
  deps.proposals.queued = (deps.proposals.queued or 0) + 1
  return staged
end

function M.advance(record, pending, deps)
  local collateralInputs, inputError = policy.collateralInputs(record)
  if not collateralInputs then return nil, tostring(inputError) end
  local count, kinds, verificationError =
    deps.verification.inputsPendingOrSnapshot(collateralInputs)
  if count == nil then return nil, tostring(verificationError) end
  if count > 0 then
    if deps.tick < pending.deadlineTick then
      pending.nextVerificationTick = deps.tick + deps.pendingRescanTicks
      return {
        waiting = true, phase = pending.phase,
        pendingRemovalInputs = count, pendingRemovalKinds = kinds,
      }
    end
    return nil, {
      error = "construction collateral did not retire before the build deadline",
      pendingRemovalInputs = count, pendingRemovalKinds = kinds,
    }
  end
  if policy.isStagedExact(record, deps.codec) then return M.stage(record, pending, deps) end
  return { readyForHelper = true }
end

return M
