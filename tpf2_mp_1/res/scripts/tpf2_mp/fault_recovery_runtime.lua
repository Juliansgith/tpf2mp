local util = require "tpf2_mp/util"
local world = require "tpf2_mp/world"

local M = {}

local function pendingRecord(records)
  for _, record in pairs(records or {}) do
    if type(record) == "table" and record.status == "pending" then return true end
  end
  return false
end

local function validDigest(value)
  return type(value) == "string" and value:match("^[0-9a-f][0-9a-f][0-9a-f][0-9a-f]"
    .. "[0-9a-f][0-9a-f][0-9a-f][0-9a-f]$") ~= nil
end

local function normalise(action)
  if type(action) ~= "table" then return nil, "recovery action must be a table" end
  for key in pairs(action) do
    if key ~= "type" then return nil, "recovery.requalify has a client-supplied field" end
  end
  return { type = "recovery.requalify" }
end

local function validateBound(action, commitSeq)
  local expected = {
    type = true, schemaVersion = true, recoveryId = true, faultType = true,
    faultCommitSeq = true, faultOutcomeSeq = true, faultCode = true,
    proposalId = true, proposalDigest = true, resultDigest = true,
    expectedCoreDigest = true, nativeErrorCode = true, requestedBy = true,
  }
  if type(action) ~= "table" then return false, "fault recovery action is unavailable" end
  for key in pairs(action) do
    if not expected[key] then return false, "fault recovery action has an unknown field" end
    expected[key] = nil
  end
  if next(expected) ~= nil or action.schemaVersion ~= 1
    or action.faultType ~= "proposal-timeout" then
    return false, "fault recovery action is incomplete or unsupported"
  end
  local faultCommit = util.integer(action.faultCommitSeq, 0)
  local faultOutcome = util.integer(action.faultOutcomeSeq, 0)
  if faultCommit < 1 or faultOutcome <= faultCommit
    or util.integer(commitSeq, 0) <= faultOutcome
    or tostring(action.recoveryId or "")
      ~= "fault-recovery:" .. tostring(faultOutcome) .. ":" .. tostring(faultCommit) then
    return false, "fault recovery ordered identity is invalid"
  end
  if not tostring(action.faultCode or ""):match("^proposal%-completion%-timeout:")
    or not tostring(action.proposalId or ""):match("^.+$")
    or not validDigest(action.proposalDigest)
    or not validDigest(action.resultDigest)
    or not validDigest(action.expectedCoreDigest)
    or tostring(action.nativeErrorCode or "") == ""
    or not tostring(action.requestedBy or ""):match("^player%d+$") then
    return false, "fault recovery evidence fields are invalid"
  end
  return true
end

