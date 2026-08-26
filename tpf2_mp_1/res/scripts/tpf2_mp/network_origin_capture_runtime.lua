local util = require "tpf2_mp/util"

local M = {}

function M.new(deps)
  local getState = assert(deps.getState, "getState dependency is required")
  local normaliseOperationCapture = assert(
    deps.normaliseOperationCapture, "normaliseOperationCapture dependency is required")
  local emitNetworkIntent = assert(deps.emitNetworkIntent, "emitNetworkIntent dependency is required")
  local activeCompany = assert(deps.activeCompany, "activeCompany dependency is required")
  local publishSnapshot = assert(deps.publishSnapshot, "publishSnapshot dependency is required")
  local diagnosticLog = assert(deps.diagnosticLog, "diagnosticLog dependency is required")
  local maximum = assert(tonumber(deps.maximum), "maximum dependency is required")

  local function capturePayload(action)
    if type(action) ~= "table" or action.type ~= "operation.capture" then return nil end
    return type(action.capture) == "table" and action.capture or action
  end

  -- Rejection of an already-applied vanilla command proves divergence. Fault
  -- closed and request the ordered pause still allowed to a faulted session.
  local function raise(errorCode, detail)
    local state = getState()
    if state.networkMode ~= "network" then return false end
    local consensus = state.world.operationConsensus
    if consensus.sessionFault then return true end
    local fault = {
      success = false, status = "faulted", errorCode = tostring(errorCode),
      detail = detail and util.deepCopy(detail) or nil,
      originPeer = tostring(state.bridge.peerId or ""), tick = state.tick,
    }
    consensus.failed = (consensus.failed or 0) + 1
    consensus.lastOutcome, consensus.sessionFault = util.deepCopy(fault), fault
    diagnosticLog("origin-applied-residue-fault", {
      errorCode = fault.errorCode,
      detail = fault.detail and util.deepCopy(fault.detail) or nil,
      tick = state.tick,
    })
    local called, emitOk, emitError = pcall(
      emitNetworkIntent, { type = "clock.request", requestedSpeed = 0 })
    if not called or emitOk ~= true then
      diagnosticLog("origin-residue-pause-failed", {
        error = tostring(not called and emitOk or emitError), tick = state.tick,
      })
    end
    state.lastError = "network session is faulted: " .. tostring(errorCode)
    publishSnapshot()
    return true
  end

  local function reject(action, errorCode, detail)
    local token = type(action) == "table" and action.originCaptureToken or nil
    if not token then return false end
    detail = type(detail) == "table" and util.deepCopy(detail) or {}
    detail.actionType = detail.actionType or tostring(action.type or "")
    detail.originCaptureToken = tostring(token)
    raise(tostring(errorCode), detail)
    return true
  end

  local function normalise(action)
    local state, capture = getState(), capturePayload(action) or {}
    local rawResidueToken = type(action) == "table" and action.rawOriginResidueToken or nil
    local called, normalized, normalizeError = pcall(normaliseOperationCapture, action)
    if not called then
      normalized, normalizeError = nil,
        "operation capture normalization failed: " .. tostring(normalized)
    end
    -- The canonical normalizer creates the ordinary token-bearing custody
    -- record on success. On rejection it creates a definitive session fault.
    -- Either outcome discharges this provisional pre-normalization marker.
    if rawResidueToken and state.world and state.world.originResidueCustody then
      state.world.originResidueCustody[tostring(rawResidueToken)] = nil
    end
    if normalized then return normalized end
    if capture.originApplied == true then
      raise("origin-applied-capture-rejected:" .. tostring(normalizeError), {
        kind = tostring(capture.kind or ""),
        targetLocalId = tonumber(capture.targetLocalId or capture.originLocalId),
      })
    end
    state.lastError = tostring(normalizeError)
    return nil, normalizeError
  end

  local function pendingReason(barrierReason, awaitingOrder, queueDepth)
    local reason = barrierReason
    if not reason and awaitingOrder then
      reason = "local intent is awaiting its host order: "
        .. tostring(awaitingOrder.localSeq or "-")
    end
    if not reason and queueDepth > 0 then
      reason = "earlier multiplayer physical actions are queued locally"
    end
    return reason
  end

  -- Native line commands have to complete on the origin so the stock Line
  -- Manager receives its real EntityRev. Preserve dependent raw captures FIFO
  -- and normalize each only when its predecessor has committed and bound.
  local function defer(queue, action, reason)
    local state, capture = getState(), capturePayload(action) or {}
    if #queue < maximum then
      local queuedAction = util.deepCopy(action)
      if capture.originApplied == true then
        state.world.originResidueNextToken = math.max(1,
          tonumber(state.world.originResidueNextToken) or 1)
        local sequence = state.world.originResidueNextToken
        state.world.originResidueNextToken = sequence + 1
        local token = tostring(state.bridge.peerId)
          .. ":operation-raw:" .. tostring(sequence)
        state.world.originResidueCustody = state.world.originResidueCustody or {}
        state.world.originResidueCustody[token] = {
          kind = tostring(capture.kind or ""), capturedTick = state.tick,
        }
        queuedAction.rawOriginResidueToken = token
      end
      queue[#queue + 1] = {
        action = queuedAction, companyCid = action.companyCid or activeCompany(),
        queuedTick = state.tick, reason = reason, rawOperationCapture = true,
      }
      local position = #queue
      diagnosticLog("network-intent-deferred", {
        type = action.type, captureKind = tostring(capture.kind or ""),
        companyCid = queue[position].companyCid, reason = reason,
        queuePosition = position, queueDepth = position,
        rawOperationCapture = true, tick = state.tick,
      })
      state.lastAction = {
        type = action.type, captureKind = tostring(capture.kind or ""),
        deferred = true, queuePosition = position,
      }
      state.lastResult = {
        queued = true, deferred = true, queuedTick = state.tick, reason = reason,
        queuePosition = position, queueDepth = position, queueCapacity = maximum,
        rawOperationCapture = true,
      }
      state.lastError = nil
      publishSnapshot()
      return true, util.deepCopy(state.lastResult)
    end
    local errorText = "multiplayer physical-action queue is full ("
      .. tostring(maximum) .. "); wait for synchronization"
    if capture.originApplied == true then
      raise("origin-applied-deferred-queue-full", {
        actionType = "operation.capture", kind = tostring(capture.kind or ""),
        targetLocalId = tonumber(capture.targetLocalId or capture.originLocalId),
        queueDepth = #queue, queueCapacity = maximum, reason = reason,
      })
      return false, state.lastError
    end
    state.lastError = errorText
    publishSnapshot()
    return false, errorText
  end

  return {
    raise = raise,
    reject = reject,
    normalise = normalise,
    pendingReason = pendingReason,
    defer = defer,
  }
end

return M
