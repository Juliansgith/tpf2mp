local util = require "tpf2_mp/util"
local hash = require "tpf2_mp/hash"
local revenue = require "tpf2_mp/economy_revenue"

local M = {}

M.SCHEMA_VERSION = 1
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

local function candidateKey(value)
  return table.concat({ value.sourceIndustryCid, value.destinationIndustryCid,
    value.cargoType, tostring(value.destinationStockIndex),
    tostring(value.sourceStopIndex) }, "|")
end

local function orientation(freightState, groups, sourceIndex, destinationIndex, accepted, deps)
  local sourcePosition = deps.positionOfEntity(groups[sourceIndex + 1])
  local destinationPosition = deps.positionOfEntity(groups[destinationIndex + 1])
  if not sourcePosition or not destinationPosition then return {} end
  local sources = sourceRows(freightState, accepted, groups[sourceIndex + 1], sourcePosition, deps)
  local destinations = destinationRows(
    freightState, groups[destinationIndex + 1], destinationPosition, deps)
  local result = {}
  for _, source in ipairs(sources) do
    for _, destination in ipairs(destinations) do
      if source.cid ~= destination.cid and source.cargoType == destination.cargoType then
        result[#result + 1] = {
          schemaVersion = M.SCHEMA_VERSION,
          sourceIndustryCid = source.cid,
          destinationIndustryCid = destination.cid,
          destinationStockIndex = destination.stockIndex,
          cargoType = source.cargoType,
          sourceStationGroupCid = deps.stationGroupCids[sourceIndex + 1],
          destinationStationGroupCid = deps.stationGroupCids[destinationIndex + 1],
          sourceStopIndex = sourceIndex,
          destinationStopIndex = destinationIndex,
          sourceCatchmentMeters = source.distance,
          destinationCatchmentMeters = destination.distance,
          sourceRatePerHour = source.outputRate,
          destinationRatePerHour = destination.inputRate,
          vehicleCapacity = source.vehicleCapacity,
          score = source.distance + destination.distance,
        }
      end
    end
  end
  return result
end

