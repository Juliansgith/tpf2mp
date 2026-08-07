local util = require "tpf2_mp/util"
local hash = require "tpf2_mp/hash"

local M = {}

M.SCHEMA_VERSION = 1
M.EPOCH_SECONDS = 3600
M.MAX_COUNT = 1000000000
M.FALLBACK_SEATS = 100

local function count(value)
  return math.min(M.MAX_COUNT, math.max(0, util.integer(value, 0)))
end

local function add(left, right)
  return math.min(M.MAX_COUNT, count(left) + count(right))
end

local function array(value)
  return type(value) == "table" and value or {}
end

local function passengerService(economyState, lineCid)
  local service = economyState and economyState.services
    and economyState.services[lineCid] or nil
  if not service then return nil end
  local market = economyState.markets and economyState.markets[service.marketCid] or nil
  if market and market.kind ~= nil and market.kind ~= "passenger" then return nil end
  local stops = service.metadata and service.metadata.stationGroupCids or nil
  if type(stops) ~= "table" or #stops < 2
    or type(stops[1]) ~= "string" or type(stops[#stops]) ~= "string"
    or stops[1] == stops[#stops] then return nil end
  return service, market, stops
end

local function resultAllocation(economyState, service)
  local market = economyState and economyState.lastResults
    and economyState.lastResults.markets
    and economyState.lastResults.markets[service.marketCid] or nil
  local row = market and market.services and market.services[service.lineCid] or nil
  return count(row and row.allocated or 0)
end

local function departuresFor(service)
  local headway = math.max(30, util.integer(service and service.headwaySeconds, M.EPOCH_SECONDS))
  return math.max(1, math.floor(M.EPOCH_SECONDS / math.min(M.EPOCH_SECONDS, headway)))
end

local function seatsFor(service)
  local metadata = service and service.metadata or {}
  local direct = count(metadata.seatsPerVehicle)
  if direct > 0 then return direct end
  local vehicles = count(metadata.vehicleCount)
  local departures = departuresFor(service)
  local capacity = count(service and service.capacity)
  if vehicles > 0 and capacity > 0 then
    local derived = math.floor(capacity / (vehicles * departures))
    if derived > 0 then return derived end
  end
  return M.FALLBACK_SEATS
end

local function splitAllocation(allocated, epoch)
  local first = math.floor(allocated / 2)
  local second = allocated - first
  -- Alternate the indivisible passenger so neither terminal receives a
  -- permanent one-person advantage across successive settlements.
  if allocated % 2 == 1 and util.integer(epoch, 0) % 2 == 0 then
    first, second = second, first
  end
  return first, second
end

function M.newState()
  return {
    schemaVersion = M.SCHEMA_VERSION,
    epoch = 0,
    lines = {},
    vehicles = {},
  }
end

function M.migrate(value)
  if type(value) ~= "table" then return M.newState() end
  value.schemaVersion = M.SCHEMA_VERSION
  value.epoch = math.max(0, util.integer(value.epoch, 0))
  value.lines = type(value.lines) == "table" and value.lines or {}
  value.vehicles = type(value.vehicles) == "table" and value.vehicles or {}
  return value
end

local function routeRecord(service, stops, allocated, epoch, previous, carryQueues)
  local first, second = splitAllocation(allocated, epoch)
  local sameRoute = previous and previous.routeDigest == hash.value(stops)
  local carryA = carryQueues and sameRoute and count(previous.waitingAToB) or 0
  local carryB = carryQueues and sameRoute and count(previous.waitingBToA) or 0
  return {
    lineCid = service.lineCid,
    companyCid = service.companyCid,
    marketCid = service.marketCid,
    epoch = epoch,
    terminalA = stops[1],
    terminalB = stops[#stops],
    stops = util.deepCopy(stops),
    stopCount = #stops,
    routeDigest = hash.value(stops),
    allocated = allocated,
    waitingAToB = add(carryA, first),
    waitingBToA = add(carryB, second),
    departuresPlanned = departuresFor(service),
    departuresAToB = 0,
    departuresBToA = 0,
    seatsPerVehicle = seatsFor(service),
    boardedTotal = 0,
    alightedTotal = 0,
    overflowTotal = sameRoute and count(previous and previous.overflowTotal) or 0,
  }
end

local function ensureLine(state, economyState, lineCid, carryQueues)
  local service, _, stops = passengerService(economyState, lineCid)
  if not service then
    state.lines[lineCid] = nil
    return nil
  end
  local epoch = math.max(0, util.integer(economyState.epoch, 0))
  local allocated = resultAllocation(economyState, service)
  local previous = state.lines[lineCid]
  local routeDigest = hash.value(stops)
  if previous and previous.epoch == epoch and previous.routeDigest == routeDigest then
    previous.companyCid = service.companyCid
    previous.marketCid = service.marketCid
    previous.stopCount = #stops
    previous.stops = util.deepCopy(stops)
    previous.departuresPlanned = departuresFor(service)
    previous.seatsPerVehicle = seatsFor(service)
    previous.allocated = allocated
    return previous
  end
  local record = routeRecord(service, stops, allocated, epoch, previous, carryQueues == true)
  state.lines[lineCid] = record
  if previous and previous.routeDigest ~= record.routeDigest then
    -- A route edit invalidates any presentation-only trip that referred to
    -- the old endpoints. Count it explicitly instead of silently moving it.
    record.overflowTotal = add(record.overflowTotal,
      add(previous.waitingAToB, previous.waitingBToA))
    for _, vehicle in pairs(state.vehicles) do
      if vehicle.lineCid == lineCid then
        vehicle.discardedTotal = add(vehicle.discardedTotal, vehicle.aboard)
        vehicle.aboard = 0
        vehicle.originStationGroupCid = nil
        vehicle.destinationStationGroupCid = nil
      end
    end
  end
  return record
end

-- Advances presentation demand exactly once per authored economy epoch. Old
-- queues carry over as a visible backlog; onboard passengers keep riding to
-- their destination, so a settlement never teleports a train empty.
function M.beginEpoch(value, economyState)
  local state = M.migrate(value)
  local epoch = math.max(0, util.integer(economyState and economyState.epoch, 0))
  if epoch == state.epoch then
    for _, lineCid in ipairs(util.sortedKeys(economyState and economyState.services or {})) do
      ensureLine(state, economyState, lineCid, false)
    end
    return true, state
  end
  if epoch < state.epoch then return false, "passenger presentation epoch moved backwards" end
  local retained = {}
  for _, lineCid in ipairs(util.sortedKeys(economyState and economyState.services or {})) do
    if passengerService(economyState, lineCid) then
      retained[lineCid] = true
      ensureLine(state, economyState, lineCid, true)
    end
  end
  for lineCid in pairs(state.lines) do
    if not retained[lineCid] then state.lines[lineCid] = nil end
  end
  state.epoch = epoch
  return true, state
end

function M.reconcileService(value, economyState, lineCid)
  local state = M.migrate(value)
  if math.max(0, util.integer(economyState and economyState.epoch, 0)) ~= state.epoch then
    local ok, err = M.beginEpoch(state, economyState)
    if not ok then return false, err end
  end
  ensureLine(state, economyState, lineCid, false)
  return true, state.lines[lineCid]
end

local function vehicleRecord(state, economyState, action, metadata)
  local line = assert(state.lines[action.lineCid])
  local existing = state.vehicles[action.vehicleCid]
  local discardedFromPriorLine = 0
  if existing and existing.lineCid ~= action.lineCid then
    discardedFromPriorLine = add(existing.discardedTotal, existing.aboard)
    existing = nil
  end
  local service = economyState.services[action.lineCid]
  local record = existing or {
    vehicleCid = action.vehicleCid,
    lineCid = action.lineCid,
    companyCid = metadata and metadata.owner or service.companyCid,
    capacity = line.seatsPerVehicle,
    aboard = 0,
    lastRound = 0,
    boardedTotal = 0,
    alightedTotal = 0,
    discardedTotal = discardedFromPriorLine,
  }
  record.lineCid = action.lineCid
  record.companyCid = record.companyCid or service.companyCid
  record.capacity = math.max(count(record.aboard), line.seatsPerVehicle)
  state.vehicles[action.vehicleCid] = record
  return record
end

-- A schema-24 game can load a schema-23 save whose vehicle rendezvous already
-- completed several rounds but which predates the passenger ledger. Seed only
-- the missing round cursor; never invent historical riders or replay boarding.
-- The same alignment makes a duplicate release retry safe immediately after
-- migration. Once a ledger has real movement, any mismatch remains an error.
function M.alignWithVehicleSync(value, economyState, vehicleSync)
  local state = M.migrate(value)
  local begun, beginError = M.beginEpoch(state, economyState)
  if not begun then return false, beginError end
  for _, vehicleCid in ipairs(util.sortedKeys(vehicleSync and vehicleSync.vehicles or {})) do
    local sync = vehicleSync.vehicles[vehicleCid]
    local lineCid = type(sync) == "table" and sync.lineCid or nil
    local line = type(lineCid) == "string"
      and ensureLine(state, economyState, lineCid, false) or nil
    if line then
      local record = vehicleRecord(state, economyState, {
        vehicleCid = vehicleCid,
        lineCid = lineCid,
      }, { owner = sync.companyCid })
      local authorized = math.max(0, util.integer(sync.lastAuthorizedRound, 0))
      if record.lastRound > authorized then
        return false, "passenger presentation is ahead of vehicle synchronization"
      end
      if record.lastRound < authorized then
        local pristine = record.lastRound == 0 and count(record.aboard) == 0
          and count(record.boardedTotal) == 0 and count(record.alightedTotal) == 0
        if not pristine then
          return false, "passenger presentation lags vehicle synchronization"
        end
        record.lastRound = authorized
        local stopIndex = util.integer(sync.stopIndex, -1)
        local _, _, stops = passengerService(economyState, lineCid)
        if stops and stopIndex >= 0 and stopIndex < #stops then
          record.lastStopIndex = stopIndex
          record.lastStationGroupCid = stops[stopIndex + 1]
        end
      end
    elseif state.vehicles[vehicleCid] then
      state.vehicles[vehicleCid] = nil
    end
  end
  return true, state
end

local function boardingAmount(waiting, departuresUsed, departuresPlanned, freeSeats)
  if waiting <= 0 or freeSeats <= 0 then return 0 end
  local remainingDepartures = math.max(1, departuresPlanned - departuresUsed)
  local desired = math.floor((waiting + remainingDepartures - 1) / remainingDepartures)
  return math.min(waiting, freeSeats, math.max(1, desired))
end

-- Runs inside the already ordered vehicle.sync_release action. No new intent,
-- barrier, clock sample, or local entity id enters the protocol.
function M.applyRelease(value, economyState, action, bindingMetadata)
  local state = M.migrate(value)
  if type(action) ~= "table" or type(action.vehicleCid) ~= "string"
    or type(action.lineCid) ~= "string" then
    return false, "passenger presentation release identity is invalid"
  end
  local begun, beginError = M.beginEpoch(state, economyState)
  if not begun then return false, beginError end
  local line = ensureLine(state, economyState, action.lineCid, false)
  if not line then return true, { passenger = false, reason = "non-passenger-service" } end
  local service, _, stops = passengerService(economyState, action.lineCid)
  local stopIndex = util.integer(action.stopIndex, -1)
  local round = util.integer(action.round, 0)
  if not service or stopIndex < 0 or stopIndex >= #stops or round < 1 then
    return false, "passenger presentation release stop/round is invalid"
  end
  local vehicle = vehicleRecord(state, economyState, action, bindingMetadata)
  if round < vehicle.lastRound then
    return false, "passenger presentation vehicle round moved backwards"
  end
  if round == vehicle.lastRound then
    if vehicle.lastStopIndex ~= stopIndex then
      return false, "passenger presentation duplicate round changed stop"
    end
    return true, { passenger = true, duplicate = true, vehicle = util.deepCopy(vehicle) }
  end
  if round ~= vehicle.lastRound + 1 then
    return false, "passenger presentation vehicle round is not sequential"
  end

  local stopCid = stops[stopIndex + 1]
  local alighted = 0
  if vehicle.destinationStationGroupCid == stopCid and vehicle.aboard > 0 then
    alighted = vehicle.aboard
    vehicle.aboard = 0
    vehicle.originStationGroupCid = nil
    vehicle.destinationStationGroupCid = nil
    vehicle.alightedTotal = add(vehicle.alightedTotal, alighted)
    line.alightedTotal = add(line.alightedTotal, alighted)
  end

  local direction, destination, departuresField, waitingField
  if stopIndex == 0 then
    direction, destination = "a-to-b", line.terminalB
    departuresField, waitingField = "departuresAToB", "waitingAToB"
  elseif stopIndex == line.stopCount - 1 then
    direction, destination = "b-to-a", line.terminalA
    departuresField, waitingField = "departuresBToA", "waitingBToA"
  end

  local boarded = 0
  if direction then
    local used = count(line[departuresField])
    local waiting = count(line[waitingField])
    boarded = boardingAmount(waiting, used, line.departuresPlanned,
      math.max(0, vehicle.capacity - vehicle.aboard))
    line[departuresField] = add(used, 1)
    line[waitingField] = waiting - boarded
    if boarded > 0 then
      vehicle.aboard = add(vehicle.aboard, boarded)
      vehicle.originStationGroupCid = stopCid
      vehicle.destinationStationGroupCid = destination
      vehicle.boardedEpoch = state.epoch
      vehicle.boardedTotal = add(vehicle.boardedTotal, boarded)
      line.boardedTotal = add(line.boardedTotal, boarded)
    end
  end

  vehicle.lastRound = round
  vehicle.lastStopIndex = stopIndex
  vehicle.lastStationGroupCid = stopCid
  return true, {
    passenger = true,
    direction = direction,
    boarded = boarded,
    alighted = alighted,
    aboard = vehicle.aboard,
    capacity = vehicle.capacity,
    waitingAToB = line.waitingAToB,
    waitingBToA = line.waitingBToA,
  }
end

function M.onOperation(value, economyState, transaction, companyCid)
  local state = M.migrate(value)
  if type(transaction) ~= "table" or type(transaction.data) ~= "table" then
    return true, state
  end
  local data = transaction.data
  if transaction.kind == "vehicle.assign" then
    local prior = state.vehicles[data.targetCid]
    if prior and prior.lineCid ~= data.lineCid then
      prior.discardedTotal = add(prior.discardedTotal, prior.aboard)
      prior.aboard = 0
      prior.originStationGroupCid = nil
      prior.destinationStationGroupCid = nil
    end
    local line = ensureLine(state, economyState, data.lineCid, false)
    if not line then
      state.vehicles[data.targetCid] = nil
      return true, state
    end
    state.vehicles[data.targetCid] = prior or {
      vehicleCid = data.targetCid,
      lineCid = data.lineCid,
      companyCid = companyCid,
      capacity = line.seatsPerVehicle,
      aboard = 0,
      lastRound = 0,
      boardedTotal = 0,
      alightedTotal = 0,
      discardedTotal = 0,
    }
    state.vehicles[data.targetCid].lineCid = data.lineCid
    state.vehicles[data.targetCid].companyCid = companyCid
  elseif transaction.kind == "vehicle.sell" then
    state.vehicles[data.targetCid] = nil
  elseif transaction.kind == "line.delete" then
    state.lines[data.targetCid] = nil
    for vehicleCid, vehicle in pairs(state.vehicles) do
      if vehicle.lineCid == data.targetCid then state.vehicles[vehicleCid] = nil end
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
      lineCid = lineCid,
      companyCid = item.companyCid,
      marketCid = item.marketCid,
      epoch = math.max(0, util.integer(item.epoch, 0)),
      terminalA = item.terminalA,
      terminalB = item.terminalB,
      stops = util.deepCopy(item.stops or { item.terminalA, item.terminalB }),
      stopCount = math.max(2, util.integer(item.stopCount, 2)),
      routeDigest = tostring(item.routeDigest or ""),
      allocated = count(item.allocated),
      waitingAToB = count(item.waitingAToB),
      waitingBToA = count(item.waitingBToA),
      departuresPlanned = math.max(1, util.integer(item.departuresPlanned, 1)),
      departuresAToB = count(item.departuresAToB),
      departuresBToA = count(item.departuresBToA),
      seatsPerVehicle = math.max(1, count(item.seatsPerVehicle)),
      boardedTotal = count(item.boardedTotal),
      alightedTotal = count(item.alightedTotal),
      overflowTotal = count(item.overflowTotal),
    }
  end
  local vehicles = {}
  for _, vehicleCid in ipairs(util.sortedKeys(state.vehicles)) do
    local item = state.vehicles[vehicleCid]
    local record = {
      vehicleCid = vehicleCid,
      lineCid = item.lineCid,
      companyCid = item.companyCid,
      capacity = math.max(1, count(item.capacity)),
      aboard = count(item.aboard),
      lastRound = math.max(0, util.integer(item.lastRound, 0)),
      boardedTotal = count(item.boardedTotal),
      alightedTotal = count(item.alightedTotal),
      discardedTotal = count(item.discardedTotal),
    }
    optional(record, "boardedEpoch", item.boardedEpoch and math.max(0, util.integer(item.boardedEpoch, 0)))
    optional(record, "lastStopIndex", item.lastStopIndex and math.max(0, util.integer(item.lastStopIndex, 0)))
    optional(record, "lastStationGroupCid", item.lastStationGroupCid)
    optional(record, "originStationGroupCid", item.originStationGroupCid)
    optional(record, "destinationStationGroupCid", item.destinationStationGroupCid)
    vehicles[#vehicles + 1] = record
  end
  return {
    schemaVersion = M.SCHEMA_VERSION,
    epoch = state.epoch,
    lines = lines,
    vehicles = vehicles,
  }
end

local function nameOf(registry, cid, fallback)
  local binding = registry and registry.byCanonical and registry.byCanonical[cid] or nil
  return binding and binding.metadata and binding.metadata.name or fallback or cid,
    binding and tonumber(binding.localId) or nil
end

-- Machine-local names and ids are added only here. The authored state and its
-- checkpoint projection remain canonical and pointer-free.
function M.publicView(value, economyState, registry)
  local state = M.migrate(value)
  local result = {
    schemaVersion = M.SCHEMA_VERSION,
    epoch = state.epoch,
    lines = {}, stations = {}, vehicles = {},
    localVehicles = {}, localStations = {}, localLines = {},
    totals = { waiting = 0, aboard = 0, capacity = 0, boarded = 0, alighted = 0 },
  }
  for _, lineCid in ipairs(util.sortedKeys(state.lines)) do
    local item = state.lines[lineCid]
    local service = economyState and economyState.services and economyState.services[lineCid] or {}
    local lineName, localLineId = nameOf(registry, lineCid, service.name)
    local line = util.deepCopy(item)
    line.name, line.localId = lineName, localLineId
    line.waiting = add(line.waitingAToB, line.waitingBToA)
    result.lines[lineCid] = line
    if localLineId then result.localLines[tostring(localLineId)] = lineCid end
    result.totals.waiting = add(result.totals.waiting, line.waiting)
    result.totals.boarded = add(result.totals.boarded, line.boardedTotal)
    result.totals.alighted = add(result.totals.alighted, line.alightedTotal)
    local firstThroughput, secondThroughput = splitAllocation(line.allocated, line.epoch)
    local routeStops = line.stops or { line.terminalA, line.terminalB }
    local seenStops = {}
    for _, stopCid in ipairs(routeStops) do
      if not seenStops[stopCid] then
        seenStops[stopCid] = true
        local terminal = { cid = stopCid, waiting = 0, throughput = 0 }
        if stopCid == line.terminalA then
          terminal.waiting, terminal.throughput = line.waitingAToB, firstThroughput
        elseif stopCid == line.terminalB then
          terminal.waiting, terminal.throughput = line.waitingBToA, secondThroughput
        end
      local stationName, localStationId = nameOf(registry, terminal.cid)
      local station = result.stations[terminal.cid] or {
        stationGroupCid = terminal.cid,
        name = stationName,
        localId = localStationId,
        waiting = 0,
        throughput = 0,
        lines = {},
      }
      station.waiting = add(station.waiting, terminal.waiting)
      station.throughput = add(station.throughput, terminal.throughput)
      station.lines[#station.lines + 1] = {
        lineCid = lineCid,
        name = lineName,
        companyCid = line.companyCid,
        allocated = terminal.throughput,
        lineAllocated = line.allocated,
        waiting = terminal.waiting,
      }
      result.stations[terminal.cid] = station
      if localStationId then result.localStations[tostring(localStationId)] = terminal.cid end
      end
    end
  end
  for _, vehicleCid in ipairs(util.sortedKeys(state.vehicles)) do
    local item = util.deepCopy(state.vehicles[vehicleCid])
    local vehicleName, localVehicleId = nameOf(registry, vehicleCid, vehicleCid)
    item.name, item.localId = vehicleName, localVehicleId
    item.lineName = result.lines[item.lineCid] and result.lines[item.lineCid].name or item.lineCid
    item.originName = item.originStationGroupCid
      and (nameOf(registry, item.originStationGroupCid)) or nil
    item.destinationName = item.destinationStationGroupCid
      and (nameOf(registry, item.destinationStationGroupCid)) or nil
    result.vehicles[vehicleCid] = item
    if localVehicleId then result.localVehicles[tostring(localVehicleId)] = vehicleCid end
    result.totals.aboard = add(result.totals.aboard, item.aboard)
    result.totals.capacity = add(result.totals.capacity, item.capacity)
  end
  return result
end

return M
