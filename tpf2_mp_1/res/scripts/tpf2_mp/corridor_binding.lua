local util = require "tpf2_mp/util"
local hash = require "tpf2_mp/hash"
local revenue = require "tpf2_mp/economy_revenue"
local townDemand = require "tpf2_mp/economy_town_demand"
local vehicleResourceFacts = require "tpf2_mp/vehicle_resource_facts"
local freightServiceBinding = require "tpf2_mp/freight_service_binding"
local multihopNetwork = require "tpf2_mp/multihop_network"
local nativeCommandAuthority = require "tpf2_mp/native_command_authority"

local M = {}

-- Corridor-binding constants. Facts derived from these are computed on the
-- origin peer and ride the ordered line.register action as authoritative
-- values, so peers and the companion replay apply results, never re-derive.
M.SERVICE_FACTS = {
  capacityWindowSeconds = 3600,   -- service capacity remains an hourly rate
  accountingIntervalSeconds = 300,
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
  gravityDivisor = townDemand.GRAVITY_DIVISOR,
                                      -- demand = sizeA*sizeB / (divisor * km)
  -- Town size is a building count, not native capacity: the crowd policy
  -- scales capacity at load, and demand goes as the product of two town sizes,
  -- so reading capacity would let a cosmetic setting rescale the whole economy
  -- by roughly the square of the policy factor. See world.townBuildingCount.
  --
  -- This converts a count back into the numeric range the divisor was tuned
  -- against. The value is the measured vanilla capacity-per-construction
  -- (3.38-3.77, AGENT_PRESENTATION_POLICY_2026-08-06) rounded to an integer.
  -- Town buildings are a subset of constructions, so the true per-building
  -- figure is somewhat higher; calibrate against a live vanilla world by
  -- comparing this size to that world's reported town capacity.
  nominalCapacityPerBuilding = townDemand.NOMINAL_CAPACITY_PER_BUILDING,
  -- An unsized town still has to trade. Documented rather than magic, and
  -- deliberately mid-range so an unreadable town neither dominates nor
  -- vanishes from a corridor.
  fallbackTownBuildings = townDemand.FALLBACK_TOWN_BUILDINGS,
  minDemand = townDemand.MIN_DEMAND,
  maxDemand = townDemand.MAX_DEMAND,
}

M.consistTransportFacts = vehicleResourceFacts.consist

function M.gravityDemand(capacityA, capacityB, distanceMeters)
  return townDemand.gravityDemand(capacityA, capacityB, distanceMeters)
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
        local service = market.services[lineCid]
        carried = carried + (tonumber(service.delivered or service.allocated) or 0)
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

