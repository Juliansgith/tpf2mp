local util = require "tpf2_mp/util"
local world = require "tpf2_mp/world"
local economyClockPolicy = require "tpf2_mp/economy_clock_policy"

local M = {}

function M.new(deps)
  local getState = assert(deps.getState, "getState dependency is required")
  local submitIntent = assert(deps.submitIntent, "submitIntent dependency is required")
  local localWorkState = assert(deps.localWorkState, "localWorkState dependency is required")
  local diagnosticLog = assert(deps.diagnosticLog, "diagnosticLog dependency is required")
  local gameTimeSeconds = deps.gameTimeSeconds
  if type(gameTimeSeconds) ~= "function" then
    local clockSnapshot = deps.clockSnapshot or world.clockSnapshot
    gameTimeSeconds = function() return tonumber((clockSnapshot() or {}).time) end
  end
  local pending

  local function reset() pending = nil end

  local function update()
    local state = getState()
    local economy = state.economy or {}
    local scheduler = economy.scheduler or {}
    if state.initialized ~= true or not state.match or state.match.status ~= "running"
      or scheduler.automatic ~= true then return false, "inactive" end
    if state.networkMode == "network" and state.bridge.peerId ~= "player1" then
      return false, "host-only"
    end
    if state.networkMode == "network"
      and (not state.bridge.companion or state.bridge.companion.connected ~= true) then
      if pending then
        diagnosticLog("economy-clock-peer-disconnected", {
          boundaryGameTimeSeconds = pending.boundary,
          submittedTick = pending.tick,
          tick = state.tick,
        })
      end
      pending = nil
      return false, "peer-disconnected"
    end
    local boundary = tonumber(scheduler.nextBoundaryGameTimeSeconds)
    local gameTime = tonumber(gameTimeSeconds())
    if not boundary or not gameTime or gameTime + 1e-9 < boundary then
      return false, "not-due"
    end
    if pending and pending.boundary ~= boundary then pending = nil end
    local work = localWorkState() or {}
    if pending and state.tick - pending.tick < 300 then return false, "submitted" end
    if pending then
      diagnosticLog("economy-clock-retry", {
        boundaryGameTimeSeconds = boundary, submittedTick = pending.tick,
        tick = state.tick,
      })
      pending = nil
    end
    if work.pending then return false, tostring(work.barrierReason or "authority-busy") end
    local accepted, result = submitIntent({
      type = "economy.settle",
      scheduled = true,
      boundaryGameTimeSeconds = util.integer(boundary, 0),
    })
    if accepted ~= true then
      diagnosticLog("economy-clock-submit-failed", {
        boundaryGameTimeSeconds = boundary,
        error = tostring(type(result) == "table" and result.error or result),
        tick = state.tick,
      })
      return false, result
    end
    pending = { boundary = boundary, tick = state.tick }
    diagnosticLog("economy-clock-submit", {
      boundaryGameTimeSeconds = boundary,
      observedGameTimeSeconds = math.floor(gameTime),
      epoch = util.integer(economy.epoch, 0) + 1,
      tick = state.tick,
    })
    return true, result
  end

  return { update = update, reset = reset, needsUpdate = function()
    return economyClockPolicy.needsUpdate(getState(), pending)
  end }
end
return M
