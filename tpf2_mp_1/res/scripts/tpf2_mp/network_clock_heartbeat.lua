local clockHealth = require "tpf2_mp/network_clock_health"

local M = {}

function M.new(deps)
  assert(type(deps) == "table" and type(deps.getState) == "function",
    "network clock heartbeat state provider is required")
  local getState = deps.getState
  local clockSnapshot = assert(deps.clockSnapshot, "clock snapshot provider is required")
  local localWorkState = assert(deps.localWorkState, "local work provider is required")
  local emit = assert(deps.emit, "clock heartbeat emitter is required")
  local wallTime = assert(deps.wallTime, "clock heartbeat wall timer is required")
  local running, paused = { calls = 0, lastWall = nil }, { calls = 0, lastWall = nil }
  local runtime = {}

  local function due(throttle, seconds, fallbackStride)
    throttle.calls = throttle.calls + 1
    local wall = wallTime()
    if wall then
      if throttle.lastWall and wall - throttle.lastWall < seconds then return false end
      throttle.lastWall = wall
      return true
    end
    return throttle.calls % fallbackStride == 1
  end

  function runtime.emit(force)
    local state = getState()
    if state.networkMode ~= "network" or not state.initialized then return false end
    if force ~= true and not due(running, 1, 4) then return false end
    local observed, clock = clockSnapshot(), state.world.networkClock
    local payload = clockHealth.payload(state, observed, clock, localWorkState() or {})
    local ok, envelope = emit("clock_health", payload, state.tick)
    if ok then
      clock.healthEmitted = (clock.healthEmitted or 0) + 1
      clock.lastHealthLocalSeq = envelope.local_seq
    else clock.lastError = tostring(envelope) end
    return ok
  end

  function runtime.emitPaused()
    local state, observed = getState(), clockSnapshot()
    if state.networkMode ~= "network" or not state.initialized
      or tonumber(observed.gameSpeed) ~= 0 or not due(paused, 2, 4) then return false end
    return runtime.emit(true)
  end

  function runtime.reset()
    running, paused = { calls = 0, lastWall = nil }, { calls = 0, lastWall = nil }
  end

  return runtime
end

return M