local function chooseContract(freightState, groups, accepted, deps)
  local candidates = orientation(freightState, groups, 0, #groups - 1, accepted, deps)
  for _, candidate in ipairs(orientation(
      freightState, groups, #groups - 1, 0, accepted, deps)) do
    candidates[#candidates + 1] = candidate
  end
  table.sort(candidates, function(a, b)
    if a.score ~= b.score then return a.score < b.score end
    return candidateKey(a) < candidateKey(b)
  end)
  if #candidates == 0 then
    return nil, "cargo endpoints have no compatible source/destination industries within "
      .. tostring(M.CATCHMENT_METERS) .. " m"
  end
  local selected = util.deepCopy(candidates[1])
  selected.score = nil
  selected.contractDigest = hash.value({
    schemaVersion = selected.schemaVersion,
    sourceIndustryCid = selected.sourceIndustryCid,
    destinationIndustryCid = selected.destinationIndustryCid,
    destinationStockIndex = selected.destinationStockIndex,
    cargoType = selected.cargoType,
    sourceStationGroupCid = selected.sourceStationGroupCid,
    destinationStationGroupCid = selected.destinationStationGroupCid,
    sourceStopIndex = selected.sourceStopIndex,
    destinationStopIndex = selected.destinationStopIndex,
  })
  return selected, #candidates
end

local function industryName(freightState, cid, deps)
  local localId = deps.resolveLocal(deps.registry, cid)
  local named = localId and deps.nameOf(localId) or nil
  if type(named) == "string" and named ~= "" then return named end
  local industry = freightState.industries and freightState.industries[cid] or nil
  return industry and industry.recipe and industry.recipe.resourceName or cid
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
  local contract, alternatives = chooseContract(
    freightState, params.groups, accepted, deps)
  if not contract then return false, alternatives end

  local marketCid = "market:freight:" .. hash.value({
    contract.sourceIndustryCid, contract.destinationIndustryCid,
    contract.cargoType, contract.destinationStockIndex,
  })
  local demand = math.max(1, math.min(
    contract.sourceRatePerHour, contract.destinationRatePerHour))
  local sourceName = industryName(freightState, contract.sourceIndustryCid, deps)
  local destinationName = industryName(freightState, contract.destinationIndustryCid, deps)
  local existingMarket = params.economyState.markets[marketCid]
  if existingMarket then demand = math.max(util.integer(existingMarket.demand, 0), demand) end
  params.economyModule.upsertMarket(params.economyState, {
    cid = marketCid,
    name = sourceName .. " -> " .. destinationName .. " (" .. contract.cargoType .. ")",
    kind = "cargo",
    demand = demand,
    metadata = {
      sourceIndustryCid = contract.sourceIndustryCid,
      destinationIndustryCid = contract.destinationIndustryCid,
      destinationStockIndex = contract.destinationStockIndex,
      cargoType = contract.cargoType,
      corridorMeters = params.computed and params.computed.distanceMeters or nil,
    },
  })

  local departures = params.computed
    and params.computed.departuresPerHourPerDirection or 0
  local exactCapacities, fleetCapacity = {}, 0
  for _, vehicleCid in ipairs(params.vehicleCids) do
    local capacity = math.max(0, util.integer(
      byVehicle[vehicleCid] and byVehicle[vehicleCid][contract.cargoType], 0))
    exactCapacities[vehicleCid] = capacity
    fleetCapacity = fleetCapacity + capacity
  end
  if fleetCapacity <= 0 then
    return false, "selected cargo contract has no exact assigned consist capacity"
  end
  local averageCapacity = math.floor(fleetCapacity / math.max(1, params.vehicles))
  local hourlyCapacity = params.vehicles > 0
    and math.floor(fleetCapacity * departures / params.vehicles) or 0
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
    capacity = hourlyCapacity,
    quality = math.max(20, 120 - math.max(0, #params.groups - 2) * 10),
    annualVehicleUpkeepCents = params.annualVehicleUpkeepCents,
    metadata = {
      freightContractSchema = M.SCHEMA_VERSION,
      freightContractDigest = contract.contractDigest,
      sourceIndustryCid = contract.sourceIndustryCid,
      destinationIndustryCid = contract.destinationIndustryCid,
      destinationStockIndex = contract.destinationStockIndex,
      cargoType = contract.cargoType,
      sourceStationGroupCid = contract.sourceStationGroupCid,
      destinationStationGroupCid = contract.destinationStationGroupCid,
      sourceStopIndex = contract.sourceStopIndex,
      destinationStopIndex = contract.destinationStopIndex,
      sourceCatchmentMeters = contract.sourceCatchmentMeters,
      destinationCatchmentMeters = contract.destinationCatchmentMeters,
      sourceRatePerHour = contract.sourceRatePerHour,
      destinationRatePerHour = contract.destinationRatePerHour,
      cargoCapacityPerVehicle = averageCapacity,
      cargoFleetCapacity = fleetCapacity,
      cargoCapacityByVehicleCid = exactCapacities,
      contractAlternatives = alternatives,
      vehicleCount = params.vehicles,
      carrier = params.consistFacts.carrier,
      factsSource = "computed-freight-contract",
      distanceMeters = params.computed.distanceMeters,
      topSpeedKmh = params.computed.topSpeedKmh,
      cruiseSpeedKmh = params.computed.cruiseSpeedKmh,
      cycleSeconds = params.computed.cycleSeconds,
      departuresPerHourPerDirection = departures,
      stationGroupCids = util.deepCopy(params.stationGroupCids),
      vehicleCids = util.deepCopy(params.vehicleCids),
      pricedVehicleCount = params.pricedVehicles,
      vehicleUpkeepCoverageComplete = params.pricedVehicles == params.vehicles,
    },
  })
  return true, {
    lineCid = params.lineCid,
    marketCid = marketCid,
    vehicleCount = params.vehicles,
    factsSource = "computed-freight-contract",
    cargoType = contract.cargoType,
    sourceIndustryCid = contract.sourceIndustryCid,
    destinationIndustryCid = contract.destinationIndustryCid,
    destinationStockIndex = contract.destinationStockIndex,
    contractDigest = contract.contractDigest,
  }
end

return M
