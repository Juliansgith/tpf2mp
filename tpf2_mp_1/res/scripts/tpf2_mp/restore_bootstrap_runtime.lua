local M = {}

function M.new(env)
  local getState = assert(env.getState, "restore bootstrap state provider is required")
  local config = assert(env.config, "restore bootstrap config provider is required")
  local submitIntent = assert(env.submitIntent, "restore bootstrap intent submitter is required")
  local awaitingOrder = assert(env.awaitingOrder, "restore bootstrap order provider is required")
  local pendingBarrierReason = assert(env.pendingBarrierReason,
    "restore bootstrap barrier provider is required")
  local diagnosticLog = assert(env.diagnosticLog, "restore bootstrap diagnostic is required")

  local function maintain(bootstrap)
    local state, cfg = getState(), config()
    if type(cfg.restoreResume) ~= "table" or cfg.restoreResume.requested ~= true then
      return false
    end
    local restore = state.recovery and state.recovery.restoreResume or nil
    if type(restore) ~= "table" or restore.status ~= "validated" then return true end
    if awaitingOrder() or pendingBarrierReason() then return true end
    local authority = state.probes.networkAuthority or {}
    if authority.ready ~= true then bootstrap.nextAttemptTick = state.tick + 30; return true end
    bootstrap.attempts = bootstrap.attempts + 1
    local ok, result = submitIntent({ type = "recovery.resume" })
    bootstrap.submitted = ok == true
    bootstrap.nextAttemptTick = state.tick + (ok and 600 or 60)
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
