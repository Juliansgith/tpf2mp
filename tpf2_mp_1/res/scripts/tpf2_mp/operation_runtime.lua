local util = require "tpf2_mp/util"
local hash = require "tpf2_mp/hash"
local canonical = require "tpf2_mp/canonical"
local bridge = require "tpf2_mp/bridge"
local world = require "tpf2_mp/world"
local economy = require "tpf2_mp/economy"
local operationCodec = require "tpf2_mp/operation_codec"
local vehiclePostcondition = require "tpf2_mp/operation_vehicle_postcondition"

local M = {}

-- Line-manager commands are the one intentional optimistic pass-through in
-- network mode.  Build 35924 asserts if its stock callback receives a rejected
-- CreateLine/UpdateLine result, so the origin may already have applied later
-- captured edits while an earlier edit is crossing the consensus barrier.
--
-- Each transaction still describes the complete line state produced by that
-- native command.  A replaying peer must physically match that intermediate
-- state exactly.  The optimistic origin instead attests the captured command's
-- state: a later captured edit is allowed to have advanced its live component,
-- and will itself be ordered next.  Capture/decode/transport loss faults the
-- session elsewhere, so this does not turn an unrecorded mutation into success.
function M.reconcileLinePostcondition(transaction, targetCid, observed, originApplied)
  if type(transaction) ~= "table"
    or (transaction.kind ~= "line.create" and transaction.kind ~= "line.update")
    or type(transaction.data) ~= "table"
    or type(transaction.data.line) ~= "table"
    or type(transaction.data.line.stops) ~= "table" then
    return nil, "line postcondition requires a valid line transaction"
  end
  if type(observed) ~= "table" or observed.exists ~= true then
    return nil, "native line target does not exist after operation"
  end
  local expected = {
    kind = transaction.kind,
    targetCid = targetCid,
    exists = true,
    stops = operationCodec.normaliseLineStops(transaction),
  }
  if originApplied == true then return expected end
  if hash.value(observed) ~= hash.value(expected) then
    return nil, "native line postcondition does not match the ordered transaction"
  end
  return expected
end

-- Apply only the portable metadata implied by a completed operation. Keeping
-- this pure makes lifecycle changes independently testable and prevents a
-- physically successful replacement from leaving the old consist in the
-- manager/economy projection until an unrelated assignment occurs.
function M.applyBindingMetadata(binding, transaction, companyCid)
  if type(binding) ~= "table" or type(transaction) ~= "table"
      or type(transaction.data) ~= "table" then return binding end
  local data = transaction.data
  binding.metadata = binding.metadata or {}
  binding.metadata.owner = binding.metadata.owner or companyCid
  binding.metadata.lastOperationDigest = transaction.digest
  if transaction.kind == "line.update" then
    binding.metadata.stops = util.deepCopy(data.line.stops)
  elseif transaction.kind == "vehicle.assign" then
    binding.metadata.lineCid = data.lineCid
  elseif transaction.kind == "vehicle.replace" then
    binding.metadata.models = util.deepCopy(data.config.vehicles)
  elseif transaction.kind == "entity.name" then
    binding.metadata.name = data.name
  elseif transaction.kind == "entity.color" then
    binding.metadata.color = util.deepCopy(data.color)
  elseif transaction.kind == "vehicle.stop" then
    binding.metadata.userStopped = data.stopped
  elseif transaction.kind == "vehicle.maintenance" then
    binding.metadata.maintenanceBasisPoints = data.valueBasisPoints
  end
  return binding
end

