local util = require "tpf2_mp/util"
local hash = require "tpf2_mp/hash"
local revenue = require "tpf2_mp/economy_revenue"
local validation = require "tpf2_mp/cargo_presentation_validation"

local M = {}

M.SCHEMA_VERSION = 1
M.MAX_COUNT = 1000000000
M.MAX_CENTS = revenue.ACCUMULATOR_LIMIT

local function count(value)
  return math.min(M.MAX_COUNT, math.max(0, util.integer(value, 0)))
end

local function add(left, right)
  return math.min(M.MAX_COUNT, count(left) + count(right))
end

local function cents(value)
  return math.min(M.MAX_CENTS, math.max(0, util.integer(value, 0)))
end

local function addCents(left, right)
  return math.min(M.MAX_CENTS, cents(left) + cents(right))
end

local function cargoService(economyState, lineCid)
  local service = economyState and economyState.services
    and economyState.services[lineCid] or nil
  if not service or service.enabled == false then return nil end
  local market = economyState.markets and economyState.markets[service.marketCid] or nil
  if not market or market.kind ~= "cargo" then return nil end
  local metadata = service.metadata or {}
  local stops = metadata.stationGroupCids
  local sourceIndex = util.integer(metadata.sourceStopIndex, -1)
  local destinationIndex = util.integer(metadata.destinationStopIndex, -1)
  if metadata.freightContractSchema ~= 1
    or type(metadata.freightContractDigest) ~= "string"
    or type(metadata.sourceIndustryCid) ~= "string"
    or type(metadata.destinationIndustryCid) ~= "string"
    or type(metadata.cargoType) ~= "string"
    or type(metadata.destinationStockIndex) ~= "number"
    or type(stops) ~= "table" or #stops < 2
    or sourceIndex < 0 or sourceIndex >= #stops
    or destinationIndex < 0 or destinationIndex >= #stops
    or sourceIndex == destinationIndex
    or stops[sourceIndex + 1] ~= metadata.sourceStationGroupCid
    or stops[destinationIndex + 1] ~= metadata.destinationStationGroupCid then
    return nil
  end
  return service, market, stops, metadata
end

local function resultAllocation(economyState, service)
  local market = economyState and economyState.lastResults
    and economyState.lastResults.markets
    and economyState.lastResults.markets[service.marketCid] or nil
  local row = market and market.services and market.services[service.lineCid] or nil
  return count(row and row.allocated or 0)
end

function M.newState()
  return { schemaVersion = M.SCHEMA_VERSION, epoch = 0, lines = {}, vehicles = {} }
end

function M.migrate(value)
  if type(value) ~= "table" then return M.newState() end
  value.schemaVersion = M.SCHEMA_VERSION
  value.epoch = count(value.epoch)
  value.lines = type(value.lines) == "table" and value.lines or {}
  value.vehicles = type(value.vehicles) == "table" and value.vehicles or {}
  for _, line in pairs(value.lines) do
    line.boardedTotal = count(line.boardedTotal)
    line.deliveredTotal = count(line.deliveredTotal)
    line.boardedThisEpoch = count(line.boardedThisEpoch)
    line.earnedRevenueCents = cents(line.earnedRevenueCents)
    line.discardedTotal = count(line.discardedTotal)
  end
  for _, vehicle in pairs(value.vehicles) do
    vehicle.aboard = count(vehicle.aboard)
    vehicle.boardedTotal = count(vehicle.boardedTotal)
    vehicle.deliveredTotal = count(vehicle.deliveredTotal)
    vehicle.earnedRevenueCents = cents(vehicle.earnedRevenueCents)
    vehicle.discardedTotal = count(vehicle.discardedTotal)
  end
  return value
end

local function routeIdentity(service, stops, metadata)
  return {
    lineCid = service.lineCid,
    companyCid = service.companyCid,
    marketCid = service.marketCid,
    contractDigest = metadata.freightContractDigest,
    sourceIndustryCid = metadata.sourceIndustryCid,
    destinationIndustryCid = metadata.destinationIndustryCid,
    destinationStockIndex = util.integer(metadata.destinationStockIndex, -1),
    cargoType = metadata.cargoType,
    sourceStationGroupCid = metadata.sourceStationGroupCid,
    destinationStationGroupCid = metadata.destinationStationGroupCid,
    sourceStopIndex = util.integer(metadata.sourceStopIndex, -1),
    destinationStopIndex = util.integer(metadata.destinationStopIndex, -1),
    stops = util.deepCopy(stops),
  }
