local util = require "tpf2_mp/util"

local M = {}

local function copyInteger(value, fallback, low, high)
  local number = util.integer(value, fallback)
  if low then number = math.max(low, number) end
  if high then number = math.min(high, number) end
  return number
end

function M.newState()
  return {
    version = 1,
    epoch = 0,
    markets = {},
    services = {},
    lastResults = { markets = {}, companies = {}, totalDemand = 0, totalRevenueCents = 0 },
    ledger = {
      settledEpochs = {},
      companies = {},
      settlementCount = 0,
      totalDemand = 0,
      totalRevenueCents = 0,
    },
  }
end

function M.upsertMarket(state, market)
  assert(type(market.cid) == "string" and market.cid ~= "", "market cid required")
  state.markets[market.cid] = {
    cid = market.cid,
    name = tostring(market.name or market.cid),
    demand = copyInteger(market.demand, 100, 0, 1000000000),
    outsideWeight = copyInteger(market.outsideWeight, 2500, 1, 1000000000),
    metadata = util.deepCopy(market.metadata or {}),
  }
  return state.markets[market.cid]
end

function M.upsertService(state, service)
  assert(type(service.lineCid) == "string" and service.lineCid ~= "", "lineCid required")
  assert(type(service.marketCid) == "string" and state.markets[service.marketCid], "known marketCid required")
  assert(type(service.companyCid) == "string" and service.companyCid ~= "", "companyCid required")
  state.services[service.lineCid] = {
    lineCid = service.lineCid,
    marketCid = service.marketCid,
    companyCid = service.companyCid,
    name = tostring(service.name or service.lineCid),
    headwaySeconds = copyInteger(service.headwaySeconds, 1800, 30, 86400),
    journeySeconds = copyInteger(service.journeySeconds, 3600, 30, 604800),
    fareCents = copyInteger(service.fareCents, 1000, 0, 100000000),
    capacity = copyInteger(service.capacity, 100, 0, 1000000000),
    quality = copyInteger(service.quality, 100, 0, 1000),
    enabled = service.enabled ~= false,
    metadata = util.deepCopy(service.metadata or {}),
  }
  return state.services[service.lineCid]
end

function M.removeService(state, lineCid)
  state.services[lineCid] = nil
end

function M.setFare(state, lineCid, fareCents)
  local service = state.services[lineCid]
  if not service then return false, "unknown service" end
  service.fareCents = copyInteger(fareCents, service.fareCents, 0, 100000000)
  return true, service.fareCents
end

function M.attractiveness(service)
  local frequency = math.floor(3600000 / math.max(30, service.headwaySeconds))
  local journey = math.floor(7200000 / math.max(30, service.journeySeconds))
  local quality = service.quality * 25
  local farePenalty = service.fareCents * 2
  local weight = 100 + frequency + journey + quality - farePenalty
  return util.clamp(weight, 1, 1000000000), {
    frequency = frequency,
    journey = journey,
    quality = quality,
    farePenalty = farePenalty,
  }
end

