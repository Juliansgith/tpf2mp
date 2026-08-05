local util = require "tpf2_mp/util"
local hash = require "tpf2_mp/hash"

local M = {}

-- Corridor-binding constants. Facts derived from these are computed on the
-- origin peer and ride the ordered line.register action as authoritative
-- values, so peers and the companion replay apply results, never re-derive.
M.SERVICE_FACTS = {
  epochSeconds = 3600,            -- one authored market hour per settlement
  routeFactorPct = 125,           -- euclidean -> track distance allowance
  speedUtilisationPct = 70,       -- sustained share of consist top speed
  defaultTopSpeedKmh = 100,
  dwellSecondsPerStop = 45,
  turnaroundSeconds = 240,        -- both terminals combined per cycle
  minHeadwaySeconds = 60,
  fallbackSeatsPerVehicle = 100,
  gravityDivisor = 25,            -- demand = capA*capB / (divisor * km)
  minDemand = 50,
  maxDemand = 100000,
}

local function modelRepository()
  local repository = api and api.res and api.res.modelRep or nil
  if repository and repository.get ~= nil and repository.find ~= nil then return repository end
  return nil
end

local function compartmentSeats(compartment)
  local best = 0
  local configs = compartment and (compartment.loadConfigs or compartment) or {}
  local iterated = pcall(function()
    for _, config in pairs(configs) do
      local total = 0
      for _, entry in pairs((config and config.cargoEntries) or {}) do
        total = total + (tonumber(entry and entry.capacity) or 0)
      end
      if total > best then best = total end
    end
  end)
  if not iterated then return 0 end
  return best
end

-- Sums seats and finds the limiting top speed for a consist by model name
-- through repository metadata, when this build exposes modelRep.get. Returns
-- nil when any part cannot be resolved: the caller falls back to estimates
-- and records which path ran, so live sessions can verify the computed path.
function M.consistTransportFacts(modelNames)
  local repository = modelRepository()
  if not repository or type(modelNames) ~= "table" or #modelNames == 0 then return nil end
  local seats, limitSpeedMs = 0, nil
  for _, name in ipairs(modelNames) do
    local found, index = pcall(repository.find, name)
    if not found or tonumber(index) == nil or tonumber(index) < 0 then return nil end
    local ok, record = pcall(repository.get, tonumber(index))
    if not ok or record == nil then return nil end
    local metadata = record.metadata or record
    local transport = metadata and metadata.transportVehicle or nil
    if not transport then return nil end
    local partSeats = 0
    local scanned = pcall(function()
      for _, compartment in pairs(transport.compartmentsList or transport.compartments or {}) do
        partSeats = partSeats + compartmentSeats(compartment)
      end
    end)
    if not scanned then return nil end
    seats = seats + partSeats
    local speed = tonumber(transport.topSpeed)
    if speed and speed > 0 and (limitSpeedMs == nil or speed < limitSpeedMs) then
      limitSpeedMs = speed
    end
  end
  return { seats = seats, limitSpeedMs = limitSpeedMs }
end

function M.gravityDemand(capacityA, capacityB, distanceMeters)
  local constants = M.SERVICE_FACTS
  local km = math.max(1, math.floor((distanceMeters or 1000) / 1000))
  local demand = math.floor((capacityA * capacityB) / (constants.gravityDivisor * km))
  return util.clamp(demand, constants.minDemand, constants.maxDemand)
end

-- Town growth version 1: capacities respond to carried demand. Growth is a
-- deterministic pure function of the ordered settlement results, so every
-- peer computes identical targets from the same committed action and issues
-- identical native commands; the structural probe then verifies convergence.
-- No new protocol, no authored-model state, no replay change.
M.TOWN_GROWTH = {
  carriedPct = 5,          -- share of carried passengers becoming capacity
  residentialPct = 60,     -- split of growth across land uses
  commercialPct = 25,
  industrialPct = 15,
  maxStepPerSettle = 50,   -- per town per settlement, per land use ceiling
  capacityCap = 100000,
}

