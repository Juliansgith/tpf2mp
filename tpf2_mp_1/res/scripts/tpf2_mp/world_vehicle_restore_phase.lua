local util = require "tpf2_mp/util"

local M = {}

local STABLE_PHASES = {
  enroute = true,
  ["release-armed"] = true,
  ["await-departure"] = true,
}

local function integer(value)
  local number = tonumber(value)
  return number and math.floor(number) or nil
end

local function reject(reasons, message)
  reasons[#reasons + 1] = message
end

-- Project only portable, discrete route state. Exact coordinates and native
-- entity ids remain deliberately outside recovery authority.
function M.project(spec)
  local vehicleCid, lineCid = spec.vehicleCid, spec.lineCid
  local phase = { vehicleCid = vehicleCid, lineCid = lineCid }
  if spec.nativeLineAssigned and not lineCid then
    phase.syncPhase = "unmapped-line"
    return phase, false, "native line has no portable canonical binding"
  end
  if not lineCid then
    phase.syncPhase = "unassigned"
    return phase, true
  end

  local reasons, native, entry, record = {}, spec.native, spec.entry, spec.record
  local nativeState = integer(spec.safeField(native, "state"))
  local nativeStop = integer(spec.safeField(native, "stopIndex"))
  local nativeStopped = spec.safeField(native, "userStopped") == true
  local requestedStopped = spec.metadata and spec.metadata.userStopped == true
  local syncPhase = record and tostring(record.phase or "") or "missing"
  local syncRound = record and math.max(0, util.integer(record.round, 0)) or nil
  local syncStop = record and integer(record.stopIndex) or nil
  local authorizedRound = entry and math.max(
    0, util.integer(entry.lastAuthorizedRound, 0)) or nil
  local authorizedStop = entry and integer(entry.stopIndex) or nil

  phase.atTerminal = nativeState == 2
  phase.nativeStopIndex = nativeStop
  phase.nativeUserStopped = nativeStopped
  phase.requestedStopped = requestedStopped
  phase.syncPhase = syncPhase
  phase.syncRound = syncRound
  phase.syncStopIndex = syncStop
  phase.authorizedRound = authorizedRound
  phase.authorizedStopIndex = authorizedStop
  phase.departedSinceRelease = record and record.departedSinceRelease == true or false
  phase.releaseReportPending = record and record.releaseReportPending == true or false

  if not native or nativeState == nil then reject(reasons, "native state is unreadable") end
  if nativeStop == nil or nativeStop < 0 or nativeStop > 255 then
    reject(reasons, "native stop index is unreadable")
  end
  if not entry or entry.lineCid ~= lineCid then
    reject(reasons, "canonical station synchronization is not bound to the line")
  end
  if not record or record.lineCid ~= lineCid then
    reject(reasons, "local station synchronization has no matching line state")
  elseif not STABLE_PHASES[syncPhase] then
    reject(reasons, "local station synchronization phase is transient")
  else
    local terminalPhase = syncPhase ~= "enroute"
    if phase.atTerminal ~= terminalPhase then
      reject(reasons, "native terminal state disagrees with the station phase")
    end
    if syncRound ~= authorizedRound then
      reject(reasons, "local and authorized station rounds differ")
    end
    if syncPhase ~= "enroute" and syncStop ~= nativeStop then
      reject(reasons, "terminal and synchronized stop indices differ")
    end
    if record.releaseReportPending == true then
      reject(reasons, "station release report is still pending")
    end
    if syncPhase == "release-armed" and not nativeStopped then
      reject(reasons, "armed station release is not natively held")
    elseif syncPhase ~= "release-armed" and nativeStopped ~= requestedStopped then
      reject(reasons, "native stop actuator disagrees with canonical stop intent")
    end
  end
  return phase, #reasons == 0, table.concat(reasons, "; ")
end

return M