-- The authored headway is an economy/service-frequency input, not a native
-- timetable. Live evidence showed that forcing a train onto the next full
-- headway slot at every stop can hold a one-train line for hundreds of game
-- seconds and eventually trip the station-round safety timeout. Physical train
-- synchronization therefore always uses the prompt all-peer rendezvous: once
-- every native copy is held at the same stop, the host releases it after only
-- the bounded network guard. departureSchedule/departureSlots remain pure
-- model queries and do not control native dwell.
function M.synchronizationSchedule(lineCid, service, stopIndex)
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
  local lineServiceKind = assert(deps.lineServiceKind, "lineServiceKind dependency is required")
  local stationGroupTown = assert(deps.stationGroupTown, "stationGroupTown dependency is required")
  local townCapacity = assert(deps.townCapacity, "townCapacity dependency is required")
  local townBuildingCount = assert(
    deps.townBuildingCount, "townBuildingCount dependency is required")
  local lineVehicleIds = assert(deps.lineVehicleIds, "lineVehicleIds dependency is required")
  local nameOf = assert(deps.nameOf, "nameOf dependency is required")
  local safeEntity = assert(deps.safeEntity, "safeEntity dependency is required")
  local positionOfEntity = assert(deps.positionOfEntity, "positionOfEntity dependency is required")
  local developmentPositionsOfTown = assert(
    deps.developmentPositionsOfTown, "developmentPositionsOfTown dependency is required")
  local resolveLocal = assert(deps.resolveLocal, "resolveLocal dependency is required")
  local resolveCanonical = assert(deps.resolveCanonical, "resolveCanonical dependency is required")

  -- The model's town size, in the same units the gravity divisor was tuned
  -- against. Deliberately never native capacity: that is presentation-scaled.
  local function townMarketSize(townId)
    return townDemand.marketSizeFromBuildings(townBuildingCount(townId))
  end

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
                ok, err = nativeCommandAuthority.send(
                  19, commandOrError, nil, "mod.world.town-development")
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
  local AUTO_REGISTER_VEHICLE_TARGET_KINDS = { ["vehicle.replace"] = true }

  function binding.autoRegisterLine(state, transaction, outputCid, deps)
    if type(transaction) ~= "table" then return end
    local field = AUTO_REGISTER_KINDS[transaction.kind]
    if not field and not AUTO_REGISTER_VEHICLE_TARGET_KINDS[transaction.kind] then return end
    local data = transaction.data or {}
    local lineCid = field and data[field] or nil
    if AUTO_REGISTER_VEHICLE_TARGET_KINDS[transaction.kind] then
      local vehicle = state.canonical.byCanonical[data.targetCid]
      lineCid = vehicle and vehicle.metadata and vehicle.metadata.lineCid or nil
    end
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

  -- A loaded match may already have complete, assigned lines and therefore
  -- never produce the operation which normally triggers registration.  Run
  -- this only after the initial structural checkpoint has converged.  Each
  -- peer queues facts solely for its own company; the ordinary ordered
  -- line.register path remains the sole author of portable market data.
  function binding.autoRegisterExistingServices(state, deps)
    local companyCid = deps.activeCompany()
    if not companyCid then return 0 end
    local queued, skipped, failed = 0, 0, 0
    local lines = state.probes and state.probes.structural
      and state.probes.structural.lines or {}
    for _, line in ipairs(lines) do
      local eligible = line.owner == companyCid
        and type(line.cid) == "string"
        and type(line.stops) == "table" and #line.stops >= 2
        and (tonumber(line.vehicles) or 0) > 0
        and resolveLocal(state.canonical, line.cid) ~= nil
      if eligible then
        local called, accepted, result = pcall(deps.submit, {
          type = "line.register", lineCid = line.cid, companyCid = companyCid,
        })
        if called and accepted == true then
          queued = queued + 1
        else
          failed = failed + 1
          if deps.log then
            deps.log("existing-service-register-failed", {
              companyCid = companyCid, lineCid = line.cid,
              error = tostring(called and result or accepted),
              reason = tostring(deps.reason or "initial-checkpoint"),
              tick = state.tick,
            })
          end
        end
      else
        skipped = skipped + 1
      end
    end
    if deps.log then
      deps.log("existing-service-register-scan", {
        companyCid = companyCid, queued = queued, skipped = skipped, failed = failed,
        reason = tostring(deps.reason or "initial-checkpoint"), tick = state.tick,
      })
    end
    return queued, { queued = queued, skipped = skipped, failed = failed }
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
      if made then
        ok, err = nativeCommandAuthority.send(
          20, commandOrError, nil, "mod.world.town-growth")
      end
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

  local function consistModelNames(vehicleId)
    local componentOk, transportVehicle = pcall(api.engine.getComponent,
      vehicleId, api.type.ComponentType.TRANSPORT_VEHICLE)
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

  -- Classify every assigned consist, not one representative vehicle. This
  -- prevents a passenger-first mixed fleet from smuggling freight capacity
  -- into the passenger economy and gives heterogeneous fleets average seats
  -- plus their conservative slowest speed.
  local function lineConsistTransportFacts(registry, vehicleIds)
    local consists, cargoCapacityByVehicleCid = {}, {}
    local walked = pcall(function()
      for _, vehicleId in ipairs(vehicleIds) do
        local names = consistModelNames(vehicleId)
        local facts = names and vehicleResourceFacts.consist(names) or nil
        if not facts then error("unreadable consist") end
        consists[#consists + 1] = facts
        local vehicleCid = resolveCanonical(registry, "vehicle", vehicleId)
        if vehicleCid then
          cargoCapacityByVehicleCid[vehicleCid] = util.deepCopy(
            facts.cargoCapacityByType or {})
        end
      end
    end)
    if not walked then return nil end
    local combined = vehicleResourceFacts.combine(consists)
    if combined then
      combined.cargoCapacityByVehicleCid = cargoCapacityByVehicleCid
    end
    return combined
  end

  local function nativeAnnualMaintenanceCents(vehicleId)
    local types = api and api.type and api.type.ComponentType or {}
    if not (types.MAINTENANCE_COST and api and api.engine
      and api.engine.getComponent) then return nil end
    local ok, component = pcall(
      api.engine.getComponent, vehicleId, types.MAINTENANCE_COST)
    local dollars = ok and component and tonumber(component.maintenanceCost) or nil
    if not dollars or dollars < 0 then return nil end
    return math.max(0, util.integer(dollars, 0)) * 100
  end

  local function lineVehicleEconomyFacts(registry, economyModule, economyState,
      vehicleIds, companyCid)
    local annualVehicleUpkeepCents, pricedVehicles, vehicleCids = 0, 0, {}
    for _, vehicleId in ipairs(vehicleIds) do
      local vehicleCid = resolveCanonical(registry, "vehicle", vehicleId)
      if vehicleCid then vehicleCids[#vehicleCids + 1] = vehicleCid end
      local vehicleBinding = vehicleCid and registry.byCanonical[vehicleCid] or nil
      local annual = vehicleBinding and vehicleBinding.metadata
        and tonumber(vehicleBinding.metadata.annualVehicleUpkeepCents) or nil
      if annual == nil and vehicleBinding then
        annual = nativeAnnualMaintenanceCents(vehicleId)
        if annual ~= nil then
          vehicleBinding.metadata = vehicleBinding.metadata or {}
          vehicleBinding.metadata.annualVehicleUpkeepCents = annual
          vehicleBinding.metadata.nativeAnnualMaintenanceDollars = math.floor(annual / 100)
          vehicleBinding.metadata.vehicleCostSource = "line-registration-native-maintenance"
        end
      end
      if annual then
        annualVehicleUpkeepCents = annualVehicleUpkeepCents
          + math.max(0, util.integer(annual, 0))
        pricedVehicles = pricedVehicles + 1
        if vehicleCid and not (economyState.vehicleCosts
          and economyState.vehicleCosts[vehicleCid]) then
          economyModule.upsertVehicleCost(
            economyState, vehicleCid, companyCid, annual)
        end
      end
    end
    table.sort(vehicleCids)
    return annualVehicleUpkeepCents, pricedVehicles, vehicleCids
  end

  -- Journey, headway, and hourly seat capacity from canonical geometry
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
    -- headway already divides the complete cycle by the number of consists,
    -- so departures is the fleet-wide departure count. Multiplying by runs a
    -- second time would make capacity scale quadratically (two trains = four
    -- times the seats), rewarding fleet spam instead of real frequency.
    local departures = math.max(1,
      math.floor(constants.capacityWindowSeconds / headway))
    return {
      distanceMeters = routeMeters,
      journeySeconds = journey,
      headwaySeconds = headway,
      -- A cycle serves the corridor once in each direction. Demand is pooled
      -- across both directions, so hourly capacity must include both legs.
      capacity = runs > 0 and (seats * departures * 2) or 0,
      seatsPerVehicle = seats,
      topSpeedKmh = math.floor(speedMs * 3.6 + 0.5),
      cruiseSpeedKmh = math.floor(cruiseMs * 3.6 + 0.5),
      cycleSeconds = cycle,
      departuresPerHourPerDirection = runs > 0 and departures or 0,
      defaultedSpeed = defaultedSpeed,
      defaultedSeats = defaultedSeats,
    }
  end

  function binding.makeLineService(
      registry, economyModule, economyState, lineId, companyCid, worldState)
    local lineCid, err = bindExisting(registry, lineId, "line", { name = nameOf(lineId) })
    if not lineCid then return false, err end
    local groups = lineStopGroups(lineId)
    if #groups < 2 then return false, "line needs at least two station groups" end
    local stationKind, stationKindDetail = lineServiceKind(lineId)
    local vehicleIds = lineVehicleIds(lineId)
    local vehicles = #vehicleIds
    local consistFacts = lineConsistTransportFacts(registry, vehicleIds)
    local consistKind = consistFacts and consistFacts.kind or "empty"
    if stationKind == "mixed" or consistKind == "mixed" then
      return false, "mixed passenger/cargo service is not authoritative yet"
    end
    if consistKind == "unknown" then
      return false, "consist cargo type is not safely readable"
    end
    if vehicles > 0 and not consistFacts then
      return false, "assigned consist resources are not safely readable"
    end
    if vehicles > 0 and consistKind == "empty" then
      return false, "assigned consists have no readable transport capacity"
    end
    local cargoService = stationKind == "cargo" or consistKind == "cargo"
    if cargoService and (stationKind ~= "cargo" or consistKind ~= "cargo") then
      return false, "cargo station mode and assigned consist type do not match"
    end
    if not cargoService and stationKind ~= "passenger" then
      return false, "line stop mode is not safely readable ("
        .. tostring(stationKindDetail or stationKind) .. ")"
    end

    local annualVehicleUpkeepCents, pricedVehicles, vehicleCids =
      lineVehicleEconomyFacts(
        registry, economyModule, economyState, vehicleIds, companyCid)
    local stationGroupCids = {}
    for _, groupId in ipairs(groups) do
      local groupCid = bindExisting(
        registry, groupId, "station_group", { name = nameOf(groupId) })
      if groupCid then stationGroupCids[#stationGroupCids + 1] = groupCid end
    end
    if #stationGroupCids ~= #groups then
      return false, "one or more line stops have no canonical station-group binding"
    end
    local computed = binding.computedServiceFacts(groups, vehicles, consistFacts)
    if cargoService then
      if not computed then return false, "cargo route geometry is not safely readable" end
      return freightServiceBinding.register({
        registry = registry, economyModule = economyModule,
        economyState = economyState, worldState = worldState,
        lineId = lineId, lineCid = lineCid, companyCid = companyCid,
        groups = groups, stationGroupCids = stationGroupCids,
        vehicleIds = vehicleIds, vehicleCids = vehicleCids,
        vehicles = vehicles, consistFacts = consistFacts, computed = computed,
        annualVehicleUpkeepCents = annualVehicleUpkeepCents,
        pricedVehicles = pricedVehicles,
        resolveLocal = resolveLocal, positionOfEntity = positionOfEntity,
        nameOf = nameOf,
      })
    end
    local townA, townAError = stationGroupTown(groups[1])
    local townB, townBError = stationGroupTown(groups[#groups])
    if not townA or not townB then
      local detail = "first: " .. tostring(townAError or townA)
        .. "; last: " .. tostring(townBError or townB)
      return false, "line endpoints do not map to readable towns (" .. detail .. ")"
    end
    local townCidA = bindExisting(registry, townA, "town", { name = nameOf(townA) })
    local townCidB = bindExisting(registry, townB, "town", { name = nameOf(townB) })
    if not townCidA or not townCidB then
      return false, "one or more endpoint towns have no canonical binding"
    end
    local localPassenger = townCidA == townCidB
    local first, second = townCidA, townCidB
    if second < first then first, second = second, first end
    local marketCid = localPassenger
      and ("market:local:" .. hash.value({ first }))
      or ("market:" .. hash.value({ first, second }))

    local capacityA = townMarketSize(townA)
    local capacityB = townMarketSize(townB)
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
    if existingMarket then
      local metadata = existingMarket.metadata or {}
      local priorNetwork = math.max(0, util.integer(metadata.networkDemand, 0))
      local priorDirect = math.max(0, util.integer(metadata.directDemand,
        math.max(0, util.integer(existingMarket.demand, 0) - priorNetwork)))
      demand = math.max(priorDirect, demand)
    end
    economyModule.upsertMarket(economyState, {
      cid = marketCid,
      name = localPassenger and (nameOf(townA) .. " local passenger market")
        or (nameOf(townA) .. " ↔ " .. nameOf(townB)),
      kind = existingMarket and existingMarket.kind or "passenger",
      demand = demand,
      metadata = {
        townA = townCidA, townB = townCidB,
        townSizeA = capacityA, townSizeB = capacityB,
        corridorMeters = corridorMeters,
        marketScope = localPassenger and "local" or "corridor",
        directDemand = demand,
        networkDemand = existingMarket and existingMarket.metadata
          and util.integer(existingMarket.metadata.networkDemand, 0) or 0,
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
      -- The legacy estimate is a presentation fallback, never rolling stock.
      -- Preserve the same zero-vehicle invariant as computedServiceFacts or
      -- an unreadable route could earn forever with no physical vehicle.
      capacity = vehicles > 0
        and math.max(50, nativeRate > 0 and util.integer(nativeRate) or vehicles * 100)
        or 0
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
      fareCents = previous and previous.fareCents
        or revenue.defaultFareCents(computed and computed.distanceMeters, "passenger"),
      capacity = capacity,
      quality = math.max(20, 120 - math.max(0, #groups - 2) * 10),
      annualVehicleUpkeepCents = annualVehicleUpkeepCents,
      metadata = {
        vehicleCount = vehicles,
        carrier = consistFacts and consistFacts.carrier or nil,
        marketScope = localPassenger and "local" or "corridor",
        factsSource = factsSource,
        distanceMeters = computed and computed.distanceMeters or nil,
        seatsPerVehicle = computed and computed.seatsPerVehicle or nil,
        topSpeedKmh = computed and computed.topSpeedKmh or nil,
        cruiseSpeedKmh = computed and computed.cruiseSpeedKmh or nil,
        cycleSeconds = computed and computed.cycleSeconds or nil,
        departuresPerHourPerDirection = computed
          and computed.departuresPerHourPerDirection or nil,
        endpointTownCids = { townCidA, townCidB },
        stationGroupCids = stationGroupCids,
        vehicleCids = vehicleCids,
        pricedVehicleCount = pricedVehicles,
        vehicleUpkeepCoverageComplete = pricedVehicles == vehicles,
      },
    })
    local network = multihopNetwork.rebuildPassenger(economyState)
    return true, {
      lineCid = lineCid, marketCid = marketCid, townA = townCidA, townB = townCidB,
      vehicleCount = vehicles, factsSource = factsSource,
      carrier = consistFacts and consistFacts.carrier or nil,
      marketScope = localPassenger and "local" or "corridor",
      networkRouteCount = network.routeCount,
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
    local interval = economyState.scheduler and economyState.scheduler.epochSeconds
      or constants.accountingIntervalSeconds
    local headway = math.min(service.headwaySeconds or interval, interval)
    -- A corridor's passengers board once and alight once, so a line's load
    -- distributes across its stops rather than appearing whole at each one.
    -- Summing the raw allocation per stop would report a 5-stop line as
    -- five times its real traffic and rank halts like termini.
    local stops = service.metadata and service.metadata.stationGroupCids or {}
    local perStop = #stops > 0 and math.floor(allocated / #stops) or 0
    local waiting = math.floor(perStop * headway / interval)
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
