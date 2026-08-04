local util = require "tpf2_mp/util"
local bridge = require "tpf2_mp/bridge"
local finance = require "tpf2_mp/finance"

local M = {
  MAX_DEFERRED_INTENTS = 32,
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
  local MAX_DEFERRED_NETWORK_INTENTS =
    tonumber(deps.maxDeferredIntents) or M.MAX_DEFERRED_INTENTS

  local state = setmetatable({}, {
    __index = function(_, key) return getState()[key] end,
    __newindex = function(_, key, value) getState()[key] = value end,
  })
  local deferredNetworkIntents = {}
  local networkIntentAwaitingOrder = nil

  local function networkPendingBarrierReason()
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
    if not networkAction then state.lastError = tostring(err); publishSnapshot(); return false, err end
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
    return ok, messageOrError
  end

  -- An origin-applied operation is a vanilla pass-through command that has
  -- already mutated this world. If it is rejected anywhere before commit, the
  -- ordered history can never contain it, so the worlds have provably
  -- diverged: fail closed exactly like a commit-time consensus fault and
  -- request the ordered pause a faulted session is still allowed to apply.
  local function raiseOriginResidueFault(errorCode, detail)
    if state.networkMode ~= "network" then return false end
    local consensus = state.world.operationConsensus
    if consensus.sessionFault then return true end
    local fault = {
      success = false,
      status = "faulted",
      errorCode = tostring(errorCode),
      detail = detail and util.deepCopy(detail) or nil,
      originPeer = tostring(state.bridge.peerId or ""),
      tick = state.tick,
    }
    consensus.failed = (consensus.failed or 0) + 1
    consensus.lastOutcome = util.deepCopy(fault)
    consensus.sessionFault = fault
    diagnosticLog("origin-applied-residue-fault", {
      errorCode = fault.errorCode,
      detail = fault.detail and util.deepCopy(fault.detail) or nil,
      tick = state.tick,
    })
    -- The pause request is best-effort: raising the fault must never throw,
    -- even if the bridge is unavailable at this exact tick.
    local called, emitOk, emitError = pcall(emitNetworkIntent, { type = "clock.request", requestedSpeed = 0 })
    if not called or emitOk ~= true then
      diagnosticLog("origin-residue-pause-failed", {
        error = tostring(not called and emitOk or emitError),
        tick = state.tick,
      })
    end
    state.lastError = "network session is faulted: " .. tostring(errorCode)
    publishSnapshot()
    return true
  end

  local function rejectOriginApplied(action, errorCode, detail)
    local token = type(action) == "table" and action.originCaptureToken or nil
    if not token then return false end
    detail = type(detail) == "table" and util.deepCopy(detail) or {}
    detail.actionType = detail.actionType or tostring(action.type or "")
    detail.originCaptureToken = tostring(token)
    raiseOriginResidueFault(tostring(errorCode), detail)
    return true
  end

  local function submitIntent(action)
    if type(action) ~= "table" then return false, "action must be a table" end
    if action.type == "network.origin_residue" then
      local raised = raiseOriginResidueFault(
        tostring(action.errorCode or "origin-applied-residue"),
        type(action.detail) == "table" and action.detail or nil)
      publishSnapshot()
      if not raised then return false, "origin residue faults exist only in network mode" end
      return true, { faulted = true, errorCode = tostring(action.errorCode or "origin-applied-residue") }
    end
    if action.type == "operation.capture" then
      local capture = type(action.capture) == "table" and action.capture or action
      local normalized, normalizeError = normaliseOperationCapture(action)
      if not normalized then
        if capture.originApplied == true then
          raiseOriginResidueFault(
            "origin-applied-capture-rejected:" .. tostring(normalizeError), {
              kind = tostring(capture.kind or ""),
              targetLocalId = tonumber(capture.targetLocalId or capture.originLocalId),
            })
        end
        state.lastError = tostring(normalizeError)
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
      if rejectOriginApplied(action, "origin-applied-authority-unavailable:" .. errorText) then
        return false, state.lastError
      end
      state.lastError = errorText
      publishSnapshot()
      return false, state.lastError
    end
    local networkAccounts = finance.ensureNetworkAccounts(state.finance)
    if state.initialized and networkAccounts.initialized ~= true then
      local errorText = tostring(networkAccounts.migrationError
        or "canonical network accounts are not initialised; start a fresh match")
      if rejectOriginApplied(action, "origin-applied-finance-unavailable:" .. errorText) then
        return false, state.lastError
      end
      state.lastError = errorText
      publishSnapshot()
      return false, state.lastError
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
    if not pendingReason and networkIntentAwaitingOrder then
      pendingReason = "local intent is awaiting its host order: "
        .. tostring(networkIntentAwaitingOrder.localSeq or "-")
    end
    if not pendingReason and #deferredNetworkIntents > 0 then
      pendingReason = "earlier multiplayer physical actions are queued locally"
    end
    if pendingReason then
      local deferablePhysical = action.type == "proposal.capture" or action.type == "proposal.prepare"
        or action.type == "proposal.build" or action.type == "operation.execute"
      if deferablePhysical and #deferredNetworkIntents < MAX_DEFERRED_NETWORK_INTENTS then
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
        if rejectOriginApplied(action, "origin-applied-deferred-queue-full", {
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
      if rejectOriginApplied(action, "origin-applied-intent-emit-failed:" .. failureText) then
        return false, state.lastError
      end
    end
    return emitted, result
  end
  
  local function processDeferredNetworkIntent()
    local pending = deferredNetworkIntents[1]
    if not pending then return false end
    local consensus = state.world.proposalConsensus or {}
    local operationConsensus = state.world.operationConsensus or {}
    if consensus.sessionFault or operationConsensus.sessionFault then
      local count = #deferredNetworkIntents
      deferredNetworkIntents = {}
      local fault = consensus.sessionFault or operationConsensus.sessionFault or {}
      state.lastError = tostring(count) .. " queued multiplayer physical action(s) discarded because the session faulted: "
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
          queueDepth = #deferredNetworkIntents,
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
          queueDepth = #deferredNetworkIntents,
          tick = state.tick,
        })
      end
      return false
    end
    table.remove(deferredNetworkIntents, 1)
    if state.networkMode ~= "network" then
      local discarded = 1 + #deferredNetworkIntents
      deferredNetworkIntents = {}
      state.lastError = tostring(discarded)
        .. " deferred multiplayer physical action(s) discarded because network mode ended"
      publishSnapshot()
      return true
    end
    local ok, result = emitNetworkIntent(pending.action)
    if ok then
      diagnosticLog("network-intent-deferred-emitted", {
        type = pending.action and pending.action.type or nil,
        deferredFromTick = pending.queuedTick,
        queueRemaining = #deferredNetworkIntents,
        localSeq = type(result) == "table" and result.local_seq or nil,
        tick = state.tick,
      })
      if type(state.lastResult) == "table" then
        state.lastResult.deferred = true
        state.lastResult.deferredFromTick = pending.queuedTick
        state.lastResult.queueRemaining = #deferredNetworkIntents
      end
    else
      local failureText = tostring(type(result) == "table" and result.error or result)
      if pending.action and pending.action.originCaptureToken then
        raiseOriginResidueFault("origin-applied-intent-emit-failed:" .. failureText, {
          actionType = tostring(pending.action.type or ""),
          originCaptureToken = tostring(pending.action.originCaptureToken),
        })
      end
      state.lastError = "deferred multiplayer physical action failed: " .. failureText
    end
    publishSnapshot()
    return true
  end
  
  local function consumeBridge()
    if state.networkMode ~= "network" then return end
    local authority = state.probes.networkAuthority or {}
    if authority.ready ~= true then
      state.lastError = "network authority is not ready: "
        .. tostring(authority.error or "native gates unavailable")
      return
    end
    for _, message in ipairs(bridge.poll(state.bridge, 16)) do
      if message.kind == "commit" and message.payload and message.payload.action then
        local originPeer = message.origin_peer or message.peer
        if networkIntentAwaitingOrder and originPeer == state.bridge.peerId
          and tonumber(message.origin_local_seq) == tonumber(networkIntentAwaitingOrder.localSeq) then
          networkIntentAwaitingOrder = nil
        end
        local ok, result, event = applyCommitted(message.payload.action, originPeer, message.seq)
        local acknowledgement = {
          commitSeq = message.seq,
          success = ok,
          digest = event and event.postDigest or coreDigest(),
        }
        if not ok then
          acknowledgement.error = tostring(type(result) == "table" and result.error or result)
        end
        bridge.emit(state.bridge, "ack", acknowledgement, state.tick)
        publishSnapshot()
      elseif message.kind == "control" and message.payload and message.payload.action then
        local action = message.payload.action
        if action.type == "network.intent_rejected" then
          local matchesOrigin = tostring(action.originPeer or "") == tostring(state.bridge.peerId)
            and networkIntentAwaitingOrder
            and tonumber(action.originLocalSeq) == tonumber(networkIntentAwaitingOrder.localSeq)
          local rejectedIntent = matchesOrigin and networkIntentAwaitingOrder or nil
          if matchesOrigin then networkIntentAwaitingOrder = nil end
          diagnosticLog("network-intent-rejected", {
            originPeer = action.originPeer,
            originLocalSeq = action.originLocalSeq,
            actionType = action.actionType,
            error = action.errorCode,
            released = matchesOrigin == true,
            tick = state.tick,
          })
          if matchesOrigin then
            if rejectedIntent.originCaptureToken then
              raiseOriginResidueFault(
                "origin-applied-intent-rejected:" .. tostring(action.errorCode or "unknown"), {
                  originLocalSeq = tonumber(action.originLocalSeq),
                  actionType = tostring(action.actionType or rejectedIntent.type or ""),
                  originCaptureToken = tostring(rejectedIntent.originCaptureToken),
                })
            else
              state.lastError = "network intent rejected: " .. tostring(action.errorCode or "unknown")
            end
          end
        else
          applyCommitted(action, message.origin_peer or "host", message.seq)
        end
        publishSnapshot()
      end
    end
  end

  return {
    submit = submitIntent,
    processDeferred = processDeferredNetworkIntent,
    consume = consumeBridge,
    pendingBarrierReason = networkPendingBarrierReason,
    raiseOriginResidueFault = raiseOriginResidueFault,
    awaitingOrder = function() return util.deepCopy(networkIntentAwaitingOrder) end,
    deferredIntents = function() return util.deepCopy(deferredNetworkIntents) end,
    reset = function()
      deferredNetworkIntents = {}
      networkIntentAwaitingOrder = nil
    end,
  }
end

return M