-- Settlement results plus the digested market metadata (which names each
-- corridor's endpoint towns) -> carried passengers per town. Both inputs are
-- identical on every peer by the time an ordered settlement applies.
function M.carriedByTown(results, markets)
  local carriedByTown = {}
  for _, marketCid in ipairs(util.sortedKeys((results and results.markets) or {})) do
    local market = results.markets[marketCid]
    local metadata = (markets and markets[marketCid] and markets[marketCid].metadata) or {}
    local townA, townB = metadata.townA, metadata.townB
    if townA and townB then
      local carried = 0
      for _, lineCid in ipairs(util.sortedKeys(market.services or {})) do
        carried = carried + (tonumber(market.services[lineCid].allocated) or 0)
      end
      local half = math.floor(carried / 2)
      carriedByTown[townA] = (carriedByTown[townA] or 0) + half
      carriedByTown[townB] = (carriedByTown[townB] or 0) + (carried - half)
    end
  end
  return carriedByTown
end

-- Pure policy: carried passengers per town -> per-town land-use capacity
-- targets. currentCapacities maps townCid -> {res, com, ind}. Deterministic
-- integer arithmetic over digested values only.
function M.townGrowthTargets(carriedByTown, currentCapacities)
  local constants = M.TOWN_GROWTH
  local targets = {}
  for _, townCid in ipairs(util.sortedKeys(carriedByTown)) do
    local current = currentCapacities[townCid]
    if current then
      local points = math.floor(carriedByTown[townCid] * constants.carriedPct / 100)
      local function grow(base, sharePct)
        local step = math.min(constants.maxStepPerSettle,
          math.floor(points * sharePct / 100))
        return math.min(constants.capacityCap, (tonumber(base) or 0) + step)
      end
      local target = {
        grow(current[1], constants.residentialPct),
        grow(current[2], constants.commercialPct),
        grow(current[3], constants.industrialPct),
      }
      if target[1] ~= current[1] or target[2] ~= current[2] or target[3] ~= current[3] then
        targets[townCid] = target
      end
    end
  end
  return targets
end

-- Deterministic departure slots per service. Pure computation only: the
-- enforcement mode (host-ordered holds versus locally issued holds) is
-- gated on the agents-off pivot, because vehicle userStopped state is
-- currently lifecycle-digest material and per-departure ordered operations
-- would serialize through consensus barriers.
function M.departureSlots(service, gameTimeSeconds)
  local period = math.max(1, tonumber(service.headwaySeconds) or 1)
  local phase = hash.adler32 and (hash.adler32(tostring(service.lineCid)) % period)
    or 0
  local now = math.max(0, math.floor(tonumber(gameTimeSeconds) or 0))
  local sincePhase = now - phase
  local index = math.floor(sincePhase / period) + 1
  local nextDeparture = phase + index * period
  return {
    periodSeconds = period,
    phaseSeconds = phase,
    nextDepartureAt = nextDeparture,
    holdSeconds = nextDeparture - now,
  }
end

function M.new(deps)
  assert(type(deps) == "table", "corridor binding dependencies are required")
  local bindExisting = assert(deps.bindExisting, "bindExisting dependency is required")
  local lineStopGroups = assert(deps.lineStopGroups, "lineStopGroups dependency is required")
  local stationGroupTown = assert(deps.stationGroupTown, "stationGroupTown dependency is required")
  local townCapacity = assert(deps.townCapacity, "townCapacity dependency is required")
  local lineVehicleCount = assert(deps.lineVehicleCount, "lineVehicleCount dependency is required")
  local nameOf = assert(deps.nameOf, "nameOf dependency is required")
  local safeEntity = assert(deps.safeEntity, "safeEntity dependency is required")
  local positionOfEntity = assert(deps.positionOfEntity, "positionOfEntity dependency is required")
  local resolveLocal = assert(deps.resolveLocal, "resolveLocal dependency is required")

  local binding = {}

  -- Applies deterministic town growth after an ordered settlement. Every
  -- peer runs this with identical results/state, issues identical native
  -- setTownInfo commands, and the structural probe verifies convergence.
  -- Fail-soft: an unavailable factory or unmapped town skips with a record.
  function binding.applyTownGrowth(registry, economyState, results)
    local outcome = { towns = 0, skipped = 0, errors = {} }
    local carriedByTown = M.carriedByTown(results, economyState.markets)
    local currentCapacities, localIds = {}, {}
    for _, townCid in ipairs(util.sortedKeys(carriedByTown)) do
      local localId = resolveLocal(registry, townCid)
      if localId then
        local _, capacities = townCapacity(localId)
        currentCapacities[townCid] = capacities
        localIds[townCid] = localId
      else
        outcome.skipped = outcome.skipped + 1
      end
    end
    local targets = M.townGrowthTargets(carriedByTown, currentCapacities)
    if next(targets) == nil then return outcome end
    local factory = util.commandFactory("setTownInfo")
    if not factory then
      outcome.errors[#outcome.errors + 1] = "setTownInfo command factory is unavailable"
      return outcome
    end
    for _, townCid in ipairs(util.sortedKeys(targets)) do
      local made, commandOrError = pcall(factory, localIds[townCid], targets[townCid])
      local ok, err = false, commandOrError
      if made then ok, err = util.sendCommand(commandOrError, nil, "mod.world.town-growth") end
      if ok then outcome.towns = outcome.towns + 1
      else outcome.errors[#outcome.errors + 1] = tostring(err) end
    end
    return outcome
  end

  local function corridorDistanceDm(groups)
    local total = 0
    for index = 2, #groups do
      local from = positionOfEntity(groups[index - 1])
      local to = positionOfEntity(groups[index])
      if not from or not to then return nil end
      local dx, dy = from[1] - to[1], from[2] - to[2]
      total = total + math.floor(math.sqrt(dx * dx + dy * dy))
    end
    return total > 0 and total or nil
  end

  -- Portable model names of one representative consist on the line, read
  -- from the first vehicle's TRANSPORT_VEHICLE component. Bounded, fail-soft.
  local function firstConsistModelNames(lineId)
    local system = api and api.engine and api.engine.system
      and api.engine.system.transportVehicleSystem or nil
    if not (system and system.getLineVehicles) then return nil end
    local ok, vehicleIds = pcall(system.getLineVehicles, lineId)
    if not ok or (type(vehicleIds) ~= "table" and type(vehicleIds) ~= "userdata") then return nil end
    local firstVehicle
    local iterated = pcall(function()
      for _, vehicleId in pairs(vehicleIds) do firstVehicle = tonumber(vehicleId); break end
    end)
    if not iterated or not firstVehicle then return nil end
    local componentOk, transportVehicle = pcall(api.engine.getComponent,
      firstVehicle, api.type.ComponentType.TRANSPORT_VEHICLE)
    if not componentOk or not transportVehicle then return nil end
    local config = transportVehicle.transportVehicleConfig
    local parts = config and config.vehicles or nil
    if parts == nil then return nil end
    local repository = api.res and api.res.modelRep or nil
    if not (repository and repository.getName) then return nil end
    local names = {}
    local walked = pcall(function()
      local count = 0
      for _, part in pairs(parts) do
        count = count + 1
        if count > 128 then error("consist too long") end
        local modelId = part and (part.part and part.part.modelId or part.modelId)
        local named, name = pcall(repository.getName, tonumber(modelId) or -1)
        if not named or type(name) ~= "string" or name == "" then error("unresolved model") end
        names[#names + 1] = name
      end
    end)
    if not walked or #names == 0 then return nil end
    return names
  end

  -- Journey, headway, and per-epoch seat capacity from canonical geometry
  -- and the consist. Origin-only arithmetic (sqrt included): the results are
  -- embedded in the ordered action, so no cross-peer recomputation happens.
  function binding.computedServiceFacts(groups, vehicles, consistFacts)
    local constants = M.SERVICE_FACTS
    local distanceDm = corridorDistanceDm(groups)
    if not distanceDm then return nil end
    local routeMeters = math.floor(distanceDm * constants.routeFactorPct / 1000)
    local speedMs = consistFacts and consistFacts.limitSpeedMs
      or (constants.defaultTopSpeedKmh * 1000 / 3600)
    local cruiseMs = speedMs * constants.speedUtilisationPct / 100
    if cruiseMs <= 0 then return nil end
    local journey = math.max(60, math.floor(routeMeters / cruiseMs)
      + constants.dwellSecondsPerStop * #groups)
    local cycle = journey * 2 + constants.turnaroundSeconds
    local headway = math.max(constants.minHeadwaySeconds,
      math.floor(cycle / math.max(1, vehicles)))
    local seats = consistFacts and consistFacts.seats and consistFacts.seats > 0
      and consistFacts.seats or constants.fallbackSeatsPerVehicle
    local departures = math.max(1, math.floor(constants.epochSeconds / headway))
    return {
      distanceMeters = routeMeters,
      journeySeconds = journey,
      headwaySeconds = headway,
      capacity = seats * math.max(1, vehicles) * departures,
      seatsPerVehicle = seats,
    }
  end

  function binding.makeLineService(registry, economyModule, economyState, lineId, companyCid)
    local lineCid, err = bindExisting(registry, lineId, "line", { name = nameOf(lineId) })
    if not lineCid then return false, err end
    local groups = lineStopGroups(lineId)
    if #groups < 2 then return false, "line needs at least two station groups" end
    local townA, townB = stationGroupTown(groups[1]), stationGroupTown(groups[#groups])
    if not townA or not townB or townA == townB then
      return false, "line endpoints do not map to two distinct towns"
    end
    local townCidA = bindExisting(registry, townA, "town", { name = nameOf(townA) })
    local townCidB = bindExisting(registry, townB, "town", { name = nameOf(townB) })
    local first, second = townCidA, townCidB
    if second < first then first, second = second, first end
    local marketCid = "market:" .. hash.value({ first, second })
    local vehicles = lineVehicleCount(lineId)

    local stationGroupCids = {}
    for _, groupId in ipairs(groups) do
      local groupCid = bindExisting(registry, groupId, "station_group", { name = nameOf(groupId) })
      if groupCid then stationGroupCids[#stationGroupCids + 1] = groupCid end
    end

    local consistFacts
    do
      local names = firstConsistModelNames(lineId)
      if names then consistFacts = M.consistTransportFacts(names) end
    end
    local computed = binding.computedServiceFacts(groups, vehicles, consistFacts)

    local capacityA = townCapacity(townA)
    local capacityB = townCapacity(townB)
    local demand = computed
      and M.gravityDemand(capacityA, capacityB, computed.distanceMeters)
      or math.max(100, math.floor((capacityA + capacityB) / 12))
    economyModule.upsertMarket(economyState, {
      cid = marketCid,
      name = nameOf(townA) .. " ↔ " .. nameOf(townB),
      kind = "passenger",
      demand = demand,
      metadata = { townA = townCidA, townB = townCidB },
    })

    local headway, journey, capacity, factsSource
    if computed then
      headway, journey, capacity = computed.headwaySeconds, computed.journeySeconds, computed.capacity
      factsSource = consistFacts and "computed-consist" or "computed-default-speed"
    else
      local lineEntity = safeEntity(lineId) or {}
      local nativeFrequency = tonumber(lineEntity.frequency) or 0
      local nativeRate = tonumber(lineEntity.rate) or 0
      headway = nativeFrequency > 0 and math.max(30, util.integer(1 / nativeFrequency, 1800))
        or math.max(300, math.floor(3600 / math.max(1, vehicles)))
      local estimatedCycle = headway * math.max(1, vehicles)
      journey = math.max(300, util.integer(estimatedCycle / 2, #groups * 900))
      capacity = math.max(50, nativeRate > 0 and util.integer(nativeRate) or vehicles * 100)
      factsSource = "estimated-legacy"
    end

    local previous = economyState.services[lineCid]
    economyModule.upsertService(economyState, {
      lineCid = lineCid,
      marketCid = marketCid,
      companyCid = companyCid,
      name = nameOf(lineId),
      headwaySeconds = headway,
      journeySeconds = journey,
      fareCents = previous and previous.fareCents or 1000,
      capacity = capacity,
      quality = math.max(20, 120 - math.max(0, #groups - 2) * 10),
      metadata = {
        vehicleCount = vehicles,
        factsSource = factsSource,
        distanceMeters = computed and computed.distanceMeters or nil,
        seatsPerVehicle = computed and computed.seatsPerVehicle or nil,
        stationGroupCids = stationGroupCids,
      },
    })
    return true, {
      lineCid = lineCid, marketCid = marketCid, townA = townCidA, townB = townCidB,
      vehicleCount = vehicles, factsSource = factsSource,
    }
  end

  return binding
end

-- Per-station display aggregation for the per-peer boards. Reads only
-- authored model state, last results, and registry names; the output never
-- enters a digest.
function M.stationBoards(economyState, registry)
  local constants = M.SERVICE_FACTS
  local boards = {}
  for _, lineCid in ipairs(util.sortedKeys(economyState.services or {})) do
    local service = economyState.services[lineCid]
    local marketResults = economyState.lastResults and economyState.lastResults.markets
      and economyState.lastResults.markets[service.marketCid] or nil
    local row = marketResults and marketResults.services and marketResults.services[lineCid] or nil
    local allocated = row and row.allocated or 0
    local headway = math.min(service.headwaySeconds or constants.epochSeconds, constants.epochSeconds)
    local waiting = math.floor(allocated * headway / constants.epochSeconds)
    for _, groupCid in ipairs((service.metadata and service.metadata.stationGroupCids) or {}) do
      local bindingRecord = registry and registry.byCanonical and registry.byCanonical[groupCid] or nil
      local stationName = bindingRecord and bindingRecord.metadata and bindingRecord.metadata.name or groupCid
      local board = boards[groupCid]
        or { stationGroupCid = groupCid, name = stationName, waiting = 0, throughput = 0, lines = {} }
      board.waiting = board.waiting + waiting
      board.throughput = board.throughput + allocated
      board.lines[#board.lines + 1] = {
        lineCid = lineCid,
        name = service.name,
        companyCid = service.companyCid,
        allocated = allocated,
        waiting = waiting,
      }
      boards[groupCid] = board
    end
  end
  return boards
end

return M
