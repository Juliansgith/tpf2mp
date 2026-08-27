local util = require "tpf2_mp/util"
local pumpErrors = require "tpf2_mp/network_pump_errors"
local M = {}

function M.new(deps)
  assert(type(deps) == "table" and type(deps.getState) == "function",
    "network pump state provider is required")
  local getState = deps.getState
  local performance = assert(deps.performance, "network pump performance runtime is required")
  local errors = pumpErrors.new(deps.getState)
  local continuationFenced = deps.continuationFenced or function() return false end

  local function protected(name, callable, onError, ...)
    local invoked, result = performance.run(name, callable, ...)
    if not invoked and onError then onError(tostring(result)) end
    return invoked, result
  end

  local function vehicleStride(state)
    return next((state.world and state.world.vehicleSync or {}).vehicles or {}) ~= nil and 1 or 30
  end

  local function contentStride(state)
    local content = state.world and state.world.industryContent or {}
    return (content.ready == true or content.fault ~= nil) and 300 or 15
  end

  local function freightStride(state)
    local freight = state.world and state.world.freightIndustry or {}
    return (freight.ready == true or type(freight.migrationError) == "string") and 300 or 15
  end

  local function prepareRestoreIfRequested(cfg)
    local state = getState()
    if cfg.automaticRecoveryPrepare ~= true or state.bridge.peerId ~= "player1"
      or state.initialized ~= true or not state.match or state.match.status ~= "running" then
      return true
    end
    state.probes = type(state.probes) == "table" and state.probes or {}
    local marker = type(state.probes.launcherRecoveryPrepare) == "table"
      and state.probes.launcherRecoveryPrepare or {}
    state.probes.launcherRecoveryPrepare = marker
    if marker.submitted == true then return true end
    local work = deps.localWorkState()
    if type(work) == "table" and work.pending == true then return true end
    local ok, result = deps.submitIntent({ type = "recovery.prepare" })
    if ok == true then
      marker.submitted = true
      marker.tick = state.tick
      marker.localSeq = type(result) == "table" and result.local_seq or nil
      marker.error = nil
      return true
    end
    marker.error = tostring(result)
    return false
  end

  local function pump(includeHealth)
    local state = getState()
    if state.networkMode ~= "network" then return true end
    local cfg = deps.config()
    local restore = state.recovery and state.recovery.restoreResume or nil
    local restoreFenced = type(cfg.restoreResume) == "table"
      and cfg.restoreResume.requested == true
      and (type(restore) ~= "table" or restore.status ~= "committed")
    local startupFenced = restoreFenced or continuationFenced() == true
    local native = deps.bridge.isNative(state.bridge)
    local consumeStride = native and 1
      or math.max(1, util.integer(cfg.networkBridgeFallbackStride, 1))
    local consumeOk = true
    if performance.due("bridge.consume", consumeStride, includeHealth == false) then
      consumeOk = protected("bridge.consume", deps.consumeBridge, errors.bridge)
    end
    local clockOk = true; if type(deps.networkClock.needsUpdate) ~= "function" or deps.networkClock.needsUpdate() then
      clockOk = protected("clock.update", deps.networkClock.update, errors.clock)
    end
    local economyClockOk = true
    if not startupFenced and (type(deps.economyClock.needsUpdate) ~= "function"
      or deps.economyClock.needsUpdate()) then
      economyClockOk = protected("economy-clock.update", deps.economyClock.update, errors.probe)
    end
    local vehicleOk = true
    if not startupFenced and performance.due("vehicle-sync.update", vehicleStride(state)) then
      vehicleOk = protected("vehicle-sync.update", deps.vehicleSync.update, errors.vehicle)
    end
    local deferredOk = true
    if not startupFenced and (type(deps.hasDeferred) ~= "function" or deps.hasDeferred()) then
      deferredOk = protected("network-intent.deferred", deps.processDeferred, errors.deferred)
    end
    local operationHoldOk = true; if not startupFenced
      and type(deps.networkClock.hasOperationHold) == "function"
      and deps.networkClock.hasOperationHold() then
      operationHoldOk = protected("clock.operation-hold",
        deps.networkClock.maintainOperationHold, errors.clock)
    end
    -- Continuation re-attests content while gameplay stays fenced; a receipt-
    -- bound restore retains its pre-proven content profile.
    local contentOk = true; if not restoreFenced and performance.due(
      "industry-content.maintain", contentStride(state)) then
      contentOk = protected("industry-content.maintain", deps.industryContent.maintain,
        errors.industry,
        deps.getState(), {
          readFacts = deps.world.industryResourceProbe,
          localWorkState = deps.localWorkState,
          submitIntent = deps.submitIntent,
        })
    end
    local freightOk = true
    if not startupFenced and performance.due("freight-industry.maintain", freightStride(state)) then
      local invoked, result = protected(
        "freight-industry.maintain", deps.freightIndustry.pump,
        errors.freight,
        deps.getState(), {
          readFacts = deps.world.industryBootstrapFacts,
          localWorkState = deps.localWorkState,
          submitIntent = deps.submitIntent,
        })
      freightOk = invoked and result == true
    end
    local prepareOk = startupFenced or prepareRestoreIfRequested(cfg); local healthOk, healthDue = true, includeHealth == false
      or performance.due("clock.health", 15)
    if healthDue then
      local health = includeHealth == false
        and deps.networkClock.emitPausedHealth or deps.networkClock.emitHealth
      healthOk = protected("clock.health", health, errors.clock)
    end
    if performance.due("bridge.status", 60) then
      local invoked, status = performance.run(
        "bridge.status", deps.bridge.nativeStatus, state.bridge)
      if invoked then performance.setNativeBridge(status) end
    end
    return consumeOk and clockOk and economyClockOk and vehicleOk and deferredOk
      and operationHoldOk and contentOk and freightOk and prepareOk and healthOk
  end

  return { pump = pump }
end

return M
