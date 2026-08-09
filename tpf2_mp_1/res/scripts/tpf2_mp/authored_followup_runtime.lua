local canonical = require "tpf2_mp/canonical"
local util = require "tpf2_mp/util"

local M = {}

local MAX_SAFE_INTEGER = 9007199254740991

function M.validateTownBatch(state, batch, requireBinding)
  if type(batch) ~= "table" or next(batch) == nil then
    return false, "town development order carries no towns"
  end
  local count = 0
  for townCid, calls in pairs(batch) do
    count = count + 1
    if count > 512 then return false, "town development batch is too large" end
    if type(townCid) ~= "string" or townCid:sub(1, 5) ~= "town:"
      or #townCid > 320 then
      return false, "town development batch has an invalid town id"
    end
    if type(calls) ~= "number" or calls ~= math.floor(calls)
      or calls < 1 or calls > 8 then
      return false, "town development call count is outside [1,8]"
    end
    if requireBinding then
      local record = state.canonical.byCanonical
        and state.canonical.byCanonical[townCid] or nil
      local localId = canonical.resolveLocal(state.canonical, townCid)
      if not record or record.kind ~= "town" or not localId then
        return false, "canonical town has no local manifest binding: " .. townCid
      end
    end
  end
  return true
end

function M.applyTownDevelopment(state, action, deps)
  local running, runningError = deps.requireRunningMatch()
  if not running then return false, runningError end
  local valid, validationError = M.validateTownBatch(state, action.batch, true)
  if not valid then return false, validationError end
  local result = deps.world.runOrderedDevelopment(
    state, action.batch,
    function()
      return deps.world.structuralSnapshot(
        state.canonical, state.world, state.companies)
    end,
    deps.diagnosticLog)
  if type(result.errors) == "table" and #result.errors > 0 then
    return false, table.concat(result.errors, "; ")
  end
  return true, util.deepCopy(result)
end

function M.acknowledgeSaveReceipt(state, action)
  if not state.initialized then return false, "initialise the match first" end
  local allowed = {
    type = true, boundarySeq = true, savedAtUnix = true, saveSha256 = true,
    metadataSha256 = true, coreDigest = true, convergenceKey = true, paused = true,
  }
  for key in pairs(action) do
    if not allowed[key] then
      return false, "save receipt has an unknown field: " .. tostring(key)
    end
  end
  for _, key in ipairs({ "type", "boundarySeq", "savedAtUnix", "saveSha256",
      "coreDigest", "convergenceKey", "paused" }) do
    if action[key] == nil then return false, "save receipt is missing " .. key end
  end
  if type(action.boundarySeq) ~= "number"
    or action.boundarySeq ~= math.floor(action.boundarySeq)
    or action.boundarySeq < 1 or action.boundarySeq > MAX_SAFE_INTEGER then
    return false, "save receipt boundary is invalid"
  end
  if type(action.savedAtUnix) ~= "number"
    or action.savedAtUnix ~= math.floor(action.savedAtUnix)
    or action.savedAtUnix < 0 or action.savedAtUnix > MAX_SAFE_INTEGER then
    return false, "save receipt timestamp is invalid"
  end
  if action.paused ~= true then
    return false, "save receipt does not attest a paused world"
  end
  if type(action.saveSha256) ~= "string" or #action.saveSha256 ~= 64
    or not action.saveSha256:match("^[0-9a-f]+$") then
    return false, "save receipt hash is invalid"
  end
  if action.metadataSha256 ~= nil and (type(action.metadataSha256) ~= "string"
      or #action.metadataSha256 ~= 64
      or not action.metadataSha256:match("^[0-9a-f]+$")) then
    return false, "save receipt metadata hash is invalid"
  end
  for _, field in ipairs({ "coreDigest", "convergenceKey" }) do
    local value = action[field]
    if type(value) ~= "string" or value == "" or #value > 128 then
      return false, "save receipt " .. field .. " is invalid"
    end
  end
  return true, {
    boundarySeq = action.boundarySeq,
    saveSha256 = action.saveSha256,
    metadataSha256 = action.metadataSha256,
    acknowledged = true,
  }
end

function M.installHandlers(handlers, deps)
  handlers["town.develop"] = function(action)
    return M.applyTownDevelopment(deps.getState(), action, deps)
  end
  handlers["recovery.save_receipt"] = function(action)
    return M.acknowledgeSaveReceipt(deps.getState(), action)
  end
end

function M.afterCommit(state, action, success, authoritySeq, exportCheckpoint, log)
  if not success or not authoritySeq then return false end
  local reason
  if action.type == "town.develop" then reason = "town-development"
  elseif action.type == "economy.settle" then reason = "economy-settlement"
  else return false end
  local checkpointed, checkpointError = exportCheckpoint(
    authoritySeq, reason)
  if not checkpointed then
    log("checkpoint-barrier-error", {
      tick = state.tick,
      boundarySeq = authoritySeq,
      error = tostring(checkpointError),
    })
  end
  return true
end

return M
