local json = require "tpf2_mp/json"

local M = {}

local function readFixture(root)
  if not (io and io.open) then return nil, "Lua file I/O is unavailable" end
  local path = tostring(root or "") .. "/launcher/second-station-transactions.json"
  local file, openError = io.open(path, "rb")
  if not file then return nil, "second-station fixture is unavailable: " .. tostring(openError) end
  local raw = file:read("*a")
  file:close()
  local decoded, fixture = pcall(json.decode, tostring(raw or ""))
  if not decoded or type(fixture) ~= "table" then
    return nil, "second-station fixture is invalid JSON: " .. tostring(fixture)
  end
  local transactions = fixture.transactions
  if tonumber(fixture.schemaVersion) ~= 1 or type(transactions) ~= "table"
    or type(transactions[1]) ~= "table" or type(transactions[2]) ~= "table"
    or tostring(transactions[1].digest or "") ~= "7fbee410"
    or tostring(transactions[2].digest or "") ~= "bcc7bc62" then
    return nil, "second-station fixture identity is invalid"
  end
  return transactions
end

function M.new(deps)
  local getState = assert(deps.getState, "second-station validation state is required")
  local transition = assert(deps.transition, "second-station validation transition is required")
  local check = assert(deps.check, "second-station validation check is required")
  local submit = assert(deps.submit, "second-station validation submit is required")
  local checkpoint = assert(deps.checkpoint, "second-station validation checkpoint is required")
  local finish = assert(deps.finish, "second-station validation finish is required")
  local loadFixture = deps.loadFixture or function(state)
    return readFixture(state.bridge and state.bridge.root)
  end

  local function queue(index)
    local state = getState()
    local transactions, fixtureError = loadFixture(state)
    check("second-station-fixture-valid-" .. tostring(index), transactions ~= nil, {
      error = fixtureError,
    })
    state.validation.values.secondStationTransactions = transactions
    state.validation.values.secondStationConsensusBefore =
      state.world.proposalConsensus.completed or 0
    state.validation.values.secondStationFailuresBefore =
      state.world.proposalConsensus.failed or 0
    if state.bridge.peerId == "player1" then
      local result = submit({ type = "proposal.prepare", transaction = transactions[index] },
        "host-origin-second-station-" .. tostring(index) .. "-queued")
      state.validation.values.secondStationLocalSeq = result and result.local_seq
    end
    transition("wait-for-second-station-" .. tostring(index) .. "-consensus")
  end

  local function begin()
    local state = getState()
    state.validation.values.secondStationCompleted = 0
    queue(1)
  end

  local function maintain(stage)
    local index = tonumber(tostring(stage):match("^wait%-for%-second%-station%-(%d+)%-consensus$"))
    local state = getState()
    if index then
      local completedBefore = state.validation.values.secondStationConsensusBefore or 0
      local failuresBefore = state.validation.values.secondStationFailuresBefore or 0
      local consensus = state.world.proposalConsensus
      if (consensus.completed or 0) <= completedBefore
        and (consensus.failed or 0) <= failuresBefore then return true end
      local outcome = consensus.lastOutcome
      local record = outcome and state.world.proposals.byId[outcome.proposalId] or nil
      local result = record and record.result or nil
      local transaction = state.validation.values.secondStationTransactions[index]
      check("second-station-physical-consensus-" .. tostring(index),
        outcome and outcome.success == true, outcome)
      check("second-station-digest-matched-" .. tostring(index),
        outcome and tostring(outcome.proposalDigest or "") == tostring(transaction.digest), outcome)
      check("second-station-produced-full-station-" .. tostring(index),
        result and type(result.outputs) == "table" and #result.outputs >= 100, result)
      state.validation.values.secondStationProposalId = outcome and outcome.proposalId or nil
      state.validation.values.secondStationCompleted = index
      transition("wait-for-second-station-" .. tostring(index) .. "-checkpoint")
      return true
    end
    index = tonumber(tostring(stage):match("^wait%-for%-second%-station%-(%d+)%-checkpoint$"))
    if index then
      local wantedProposalId = state.validation.values.secondStationProposalId
      local agreed = checkpoint(function(record)
        return wantedProposalId ~= nil
          and tostring(record.proposalId or "") == tostring(wantedProposalId)
      end)
      if not agreed then return true end
      check("second-station-checkpoint-consensus-" .. tostring(index), agreed.success == true, agreed)
      if index == 1 then
        queue(2)
      else
        local bindings = state.canonical and state.canonical.byCanonical or {}
        check("second-station-collateral-retired",
          bindings["construction:pre:8d3528af"] == nil
            and bindings["construction:pre:8d4028a5"] == nil, {})
        finish(agreed.boundarySeq)
      end
      return true
    end
    return false
  end

  return { begin = begin, maintain = maintain }
end

return M
