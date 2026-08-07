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
  -- With the agent policy pinning load speed, native dwell no longer varies
  -- with boarding, so this constant describes the world exactly instead of
  -- averaging it. Under the vanilla-population policy it remains an estimate.
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

-- Physical town growth, as an experiment that reports rather than assumes.
--
-- Capacity growth (above) is deterministic and already converges, but a town
-- whose capacity rises without gaining buildings still looks frozen, and
-- frozen towns are the thing testers object to by name. The cheapest honest
-- route is to let the game's own development logic choose lots and to order
-- only *when* it runs: the host emits one ordered `town.develop`, both peers
-- apply it, and the existing structural digest then says whether native
-- growth is deterministic enough to keep.
--
-- If it converges, visible growth costs almost nothing. If it diverges, the
-- structural comparison says so on the first attempt and authored placement
-- through the construction pipeline becomes the plan. Either way the answer
-- comes from one live session instead of a guess.
M.TOWN_DEVELOPMENT = {
  pointsPerBuilding = 400,    -- carried passengers behind one development call
  maxCallsPerSettle = 2,      -- per town, so a boom cannot flood a world
  maxPointsCarried = 4000,    -- accumulator ceiling
}

-- Growth points accumulate per town from carried demand and are spent in
-- whole buildings, so a quiet corridor still eventually grows its towns and
-- a busy one does not grow without bound.
function M.accumulateDevelopment(worldState, carriedByTown)
  local constants = M.TOWN_DEVELOPMENT
  worldState.townDevelopment = worldState.townDevelopment or {
    schemaVersion = 1, enabled = true, points = {}, cursor = {},
  }
  local pending = worldState.townDevelopment.points or {}
  local due = {}
  for _, townCid in ipairs(util.sortedKeys(carriedByTown or {})) do
    local total = math.min(constants.maxPointsCarried,
      util.integer(pending[townCid], 0) + util.integer(carriedByTown[townCid], 0))
    local calls = math.min(constants.maxCallsPerSettle,
      math.floor(total / constants.pointsPerBuilding))
    if calls > 0 then
      due[townCid] = calls
      total = total - calls * constants.pointsPerBuilding
    end
    pending[townCid] = total
  end
  worldState.townDevelopment.points = pending
  return due
end

