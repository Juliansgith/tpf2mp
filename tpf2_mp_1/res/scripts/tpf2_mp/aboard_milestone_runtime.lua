local util = require "tpf2_mp/util"

local M = {}

local function validCid(value, prefix)
  return type(value) == "string" and #value <= 240
    and value:sub(1, #prefix + 1) == prefix .. ":"
    and not value:find("[%z\1-\31]")
end

function M.new(spec)
  local actionType = assert(spec.actionType, "actionType is required")
  local probeKey = assert(spec.probeKey, "probeKey is required")
  local label = assert(spec.label, "label is required")
  local ledgerOf = assert(spec.ledgerOf, "ledgerOf is required")
  local eligible = spec.eligible or function() return true end

  local function normalise(action)
    if type(action) ~= "table" then
      return nil, label .. " milestone must be a table"
    end
    for key in pairs(action) do
      if key ~= "type" and key ~= "stage" and key ~= "lineCid"
        and key ~= "vehicleCid" then
        return nil, label .. " milestone has an unknown field: " .. tostring(key)
      end
    end
    if action.type ~= actionType or action.stage ~= "aboard"
      or not validCid(action.lineCid, "line")
      or not validCid(action.vehicleCid, "vehicle") then
      return nil, label .. " aboard milestone has invalid canonical identity"
    end
    return { type = actionType, stage = "aboard",
      lineCid = action.lineCid, vehicleCid = action.vehicleCid }
  end

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
      if not vehicle or vehicle.lineCid ~= action.lineCid or not line
        or util.integer(vehicle.aboard, 0) < 1
        or not eligible(state, vehicle, line) then
        return false, label .. " aboard milestone is not present in the authored ledger"
      end
      state.probes[probeKey] = {
        aboardCheckpointed = true, lineCid = action.lineCid,
        vehicleCid = action.vehicleCid, sessionId = state.bridge.sessionId,
        tick = state.tick,
      }
      return true, { stage = "aboard", lineCid = action.lineCid,
        vehicleCid = action.vehicleCid, aboard = util.integer(vehicle.aboard, 0) }
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
    if not vehicle or not line or util.integer(vehicle.aboard, 0) < 1
      or not validCid(vehicle.lineCid, "line")
      or not eligible(state, vehicle, line) then return false end
    local ok, result = controller.scheduleFollowup({
      type = actionType, stage = "aboard",
      lineCid = vehicle.lineCid, vehicleCid = action.vehicleCid,
    })
    log(label .. "-milestone-schedule", {
      stage = "aboard", lineCid = vehicle.lineCid, vehicleCid = action.vehicleCid,
      aboard = util.integer(vehicle.aboard, 0), queued = ok == true,
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
