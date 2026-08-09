local util = require "tpf2_mp/util"
local hash = require "tpf2_mp/hash"
local passengerPresentation = require "tpf2_mp/passenger_presentation"
local cargoPresentation = require "tpf2_mp/cargo_presentation"

local M = {}
local MAX_EXACT_INTEGER = 9007199254740991

function M.disabledSchedule()
  return { schemaVersion = 1, enabled = false }
end

function M.scheduleView(value)
  if type(value) ~= "table" or value.enabled ~= true then return M.disabledSchedule() end
  return {
    schemaVersion = 1,
    enabled = true,
    periodSeconds = math.max(1, util.integer(value.periodSeconds, 1)),
    phaseSeconds = math.max(0, util.integer(value.phaseSeconds, 0)),
    slotIndex = math.max(0, util.integer(value.slotIndex, 0)),
    scheduledDepartureAt = tonumber(value.scheduledDepartureAt) or 0,
  }
end

local function exactFields(value, names)
  if type(value) ~= "table" then return false end
  local expected, count = {}, 0
  for _, name in ipairs(names) do expected[name] = true end
  for key in pairs(value) do
    if not expected[key] then return false end
    count = count + 1
  end
  return count == #names
end

function M.normalizeReleaseSchedule(value, releaseAt, releaseWhilePaused)
  if value == nil then return M.disabledSchedule() end -- schema-1 archive compatibility
  if type(value) ~= "table" or value.schemaVersion ~= 1 or type(value.enabled) ~= "boolean" then
    return nil, "vehicle release schedule header is invalid"
  end
  if value.enabled == false then
    if not exactFields(value, { "schemaVersion", "enabled" }) then
      return nil, "disabled vehicle release schedule has unknown fields"
    end
    return M.disabledSchedule()
  end
  if not exactFields(value, { "schemaVersion", "enabled", "periodSeconds", "phaseSeconds",
      "slotIndex", "scheduledDepartureAt" }) then
    return nil, "enabled vehicle release schedule has unknown or missing fields"
  end
  local period = tonumber(value.periodSeconds)
  local phase = tonumber(value.phaseSeconds)
  local slotIndex = tonumber(value.slotIndex)
  local scheduled = tonumber(value.scheduledDepartureAt)
  if not period or period ~= math.floor(period) or period < 1 or period > 31536000
    or not phase or phase ~= math.floor(phase) or phase < 0 or phase >= period
    or not slotIndex or slotIndex ~= math.floor(slotIndex) or slotIndex < 0 or slotIndex > 1000000000
    or not scheduled or scheduled ~= scheduled or scheduled < 0 or scheduled > MAX_EXACT_INTEGER
    or scheduled ~= phase + slotIndex * period
    or tonumber(releaseAt) ~= scheduled or releaseWhilePaused == true then
    return nil, "enabled vehicle release schedule is inconsistent"
  end
  return {
    schemaVersion = 1,
    enabled = true,
    periodSeconds = period,
    phaseSeconds = phase,
    slotIndex = slotIndex,
    scheduledDepartureAt = scheduled,
  }
end

function M.equalSchedules(first, second)
  return hash.value(M.scheduleView(first)) == hash.value(M.scheduleView(second))
end

function M.reportSchedule(value)
  if type(value) ~= "table" or value.enabled ~= true then return M.disabledSchedule() end
  return {
    schemaVersion = 1,
    enabled = true,
    periodSeconds = math.max(1, util.integer(value.periodSeconds, 1)),
    phaseSeconds = math.max(0, util.integer(value.phaseSeconds, 0)),
  }
end

function M.scheduleFor(economyState, lineCid, stopIndex, synchronizationSchedule)
  local service = economyState and economyState.services and economyState.services[lineCid] or nil
  local policy = synchronizationSchedule(lineCid, service, stopIndex)
  if type(policy) ~= "table" or policy.enabled ~= true then return M.disabledSchedule() end
  return M.reportSchedule({
    enabled = true,
    periodSeconds = policy.periodSeconds,
    phaseSeconds = policy.phaseSeconds,
  })
end

-- High-frequency urban fleets would otherwise create one all-peer network
-- round at every intermediate curb stop. Their authored passenger ledger only
-- boards/alights at the route endpoints, so ROAD/TRAM services rendezvous at
-- those two anchors. Freight still uses its exact source/sink indices. Rail,
-- water, air, unknown and pre-registration services retain every-stop safety.
function M.synchronizesStop(economyState, lineCid, stopIndex)
  local service = economyState and economyState.services and economyState.services[lineCid]
  local metadata = service and service.metadata or {}
  local index = util.integer(stopIndex, -1)
  if metadata.freightContractSchema ~= nil then
    return index == util.integer(metadata.sourceStopIndex, -2)
      or index == util.integer(metadata.destinationStopIndex, -3)
  end
  if metadata.carrier ~= "ROAD" and metadata.carrier ~= "TRAM" then return true end
  local stops = metadata.stationGroupCids
  if type(stops) ~= "table" or #stops < 2 then return true end
  return index == 0 or index == #stops - 1
end

function M.authoritativeEntry(worldState, vehicleCid)
  local sync = worldState.vehicleSync
  sync.vehicles = sync.vehicles or {}
  return sync.vehicles[vehicleCid]
end

function M.passThrough(record, lastRound)
  if record.phase == "held" or record.phase == "holding"
    or record.phase == "release-armed" then
    return false, "vehicle reached a pass-through stop before ordered release"
  end
  record.phase, record.round, record.departedSinceRelease = "pass-through", lastRound, true
  return true
end

function M.digestView(worldState)
  local source = worldState and worldState.vehicleSync or {}
  local vehicles = {}
  for _, vehicleCid in ipairs(util.sortedKeys(source.vehicles or {})) do
    local item = source.vehicles[vehicleCid]
    vehicles[#vehicles + 1] = {
      vehicleCid = vehicleCid,
      lineCid = item.lineCid,
      companyCid = item.companyCid,
      lastAuthorizedRound = math.max(0, util.integer(item.lastAuthorizedRound, 0)),
      stopIndex = item.stopIndex,
      releaseAtGameTime = item.releaseAtGameTime,
      releaseWhilePaused = item.releaseWhilePaused == true,
      schedule = M.scheduleView(item.schedule),
    }
  end
  local reservations = {}
  for _, key in ipairs(util.sortedKeys(source.scheduleReservations or {})) do
    local item = source.scheduleReservations[key]
    reservations[#reservations + 1] = {
      lineCid = item.lineCid,
      stopIndex = math.max(0, util.integer(item.stopIndex, 0)),
      periodSeconds = math.max(1, util.integer(item.periodSeconds, 1)),
      phaseSeconds = math.max(0, util.integer(item.phaseSeconds, 0)),
      lastSlotIndex = math.max(0, util.integer(item.lastSlotIndex, 0)),
      lastScheduledDepartureAt = tonumber(item.lastScheduledDepartureAt) or 0,
    }
  end
  return {
    schemaVersion = 4,
    enabled = source.enabled ~= false,
    vehicles = vehicles,
    scheduleReservations = reservations,
    passengerPresentation = passengerPresentation.digestView(
      worldState and worldState.passengerPresentation),
    cargoPresentation = cargoPresentation.digestView(
      worldState and worldState.cargoPresentation),
  }
end

return M
