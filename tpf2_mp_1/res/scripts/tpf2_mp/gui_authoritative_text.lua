local util = require "tpf2_mp/util"

local M = {}

local function rounded(value)
  value = tonumber(value) or 0
  if value >= 0 then return math.floor(value + 0.5) end
  return math.ceil(value - 0.5)
end

local function grouped(value)
  local integer = rounded(value)
  local sign = integer < 0 and "-" or ""
  local digits = tostring(math.abs(integer))
  local result = digits
  while true do
    local changed
    result, changed = result:gsub("^(%d+)(%d%d%d)", "%1,%2")
    if changed == 0 then break end
  end
  return sign .. result
end

function M.moneyCents(cents)
  local dollars = (tonumber(cents) or 0) / 100
  local absolute = math.abs(dollars)
  if absolute >= 1000000000 then return string.format("$%.2fb", dollars / 1000000000) end
  if absolute >= 1000000 then return string.format("$%.2fm", dollars / 1000000) end
  if absolute >= 1000 then return string.format("$%.1fk", dollars / 1000) end
  return string.format("$%.2f", dollars)
end

function M.moneyDollars(dollars)
  return M.moneyCents((tonumber(dollars) or 0) * 100)
end

function M.accountNumber(dollars)
  return grouped(dollars)
end

local function minutes(seconds)
  return string.format("%.1f min", (tonumber(seconds) or 0) / 60)
end

local function percentPpm(value)
  return string.format("%.1f%%", (tonumber(value) or 0) / 10000)
end

local function activeCompany(snapshot)
  local view = snapshot and snapshot.economyPresentation or {}
  local cid = view.activeCompanyCid or (snapshot and snapshot.activeCompanyCid)
  local projected = cid and view.companies and view.companies[cid] or {}
  local account = cid and snapshot and snapshot.companies and snapshot.companies[cid] or {}
  local ledger = cid and snapshot and snapshot.ledger and snapshot.ledger.companies
    and snapshot.ledger.companies[cid] or {}
  return cid, projected or {}, account or {}, ledger or {}
end

local function localItem(view, mapName, valuesName, localId)
  if type(view) ~= "table" or localId == nil then return nil, nil end
  local map = view[mapName] or {}
  local cid = map[tostring(localId)]
  return cid and (view[valuesName] or {})[cid] or nil, cid
end

function M.company(snapshot)
  snapshot = snapshot or {}
  local cid, company, account, ledger = activeCompany(snapshot)
  local balance = account.effectiveBalance
  if balance == nil then balance = account.balance end
  local gross = company.grossRevenueCents or company.revenueCents or 0
  local vehicles = company.vehicleUpkeepCents or 0
  local infrastructure = company.infrastructureUpkeepCents or 0
  local net = company.netRevenueCents or company.revenueCents or 0
  local cumulative = ledger.netRevenueCents or ledger.revenueCents
  local name = snapshot.activeCompanyName or account.name or cid or "company"
  local economyView = snapshot.economyPresentation or {}
  local difficultyText = string.format("%s %.0f%%",
    tostring(economyView.economyDifficultyLabel or "Normal"),
    (tonumber(economyView.revenueMultiplierPpm) or 1000000) / 10000)
  local primary = string.format("%s | balance %s | accounting tick %d",
    tostring(name), balance ~= nil and M.moneyDollars(balance) or "unavailable",
    tonumber(snapshot.epoch) or 0)
  local secondary = string.format("%s | Last 5m: %s gross - %s vehicles - %s infrastructure = %s net | %s pending",
    difficultyText,
    M.moneyCents(gross), M.moneyCents(vehicles), M.moneyCents(infrastructure),
    M.moneyCents(net), M.moneyCents(company.pendingGrossRevenueCents))
  if cumulative ~= nil then
    secondary = secondary .. " | cumulative net " .. M.moneyCents(cumulative)
  end
  return {
    title = "TPF2MP AUTHORITATIVE COMPANY",
    primary = primary,
    secondary = secondary,
    tooltip = "Synchronized competitive account with five-minute accounting. Completed passenger trips accrue pending revenue immediately; the next tick pays it. Native trip income and journal history are cosmetic.",
    balance = balance,
    netRevenueCents = net,
  }
end

