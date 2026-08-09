local util = require "tpf2_mp/util"

local M = {}

local function belongs(snapshot, companyCid)
  local active = snapshot and snapshot.activeCompanyCid
  return active == nil or companyCid == nil or companyCid == active
end

local function finish(lines, omitted, empty)
  if #lines == 0 then lines[1] = empty end
  if omitted > 0 then
    lines[#lines + 1] = string.format("... %d more in the Multiplayer panel", omitted)
  end
  return table.concat(lines, "\n")
end

function M.services(snapshot, limit, money)
  local view = snapshot and snapshot.economyPresentation or {}
  local lines, omitted = {}, 0
  for _, cid in ipairs(util.sortedKeys(view.services or {})) do
    local service = view.services[cid]
    if belongs(snapshot, service.companyCid) then
      if #lines < (limit or 10) then
        local units = service.kind == "cargo" and "cargo" or "passengers"
        lines[#lines + 1] = string.format("%s | %d %s delivered + %d pending | %s | %s net/5m",
          tostring(service.name or cid), tonumber(service.delivered) or 0, units,
          tonumber(service.pendingDelivered) or 0,
          service.topSpeedKmh and (tostring(service.topSpeedKmh) .. " km/h") or "speed estimated",
          money(service.netRevenueCents))
      else omitted = omitted + 1 end
    end
  end
  return finish(lines, omitted, "No registered authored services.")
end

function M.vehicles(snapshot, limit, money)
  local view = snapshot and snapshot.economyPresentation or {}
  local passengers = snapshot and snapshot.passengerPresentation or {}
  local cargo = snapshot and snapshot.cargoPresentation or {}
  local lines, omitted = {}, 0
  for _, cid in ipairs(util.sortedKeys(view.vehicles or {})) do
    local vehicle = view.vehicles[cid]
    if belongs(snapshot, vehicle.companyCid) then
      if #lines < (limit or 10) then
        local load = cargo.vehicles and cargo.vehicles[cid]
          or passengers.vehicles and passengers.vehicles[cid] or {}
        local unit = load.cargoType or "pax"
        lines[#lines + 1] = string.format("%s | %d/%d %s | %s/yr | %s",
          tostring(load.name or cid), tonumber(load.aboard) or 0,
          tonumber(load.capacity) or 0, tostring(unit),
          money(vehicle.annualVehicleUpkeepCents),
          tostring(load.lineName or vehicle.lineCid or "unassigned"))
      else omitted = omitted + 1 end
    end
  end
  return finish(lines, omitted, "No canonical vehicles.")
end

local function owned(snapshot, station)
  for _, line in ipairs(station and station.lines or {}) do
    if belongs(snapshot, line.companyCid) then return true end
  end
  return false
end

function M.stations(snapshot, limit)
  local passengers = snapshot and snapshot.passengerPresentation or {}
  local cargo = snapshot and snapshot.cargoPresentation or {}
  local stationCids = {}
  for cid in pairs(passengers.stations or {}) do stationCids[cid] = true end
  for cid in pairs(cargo.stations or {}) do stationCids[cid] = true end
  local lines, omitted = {}, 0
  for _, cid in ipairs(util.sortedKeys(stationCids)) do
    local passenger, freight = (passengers.stations or {})[cid], (cargo.stations or {})[cid]
    if owned(snapshot, passenger) or owned(snapshot, freight) then
      if #lines < (limit or 10) then
        lines[#lines + 1] = string.format(
          "%s | %d pax + %d cargo waiting | %d cargo delivered | %d passengers/5m",
          tostring((passenger and passenger.name) or (freight and freight.name) or cid),
          tonumber(passenger and passenger.waiting) or 0,
          tonumber(freight and freight.waiting) or 0,
          tonumber(freight and freight.delivered) or 0,
          tonumber(passenger and passenger.throughput) or 0)
      else omitted = omitted + 1 end
    end
  end
  return finish(lines, omitted, "No authored passenger or cargo station boards.")
end

return M