-- Canonical schedule policy consumed by the station barrier. The base phase
-- belongs to the line; each stop receives a deterministic journey offset so
-- termini do not accidentally share one departure instant. The host reserves
-- concrete slot indices, which prevents two trains arriving together from
-- claiming the same service departure.
function M.departureSchedule(service, stopIndex)
  local period = math.max(1, math.floor(tonumber(service and service.headwaySeconds) or 1))
  local lineCid = tostring(service and service.lineCid or "")
  local basePhase = hash.adler32 and (hash.adler32(lineCid) % period) or 0
  local stops = service and service.metadata and service.metadata.stationGroupCids or {}
  local stopCount = math.max(1, type(stops) == "table" and #stops or 0)
  local normalizedStop = math.max(0, math.floor(tonumber(stopIndex) or 0)) % stopCount
  local offset = 0
  if stopCount > 1 then
    local journey = math.max(0, math.floor(tonumber(service.journeySeconds) or period))
    offset = math.floor(journey * normalizedStop / (stopCount - 1))
  end
  return {
    schemaVersion = 1,
    enabled = true,
    periodSeconds = period,
    phaseSeconds = (basePhase + offset) % period,
  }
end

-- Registered competitive services supply the timetable enforced by the
-- station barrier. An ordinary line has no authored headway yet, so inventing
-- one here would turn synchronization into an artificial station dwell. It
-- still uses the all-peer barrier, but the host releases it after the normal
-- network safety guard instead of reserving a timetable slot.
function M.synchronizationSchedule(lineCid, service, stopIndex)
  if type(service) == "table" and service.enabled ~= false then
    return M.departureSchedule(service, stopIndex)
  end
  return { schemaVersion = 1, enabled = false }
end

-- Returns the first strictly future slot from the same policy the network
-- station barrier enforces. Pure callers (UI/model/tests) and enforcement must
-- therefore never grow independent opinions about departure timing.
function M.departureSlots(service, gameTimeSeconds, stopIndex)
  local schedule = M.departureSchedule(service, stopIndex)
  local period, phase = schedule.periodSeconds, schedule.phaseSeconds
  local now = math.max(0, math.floor(tonumber(gameTimeSeconds) or 0))
  local sincePhase = now - phase
  local index = math.floor(sincePhase / period) + 1
  local nextDeparture = phase + index * period
  return {
    schemaVersion = schedule.schemaVersion,
    periodSeconds = period,
    phaseSeconds = phase,
    slotIndex = index,
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
  local developmentPositionsOfTown = assert(
    deps.developmentPositionsOfTown, "developmentPositionsOfTown dependency is required")
  local resolveLocal = assert(deps.resolveLocal, "resolveLocal dependency is required")

  local binding = {}

  -- Applies deterministic town growth after an ordered settlement. Every
  -- peer runs this with identical results/state, issues identical native
  -- setTownInfo commands, and the structural probe verifies convergence.
  -- Fail-soft: an unavailable factory or unmapped town skips with a record.
  -- Applies one ordered development batch. Every peer runs the identical
  -- call sequence; the structural probe then decides whether the native
  -- results agreed. Fail-soft with a recorded outcome, because an
  -- unavailable factory must not fault a session that is otherwise healthy.
  function binding.applyTownDevelopment(registry, batch, worldState)
    worldState = worldState or {}
    worldState.townDevelopment = worldState.townDevelopment or {
      schemaVersion = 1, enabled = true, points = {}, cursor = {},
    }
    worldState.townDevelopment.cursor = worldState.townDevelopment.cursor or {}
    local outcome = {
      towns = 0, calls = 0, activated = 0, refrozen = 0,
      candidatePositions = {}, positionDiagnostics = {},
      selectedPositions = {}, errors = {},
    }
    local factory = util.commandFactory("developTown")
    if not factory then
      outcome.errors[#outcome.errors + 1] = "developTown command factory is unavailable"
      return outcome
    end
    for _, townCid in ipairs(util.sortedKeys(batch or {})) do
      local localId = resolveLocal(registry, townCid)
      if not localId then
        outcome.errors[#outcome.errors + 1] = "town is not mapped locally: " .. tostring(townCid)
      else
        -- Cursor movement belongs to the committed authored action, not to
        -- machine-local command success. This keeps Lua state identical to
        -- portable checkpoint replay even when a native command later faults
        -- (the handler then suppresses the boundary checkpoint).
        local requested = math.max(0, util.integer(batch[townCid], 0))
        local cursor = math.max(0,
          util.integer(worldState.townDevelopment.cursor[townCid], 0))
        worldState.townDevelopment.cursor[townCid] = cursor + requested
        local positions, positionDiagnostics = developmentPositionsOfTown(localId)
        outcome.positionDiagnostics[townCid] = positionDiagnostics
        local vec2Factory = api and api.type and api.type.Vec2f
          and api.type.Vec2f.new or nil
        if #positions == 0 or not vec2Factory then
          outcome.errors[#outcome.errors + 1] =
            "town development position is unavailable: " .. tostring(townCid)
        else
          outcome.candidatePositions[townCid] = #positions
          -- The match keeps autonomous growth disabled. DevelopTown is a
          -- no-op while that per-town switch is false, even when the command
          -- itself reports success. Open it only inside this ordered engine
          -- callback, issue the immediate native command(s), and close it
          -- again before the action can be checkpointed.
          local setDevelopmentActive = game and game.interface
            and game.interface.setTownDevelopmentActive or nil
          local activated, activateError = false, "setTownDevelopmentActive is unavailable"
          if type(setDevelopmentActive) == "function" then
            activated, activateError = pcall(setDevelopmentActive, localId, true)
          end
          if not activated then
            outcome.errors[#outcome.errors + 1] = tostring(activateError)
          else
            outcome.activated = outcome.activated + 1
            outcome.towns = outcome.towns + 1
            for callIndex = 1, requested do
              local positionIndex = ((cursor + callIndex - 1) % #positions) + 1
              local position = positions[positionIndex]
              outcome.selectedPositions[#outcome.selectedPositions + 1] = {
                townCid = townCid, index = positionIndex,
                x = position[1], y = position[2],
              }
              local madePosition, nativePosition = pcall(
                vec2Factory, position[1], position[2])
              local made, commandOrError = false, nativePosition
              if madePosition then made, commandOrError = pcall(factory, nativePosition) end
              local ok, err = false, commandOrError
              if made then
                ok, err = util.sendCommand(commandOrError, nil, "mod.world.town-development")
              end
              if ok then
                outcome.calls = outcome.calls + 1
              else
                outcome.errors[#outcome.errors + 1] = tostring(err)
              end
            end
            local refrozen, refreezeError = pcall(setDevelopmentActive, localId, false)
            if refrozen then
              outcome.refrozen = outcome.refrozen + 1
            else
              outcome.errors[#outcome.errors + 1] = tostring(refreezeError)
            end
          end
        end
      end
    end
    return outcome
  end

  -- Registration is automatic: any operation that changes a line's shape or
  -- its vehicle set makes the owning peer re-derive that line's competitive
  -- facts. The player never asks for a market; running a service is the ask.
  local AUTO_REGISTER_KINDS = {
    ["line.create"] = "targetCid",
    ["line.update"] = "targetCid",
    ["vehicle.assign"] = "lineCid",
  }

  function binding.autoRegisterLine(state, transaction, outputCid, deps)
    if type(transaction) ~= "table" then return end
    local field = AUTO_REGISTER_KINDS[transaction.kind]
    if not field then return end
    local lineCid = transaction.data and transaction.data[field] or nil
    if transaction.kind == "line.create" then lineCid = outputCid end
    if type(lineCid) ~= "string" or lineCid == "" then return end
    local companyCid = transaction.companyCid
    local existing = state.economy.services[lineCid]
    if existing and existing.companyCid ~= companyCid then return end
    -- Only the owning peer derives and carries the facts; every other peer
    -- applies the ordered result, exactly like a manual registration.
    if state.networkMode == "network" and deps.activeCompany() ~= companyCid then return end
    if not resolveLocal(state.canonical, lineCid) then return end
    local called, queued, queueResult = pcall(deps.submit, {
      type = "line.register", lineCid = lineCid, companyCid = companyCid,
    })
    if (not called or queued ~= true) and deps.log then
      deps.log("auto-register-failed", {
        lineCid = lineCid,
        error = tostring(not called and queued or queueResult), tick = state.tick,
      })
    end
    return called and queued == true, called and queueResult or queued
  end

  -- Applies an ordered batch and refreshes the structural probe so the next
  -- checkpoint compares the world these calls produced, not the one before.
  function binding.runOrderedDevelopment(state, batch, structuralSnapshot, log)
    local applied, outcome = pcall(
      binding.applyTownDevelopment, state.canonical, batch, state.world)
    state.probes.townDevelopment = applied and outcome or { errors = { tostring(outcome) } }
    state.probes.townDevelopment.batch = util.deepCopy(batch)
    state.probes.structural = structuralSnapshot()
    state.probes.townDevelopment.structuralDigest = state.probes.structural
      and state.probes.structural.digest or nil
    if log then
      log("town-development", {
        towns = state.probes.townDevelopment.towns,
        calls = state.probes.townDevelopment.calls,
        structuralDigest = state.probes.townDevelopment.structuralDigest,
        tick = state.tick,
      })
    end
    return state.probes.townDevelopment
  end

  -- Turns a settlement's carried demand into an ordered development batch on
  -- the host, or applies it directly when there is no ordering to do.
  function binding.settleDevelopment(state, results, economyState, cfg, submit, apply)
    if not cfg.townDevelopment then return nil end
    local carried = M.carriedByTown(results, economyState.markets)
    local due = M.accumulateDevelopment(state.world, carried)
    if next(due) == nil then return nil end
    if state.networkMode == "network" then
      if state.bridge.peerId ~= "player1" then return nil end
      local called, queued, queueResult = pcall(
        submit, { type = "town.develop", batch = due })
      if not called or queued ~= true then
        state.probes.townDevelopmentQueue = {
          success = false,
          error = tostring(not called and queued or queueResult),
          batch = util.deepCopy(due),
          tick = state.tick,
        }
        return due, state.probes.townDevelopmentQueue.error
      end
      state.probes.townDevelopmentQueue = {
        success = true, batch = util.deepCopy(due), tick = state.tick,
      }
    else
      apply({ type = "town.develop", batch = due }, state.bridge.peerId, nil)
    end
    return due
  end

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

  -- positionOfEntity here is world's strict resolver: it answers nil rather
  -- than a {0,0} sentinel, so an unresolvable stop fails the computed path
  -- honestly instead of fabricating geometry, and a legitimate station at
  -- the world origin still measures correctly.
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
    -- Each fallback is reported, so factsSource names what actually ran
    -- rather than implying repository metadata that never resolved.
    local speedMs = consistFacts and consistFacts.limitSpeedMs
    local defaultedSpeed = not (speedMs and speedMs > 0)
    if defaultedSpeed then speedMs = constants.defaultTopSpeedKmh * 1000 / 3600 end
    local cruiseMs = speedMs * constants.speedUtilisationPct / 100
    if cruiseMs <= 0 then return nil end
    local journey = math.max(60, math.floor(routeMeters / cruiseMs)
      + constants.dwellSecondsPerStop * #groups)
    local cycle = journey * 2 + constants.turnaroundSeconds
    -- A line with no rolling stock runs no service: it gets a nominal
    -- headway for display and zero capacity, so it can never be allocated
    -- passengers or earn revenue.
    local runs = math.max(0, util.integer(vehicles, 0))
    local headway = math.max(constants.minHeadwaySeconds,
      math.floor(cycle / math.max(1, runs)))
    local seats = consistFacts and consistFacts.seats or 0
    local defaultedSeats = not (seats > 0)
    if defaultedSeats then seats = constants.fallbackSeatsPerVehicle end
    local departures = math.max(1, math.floor(constants.epochSeconds / headway))
    return {
      distanceMeters = routeMeters,
      journeySeconds = journey,
      headwaySeconds = headway,
      capacity = runs > 0 and (seats * runs * departures) or 0,
      seatsPerVehicle = seats,
      defaultedSpeed = defaultedSpeed,
      defaultedSeats = defaultedSeats,
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
    -- The market belongs to the town pair, not to the registering line. A
    -- rival's detour must never deflate a shared corridor, so the pool is
    -- sized by the shortest route anyone has found between these towns and
    -- an existing market's demand is only ever revised upward.
    local existingMarket = economyState.markets[marketCid]
    local existingDistance = existingMarket and existingMarket.metadata
      and tonumber(existingMarket.metadata.corridorMeters) or nil
    local corridorMeters = computed and computed.distanceMeters or existingDistance
    if computed and existingDistance then
      corridorMeters = math.min(existingDistance, computed.distanceMeters)
    end
    local demand = corridorMeters
      and M.gravityDemand(capacityA, capacityB, corridorMeters)
      or util.clamp(math.max(100, math.floor((capacityA + capacityB) / 12)),
        M.SERVICE_FACTS.minDemand, M.SERVICE_FACTS.maxDemand)
    if existingMarket then demand = math.max(util.integer(existingMarket.demand, 0), demand) end
    economyModule.upsertMarket(economyState, {
      cid = marketCid,
      name = nameOf(townA) .. " ↔ " .. nameOf(townB),
      kind = existingMarket and existingMarket.kind or "passenger",
      demand = demand,
      metadata = {
        townA = townCidA, townB = townCidB,
        corridorMeters = corridorMeters,
      },
    })

    local headway, journey, capacity, factsSource
    if computed then
      headway, journey, capacity = computed.headwaySeconds, computed.journeySeconds, computed.capacity
      factsSource = "computed-consist"
      if computed.defaultedSpeed then factsSource = "computed-default-speed" end
      if computed.defaultedSeats then
        factsSource = computed.defaultedSpeed and "computed-defaults" or "computed-default-seats"
      end
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
    -- A corridor's passengers board once and alight once, so a line's load
    -- distributes across its stops rather than appearing whole at each one.
    -- Summing the raw allocation per stop would report a 5-stop line as
    -- five times its real traffic and rank halts like termini.
    local stops = service.metadata and service.metadata.stationGroupCids or {}
    local perStop = #stops > 0 and math.floor(allocated / #stops) or 0
    local waiting = math.floor(perStop * headway / constants.epochSeconds)
    for _, groupCid in ipairs(stops) do
      local bindingRecord = registry and registry.byCanonical and registry.byCanonical[groupCid] or nil
      local stationName = bindingRecord and bindingRecord.metadata and bindingRecord.metadata.name or groupCid
      local board = boards[groupCid]
        or { stationGroupCid = groupCid, name = stationName, waiting = 0, throughput = 0, lines = {} }
      board.waiting = board.waiting + waiting
      board.throughput = board.throughput + perStop
      board.lines[#board.lines + 1] = {
        lineCid = lineCid,
        name = service.name,
        companyCid = service.companyCid,
        allocated = perStop,
        lineAllocated = allocated,
        waiting = waiting,
      }
      boards[groupCid] = board
    end
  end
  return boards
end

return M
