local util = require "tpf2_mp/util"
local bridge = require "tpf2_mp/bridge"
local canonical = require "tpf2_mp/canonical"
local world = require "tpf2_mp/world"
local vehicleSyncState = require "tpf2_mp/vehicle_sync_state"
local vehicleSyncPassengers = require "tpf2_mp/vehicle_sync_passengers"
local M, disabledSchedule = {}, vehicleSyncState.disabledSchedule

M.digestView = vehicleSyncState.digestView
function M.new(deps)
  assert(type(deps) == "table" and type(deps.getState) == "function", "vehicle sync runtime state provider is required")
  local getState = deps.getState
  local diagnosticLog = assert(deps.diagnosticLog, "diagnostic logger is required")
  local component = deps.component or function(localId, componentType)
    local ok, value = pcall(api.engine.getComponent, localId, componentType)
    return ok and value or nil
  end
  local clockSnapshot = deps.clockSnapshot or world.clockSnapshot
  local commandFactory = deps.commandFactory or util.commandFactory
  local sendCommand = deps.sendCommand or util.sendCommand
  local authorizeCommand = deps.authorizeCommand or function(tag)
    local authorize = rawget(_G, "tpf2mp_native_authorize_command")
    if type(authorize) ~= "function" then
      return false, "native command authorization is unavailable"
    end
    local called, accepted, err = pcall(authorize, tostring(tag))
    if not called or accepted == false then return false, tostring(err or accepted) end
    return true
  end
  local emit = deps.emit or function(kind, payload, tick)
    return bridge.emit(getState().bridge, kind, payload, tick)
  end
  local state = setmetatable({}, {
    __index = function(_, key) return getState()[key] end,
    __newindex = function(_, key, value) getState()[key] = value end,
  })
  local localVehicles = {}

  local function safeField(value, key)
    if value == nil then return nil end
    local ok, result = pcall(function() return value[key] end)
    return ok and result or nil
  end

  local function probe()
    state.probes.vehicleSync = state.probes.vehicleSync or {
      managed = 0, held = 0, released = 0, faults = 0, reports = 0,
    }
    return state.probes.vehicleSync
  end

  local function now()
    local observed = clockSnapshot() or {}
    return tonumber(observed.time) or 0, tonumber(observed.gameSpeed), observed
  end

  local function report(binding, record, reportState, detail)
    local gameTime = now()
    local payload = {
      schemaVersion = 2,
      vehicleCid = binding.canonicalId,
      lineCid = tostring(record.lineCid),
      round = math.max(1, util.integer(record.round, 1)),
      stopIndex = math.max(0, util.integer(record.stopIndex, 0)),
      state = tostring(reportState),
      gameTime = gameTime,
      engineTick = math.max(0, util.integer(state.tick, 0)),
      detail = tostring(detail or ""),
      schedule = vehicleSyncState.reportSchedule(record.schedule),
    }
    local ok, result = emit("vehicle_sync", payload, state.tick)
    local telemetry = probe()
    if ok then
      telemetry.reports = (telemetry.reports or 0) + 1
      record.lastReportTick = state.tick
      record.lastReportedState = reportState
      if reportState == "released" then
        record.releaseReportPending = false
        telemetry.reportedReleases = telemetry.reportedReleases or {}
        telemetry.reportedReleases[binding.canonicalId] = math.max(
          util.integer(telemetry.reportedReleases[binding.canonicalId], 0),
          util.integer(record.round, 0))
      end
      telemetry.lastEvent = util.deepCopy(payload)
      telemetry.lastError = nil
    else
      telemetry.lastError = tostring(result)
    end
    return ok, result
  end

  local function fault(binding, record, message)
    local newlyFaulted = record.phase ~= "faulted"
    if newlyFaulted then
      record.phase = "faulted"
      record.error = tostring(message)
      local telemetry = probe()
      telemetry.faults = (telemetry.faults or 0) + 1
      telemetry.lastError = record.error
      diagnosticLog("vehicle-sync-fault", {
        vehicleCid = binding.canonicalId,
        lineCid = record.lineCid,
        round = record.round,
        stopIndex = record.stopIndex,
        error = record.error,
        tick = state.tick,
      })
    end
    if newlyFaulted or not record.lastReportTick or state.tick - record.lastReportTick >= 60 then
      report(binding, record, "fault", record.error)
    end
    return false, record.error
  end

  local function issueStopped(binding, record, localId, stopped, callback)
    local factory = commandFactory("setUserStopped")
    if not factory then return false, "setUserStopped factory is unavailable" end
    local made, commandOrError = pcall(factory, localId, stopped == true)
    if not made then return false, "could not create setUserStopped: " .. tostring(commandOrError) end
    local authorized, authorizeError = authorizeCommand(8)
    if not authorized then return false, tostring(authorizeError) end
    local sent, sendError = sendCommand(commandOrError, function(_, success)
      callback(success == true)
    end, stopped and "mod.vehicle-sync.hold" or "mod.vehicle-sync.release")
    if not sent then return false, "could not issue setUserStopped: " .. tostring(sendError) end
    return true
  end

  local function hold(binding, record, localId)
    record.schedule = vehicleSyncState.scheduleFor(
      state.economy, record.lineCid, record.stopIndex, world.synchronizationSchedule)
    record.phase = "holding"
    local sent, sendError = issueStopped(binding, record, localId, true, function(success)
      if success then
        record.phase = "held"
        record.lastReportTick = nil
        local telemetry = probe()
        telemetry.held = (telemetry.held or 0) + 1
        report(binding, record, "held", "canonical-stop-held")
      else
        fault(binding, record, "native station hold was rejected")
      end
    end)
    if not sent then return fault(binding, record, sendError) end
    return true
  end

  local function release(binding, record, localId, transportVehicle, observed)
    local metadata = binding.metadata or {}
    if metadata.userStopped == true then
      record.phase = "await-departure"
      record.lastReportTick = nil
      record.releaseReportPending = true
      report(binding, record, "released", "canonical-manual-stop-retained")
      return true
    end
    if safeField(transportVehicle, "userStopped") ~= true then
      record.phase = "await-departure"
      record.lastReportTick = nil
      record.releaseReportPending = true
      local telemetry = probe()
      telemetry.released = (telemetry.released or 0) + 1
      report(binding, record, "released", "already-released")
      return true
    end
    record.phase = "releasing"
    local sent, sendError = issueStopped(binding, record, localId, false, function(success)
      if success then
        record.phase = "await-departure"
        record.lastReportTick = nil
        record.releaseReportPending = true
        local telemetry = probe()
        telemetry.released = (telemetry.released or 0) + 1
        report(binding, record, "released", "canonical-stop-released")
      else
        fault(binding, record, "native station release was rejected")
      end
    end)
    if not sent then return fault(binding, record, sendError) end
    return true
  end

  local function processVehicle(binding)
    local localId = tonumber(binding.localId)
    local types = api and api.type and api.type.ComponentType or {}
    if not localId or not types.TRANSPORT_VEHICLE then return false end
    local vehicle = component(localId, types.TRANSPORT_VEHICLE)
    if not vehicle then return false end
    local nativeLine = tonumber(safeField(vehicle, "line"))
    local declaredLine = binding.metadata and binding.metadata.lineCid or nil
    local observedLine = nativeLine and canonical.resolveCanonical(state.canonical, "line", nativeLine) or nil
    if declaredLine and observedLine and declaredLine ~= observedLine then return false end
    local lineCid = declaredLine or observedLine
    if type(lineCid) ~= "string" or lineCid == "" then return false end
    local lineLocalId = tonumber(canonical.resolveLocal(state.canonical, lineCid))
    if lineLocalId and nativeLine ~= lineLocalId then return false end
    local nativeState = tonumber(safeField(vehicle, "state"))
    local stopIndex = tonumber(safeField(vehicle, "stopIndex"))
    stopIndex = stopIndex and math.floor(stopIndex) or nil
    local entry = vehicleSyncState.authoritativeEntry(state.world, binding.canonicalId)
    local lastRound = entry and math.max(0, util.integer(entry.lastAuthorizedRound, 0)) or 0
    local record = localVehicles[binding.canonicalId]
    if not record then
      local reportedReleases = probe().reportedReleases or {}
      record = {
        lineCid = lineCid,
        round = lastRound,
        phase = nativeState == 2 and "unknown-terminal" or "enroute",
        departedSinceRelease = nativeState ~= 2,
        stopIndex = entry and entry.stopIndex or nil,
        releaseReportPending = nativeState ~= 2 and lastRound > 0
          and util.integer(reportedReleases[binding.canonicalId], 0) < lastRound,
        schedule = entry and util.deepCopy(entry.schedule) or disabledSchedule(),
      }
      localVehicles[binding.canonicalId] = record
    end
    record.lineCid = lineCid
    if record.phase == "faulted" then return fault(binding, record, record.error) end
    if record.releaseReportPending
      and (not record.lastReportTick or state.tick - record.lastReportTick >= 60) then
      report(binding, record, "released", "canonical-stop-release-recovered")
    end
    if nativeState ~= 2 then
      if record.phase == "held" or record.phase == "holding"
        or record.phase == "release-armed" then
        return fault(binding, record, "vehicle departed before the ordered station release")
      end
      record.phase = "enroute"
      record.round = lastRound
      record.departedSinceRelease = true
      return true
    end
    if stopIndex == nil or stopIndex < 0 or stopIndex > 255 then
      return fault(binding, record, "terminal vehicle has no bounded stopIndex")
    end
    record.stopIndex = stopIndex
    if not vehicleSyncState.synchronizesStop(state.economy, lineCid, stopIndex) then
      local passed, passError = vehicleSyncState.passThrough(record, lastRound)
      if not passed then return fault(binding, record, passError) end
      local telemetry = probe(); telemetry.passThroughStops = (telemetry.passThroughStops or 0) + 1
      return true
    end
    if entry and entry.lastAuthorizedRound == lastRound
      and entry.lineCid == lineCid and entry.stopIndex == stopIndex
      and record.round <= lastRound and not record.departedSinceRelease
      and record.phase == "unknown-terminal" then
      record.round = lastRound
      record.phase = safeField(vehicle, "userStopped") == true
        and "release-armed" or "await-departure"
    elseif record.phase == "unknown-terminal" then
      if entry and entry.lineCid == lineCid and entry.stopIndex == stopIndex and lastRound > 0 then
        record.round = lastRound
        record.phase = safeField(vehicle, "userStopped") == true
          and "release-armed" or "await-departure"
      else
        record.round = lastRound + 1
        record.departedSinceRelease = false
        return hold(binding, record, localId)
      end
    elseif record.phase == "enroute" then
      record.round = lastRound + 1
      record.departedSinceRelease = false
      return hold(binding, record, localId)
    elseif record.phase == "held" then
      if not record.lastReportTick or state.tick - record.lastReportTick >= 60 then
        report(binding, record, "held", "canonical-stop-held-retry")
      end
    elseif record.phase == "release-armed" then
      local gameTime, _, observed = now()
      local due = entry and (entry.releaseWhilePaused == true
        or gameTime >= tonumber(entry.releaseAtGameTime or math.huge))
      if due then return release(binding, record, localId, vehicle, observed) end
    elseif record.phase == "await-departure" and record.releaseReportPending
      and (not record.lastReportTick or state.tick - record.lastReportTick >= 60) then
      report(binding, record, "released", "canonical-stop-release-retry")
    end
    return true
  end

  local runtime = {}

  function runtime.applyRelease(action)
    if state.networkMode ~= "network" then return false, "vehicle synchronization is network-only" end
    local vehicleCid = type(action) == "table" and tostring(action.vehicleCid or "") or ""
    local lineCid = type(action) == "table" and tostring(action.lineCid or "") or ""
    local round = util.integer(action and action.round, 0)
    local stopIndex = util.integer(action and action.stopIndex, -1)
    local releaseAt = tonumber(action and action.releaseAtGameTime)
    if not vehicleCid:match("^vehicle:") or not lineCid:match("^line:")
      or round < 1 or stopIndex < 0 or stopIndex > 255 or not releaseAt or releaseAt < 0
      or type(action.releaseWhilePaused) ~= "boolean" then
      return false, "invalid canonical vehicle release"
    end
    local releaseSchedule, scheduleError = vehicleSyncState.normalizeReleaseSchedule(
      action.schedule, releaseAt, action.releaseWhilePaused)
    if not releaseSchedule then return false, scheduleError end
    local binding = state.canonical.byCanonical[vehicleCid]
    if not binding or binding.kind ~= "vehicle" then
      return false, "canonical vehicle release target is not mapped"
    end
    local sync = state.world.vehicleSync
    local entry = sync.vehicles[vehicleCid]
    local priorRound = entry and math.max(0, util.integer(entry.lastAuthorizedRound, 0)) or 0
    if round < priorRound or round > priorRound + 1 then return false, "vehicle release round is not sequential" end
    if round == priorRound then
      local same = entry.lineCid == lineCid and entry.stopIndex == stopIndex
        and tonumber(entry.releaseAtGameTime) == releaseAt
        and entry.releaseWhilePaused == action.releaseWhilePaused
        and vehicleSyncState.equalSchedules(entry.schedule, releaseSchedule)
      if not same then return false, "conflicting duplicate vehicle release" end
      local aligned, alignmentError = vehicleSyncPassengers.applyRelease(
        state.world, state.economy, sync, action, binding.metadata)
      if not aligned then return false, alignmentError end
      return true, util.deepCopy(entry)
    end
    local presented, presentationResult = vehicleSyncPassengers.applyRelease(
      state.world, state.economy, sync, action, binding.metadata)
    if not presented then
      return false, presentationResult
    end
    sync.vehicles[vehicleCid] = {
      vehicleCid = vehicleCid,
      lineCid = lineCid,
      companyCid = binding.metadata and binding.metadata.owner or nil,
      lastAuthorizedRound = round,
      stopIndex = stopIndex,
      releaseAtGameTime = releaseAt,
      releaseWhilePaused = action.releaseWhilePaused == true,
      schedule = util.deepCopy(releaseSchedule),
    }
    sync.scheduleReservations = sync.scheduleReservations or {}
    if releaseSchedule.enabled == true then
      local reservationKey = lineCid .. "#" .. tostring(stopIndex)
      sync.scheduleReservations[reservationKey] = {
        lineCid = lineCid,
        stopIndex = stopIndex,
        periodSeconds = releaseSchedule.periodSeconds,
        phaseSeconds = releaseSchedule.phaseSeconds,
        lastSlotIndex = releaseSchedule.slotIndex,
        lastScheduledDepartureAt = releaseSchedule.scheduledDepartureAt,
      }
    else sync.scheduleReservations[lineCid .. "#" .. tostring(stopIndex)] = nil end
    local record = localVehicles[vehicleCid]
    if record then
      record.lineCid = lineCid
      record.round = round
      record.stopIndex = stopIndex
      record.schedule = util.deepCopy(releaseSchedule)
      record.phase = "release-armed"
    end
    return true, util.deepCopy(sync.vehicles[vehicleCid])
  end

  function runtime.onOperationConsensus(record)
    local transaction = record and record.transaction or nil
    local data = transaction and transaction.data or nil
    if type(transaction) ~= "table" or type(data) ~= "table" then return false end
    local sync = state.world.vehicleSync
    local function applyPassengerOperation()
      return vehicleSyncPassengers.applyOperation(
        state.world, state.economy, transaction, record.companyCid)
    end
    if transaction.kind == "vehicle.assign" then
      local binding = state.canonical.byCanonical[data.targetCid]
      local prior = sync.vehicles[data.targetCid] or {}
      sync.vehicles[data.targetCid] = {
        vehicleCid = data.targetCid,
        lineCid = data.lineCid,
        companyCid = record.companyCid,
        lastAuthorizedRound = math.max(0, util.integer(prior.lastAuthorizedRound, 0)),
        stopIndex = prior.stopIndex,
        releaseAtGameTime = prior.releaseAtGameTime,
        releaseWhilePaused = prior.releaseWhilePaused == true,
        schedule = util.deepCopy(prior.schedule or disabledSchedule()),
      }
      localVehicles[data.targetCid] = nil
      return applyPassengerOperation()
    elseif transaction.kind == "vehicle.sell" then
      sync.vehicles[data.targetCid] = nil
      localVehicles[data.targetCid] = nil
      return applyPassengerOperation()
    elseif transaction.kind == "line.delete" then
      for vehicleCid, entry in pairs(sync.vehicles) do
        if entry.lineCid == data.targetCid then
          sync.vehicles[vehicleCid] = nil
          localVehicles[vehicleCid] = nil
        end
      end
      for key, reservation in pairs(sync.scheduleReservations or {}) do
        if reservation.lineCid == data.targetCid then sync.scheduleReservations[key] = nil end
      end
      return applyPassengerOperation()
    end
    return false
  end

  function runtime.update()
    if state.networkMode ~= "network" or not state.initialized
      or state.world.vehicleSync.enabled == false then return false end
    local managed = 0
    for _, vehicleCid in ipairs(util.sortedKeys(state.canonical.byCanonical or {})) do
      local binding = state.canonical.byCanonical[vehicleCid]
      if binding.kind == "vehicle" then
        local ok, result = pcall(processVehicle, binding)
        if not ok then
          local lineCid = binding.metadata and binding.metadata.lineCid
          local entry = state.world.vehicleSync.vehicles[vehicleCid]
          lineCid = lineCid or (entry and entry.lineCid)
          if lineCid then
            local record = localVehicles[vehicleCid] or {
              lineCid = lineCid, round = 1, stopIndex = 0,
            }
            localVehicles[vehicleCid] = record
            fault(binding, record, result)
          else
            probe().lastError = tostring(result)
          end
        elseif result == true then
          managed = managed + 1
        end
      end
    end
    probe().managed = managed
    return true
  end

  function runtime.reset()
    localVehicles = {}
  end

  function runtime.localState()
    return util.deepCopy(localVehicles)
  end

  return runtime
end

return M
