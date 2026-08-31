local connectedTerminal = require "tpf2_mp/validation_connected_terminal_proposal"

local M = {}

local function completeOutputs(outputs)
  local wanted = {
    ["construction:construction:1"] = true, ["edge:edge:1"] = true,
    ["edge:edge:2"] = true, ["edge:edge:3"] = true,
    ["node:node:1"] = true, ["node:node:2"] = true,
    ["station:station:1"] = true, ["station_group:station_group:1"] = true,
  }
  for _, item in ipairs(outputs or {}) do wanted[tostring(item.kind) .. ":" .. tostring(item.slot)] = nil end
  return #(outputs or {}) == 8 and next(wanted) == nil
end

function M.new(deps)
  local getState = assert(deps.getState, "connected-terminal validation state is required")
  local transition = assert(deps.transition, "connected-terminal validation transition is required")
  local check = assert(deps.check, "connected-terminal validation check is required")
  local submit = assert(deps.submit, "connected-terminal validation submit is required")
  local checkpoint = assert(deps.checkpoint, "connected-terminal validation checkpoint is required")
  local finish = assert(deps.finish, "connected-terminal validation finish is required")

  local function begin()
    local state = getState()
    state.validation.values.connectedTerminalConsensusBefore =
      state.world.proposalConsensus.completed or 0
    state.validation.values.connectedTerminalFailuresBefore =
      state.world.proposalConsensus.failed or 0
    if state.bridge.peerId == "player1" then
      local transaction, transactionError = connectedTerminal.transaction("company:1")
      check("connected-terminal-transaction-valid", transaction ~= nil, {
        error = transactionError, digest = transaction and transaction.digest or nil,
      })
      local result = submit({ type = "proposal.prepare", transaction = transaction },
        "host-origin-connected-terminal-queued")
      state.validation.values.connectedTerminalLocalSeq = result and result.local_seq
    end
    transition("wait-for-connected-terminal-consensus")
  end

  local function maintain(stage)
    local state = getState()
    if stage == "wait-for-connected-terminal-consensus" then
      local before = state.validation.values.connectedTerminalConsensusBefore or 0
      local failuresBefore = state.validation.values.connectedTerminalFailuresBefore or 0
      local consensus = state.world.proposalConsensus
      if (consensus.completed or 0) <= before
        and (consensus.failed or 0) <= failuresBefore then return true end
      local outcome = consensus.lastOutcome
      local record = outcome and state.world.proposals.byId[outcome.proposalId] or nil
      local result = record and record.result or nil
      check("connected-terminal-physical-consensus", outcome and outcome.success == true, outcome)
      check("connected-terminal-used-staged-exact-replay", result
        and result.constructionReplayPath == "staged-gui-build-proposal", result)
      check("connected-terminal-created-exact-connected-graph",
        result and completeOutputs(result.outputs), result)
      local bindings = state.canonical and state.canonical.byCanonical or {}
      check("connected-terminal-retired-road-and-collateral",
        bindings["edge:pre:72fc11f4"] == nil
          and bindings["construction:pre:adee28b9"] == nil
          and bindings["construction:pre:aff228b9"] == nil, {})
      state.validation.values.connectedTerminalProposalId = outcome and outcome.proposalId or nil
      transition("wait-for-connected-terminal-checkpoint")
      return true
    end
    if stage == "wait-for-connected-terminal-checkpoint" then
      local wantedProposalId = state.validation.values.connectedTerminalProposalId
      local agreed = checkpoint(function(record)
        return wantedProposalId ~= nil
          and tostring(record.proposalId or "") == tostring(wantedProposalId)
      end)
      if not agreed then return true end
      check("connected-terminal-post-proposal-checkpoint-consensus", agreed.success == true, agreed)
      finish(agreed.boundarySeq)
      return true
    end
    return false
  end

  return { begin = begin, maintain = maintain }
end

return M
