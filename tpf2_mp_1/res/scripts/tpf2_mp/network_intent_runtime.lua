local util = require "tpf2_mp/util"
local bridge = require "tpf2_mp/bridge"
local finance = require "tpf2_mp/finance"
local bridgeConsumerModule = require "tpf2_mp/network_bridge_consumer"
local followupQueueModule = require "tpf2_mp/network_followup_queue"
local busyRejection = require "tpf2_mp/network_busy_rejection"
local originCaptureRuntimeModule = require "tpf2_mp/network_origin_capture_runtime"
local startupFence = require "tpf2_mp/network_startup_fence"
local M = {
  MAX_DEFERRED_INTENTS = 32,
  MAX_DEFERRED_FOLLOWUPS = 512,
}
function M.new(deps)
  assert(type(deps) == "table", "network intent runtime dependencies are required")
  local getState = assert(deps.getState, "getState dependency is required")
  local normaliseForNetwork = assert(deps.normaliseForNetwork, "normaliseForNetwork dependency is required")
  local normaliseOperationCapture = assert(deps.normaliseOperationCapture, "normaliseOperationCapture dependency is required")
  local applyCommitted = assert(deps.applyCommitted, "applyCommitted dependency is required")
  local activeCompany = assert(deps.activeCompany, "activeCompany dependency is required")
  local publishSnapshot = assert(deps.publishSnapshot, "publishSnapshot dependency is required")
  local diagnosticLog = assert(deps.diagnosticLog, "diagnosticLog dependency is required")
  local coreDigest = assert(deps.coreDigest, "coreDigest dependency is required")
  local proposalPreparation = assert(deps.proposalPreparation, "proposalPreparation dependency is required")
  local physicalPrerequisite, physicalPrerequisiteResult, noteClockRequest =
    deps.physicalPrerequisite, deps.physicalPrerequisiteResult, deps.noteClockRequest
  local MAX_DEFERRED_NETWORK_INTENTS =
    tonumber(deps.maxDeferredIntents) or M.MAX_DEFERRED_INTENTS
  local MAX_DEFERRED_FOLLOWUPS =
    tonumber(deps.maxDeferredFollowups) or M.MAX_DEFERRED_FOLLOWUPS
  local state = setmetatable({}, {
    __index = function(_, key) return getState()[key] end,
    __newindex = function(_, key, value) getState()[key] = value end,
  })
  local deferredNetworkIntents, networkIntentAwaitingOrder = {}, nil
  local followups = followupQueueModule.new({
    getState = getState, diagnosticLog = diagnosticLog,
    maximum = MAX_DEFERRED_FOLLOWUPS,
  })
  local networkPendingBarrierReason
  local function localWorkState()
    local barrierReason = networkPendingBarrierReason and networkPendingBarrierReason() or nil
    return {
      pending = networkIntentAwaitingOrder ~= nil or #deferredNetworkIntents > 0
        or followups.count() > 0 or barrierReason ~= nil,
      awaitingOrder = networkIntentAwaitingOrder ~= nil,
      physicalCount = #deferredNetworkIntents,
      followupCount = followups.count(),
      deferredCount = #deferredNetworkIntents + followups.count(),
      barrierReason = barrierReason,
    }
  end

  networkPendingBarrierReason = function()
    if type(state.bridge.companion) == "table" and state.bridge.companion.connected ~= true then return "network companion is not connected to all required peers" end
    local rendezvous = state.world.networkClock and state.world.networkClock.rendezvous
    if rendezvous then
      return "shared clock rendezvous is awaiting all-peer simulation time: "
        .. tostring(rendezvous.generation or "-")
    end
    for digest, preparation in pairs(proposalPreparation.pending) do
      return "proposal is prepared and awaiting host commit: "
        .. tostring(preparation.transactionId or digest)
    end
    for _, boundarySeq in ipairs(util.sortedKeys(state.world.checkpointConsensus.byBoundary or {})) do
      local outcome = state.world.checkpointConsensus.byBoundary[boundarySeq]
      if outcome.status == "pending" then
        return "checkpoint boundary is awaiting two-peer consensus: " .. tostring(boundarySeq)
      end
    end
    for _, proposalId in ipairs(util.sortedKeys(state.world.proposalConsensus.byId or {})) do
      local outcome = state.world.proposalConsensus.byId[proposalId]
      if outcome.status == "pending" then
        return "physical proposal is awaiting two-peer consensus: " .. tostring(proposalId)
      end
    end
    for _, operationId in ipairs(util.sortedKeys(state.world.operationConsensus.byId or {})) do
      local outcome = state.world.operationConsensus.byId[operationId]
      if outcome.status == "pending" then
        return "physical operation is awaiting two-peer consensus: " .. tostring(operationId)
      end
    end
    return nil
  end

  local function emitNetworkIntent(action)
    local normalizeCalled, networkAction, err = pcall(normaliseForNetwork, action)
    if not normalizeCalled then
      err = "network action normalisation failed: " .. tostring(networkAction)
      networkAction = nil
    end
    if not networkAction then state.lastError = tostring(err); publishSnapshot(); return false, err, "normalise" end
    local emitCalled, ok, messageOrError = pcall(
      bridge.emit, state.bridge, "intent", { action = networkAction }, state.tick)
    if not emitCalled then
      messageOrError = "bridge emit failed: " .. tostring(ok)
      ok = false
    elseif ok == true and type(messageOrError) ~= "table" then
      ok = false
      messageOrError = "bridge emit returned success without a message envelope"
    end
    state.lastAction = networkAction
    state.lastResult = ok and { queued = true, localSeq = messageOrError.local_seq } or messageOrError
    if ok then
      state.lastError = nil
      networkIntentAwaitingOrder = {
        localSeq = tonumber(messageOrError.local_seq),
        type = networkAction.type,
        originCaptureToken = networkAction.originCaptureToken,
        emittedTick = state.tick,
      }
    else
      state.lastError = tostring(messageOrError)
    end
    publishSnapshot()
    return ok, messageOrError, "emit"
  end

  local originCapture = originCaptureRuntimeModule.new({
    getState = getState, normaliseOperationCapture = normaliseOperationCapture,
    emitNetworkIntent = emitNetworkIntent, activeCompany = activeCompany,
    publishSnapshot = publishSnapshot, diagnosticLog = diagnosticLog,
    maximum = MAX_DEFERRED_NETWORK_INTENTS,
  })

  local function submitIntent(action)
    if type(action) ~= "table" then return false, "action must be a table" end
    if action.type == "clock.request" and type(noteClockRequest) == "function" then pcall(noteClockRequest, action) end
    local duplicate = deps.ignoreDuplicateInitialise and { deps.ignoreDuplicateInitialise(action) }; if duplicate and duplicate[1] then return true, duplicate[2] end
    if action.type == "network.origin_residue" then
      local raised = originCapture.raise(
        tostring(action.errorCode or "origin-applied-residue"),
        type(action.detail) == "table" and action.detail or nil)
      publishSnapshot()
      if not raised then return false, "origin residue faults exist only in network mode" end
      return true, { faulted = true, errorCode = tostring(action.errorCode or "origin-applied-residue") }
    end
    if action.type == "operation.capture" then
      local consensus = state.world.proposalConsensus or {}
      local operationConsensus = state.world.operationConsensus or {}
      local authority = state.probes.networkAuthority or {}
      local pendingReason = state.networkMode == "network"
        and not consensus.sessionFault and not operationConsensus.sessionFault
        and authority.ready == true and originCapture.pendingReason(
          networkPendingBarrierReason(), networkIntentAwaitingOrder,
          #deferredNetworkIntents) or nil
      if pendingReason then
        return originCapture.defer(deferredNetworkIntents, action, pendingReason)
      end
      local normalized, normalizeError = originCapture.normalise(action)
      if not normalized then
        publishSnapshot()
        return false, normalizeError
      end
      action = normalized
    end
    local localControl = action.type == "network.set_mode" or action.type == "snapshot.export"
      or action.type == "checkpoint.export"
      or action.type == "native.build_gate" or action.type == "native.build_authorize"
      or action.type == "native.command_gate" or action.type == "native.command_authorize"
      or action.type == "native.observed" or action.type == "probe.run" or action.type == "probe.export_research"
      or action.type == "probe.gui_capabilities"
      or action.type == "company.cycle" or action.type == "company.reconcile"
      or action.type == "finance.repair_starting_cash"
    if state.networkMode ~= "network" or localControl or action.localOnly then
      local ok, result = applyCommitted(action, state.bridge.peerId, nil)
      publishSnapshot()
      return ok, result
    end
    local authority = state.probes.networkAuthority or {}
    if authority.ready ~= true then
      local errorText = "network authority is not ready: "
        .. tostring(authority.error or "native gates unavailable")
      if originCapture.reject(action, "origin-applied-authority-unavailable:" .. errorText) then
        return false, state.lastError
      end
      state.lastError = errorText
      publishSnapshot()
      return false, state.lastError
    end
    local startupRejection = startupFence.rejection(state, action)
    if startupRejection then
      state.lastError = startupRejection
      publishSnapshot()
      return false, state.lastError
    end
    local networkAccounts = finance.ensureNetworkAccounts(state.finance)
    if state.initialized and networkAccounts.initialized ~= true then
      local errorText = tostring(networkAccounts.migrationError
        or "canonical network accounts are not initialised; start a fresh match")
      if originCapture.reject(action, "origin-applied-finance-unavailable:" .. errorText) then
        return false, state.lastError
      end
      state.lastError = errorText
      publishSnapshot()
      return false, state.lastError
    end
    if action.type == "recovery.requalify" then
      local work = localWorkState()
      if work.pending then
        state.lastError = "session recovery is waiting for local ordered work to drain"
        publishSnapshot()
        return false, state.lastError
      end
      return emitNetworkIntent(action)
    end
    if action.type == "clock.request" then
      local faulted = state.world.proposalConsensus.sessionFault
        or state.world.operationConsensus.sessionFault
      if faulted and util.integer(action.requestedSpeed, -1) ~= 0 then
        state.lastError = "a faulted multiplayer session may only be paused"
        publishSnapshot()
        return false, state.lastError
      end
      return emitNetworkIntent(action)
    end
    local consensus = state.world.proposalConsensus
    if consensus.sessionFault then
      local reason = consensus.sessionFault.errorCode or "proposal-consensus-failed"
      state.lastError = "network session is faulted: " .. tostring(reason)
      publishSnapshot()
      return false, state.lastError
    end
    local operationConsensus = state.world.operationConsensus
    if operationConsensus.sessionFault then
      local reason = operationConsensus.sessionFault.errorCode or "operation-consensus-failed"
      state.lastError = "network session is faulted: " .. tostring(reason)
      publishSnapshot()
      return false, state.lastError
    end
    local pendingReason = networkPendingBarrierReason()
    if not pendingReason and not networkIntentAwaitingOrder and #deferredNetworkIntents == 0
      and type(physicalPrerequisite) == "function" then
      local called, prerequisite, prerequisiteReason = pcall(physicalPrerequisite, action)
      if not called then
        state.lastError = "physical prerequisite failed: " .. tostring(prerequisite)
        publishSnapshot()
        return false, state.lastError
      elseif prerequisite then
        local prerequisiteOk, prerequisiteResult = emitNetworkIntent(prerequisite)
        if type(physicalPrerequisiteResult) == "function" then pcall(physicalPrerequisiteResult,
          prerequisite, prerequisiteOk, prerequisiteResult, action) end
        if not prerequisiteOk then return false, prerequisiteResult end
        pendingReason = tostring(prerequisiteReason or "shared-clock prerequisite is pending")
      end
    end
    if not pendingReason and networkIntentAwaitingOrder then
      pendingReason = "local intent is awaiting its host order: "
        .. tostring(networkIntentAwaitingOrder.localSeq or "-")
    end
    if not pendingReason and #deferredNetworkIntents > 0 then
      pendingReason = "earlier multiplayer physical actions are queued locally"
    end
    if pendingReason then
      local deferablePhysical = action.type == "proposal.prepare"
        or action.type == "proposal.build" or action.type == "operation.execute"
      local busyHandled, busyAccepted, busyResult = busyRejection.handle(
        action, pendingReason, state, deferredNetworkIntents,
        MAX_DEFERRED_NETWORK_INTENTS, diagnosticLog, publishSnapshot)
      if busyHandled then return busyAccepted, busyResult
      elseif deferablePhysical and #deferredNetworkIntents < MAX_DEFERRED_NETWORK_INTENTS then
        deferredNetworkIntents[#deferredNetworkIntents + 1] = {
          action = util.deepCopy(action),
          companyCid = action.companyCid
            or (type(action.transaction) == "table" and action.transaction.companyCid)
            or activeCompany(),
          queuedTick = state.tick,
          reason = pendingReason,
        }
        local queuePosition = #deferredNetworkIntents
        diagnosticLog("network-intent-deferred", {
          type = action.type,
          companyCid = deferredNetworkIntents[queuePosition].companyCid,
          reason = pendingReason,
          queuePosition = queuePosition,
          queueDepth = queuePosition,
          awaitingLocalSeq = networkIntentAwaitingOrder
            and networkIntentAwaitingOrder.localSeq or nil,
          tick = state.tick,
        })
        state.lastAction = { type = action.type, deferred = true, queuePosition = queuePosition }
        state.lastResult = {
          queued = true,
          deferred = true,
          queuedTick = state.tick,
          reason = pendingReason,
          queuePosition = queuePosition,
          queueDepth = queuePosition,
          queueCapacity = MAX_DEFERRED_NETWORK_INTENTS,
        }
        state.lastError = nil
        publishSnapshot()
        return true, util.deepCopy(state.lastResult)
      elseif deferablePhysical then
        local errorText = "multiplayer physical-action queue is full ("
          .. tostring(MAX_DEFERRED_NETWORK_INTENTS) .. "); wait for synchronization"
        if originCapture.reject(action, "origin-applied-deferred-queue-full", {
          queueDepth = #deferredNetworkIntents,
          queueCapacity = MAX_DEFERRED_NETWORK_INTENTS,
          reason = pendingReason,
        }) then
          return false, state.lastError
        end
        state.lastError = errorText
        publishSnapshot()
        return false, state.lastError
      else
        state.lastError = pendingReason
        publishSnapshot()
        return false, state.lastError
      end
    end
    local emitted, result = emitNetworkIntent(action)
    if not emitted then
      local failureText = tostring(type(result) == "table" and result.error or result)
      if originCapture.reject(action, "origin-applied-intent-emit-failed:" .. failureText) then
        return false, state.lastError
      end
    end
    return emitted, result
  end
  
  local function processDeferredNetworkIntent()
    local pending = followups.priorityHead()
    local lane = pending and "followup" or "physical"
    pending = pending or deferredNetworkIntents[1]
    if not pending then lane, pending = "followup", followups.head() end
    if not pending then return false end
    local consensus = state.world.proposalConsensus or {}
    local operationConsensus = state.world.operationConsensus or {}
    if consensus.sessionFault or operationConsensus.sessionFault then
      local physicalCount = #deferredNetworkIntents
      local authoredCount = followups.count()
      deferredNetworkIntents = {}
      followups.clear()
      local fault = consensus.sessionFault or operationConsensus.sessionFault or {}
      state.lastError = tostring(physicalCount) .. " queued multiplayer physical action(s) and "
        .. tostring(authoredCount) .. " authored follow-up(s) discarded because the session faulted: "
        .. tostring(fault.errorCode or "consensus-failed")
      publishSnapshot()
      return true
    end
    if networkIntentAwaitingOrder then
      pending.reason = "local intent is awaiting its host order: "
        .. tostring(networkIntentAwaitingOrder.localSeq or "-")
      if pending.lastLoggedReason ~= pending.reason then
        pending.lastLoggedReason = pending.reason
        diagnosticLog("network-intent-deferred-blocked", {
          type = pending.action and pending.action.type or nil,
          reason = pending.reason,
          queueDepth = #deferredNetworkIntents + followups.count(),
          lane = lane,
          tick = state.tick,
        })
      end
      return false
    end
    local pendingReason = networkPendingBarrierReason()
    if pendingReason then
      pending.reason = pendingReason
      if pending.lastLoggedReason ~= pending.reason then
        pending.lastLoggedReason = pending.reason
        diagnosticLog("network-intent-deferred-blocked", {
          type = pending.action and pending.action.type or nil,
          reason = pending.reason,
          queueDepth = #deferredNetworkIntents + followups.count(),
          lane = lane,
          tick = state.tick,
        })
      end
      return false
    end
    if state.networkMode ~= "network" then
      local discarded = #deferredNetworkIntents + followups.count()
      deferredNetworkIntents = {}
      followups.clear()
      state.lastError = tostring(discarded)
        .. " deferred multiplayer action(s) discarded because network mode ended"
      publishSnapshot()
      return true
    end
    if pending.nextAttemptTick and state.tick < pending.nextAttemptTick then return false end
    local emissionAction = lane == "followup" and followups.emissionAction(pending)
      or util.deepCopy(pending.action)
    if not emissionAction then
      if lane == "followup" then followups.dropHead()
      else table.remove(deferredNetworkIntents, 1) end
      state.lastError = "deferred multiplayer action became empty before emission"
      publishSnapshot()
      return true
    end
    if lane == "physical" and emissionAction.type == "operation.capture" then
      local normalized, normalizeError = originCapture.normalise(emissionAction)
      if not normalized then
        table.remove(deferredNetworkIntents, 1)
        diagnosticLog("network-intent-deferred-normalization-failed", {
          type = "operation.capture",
          captureKind = tostring(
            type(emissionAction.capture) == "table" and emissionAction.capture.kind or ""),
          error = tostring(normalizeError),
          deferredFromTick = pending.queuedTick,
          queueRemaining = #deferredNetworkIntents + followups.count(),
          tick = state.tick,
        })
        publishSnapshot()
        return true
      end
      emissionAction = normalized
    end
    if lane == "physical" then table.remove(deferredNetworkIntents, 1) end
    local ok, result, failurePhase = emitNetworkIntent(emissionAction)
    if ok then
      local retained = false
      if lane == "followup" then retained = followups.consume(pending, emissionAction) end
      diagnosticLog("network-intent-deferred-emitted", {
        type = emissionAction.type,
        lane = lane,
        deferredFromTick = pending.queuedTick,
        queueRemaining = #deferredNetworkIntents + followups.count(),
        followupRetained = retained,
        localSeq = type(result) == "table" and result.local_seq or nil,
        tick = state.tick,
      })
      if type(state.lastResult) == "table" then
        state.lastResult.deferred = true
        state.lastResult.deferredFromTick = pending.queuedTick
        state.lastResult.queueRemaining = #deferredNetworkIntents + followups.count()
      end
    else
      local failureText = tostring(type(result) == "table" and result.error or result)
      if lane == "physical" and emissionAction.originCaptureToken then
        originCapture.raise("origin-applied-intent-emit-failed:" .. failureText, {
          actionType = tostring(emissionAction.type or ""),
          originCaptureToken = tostring(emissionAction.originCaptureToken),
        })
      end
      if lane == "followup" and not followups.handleFailure(pending, emissionAction, failurePhase, failureText) then
        -- No native mutation has happened for a follow-up yet, so retain it
        -- across a transient bridge failure instead of losing authored work.
        pending.failures = (pending.failures or 0) + 1
        pending.lastError = failureText
        pending.nextAttemptTick = state.tick + math.min(300, 15 * pending.failures)
      end
      state.lastError = "deferred multiplayer " .. lane .. " action failed: " .. failureText
    end
    publishSnapshot()
    return true
  end
  
  local consumeBridge = bridgeConsumerModule.new({
    getState = getState,
    takeAwaiting = function(originPeer, localSeq)
      if tostring(originPeer or "") ~= tostring(state.bridge.peerId)
        or not networkIntentAwaitingOrder
        or tonumber(localSeq) ~= tonumber(networkIntentAwaitingOrder.localSeq) then return nil end
      local result = networkIntentAwaitingOrder
      networkIntentAwaitingOrder = nil
      return result
    end,
    applyCommitted = applyCommitted,
    coreDigest = coreDigest,
    diagnosticLog = diagnosticLog,
    raiseOriginResidueFault = originCapture.raise,
    publishSnapshot = publishSnapshot,
  })

  return {
    submit = submitIntent,
    scheduleFollowup = followups.schedule, cancelLineRegistration = followups.cancelLineRegistration,
    processDeferred = processDeferredNetworkIntent,
    hasDeferred = function() return #deferredNetworkIntents > 0 or followups.count() > 0 end,
    consume = consumeBridge,
    pendingBarrierReason = networkPendingBarrierReason,
    raiseOriginResidueFault = originCapture.raise,
    awaitingOrder = function() return util.deepCopy(networkIntentAwaitingOrder) end,
    deferredIntents = function() return util.deepCopy(deferredNetworkIntents) end,
    deferredFollowups = followups.copy,
    localWorkState = function() return util.deepCopy(localWorkState()) end,
    reset = function()
      deferredNetworkIntents = {}
      followups.clear()
      networkIntentAwaitingOrder = nil
    end,
  }
end

return M