function M.vehicle(snapshot, localId)
  snapshot = snapshot or {}
  local economyView = snapshot.economyPresentation or {}
  local passengerView = snapshot.passengerPresentation or {}
  local economyItem, cid = localItem(economyView, "localVehicles", "vehicles", localId)
  local passengerItem = localItem(passengerView, "localVehicles", "vehicles", localId)
  if not economyItem and not passengerItem then
    return {
      title = "TPF2MP AUTHORITATIVE VEHICLE",
      primary = "This vehicle is not yet canonical or assigned to an authored service.",
      secondary = "Native purchase and annual maintenance remain exact; native load and income history are cosmetic.",
      tooltip = "Assign the vehicle to a synchronized line to populate competitive load, revenue, and operating-cost fields.",
    }
  end
  local aboard = passengerItem and tonumber(passengerItem.aboard) or 0
  local capacity = passengerItem and tonumber(passengerItem.capacity) or 0
  local trip = "parked or between authored endpoints"
  if passengerItem and passengerItem.originName and passengerItem.destinationName then
    trip = tostring(passengerItem.originName) .. " -> " .. tostring(passengerItem.destinationName)
  elseif passengerItem and passengerItem.destinationName then
    trip = "to " .. tostring(passengerItem.destinationName)
  end
  local lineName = passengerItem and passengerItem.lineName
    or economyItem and economyItem.line and economyItem.line.name
    or economyItem and economyItem.lineCid or "unassigned"
  local purchase = economyItem and economyItem.purchasePriceDollars
    and M.moneyDollars(economyItem.purchasePriceDollars) or "pre-existing"
  local annual = economyItem and economyItem.annualVehicleUpkeepCents
    and (M.moneyCents(economyItem.annualVehicleUpkeepCents) .. "/yr") or "upkeep unbound"
  local hourly = economyItem and economyItem.projectedHourlyVehicleUpkeepCents
    and (M.moneyCents(economyItem.projectedHourlyVehicleUpkeepCents) .. "/h") or "-"
  local primary = string.format("%d/%d authored passengers | %s | line %s",
    aboard, capacity, trip, tostring(lineName))
  local secondary = string.format("Purchase %s | upkeep %s (%s)", purchase, annual, hourly)
  if economyItem and economyItem.line then
    secondary = secondary .. string.format(" | line %s pending, %s net/5m",
      M.moneyCents(economyItem.line.pendingGrossRevenueCents),
      M.moneyCents(economyItem.line.netRevenueCents))
  end
  return {
    title = "TPF2MP AUTHORITATIVE VEHICLE " .. tostring(cid or ""),
    primary = primary,
    secondary = secondary,
    tooltip = "Exact synchronized model load and competitive cost. The stock load glyph, transported counter, income popup, and history are hidden or relabelled because native agents are scenery.",
  }
end

function M.line(snapshot, localId)
  snapshot = snapshot or {}
  local economyView = snapshot.economyPresentation or {}
  local passengerView = snapshot.passengerPresentation or {}
  local service, cid = localItem(economyView, "localLines", "services", localId)
  local passengers = localItem(passengerView, "localLines", "lines", localId)
  if not service and not passengers then
    return {
      title = "TPF2MP AUTHORITATIVE LINE",
      primary = "Select or register a synchronized line to show competitive service facts.",
      secondary = "Native rate, transported, profit, and history are not used for match cash or score.",
      tooltip = "Line registration is automatic after canonical creation or assignment and may be rechecked from the Multiplayer panel.",
    }
  end
  local name = service and service.name or passengers and passengers.name or cid or "line"
  local speed = service and service.topSpeedKmh
    and (tostring(service.topSpeedKmh) .. " km/h") or "estimated speed"
  local primary = string.format("%s | fare %s | %s | %s trip | every %s | capacity %d/h",
    tostring(name), M.moneyCents(service and service.fareCents or 0), speed,
    minutes(service and service.journeySeconds), minutes(service and service.headwaySeconds),
    tonumber(service and service.capacity) or 0)
  local townScale = service and service.modelTownSizeA and service.modelTownSizeB
    and string.format(" | model towns %d <-> %d",
      tonumber(service.modelTownSizeA) or 0, tonumber(service.modelTownSizeB) or 0) or ""
  local secondary = string.format("%d demand/h | %d allocated, %d delivered + %d pending%s | share %s | %s net/5m (%s/h)",
    tonumber(service and service.hourlyMarketDemand) or 0,
    tonumber(passengers and passengers.allocated or service and service.allocated) or 0,
    tonumber(service and service.delivered) or 0,
    tonumber(service and service.pendingDelivered) or 0,
    townScale,
    percentPpm(service and service.sharePpm),
    M.moneyCents(service and service.netRevenueCents),
    M.moneyCents(service and service.projectedHourlyNetRevenueCents))
  return {
    title = "TPF2MP AUTHORITATIVE LINE " .. tostring(cid or ""),
    primary = primary,
    secondary = secondary,
    tooltip = "The demand model values fare, journey time, waiting time, crowding, capacity, rival services, and the outside option. These figures replace native profit and transported history for competitive play.",
  }
end

