local util = require "tpf2_mp/util"

local M = {}

local function optional(record, key, value)
  if value ~= nil then record[key] = value end
end

local function nameOf(registry, cid, fallback)
  local binding = registry and registry.byCanonical and registry.byCanonical[cid] or nil
  return binding and binding.metadata and binding.metadata.name or fallback or cid,
    binding and tonumber(binding.localId) or nil
end

function M.new(env)
  local schemaVersion = assert(env.schemaVersion, "cargo projection schema is required")
  local migrate, count, cents = env.migrate, env.count, env.cents
  local add, addCents, availableOutput = env.add, env.addCents, env.availableOutput
  local result = {}

  function result.digestView(value)
    local state, lines = migrate(value), {}
    for _, lineCid in ipairs(util.sortedKeys(state.lines)) do
      local item = state.lines[lineCid]
      lines[#lines + 1] = {
        lineCid = lineCid, companyCid = item.companyCid, marketCid = item.marketCid,
        contractDigest = item.contractDigest,
        sourceIndustryCid = item.sourceIndustryCid,
        destinationIndustryCid = item.destinationIndustryCid,
        destinationStockIndex = util.integer(item.destinationStockIndex, 0),
        cargoType = item.cargoType,
        sourceStationGroupCid = item.sourceStationGroupCid,
        destinationStationGroupCid = item.destinationStationGroupCid,
        sourceStopIndex = count(item.sourceStopIndex),
        destinationStopIndex = count(item.destinationStopIndex),
        transportSchema = util.integer(item.transportSchema, 1),
        pathDigest = item.pathDigest or item.contractDigest,
        legIndex = count(item.legIndex), legCount = math.max(1, count(item.legCount)),
        sourceKind = item.sourceKind == "station" and "station" or "industry",
        destinationKind = item.destinationKind == "station" and "station" or "industry",
        stops = util.deepCopy(item.stops or {}), routeDigest = item.routeDigest,
        epoch = count(item.epoch), allocated = count(item.allocated),
        boardedThisEpoch = count(item.boardedThisEpoch),
        capacityPerVehicle = count(item.capacityPerVehicle),
        boardedTotal = count(item.boardedTotal),
        deliveredTotal = count(item.deliveredTotal),
        earnedRevenueCents = cents(item.earnedRevenueCents),
        discardedTotal = count(item.discardedTotal), retired = item.retired == true,
      }
    end
    local vehicles = {}
    for _, vehicleCid in ipairs(util.sortedKeys(state.vehicles)) do
      local item = state.vehicles[vehicleCid]
      local record = {
        vehicleCid = vehicleCid, lineCid = item.lineCid, companyCid = item.companyCid,
        capacity = count(item.capacity), aboard = count(item.aboard),
        lastRound = count(item.lastRound), boardedTotal = count(item.boardedTotal),
        deliveredTotal = count(item.deliveredTotal),
        earnedRevenueCents = cents(item.earnedRevenueCents),
        discardedTotal = count(item.discardedTotal),
      }
      optional(record, "boardedEpoch", item.boardedEpoch and count(item.boardedEpoch))
      optional(record, "lastStopIndex", item.lastStopIndex and count(item.lastStopIndex))
      optional(record, "lastStationGroupCid", item.lastStationGroupCid)
      optional(record, "boardedFareCents", item.boardedFareCents and count(item.boardedFareCents))
      optional(record, "boardedDistanceMeters",
        item.boardedDistanceMeters and count(item.boardedDistanceMeters))
      vehicles[#vehicles + 1] = record
    end
    return { schemaVersion = schemaVersion, epoch = state.epoch,
      lines = lines, vehicles = vehicles, stationStock = util.deepCopy(state.stationStock) }
  end

  function result.economySnapshot(value)
    local state, lines = migrate(value), {}
    for _, lineCid in ipairs(util.sortedKeys(state.lines)) do
      local line = state.lines[lineCid]
      local row = {
        contractDigest = line.contractDigest,
        sourceIndustryCid = line.sourceIndustryCid,
        destinationIndustryCid = line.destinationIndustryCid,
        destinationStockIndex = util.integer(line.destinationStockIndex, 0),
        cargoType = line.cargoType,
        boardedUnits = count(line.boardedTotal),
        deliveredUnits = count(line.deliveredTotal),
        earnedRevenueCents = cents(line.earnedRevenueCents),
      }
      if util.integer(line.transportSchema, 1) >= 2 then
        row.transportSchema, row.pathDigest = 2, line.pathDigest
        row.legIndex, row.legCount = count(line.legIndex), math.max(1, count(line.legCount))
        row.sourceKind, row.destinationKind = line.sourceKind, line.destinationKind
        row.sourceStationGroupCid = line.sourceStationGroupCid
        row.destinationStationGroupCid = line.destinationStationGroupCid
      end
      lines[lineCid] = row
    end
    return { schemaVersion = schemaVersion, presentationEpoch = state.epoch, lines = lines }
  end

  function result.publicView(value, economyState, freightState, registry)
    local state = migrate(value)
    local view = { schemaVersion = schemaVersion, epoch = state.epoch,
      lines = {}, stations = {}, vehicles = {}, localVehicles = {}, localStations = {},
      transferStations = {}, totals = { waiting = 0, aboard = 0, capacity = 0,
        boarded = 0, delivered = 0, transferStock = 0, discarded = 0,
        earnedRevenueCents = 0 } }
    for _, stationCid in ipairs(util.sortedKeys(state.stationStock)) do
      local stocks, total = {}, 0
      for _, cargoType in ipairs(util.sortedKeys(state.stationStock[stationCid])) do
        local amount = count(state.stationStock[stationCid][cargoType])
        if amount > 0 then stocks[cargoType], total = amount, total + amount end
      end
      if total > 0 then
        local stationName, localStationId = nameOf(registry, stationCid, stationCid)
        view.transferStations[stationCid] = { stationGroupCid = stationCid,
          name = stationName, localId = localStationId, stocks = stocks, total = total }
        view.totals.transferStock = add(view.totals.transferStock, total)
      end
    end
    for _, lineCid in ipairs(util.sortedKeys(state.lines)) do
      local item = util.deepCopy(state.lines[lineCid])
      local service = economyState and economyState.services and economyState.services[lineCid] or {}
      item.name, item.localId = nameOf(registry, lineCid, service.name)
      item.sourceIndustryName = nameOf(registry, item.sourceIndustryCid, item.sourceIndustryCid)
      item.destinationIndustryName = nameOf(
        registry, item.destinationIndustryCid, item.destinationIndustryCid)
      item.availableAtSource = availableOutput(state, freightState, item)
      item.waiting = math.min(item.availableAtSource,
        math.max(0, count(item.allocated) - count(item.boardedThisEpoch)))
      view.lines[lineCid] = item
      view.totals.waiting = add(view.totals.waiting, item.waiting)
      view.totals.boarded = add(view.totals.boarded, item.boardedTotal)
      view.totals.delivered = add(view.totals.delivered, item.deliveredTotal)
      view.totals.discarded = add(view.totals.discarded, item.discardedTotal)
      view.totals.earnedRevenueCents = addCents(
        view.totals.earnedRevenueCents, item.earnedRevenueCents)
      local stationName, localStationId = nameOf(
        registry, item.sourceStationGroupCid, item.sourceStationGroupCid)
      local station = view.stations[item.sourceStationGroupCid] or {
        stationGroupCid = item.sourceStationGroupCid, name = stationName,
        localId = localStationId, waiting = 0, delivered = 0, lines = {} }
      station.waiting = add(station.waiting, item.waiting)
      station.lines[#station.lines + 1] = { lineCid = lineCid, name = item.name,
        companyCid = item.companyCid, cargoType = item.cargoType,
        waiting = item.waiting, delivered = 0, role = "source" }
      view.stations[item.sourceStationGroupCid] = station
      if localStationId then view.localStations[tostring(localStationId)] = item.sourceStationGroupCid end

      local destinationName, localDestinationId = nameOf(
        registry, item.destinationStationGroupCid, item.destinationStationGroupCid)
      local destination = view.stations[item.destinationStationGroupCid] or {
        stationGroupCid = item.destinationStationGroupCid, name = destinationName,
        localId = localDestinationId, waiting = 0, delivered = 0, lines = {} }
      destination.delivered = add(destination.delivered, item.deliveredTotal)
      destination.lines[#destination.lines + 1] = { lineCid = lineCid, name = item.name,
        companyCid = item.companyCid, cargoType = item.cargoType, waiting = 0,
        delivered = item.deliveredTotal, role = "destination" }
      view.stations[item.destinationStationGroupCid] = destination
      if localDestinationId then
        view.localStations[tostring(localDestinationId)] = item.destinationStationGroupCid
      end
    end
    for _, vehicleCid in ipairs(util.sortedKeys(state.vehicles)) do
      local item = util.deepCopy(state.vehicles[vehicleCid])
      item.name, item.localId = nameOf(registry, vehicleCid, vehicleCid)
      local line = state.lines[item.lineCid]
      item.cargoType = line and line.cargoType or nil
      item.lineName = view.lines[item.lineCid] and view.lines[item.lineCid].name or item.lineCid
      view.vehicles[vehicleCid] = item
      if item.localId then view.localVehicles[tostring(item.localId)] = vehicleCid end
      view.totals.aboard = add(view.totals.aboard, item.aboard)
      view.totals.capacity = add(view.totals.capacity, item.capacity)
    end
    return view
  end

  return result
end

return M
