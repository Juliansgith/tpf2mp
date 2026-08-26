local finance = require "tpf2_mp/finance"
local rejectionProof = require "tpf2_mp/operation_rejection_proof"
local util = require "tpf2_mp/util"

local M = {}

local function localRejectionMatches(state, record, action, gameApi)
  local completion = record.completion
  local outputs = completion and completion.outputs
  local digest = record.transaction and tostring(record.transaction.digest or "") or ""
  return completion ~= nil
    and completion.success == false
    and type(outputs) == "table" and next(outputs) == nil
    and completion.financeDelta == nil
    and record.transaction and record.transaction.kind == "vehicle.assign"
    and digest ~= "" and digest == tostring(action.operationDigest or "")
    and tostring(completion.operationDigest or "") == tostring(action.operationDigest or "")
    and tostring(completion.resultDigest or "") == tostring(action.resultDigest or "")
    and tostring(completion.coreDigest or "") == tostring(action.coreDigest or "")
    and rejectionProof.validate(state, record, completion.postcondition, gameApi)
end

local function unknownFault(state, consensus, action, operationId, recoverable)
  if action.success == true then
    return false, "successful consensus references an unknown operation"
  end
  local fault = {
    operationId = operationId,
    commitSeq = tonumber(action.commitSeq),
    operationDigest = tostring(action.operationDigest or ""),
    success = false,
    recoverable = false,
    status = "faulted",
    errorCode = recoverable and "recoverable-rejection-references-unknown-operation"
      or tostring(action.errorCode or "operation-consensus-failed"),
    tick = state.tick,
  }
  consensus.byId[operationId] = fault
  consensus.lastOutcome = util.deepCopy(fault)
  consensus.failed = (consensus.failed or 0) + 1
  consensus.sessionFault = util.deepCopy(fault)
  return false, fault
end

function M.new(env)
  assert(type(env) == "table" and type(env.getState) == "function",
    "operation outcome environment is required")
  assert(type(env.recordVehiclePurchaseCost) == "function",
    "vehicle purchase cost recorder is required")

  return function(action)
    local state = env.getState()
    if state.networkMode ~= "network" then
      return false, "operation consensus exists only in network mode"
    end
    local operationId = type(action) == "table" and tostring(action.operationId or "") or ""
    local requestedRecoverable = type(action) == "table" and action.recoverable == true
    local recoverable = requestedRecoverable and action.success ~= true
    local consensus = state.world.operationConsensus
    local record = state.world.operations.byId[operationId]
    if not record then return unknownFault(state, consensus, action, operationId, recoverable) end
    if tonumber(action.commitSeq) ~= tonumber(record.commitSeq) then
      return false, "operation consensus commit sequence mismatch"
    end
    local existing = consensus.byId[operationId]
    if existing and existing.status ~= "pending" then
      local same = existing.success == (action.success == true)
        and existing.recoverable == recoverable
        and tostring(existing.resultDigest or "") == tostring(action.resultDigest or "")
        and tostring(existing.coreDigest or "") == tostring(action.coreDigest or "")
      if not same then return false, "conflicting operation consensus outcome" end
      return existing.success == true or existing.recoverable == true, util.deepCopy(existing)
    end

    local completion = record.completion
    local success = action.success == true
    if requestedRecoverable and success then
      success = false
      action = util.deepCopy(action)
      action.errorCode = "successful-operation-consensus-cannot-be-recoverable"
    end
    if success and (not completion or completion.success ~= true
      or tostring(completion.resultDigest or "") ~= tostring(action.resultDigest or "")
      or tostring(completion.coreDigest or "") ~= tostring(action.coreDigest or "")) then
      success = false
      action = util.deepCopy(action)
      action.errorCode = "local-operation-completion-does-not-match-consensus"
    end
    if recoverable and not localRejectionMatches(
      state, record, action, env.getApi and env.getApi() or api) then
      recoverable = false
      action = util.deepCopy(action)
      action.errorCode = "recoverable-operation-rejection-does-not-match-local-completion"
    end

    local authoritativeFinanceDelta = tonumber(action.financeDelta)
    local canonicalFinanceEntry, nativeReconciliation
    if success and authoritativeFinanceDelta == nil then
      success = false
      action = util.deepCopy(action)
      action.errorCode = "operation-finance-consensus-is-unavailable"
    elseif success then
      local applied, entryOrError = finance.applyNetworkDelta(
        state.finance, record.companyCid, authoritativeFinanceDelta, {
          kind = "operation", operationId = operationId,
          operationKind = record.transaction.kind,
          commitSeq = tonumber(action.commitSeq),
        })
      if not applied then
        success = false
        action = util.deepCopy(action)
        action.errorCode = "operation-canonical-finance-failed:" .. tostring(entryOrError)
      else
        canonicalFinanceEntry = entryOrError
        local reconciled, result = finance.reconcileNetworkAccounts(
          state.finance, state.companies, {
            reason = "operation-consensus", operationId = operationId,
            commitSeq = tonumber(action.commitSeq), tick = state.tick,
          })
        nativeReconciliation = type(result) == "table" and result
          or { error = tostring(result) }
        if not reconciled then
          success = false
          action = util.deepCopy(action)
          action.errorCode = "operation-native-wallet-reconciliation-failed:"
            .. tostring(nativeReconciliation.error or result)
        end
      end
    end
    if success then env.recordVehiclePurchaseCost(record, authoritativeFinanceDelta) end
    local outcome = {
      operationId = operationId, commitSeq = tonumber(action.commitSeq),
      operationDigest = tostring(action.operationDigest or ""), success = success,
      recoverable = recoverable,
      status = success and "complete" or recoverable and "rejected" or "faulted",
      resultDigest = tostring(action.resultDigest or ""),
      coreDigest = tostring(action.coreDigest or ""),
      financeDelta = authoritativeFinanceDelta,
      canonicalFinanceEntry = util.deepCopy(canonicalFinanceEntry),
      nativeReconciliation = util.deepCopy(nativeReconciliation),
      peers = util.deepCopy(type(action.peers) == "table" and action.peers or {}),
      errorCode = not success and tostring(action.errorCode or "operation-consensus-failed") or nil,
      tick = state.tick,
    }
    consensus.byId[operationId], consensus.lastOutcome = outcome, util.deepCopy(outcome)
    if success then
      consensus.completed = (consensus.completed or 0) + 1
    elseif recoverable then
      consensus.rejected = (consensus.rejected or 0) + 1
    else
      consensus.failed = (consensus.failed or 0) + 1
      consensus.sessionFault = util.deepCopy(outcome)
    end
    local vehicleSync = env.getVehicleSync and env.getVehicleSync() or nil
    if success and vehicleSync then vehicleSync.onOperationConsensus(record) end
    return success or recoverable, util.deepCopy(outcome)
  end
end

return M
