local util = require "tpf2_mp/util"
local hash = require "tpf2_mp/hash"
local revenue = require "tpf2_mp/economy_revenue"
local multihop = require "tpf2_mp/multihop_network"

local M = {}

M.SCHEMA_VERSION = 2
M.CATCHMENT_METERS = 500

local function positionDistance(from, to)
  if type(from) ~= "table" or type(to) ~= "table" then return nil end
  local dx = (tonumber(from[1]) or 0) - (tonumber(to[1]) or 0)
  local dy = (tonumber(from[2]) or 0) - (tonumber(to[2]) or 0)
  return math.floor(math.sqrt(dx * dx + dy * dy))
end

local function outputRate(industry, cargoType)
  local amount = 0
  for _, output in ipairs(industry.recipe and industry.recipe.outputs or {}) do
    if output.cargoType == cargoType then amount = amount + util.integer(output.amount, 0) end
  end
  return math.max(0, util.integer(industry.recipe and industry.recipe.capacity, 0) * amount)
end

local function inputRate(industry, stockIndex, cargoType)
  local largest = 0
  for _, alternative in ipairs(industry.recipe and industry.recipe.inputs or {}) do
    for _, requirement in ipairs(alternative) do
      if requirement.stockIndex == stockIndex and requirement.cargoType == cargoType then
        largest = math.max(largest, util.integer(requirement.amount, 0))
      end
    end
  end
  return math.max(0, util.integer(industry.recipe and industry.recipe.capacity, 0) * largest)
end

local function sourceRows(freightState, accepted, endpointId, endpointPosition, deps)
  local result = {}
  for _, cid in ipairs(util.sortedKeys(freightState.industries or {})) do
    local industry = freightState.industries[cid]
    local localId = deps.resolveLocal(deps.registry, cid)
    local distance = localId and positionDistance(endpointPosition, deps.positionOfEntity(localId))
    if distance and distance <= M.CATCHMENT_METERS then
      for _, output in ipairs(industry.recipe and industry.recipe.outputs or {}) do
        local cargoType = output.cargoType
        local capacity = math.max(0, util.integer(accepted[cargoType], 0))
        local rate = outputRate(industry, cargoType)
        if capacity > 0 and rate > 0 then
          result[#result + 1] = {
            cid = cid, localId = localId, endpointId = endpointId,
            cargoType = cargoType, distance = distance,
            outputRate = rate, vehicleCapacity = capacity,
          }
        end
      end
    end
  end
  return result
end

local function destinationRows(freightState, endpointId, endpointPosition, deps)
  local result = {}
  for _, cid in ipairs(util.sortedKeys(freightState.industries or {})) do
    local industry = freightState.industries[cid]
    local localId = deps.resolveLocal(deps.registry, cid)
    local distance = localId and positionDistance(endpointPosition, deps.positionOfEntity(localId))
    if distance and distance <= M.CATCHMENT_METERS then
      for _, stock in ipairs(industry.inputStock or {}) do
        local rate = inputRate(industry, stock.index, stock.cargoType)
        if rate > 0 then
          result[#result + 1] = {
            cid = cid, localId = localId, endpointId = endpointId,
            cargoType = stock.cargoType, stockIndex = stock.index,
            distance = distance, inputRate = rate,
          }
        end
      end
    end
  end
  return result
end

local function endpointFacts(freightState, groups, stationGroupCids, accepted, deps)
  local facts = {}
  for groupIndex = 1, #groups do
    local groupId = groups[groupIndex]
    local position = deps.positionOfEntity(groupId)
    if position then
      local sources, destinations = {}, {}
      for _, source in ipairs(sourceRows(
          freightState, accepted, groupId, position, deps)) do
        sources[#sources + 1] = {
          industryCid = source.cid, cargoType = source.cargoType,
          distanceMeters = source.distance, ratePerHour = source.outputRate,
        }
      end
      for _, destination in ipairs(destinationRows(
          freightState, groupId, position, deps)) do
        destinations[#destinations + 1] = {
          industryCid = destination.cid, cargoType = destination.cargoType,
          stockIndex = destination.stockIndex,
          distanceMeters = destination.distance,
          ratePerHour = destination.inputRate,
        }
      end
      table.sort(sources, function(a, b)
        return table.concat({ a.cargoType, a.industryCid }, "|")
          < table.concat({ b.cargoType, b.industryCid }, "|")
      end)
      table.sort(destinations, function(a, b)
        return table.concat({ a.cargoType, a.industryCid, tostring(a.stockIndex) }, "|")
          < table.concat({ b.cargoType, b.industryCid, tostring(b.stockIndex) }, "|")
      end)
      facts[#facts + 1] = {
        stationGroupCid = stationGroupCids[groupIndex],
        stopIndex = groupIndex - 1,
        sources = sources, destinations = destinations,
      }
    end
  end
  return facts
end