end

local function newLine(service, stops, metadata, epoch, previous)
  local identity = routeIdentity(service, stops, metadata)
  identity.epoch = epoch
  identity.routeDigest = hash.value(identity.stops)
  identity.allocated = resultAllocation(nil, service)
  identity.boardedThisEpoch = 0
  identity.capacityPerVehicle = count(metadata.cargoCapacityPerVehicle)
  identity.boardedTotal = count(previous and previous.boardedTotal)
  identity.deliveredTotal = count(previous and previous.deliveredTotal)
  identity.earnedRevenueCents = cents(previous and previous.earnedRevenueCents)
  identity.discardedTotal = count(previous and previous.discardedTotal)
  identity.retired = false
  return identity
end

local function ensureLine(state, economyState, lineCid, resetEpoch)
  local service, _, stops, metadata = cargoService(economyState, lineCid)
  if not service then
    if state.lines[lineCid] then state.lines[lineCid].retired = true end
    return nil
  end
  local epoch = count(economyState.epoch)
  local previous = state.lines[lineCid]
  if previous and previous.contractDigest ~= metadata.freightContractDigest then
    local active = count(previous.boardedTotal) > 0
      or count(previous.deliveredTotal) > 0 or count(previous.discardedTotal) > 0
    for _, vehicle in pairs(state.vehicles) do
      if vehicle.lineCid == lineCid and count(vehicle.aboard) > 0 then active = true end
    end
    if active then return false, "an active freight line cannot change its industry contract" end
    previous = nil
  end
  local line = previous or newLine(service, stops, metadata, epoch)
  local identity = routeIdentity(service, stops, metadata)
  for key, value in pairs(identity) do line[key] = value end
  line.routeDigest = hash.value(stops)
  line.capacityPerVehicle = count(metadata.cargoCapacityPerVehicle)
  line.retired = false
  line.allocated = resultAllocation(economyState, service)
  if resetEpoch or line.epoch ~= epoch then
    line.epoch = epoch
    line.boardedThisEpoch = 0
  end
  state.lines[lineCid] = line
  return line
end

local function retireVehicle(state, vehicleCid)
  local vehicle = state.vehicles[vehicleCid]
  if not vehicle then return end
  local line = state.lines[vehicle.lineCid]
  if line then line.discardedTotal = add(line.discardedTotal, vehicle.aboard) end
  state.vehicles[vehicleCid] = nil
end

function M.beginEpoch(value, economyState)
  local state = M.migrate(value)
  local epoch = count(economyState and economyState.epoch)
  if epoch < state.epoch then return false, "cargo presentation epoch moved backwards" end
  local advancing = epoch > state.epoch
  local retained = {}
  for _, lineCid in ipairs(util.sortedKeys(economyState and economyState.services or {})) do
    if cargoService(economyState, lineCid) then
      retained[lineCid] = true
      local line, lineError = ensureLine(state, economyState, lineCid, advancing)
      if line == false then return false, lineError end
    end
  end
  for lineCid, line in pairs(state.lines) do
    if not retained[lineCid] then line.retired = true end
  end
  for _, vehicleCid in ipairs(util.sortedKeys(state.vehicles)) do
    local vehicle = state.vehicles[vehicleCid]
    if not cargoService(economyState, vehicle.lineCid) then
      retireVehicle(state, vehicleCid)
    end
  end
  state.epoch = epoch
  return true, state
end

function M.reconcileService(value, economyState, lineCid)
  local state = M.migrate(value)
  local begun, beginError = M.beginEpoch(state, economyState)
  if not begun then return false, beginError end
  local line, lineError = ensureLine(state, economyState, lineCid, false)
  if line == false then return false, lineError end
  return true, line
end

local function vehicleRecord(state, service, metadata, action, owner)
  local line = assert(state.lines[action.lineCid])
  local existing = state.vehicles[action.vehicleCid]
  if existing and existing.lineCid ~= action.lineCid then
    local priorLine = state.lines[existing.lineCid]
    if priorLine then priorLine.discardedTotal = add(priorLine.discardedTotal, existing.aboard) end
    existing = nil
  end
  local exactCapacities = metadata.cargoCapacityByVehicleCid or {}
  local exactCapacity = count(exactCapacities[action.vehicleCid])
  if exactCapacities[action.vehicleCid] == nil then
    exactCapacity = count(metadata.cargoCapacityPerVehicle)
  end
  local record = existing or {
    vehicleCid = action.vehicleCid, lineCid = action.lineCid,
    companyCid = owner or service.companyCid, capacity = exactCapacity,
    aboard = 0, lastRound = 0, boardedTotal = 0, deliveredTotal = 0,
    earnedRevenueCents = 0, discardedTotal = 0,
  }
  record.lineCid = action.lineCid
  record.companyCid = record.companyCid or owner or service.companyCid
  record.capacity = math.max(count(record.aboard), exactCapacity)
  state.vehicles[action.vehicleCid] = record
  return record
