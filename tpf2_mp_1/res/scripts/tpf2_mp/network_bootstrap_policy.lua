local M = {}

function M.contentReady(state)
  local content = type(state) == "table" and state.world and state.world.industryContent or nil
  return type(content) == "table" and content.ready == true
    and type(content.digest) == "string" and content.digest ~= ""
end

function M.deferForContent(state, bootstrap, diagnosticLog)
  if M.contentReady(state) then bootstrap.waitingFor = nil; return false end
  if bootstrap.waitingFor ~= "industry-content-consensus" then
    bootstrap.waitingFor = "industry-content-consensus"
    diagnosticLog("manual-network-bootstrap-deferred",
      { reason = bootstrap.waitingFor, tick = state.tick })
  end
  return true
end

function M.due(state, cfg, bootstrap)
  if state.networkMode ~= "network" or state.bridge.peerId ~= "player1" then return false end
  if type(cfg.restoreResume) == "table" and cfg.restoreResume.requested == true then
    local restore = state.recovery and state.recovery.restoreResume or nil
    return type(restore) == "table" and restore.status == "validated" and bootstrap.submitted ~= true
  end
  if cfg.continueSavedMatch == true then
    local continuation = state.recovery and state.recovery.savedMatchContinuation or nil
    return type(continuation) == "table" and continuation.status == "validated" and bootstrap.savedMatchSubmitted ~= true
  end
  local ready = cfg.manualBootstrapReady == true or bootstrap.launcherReady == true
  return cfg.manualNetwork == true and ready and M.contentReady(state) and state.initialized ~= true
    and state.tick >= math.max(240, tonumber(bootstrap.nextAttemptTick) or 240)
end

return M
