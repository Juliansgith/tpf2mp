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

  local function prepare(action, _, commitSeq)
    local state = getState()
    if state.networkMode ~= "network" or not commitSeq then
      return false, "restore point preparation requires an ordered network session"
    end
    state.recovery.anchorPreparation = {
      status = "requested", preparationSeq = commitSeq, tick = state.tick,
      automatic = action and action.automatic == true or nil,
    }
    return true, util.deepCopy(state.recovery.anchorPreparation)
  end

  local function checkpointRequest(action, _, commitSeq)
    local state = getState()
    local previous = state.recovery.anchorPreparation
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
      automatic = type(previous) == "table" and previous.automatic == true or nil,
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

  local function cancel(action, _, commitSeq)
    local state = getState()
    local preparationSeq = util.integer(action and action.preparationSeq, 0)
    local errorCode = tostring(action and action.errorCode or "")
    local preparation = state.recovery and state.recovery.anchorPreparation
    if state.networkMode ~= "network" or not commitSeq or preparationSeq < 1
      or errorCode == "" or #errorCode > 512 then
      return false, "invalid host restore-point cancellation"
    end
    if type(preparation) == "table"
      and util.integer(preparation.preparationSeq, -1) == preparationSeq then
      preparation.status = "failed"
      preparation.errorCode = errorCode
      preparation.outcomeTick = state.tick
    end
    return true, { cancelled = true, preparationSeq = preparationSeq }
  end

  return {
    manualCheckpoint = manualCheckpoint,
    prepare = prepare,
    checkpointRequest = checkpointRequest,
    checkpointOutcome = checkpointOutcome,
    cancel = cancel,
  }
end

return M
