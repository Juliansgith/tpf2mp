local M = {}

function M.reject(action, pendingReason, state, queueDepth, diagnosticLog, publishSnapshot)
  if action.type ~= "proposal.capture" or action.queuePolicy ~= "reject-if-busy" then
    return false
  end
  local errorText = "previous multiplayer action is still synchronising; construction input was not queued"
  state.lastAction = { type = action.type, rejected = true, busy = true }
  state.lastResult = {
    queued = false, rejected = true, busy = true, reason = pendingReason,
  }
  state.lastError = errorText
  diagnosticLog("network-intent-busy-rejected", {
    type = action.type, companyCid = action.companyCid,
    reason = pendingReason, queueDepth = queueDepth, tick = state.tick,
  })
  publishSnapshot()
  return true, errorText
end

return M
