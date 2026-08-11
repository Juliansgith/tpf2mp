local util = require "tpf2_mp/util"
local recoveryPhaseProof = require "tpf2_mp/recovery_phase_proof"

local M = {}

function M.new(env)
  local getState = assert(env.getState, "recovery preparation state provider is required")
  local emitCheckpoint = assert(env.emitCheckpoint, "checkpoint emitter is required")
  local exportCheckpointBarrier = assert(env.exportCheckpointBarrier,
    "checkpoint barrier exporter is required")

  local function manualCheckpoint(action)
    local state = getState()
    local reason = action and action.reason or "manual"
    if state.networkMode == "network" and reason == "manual-ui" then
      return exportCheckpointBarrier(math.max(1, (state.bridge.nextInSeq or 1) - 1), reason)
    end
    return emitCheckpoint(reason)
  end

  local function prepare(_, _, commitSeq)
    local state = getState()
    if state.networkMode ~= "network" or not commitSeq then
      return false, "restore point preparation requires an ordered network session"
    end
    state.recovery.anchorPreparation = {
      status = "requested", preparationSeq = commitSeq, tick = state.tick,
    }
    return true, util.deepCopy(state.recovery.anchorPreparation)
  end

  local function checkpointRequest(action, _, commitSeq)
    local state = getState()
    local preparationSeq = util.integer(action and action.preparationSeq, 0)
    local reason = tostring(action and action.reason or "")
    local phaseProof, phaseError = recoveryPhaseProof.normalise(
      action and action.vehiclePhaseProof)
    if state.networkMode ~= "network" or not commitSeq or preparationSeq < 1
      or reason ~= "recovery-prepare:" .. tostring(preparationSeq) or not phaseProof then
      return false, phaseError or "invalid host restore-point checkpoint request"
    end
    state.recovery.anchorPreparation = {
      status = "checkpointing", preparationSeq = preparationSeq,
      boundarySeq = commitSeq, tick = state.tick,
      vehiclePhaseProof = phaseProof,
    }
    return exportCheckpointBarrier(commitSeq, reason)
  end

  local function checkpointOutcome(action, success, record)
    local state = getState()
    local preparation = state.recovery.anchorPreparation
    if type(preparation) == "table"
      and util.integer(preparation.boundarySeq, 0) == util.integer(action and action.boundarySeq, -1)
      and tostring(record and record.reason or ""):match("^recovery%-prepare:%d+$") then
      preparation.status = success and "ready" or "failed"
      preparation.errorCode = not success
        and tostring(record.errorCode or "checkpoint-consensus-failed") or nil
      preparation.outcomeTick = state.tick
    end
  end

  return {
    manualCheckpoint = manualCheckpoint,
    prepare = prepare,
    checkpointRequest = checkpointRequest,
    checkpointOutcome = checkpointOutcome,
  }
end

return M
