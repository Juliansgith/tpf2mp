local util = require "tpf2_mp/util"
local M = {}

local function result(state, action, pendingReason, queue, position, replaced)
  local value = {
    queued = true, deferred = true, busy = true,
    coalescedConstruction = true, replaced = replaced == true,
    queuedTick = state.tick, reason = pendingReason,
    queuePosition = position, queueDepth = #queue,
  }
  state.lastAction = {
    type = action.type, deferred = true,
    coalescedConstruction = true, replaced = replaced == true,
    queuePosition = position,
  }
  state.lastResult, state.lastError = value, nil
  return value
end

-- Construction clicks are not ordinary FIFO work. Keeping every click made
-- while a prior build settles caused old station ghosts to appear seconds
-- later; rejecting all of them made a legitimate terminal click disappear.
-- Keep one visible lane and move its newest value to the physical queue tail.
function M.handle(action, pendingReason, state, queue, maximum, diagnosticLog, publishSnapshot)
  if action.type ~= "proposal.capture" then return false end
  if action.queuePolicy == "reject-if-busy" then
    local errorText = "previous multiplayer action is still synchronising; construction input was not queued"
    state.lastAction = { type = action.type, rejected = true, busy = true }
    state.lastResult = { queued = false, rejected = true, busy = true, reason = pendingReason }
    state.lastError = errorText
    diagnosticLog("network-intent-busy-rejected", {
      type = action.type, companyCid = action.companyCid,
      reason = pendingReason, queueDepth = #queue, tick = state.tick,
    })
    publishSnapshot()
    return true, false, errorText
  end
  if action.queuePolicy ~= "coalesce-latest-construction" then return false end
  local replaced
  for index = #queue, 1, -1 do
    local queued = queue[index].action or {}
    if queued.type == "proposal.capture"
      and queued.queuePolicy == action.queuePolicy then
      replaced = table.remove(queue, index)
      break
    end
  end
  if not replaced and #queue >= maximum then
    local errorText = "multiplayer deferred-action queue is full; construction input was not queued"
    state.lastAction = { type = action.type, rejected = true, busy = true }
    state.lastResult = {
      queued = false, rejected = true, busy = true,
      reason = pendingReason, queueDepth = #queue,
    }
    state.lastError = errorText
    diagnosticLog("network-construction-deferred-full", {
      type = action.type, companyCid = action.companyCid,
      reason = pendingReason, queueDepth = #queue,
      queueCapacity = maximum, tick = state.tick,
    })
    publishSnapshot()
    return true, false, errorText
  end
  queue[#queue + 1] = {
    action = util.deepCopy(action), companyCid = action.companyCid,
    queuedTick = state.tick, reason = pendingReason,
  }
  local value = result(state, action, pendingReason, queue, #queue, replaced ~= nil)
  diagnosticLog(replaced and "network-construction-deferred-replaced"
      or "network-construction-deferred", {
    type = action.type, companyCid = action.companyCid,
    reason = pendingReason, queueDepth = #queue,
    replacedQueuedTick = replaced and replaced.queuedTick or nil,
    queueCapacity = maximum, tick = state.tick,
  })
  publishSnapshot()
  return true, true, util.deepCopy(value)
end

return M
