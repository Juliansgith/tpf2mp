local M = {}

function M.due(state, cfg, bootstrap)
  if state.networkMode ~= "network" or state.bridge.peerId ~= "player1" then return false end
  if type(cfg.restoreResume) == "table" and cfg.restoreResume.requested == true then
    local restore = state.recovery and state.recovery.restoreResume or nil
    return type(restore) == "table" and restore.status == "validated"
      and bootstrap.submitted ~= true
  end
  local ready = cfg.manualBootstrapReady == true or bootstrap.launcherReady == true
  return cfg.manualNetwork == true and ready and state.initialized ~= true
    and state.tick >= math.max(240, tonumber(bootstrap.nextAttemptTick) or 240)
end

return M
