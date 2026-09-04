local util = require "tpf2_mp/util"
local resultError = require "tpf2_mp/result_error"

local M = {}
local FULL_SAMPLE_EVERY = 10

local ORDERED_PROBES = {
  ["probe.mobility"] = true,
  ["probe.structural"] = true,
  ["probe.native_fingerprint"] = true,
}

function M.refresh(state, world, fullInventory)
  state.probes.nativeFingerprint = world.nativeFingerprint(
    state.canonical, state.world, state.companies, {
      fullInventory = fullInventory == true,
    })
  return state.probes.nativeFingerprint
end

function M.isOrderedProbe(actionType)
  return ORDERED_PROBES[actionType] == true
end

function M.normaliseOrderedProbe(action, state)
  if state.bridge.peerId ~= "player1" then
    return nil, "only the host peer can request an ordered native-world sample"
  end
  for key in pairs(action) do
    if key ~= "type" then
      return nil, tostring(action.type) .. " has an unknown field: " .. tostring(key)
    end
  end
  return { type = action.type }
end

function M.new(deps)
  local getState = assert(deps.getState, "state accessor is required")
  local submitIntent = assert(deps.submitIntent, "intent submitter is required")
  local exportCheckpoint = assert(deps.exportCheckpoint, "checkpoint exporter is required")
  local diagnosticLog = assert(deps.diagnosticLog, "diagnostic logger is required")

  local function maintain(cfg)
    local state = getState()
    if state.networkMode ~= "network" or state.bridge.peerId ~= "player1"
      or state.initialized ~= true or state.match.status ~= "running" then return false end
    local interval = tonumber(cfg and cfg.nativeFingerprintTicks) or 1800
    state.probes.nativeFingerprintScheduler = state.probes.nativeFingerprintScheduler or {
      nextTick = state.tick + interval, submitted = 0, deferred = 0, lastError = nil,
    }
    local scheduler = state.probes.nativeFingerprintScheduler
    if state.tick < util.integer(scheduler.nextTick, interval) then return false end
    local nextSubmission = (scheduler.submitted or 0) + 1
    local probeType = nextSubmission % FULL_SAMPLE_EVERY == 0
      and "probe.structural" or "probe.native_fingerprint"
    local submitted, submitResult = submitIntent({ type = probeType })
    if submitted then
      scheduler.submitted = (scheduler.submitted or 0) + 1
      scheduler.lastError = nil
      scheduler.nextTick = state.tick + interval
    else
      scheduler.deferred = (scheduler.deferred or 0) + 1
      scheduler.lastError = resultError.text(submitResult)
      scheduler.nextTick = state.tick + math.min(120, interval)
    end
    return submitted == true
  end

  local function afterCommit(action, success, authoritySeq)
    if success ~= true or not authoritySeq
      or (action.type ~= "probe.structural"
        and action.type ~= "probe.native_fingerprint") then return false end
    local reason = action.type == "probe.structural"
      and "structural-probe" or "native-fingerprint-probe"
    local checkpointed, checkpointError = exportCheckpoint(authoritySeq, reason)
    if not checkpointed then
      diagnosticLog("checkpoint-barrier-error", {
        tick = getState().tick, boundarySeq = authoritySeq,
        error = tostring(checkpointError),
      })
    end
    return true
  end

  return { maintain = maintain, afterCommit = afterCommit,
    fullSampleEvery = FULL_SAMPLE_EVERY }
end

return M
