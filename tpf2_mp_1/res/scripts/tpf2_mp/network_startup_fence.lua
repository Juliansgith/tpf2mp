local util = require "tpf2_mp/util"
local M = {}

function M.rejection(state, action)
  local continuation = type(state.recovery) == "table"
    and state.recovery.savedMatchContinuation or nil
  if type(continuation) ~= "table" or continuation.status == "complete"
    or action.type == "recovery.continue"
    or action.type == "content.industry_attest"
    or (action.type == "clock.request"
      and util.integer(action.requestedSpeed, -1) == 0) then return nil end
  if continuation.status == "failed" then
    return "saved match continuation is blocked: "
      .. tostring(continuation.error or "source validation failed")
  end
  return "saved match continuation is establishing its first two-peer checkpoint"
end

return M