end

function M.alignWithVehicleSync(value, economyState, vehicleSync)
  local state = M.migrate(value)
  local begun, beginError = M.beginEpoch(state, economyState)
  if not begun then return false, beginError end
  for _, vehicleCid in ipairs(util.sortedKeys(vehicleSync and vehicleSync.vehicles or {})) do
    local sync = vehicleSync.vehicles[vehicleCid]
    local service, _, _, metadata = cargoService(economyState, sync.lineCid)
    local line = service and ensureLine(state, economyState, sync.lineCid, false) or nil
    if line == false then return false, "cargo presentation route alignment failed" end
    if line then
      local record = vehicleRecord(state, service, metadata, {
        vehicleCid = vehicleCid, lineCid = sync.lineCid,
      }, sync.companyCid)
      local authorized = count(sync.lastAuthorizedRound)
      if record.lastRound > authorized then
        return false, "cargo presentation is ahead of vehicle synchronization"
      end
      if record.lastRound < authorized then
        local pristine = record.lastRound == 0 and record.aboard == 0
          and record.boardedTotal == 0 and record.deliveredTotal == 0
        if not pristine then return false, "cargo presentation lags vehicle synchronization" end
        record.lastRound = authorized
        record.lastStopIndex = sync.stopIndex
        record.lastStationGroupCid = metadata.stationGroupCids
          and metadata.stationGroupCids[util.integer(sync.stopIndex, -1) + 1] or nil
      end
    elseif state.vehicles[vehicleCid] then
      retireVehicle(state, vehicleCid)
    end
  end
  return true, state
end

-- ScriptSave is an authority boundary, not a trusted cache.  Re-check the
-- cross-ledger invariants after migration so an interrupted/edited save cannot
-- resume with cargo duplicated between a station, vehicle, and industry.
function M.validateState(value, economyState, freightState, vehicleSync)
  return validation.validate(value, economyState, freightState, vehicleSync, {
    schemaVersion = M.SCHEMA_VERSION, maxCount = M.MAX_COUNT,
    maxCents = M.MAX_CENTS, count = count, add = add,
    cargoService = cargoService,
  })
end

local function unsettledReservations(state, freightState, sourceCid, cargoType)
  local total = 0
  local cursors = freightState and freightState.transportCursors or {}
  for lineCid, line in pairs(state.lines) do
    if line.sourceIndustryCid == sourceCid and line.cargoType == cargoType then
      local cursor = cursors[lineCid] or {}
      total = add(total, math.max(0,
        count(line.boardedTotal) - count(cursor.boardedUnits)))
    end
  end
  return total
end

local function availableOutput(state, freightState, line)
  local industry = freightState and freightState.industries
    and freightState.industries[line.sourceIndustryCid] or nil
  local stock = industry and industry.outputStock or nil
  local available = count(stock and stock[line.cargoType])
  return math.max(0, available - unsettledReservations(
    state, freightState, line.sourceIndustryCid, line.cargoType))
end

