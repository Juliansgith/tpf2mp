local util = require "tpf2_mp/util"
local witness = require "tpf2_mp/aboard_milestone_witness"

local M = {}

function M.supports(actionType)
  return actionType == "freight.milestone" or actionType == "passenger.milestone"
end

function M.coalesce(items, action, state, log, count)
  local label = action.type == "passenger.milestone" and "passenger" or "freight"
  local normalised, validationError = witness.normalise(action, action.type, label)
  if not normalised then return false, validationError end
  action = normalised
  for index, pending in ipairs(items) do
    if pending.action and pending.action.type == action.type then
      if action.observedRound ~= nil then pending.action = util.deepCopy(action) end
      pending.updatedTick = state.tick
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

function M.insert(items, pending, actionType)
  if not M.supports(actionType) then
    items[#items + 1] = pending
    return #items
  end
  local position = 1
  while items[position] and M.supports(items[position].action
      and items[position].action.type) do position = position + 1 end
  table.insert(items, position, pending)
  return position
end

function M.priorityHead(items)
  local head = items[1]
  return head and M.supports(head.action and head.action.type) and head or nil
end

return M
