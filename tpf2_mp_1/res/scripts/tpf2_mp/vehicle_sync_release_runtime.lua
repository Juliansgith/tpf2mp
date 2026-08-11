local util = require "tpf2_mp/util"
local vehicleSyncState = require "tpf2_mp/vehicle_sync_state"
local vehicleSyncPassengers = require "tpf2_mp/vehicle_sync_passengers"

local M = {}

local function authoritativeCompanyCid(state, binding, lineCid)
  local service = state.economy and state.economy.services
    and state.economy.services[lineCid] or nil
  local serviceCompany = service and service.companyCid or nil
  if type(serviceCompany) == "string" and serviceCompany:match("^company:%d+$") then
    return serviceCompany
  end
  local owner = binding and binding.metadata and binding.metadata.owner or nil
  if type(owner) == "string" and owner:match("^company:%d+$") then return owner end
  return nil
end

function M.apply(state, localVehicles, action)
  if state.networkMode ~= "network" then return false, "vehicle synchronization is network-only" end
  local vehicleCid = type(action) == "table" and tostring(action.vehicleCid or "") or ""
  local lineCid = type(action) == "table" and tostring(action.lineCid or "") or ""
  local round = util.integer(action and action.round, 0)
  local stopIndex = util.integer(action and action.stopIndex, -1)
  local releaseAt = tonumber(action and action.releaseAtGameTime)
  if not vehicleCid:match("^vehicle:") or not lineCid:match("^line:")
    or round < 1 or stopIndex < 0 or stopIndex > 255 or not releaseAt or releaseAt < 0
    or type(action.releaseWhilePaused) ~= "boolean" then
    return false, "invalid canonical vehicle release"
  end
  local releaseSchedule, scheduleError = vehicleSyncState.normalizeReleaseSchedule(
    action.schedule, releaseAt, action.releaseWhilePaused)
  if not releaseSchedule then return false, scheduleError end
  local binding = state.canonical.byCanonical[vehicleCid]
  if not binding or binding.kind ~= "vehicle" then
    return false, "canonical vehicle release target is not mapped"
  end
  local companyCid = authoritativeCompanyCid(state, binding, lineCid)
  if not companyCid then
    return false, "canonical vehicle release line has no authoritative company"
  end
  local sync = state.world.vehicleSync
  local entry = sync.vehicles[vehicleCid]
  if entry and entry.companyCid ~= nil and entry.companyCid ~= companyCid then
    return false, "canonical vehicle release company disagrees with its economy service"
  end
  local priorRound = entry and math.max(0, util.integer(entry.lastAuthorizedRound, 0)) or 0
  if round < priorRound or round > priorRound + 1 then
    return false, "vehicle release round is not sequential"
  end
  if round == priorRound then
    local same = entry.lineCid == lineCid and entry.stopIndex == stopIndex
      and tonumber(entry.releaseAtGameTime) == releaseAt
      and entry.releaseWhilePaused == action.releaseWhilePaused
      and vehicleSyncState.equalSchedules(entry.schedule, releaseSchedule)
    if not same then return false, "conflicting duplicate vehicle release" end
    local aligned, alignmentError = vehicleSyncPassengers.applyRelease(
      state.world, state.economy, sync, action, binding.metadata)
    if not aligned then return false, alignmentError end
    entry.companyCid = companyCid
    return true, util.deepCopy(entry)
  end
  local presented, presentationResult = vehicleSyncPassengers.applyRelease(
    state.world, state.economy, sync, action, binding.metadata)
  if not presented then return false, presentationResult end
  sync.vehicles[vehicleCid] = {
    vehicleCid = vehicleCid, lineCid = lineCid, companyCid = companyCid,
    lastAuthorizedRound = round, stopIndex = stopIndex,
    releaseAtGameTime = releaseAt,
    releaseWhilePaused = action.releaseWhilePaused == true,
    schedule = util.deepCopy(releaseSchedule),
  }
  sync.scheduleReservations = sync.scheduleReservations or {}
  if releaseSchedule.enabled == true then
    sync.scheduleReservations[lineCid .. "#" .. tostring(stopIndex)] = {
      lineCid = lineCid, stopIndex = stopIndex,
      periodSeconds = releaseSchedule.periodSeconds,
      phaseSeconds = releaseSchedule.phaseSeconds,
      lastSlotIndex = releaseSchedule.slotIndex,
      lastScheduledDepartureAt = releaseSchedule.scheduledDepartureAt,
    }
  else sync.scheduleReservations[lineCid .. "#" .. tostring(stopIndex)] = nil end
  local record = localVehicles[vehicleCid]
  if record then
    record.lineCid, record.round, record.stopIndex = lineCid, round, stopIndex
    record.schedule = util.deepCopy(releaseSchedule)
    record.phase = "release-armed"
  end
  return true, util.deepCopy(sync.vehicles[vehicleCid])
end

return M