local function proportional(total, items)
  local sumWeight = 0
  for _, item in ipairs(items) do sumWeight = sumWeight + item.weight end
  local allocations, ranked, used = {}, {}, 0
  if total <= 0 or sumWeight <= 0 then return allocations end

  for _, item in ipairs(items) do
    local numerator = total * item.weight
    local base = math.floor(numerator / sumWeight)
    allocations[item.cid] = base
    used = used + base
    ranked[#ranked + 1] = { cid = item.cid, remainder = numerator % sumWeight }
  end

  table.sort(ranked, function(a, b)
    if a.remainder == b.remainder then return a.cid < b.cid end
    return a.remainder > b.remainder
  end)
  local remainder = total - used
  for index = 1, remainder do
    local cid = ranked[((index - 1) % #ranked) + 1].cid
    allocations[cid] = allocations[cid] + 1
  end
  return allocations
end

local function marketServices(state, marketCid)
  local services = {}
  for _, lineCid in ipairs(util.sortedKeys(state.services)) do
    local service = state.services[lineCid]
    if service.enabled and service.marketCid == marketCid then
      local weight, factors = M.attractiveness(service)
      services[#services + 1] = { service = service, cid = lineCid, weight = weight, factors = factors }
    end
  end
  return services
end

function M.evaluateMarket(state, marketCid)
  local market = state.markets[marketCid]
  if not market then return nil, "unknown market" end
  local services = marketServices(state, marketCid)
  local active, allocations = {}, {}
  for _, option in ipairs(services) do active[#active + 1] = option end

  local remaining = market.demand
  while remaining > 0 and #active > 0 do
    local previewItems = { { cid = "~outside", weight = market.outsideWeight } }
    for _, option in ipairs(active) do previewItems[#previewItems + 1] = { cid = option.cid, weight = option.weight } end
    local preview = proportional(remaining, previewItems)
    local capped, survivors = {}, {}
    for _, option in ipairs(active) do
      local cap = option.service.capacity
      if (preview[option.cid] or 0) > cap then capped[#capped + 1] = option else survivors[#survivors + 1] = option end
    end
    if #capped == 0 then
      for cid, amount in pairs(preview) do allocations[cid] = (allocations[cid] or 0) + amount end
      remaining = 0
    else
      for _, option in ipairs(capped) do
        allocations[option.cid] = option.service.capacity
        remaining = remaining - option.service.capacity
      end
      active = survivors
    end
  end
  if remaining > 0 then allocations["~outside"] = (allocations["~outside"] or 0) + remaining end

  local result = {
    marketCid = marketCid,
    name = market.name,
    demand = market.demand,
    outside = allocations["~outside"] or 0,
    services = {},
  }
  for _, option in ipairs(services) do
    local amount = allocations[option.cid] or 0
    result.services[option.cid] = {
      lineCid = option.cid,
      companyCid = option.service.companyCid,
      name = option.service.name,
      allocated = amount,
      capacity = option.service.capacity,
      fareCents = option.service.fareCents,
      revenueCents = amount * option.service.fareCents,
      shareBasisPoints = market.demand > 0 and math.floor(amount * 10000 / market.demand) or 0,
      weight = option.weight,
      factors = option.factors,
    }
  end
  return result
end

function M.evaluateAll(state)
  local results = { markets = {}, companies = {}, totalDemand = 0, totalRevenueCents = 0 }
  for _, marketCid in ipairs(util.sortedKeys(state.markets)) do
    local result = assert(M.evaluateMarket(state, marketCid))
    results.markets[marketCid] = result
    results.totalDemand = results.totalDemand + result.demand
    for _, lineCid in ipairs(util.sortedKeys(result.services)) do
      local service = result.services[lineCid]
      local company = results.companies[service.companyCid] or { companyCid = service.companyCid, demand = 0, revenueCents = 0 }
      company.demand = company.demand + service.allocated
      company.revenueCents = company.revenueCents + service.revenueCents
      results.companies[service.companyCid] = company
      results.totalRevenueCents = results.totalRevenueCents + service.revenueCents
    end
  end
  state.epoch = (state.epoch or 0) + 1
  results.epoch = state.epoch
  state.lastResults = results
  return results
end

function M.acceptAuthoritativeResults(state, results)
  if type(results) ~= "table" or type(results.markets) ~= "table" or type(results.companies) ~= "table" then
    return false, "authoritative results are malformed"
  end
  if tonumber(results.epoch) ~= (state.epoch or 0) + 1 then
    return false, "authoritative epoch is not the next epoch"
  end
  if util.tableCount(results.markets) ~= util.tableCount(state.markets) then
    return false, "authoritative market count mismatch"
  end
  local companyTotals, totalDemand, totalRevenue = {}, 0, 0
  for _, marketCid in ipairs(util.sortedKeys(state.markets)) do
    local market = state.markets[marketCid]
    local result = results.markets[marketCid]
    if type(result) ~= "table" or tonumber(result.demand) ~= market.demand then
      return false, "authoritative market mismatch: " .. marketCid
    end
    local allocated = tonumber(result.outside) or 0
    for _, lineCid in ipairs(util.sortedKeys(result.services or {})) do
      local serviceResult = result.services[lineCid]
      local service = state.services[lineCid]
      if not service or service.marketCid ~= marketCid or service.companyCid ~= serviceResult.companyCid then
        return false, "authoritative service mismatch: " .. tostring(lineCid)
      end
      if tonumber(serviceResult.fareCents) ~= service.fareCents then
        return false, "authoritative fare mismatch: " .. tostring(lineCid)
      end
      local amount = util.integer(serviceResult.allocated, -1)
      if amount < 0 or amount > service.capacity then return false, "authoritative allocation outside capacity" end
      if tonumber(serviceResult.revenueCents) ~= amount * service.fareCents then
        return false, "authoritative revenue mismatch: " .. tostring(lineCid)
      end
      allocated = allocated + amount
      totalRevenue = totalRevenue + serviceResult.revenueCents
      local company = companyTotals[service.companyCid] or { companyCid = service.companyCid, demand = 0, revenueCents = 0 }
      company.demand = company.demand + amount
      company.revenueCents = company.revenueCents + serviceResult.revenueCents
      companyTotals[service.companyCid] = company
    end
    if allocated ~= market.demand then return false, "authoritative demand is not conserved: " .. marketCid end
    totalDemand = totalDemand + market.demand
  end
  if tonumber(results.totalDemand) ~= totalDemand or tonumber(results.totalRevenueCents) ~= totalRevenue then
    return false, "authoritative totals mismatch"
  end
  for _, companyCid in ipairs(util.sortedKeys(companyTotals)) do
    local expected, actual = companyTotals[companyCid], results.companies[companyCid]
    if not actual or tonumber(actual.demand) ~= expected.demand or tonumber(actual.revenueCents) ~= expected.revenueCents then
      return false, "authoritative company totals mismatch: " .. companyCid
    end
  end
  state.epoch = results.epoch
  state.lastResults = util.deepCopy(results)
  return true, state.lastResults
end

function M.recordSettlement(state, results)
  state.ledger = state.ledger or {
    settledEpochs = {}, companies = {}, settlementCount = 0, totalDemand = 0, totalRevenueCents = 0,
  }
  state.ledger.settledEpochs = state.ledger.settledEpochs or {}
  local epoch = assert(tonumber(results.epoch), "results epoch required")
  local epochKey = tostring(epoch)
  if state.ledger.settledEpochs[epochKey] then return false, "epoch already settled" end
  state.ledger.settledEpochs[epochKey] = true
  state.ledger.settlementCount = (state.ledger.settlementCount or 0) + 1
  state.ledger.totalDemand = (state.ledger.totalDemand or 0) + (results.totalDemand or 0)
  state.ledger.totalRevenueCents = (state.ledger.totalRevenueCents or 0) + (results.totalRevenueCents or 0)
  state.ledger.companies = state.ledger.companies or {}
  for _, companyCid in ipairs(util.sortedKeys(results.companies or {})) do
    local result = results.companies[companyCid]
    local total = state.ledger.companies[companyCid] or {
      companyCid = companyCid, demand = 0, revenueCents = 0, wins = 0,
    }
    total.demand = total.demand + (result.demand or 0)
    total.revenueCents = total.revenueCents + (result.revenueCents or 0)
    state.ledger.companies[companyCid] = total
  end
  for _, market in pairs(results.markets or {}) do
    local bestCompany, bestDemand = nil, -1
    for _, service in pairs(market.services or {}) do
      if service.allocated > bestDemand or (service.allocated == bestDemand and service.companyCid < (bestCompany or "~")) then
        bestCompany, bestDemand = service.companyCid, service.allocated
      end
    end
    if bestCompany and state.ledger.companies[bestCompany] then
      state.ledger.companies[bestCompany].wins = (state.ledger.companies[bestCompany].wins or 0) + 1
    end
  end
  return true, state.ledger
end

function M.scoreboard(state, companies)
  local marketsByCompany, linesByCompany = {}, {}
  for _, service in pairs(state.services or {}) do
    if service.enabled then
      linesByCompany[service.companyCid] = (linesByCompany[service.companyCid] or 0) + 1
      marketsByCompany[service.companyCid] = marketsByCompany[service.companyCid] or {}
      marketsByCompany[service.companyCid][service.marketCid] = true
    end
  end
  local result = {}
  for _, companyCid in ipairs(util.sortedKeys(companies or {})) do
    local totals = state.ledger and state.ledger.companies and state.ledger.companies[companyCid] or {}
    local reach = util.tableCount(marketsByCompany[companyCid])
    local lines = linesByCompany[companyCid] or 0
    local revenue = totals.revenueCents or 0
    local demand = totals.demand or 0
    result[companyCid] = {
      companyCid = companyCid,
      name = companies[companyCid].name or companyCid,
      settledDemand = demand,
      settledRevenueCents = revenue,
      marketsReached = reach,
      activeLines = lines,
      marketWins = totals.wins or 0,
      modelValueCents = revenue * 10 + demand * 100 + reach * 500000 + lines * 250000,
    }
  end
  return result
end

return M
