local util = require "tpf2_mp/util"

local M = {}

local CANDIDATES = {
  { -1400, -1400 }, { 1400, -1400 }, { -1400, 1400 }, { 1400, 1400 },
  { -1000, -1200 }, { 1000, -1200 }, { -1000, 1200 }, { 1000, 1200 },
  { -600, -1400 }, { 600, -1400 }, { -600, 1400 }, { 600, 1400 },
  { -1600, 0 }, { 1600, 0 }, { 0, -1600 }, { 0, 1600 },
}

function M.new(deps)
  local getState = assert(deps.getState, "getState dependency is required")
  local transactionFor = assert(deps.transaction, "transaction dependency is required")
  local applyCommitted = assert(deps.applyCommitted, "applyCommitted dependency is required")
  local check = assert(deps.check, "check dependency is required")
  local submit = assert(deps.submit, "submit dependency is required")

  local function standalone(companyCid, startIndex)
    local errors = {}
    for index = math.max(1, util.integer(startIndex, 1)), #CANDIDATES do
      local candidate = CANDIDATES[index]
      local transaction, transactionError = transactionFor(
        candidate[1], candidate[2], companyCid)
      if transaction then
        local ok, result = applyCommitted(
          { type = "proposal.build", transaction = transaction }, "auto-validator", nil)
        if ok then return true, { candidate = index, transaction = transaction, result = result } end
        errors[#errors + 1] = tostring(type(result) == "table" and result.error or result)
      else
        errors[#errors + 1] = tostring(transactionError)
      end
    end
    return false, { error = "no canonical track proposal candidate succeeded",
      attempts = #CANDIDATES, errors = errors }
  end

  local function nextCandidate(prefix, companyCid, preferredIndex, excludedIndex)
    local values = getState().validation.values
    local attemptsKey = prefix .. "ProposalAttemptedCandidates"
    local attempted = values[attemptsKey]
    if type(attempted) ~= "table" then
      attempted = {}
      values[attemptsKey] = attempted
    end
    local errors, count = {}, #CANDIDATES
    local first = math.max(1, math.min(count, util.integer(preferredIndex, 1)))
    for offset = 0, count - 1 do
      local index = ((first - 1 + offset) % count) + 1
      local key = tostring(index)
      if not attempted[key] and index ~= excludedIndex then
        attempted[key] = true
        local candidate = CANDIDATES[index]
        local transaction, transactionError = transactionFor(
          candidate[1], candidate[2], companyCid)
        if transaction then return index, transaction, errors end
        errors[#errors + 1] = { candidate = index, error = tostring(transactionError) }
      end
    end
    return nil, nil, errors
  end

  local function queue(prefix, companyCid, originPeer, preferredIndex,
      excludedIndex, checkName, submitLabel)
    local state = getState()
    local index, transaction, errors = nextCandidate(
      prefix, companyCid, preferredIndex, excludedIndex)
    check(checkName, transaction ~= nil, {
      candidate = index, errors = errors,
      digest = transaction and transaction.digest or nil,
    })
    local values = state.validation.values
    values[prefix .. "ProposalCandidate"] = index
    values[prefix .. "ProposalDigest"] = transaction.digest
    if state.bridge.peerId == originPeer then
      local result = submit({ type = "proposal.prepare", transaction = transaction }, submitLabel)
      values[prefix .. "ProposalLocalSeq"] = result and result.local_seq
    end
  end

  local function outcome(prefix, companyCid)
    local state = getState()
    local wantedDigest = tostring(state.validation.values[prefix .. "ProposalDigest"] or "")
    if wantedDigest == "" then return nil, nil end
    local bestOutcome, bestRecord
    local proposals = state.world.proposals and state.world.proposals.byId or {}
    for proposalId, record in pairs(proposals) do
      local transaction = type(record) == "table" and record.transaction or nil
      if transaction and tostring(transaction.digest or "") == wantedDigest
        and tostring(transaction.companyCid or "") == tostring(companyCid) then
        local candidate = state.world.proposalConsensus.byId[tostring(proposalId)]
        if candidate and candidate.status ~= "pending"
          and (not bestRecord or util.integer(record.commitSeq, 0)
            > util.integer(bestRecord.commitSeq, 0)) then
          bestOutcome, bestRecord = candidate, record
        end
      end
    end
    return bestOutcome, bestRecord
  end

  local function retainRejection(prefix, rejectedOutcome)
    local state = getState()
    local key = prefix .. "ProposalRejections"
    local rejected = state.validation.values[key]
    if type(rejected) ~= "table" then
      rejected = {}
      state.validation.values[key] = rejected
    end
    rejected[#rejected + 1] = {
      proposalId = rejectedOutcome.proposalId,
      candidate = state.validation.values[prefix .. "ProposalCandidate"],
      errorCode = rejectedOutcome.errorCode,
      tick = state.tick,
    }
    state.validation.values[prefix .. "RejectedProposalId"] = rejectedOutcome.proposalId
  end

  local function retryAfterCheckpoint(prefix, companyCid, originPeer, excludedIndex,
      checkpoint, checkpointCheckName, candidateCheckName, submitLabel)
    local state = getState()
    local rejectedProposalId = state.validation.values[prefix .. "RejectedProposalId"]
    local agreed = checkpoint(function(record)
      return rejectedProposalId ~= nil
        and tostring(record.proposalId or "") == tostring(rejectedProposalId)
    end)
    if not agreed then return false end
    check(checkpointCheckName, agreed.success == true, agreed)
    queue(prefix, companyCid, originPeer,
      util.integer(state.validation.values[prefix .. "ProposalCandidate"], 1) + 1,
      excludedIndex, candidateCheckName, submitLabel)
    return true
  end

  return {
    standalone = standalone,
    queue = queue,
    outcome = outcome,
    retainRejection = retainRejection,
    retryAfterCheckpoint = retryAfterCheckpoint,
  }
end

return M