function M.register(params)
  local freightState = params.worldState and params.worldState.freightIndustry or nil
  if type(freightState) ~= "table" or freightState.ready ~= true then
    return false, "cargo service requires ready canonical freight industries"
  end
  local accepted = params.consistFacts and params.consistFacts.cargoCapacityByType or {}
  if next(accepted) == nil then
    return false, "assigned cargo consists expose no named portable cargo capacity"
  end
  local byVehicle = params.consistFacts.cargoCapacityByVehicleCid or {}
  if #params.vehicleCids ~= params.vehicles
      or util.tableCount(byVehicle) ~= params.vehicles then
    return false, "every assigned cargo consist requires a canonical capacity binding"
  end
  local deps = {
    registry = params.registry,
    stationGroupCids = params.stationGroupCids,
    resolveLocal = params.resolveLocal,
    positionOfEntity = params.positionOfEntity,
    nameOf = params.nameOf,
  }
  local facts = endpointFacts(freightState, params.groups,
    params.stationGroupCids, accepted, deps)
  local marketCid = "market:freight-leg:" .. hash.value({ params.lineCid })
  params.economyModule.upsertMarket(params.economyState, {
    cid = marketCid,
    name = params.nameOf(params.lineId) .. " cargo leg",
    kind = "cargo",
    demand = 0,
    metadata = {
      corridorMeters = params.computed and params.computed.distanceMeters or nil,
      networkStatus = "awaiting-compatible-path",
    },
  })

  local departures = params.computed
    and params.computed.departuresPerHourPerDirection or 0
  local exactCapacities, fleetCapacity = {}, 0
  for _, vehicleCid in ipairs(params.vehicleCids) do
    local capacities = {}
    for cargoType, capacity in pairs(byVehicle[vehicleCid] or {}) do
      capacities[cargoType] = math.max(0, util.integer(capacity, 0))
      fleetCapacity = fleetCapacity + capacities[cargoType]
    end
    exactCapacities[vehicleCid] = capacities
  end
  if fleetCapacity <= 0 then
    return false, "cargo line has no exact assigned consist capacity"
  end
  local hourlyCapacityByType, averageCapacityByType = {}, {}
  for cargoType in pairs(accepted) do
    local total = 0
    for _, vehicleCid in ipairs(params.vehicleCids) do
      total = total + math.max(0, util.integer(
        exactCapacities[vehicleCid] and exactCapacities[vehicleCid][cargoType], 0))
    end
    averageCapacityByType[cargoType] = math.floor(total / math.max(1, params.vehicles))
    hourlyCapacityByType[cargoType] = params.vehicles > 0
      and math.floor(total * departures / params.vehicles) or 0
  end
  local prior = params.economyState.services[params.lineCid]
  params.economyModule.upsertService(params.economyState, {
    lineCid = params.lineCid,
    marketCid = marketCid,
    companyCid = params.companyCid,
    name = params.nameOf(params.lineId),
    headwaySeconds = params.computed.headwaySeconds,
    journeySeconds = params.computed.journeySeconds,
    fareCents = prior and prior.fareCents
      or revenue.defaultFareCents(params.computed.distanceMeters, "cargo"),
    capacity = 0,
    quality = math.max(20, 120 - math.max(0, #params.groups - 2) * 10),
    annualVehicleUpkeepCents = params.annualVehicleUpkeepCents,
    metadata = {
      freightNetworkSchema = 1,
      cargoEndpointFacts = facts,
      cargoCapacityByType = util.deepCopy(accepted),
      cargoCapacityByVehicleCid = exactCapacities,
      cargoAverageCapacityByType = averageCapacityByType,
      cargoHourlyCapacityByType = hourlyCapacityByType,
      vehicleCount = params.vehicles,
      carrier = params.consistFacts.carrier,
      factsSource = "computed-cargo-network-leg",
      networkStatus = "awaiting-compatible-path",
      distanceMeters = params.computed.distanceMeters,
      topSpeedKmh = params.computed.topSpeedKmh,
      cruiseSpeedKmh = params.computed.cruiseSpeedKmh,
      cycleSeconds = params.computed.cycleSeconds,
      departuresPerHourPerDirection = departures,
      stationGroupCids = util.deepCopy(params.stationGroupCids),
      vehicleCids = util.deepCopy(params.vehicleCids),
      pricedVehicleCount = params.pricedVehicles,
      vehicleUpkeepCoverageComplete = params.pricedVehicles == params.vehicles,
      -- Once a route enters operation, its identity is part of three ledgers.
      -- Preserve the path pin through harmless re-registration (for example a
      -- consist/headway update); the network planner may only select that same
      -- path until the line itself is deleted and recreated.
      freightPinnedPathDigest = prior and prior.metadata
        and prior.metadata.freightPinnedPathDigest or nil,
    },
  })
  local network = multihop.rebuild(params.economyState)
  local registered = params.economyState.services[params.lineCid]
  local metadata = registered and registered.metadata or {}
  return true, {
    lineCid = params.lineCid,
    marketCid = marketCid,
    vehicleCount = params.vehicles,
    factsSource = metadata.factsSource or "computed-cargo-network-leg",
    networkStatus = metadata.networkStatus,
    cargoType = metadata.cargoType,
    sourceIndustryCid = metadata.sourceIndustryCid,
    destinationIndustryCid = metadata.destinationIndustryCid,
    destinationStockIndex = metadata.destinationStockIndex,
    contractDigest = metadata.freightContractDigest,
    pathDigest = metadata.freightPathDigest,
    legIndex = metadata.freightLegIndex,
    legCount = metadata.freightLegCount,
    network = network,
  }
end

return M
