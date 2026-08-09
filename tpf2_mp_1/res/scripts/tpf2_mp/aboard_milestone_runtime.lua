local util = require "tpf2_mp/util"
local witness = require "tpf2_mp/aboard_milestone_witness"

local M = {}

function M.new(spec)
  local actionType = assert(spec.actionType, "actionType is required")
  local probeKey = assert(spec.probeKey, "probeKey is required")
  local label = assert(spec.label, "label is required")
  local ledgerOf = assert(spec.ledgerOf, "ledgerOf is required")
  local eligible = spec.eligible or function() return true end

  local function normalise(action) return witness.normalise(action, actionType, label) end

  local runtime = {}

  function runtime.normaliseIntent(state, action)
    if state.bridge.peerId ~= "player1" then
      return nil, "only the host peer can author a " .. label .. " milestone"
    end
    return normalise(action)
  end

  function runtime.installHandler(handlers, deps)
    handlers[actionType] = function(action)
      local running, runningError = deps.requireRunningMatch()
      if not running then return false, runningError end
      local state = deps.getState()
      local normalised, normaliseError = normalise(action)
      if not normalised then return false, normaliseError end
      local ledger = ledgerOf(state) or {}
      local vehicle = ledger.vehicles and ledger.vehicles[action.vehicleCid] or nil
      local line = ledger.lines and ledger.lines[action.lineCid] or nil
      local verified, currentAboard = witness.verify(
        normalised, vehicle, line,
        function(candidate, candidateLine)
          return eligible(state, candidate, candidateLine)
        end)
      if not verified then
        state.probes[probeKey] = {
          aboardCheckpointed = false, stale = true,
          lineCid = action.lineCid, vehicleCid = action.vehicleCid,
          sessionId = state.bridge.sessionId, tick = state.tick,
        }
        return true, { stage = "aboard", stale = true,
          lineCid = action.lineCid, vehicleCid = action.vehicleCid }
      end
      state.probes[probeKey] = {
        aboardCheckpointed = true, lineCid = action.lineCid,
        vehicleCid = action.vehicleCid, sessionId = state.bridge.sessionId,
        observedRound = normalised.observedRound,
        boardedTotal = normalised.boardedTotal,
        aboard = normalised.aboard or currentAboard, tick = state.tick,
      }
      return true, { stage = "aboard", lineCid = action.lineCid,
        vehicleCid = action.vehicleCid,
        aboard = normalised.aboard or currentAboard,
        observedRound = normalised.observedRound,
        boardedTotal = normalised.boardedTotal }
    end
  end

  function runtime.observeRelease(state, action, controller, log)
    local probe = state.probes[probeKey]
    if state.networkMode ~= "network" or state.bridge.peerId ~= "player1"
      or (probe and probe.aboardCheckpointed == true
        and probe.sessionId == state.bridge.sessionId) then return false end
    local companion = state.bridge.companion or {}
    if companion.connected ~= true then return false end
    local ledger = ledgerOf(state) or {}
    local vehicle = ledger.vehicles and ledger.vehicles[action.vehicleCid] or nil
    local line = vehicle and ledger.lines and ledger.lines[vehicle.lineCid] or nil
    local observed = witness.capture(vehicle)
    if not observed or not line or not eligible(state, vehicle, line) then return false end
    local ok, result = controller.scheduleFollowup({
      type = actionType, stage = "aboard",
      lineCid = vehicle.lineCid, vehicleCid = action.vehicleCid,
      observedRound = observed.observedRound,
      boardedTotal = observed.boardedTotal, aboard = observed.aboard,
    })
    log(label .. "-milestone-schedule", {
      stage = "aboard", lineCid = vehicle.lineCid, vehicleCid = action.vehicleCid,
      aboard = observed.aboard, queued = ok == true,
      error = ok and nil or tostring(result), tick = state.tick,
    })
    return ok == true, result
  end

  function runtime.afterCommit(state, action, success, authoritySeq,
      exportCheckpoint, log)
    if not success or action.type ~= actionType or not authoritySeq then return false end
    local reason = label .. "-milestone:" .. tostring(action.stage)
    local ok, err = exportCheckpoint(authoritySeq, reason)
    if not ok then
      log("checkpoint-barrier-error", {
        tick = state.tick, boundarySeq = authoritySeq, error = tostring(err),
      })
    end
    return true
  end

  function runtime.reset() end

  return runtime
end

return M
