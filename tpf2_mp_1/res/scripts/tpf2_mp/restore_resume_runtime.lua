local util = require "tpf2_mp/util"

local M = {}

function M.new(env)
  local getState = assert(env.getState, "restore state provider is required")
  local coreDigest = assert(env.coreDigest, "restore core digest provider is required")

  local function view(restore)
    return {
      fromSession = tostring(restore.fromSession or ""),
      boundarySeq = util.integer(restore.boundarySeq, 0),
      coreDigest = tostring(restore.coreDigest or ""),
      convergenceKey = tostring(restore.convergenceKey or ""),
      planChecksum = tostring(restore.planChecksum or ""),
      vehiclePhaseDigest = tostring(restore.vehiclePhaseDigest or ""),
    }
  end

  local function normalise(action)
    local state = getState()
    if state.bridge.peerId ~= "player1" then
      return nil, "only the host peer can resume a restore plan"
    end
    for key in pairs(action or {}) do
      if key ~= "type" then
        return nil, "recovery.resume has a client-supplied field: " .. tostring(key)
      end
    end
    local restore = state.recovery and state.recovery.restoreResume or nil
    if type(restore) ~= "table" or restore.status ~= "validated" then
      return nil, "the loaded save has no validated restore plan"
    end
    local result = view(restore)
    result.type = "recovery.resume"
    return result
  end

  local function apply(action, _, commitSeq)
    local state = getState()
    local restore = state.recovery and state.recovery.restoreResume or nil
    if state.networkMode ~= "network" or not commitSeq or type(restore) ~= "table" then
      return false, "restore resume is unavailable in this world"
    end
    local expected = view(restore)
    for key, value in pairs(expected) do
      if action[key] ~= value then
        return false, "restore resume attestation mismatch: " .. key
      end
    end
    if restore.status == "committed" then return true, util.deepCopy(restore) end
    if restore.status ~= "validated" then
      return false, "restore source validation did not complete"
    end
    -- The plan binds the source checkpoint before state-schema migration. A
    -- compatible newer build may deliberately add authored defaults and thus
    -- produce a different current digest on both peers. Revalidate the saved
    -- source anchor here; the mandatory restore-resume checkpoint immediately
    -- following this action proves that both migrated worlds have the same
    -- new core digest before gameplay is released.
    local source = restore.sourceAnchor
    if type(source) ~= "table"
      or util.integer(source.boundarySeq, 0) ~= expected.boundarySeq
      or tostring(source.coreDigest or "") ~= expected.coreDigest
      or tostring(source.convergenceKey or "") ~= expected.convergenceKey then
      restore.status, restore.error = "failed", "restored source anchor does not match the plan"
      return false, restore.error
    end
    restore.migratedCoreDigest = coreDigest()
    restore.status, restore.commitSeq = "committed", commitSeq
    restore.resumedTick, restore.error = state.tick, nil
    return true, util.deepCopy(restore)
  end

  return { normalise = normalise, apply = apply }
end

return M
