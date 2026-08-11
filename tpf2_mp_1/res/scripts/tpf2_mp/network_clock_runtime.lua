local util = require "tpf2_mp/util"
local bridge = require "tpf2_mp/bridge"
local heartbeatModule = require "tpf2_mp/network_clock_heartbeat"
local world = require "tpf2_mp/world"
local restoreBootstrapRuntime = require "tpf2_mp/restore_bootstrap_runtime"
local M = {}
function M.new(deps)
  assert(type(deps) == "table", "network clock runtime dependencies are required")
  local getState = assert(deps.getState, "getState dependency is required")
  local config = assert(deps.config, "config dependency is required")
  local diagnosticLog = assert(deps.diagnosticLog, "diagnosticLog dependency is required")
  local submitIntent = assert(deps.submitIntent, "submitIntent dependency is required")
  local awaitingOrder = assert(deps.awaitingOrder, "awaitingOrder dependency is required")
  local networkPendingBarrierReason =
    assert(deps.pendingBarrierReason, "pendingBarrierReason dependency is required")
  local localWorkState = deps.localWorkState or function()
    return { pending = awaitingOrder() ~= nil or networkPendingBarrierReason() ~= nil,
      deferredCount = 0 }
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
  local wallTime = deps.wallTime or function()
    if not (os and type(os.time) == "function") then return nil end
    local ok, value = pcall(os.time)
    return ok and tonumber(value) or nil
  end
  local state = setmetatable({}, {
    __index = function(_, key) return getState()[key] end,
    __newindex = function(_, key, value) getState()[key] = value end,
  })
  local networkClock = {
    manualBootstrap = { nextAttemptTick = 240, attempts = 0, submitted = false },
  }
  local heartbeat = heartbeatModule.new({
    getState = getState, clockSnapshot = clockSnapshot,
    localWorkState = localWorkState, emit = emit, wallTime = wallTime,
  })
  -- Native clocks are not saved; their process-local rearm need is never serialized.
  local nativeRearmPending = false
  local restoreBootstrap = restoreBootstrapRuntime.new({
    getState = getState, config = config, diagnosticLog = diagnosticLog,
    submitIntent = submitIntent, awaitingOrder = awaitingOrder,
    pendingBarrierReason = networkPendingBarrierReason, wallTime = wallTime,
  })

  local function issueSpeed(speed, callback, origin)
    local factory = commandFactory("setGameSpeed")
    if not factory then
      return false, "network clock requires SetGameSpeed factory and native tag-0 authority"
    end
    local made, commandOrError = pcall(factory, speed)
    if not made then return false, "could not create SetGameSpeed: " .. tostring(commandOrError) end
    local authorized, authorizeError = authorizeCommand(0)
    if not authorized then
      return false, "could not authorize SetGameSpeed: " .. tostring(authorizeError)
    end
    local sent, sendError = sendCommand(commandOrError, callback,
      origin or "mod.network.set-game-speed")
    if not sent then return false, "could not issue SetGameSpeed: " .. tostring(sendError) end
    return true
  end

  local function freezeNetworkCalendar()
    if state.networkMode ~= "network" then
      state.probes.networkCalendar = { frozen = false, requested = false, standalone = true }
      return true
    end
    local factory = commandFactory("setCalendarSpeed")
    if not factory then
      local message = "network mode requires an authorized setCalendarSpeed command to freeze native finance drift"
      state.probes.networkCalendar = { frozen = false, requested = false, error = message }
      return false, message
    end
    local authorized, authorizeError = authorizeCommand(1)
    if not authorized then
      local message = "could not authorize the network calendar freeze: " .. tostring(authorizeError)
      state.probes.networkCalendar = { frozen = false, requested = false, error = message }
      return false, message
    end
    local made, commandOrError = pcall(factory, 0)
    if not made then
      local message = "could not create the network calendar freeze command: " .. tostring(commandOrError)
      state.probes.networkCalendar = { frozen = false, requested = false, error = message }
      return false, message
    end
    local sent, sendError = sendCommand(commandOrError, nil, "mod.network.freeze-calendar")
    if not sent then
      local message = "could not issue the network calendar freeze command: " .. tostring(sendError)
      state.probes.networkCalendar = { frozen = false, requested = true, error = message }
      return false, message
    end
    state.probes.networkCalendar = {
      frozen = true, requested = true, speed = 0, commandTag = 1, tick = state.tick,
    }
    return true
  end

  local emitHealth

  local function freezeNetworkGame()
    if state.networkMode ~= "network" then return true end
    local current = state.world.networkClock
    -- Build 35924 compares duplicate game-script states during startup. A
    -- first-init native readback can differ in the second state and abort
    -- StartGameSim, so keep the authored request identical and defer readback
    -- until update(), after the engine's initial equality boundary.
    current.startupPause = {
      requested = true, confirmed = false, tick = state.tick,
    }
    current.requestedSpeed, current.effectiveSpeed = 0, 0
    -- An init callback in only one duplicate state causes the same race.
    local sent, sendError = issueSpeed(0, nil, "mod.network.startup-pause")
    if not sent then
      current.startupPause.requested, current.startupPause.error, current.lastError =
        false, tostring(sendError), tostring(sendError)
      return false, sendError
    end
    return true
  end

  local function emitReached(rendezvous, success, errorText)
    if rendezvous.reachedEmitted then return true end
    local observed = clockSnapshot()
    local ok, result = emit("clock_reached", {
      schemaVersion = 1,
      generation = util.integer(rendezvous.generation, 0),
      targetGameTime = tonumber(rendezvous.targetGameTime) or 0,
      actualGameTime = tonumber(observed.time) or tonumber(rendezvous.targetGameTime) or 0,
      engineTick = math.max(0, util.integer(state.tick, 0)),
      success = success == true,
      error = tostring(errorText or ""),
    }, state.tick)
    if ok then
      rendezvous.reachedEmitted = true
      state.world.networkClock.rendezvousReached =
        (state.world.networkClock.rendezvousReached or 0) + (success and 1 or 0)
      state.world.networkClock.rendezvousFaults =
        (state.world.networkClock.rendezvousFaults or 0) + (success and 0 or 1)
      emitHealth(true)
    else
      state.world.networkClock.lastError = tostring(result)
    end
    return ok, result
  end

  function networkClock.update()
    if state.networkMode ~= "network" then return false end
    local current = state.world.networkClock
    if nativeRearmPending then
      -- A normal update runs after Build 35924 compares duplicate ScriptSave() values.
      current.startupPause = { requested = false, confirmed = false }
      state.probes.networkCalendar = { frozen = false, requested = false }
      nativeRearmPending = false
    end
    -- app.loadGame restores native clocks after init(); re-arm them after each load.
    local startup = current.startupPause
    if type(startup) ~= "table" or startup.requested ~= true then
      local paused, pauseError = freezeNetworkGame()
      if not paused then return false, pauseError end
      startup = current.startupPause
    elseif startup.confirmed ~= true then
      local observed = clockSnapshot() or {}
      if tonumber(observed.gameSpeed) == 0 then
        startup.confirmed = true
        current.lastNativeSuccess = true
      end
    end
    local calendar = state.probes.networkCalendar
    if type(calendar) ~= "table" or calendar.requested ~= true
      or calendar.frozen ~= true then
      local frozen, calendarError = freezeNetworkCalendar()
      if not frozen then return false, calendarError end
    end
    local rendezvous = current.rendezvous
    if type(rendezvous) ~= "table" or rendezvous.reachedEmitted
      or rendezvous.status == "faulted" then return false end
    local observed = clockSnapshot()
    local gameTime = tonumber(observed.time)
    if not gameTime then
      rendezvous.status = "faulted"
      current.lastError = "game time is unavailable during clock rendezvous"
      return emitReached(rendezvous, false, current.lastError)
    end
    if gameTime + 1e-9 < tonumber(rendezvous.targetGameTime) then
      rendezvous.status = "approaching"
      return false
    end
    if rendezvous.status == "pausing" then return false end
    if tonumber(observed.gameSpeed) == 0 then
      current.effectiveSpeed = 0
      rendezvous.status = "reached"
      return emitReached(rendezvous, true)
    end
    rendezvous.status = "pausing"
    local sent, sendError = issueSpeed(0, function(_, success)
      if success == true then
        current.effectiveSpeed = 0
        rendezvous.status = "reached"
        emitReached(rendezvous, true)
      else
        rendezvous.status = "faulted"
        current.lastError = "native rendezvous pause was rejected"
        emitReached(rendezvous, false, current.lastError)
      end
    end, "mod.network.rendezvous-pause")
    if not sent then
      rendezvous.status = "faulted"
      current.lastError = tostring(sendError)
      emitReached(rendezvous, false, current.lastError)
      return false, current.lastError
    end
    return true
  end

  function networkClock.apply(action)
    if state.networkMode ~= "network" then return false, "ordered clock control is network-only" end
    local requested = util.integer(action and action.requestedSpeed, -1)
    local effective = util.integer(action and action.effectiveSpeed, -1)
    local generation = util.integer(action and action.generation, -1)
    local current = state.world.networkClock
    if requested < 0 or requested > 4 or effective < 0 or effective > requested then
      return false, "invalid requested/effective network speed"
    end
    if generation <= util.integer(current.generation, 0) then
      return false, "stale network clock generation"
    end
    local previous = util.deepCopy(current)
    current.requestedSpeed, current.effectiveSpeed = requested, effective
    current.generation, current.reason = generation, tostring(action.reason or "host-order")
    current.lastCommandTick, current.lastError = state.tick, nil
    current.lastRendezvous, current.rendezvous = util.deepCopy(current.rendezvous), nil
    local sent, sendError = issueSpeed(effective, function(_, success)
      current.lastNativeSuccess = success == true
      if success ~= true then current.lastError = "native SetGameSpeed command was rejected" end
    end)
    if not sent then state.world.networkClock = previous; return false, sendError end
    return true, {
      requestedSpeed = requested, effectiveSpeed = effective,
      generation = generation, reason = current.reason,
    }
  end

  function networkClock.arm(action)
    if state.networkMode ~= "network" then return false, "clock rendezvous is network-only" end
    local requested = util.integer(action and action.requestedSpeed, -1)
    local approach = util.integer(action and action.approachSpeed, -1)
    local release = util.integer(action and action.releaseSpeed, -1)
    local generation = util.integer(action and action.generation, -1)
    local target = tonumber(action and action.targetGameTime)
    local current, observed = state.world.networkClock, clockSnapshot()
    if requested < 0 or requested > 4 or approach < 0 or approach > 4
      or release < 0 or release > requested or generation <= util.integer(current.generation, 0)
      or not target or target < 0 or target ~= target or target == math.huge
      or not tonumber(observed.time) then
      return false, "invalid clock rendezvous"
    end
    if approach == 0 and tonumber(observed.time) and target > tonumber(observed.time) + 0.35 then
      return false, "paused rendezvous target is unreachable"
    end
    local previous = util.deepCopy(current)
    current.requestedSpeed, current.effectiveSpeed = requested, approach
    current.generation, current.reason = generation, tostring(action.reason or "host-rendezvous")
    current.lastCommandTick, current.lastError = state.tick, nil
    current.lastRendezvous = util.deepCopy(current.rendezvous)
    current.rendezvous = {
      generation = generation, targetGameTime = target,
      approachSpeed = approach, releaseSpeed = release,
      status = "armed", armedTick = state.tick, reachedEmitted = false,
    }
    if approach > 0 and tonumber(observed.gameSpeed) ~= approach then
      local sent, sendError = issueSpeed(approach, function(_, success)
        current.lastNativeSuccess = success == true
        if success ~= true then current.lastError = "native rendezvous approach speed was rejected" end
      end, "mod.network.rendezvous-approach")
      if not sent then state.world.networkClock = previous; return false, sendError end
    end
    networkClock.update()
    return true, util.deepCopy(current.rendezvous)
  end
  emitHealth = function(force)
    -- network_pump_runtime owns the running cadence. Keeping a second modulo
    -- gate here phase-locked the scheduler onto a permanently non-divisible
    -- tick after resume, so every running heartbeat disappeared.
    return heartbeat.emit(force)
  end
  networkClock.emitHealth = emitHealth

  function networkClock.emitPausedHealth()
    return heartbeat.emitPaused()
  end

  function networkClock.operationPrerequisite(action)
    local transaction = type(action) == "table" and action.transaction or nil
    local kind = type(transaction) == "table" and tostring(transaction.kind or "") or ""
    if state.networkMode ~= "network" or action.type ~= "operation.execute"
      or (not kind:match("^vehicle%.") and not kind:match("^line%.")) then return nil end
    local clock = state.world.networkClock
    if type(clock.rendezvous) == "table" then return nil end
    local observed = clockSnapshot()
    if util.integer(clock.effectiveSpeed, 0) > 0
      or (tonumber(observed.gameSpeed) or 0) > 0 then
      return { type = "clock.request", requestedSpeed = 0 },
        "line/vehicle operation is waiting for a shared-clock rendezvous"
    end
    return nil
  end

  function networkClock.maintainManualBootstrap(launcherReady)
    local cfg, bootstrap = config(), networkClock.manualBootstrap
    if launcherReady == true then bootstrap.launcherReady = true end
    local bootstrapReady = cfg.manualBootstrapReady == true or bootstrap.launcherReady == true
    if not cfg.manualNetwork or not bootstrapReady or state.networkMode ~= "network"
      or state.bridge.peerId ~= "player1" then return end
    if restoreBootstrap.maintain(bootstrap) then return end
    if state.tick < math.max(240, tonumber(bootstrap.nextAttemptTick) or 240) then return end
    if state.initialized then return end
    if awaitingOrder() or networkPendingBarrierReason() then return end
    local authority = state.probes.networkAuthority or {}
    if authority.ready ~= true then bootstrap.nextAttemptTick = state.tick + 30; return end
    bootstrap.attempts = bootstrap.attempts + 1
    local ok, result = submitIntent({ type = "match.initialise" })
    bootstrap.submitted = ok == true
    bootstrap.nextAttemptTick = state.tick + (ok and 600 or 60)
    diagnosticLog("manual-network-bootstrap", {
      success = ok == true, attempt = bootstrap.attempts,
      localSeq = type(result) == "table" and (result.local_seq or result.localSeq) or nil,
      error = not ok and tostring(type(result) == "table" and result.error or result) or nil,
      tick = state.tick,
    })
  end

  networkClock.freezeCalendar = freezeNetworkCalendar
  networkClock.freezeGame = freezeNetworkGame
  networkClock.reset = function()
    networkClock.manualBootstrap = {
      nextAttemptTick = 240, attempts = 0, submitted = false,
      launcherReady = false, restoreNextAttemptAt = nil,
    }
    heartbeat.reset()
    nativeRearmPending = true
  end
  return networkClock
end

return M
