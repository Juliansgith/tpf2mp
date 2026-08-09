local M = {}

function M.coalesce(items, action, state, log, count)
  if action.stage ~= "aboard" or type(action.lineCid) ~= "string"
    or type(action.vehicleCid) ~= "string" then
    return false, "aboard milestone follow-up is malformed"
  end
  for index, pending in ipairs(items) do
    if pending.action and pending.action.type == action.type then
      pending.coalesced = (pending.coalesced or 0) + 1
      log("network-followup-coalesced", {
        type = action.type, queuePosition = index,
        coalesced = pending.coalesced, tick = state.tick,
      })
      return true, {
        queued = true, deferred = true, coalesced = true,
        queuePosition = index, queueDepth = count(),
      }
    end
  end
  return nil
end

return M