function M.new(env)
  local getState = assert(env.getState, "fault recovery state provider is required")
  local coreDigest = assert(env.coreDigest, "fault recovery core digest is required")

  local function begin(action, _, commitSeq)
    local state = getState()
    local valid, validationError = validateBound(action, commitSeq)
    if not valid then return false, validationError end
    if state.networkMode ~= "network" then return false, "fault recovery is network-only" end
    local consensus = state.world.proposalConsensus
    local fault = consensus and consensus.sessionFault or nil
    if type(fault) ~= "table"
      or tostring(fault.errorCode or "") ~= tostring(action.faultCode) then
      return false, "local proposal fault does not match the host recovery proof"
    end
    if state.world.operationConsensus and state.world.operationConsensus.sessionFault then
      return false, "an additional operation fault requires a verified restore"
    end
    if util.tableCount(state.world.originResidueCustody or {}) > 0 then
      return false, "unowned native mutation residue requires a verified restore"
    end
    if pendingRecord(consensus.byId)
      or pendingRecord(state.world.operationConsensus.byId)
      or pendingRecord(state.world.checkpointConsensus.byBoundary) then
      return false, "local consensus work is still pending"
    end
    local proposal = state.world.proposals.byId[tostring(action.proposalId)]
    local completion = proposal and proposal.completion or nil
    local outputs = completion and completion.outputs or nil
    if type(proposal) ~= "table" or type(completion) ~= "table"
      or completion.success ~= false or type(outputs) ~= "table" or next(outputs) ~= nil
      or completion.financeDelta ~= nil
      or util.integer(proposal.commitSeq, 0) ~= util.integer(action.faultCommitSeq, -1)
      or tostring(proposal.transaction and proposal.transaction.digest or "")
        ~= tostring(action.proposalDigest)
      or tostring(completion.proposalDigest or "") ~= tostring(action.proposalDigest)
      or tostring(completion.resultDigest or "") ~= tostring(action.resultDigest)
      or tostring(completion.coreDigest or "") ~= tostring(action.expectedCoreDigest)
      or tostring(completion.errorCode or "") ~= tostring(action.nativeErrorCode) then
      return false, "local late completion does not prove an empty identical rejection"
    end
    if coreDigest() ~= tostring(action.expectedCoreDigest) then
      return false, "authored state changed after the timed-out rejection"
    end
    state.probes.structural = world.structuralSnapshot(
      state.canonical, state.world, state.companies)
    local manifest = world.canonicalManifest(state.canonical, state.world)
    state.probes.worldManifest = {
      schemaVersion = manifest.schemaVersion, total = manifest.total,
      uniqueBound = manifest.uniqueBound, deferredUnique = manifest.deferredUnique,
      ambiguousCount = manifest.ambiguousCount, digest = manifest.digest,
    }
    state.recovery.faultRecovery = {
      schemaVersion = 1, status = "probing", recoveryId = action.recoveryId,
      boundarySeq = commitSeq, faultCommitSeq = action.faultCommitSeq,
      faultOutcomeSeq = action.faultOutcomeSeq, faultCode = action.faultCode,
      proposalId = action.proposalId, expectedCoreDigest = action.expectedCoreDigest,
      requestedBy = action.requestedBy, tick = state.tick,
    }
    return true, util.deepCopy(state.recovery.faultRecovery)
  end

  local function afterCommit(action, success, authoritySeq, exportCheckpoint, log)
    if action.type ~= "recovery.requalify" then return false end
    if success and authoritySeq then
      local ok, result = exportCheckpoint(
        authoritySeq, "fault-recovery:" .. tostring(action.recoveryId))
      if not ok then log("fault-recovery-checkpoint-error", {
        boundarySeq = authoritySeq, error = tostring(result),
      }) end
    end
    return true
  end

  local function checkpointOutcome(action, success, record, errorCode)
    local state = getState()
    local proof = type(action) == "table" and action.faultRecovery or nil
    if type(proof) ~= "table" then return success, errorCode end
    local recovery = state.recovery and state.recovery.faultRecovery or nil
    if type(recovery) ~= "table" or recovery.status ~= "probing"
      or tostring(proof.recoveryId or "") ~= tostring(recovery.recoveryId)
      or util.integer(action.boundarySeq, 0) ~= util.integer(recovery.boundarySeq, -1)
      or tostring(record and record.reason or "")
        ~= "fault-recovery:" .. tostring(recovery.recoveryId) then
      local detail = "fault recovery checkpoint does not match its local probe"
      record.success, record.status, record.errorCode = false, "faulted", detail
      return false, detail
    end
    if not success then
      recovery.status = "rollback-required"
      recovery.errorCode = tostring(record and record.errorCode or "checkpoint failed")
      return success, errorCode
    end
    local consensus = state.world.proposalConsensus
    local fault = consensus.sessionFault
    local outcome = consensus.byId[tostring(recovery.proposalId)]
    if type(fault) ~= "table" or tostring(fault.errorCode or "") ~= recovery.faultCode
      or type(outcome) ~= "table" or outcome.status ~= "faulted"
      or util.integer(outcome.commitSeq, 0) ~= util.integer(recovery.faultCommitSeq, -1) then
      local detail = "fault recovery cannot clear a different local fault"
      record.success, record.status, record.errorCode = false, "faulted", detail
      return false, detail
    end
    outcome.status, outcome.success, outcome.recoverable = "rejected", false, true
    outcome.timeoutErrorCode, outcome.errorCode = recovery.faultCode, "native-proposal-rejected"
    outcome.recoveredFromTimeout, outcome.recoveryId = true, recovery.recoveryId
    consensus.failed = math.max(0, util.integer(consensus.failed, 0) - 1)
    consensus.rejected = math.max(0, util.integer(consensus.rejected, 0)) + 1
    consensus.sessionFault, consensus.lastOutcome = nil, util.deepCopy(outcome)
    local proposal = state.world.proposals.byId[tostring(recovery.proposalId)]
    if proposal then proposal.recoveredFromTimeout = true end
    recovery.status, recovery.recoveredTick = "recovered", state.tick
    recovery.checkpoint = {
      convergenceKey = record.convergenceKey, coreDigest = record.coreDigest,
      structuralDigest = record.structuralDigest,
      worldManifestDigest = record.worldManifestDigest,
    }
    return true, errorCode
  end

  return {
    normalise = normalise, begin = begin, afterCommit = afterCommit,
    checkpointOutcome = checkpointOutcome,
  }
end

return M
