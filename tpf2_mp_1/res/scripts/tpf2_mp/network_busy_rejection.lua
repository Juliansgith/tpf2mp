local M = {}

-- Raw proposal captures contain process-local native IDs. They may never wait
-- behind another physical action: that action can replace precisely the edge
-- or construction those IDs describe. A rejected click is recoverable; a
-- delayed snapshot can poison prepared StreetGeometry before it is detected.
function M.handle(action, pendingReason, state, queue, maximum, diagnosticLog, publishSnapshot)
  if action.type ~= "proposal.capture" then return false end
  local errorText = "previous multiplayer action is still synchronising; build input was not queued"
  state.lastAction = { type = action.type, rejected = true, busy = true }
  state.lastResult = {
    queued = false, rejected = true, busy = true,
    reason = pendingReason, queueDepth = #queue,
  }
  state.lastError = errorText
  diagnosticLog("network-intent-busy-rejected", {
    type = action.type, companyCid = action.companyCid,
    reason = pendingReason, queueDepth = #queue,
    queueCapacity = maximum, tick = state.tick,
  })
  publishSnapshot()
  return true, false, errorText
end

return M
