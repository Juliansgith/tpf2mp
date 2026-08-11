local util = require "tpf2_mp/util"
local hash = require "tpf2_mp/hash"
local revenue = require "tpf2_mp/economy_revenue"

local M = {}

M.SCHEMA_VERSION = 4
M.EPOCH_SECONDS = 300
M.MAX_COUNT = 1000000000
M.MAX_CENTS = revenue.ACCUMULATOR_LIMIT
M.FALLBACK_SEATS = 100
M.TIME_SCALE = 1000
M.MAX_TIME_MILLISECONDS = 9000000000000000

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

local function array(value)
  return type(value) == "table" and value or {}
end

local function passengerService(economyState, lineCid)
  local service = economyState and economyState.services
    and economyState.services[lineCid] or nil
  if not service or service.enabled == false then return nil end
  local market = economyState.markets and economyState.markets[service.marketCid] or nil
  if market and market.kind ~= nil and market.kind ~= "passenger" then return nil end
  local stops = service.metadata and service.metadata.stationGroupCids or nil
  if type(stops) ~= "table" or #stops < 2
    or type(stops[1]) ~= "string" or type(stops[#stops]) ~= "string"
    or stops[1] == stops[#stops] then return nil end
  return service, market, stops
end

local function resultDemand(economyState, service)
  local market = economyState and economyState.lastResults
    and economyState.lastResults.markets
    and economyState.lastResults.markets[service.marketCid] or nil
  local row = market and market.services and market.services[service.lineCid] or nil
  local allocated = count(row and row.allocated or 0)
  local requested = count(row and row.requested or allocated)
  local capacityOverflow = count(row and row.capacityOverflow
    or math.max(0, requested - allocated))
  local intervalSeconds = math.max(60, math.min(86400, util.integer(
    market and market.intervalSeconds
      or economyState and economyState.lastResults
        and economyState.lastResults.intervalSeconds
      or economyState and economyState.scheduler
        and economyState.scheduler.epochSeconds,
    M.EPOCH_SECONDS)))
  return allocated, requested, capacityOverflow, intervalSeconds
end

local function milliseconds(value)
  local numeric = tonumber(value)
  if not numeric or numeric ~= numeric or numeric < 0 then return nil end
  if numeric >= M.MAX_TIME_MILLISECONDS / M.TIME_SCALE then
    return M.MAX_TIME_MILLISECONDS
  end
  return math.floor(numeric * M.TIME_SCALE + 0.5)
end

local function boundaryMilliseconds(economyState)
  local results = economyState and economyState.lastResults or {}
  local scheduler = economyState and economyState.scheduler or {}
  return milliseconds(results.boundaryGameTimeSeconds
    or scheduler.lastBoundaryGameTimeSeconds
    or scheduler.startGameTimeSeconds
    or 0)
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
  local headway = math.max(30, util.integer(service and service.headwaySeconds, 3600))
  local departures = math.max(1, math.floor(3600 / math.min(3600, headway)))
  local capacity = count(service and service.capacity)
  if vehicles > 0 and capacity > 0 then
    local derived = math.floor(capacity / (2 * departures))
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

local function queueLimit(rate, intervalSeconds, seats, params)
  local maxWaitSeconds = math.max(60, math.min(86400,
    util.integer(params and params.maxWaitSeconds, 1800)))
  local numerator = count(rate) * maxWaitSeconds
  local demandLimit = math.floor((numerator + intervalSeconds - 1) / intervalSeconds)
  return math.min(M.MAX_COUNT, math.max(1, count(seats), demandLimit))
end

-- Exact fixed-point arrival integration without multiplying two unbounded
-- values. Full accounting intervals contribute whole riders; the remaining
-- milliseconds use a quotient/remainder decomposition whose largest product
-- stays below Lua's exact-integer range.
local function generatedDuring(rate, elapsedMilliseconds, intervalMilliseconds, residual)
  rate = count(rate)
  residual = math.max(0, util.integer(residual, 0)) % intervalMilliseconds
  if rate == 0 or elapsedMilliseconds <= 0 then return 0, residual end
  local fullIntervals = math.floor(elapsedMilliseconds / intervalMilliseconds)
  local partialMilliseconds = elapsedMilliseconds % intervalMilliseconds
  local fullGenerated
  if fullIntervals > math.floor(M.MAX_COUNT / rate) then fullGenerated = M.MAX_COUNT
  else fullGenerated = fullIntervals * rate end
  local ratePerMillisecond = math.floor(rate / intervalMilliseconds)
  local rateRemainder = rate % intervalMilliseconds
  local partialNumerator = partialMilliseconds * rateRemainder + residual
  local partialGenerated = partialMilliseconds * ratePerMillisecond
    + math.floor(partialNumerator / intervalMilliseconds)
  return math.min(M.MAX_COUNT, fullGenerated + partialGenerated),
    partialNumerator % intervalMilliseconds
end

local function accrueDirection(waiting, residual, rate, elapsedMilliseconds,
    intervalMilliseconds, seats, params)
  local generated, nextResidual = generatedDuring(
    rate, elapsedMilliseconds, intervalMilliseconds, residual)
  local limit = queueLimit(rate, math.floor(intervalMilliseconds / M.TIME_SCALE),
    seats, params)
  -- A falling demand rate must not make an existing queue disappear. The cap
  -- limits only new arrivals to one maximum-wait demand window; arrivals that
  -- do not fit deterministically abandon and are counted in overflowTotal.
  local room = math.max(0, math.max(count(waiting), limit) - count(waiting))
  local admitted = math.min(generated, room)
  return add(waiting, admitted), nextResidual, generated, generated - admitted
end

local function accrueLineTo(line, targetMilliseconds, params)
  targetMilliseconds = math.max(0, math.min(M.MAX_TIME_MILLISECONDS,
    util.integer(targetMilliseconds, 0)))
  local cursor = line.demandCursorMilliseconds
  if cursor == nil then
    line.demandCursorMilliseconds = targetMilliseconds
    return 0, 0, 0
  end
  cursor = math.max(0, math.min(M.MAX_TIME_MILLISECONDS, util.integer(cursor, 0)))
  if targetMilliseconds <= cursor then return 0, 0, 0 end
  local elapsed = targetMilliseconds - cursor
  local intervalMilliseconds = math.max(60, math.min(86400,
    util.integer(line.intervalSeconds, M.EPOCH_SECONDS))) * M.TIME_SCALE
  local rateA, rateB = splitAllocation(count(line.requested), line.epoch)
  local generatedA, generatedB, abandonedA, abandonedB
  line.waitingAToB, line.demandResidAToB, generatedA, abandonedA = accrueDirection(
    line.waitingAToB, line.demandResidAToB, rateA, elapsed,
    intervalMilliseconds, line.seatsPerVehicle, params)
  line.waitingBToA, line.demandResidBToA, generatedB, abandonedB = accrueDirection(
    line.waitingBToA, line.demandResidBToA, rateB, elapsed,
    intervalMilliseconds, line.seatsPerVehicle, params)
  line.generatedTotal = add(line.generatedTotal, add(generatedA, generatedB))
  line.overflowTotal = add(line.overflowTotal, add(abandonedA, abandonedB))
  line.demandCursorMilliseconds = targetMilliseconds
  return generatedA, generatedB, add(abandonedA, abandonedB)
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
  local previousSchema = math.max(1, util.integer(value.schemaVersion, 1))
  value.schemaVersion = M.SCHEMA_VERSION
  value.epoch = math.max(0, util.integer(value.epoch, 0))
  value.lines = type(value.lines) == "table" and value.lines or {}
  value.vehicles = type(value.vehicles) == "table" and value.vehicles or {}
  for _, line in pairs(value.lines) do
    line.allocated = count(line.allocated)
    line.requested = count(line.requested ~= nil and line.requested or line.allocated)
    line.capacityOverflow = count(line.capacityOverflow ~= nil
      and line.capacityOverflow or math.max(0, line.requested - line.allocated))
    line.intervalSeconds = math.max(60, math.min(86400,
      util.integer(line.intervalSeconds, M.EPOCH_SECONDS)))
    if line.demandCursorMilliseconds ~= nil then
      line.demandCursorMilliseconds = math.max(0, math.min(
        M.MAX_TIME_MILLISECONDS, util.integer(line.demandCursorMilliseconds, 0)))
    end
    local intervalMilliseconds = line.intervalSeconds * M.TIME_SCALE
    line.demandResidAToB = math.max(0,
      util.integer(line.demandResidAToB, 0)) % intervalMilliseconds
    line.demandResidBToA = math.max(0,
      util.integer(line.demandResidBToA, 0)) % intervalMilliseconds
    if line.generatedTotal == nil and previousSchema < 3 then
      line.generatedTotal = add(add(line.boardedTotal,
        add(line.waitingAToB, line.waitingBToA)), line.overflowTotal)
    end
    line.generatedTotal = count(line.generatedTotal)
    line.discardedTotal = count(line.discardedTotal)
    line.earnedRevenueCents = cents(line.earnedRevenueCents)
  end
  local aboardByLine = {}
  for _, vehicle in pairs(value.vehicles) do
    vehicle.aboard = count(vehicle.aboard)
    vehicle.boardedTotal = count(vehicle.boardedTotal)
    vehicle.alightedTotal = count(vehicle.alightedTotal)
    vehicle.discardedTotal = count(vehicle.discardedTotal)
    if previousSchema < 4 then
      -- Schema 3 carried a prior line's discarded count onto the fresh
      -- per-line record during reassignment. Schema 4 makes each vehicle
      -- sub-ledger line-local, so recover only the residue explained by this
      -- record's own boarded/alighted/aboard counters.
      vehicle.discardedTotal = math.max(0,
        vehicle.boardedTotal - vehicle.alightedTotal - vehicle.aboard)
    end
    vehicle.earnedRevenueCents = cents(vehicle.earnedRevenueCents)
    if vehicle.boardedFareCents ~= nil then
      vehicle.boardedFareCents = math.max(0, util.integer(vehicle.boardedFareCents, 0))
    end
    if type(vehicle.lineCid) == "string" then
      aboardByLine[vehicle.lineCid] = add(aboardByLine[vehicle.lineCid], vehicle.aboard)
    end
  end
  if previousSchema < 4 then
    -- Schema 1-3 removed sold vehicles without recording their onboard load.
    -- Recover that exact residue from the monotonic line counters so old
    -- saves begin schema 4 with a conserved ledger rather than silent riders.
    for lineCid, line in pairs(value.lines) do
      local residue = math.max(0, count(line.boardedTotal)
        - count(line.alightedTotal) - count(aboardByLine[lineCid]))
      line.discardedTotal = math.max(count(line.discardedTotal), residue)
    end
  end
  return value
end

local function routeRecord(service, stops, demand, epoch, previous, carryQueues,
    boundaryMillisecondsValue)
  local sameRoute = previous and previous.routeDigest == hash.value(stops)
  local carryA = carryQueues and sameRoute and count(previous.waitingAToB) or 0
  local carryB = carryQueues and sameRoute and count(previous.waitingBToA) or 0
  local sameInterval = sameRoute and previous.intervalSeconds == demand.intervalSeconds
  local cursor = previous and previous.demandCursorMilliseconds
    or boundaryMillisecondsValue
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
    allocated = demand.allocated,
    requested = demand.requested,
    capacityOverflow = demand.capacityOverflow,
    intervalSeconds = demand.intervalSeconds,
    waitingAToB = carryA,
    waitingBToA = carryB,
    demandCursorMilliseconds = cursor,
    demandResidAToB = carryQueues and sameInterval
      and math.max(0, util.integer(previous.demandResidAToB, 0)) or 0,
    demandResidBToA = carryQueues and sameInterval
      and math.max(0, util.integer(previous.demandResidBToA, 0)) or 0,
    departuresPlanned = departuresFor(service),
    departuresAToB = 0,
    departuresBToA = 0,
    seatsPerVehicle = seatsFor(service),
    -- These three fields are lifetime monotonic counters consumed by the
    -- settlement delivery cursor. A new accounting interval or route edit
    -- must never make the next snapshot move backwards.
    boardedTotal = count(previous and previous.boardedTotal),
    alightedTotal = count(previous and previous.alightedTotal),
    discardedTotal = count(previous and previous.discardedTotal),
    earnedRevenueCents = cents(previous and previous.earnedRevenueCents),
    overflowTotal = count(previous and previous.overflowTotal),
    generatedTotal = count(previous and previous.generatedTotal),
  }
end

local function retireVehicle(state, vehicleCid)
  local vehicle = state.vehicles[vehicleCid]
  if not vehicle then return end
  local line = state.lines[vehicle.lineCid]
  if line then line.discardedTotal = add(line.discardedTotal, vehicle.aboard) end
  state.vehicles[vehicleCid] = nil
end

local function retireLine(state, lineCid)
  for _, vehicleCid in ipairs(util.sortedKeys(state.vehicles)) do
    local vehicle = state.vehicles[vehicleCid]
    if vehicle.lineCid == lineCid then retireVehicle(state, vehicleCid) end
  end
  state.lines[lineCid] = nil
end

local function ensureLine(state, economyState, lineCid, carryQueues)
  local service, _, stops = passengerService(economyState, lineCid)
  if not service then
    retireLine(state, lineCid)
    return nil
  end
  local epoch = math.max(0, util.integer(economyState.epoch, 0))
  local allocated, requested, capacityOverflow, intervalSeconds =
    resultDemand(economyState, service)
  local demand = {
    allocated = allocated, requested = requested,
    capacityOverflow = capacityOverflow, intervalSeconds = intervalSeconds,
  }
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
    previous.requested = requested
    previous.capacityOverflow = capacityOverflow
    previous.intervalSeconds = intervalSeconds
    if previous.demandCursorMilliseconds == nil then
      previous.demandCursorMilliseconds = boundaryMilliseconds(economyState)
    end
    return previous
  end
  local boundary = boundaryMilliseconds(economyState)
  if previous and previous.routeDigest == routeDigest and previous.epoch ~= epoch then
    accrueLineTo(previous, boundary, economyState and economyState.params)
  end
  local record = routeRecord(service, stops, demand, epoch, previous,
    carryQueues == true, boundary)
  state.lines[lineCid] = record
  if previous and previous.routeDigest ~= record.routeDigest then
    -- A route edit invalidates any presentation-only trip that referred to
    -- the old endpoints. Count it explicitly instead of silently moving it.
    record.overflowTotal = add(record.overflowTotal,
      add(previous.waitingAToB, previous.waitingBToA))
    for _, vehicle in pairs(state.vehicles) do
      if vehicle.lineCid == lineCid then
        record.discardedTotal = add(record.discardedTotal, vehicle.aboard)
        vehicle.discardedTotal = add(vehicle.discardedTotal, vehicle.aboard)
        vehicle.aboard = 0
        vehicle.originStationGroupCid = nil
        vehicle.destinationStationGroupCid = nil
        vehicle.boardedFareCents = nil
      end
    end
  end
  return record
end

local function removeInactiveVehicles(state, economyState)
  for _, vehicleCid in ipairs(util.sortedKeys(state.vehicles)) do
    local vehicle = state.vehicles[vehicleCid]
    if not passengerService(economyState, vehicle.lineCid) then
      retireVehicle(state, vehicleCid)
    end
  end
end

-- Installs the authored arrival rate for an economy epoch. Exact arrivals are
-- accrued later against host-ordered departure times. Old queues carry over as
-- a visible backlog; onboard passengers keep riding to their destination, so
-- a settlement never teleports a train empty.
function M.beginEpoch(value, economyState)
  local state = M.migrate(value)
  local epoch = math.max(0, util.integer(economyState and economyState.epoch, 0))
  if epoch == state.epoch then
    for _, lineCid in ipairs(util.sortedKeys(economyState and economyState.services or {})) do
      ensureLine(state, economyState, lineCid, false)
    end
    removeInactiveVehicles(state, economyState)
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
    if not retained[lineCid] then retireLine(state, lineCid) end
  end
  removeInactiveVehicles(state, economyState)
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
  removeInactiveVehicles(state, economyState)
  return true, state.lines[lineCid]
end

local function vehicleRecord(state, economyState, action, metadata)
  local line = assert(state.lines[action.lineCid])
  local existing = state.vehicles[action.vehicleCid]
  if existing and existing.lineCid ~= action.lineCid then
    retireVehicle(state, action.vehicleCid)
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
    earnedRevenueCents = 0,
    discardedTotal = 0,
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

local function boardingAmount(waiting, freeSeats)
  return math.min(count(waiting), math.max(0, util.integer(freeSeats, 0)))
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
  local releaseMilliseconds = milliseconds(action.releaseAtGameTime)
  if not service or stopIndex < 0 or stopIndex >= #stops or round < 1
    or releaseMilliseconds == nil then
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

  -- Both terminal queues advance to the same host-ordered departure instant.
  -- This turns an interval rate into the 19/20-rider loads expected from a
  -- 20-seat train on a roughly 6.5-minute headway, instead of smoothing every
  -- five-minute allocation into an artificial 15 riders per departure.
  local generatedAToB, generatedBToA, abandoned = accrueLineTo(
    line, releaseMilliseconds, economyState and economyState.params)

  local stopCid = stops[stopIndex + 1]
  local alighted = 0
  if vehicle.destinationStationGroupCid == stopCid and vehicle.aboard > 0 then
    alighted = vehicle.aboard
    local earned = revenue.passengerDeliveryCents(
      alighted, vehicle.boardedFareCents or service.fareCents)
    vehicle.aboard = 0
    vehicle.originStationGroupCid = nil
    vehicle.destinationStationGroupCid = nil
    vehicle.boardedFareCents = nil
    vehicle.alightedTotal = add(vehicle.alightedTotal, alighted)
    vehicle.earnedRevenueCents = addCents(vehicle.earnedRevenueCents, earned)
    line.alightedTotal = add(line.alightedTotal, alighted)
    line.earnedRevenueCents = addCents(line.earnedRevenueCents, earned)
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
    boarded = boardingAmount(waiting, math.max(0, vehicle.capacity - vehicle.aboard))
    line[departuresField] = add(used, 1)
    line[waitingField] = waiting - boarded
    if boarded > 0 then
      vehicle.aboard = add(vehicle.aboard, boarded)
      vehicle.originStationGroupCid = stopCid
      vehicle.destinationStationGroupCid = destination
      vehicle.boardedFareCents = service.fareCents
      vehicle.boardedEpoch = state.epoch
      vehicle.boardedTotal = add(vehicle.boardedTotal, boarded)
      line.boardedTotal = add(line.boardedTotal, boarded)
    end
  end

  vehicle.lastRound = round
  vehicle.lastStopIndex = stopIndex
  vehicle.lastStationGroupCid = stopCid
  vehicle.lastReleaseAtMilliseconds = releaseMilliseconds
  return true, {
    passenger = true,
    direction = direction,
    boarded = boarded,
    alighted = alighted,
    aboard = vehicle.aboard,
    capacity = vehicle.capacity,
    requested = line.requested,
    allocated = line.allocated,
    generatedAToB = generatedAToB,
    generatedBToA = generatedBToA,
    abandoned = abandoned,
    waitingAToB = line.waitingAToB,
    waitingBToA = line.waitingBToA,
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
    local prior = state.vehicles[data.targetCid]
    if prior and prior.lineCid ~= data.lineCid then
      retireVehicle(state, data.targetCid)
      prior = nil
    end
    local line = ensureLine(state, economyState, data.lineCid, false)
    if not line then
      retireVehicle(state, data.targetCid)
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
      earnedRevenueCents = 0,
      discardedTotal = 0,
    }
    state.vehicles[data.targetCid].lineCid = data.lineCid
    state.vehicles[data.targetCid].companyCid = companyCid
  elseif transaction.kind == "vehicle.sell" then
    retireVehicle(state, data.targetCid)
  elseif transaction.kind == "vehicle.sell_batch" then
    for _, targetCid in ipairs(data.targetCids or {}) do retireVehicle(state, targetCid) end
  elseif transaction.kind == "line.delete" then
    retireLine(state, data.targetCid)
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
      requested = count(item.requested),
      capacityOverflow = count(item.capacityOverflow),
      intervalSeconds = math.max(60, math.min(86400,
        util.integer(item.intervalSeconds, M.EPOCH_SECONDS))),
      waitingAToB = count(item.waitingAToB),
      waitingBToA = count(item.waitingBToA),
      demandCursorMilliseconds = math.max(0, math.min(
        M.MAX_TIME_MILLISECONDS, util.integer(item.demandCursorMilliseconds, 0))),
      demandResidAToB = math.max(0, util.integer(item.demandResidAToB, 0)),
      demandResidBToA = math.max(0, util.integer(item.demandResidBToA, 0)),
      departuresPlanned = math.max(1, util.integer(item.departuresPlanned, 1)),
      departuresAToB = count(item.departuresAToB),
      departuresBToA = count(item.departuresBToA),
      seatsPerVehicle = math.max(1, count(item.seatsPerVehicle)),
      boardedTotal = count(item.boardedTotal),
      alightedTotal = count(item.alightedTotal),
      discardedTotal = count(item.discardedTotal),
      earnedRevenueCents = cents(item.earnedRevenueCents),
      overflowTotal = count(item.overflowTotal),
      generatedTotal = count(item.generatedTotal),
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
      earnedRevenueCents = cents(item.earnedRevenueCents),
      discardedTotal = count(item.discardedTotal),
    }
    optional(record, "boardedEpoch", item.boardedEpoch and math.max(0, util.integer(item.boardedEpoch, 0)))
    optional(record, "lastStopIndex", item.lastStopIndex and math.max(0, util.integer(item.lastStopIndex, 0)))
    optional(record, "lastStationGroupCid", item.lastStationGroupCid)
    optional(record, "originStationGroupCid", item.originStationGroupCid)
    optional(record, "destinationStationGroupCid", item.destinationStationGroupCid)
    optional(record, "boardedFareCents", item.boardedFareCents
      and math.max(0, util.integer(item.boardedFareCents, 0)))
    optional(record, "lastReleaseAtMilliseconds", item.lastReleaseAtMilliseconds
      and math.max(0, math.min(M.MAX_TIME_MILLISECONDS,
        util.integer(item.lastReleaseAtMilliseconds, 0))))
    vehicles[#vehicles + 1] = record
  end
  return {
    schemaVersion = M.SCHEMA_VERSION,
    epoch = state.epoch,
    lines = lines,
    vehicles = vehicles,
  }
end

-- The host embeds this cumulative, core-digested view in each ordered economy
-- settlement. Every peer compares it with its own station-release ledger
-- before accepting the payout, so only completed synchronized trips earn cash.
function M.economySnapshot(value)
  local state = M.migrate(value)
  local lines = {}
  for _, lineCid in ipairs(util.sortedKeys(state.lines)) do
    local line = state.lines[lineCid]
    lines[lineCid] = {
      deliveredPassengers = count(line.alightedTotal),
      earnedRevenueCents = cents(line.earnedRevenueCents),
    }
  end
  return { schemaVersion = 1, presentationEpoch = state.epoch, lines = lines }
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
    totals = { waiting = 0, aboard = 0, capacity = 0, boarded = 0,
      alighted = 0, discarded = 0, requested = 0, allocated = 0, capacityOverflow = 0,
      abandoned = 0, earnedRevenueCents = 0 },
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
    result.totals.requested = add(result.totals.requested, line.requested)
    result.totals.allocated = add(result.totals.allocated, line.allocated)
    result.totals.capacityOverflow = add(
      result.totals.capacityOverflow, line.capacityOverflow)
    result.totals.abandoned = add(result.totals.abandoned, line.overflowTotal)
    result.totals.boarded = add(result.totals.boarded, line.boardedTotal)
    result.totals.alighted = add(result.totals.alighted, line.alightedTotal)
    result.totals.discarded = add(result.totals.discarded, line.discardedTotal)
    result.totals.earnedRevenueCents = addCents(
      result.totals.earnedRevenueCents, line.earnedRevenueCents)
    local firstThroughput, secondThroughput = splitAllocation(line.allocated, line.epoch)
    local firstRequested, secondRequested = splitAllocation(line.requested, line.epoch)
    local firstOverflow, secondOverflow = splitAllocation(
      line.capacityOverflow, line.epoch)
    local routeStops = line.stops or { line.terminalA, line.terminalB }
    local seenStops = {}
    for _, stopCid in ipairs(routeStops) do
      if not seenStops[stopCid] then
        seenStops[stopCid] = true
        local terminal = {
          cid = stopCid, waiting = 0, throughput = 0,
          requested = 0, capacityOverflow = 0,
        }
        if stopCid == line.terminalA then
          terminal.waiting, terminal.throughput = line.waitingAToB, firstThroughput
          terminal.requested, terminal.capacityOverflow = firstRequested, firstOverflow
        elseif stopCid == line.terminalB then
          terminal.waiting, terminal.throughput = line.waitingBToA, secondThroughput
          terminal.requested, terminal.capacityOverflow = secondRequested, secondOverflow
        end
        local stationName, localStationId = nameOf(registry, terminal.cid)
        local station = result.stations[terminal.cid] or {
          stationGroupCid = terminal.cid,
          name = stationName,
          localId = localStationId,
          waiting = 0,
          throughput = 0,
          requested = 0,
          capacityOverflow = 0,
          lines = {},
        }
        station.waiting = add(station.waiting, terminal.waiting)
        station.throughput = add(station.throughput, terminal.throughput)
        station.requested = add(station.requested, terminal.requested)
        station.capacityOverflow = add(
          station.capacityOverflow, terminal.capacityOverflow)
        station.lines[#station.lines + 1] = {
          lineCid = lineCid,
          name = lineName,
          companyCid = line.companyCid,
          allocated = terminal.throughput,
          requested = terminal.requested,
          capacityOverflow = terminal.capacityOverflow,
          lineAllocated = line.allocated,
          waiting = terminal.waiting,
        }
        result.stations[terminal.cid] = station
        if localStationId then
          result.localStations[tostring(localStationId)] = terminal.cid
        end
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