function M.station(snapshot, localId)
  snapshot = snapshot or {}
  local view = snapshot.passengerPresentation or {}
  local item, cid = localItem(view, "localStations", "stations", localId)
  if not item then
    return {
      title = "TPF2MP AUTHORITATIVE STATION",
      primary = "No authored passenger board is bound to this station group yet.",
      secondary = "Native waiting agents remain scenery and are not used for revenue or score.",
      tooltip = "Register a passenger service using this station to create its synchronized board.",
    }
  end
  local lineParts = {}
  for _, line in ipairs(item.lines or {}) do
    lineParts[#lineParts + 1] = string.format("%s %d waiting/%d this tick",
      tostring(line.name or line.lineCid), tonumber(line.waiting) or 0,
      tonumber(line.allocated) or 0)
  end
  return {
    title = "TPF2MP AUTHORITATIVE STATION " .. tostring(cid or ""),
    primary = string.format("%s | %d waiting | %d passengers this 5m tick",
      tostring(item.name or cid), tonumber(item.waiting) or 0, tonumber(item.throughput) or 0),
    secondary = #lineParts > 0 and table.concat(lineParts, " | ") or "No authored passenger service",
    tooltip = "Exact synchronized endpoint queues. The native StationGroupDisplay passenger/cargo agents are cosmetic and are hidden in multiplayer presentation.",
  }
end

function M.toolbar(snapshot)
  local company = M.company(snapshot)
  local totals = snapshot and snapshot.passengerPresentation
    and snapshot.passengerPresentation.totals or {}
  return {
    accountNumber = company.balance ~= nil and M.accountNumber(company.balance) or "--",
    earningsLabel = "TPF2MP net/5m",
    earnings = M.moneyCents(company.netRevenueCents),
    transportedPassengers = grouped(totals.boarded or 0),
    passengerTooltip = string.format(
      "Authoritative passengers transported: %s. Current exact state: %s aboard, %s waiting.",
      grouped(totals.boarded or 0), grouped(totals.aboard or 0), grouped(totals.waiting or 0)),
  }
end

local function belongsToActive(snapshot, companyCid)
  local active = snapshot and snapshot.activeCompanyCid
  return active == nil or companyCid == nil or companyCid == active
end

function M.serviceList(snapshot, limit)
  local view = snapshot and snapshot.economyPresentation or {}
  local lines, omitted = {}, 0
  for _, cid in ipairs(util.sortedKeys(view.services or {})) do
    local service = view.services[cid]
    if belongsToActive(snapshot, service.companyCid) then
      if #lines < (limit or 10) then
        lines[#lines + 1] = string.format("%s | %d delivered + %d pending | %s | %s net/5m",
          tostring(service.name or cid), tonumber(service.delivered) or 0,
          tonumber(service.pendingDelivered) or 0,
          service.topSpeedKmh and (tostring(service.topSpeedKmh) .. " km/h") or "speed estimated",
          M.moneyCents(service.netRevenueCents))
      else omitted = omitted + 1 end
    end
  end
  if #lines == 0 then lines[1] = "No registered authored services." end
  if omitted > 0 then lines[#lines + 1] = string.format("... %d more in the Multiplayer panel", omitted) end
  return table.concat(lines, "\n")
end

function M.vehicleList(snapshot, limit)
  local view = snapshot and snapshot.economyPresentation or {}
  local passengerView = snapshot and snapshot.passengerPresentation or {}
  local lines, omitted = {}, 0
  for _, cid in ipairs(util.sortedKeys(view.vehicles or {})) do
    local vehicle = view.vehicles[cid]
    if belongsToActive(snapshot, vehicle.companyCid) then
      if #lines < (limit or 10) then
        local passenger = passengerView.vehicles and passengerView.vehicles[cid] or {}
        lines[#lines + 1] = string.format("%s | %d/%d pax | %s/yr | %s",
          tostring(passenger.name or cid), tonumber(passenger.aboard) or 0,
          tonumber(passenger.capacity) or 0, M.moneyCents(vehicle.annualVehicleUpkeepCents),
          tostring(passenger.lineName or vehicle.lineCid or "unassigned"))
      else omitted = omitted + 1 end
    end
  end
  if #lines == 0 then lines[1] = "No canonical vehicles." end
  if omitted > 0 then lines[#lines + 1] = string.format("... %d more in the Multiplayer panel", omitted) end
  return table.concat(lines, "\n")
end

function M.stationList(snapshot, limit)
  local view = snapshot and snapshot.passengerPresentation or {}
  local lines, omitted = {}, 0
  for _, cid in ipairs(util.sortedKeys(view.stations or {})) do
    local station = view.stations[cid]
    local owned = false
    for _, line in ipairs(station.lines or {}) do
      if belongsToActive(snapshot, line.companyCid) then owned = true end
    end
    if owned then
      if #lines < (limit or 10) then
        lines[#lines + 1] = string.format("%s | %d waiting | %d passengers/5m",
          tostring(station.name or cid), tonumber(station.waiting) or 0,
          tonumber(station.throughput) or 0)
      else omitted = omitted + 1 end
    end
  end
  if #lines == 0 then lines[1] = "No authored passenger station boards." end
  if omitted > 0 then lines[#lines + 1] = string.format("... %d more in the Multiplayer panel", omitted) end
  return table.concat(lines, "\n")
end

return M
