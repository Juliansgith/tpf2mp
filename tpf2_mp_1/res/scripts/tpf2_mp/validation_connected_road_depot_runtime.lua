local fixture = require "tpf2_mp/validation_connected_road_depot_proposal"
local purchaseModule = require "tpf2_mp/validation_depot_vehicle_purchase"

local M = {}

local function completeOutputs(outputs)
  local wanted = {
    ["construction:construction:1"] = true, ["depot:depot:1"] = true,
    ["edge:edge:1"] = true, ["node:node:1"] = true,
  }
  for _, item in ipairs(outputs or {}) do
    wanted[tostring(item.kind) .. ":" .. tostring(item.slot)] = nil
  end
  return #(outputs or {}) == 4 and next(wanted) == nil
end

function M.new(deps)
  local getState = assert(deps.getState, "road-depot validation state is required")
  local transition = assert(deps.transition, "road-depot validation transition is required")
  local check = assert(deps.check, "road-depot validation check is required")
  local submit = assert(deps.submit, "road-depot validation submit is required")
  local checkpoint = assert(deps.checkpoint, "road-depot validation checkpoint is required")
  local finish = assert(deps.finish, "road-depot validation finish is required")
  local key = tostring(deps.validationKey or "connectedRoadDepot")
  local stagePrefix = tostring(deps.stagePrefix or "connected-road-depot")
  local checkPrefix = tostring(deps.checkPrefix or stagePrefix)
  local fixtureOptions = deps.fixtureOptions
  local purchase = not deps.afterCheckpoint and purchaseModule.new({
    getState = getState, transition = transition, check = check,
    submit = submit, checkpoint = checkpoint, finish = finish,
  }) or nil

  local function begin()
    local state = getState()
    state.validation.values[key .. "ConsensusBefore"] =
      state.world.proposalConsensus.completed or 0
    state.validation.values[key .. "FailuresBefore"] =
      state.world.proposalConsensus.failed or 0
    if state.bridge.peerId == "player1" then
      local transaction, transactionError = fixture.transaction("company:1", fixtureOptions)
      check(checkPrefix .. "-transaction-valid", transaction ~= nil, {
        error = transactionError, digest = transaction and transaction.digest or nil,
      })
      local result = submit({ type = "proposal.prepare", transaction = transaction },
        "host-origin-" .. stagePrefix .. "-queued")
      state.validation.values[key .. "LocalSeq"] = result and result.local_seq
    end
    transition("wait-for-" .. stagePrefix .. "-consensus")
  end

  local function maintain(stage)
    local state = getState()
    if stage == "wait-for-" .. stagePrefix .. "-consensus" then
      local before = state.validation.values[key .. "ConsensusBefore"] or 0
      local failuresBefore = state.validation.values[key .. "FailuresBefore"] or 0
      local consensus = state.world.proposalConsensus
      if (consensus.completed or 0) <= before
        and (consensus.failed or 0) <= failuresBefore then return true end
      local outcome = consensus.lastOutcome
      local record = outcome and state.world.proposals.byId[outcome.proposalId] or nil
      local result = record and record.result or nil
      check(checkPrefix .. "-physical-consensus",
        outcome and outcome.success == true, outcome)
      check(checkPrefix .. "-used-exact-replay", result
        and result.constructionReplayPath == "gui-build-proposal", result)
      check(checkPrefix .. "-created-complete-graph",
        result and completeOutputs(result.outputs), result)
      for _, output in ipairs(result and result.outputs or {}) do
        if output.kind == "depot" then
          state.validation.values[key .. "Cid"] = output.cid
        end
      end
      state.validation.values[key .. "ProposalId"] =
        outcome and outcome.proposalId or nil
      transition("wait-for-" .. stagePrefix .. "-checkpoint")
      return true
    end
    if stage == "wait-for-" .. stagePrefix .. "-checkpoint" then
      local wanted = state.validation.values[key .. "ProposalId"]
      local agreed = checkpoint(function(record)
        return wanted ~= nil and tostring(record.proposalId or "") == tostring(wanted)
      end)
      if not agreed then return true end
      check(checkPrefix .. "-post-proposal-checkpoint-consensus",
        agreed.success == true, agreed)
      if deps.afterCheckpoint then
        deps.afterCheckpoint(state.validation.values[key .. "Cid"],
          "company:1", agreed.boundarySeq)
      else
        purchase.begin(state.validation.values[key .. "Cid"], "company:1")
      end
      return true
    end
    if purchase and purchase.maintain(stage) then return true end
    return false
  end

  return { begin = begin, maintain = maintain }
end

return M
