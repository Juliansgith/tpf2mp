local util = require "tpf2_mp/util"
local hash = require "tpf2_mp/hash"

local M = {}
local SUBMISSION_TIMEOUT_TICKS = 1800

local function contains(values, expected)
  for _, value in ipairs(type(values) == "table" and values or {}) do
    if util.integer(value, 0) == expected then return true end
  end
  return false
end

local function safeIdentity(value, maximum)
  value = tostring(value or "")
  if #value < 1 or #value > maximum or not value:match("^[%w][%w_.%-]*$") then
    return nil
  end
  return value
end

function M.saveName(sessionId, peerId, boundarySeq)
  local session = safeIdentity(sessionId, 64)
  local peer = safeIdentity(peerId, 16)
  local boundary = util.integer(boundarySeq, 0)
  if not session or not peer or boundary < 1 then return nil end
  -- Build 35924's stock save dialog truncates names to fifty characters.
  -- Session ids are intentionally much longer, so preserve their identity in
  -- a deterministic digest and keep the peer token bounded.  The watcher uses
  -- the same Adler-32 construction and never accepts this name without also
  -- checking the READY boundary and receipt-bound file hashes.
  local peerToken = peer == "player1" and "p1"
    or peer == "player2" and "p2" or hash.text(peer)
  return "tpf2mp_r_" .. hash.text(session) .. "_" .. peerToken
    .. "_b" .. tostring(boundary)
end

function M.new(env)
  local getState = assert(env.getState, "native-save state provider is required")
  local coreDigest = assert(env.coreDigest, "native-save core digest is required")
  local commandFactory = env.commandFactory or util.commandFactory
  local sendCommand = env.sendCommand or util.sendCommand

  local function record(state)
    state.recovery = state.recovery or { schemaVersion = 1 }
    state.recovery.nativeSave = type(state.recovery.nativeSave) == "table"
      and state.recovery.nativeSave or { schemaVersion = 1, status = "idle" }
    return state.recovery.nativeSave
  end

  local function fail(state, boundary, saveName, message)
    local current = record(state)
    current.schemaVersion = 1
    current.status = "failed"
    current.boundarySeq = boundary
    current.saveName = saveName
    current.completedTick = state.tick
    current.retryTick = util.integer(state.tick, 0) + 60
    current.error = tostring(message or "native save command failed")
    return false, current.error
  end

  local function maintain()
    local state = getState()
    local current = record(state)
    local companion = state.bridge and state.bridge.companion or {}
    local boundary = util.integer(companion.anchorBoundarySeq, 0)
    local locallyFiled = contains(companion.localAnchorsFiled, boundary)
      or contains(companion.anchorsFiled, boundary)
    if boundary > 0 and locallyFiled then
      current.status = "receipt-filed"
      current.boundarySeq = boundary
      current.error = nil
      return true, util.deepCopy(current)
    end
    if state.networkMode ~= "network" or companion.anchorReady ~= true or boundary < 1 then
      return false, "no READY restore boundary"
    end
    local preparation = state.recovery and state.recovery.anchorPreparation or {}
    if preparation.status ~= "ready"
      or util.integer(preparation.boundarySeq, 0) ~= boundary
      or companion.anchorPreparationStatus ~= "ready"
      or util.integer(companion.anchorPreparationCheckpointSeq, 0) ~= boundary then
      return false, "local restore preparation has not reached the READY boundary"
    end
    local expectedCore = tostring(companion.anchorCoreDigest or "")
    local digested, currentCore = pcall(coreDigest)
    if not digested or expectedCore == "" or tostring(currentCore) ~= expectedCore then
      return false, "READY boundary does not match the current core digest"
    end
    local sameBoundary = current.boundarySeq == boundary
    if sameBoundary and current.status == "save-command-submitted"
      and util.integer(state.tick, 0) - util.integer(current.requestedTick, 0)
        >= SUBMISSION_TIMEOUT_TICKS then
      return fail(state, boundary, current.saveName,
        "native save command callback timed out")
    end
    if sameBoundary and current.status ~= "failed"
      and current.status ~= "idle" then
      return false, "native save was already requested for this boundary"
    end
    local attempts = sameBoundary and util.integer(current.attempts, 0) or 0
    if sameBoundary and current.status == "failed" and attempts >= 3 then
      return false, "native save retry limit reached for this boundary"
    end
    if sameBoundary and current.status == "failed" and util.integer(state.tick, 0)
      < util.integer(current.retryTick, 0) then
      return false, "native save retry is cooling down"
    end

    local name = M.saveName(state.bridge.sessionId, state.bridge.peerId, boundary)
    current.boundarySeq = boundary
    current.attempts = attempts + 1
    if not name then return fail(state, boundary, nil, "native save identity is invalid") end
    local factory = commandFactory("saveGame")
    if not factory then return fail(state, boundary, name, "saveGame command is unavailable") end
    local made, commandOrError = pcall(factory, name)
    if not made or commandOrError == nil then
      return fail(state, boundary, name, commandOrError or "saveGame factory returned no command")
    end

    current.schemaVersion = 1
    current.status = "submitting"
    current.boundarySeq = boundary
    current.saveName = name
    current.requestedTick = state.tick
    current.completedTick = nil
    current.retryTick = nil
    current.error = nil
    local attempt = current.attempts
    local callbackCalled, callbackSuccess = false, false
    local sent, sendError = sendCommand(commandOrError, function(_, success)
      callbackCalled = true
      callbackSuccess = success == true
      local latestState = getState()
      local latest = record(latestState)
      if latest.boundarySeq ~= boundary or latest.saveName ~= name
        or util.integer(latest.attempts, 0) ~= attempt then return end
      if latest.status == "receipt-filed" then return end
      if callbackSuccess then
        latest.status = "save-command-complete"
        latest.completedTick = latestState.tick
        latest.retryTick = nil
        latest.error = nil
      else
        fail(latestState, boundary, name, "native save command was rejected")
      end
    end, "mod.recovery.save-game")
    if not sent then return fail(state, boundary, name, sendError) end
    if not callbackCalled then current.status = "save-command-submitted"
    elseif callbackSuccess then current.status = "save-command-complete" end
    return true, util.deepCopy(current)
  end

  return { maintain = maintain }
end

return M
