local util = require "tpf2_mp/util"

local M = {}

local function checkpointReason(record)
  return "saved-match-continuation:" .. tostring(record.saveFingerprint or ""):sub(1, 12)
end

function M.new(env)
  local getState = assert(env.getState, "saved-match continuation state provider is required")
  local config = assert(env.config, "saved-match continuation config provider is required")
  local coreDigest = assert(env.coreDigest, "saved-match continuation digest provider is required")

  local function record()
    local state = getState()
    return state.recovery and state.recovery.savedMatchContinuation or nil
  end

  local function fenced()
    local current = record()
    return type(current) == "table" and current.status ~= "complete"
  end

  local function expected(current)
    return {
      fromSession = tostring(current.fromSession or ""),
      sourceStateVersion = util.integer(current.sourceStateVersion, 0),
      sourceCoreDigest = coreDigest(),
      saveFingerprint = tostring(current.saveFingerprint or ""),
    }
  end

  local function normalise(action)
    local state = getState()
    if state.bridge.peerId ~= "player1" then
      return nil, "only the host peer can continue a saved match"
    end
    for key in pairs(action or {}) do
      if key ~= "type" then
        return nil, "recovery.continue has a client-supplied field: " .. tostring(key)
      end
    end
    local current = record()
    if type(current) ~= "table" or current.status ~= "validated" then
      return nil, "the loaded save has no validated saved-match continuation"
    end
    local result = expected(current)
    result.type = "recovery.continue"
    return result
  end

  local function apply(action, _, commitSeq)
    local state = getState()
    local current = record()
    if state.networkMode ~= "network" or not commitSeq or type(current) ~= "table" then
      return false, "saved-match continuation is unavailable in this world"
    end
    if current.status == "complete" then return true, util.deepCopy(current) end
    if current.status ~= "validated" then
      return false, tostring(current.error or "saved-match source validation did not complete")
    end
    local configuredFingerprint = tostring(config().matchFingerprint or "")
    local fields = expected(current)
    for key, value in pairs(fields) do
      if action[key] ~= value then
        current.status = "failed"
        current.error = "saved-match continuation attestation mismatch: " .. key
        return false, current.error
      end
    end
    if configuredFingerprint == "" or configuredFingerprint ~= fields.saveFingerprint then
      current.status = "failed"
      current.error = "loaded save fingerprint does not match the launcher manifest"
      return false, current.error
    end
    current.status = "awaiting-checkpoint"
    current.commitSeq = util.integer(commitSeq, 0)
    current.migratedCoreDigest = fields.sourceCoreDigest
    current.checkpointReason = checkpointReason(current)
    current.committedTick = state.tick
    current.error = nil
    return true, util.deepCopy(current)
  end

  local function afterCheckpoint(action)
    local state = getState()
    local current = record()
    if type(current) ~= "table" or current.status ~= "awaiting-checkpoint"
      or type(action) ~= "table" or action.type ~= "network.checkpoint_outcome"
      or util.integer(action.boundarySeq, 0) ~= util.integer(current.commitSeq, -1)
      or tostring(action.reason or "") ~= checkpointReason(current) then
      return false
    end
    if action.success == true then
      current.status = "complete"
      current.completedTick = state.tick
      current.convergenceKey = tostring(action.convergenceKey or "")
      current.coreDigest = tostring(action.coreDigest or current.migratedCoreDigest or "")
      current.error = nil
    else
      current.status = "failed"
      current.error = tostring(action.errorCode or "saved-match continuation checkpoint failed")
    end
    return true
  end

  local function maintain(bootstrap, deps)
    local state, cfg = getState(), config()
    if cfg.continueSavedMatch ~= true then return false end
    local current = record()
    if type(current) ~= "table" or current.status == "complete" then return false end
    if current.status ~= "validated" then return true end
    if state.bridge.peerId ~= "player1" then return true end
    local now = deps.wallTime and tonumber(deps.wallTime()) or nil
    if bootstrap.savedMatchSubmitted == true then return true end
    if now and now < tonumber(bootstrap.savedMatchNextAttemptAt or 0) then return true end
    if deps.awaitingOrder() or deps.pendingBarrierReason() then return true end
    local authority = state.probes.networkAuthority or {}
    if authority.ready ~= true then
      bootstrap.savedMatchNextAttemptAt = now and now + 1 or nil
      return true
    end
    bootstrap.savedMatchAttempts = math.max(0,
      util.integer(bootstrap.savedMatchAttempts, 0)) + 1
    local ok, result = deps.submitIntent({ type = "recovery.continue" })
    bootstrap.savedMatchSubmitted = ok == true
    bootstrap.savedMatchNextAttemptAt = now and now + (ok and 30 or 1) or nil
    deps.diagnosticLog("manual-network-saved-match-continuation", {
      success = ok == true,
      attempt = bootstrap.savedMatchAttempts,
      localSeq = type(result) == "table" and (result.local_seq or result.localSeq) or nil,
      error = not ok and tostring(type(result) == "table" and result.error or result) or nil,
      tick = state.tick,
    })
    return true
  end

  return {
    normalise = normalise,
    apply = apply,
    afterCheckpoint = afterCheckpoint,
    maintain = maintain,
    fenced = fenced,
    checkpointReason = checkpointReason,
  }
end

return M