function M.new(env)
  assert(type(env) == "table", "operation runtime environment is required")
  assert(type(env.getState) == "function", "operation runtime state provider is required")
  assert(type(env.requireRunningMatch) == "function", "running-match guard is required")
  assert(type(env.balanceOf) == "function", "balance provider is required")
  assert(type(env.coreDigest) == "function", "core digest provider is required")
  assert(type(env.refreshOwnershipProbe) == "function", "ownership refresher is required")
  assert(type(env.proposalPreparation) == "table", "operation origin registry is required")

  local function currentState() return env.getState() end

  local function pruneOperationRecords(targetRetained)
    targetRetained = math.max(0, util.integer(targetRetained, 24))
    local records, completed = currentState().world.operations.byId, {}
    for operationId, record in pairs(records) do
      if record.status == "applied" or record.status == "failed" then
        completed[#completed + 1] = {
          operationId = operationId,
          completedTick = util.integer(record.completedTick, record.queuedTick or 0),
        }
      end
    end
    table.sort(completed, function(a, b)
      if a.completedTick ~= b.completedTick then return a.completedTick < b.completedTick end
      return tostring(a.operationId) < tostring(b.operationId)
    end)
    for _, item in ipairs(completed) do
      if util.tableCount(records) <= targetRetained then break end
      records[item.operationId] = nil
      currentState().world.operationConsensus.byId[item.operationId] = nil
    end
  end
  
  local function operationResolve(record, cid, expectedKind)
    local localId = record.localRefs and record.localRefs[cid]
      or canonical.resolveLocal(currentState().canonical, cid)
    if not localId then return nil, "canonical object is not mapped locally: " .. tostring(cid) end
    local binding = currentState().canonical.byCanonical[cid]
    if expectedKind and expectedKind ~= "entity" and binding and binding.kind ~= expectedKind then
      return nil, "canonical object kind mismatch for " .. tostring(cid)
    end
    return tonumber(localId)
  end
  
  local function operationOwner(localId)
    return world.logicalOwnerOf(currentState().world, currentState().companies, localId)
  end
  
  local function operationAccess(transaction, cid, expectedKind, localRefs)
    local binding = currentState().canonical.byCanonical[cid]
    local localId = binding and binding.localId or canonical.resolveLocal(currentState().canonical, cid)
    if not localId then return false, "canonical object is not mapped locally: " .. tostring(cid) end
    if currentState().networkMode == "network" and cid:find(":pre:", 1, true)
      and not (binding and binding.metadata and binding.metadata.manifestBound == true) then
      return false, "pre-existing object is not uniquely bound by the world manifest: " .. tostring(cid)
    end
    if expectedKind and expectedKind ~= "entity" and binding and binding.kind ~= expectedKind then
      return false, "canonical object kind mismatch for " .. tostring(cid)
    end
    local owner = operationOwner(localId)
    local metadataOwner = binding and binding.metadata and binding.metadata.owner or nil
    owner = owner or metadataOwner
    if owner and owner ~= transaction.companyCid then
      return false, "operation cannot mutate rival-owned " .. tostring(expectedKind or "entity")
        .. " " .. tostring(cid)
    end
    localRefs[cid] = localId
    return true, localId
  end
  
  local function queueCanonicalOperation(transaction, eventId, commitSeq, originCaptureToken)
    local running, runningError = env.requireRunningMatch()
    if not running then return false, runningError end
    local valid, validationError = operationCodec.validate(transaction)
    if not valid then return false, validationError end
    local company = currentState().companies[transaction.companyCid]
    if not company then return false, "operation targets an unknown company" end
    if util.tableCount(currentState().world.operations.byId) >= 48 then pruneOperationRecords(24) end
    if util.tableCount(currentState().world.operations.byId) >= 48 then
      return false, "too many in-flight canonical operations"
    end
    if currentState().world.operations.byId[eventId] then return false, "duplicate canonical operation event" end
  
    local data, localRefs = transaction.data, {}
    local spec = operationCodec.spec(transaction.kind)
    if data.targetCid then
      local ok, err = operationAccess(transaction, data.targetCid, spec.targetKind, localRefs)
      if not ok then return false, err end
    end
    if data.depotCid then
      local ok, err = operationAccess(transaction, data.depotCid, "depot", localRefs)
      if not ok then return false, err end
    end
    if data.lineCid then
      local ok, err = operationAccess(transaction, data.lineCid, "line", localRefs)
      if not ok then return false, err end
    end
    if data.line and type(data.line.stops) == "table" then
      for _, stop in ipairs(data.line.stops) do
        local cid = stop.stationGroupCid
        local binding = currentState().canonical.byCanonical[cid]
        local localId = binding and binding.localId or canonical.resolveLocal(currentState().canonical, cid)
        if not localId then return false, "line stop is not mapped locally: " .. tostring(cid) end
        if currentState().networkMode == "network" and cid:find(":pre:", 1, true)
          and not (binding and binding.metadata and binding.metadata.manifestBound == true) then
          return false, "station group is ambiguous in the pre-existing world manifest: " .. tostring(cid)
        end
        -- Public station groups are legal; a positively identified rival group
        -- is not. This keeps shared/public infrastructure possible without
        -- reopening the rival-asset mutation hole.
        local owner = operationOwner(localId)
        if owner and owner ~= transaction.companyCid then
          return false, "line cannot use a rival-owned station group: " .. tostring(cid)
        end
        localRefs[cid] = localId
      end
    end
  
    local originPeer = tostring(eventId):match(":([^:]+):%d+$")
    local originApplied
    originCaptureToken = originCaptureToken ~= nil and tostring(originCaptureToken) or nil
    if originPeer == currentState().bridge.peerId and originCaptureToken then
      originApplied = env.proposalPreparation.originAppliedOperations[originCaptureToken]
      env.proposalPreparation.originAppliedOperations[originCaptureToken] = nil
      -- Custody ends when the ordered commit takes the record; release the
      -- persisted marker so a later save/load does not re-report this loss.
      local custody = currentState().world and currentState().world.originResidueCustody or nil
      if custody then custody[originCaptureToken] = nil end
      if not originApplied then
        return false, "optimistic local operation result is unavailable for "
          .. tostring(originCaptureToken)
      end
      if originApplied.transactionId ~= transaction.transactionId
        or originApplied.kind ~= transaction.kind
        or originApplied.companyCid ~= transaction.companyCid then
        return false, "optimistic local operation result does not match the ordered transaction"
      end
    end
  
    local issuerPlayerId = game.interface.getPlayer()
    local nativePlayerId = currentState().world.proxyMode and issuerPlayerId or company.playerId
    local record = {
      operationId = eventId,
      transactionId = transaction.transactionId,
      eventId = eventId,
      commitSeq = tonumber(commitSeq),
      originPeer = originPeer,
      originCaptureToken = originCaptureToken,
      originApplied = originApplied and {
        localId = tonumber(originApplied.localId),
        capturedTick = tonumber(originApplied.capturedTick),
      } or nil,
      companyCid = transaction.companyCid,
      transaction = util.deepCopy(transaction),
      localRefs = localRefs,
      issuerPlayerId = tonumber(issuerPlayerId),
      nativePlayerId = tonumber(nativePlayerId),
      balanceBefore = env.balanceOf(nativePlayerId),
      status = "queued",
      queuedTick = currentState().tick,
    }
    if record.balanceBefore == nil then return false, "operation company balance is unavailable" end
    currentState().world.operations.byId[eventId] = record
    currentState().world.operations.queued = (currentState().world.operations.queued or 0) + 1
    if currentState().networkMode == "network" then
      currentState().world.operationConsensus.byId[eventId] = {
        operationId = eventId,
        commitSeq = tonumber(commitSeq),
        operationDigest = transaction.digest,
        status = "pending",
      }
    end
    return true, {
      queued = true,
      operationId = eventId,
      transactionId = transaction.transactionId,
      operationDigest = transaction.digest,
      kind = transaction.kind,
      companyCid = transaction.companyCid,
    }
  end
  
  local function operationFailure(record, message)
    local value = type(message) == "table" and message or { error = tostring(message) }
    if value.error == nil then value.error = "canonical operation failed" end
    record.status = "failed"
    record.completedTick = currentState().tick
    record.error = tostring(value.error)
    record.result = util.deepCopy(value)
    currentState().world.operations.failed = (currentState().world.operations.failed or 0) + 1
    currentState().probes.capture.operationReplayFailureCount =
      (currentState().probes.capture.operationReplayFailureCount or 0) + 1
    return false, record.result
  end
  
  local function safeOperationComponent(localId, componentType)
    if not componentType then return nil end
    local ok, value = pcall(api.engine.getComponent, localId, componentType)
    return ok and value or nil
  end
  
  local function operationPostcondition(record, outputCid, outputLocalId)
    local transaction, data = record.transaction, record.transaction.data
    local kind, types = transaction.kind, api.type.ComponentType
    local targetCid = outputCid or data.targetCid
    local localId = outputLocalId
    if not localId and data.targetCid then localId = operationResolve(record, data.targetCid) end
    if kind == "line.delete" or kind == "vehicle.sell" then
      return { kind = kind, targetCid = data.targetCid, exists = world.entityExists(localId) }
    end
    if not localId or not world.entityExists(localId) then
      return nil, "operation output/target does not exist after native success"
    end
    local result = { kind = kind, targetCid = targetCid, exists = true }
    if kind == "line.create" or kind == "line.update" then
      local line = safeOperationComponent(localId, types.LINE)
      if not line then return nil, "native line component is unavailable after operation" end
      result.stops = {}
      for _, stop in ipairs(line.stops or {}) do
        local groupId = tonumber(stop.stationGroup or stop.group or stop.station)
        local cid = groupId and canonical.resolveCanonical(currentState().canonical, "station_group", groupId) or nil
        if not cid then return nil, "native line contains an unmapped station group" end
        local alternativeTerminals = {}
        for _, alternative in ipairs(stop.alternativeTerminals or {}) do
          alternativeTerminals[#alternativeTerminals + 1] = {
            station = util.integer(alternative.station, 0),
            terminal = util.integer(alternative.terminal, 0),
          }
        end
        result.stops[#result.stops + 1] = {
          stationGroupCid = cid,
          station = util.integer(stop.station, 0),
          terminal = util.integer(stop.terminal, 0),
          alternativeTerminals = alternativeTerminals,
        }
      end
      return M.reconcileLinePostcondition(
        transaction, targetCid, result, type(record.originApplied) == "table")
    elseif kind:sub(1, 8) == "vehicle." then
      local vehicle = safeOperationComponent(localId, types.TRANSPORT_VEHICLE)
      if not vehicle then return nil, "native vehicle component is unavailable after operation" end
      result.userStopped = vehicle.userStopped == true
      result.sellOnArrival = vehicle.sellOnArrival == true
      local lineId = tonumber(vehicle.line)
      if lineId and lineId >= 0 then
        result.lineCid = canonical.resolveCanonical(currentState().canonical, "line", lineId)
      end
      result.stopIndex = tonumber(vehicle.stopIndex)
      local projection = vehiclePostcondition.project(vehicle, api)
      result.vehicleParts = projection.vehicleParts
      if kind == "vehicle.buy" or kind == "vehicle.replace" or kind == "vehicle.reverse" then
        result.vehicleConfig = projection.vehicleConfig
        result.vehicleConfigKnown = projection.vehicleConfigKnown
      elseif kind == "vehicle.maintenance" then
        result.targetMaintenanceBasisPoints = projection.targetMaintenanceBasisPoints
        result.targetMaintenanceKnown = projection.targetMaintenanceKnown
      end
      -- This is the same resolved annual figure the stock purchase and vehicle
      -- detail windows display after all vanilla/modded model modifiers have
      -- run.  Keeping it in the physical postcondition makes every peer agree
      -- on the economic basis instead of re-implementing the engine's private
      -- automatic-cost formula or trusting a single machine's resource data.
      local maintenance = safeOperationComponent(localId, types.MAINTENANCE_COST)
      local annual = maintenance and tonumber(maintenance.maintenanceCost) or nil
      if annual and annual >= 0 then
        result.annualMaintenanceDollars = math.max(0, util.integer(annual, 0))
      end
      local postconditionOk, postconditionError = vehiclePostcondition.validate(transaction, result)
      if not postconditionOk then return nil, postconditionError end
    elseif kind == "entity.name" then
      local name = safeOperationComponent(localId, types.NAME)
      result.name = name and tostring(name.name or "") or nil
      if result.name ~= data.name then
        return nil, "native entity name does not match the ordered transaction"
      end
    elseif kind == "entity.color" then
      -- Color userdata layout has varied between API states. Callback success,
      -- target existence, and the canonical transaction remain authoritative;
      -- retain an explicit marker instead of guessing component fields.
      result.colorApplied = safeOperationComponent(localId, types.COLOR) ~= nil
    end
    return result
  end
  
  local function bindOperationOutput(record, localId)
    local spec = operationCodec.spec(record.transaction.kind)
    if not spec.outputKind then return nil end
    if not localId or not world.entityExists(localId) then
      return nil, "native operation did not produce a valid local output"
    end
    if world.kindOf(localId) ~= spec.outputKind then
      return nil, "native operation output kind mismatch"
    end
    local cid = canonical.createdId(spec.outputKind, record.eventId, 1)
    local metadata = {
      owner = record.companyCid,
      operationDigest = record.transaction.digest,
      outputSlot = spec.outputKind .. ":1",
    }
    if spec.outputKind == "line" then
      metadata.name = record.transaction.data.name
      metadata.stops = util.deepCopy(record.transaction.data.line.stops)
    elseif spec.outputKind == "vehicle" then
      metadata.models = util.deepCopy(record.transaction.data.config.vehicles)
      metadata.depotCid = record.transaction.data.depotCid
    end
    local ok, err = canonical.bind(currentState().canonical, cid, spec.outputKind, localId, metadata)
    if not ok then return nil, err end
    currentState().world.logicalOwners[tostring(localId)] = record.companyCid
    return { kind = spec.outputKind, cid = cid, slot = spec.outputKind .. ":1", localId = localId }
  end
  
  local function applyOperationMetadata(record)
    local transaction, data = record.transaction, record.transaction.data
    local binding = data.targetCid and currentState().canonical.byCanonical[data.targetCid] or nil
    M.applyBindingMetadata(binding, transaction, record.companyCid)
    if transaction.kind == "line.delete" or transaction.kind == "vehicle.sell" then
      local localId = binding and binding.localId or record.localRefs[data.targetCid]
      canonical.unbindCanonical(currentState().canonical, data.targetCid)
      if localId then currentState().world.logicalOwners[tostring(localId)] = nil end
      -- A deleted line must stop earning. Without this the registered service
      -- keeps its capacity and settles revenue every accounting tick forever, on every
      -- peer identically, so no digest would ever catch it.
      if transaction.kind == "line.delete" then
        economy.removeService(currentState().economy, data.targetCid)
      end
    end
  end
  
  local function emitOperationCompletion(record, success, result)
    if currentState().networkMode ~= "network" or record.completionEmitted == true then return true end
    local outputs = {}
    for _, output in ipairs(success and type(result) == "table" and (result.outputs or {}) or {}) do
      outputs[#outputs + 1] = { kind = output.kind, cid = output.cid, slot = output.slot }
    end
    local view = {
      operationId = record.operationId,
      commitSeq = tonumber(record.commitSeq),
      operationDigest = record.transaction.digest,
      success = success == true,
      outputs = outputs,
      postcondition = success and util.deepCopy(result.postcondition) or {},
      coreDigest = env.coreDigest(),
    }
    local payload = util.deepCopy(view)
    payload.financeDelta = success and util.integer(result.financeDelta, 0) or nil
    payload.resultDigest = hash.value(view)
    if not success then payload.errorCode = "native-operation-failed" end
    local emitted, messageOrError = bridge.emit(
      currentState().bridge, "operation_completion", payload, currentState().tick)
    if not emitted then record.completionError = tostring(messageOrError); return false, record.completionError end
    record.completionEmitted = true
    record.completionError = nil
    record.completion = util.deepCopy(payload)
    return true, payload
  end
  
  local function finaliseCanonicalOperation(payload)
    payload = type(payload) == "table" and payload or {}
    local operationId = tostring(payload.operationId or "")
    local record = currentState().world.operations.byId[operationId]
    if not record then return false, "unknown pending canonical operation" end
    if record.status == "applied" then return true, util.deepCopy(record.result) end
    if record.status == "failed" then return false, util.deepCopy(record.result) end
    if payload.success ~= true then
      local ok, result = operationFailure(record,
        { error = tostring(payload.error or "GUI-state native operation was rejected") })
      emitOperationCompletion(record, false, result)
      return ok, result
    end
  
    local output
    if operationCodec.spec(record.transaction.kind).outputKind then
      local bound, bindError = bindOperationOutput(record, tonumber(payload.outputLocalId))
      if not bound then
        local ok, result = operationFailure(record, bindError)
        emitOperationCompletion(record, false, result)
        return ok, result
      end
      output = bound
    end
    local postcondition, postError = operationPostcondition(
      record, output and output.cid or nil, output and output.localId or nil)
    if not postcondition then
      if output then canonical.unbindCanonical(currentState().canonical, output.cid) end
      local ok, result = operationFailure(record, postError)
      emitOperationCompletion(record, false, result)
      return ok, result
    end
    if (record.transaction.kind == "line.delete" or record.transaction.kind == "vehicle.sell")
      and postcondition.exists == true then
      local ok, result = operationFailure(record, "native delete/sell left the target entity alive")
      emitOperationCompletion(record, false, result)
      return ok, result
    end
    -- Keep the old assignment long enough for the post-consensus follow-up to
    -- refresh both affected services. applyOperationMetadata intentionally
    -- unbinds a sold vehicle, so this fact would otherwise disappear before
    -- the owning peer can remove its seats/upkeep from the old line.
    if record.transaction.kind == "vehicle.assign"
      or record.transaction.kind == "vehicle.sell" then
      local targetCid = record.transaction.data and record.transaction.data.targetCid
      local targetBinding = targetCid and currentState().canonical.byCanonical[targetCid] or nil
      record.previousLineCid = targetBinding and targetBinding.metadata
        and targetBinding.metadata.lineCid or nil
    end
    applyOperationMetadata(record)
    local balanceAfter = tonumber(payload.balanceAfter) or env.balanceOf(record.nativePlayerId)
    local financeDelta = tonumber(payload.financeDelta) ~= nil
      and util.integer(payload.financeDelta, 0)
      or (balanceAfter and record.balanceBefore
        and util.integer(balanceAfter - record.balanceBefore, 0) or 0)
    local result = {
      operationId = operationId,
      transactionId = record.transaction.transactionId,
      operationDigest = record.transaction.digest,
      kind = record.transaction.kind,
      companyCid = record.companyCid,
      outputs = output and { {
        kind = output.kind, cid = output.cid, slot = output.slot,
      } } or {},
      postcondition = postcondition,
      financeDelta = financeDelta,
    }
    record.status = "applied"
    record.completedTick = currentState().tick
    record.result = util.deepCopy(result)
    -- Standalone has no consensus outcome to hang auto-registration on, so a
    -- completed local operation is itself the trigger. Network mode registers
    -- after both peers agree, in the operation-outcome handler.
    if currentState().networkMode ~= "network" and env.autoRegisterLine then
      pcall(env.autoRegisterLine, record.transaction, output and output.cid or nil)
    end
    currentState().world.operations.applied = (currentState().world.operations.applied or 0) + 1
    currentState().probes.capture.operationReplayCount =
      (currentState().probes.capture.operationReplayCount or 0) + 1
    env.refreshOwnershipProbe()
    emitOperationCompletion(record, true, result)
    return true, result
  end
  
  
  return {
    queue = queueCanonicalOperation,
    finalise = finaliseCanonicalOperation,
    emitCompletion = emitOperationCompletion,
  }
end

return M