function M.applyRelease(value, economyState, freightState, action, bindingMetadata)
  local state = M.migrate(value)
  if type(action) ~= "table" or type(action.vehicleCid) ~= "string"
    or type(action.lineCid) ~= "string" then
    return false, "cargo presentation release identity is invalid"
  end
  local begun, beginError = M.beginEpoch(state, economyState)
  if not begun then return false, beginError end
  local line, lineError = ensureLine(state, economyState, action.lineCid, false)
  if line == false then return false, lineError end
  if not line then return true, { cargo = false, reason = "non-cargo-service" } end
  local service, _, stops, metadata = cargoService(economyState, action.lineCid)
  local stopIndex, round = util.integer(action.stopIndex, -1), util.integer(action.round, 0)
  if not service or stopIndex < 0 or stopIndex >= #stops or round < 1 then
    return false, "cargo presentation release stop/round is invalid"
  end
  local vehicle = vehicleRecord(
    state, service, metadata, action, bindingMetadata and bindingMetadata.owner)
  if round < vehicle.lastRound then return false, "cargo vehicle round moved backwards" end
  if round == vehicle.lastRound then
    if vehicle.lastStopIndex ~= stopIndex then
      return false, "cargo duplicate round changed stop"
    end
    return true, { cargo = true, duplicate = true, vehicle = util.deepCopy(vehicle) }
  end
  if round ~= vehicle.lastRound + 1 then
    return false, "cargo vehicle round is not sequential"
  end

  local delivered = 0
  if stopIndex == line.destinationStopIndex and vehicle.aboard > 0 then
    delivered = vehicle.aboard
    local earned = revenue.modelDeliveryCents(
      { kind = "cargo" }, {
        fareCents = vehicle.boardedFareCents or service.fareCents,
        metadata = { distanceMeters = vehicle.boardedDistanceMeters
          or metadata.distanceMeters },
      }, delivered)
    vehicle.aboard = 0
    vehicle.deliveredTotal = add(vehicle.deliveredTotal, delivered)
    vehicle.earnedRevenueCents = addCents(vehicle.earnedRevenueCents, earned)
    vehicle.boardedFareCents, vehicle.boardedDistanceMeters = nil, nil
    line.deliveredTotal = add(line.deliveredTotal, delivered)
    line.earnedRevenueCents = addCents(line.earnedRevenueCents, earned)
  end

  local boarded = 0
  if stopIndex == line.sourceStopIndex then
    local quota = math.max(0, count(line.allocated) - count(line.boardedThisEpoch))
    local free = math.max(0, count(vehicle.capacity) - count(vehicle.aboard))
    boarded = math.min(quota, free, availableOutput(state, freightState, line))
    if boarded > 0 then
      vehicle.aboard = add(vehicle.aboard, boarded)
      vehicle.boardedTotal = add(vehicle.boardedTotal, boarded)
      vehicle.boardedFareCents = service.fareCents
      vehicle.boardedDistanceMeters = metadata.distanceMeters
      vehicle.boardedEpoch = state.epoch
      line.boardedTotal = add(line.boardedTotal, boarded)
      line.boardedThisEpoch = add(line.boardedThisEpoch, boarded)
    end
  end

  vehicle.lastRound = round
  vehicle.lastStopIndex = stopIndex
  vehicle.lastStationGroupCid = stops[stopIndex + 1]
  return true, {
    cargo = true, cargoType = line.cargoType,
    boarded = boarded, delivered = delivered,
    aboard = vehicle.aboard, capacity = vehicle.capacity,
    availableAtSource = availableOutput(state, freightState, line),
    earnedRevenueCents = line.earnedRevenueCents,
  }
end

function M.onOperation(value, economyState, transaction, companyCid)
  local state = M.migrate(value)
  if type(transaction) ~= "table" or type(transaction.data) ~= "table" then
    return true, state
  end
  local data = transaction.data
  if transaction.kind == "vehicle.assign" then
    local vehicle = state.vehicles[data.targetCid]
    if vehicle and vehicle.lineCid ~= data.lineCid then
      retireVehicle(state, data.targetCid)
    end
  elseif transaction.kind == "vehicle.sell" then
    retireVehicle(state, data.targetCid)
  elseif transaction.kind == "vehicle.sell_batch" then
    for _, targetCid in ipairs(data.targetCids or {}) do retireVehicle(state, targetCid) end
  elseif transaction.kind == "line.delete" then
    local line = state.lines[data.targetCid]
    if line then line.retired = true end
    for _, vehicleCid in ipairs(util.sortedKeys(state.vehicles)) do
      local vehicle = state.vehicles[vehicleCid]
      if vehicle.lineCid == data.targetCid then
        retireVehicle(state, vehicleCid)
      end
    end
  end
  return true, state
end

local function optional(record, key, value)
  if value ~= nil then record[key] = value end
end

function M.digestView(value)
  local state = M.migrate(value)
  local lines = {}
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
  return { schemaVersion = M.SCHEMA_VERSION, epoch = state.epoch,
    lines = lines, vehicles = vehicles }
end

function M.economySnapshot(value)
  local state = M.migrate(value)
  local lines = {}
  for _, lineCid in ipairs(util.sortedKeys(state.lines)) do
    local line = state.lines[lineCid]
    lines[lineCid] = {
      contractDigest = line.contractDigest,
      sourceIndustryCid = line.sourceIndustryCid,
      destinationIndustryCid = line.destinationIndustryCid,
      destinationStockIndex = util.integer(line.destinationStockIndex, 0),
      cargoType = line.cargoType,
      boardedUnits = count(line.boardedTotal),
      deliveredUnits = count(line.deliveredTotal),
      earnedRevenueCents = cents(line.earnedRevenueCents),
    }
  end
  return { schemaVersion = M.SCHEMA_VERSION, presentationEpoch = state.epoch, lines = lines }
