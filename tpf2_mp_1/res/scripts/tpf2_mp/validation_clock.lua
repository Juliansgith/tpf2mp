local util = require "tpf2_mp/util"
local bridge = require "tpf2_mp/bridge"
local world = require "tpf2_mp/world"

local M = {}

function M.new(getState)
  assert(type(getState) == "function", "validation clock state accessor is required")
  local result = {}

  function result.settled(speed)
    local state, expected = getState(), util.integer(speed, 0)
    local clock = state.world.networkClock or {}
    if util.integer(clock.requestedSpeed, -1) ~= expected
      or util.integer(clock.effectiveSpeed, -1) ~= expected
      or type(clock.rendezvous) == "table" then return false end
    local observed = world.clockSnapshot()
    if util.integer(observed and observed.gameSpeed, -1) ~= expected then return false end
    if state.bridge.peerId ~= "player1" then return true end
    local companion = bridge.pollCompanionStatus(state.bridge) or {}
    local authority = companion.clock or {}
    return util.integer(authority.requestedSpeed, -1) == expected
      and util.integer(authority.effectiveSpeed, -1) == expected
      and authority.pendingSeq == nil and authority.rendezvous == nil
  end

  function result.peersReady()
    local state = getState()
    if state.bridge.peerId ~= "player1" then return true end
    local companion = bridge.pollCompanionStatus(state.bridge) or {}
    local peers = companion.clock and companion.clock.healthPeers or {}
    local present = {}
    for _, peer in ipairs(type(peers) == "table" and peers or {}) do
      present[tostring(peer)] = true
    end
    return present.player1 == true and present.player2 == true
  end

  function result.event(speed)
    local state = getState()
    local items = state.eventLog and state.eventLog.items or {}
    local prefix = tostring(state.bridge.sessionId or "") .. ":"
    for index = #items, 1, -1 do
      local event, action = items[index], items[index] and items[index].action
      if event.success == true and tostring(event.eventId or ""):sub(1, #prefix) == prefix
        and type(action) == "table" and action.type == "clock.set"
        and util.integer(action.requestedSpeed, -1) == speed
        and util.integer(action.effectiveSpeed, -1) == speed then return event end
    end
    return nil
  end

  function result.rendezvousConverged(companion)
    local clock = type(companion) == "table" and companion.clock or nil
    local last = type(clock) == "table" and clock.lastRendezvous or nil
    return type(last) == "table" and last.status == "reached"
      and tonumber(last.observedSkew) ~= nil and last.observedSkew <= 0.35
  end

  return result
end

return M
