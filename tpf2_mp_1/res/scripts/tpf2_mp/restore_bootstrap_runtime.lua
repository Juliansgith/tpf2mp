local M = {}

function M.new(env)
  local getState = assert(env.getState, "restore bootstrap state provider is required")
  local config = assert(env.config, "restore bootstrap config provider is required")
  local submitIntent = assert(env.submitIntent, "restore bootstrap intent submitter is required")
  local awaitingOrder = assert(env.awaitingOrder, "restore bootstrap order provider is required")
  local pendingBarrierReason = assert(env.pendingBarrierReason,
    "restore bootstrap barrier provider is required")
  local diagnosticLog = assert(env.diagnosticLog, "restore bootstrap diagnostic is required")
  local wallTime = env.wallTime or function()
    local ok, value = pcall(function() return os.time() end)
    return ok and tonumber(value) or nil
  end

  local function maintain(bootstrap)
    local state, cfg = getState(), config()
    if type(cfg.restoreResume) ~= "table" or cfg.restoreResume.requested ~= true then
      return false
    end
    local restore = state.recovery and state.recovery.restoreResume or nil
    if type(restore) ~= "table" or restore.status ~= "validated" then return true end
    local now = tonumber(wallTime())
    if bootstrap.submitted == true then return true end
    if now and now < tonumber(bootstrap.restoreNextAttemptAt or 0) then return true end
    if awaitingOrder() or pendingBarrierReason() then return true end
    local authority = state.probes.networkAuthority or {}
    if authority.ready ~= true then
      bootstrap.restoreNextAttemptAt = now and now + 1 or nil
      return true
    end
    bootstrap.attempts = bootstrap.attempts + 1
    local ok, result = submitIntent({ type = "recovery.resume" })
    bootstrap.submitted = ok == true
    bootstrap.restoreNextAttemptAt = now and now + (ok and 30 or 1) or nil
    diagnosticLog("manual-network-restore", {
      success = ok == true, attempt = bootstrap.attempts,
      localSeq = type(result) == "table" and (result.local_seq or result.localSeq) or nil,
      error = not ok and tostring(type(result) == "table" and result.error or result) or nil,
      tick = state.tick,
    })
    return true
  end

  return { maintain = maintain }
end

return M