end

local function nameOf(registry, cid, fallback)
  local binding = registry and registry.byCanonical and registry.byCanonical[cid] or nil
  return binding and binding.metadata and binding.metadata.name or fallback or cid,
    binding and tonumber(binding.localId) or nil
end

function M.publicView(value, economyState, freightState, registry)
  local state = M.migrate(value)
  local result = { schemaVersion = M.SCHEMA_VERSION, epoch = state.epoch,
    lines = {}, stations = {}, vehicles = {}, localVehicles = {}, localStations = {},
    totals = { waiting = 0, aboard = 0, capacity = 0, boarded = 0,
      delivered = 0, discarded = 0, earnedRevenueCents = 0 } }
  for _, lineCid in ipairs(util.sortedKeys(state.lines)) do
    local item = util.deepCopy(state.lines[lineCid])
    local service = economyState and economyState.services and economyState.services[lineCid] or {}
    item.name, item.localId = nameOf(registry, lineCid, service.name)
    item.sourceIndustryName = nameOf(registry,
      item.sourceIndustryCid, item.sourceIndustryCid)
    item.destinationIndustryName = nameOf(registry,
      item.destinationIndustryCid, item.destinationIndustryCid)
    item.availableAtSource = availableOutput(state, freightState, item)
    item.waiting = math.min(item.availableAtSource,
      math.max(0, count(item.allocated) - count(item.boardedThisEpoch)))
    result.lines[lineCid] = item
    result.totals.waiting = add(result.totals.waiting, item.waiting)
    result.totals.boarded = add(result.totals.boarded, item.boardedTotal)
    result.totals.delivered = add(result.totals.delivered, item.deliveredTotal)
    result.totals.discarded = add(result.totals.discarded, item.discardedTotal)
    result.totals.earnedRevenueCents = addCents(
      result.totals.earnedRevenueCents, item.earnedRevenueCents)
    local stationName, localStationId = nameOf(
      registry, item.sourceStationGroupCid, item.sourceStationGroupCid)
    local station = result.stations[item.sourceStationGroupCid] or {
      stationGroupCid = item.sourceStationGroupCid, name = stationName,
      localId = localStationId, waiting = 0, delivered = 0, lines = {},
    }
    station.waiting = add(station.waiting, item.waiting)
    station.lines[#station.lines + 1] = {
      lineCid = lineCid, name = item.name, companyCid = item.companyCid,
      cargoType = item.cargoType, waiting = item.waiting, delivered = 0,
      role = "source",
    }
    result.stations[item.sourceStationGroupCid] = station
    if localStationId then result.localStations[tostring(localStationId)] = item.sourceStationGroupCid end

    local destinationName, localDestinationId = nameOf(
      registry, item.destinationStationGroupCid, item.destinationStationGroupCid)
    local destination = result.stations[item.destinationStationGroupCid] or {
      stationGroupCid = item.destinationStationGroupCid, name = destinationName,
      localId = localDestinationId, waiting = 0, delivered = 0, lines = {},
    }
    destination.delivered = add(destination.delivered, item.deliveredTotal)
    destination.lines[#destination.lines + 1] = {
      lineCid = lineCid, name = item.name, companyCid = item.companyCid,
      cargoType = item.cargoType, waiting = 0,
      delivered = item.deliveredTotal, role = "destination",
    }
    result.stations[item.destinationStationGroupCid] = destination
    if localDestinationId then
      result.localStations[tostring(localDestinationId)] = item.destinationStationGroupCid
    end
  end
  for _, vehicleCid in ipairs(util.sortedKeys(state.vehicles)) do
    local item = util.deepCopy(state.vehicles[vehicleCid])
    item.name, item.localId = nameOf(registry, vehicleCid, vehicleCid)
    local line = state.lines[item.lineCid]
    item.cargoType = line and line.cargoType or nil
    item.lineName = result.lines[item.lineCid] and result.lines[item.lineCid].name or item.lineCid
    result.vehicles[vehicleCid] = item
    if item.localId then result.localVehicles[tostring(item.localId)] = vehicleCid end
    result.totals.aboard = add(result.totals.aboard, item.aboard)
    result.totals.capacity = add(result.totals.capacity, item.capacity)
  end
  return result
end

return M
