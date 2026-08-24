local util = require "tpf2_mp/util"

local M = {}

function M.automatic(cfg)
  return type(cfg) == "table" and cfg.manualNetwork == true
end

function M.showManualControl(cfg)
  return not M.automatic(cfg)
end

function M.isDuplicate(state, action)
  return type(state) == "table" and state.initialized == true
    and type(action) == "table" and action.type == "match.initialise"
end

function M.duplicateResult(phase)
  return {
    ignored = true,
    alreadyInitialized = true,
    phase = tostring(phase or "unknown"),
    reason = "match is already initialised",
  }
end

function M.ignoreDuplicateSubmission(state, action, diagnosticLog, publishSnapshot)
  if not M.isDuplicate(state, action) then return false end
  local result = M.duplicateResult("local-submission")
  state.lastAction = { type = "match.initialise", ignored = true }
  state.lastResult = util.deepCopy(result)
  state.lastError = nil
  if type(diagnosticLog) == "function" then
    diagnosticLog("duplicate-match-initialise-ignored", {
      phase = result.phase,
      peerId = state.bridge and state.bridge.peerId or nil,
      tick = state.tick,
    })
  end
  if type(publishSnapshot) == "function" then publishSnapshot() end
  return true, result
end

function M.status(snapshot)
  snapshot = type(snapshot) == "table" and snapshot or {}
  local companion = snapshot.bridge and snapshot.bridge.companion or {}
  local proposal = snapshot.proposalConsensus or {}
  local operation = snapshot.operationConsensus or {}
  if proposal.sessionFault or operation.sessionFault or companion.sessionFault then
    return "FAULTED"
  end
  if snapshot.initialized == true then
    if snapshot.networkMode == "network"
      and type(snapshot.checkpointConsensus) == "table"
      and not snapshot.checkpointConsensus.lastAgreed then
      return "synchronising checkpoint"
    end
    return "ready"
  end
  if snapshot.networkMode ~= "network" then return "manual setup" end
  local content = snapshot.industryContent or {}
  if companion.connected == true and content.ready ~= true then
    return "waiting for peer world"
  end
  if companion.connected == true then return "starting automatically" end
  return "waiting for peer"
end

return M
