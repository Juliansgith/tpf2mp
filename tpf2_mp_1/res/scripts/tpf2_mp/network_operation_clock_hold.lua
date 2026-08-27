local util = require "tpf2_mp/util"
local M = {}

function M.new(deps)
  local getState = assert(deps.getState, "operation clock hold requires state")
  local localWorkState = assert(deps.localWorkState,
    "operation clock hold requires local work state")
  local submitIntent = assert(deps.submitIntent, "operation clock hold requires submitIntent")
  local diagnosticLog = assert(deps.diagnosticLog,
    "operation clock hold requires diagnostic logging")
  local clockSnapshot = assert(deps.clockSnapshot,
    "operation clock hold requires native clock snapshots")
  local hold, submittingResume = nil, false
  local runtime = {}

  local function publish(value)
    local state = getState()
    state.probes = type(state.probes) == "table" and state.probes or {}
    state.probes.networkOperationClockHold = value and util.deepCopy(value) or nil
  end

  local function reasonContinues(reason, prefix)
    reason, prefix = tostring(reason or ""), tostring(prefix or "")
    return prefix ~= "" and reason:sub(1, #prefix) == prefix
  end

  local function cancel(status, action)
    if not hold then return false end
    local state, cancelled = getState(), util.deepCopy(hold)
    cancelled.status = tostring(status or "cancelled")
    cancelled.cancelledTick = state.tick
    cancelled.cancelledSpeed = util.integer(action and action.requestedSpeed, -1)
    cancelled.cancelledReason = tostring(action and action.reason or "")
    publish(cancelled)
    hold = nil
    return true
  end

  function runtime.observeOrderedClock(action)
    if not hold or type(action) ~= "table" then return end
    local state = getState()
    local requested = util.integer(action.requestedSpeed, -1)
    local generation = util.integer(action.generation, -1)
    if hold.status == "pause-requested"
      and requested == 0 and generation > hold.armedGeneration then
      hold.pauseGeneration = generation
      hold.pauseReason = tostring(action.reason or "")
      hold.status = action.type == "clock.rendezvous" and "pause-rendezvous" or "paused"
      publish(hold)
      return
    end
    if hold.status == "pause-rendezvous"
      and action.type == "clock.rendezvous" and requested == 0
      and generation > util.integer(hold.pauseGeneration, -1)
      and reasonContinues(action.reason, hold.pauseReason) then
      hold.pauseGeneration = generation
      hold.pauseReason = tostring(action.reason or hold.pauseReason)
      publish(hold)
      return
    end
    if hold.status == "pause-rendezvous"
      and action.type == "clock.set" and requested == 0
      and generation > util.integer(hold.pauseGeneration, -1)
      and reasonContinues(action.reason, hold.pauseReason) then
      hold.pauseGeneration, hold.status = generation, "paused"
      publish(hold)
      return
    end
    if hold.status == "resume-requested" and requested == hold.resumeSpeed then
      hold.resumeGeneration = generation
      hold.resumeReason = tostring(action.reason or "")
      hold.status = action.type == "clock.rendezvous" and "resume-rendezvous" or "complete"
      publish(hold)
      if hold.status == "complete" then hold = nil end
      return
    end
    if hold.status == "resume-rendezvous"
      and action.type == "clock.rendezvous" and requested == hold.resumeSpeed
      and generation > util.integer(hold.resumeGeneration, -1)
      and reasonContinues(action.reason, hold.resumeReason) then
      hold.resumeGeneration = generation
      hold.resumeReason = tostring(action.reason or hold.resumeReason)
      publish(hold)
      return
    end
    if hold.status == "resume-rendezvous"
      and action.type == "clock.set" and requested == hold.resumeSpeed
      and generation > util.integer(hold.resumeGeneration, -1)
      and reasonContinues(action.reason, hold.resumeReason) then
      local complete = util.deepCopy(hold)
      complete.status, complete.completedTick = "complete", state.tick
      complete.completedGeneration = generation
      publish(complete)
      hold = nil
      return
    end
    local boundary = util.integer(hold.pauseGeneration, hold.armedGeneration)
    if generation > boundary then cancel("cancelled-by-ordered-clock-request", action) end
  end

  function runtime.prerequisite(action)
    local state = getState()
    local transaction = type(action) == "table" and action.transaction or nil
    local kind = type(transaction) == "table" and tostring(transaction.kind or "") or ""
    if state.networkMode ~= "network" or action.type ~= "operation.execute"
      or (not kind:match("^vehicle%.") and not kind:match("^line%.")) then return nil end
    local clock = state.world.networkClock
    if type(clock.rendezvous) == "table" then return nil end
    local observed = clockSnapshot()
    if util.integer(clock.effectiveSpeed, 0) <= 0
      and (tonumber(observed.gameSpeed) or 0) <= 0 then return nil end
    local resumeSpeed = math.max(1, math.min(4,
      util.integer(clock.requestedSpeed, util.integer(observed.gameSpeed, 1))))
    hold = {
      status = "pause-requested", resumeSpeed = resumeSpeed,
      armedGeneration = util.integer(clock.generation, 0), armedTick = state.tick,
      operationKind = kind,
    }
    publish(hold)
    return { type = "clock.request", requestedSpeed = 0 },
      "line/vehicle operation is waiting for a shared-clock rendezvous"
  end

  function runtime.prerequisiteResult(_, success, result)
    if not hold or success == true then return end
    hold.status = "pause-request-failed"
    hold.error = tostring(type(result) == "table" and result.error or result)
    publish(hold)
    hold = nil
  end

  function runtime.noteClockRequest(action)
    if submittingResume or not hold or type(action) ~= "table"
      or action.type ~= "clock.request" then return false end
    return cancel("cancelled-by-player-clock-request", action)
  end

  function runtime.maintain()
    local state = getState()
    if not hold or state.networkMode ~= "network" then return false end
    local clock = state.world.networkClock or {}
    if hold.status == "resume-requested" or hold.status == "resume-rendezvous" then
      if type(clock.rendezvous) ~= "table" and util.integer(clock.effectiveSpeed, 0) > 0 then
        local complete = util.deepCopy(hold)
        complete.status, complete.completedTick = "complete", state.tick
        complete.completedGeneration = util.integer(clock.generation, 0)
        publish(complete)
        hold = nil
        return true
      end
      return false
    end
    if type(clock.rendezvous) == "table"
      or util.integer(clock.effectiveSpeed, -1) ~= 0 then return false end
    local work = localWorkState()
    if type(work) == "table" and work.pending == true then return false end
    hold.status, hold.resumeTick = "submitting-resume", state.tick
    publish(hold)
    submittingResume = true
    local ok, result = submitIntent({ type = "clock.request", requestedSpeed = hold.resumeSpeed })
    submittingResume = false
    if ok == true then
      hold.status = "resume-requested"
      hold.resumeLocalSeq = type(result) == "table"
        and (result.local_seq or result.localSeq) or nil
      publish(hold)
      diagnosticLog("network-operation-clock-auto-resume", {
        resumeSpeed = hold.resumeSpeed, operationKind = hold.operationKind,
        localSeq = hold.resumeLocalSeq, tick = state.tick,
      })
      return true
    end
    hold.status = "resume-retry"
    hold.error = tostring(type(result) == "table" and result.error or result)
    publish(hold)
    return false
  end

  function runtime.has() return hold ~= nil end
  function runtime.reset() hold, submittingResume = nil, false; publish(nil) end
  return runtime
end

return M
