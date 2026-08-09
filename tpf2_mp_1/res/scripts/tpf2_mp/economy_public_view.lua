local util = require "tpf2_mp/util"
local costs = require "tpf2_mp/economy_costs"
local difficulty = require "tpf2_mp/economy_difficulty"
local pendingDelivery = require "tpf2_mp/economy_pending_delivery"

local M = {}

local function resultServices(lastResults)
  local services, markets = {}, {}
  for marketCid, market in pairs(lastResults and lastResults.markets or {}) do
    markets[marketCid] = market
    for lineCid, service in pairs(market.services or {}) do
      services[lineCid] = service
    end
  end
  return services, markets
end

local function countParts(models)
  local count = 0
  for _ in pairs(type(models) == "table" and models or {}) do count = count + 1 end
  return count
end

function M.build(state, activeCompanyCid)
  local economyState = state.economy or {}
  local canonical = state.canonical and state.canonical.byCanonical or {}
  local lastResults = economyState.lastResults or {}
  local latestServices, latestMarkets = resultServices(lastResults)
  local intervalSeconds = math.max(60, util.integer(
    lastResults.intervalSeconds or (economyState.scheduler
      and economyState.scheduler.epochSeconds), 300))
  local hourlyFactor = 3600 / intervalSeconds
  local difficultyPreset = difficulty.preset(economyState.params
    and economyState.params.economyDifficulty)
  local result = {
    hoursPerYear = costs.HOURS_PER_YEAR,
    financialYearSeconds = costs.FINANCIAL_YEAR_SECONDS,
    intervalSeconds = intervalSeconds,
    activeCompanyCid = activeCompanyCid,
    economyDifficulty = difficultyPreset.key,
    economyDifficultyLabel = difficultyPreset.label,
    revenueMultiplierPpm = difficultyPreset.revenueMultiplierPpm,
    companies = util.deepCopy(lastResults.companies or {}),
    towns = util.deepCopy(economyState.towns or {}),
    services = {}, vehicles = {}, localLines = {}, localVehicles = {},
  }

  for _, lineCid in ipairs(util.sortedKeys(economyState.services or {})) do
    local service = economyState.services[lineCid]
    local latest = latestServices[lineCid] or {}
    local market = latestMarkets[service.marketCid] or {}
    local factors = latest.factors or {}
    local nonFareCents = math.max(0,
      (tonumber(factors.gcCents) or 0) - (tonumber(factors.fareCents) or 0))
    local metadata = service.metadata or {}
    local authoredMarket = economyState.markets and economyState.markets[service.marketCid] or {}
    local marketMetadata = authoredMarket.metadata or {}
    local townA = economyState.towns and economyState.towns[marketMetadata.townA] or {}
    local townB = economyState.towns and economyState.towns[marketMetadata.townB] or {}
    local pending = pendingDelivery.service(
      state, service, lineCid, difficultyPreset.revenueMultiplierPpm)
    local gross = latest.grossRevenueCents or latest.revenueCents or 0
    local upkeep = latest.vehicleUpkeepCents or 0
    local net = latest.netRevenueCents or latest.revenueCents or 0
    result.services[lineCid] = {
      lineCid = lineCid,
      companyCid = service.companyCid,
      marketCid = service.marketCid,
      kind = pending.kind,
      hourlyMarketDemand = authoredMarket.demand or market.hourlyDemand or market.demand or 0,
      modelTownSizeA = townA.size or marketMetadata.townSizeA,
      modelTownSizeB = townB.size or marketMetadata.townSizeB,
      name = service.name or lineCid,
      fareCents = service.fareCents or 0,
      journeySeconds = service.journeySeconds or 0,
      headwaySeconds = service.headwaySeconds or 0,
      capacity = service.capacity or 0,
      topSpeedKmh = metadata.topSpeedKmh,
      cruiseSpeedKmh = metadata.cruiseSpeedKmh,
      carrier = metadata.carrier,
      marketScope = metadata.marketScope or marketMetadata.marketScope,
      departuresPerHourPerDirection = metadata.departuresPerHourPerDirection,
      vehicleCount = metadata.vehicleCount or 0,
      factsSource = metadata.factsSource,
      allocated = latest.allocated or 0,
      delivered = latest.delivered or 0,
      availableCapacity = latest.availableCapacity or 0,
      pendingDelivered = pending.pendingDelivered,
      pendingGrossRevenueCents = pending.pendingGrossRevenueCents,
      pendingRawGrossRevenueCents = pending.pendingRawGrossRevenueCents,
      grossRevenueCents = gross,
      rawGrossRevenueCents = latest.rawGrossRevenueCents,
      revenueMultiplierPpm = difficultyPreset.revenueMultiplierPpm,
      vehicleUpkeepCents = upkeep,
      netRevenueCents = net,
      projectedHourlyGrossRevenueCents = math.floor(gross * hourlyFactor),
      projectedHourlyVehicleUpkeepCents = math.floor(upkeep * hourlyFactor),
      projectedHourlyNetRevenueCents = math.floor(net * hourlyFactor),
      sharePpm = latest.sharePpm or service.sharePpm or 0,
      equilibriumPpm = latest.equilibriumPpm or 0,
      generalizedCostCents = factors.gcCents,
      timeCostCents = factors.timeCostCents,
      waitCostCents = factors.waitCostCents,
      feederAccessCents = factors.feederAccessCents or 0,
      feederAccessEndpoints = factors.feederAccessEndpoints or 0,
      outsideCostCents = market.gcOutsideCents,
      -- This is not a hard recommended fare: it is the fare at which the
      -- service's current non-fare generalized cost reaches the outside option.
      fareAtOutsideParityCents = market.gcOutsideCents
        and math.max(0, market.gcOutsideCents - nonFareCents) or nil,
    }
    local company = result.companies[service.companyCid] or {
      companyCid = service.companyCid, demand = 0, revenueCents = 0,
      grossRevenueCents = 0, vehicleUpkeepCents = 0,
      infrastructureUpkeepCents = 0, netRevenueCents = 0,
    }
    company.pendingDelivered = (company.pendingDelivered or 0) + pending.pendingDelivered
    company.pendingGrossRevenueCents = (company.pendingGrossRevenueCents or 0)
      + pending.pendingGrossRevenueCents
    result.companies[service.companyCid] = company
  end

  for _, company in pairs(result.companies) do
    local gross = company.grossRevenueCents or company.revenueCents or 0
    local upkeep = company.vehicleUpkeepCents or 0
    local infrastructure = company.infrastructureUpkeepCents or 0
    local net = company.netRevenueCents or company.revenueCents or 0
    company.projectedHourlyGrossRevenueCents = math.floor(gross * hourlyFactor)
    company.projectedHourlyVehicleUpkeepCents = math.floor(upkeep * hourlyFactor)
    company.projectedHourlyInfrastructureUpkeepCents = math.floor(infrastructure * hourlyFactor)
    company.projectedHourlyNetRevenueCents = math.floor(net * hourlyFactor)
  end

  for cid, binding in pairs(canonical) do
    local localId = tonumber(binding.localId)
    if binding.kind == "line" and localId then
      result.localLines[tostring(localId)] = cid
    elseif binding.kind == "vehicle" then
      local cost = economyState.vehicleCosts and economyState.vehicleCosts[cid] or nil
      local metadata = binding.metadata or {}
      local lineCid = metadata.lineCid
      local item = {
        vehicleCid = cid,
        companyCid = cost and cost.companyCid or metadata.owner,
        localId = localId,
        lineCid = lineCid,
        purchasePriceDollars = metadata.purchasePriceDollars,
        annualVehicleUpkeepCents = cost and cost.annualVehicleUpkeepCents
          or metadata.annualVehicleUpkeepCents,
        nativeAnnualMaintenanceDollars = metadata.nativeAnnualMaintenanceDollars,
        costSource = metadata.vehicleCostSource,
        modelPartCount = countParts(metadata.models),
      }
      if item.annualVehicleUpkeepCents then
        item.intervalVehicleUpkeepCents = costs.periodCharge(
          item.annualVehicleUpkeepCents, 0, intervalSeconds)
        item.projectedHourlyVehicleUpkeepCents = math.floor(
          item.annualVehicleUpkeepCents * 3600 / costs.FINANCIAL_YEAR_SECONDS)
      end
      item.line = lineCid and util.deepCopy(result.services[lineCid]) or nil
      result.vehicles[cid] = item
      if localId then result.localVehicles[tostring(localId)] = cid end
    end
  end
  return result
end

return M
