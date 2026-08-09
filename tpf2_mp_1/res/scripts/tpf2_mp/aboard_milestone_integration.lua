local freight = require "tpf2_mp/freight_milestone_runtime"
local passenger = require "tpf2_mp/passenger_milestone_runtime"

local M = {}

local function runtimeFor(action)
  if action and action.type == "freight.milestone" then return freight end
  if action and action.type == "passenger.milestone" then return passenger end
  return nil
end

function M.installHandlers(handlers, deps)
  freight.installHandler(handlers, deps)
  passenger.installHandler(handlers, deps)
end

function M.normaliseIntent(state, action)
  local runtime = runtimeFor(action)
  if not runtime then return nil, "unknown aboard milestone type" end
  return runtime.normaliseIntent(state, action)
end

function M.observeRelease(state, action, controller, log)
  passenger.observeRelease(state, action, controller, log)
  freight.observeRelease(state, action, controller, log)
end

function M.afterCommit(state, action, success, authoritySeq, exportCheckpoint, log)
  local runtime = runtimeFor(action)
  return runtime and runtime.afterCommit(
    state, action, success, authoritySeq, exportCheckpoint, log) or false
end

function M.reset()
  freight.reset()
  passenger.reset()
end

return M
