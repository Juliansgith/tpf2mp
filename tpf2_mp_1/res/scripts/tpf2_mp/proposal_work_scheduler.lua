local util = require "tpf2_mp/util"
local M = {}

function M.hasDueFinance(state, workIndex)
  for _, recordId in ipairs(workIndex.candidates(state.world.proposals)) do
    local record = state.world.proposals.byId[recordId]
    local pending = type(record) == "table" and record.pendingFinance or nil
    if type(pending) == "table"
      and state.tick >= util.integer(pending.earliestTick or pending.dueTick, state.tick) then
      return true
    end
  end
  return false
end

function M.hasDueConstruction(state, workIndex)
  for _, recordId in ipairs(workIndex.candidates(state.world.proposals)) do
    local record = state.world.proposals.byId[recordId]
    if type(record) == "table" and record.status == "queued" then return true end
    local pending = type(record) == "table" and record.constructionPending or nil
    if type(pending) == "table"
      and state.tick >= util.integer(pending.nextVerificationTick, state.tick) then
      return true
    end
  end
  return false
end

return M
