local util = require "tpf2_mp/util"
local bridge = require "tpf2_mp/bridge"
local world = require "tpf2_mp/world"

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

  local state = setmetatable({}, {
    __index = function(_, key) return getState()[key] end,
    __newindex = function(_, key, value) getState()[key] = value end,
  })
  local networkClock = {
    manualBootstrap = { nextAttemptTick = 240, attempts = 0, submitted = false },
  }

  local function freezeNetworkCalendar()
    if state.networkMode ~= "network" then
      state.probes.networkCalendar = { frozen = false, requested = false, standalone = true }
      return true
    end
    local factory = util.commandFactory("setCalendarSpeed")
    local authorize = rawget(_G, "tpf2mp_native_authorize_command")
    if not factory or type(authorize) ~= "function"
      or not (api and api.cmd and type(api.cmd.sendCommand) == "function") then
      local message = "network mode requires an authorized setCalendarSpeed command to freeze native finance drift"
      state.probes.networkCalendar = { frozen = false, requested = false, error = message }
      return false, message
    end
    local authorized, authorizeError = pcall(authorize, "1")
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
    local sent, sendError = util.sendCommand(
      commandOrError, nil, "mod.network.freeze-calendar")
    if not sent then
      local message = "could not issue the network calendar freeze command: " .. tostring(sendError)
      state.probes.networkCalendar = { frozen = false, requested = true, error = message }
      return false, message
    end
    state.probes.networkCalendar = {
      frozen = true,
      requested = true,
      speed = 0,
      commandTag = 1,
      tick = state.tick,
    }
    return true
  end
  
  
  function networkClock.apply(action)
    if state.networkMode ~= "network" then return false, "ordered clock control is network-only" end
    local requested = util.integer(action and action.requestedSpeed, -1)
    local effective = util.integer(action and action.effectiveSpeed, -1)
    local generation = util.integer(action and action.generation, -1)
    if requested < 0 or requested > 4 or effective < 0 or effective > requested then
      return false, "invalid requested/effective network speed"
    end
    local current = state.world.networkClock
    if generation <= util.integer(current.generation, 0) then
      return false, "stale network clock generation"
    end
    local factory = util.commandFactory("setGameSpeed")
    local authorize = rawget(_G, "tpf2mp_native_authorize_command")
    if not factory or type(authorize) ~= "function"
      or not (api and api.cmd and type(api.cmd.sendCommand) == "function") then
      return false, "network clock requires SetGameSpeed factory and native tag-0 authority"
    end
    local made, commandOrError = pcall(factory, effective)
    if not made then return false, "could not create SetGameSpeed: " .. tostring(commandOrError) end
    local called, authorized, authorizeError = pcall(authorize, "0")
    if not called or authorized == false then
      return false, "could not authorize SetGameSpeed: " .. tostring(authorizeError or authorized)
    end
  
    local previous = util.deepCopy(current)
    current.requestedSpeed = requested
    current.effectiveSpeed = effective
    current.generation = generation
    current.reason = tostring(action.reason or "host-order")
    current.lastCommandTick = state.tick
    current.lastError = nil
    local sent, sendError = util.sendCommand(commandOrError, function(_, success)
      current.lastNativeSuccess = success == true
      if success ~= true then current.lastError = "native SetGameSpeed command was rejected" end
    end, "mod.network.set-game-speed")
    if not sent then
      state.world.networkClock = previous
      return false, "could not issue SetGameSpeed: " .. tostring(sendError)
    end
    return true, {
      requestedSpeed = requested,
      effectiveSpeed = effective,
      generation = generation,
      reason = current.reason,
    }
  end
  
  function networkClock.emitHealth()
    if state.networkMode ~= "network" or not state.initialized or state.tick % 15 ~= 0 then
      return false
    end
    local observed = world.clockSnapshot()
    local clock = state.world.networkClock
    local proposalPending = false
    for _, record in pairs(state.world.proposalConsensus.byId or {}) do
      if record.status == "pending" then proposalPending = true; break end
    end
    local ok, envelope = bridge.emit(state.bridge, "clock_health", {
      schemaVersion = 1,
      requestedSpeed = util.integer(clock.requestedSpeed, 0),
      effectiveSpeed = util.integer(clock.effectiveSpeed, 0),
      generation = util.integer(clock.generation, 0),
      observedSpeed = tonumber(observed.gameSpeed),
      gameTime = tonumber(observed.time),
      engineTick = state.tick,
      lastCommitSeq = math.max(0, util.integer((state.bridge.nextInSeq or 1) - 1, 0)),
      proposalPending = proposalPending,
    }, state.tick)
    if ok then
      clock.healthEmitted = (clock.healthEmitted or 0) + 1
      clock.lastHealthLocalSeq = envelope.local_seq
    else
      clock.lastError = tostring(envelope)
    end
    return ok
  end
  
  
  function networkClock.maintainManualBootstrap(launcherReady)
    local cfg = config()
    local bootstrap = networkClock.manualBootstrap
    -- The launcher can deliver its readiness event as soon as the paused
    -- world has been woken, before this script reaches the conservative tick
    -- 240 authority boundary.  Latch that one-shot handoff: losing it here
    -- would leave later update ticks dependent on Transport Fever 2's stale
    -- sandbox file cache and deadlock an otherwise healthy manual session.
    if launcherReady == true then bootstrap.launcherReady = true end
    local bootstrapReady = cfg.manualBootstrapReady == true
      or bootstrap.launcherReady == true
    if not cfg.manualNetwork or not bootstrapReady
      or state.networkMode ~= "network" or state.initialized then return end
    if state.bridge.peerId ~= "player1" then return end
    if state.tick < math.max(240, tonumber(bootstrap.nextAttemptTick) or 240) then return end
    if awaitingOrder() or networkPendingBarrierReason() then return end
    local authority = state.probes.networkAuthority or {}
    if authority.ready ~= true then
      bootstrap.nextAttemptTick = state.tick + 30
      return
    end
    bootstrap.attempts = bootstrap.attempts + 1
    local ok, result = submitIntent({ type = "match.initialise" })
    bootstrap.submitted = ok == true
    bootstrap.nextAttemptTick = state.tick + (ok and 600 or 60)
    diagnosticLog("manual-network-bootstrap", {
      success = ok == true,
      attempt = bootstrap.attempts,
      localSeq = type(result) == "table" and (result.local_seq or result.localSeq) or nil,
      error = not ok and tostring(type(result) == "table" and result.error or result) or nil,
      tick = state.tick,
    })
  end

  networkClock.freezeCalendar = freezeNetworkCalendar
  networkClock.reset = function()
    networkClock.manualBootstrap = {
      nextAttemptTick = 240,
      attempts = 0,
      submitted = false,
      launcherReady = false,
    }
  end
  return networkClock
end

return M
