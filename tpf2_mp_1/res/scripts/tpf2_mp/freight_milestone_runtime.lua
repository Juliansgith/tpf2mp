local util = require "tpf2_mp/util"

local M = {}

local function validCid(value, prefix)
  return type(value) == "string" and #value <= 240
    and value:sub(1, #prefix + 1) == prefix .. ":"
    and not value:find("[%z\1-\31]")
end

local function normalise(action)
  if type(action) ~= "table" then return nil, "freight milestone must be a table" end
  for key in pairs(action) do
    if key ~= "type" and key ~= "stage" and key ~= "lineCid" and key ~= "vehicleCid" then
      return nil, "freight milestone has an unknown field: " .. tostring(key)
    end
  end
  if action.stage ~= "aboard" or not validCid(action.lineCid, "line")
    or not validCid(action.vehicleCid, "vehicle") then
    return nil, "freight aboard milestone has invalid canonical identity"
  end
  return { type = "freight.milestone", stage = "aboard",
    lineCid = action.lineCid, vehicleCid = action.vehicleCid }
end

function M.normaliseIntent(state, action)
  if state.bridge.peerId ~= "player1" then
    return nil, "only the host peer can author a freight milestone"
  end
  return normalise(action)
end

function M.installHandler(handlers, deps)
  handlers["freight.milestone"] = function(action)
    local running, runningError = deps.requireRunningMatch()
    if not running then return false, runningError end
    local state = deps.getState()
    -- Both peers apply this host-authored action. Host-only authority belongs
    -- at intent submission, not at ordered-commit application.
    local normalised, normaliseError = normalise(action)
    if not normalised then return false, normaliseError end
    local cargo = state.world.cargoPresentation or {}
    local vehicle = cargo.vehicles and cargo.vehicles[action.vehicleCid] or nil
    local line = cargo.lines and cargo.lines[action.lineCid] or nil
    if not vehicle or vehicle.lineCid ~= action.lineCid
      or not line or line.retired == true or util.integer(vehicle.aboard, 0) < 1 then
      return false, "freight aboard milestone is not present in the authored cargo ledger"
    end
    state.probes.freightMilestone = {
      aboardCheckpointed = true, lineCid = action.lineCid,
      vehicleCid = action.vehicleCid, sessionId = state.bridge.sessionId,
      tick = state.tick,
    }
    return true, { stage = "aboard", lineCid = action.lineCid,
      vehicleCid = action.vehicleCid, aboard = util.integer(vehicle.aboard, 0) }
  end
end

function M.observeRelease(state, action, controller, log)
  if state.networkMode ~= "network" or state.bridge.peerId ~= "player1"
    or (state.probes.freightMilestone
      and state.probes.freightMilestone.aboardCheckpointed == true
      and state.probes.freightMilestone.sessionId == state.bridge.sessionId) then return false end
  local companion = state.bridge.companion or {}
  if companion.connected ~= true then return false end
  local cargo = state.world.cargoPresentation or {}
  local vehicle = cargo.vehicles and cargo.vehicles[action.vehicleCid] or nil
  if not vehicle or util.integer(vehicle.aboard, 0) < 1
    or not validCid(vehicle.lineCid, "line") then return false end
  local ok, result = controller.scheduleFollowup({
    type = "freight.milestone", stage = "aboard",
    lineCid = vehicle.lineCid, vehicleCid = action.vehicleCid,
  })
  log("freight-milestone-schedule", {
    stage = "aboard", lineCid = vehicle.lineCid, vehicleCid = action.vehicleCid,
    aboard = util.integer(vehicle.aboard, 0), queued = ok == true,
    error = ok and nil or tostring(result), tick = state.tick,
  })
  return ok == true, result
end

function M.afterCommit(state, action, success, authoritySeq, exportCheckpoint, log)
  if not success or action.type ~= "freight.milestone" or not authoritySeq then
    return false
  end
  local reason = "freight-milestone:" .. tostring(action.stage)
  local ok, err = exportCheckpoint(authoritySeq, reason)
  if not ok then
    log("checkpoint-barrier-error", {
      tick = state.tick, boundarySeq = authoritySeq, error = tostring(err),
    })
  end
  return true
end

function M.reset()
  -- Queue ownership lives in network_intent_runtime and is reset there. This
  -- no-op keeps the entry point's transient-runtime interface explicit.
end

return M
