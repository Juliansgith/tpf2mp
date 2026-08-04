local util = require "tpf2_mp/util"
local hash = require "tpf2_mp/hash"

local M = {}

M.VERSION = 4

-- Market kinds share one evaluator; only the cents weighting differs. Cargo
-- barely minds waiting (inventory, not a person on a platform), pays heavily
-- for transshipment, values time far below passengers, and competes against
-- trucking rather than staying home.
M.MARKET_KINDS = {
  passenger = {
    waitWeightPm = 2000,
    transferSeconds = 480,
    votCentsPerHour = 450,
    gcOutsideCents = 2500,
  },
  cargo = {
    waitWeightPm = 1000,
    transferSeconds = 1800,
    votCentsPerHour = 60,
    gcOutsideCents = 1800,
  },
}
M.SHARE_SCALE = 1000000
-- Lua 5.1 stores every number as an IEEE-754 double. Keep authored aggregate
-- values well below 2^53 so the Python replayer cannot retain precision that
-- the game has already lost. This is $10 trillion and unreachable in normal
-- play, but the public input clamps permit adversarial larger products.
M.ACCUMULATOR_LIMIT = 1000000000000000

-- EXP_TABLE[k + 1] = round(65536 * exp(-k / 10)) for k = 0..80. Pinned source
-- literals shared byte-for-byte with the companion replayer: both languages
-- must interpolate the same table, never a platform libm.
local EXP_TABLE = {
  65536, 59299, 53656, 48550, 43930, 39750, 35967, 32544, 29447,
  26645, 24109, 21815, 19739, 17861, 16161, 14623, 13231, 11972,
  10833, 9802, 8869, 8025, 7262, 6571, 5945, 5380, 4868,
  4404, 3985, 3606, 3263, 2952, 2671, 2417, 2187, 1979,
  1791, 1620, 1466, 1327, 1200, 1086, 983, 889, 805,
  728, 659, 596, 539, 488, 442, 400, 362, 327,
  296, 268, 242, 219, 198, 180, 162, 147, 133,
  120, 109, 99, 89, 81, 73, 66, 60, 54,
  49, 44, 40, 36, 33, 30, 27, 24, 22,
}

local function copyInteger(value, fallback, low, high)
  local number = util.integer(value, fallback)
  if low then number = math.max(low, number) end
  if high then number = math.min(high, number) end
  return number
end

local function saturatingAdd(left, right)
  return math.min(M.ACCUMULATOR_LIMIT, math.max(0, left or 0) + math.max(0, right or 0))
end

local function saturatingMultiply(left, right)
  return math.min(M.ACCUMULATOR_LIMIT, math.max(0, left or 0) * math.max(0, right or 0))
end

function M.defaultParams()
  return {
    alphaUpPm = 80,
    alphaDownPm = 250,
    maxWaitSeconds = 1800,
    transferSeconds = 480,
    crowdThresholdPpm = 700000,
  }
end

function M.newState()
  return {
    version = M.VERSION,
    epoch = 0,
    params = M.defaultParams(),
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

-- A version-1 state carries additive weights and no share stocks. Markets get
-- the cents-denominated defaults; services keep their operating facts and
-- initialise their stocks lazily on the first evaluation.
function M.migrate(state)
  if type(state) ~= "table" then return M.newState() end
  local previousVersion = util.integer(state.version, 1)
  if previousVersion >= M.VERSION then
    state.params = state.params or M.defaultParams()
    return state
  end
  if previousVersion <= 1 then
    state.params = M.defaultParams()
    for _, market in pairs(state.markets or {}) do
      market.outsideWeight = nil
      market.votCentsPerHour = copyInteger(market.votCentsPerHour, 450, 30, 100000)
      market.gcOutsideCents = copyInteger(market.gcOutsideCents, 2500, 1, 100000000)
      market.thetaCents = copyInteger(market.thetaCents,
        math.max(200, math.floor(market.gcOutsideCents * 8 / 100)), 50, 1000000)
    end
    for _, service in pairs(state.services or {}) do
      service.transfers = copyInteger(service.transfers, 0, 0, 8)
      service.sharePpm = nil
      service.shareResid = 0
      service.lagLoadPpm = 0
    end
  end
  if previousVersion <= 2 then
    local defaults = M.defaultParams()
    state.params = state.params or {}
    for key, value in pairs(defaults) do
      if state.params[key] == nil then state.params[key] = value end
    end
    -- Version 2 did not record the fare used by the preceding settlement.
    -- Nil deliberately makes the first downward glide fail safe as a fare
    -- shock; the evaluator then records the current fare.
    for _, service in pairs(state.services or {}) do service.lastFareCents = nil end
  end
  -- Version 4: kind-weighted markets. Passenger-equivalent values keep every
  -- migrated market's generalized cost bit-identical to its version-3 result.
  for _, market in pairs(state.markets or {}) do
    market.kind = M.MARKET_KINDS[market.kind] and market.kind or "passenger"
    market.waitWeightPm = copyInteger(market.waitWeightPm, 2000, 0, 10000)
    market.transferSeconds = copyInteger(market.transferSeconds,
      util.integer(state.params and state.params.transferSeconds, 480), 0, 14400)
  end
  state.version = M.VERSION
  return state
end

function M.upsertMarket(state, market)
  assert(type(market.cid) == "string" and market.cid ~= "", "market cid required")
  local v4 = util.integer(state.version, M.VERSION) >= 4
  local kind = "passenger"
  if v4 and type(market.kind) == "string" and M.MARKET_KINDS[market.kind] then
    kind = market.kind
  end
  local kindDefaults = M.MARKET_KINDS[kind]
  local gcOutside = copyInteger(market.gcOutsideCents,
    v4 and kindDefaults.gcOutsideCents or 2500, 1, 100000000)
  local record = {
    cid = market.cid,
    name = tostring(market.name or market.cid),
    demand = copyInteger(market.demand, 100, 0, 1000000000),
    votCentsPerHour = copyInteger(market.votCentsPerHour,
      v4 and kindDefaults.votCentsPerHour or 450, 30, 100000),
    gcOutsideCents = gcOutside,
    thetaCents = copyInteger(market.thetaCents,
      math.max(200, math.floor(gcOutside * 8 / 100)), 50, 1000000),
    metadata = util.deepCopy(market.metadata or {}),
  }
  if v4 then
    record.kind = kind
    record.waitWeightPm = copyInteger(market.waitWeightPm, kindDefaults.waitWeightPm, 0, 10000)
    record.transferSeconds = copyInteger(market.transferSeconds, kindDefaults.transferSeconds, 0, 14400)
  end
  state.markets[market.cid] = record
  return record
end

function M.upsertService(state, service)
  assert(type(service.lineCid) == "string" and service.lineCid ~= "", "lineCid required")
  assert(type(service.marketCid) == "string" and state.markets[service.marketCid], "known marketCid required")
  assert(type(service.companyCid) == "string" and service.companyCid ~= "", "companyCid required")
  local existing = state.services[service.lineCid]
  local fareCents = copyInteger(service.fareCents, 1000, 0, 100000000)
  local lastFareCents = nil
  if util.integer(state.version, M.VERSION) >= 3 then
    lastFareCents = existing and existing.lastFareCents
      or copyInteger(service.lastFareCents, fareCents, 0, 100000000)
    if existing and existing.lastFareCents == nil then lastFareCents = nil end
  end
  state.services[service.lineCid] = {
    lineCid = service.lineCid,
    marketCid = service.marketCid,
    companyCid = service.companyCid,
    name = tostring(service.name or service.lineCid),
    headwaySeconds = copyInteger(service.headwaySeconds, 1800, 30, 86400),
    journeySeconds = copyInteger(service.journeySeconds, 3600, 30, 604800),
    fareCents = fareCents,
    capacity = copyInteger(service.capacity, 100, 0, 1000000000),
    quality = copyInteger(service.quality, 100, 0, 1000),
    transfers = copyInteger(service.transfers, 0, 0, 8),
    enabled = service.enabled ~= false,
    -- Share is a stock: a re-upserted service keeps its earned position, a
    -- brand-new one starts from nothing and must climb at alphaUp.
    sharePpm = existing and existing.sharePpm or copyInteger(service.sharePpm, 0, 0, M.SHARE_SCALE),
    shareResid = existing and existing.shareResid or 0,
    lagLoadPpm = existing and existing.lagLoadPpm or 0,
    -- Fare hikes cannot monetize yesterday's retained share. Other causes of
    -- a lower equilibrium (notably lagged crowding) keep the smooth down-glide.
    lastFareCents = lastFareCents,
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

-- Everything the shipper or passenger experiences is converted into cents so
-- every factor shares a unit the player can read. The wait weight and
-- transshipment time are market-kind data (passengers wait at double weight;
-- cargo tolerates waiting but pays dearly per transfer); crowding scales the
-- in-vehicle cost from the previous epoch's load. Markets recorded before
-- version 4 carry no kind fields and keep the passenger-equivalent formula.
function M.generalizedCost(params, market, service)
  local vot = market.votCentsPerHour
  local waitWeightPm = market.waitWeightPm
  if waitWeightPm == nil then waitWeightPm = 2000 end
  local transferSeconds = market.transferSeconds
  if transferSeconds == nil then transferSeconds = params.transferSeconds end
  local waitSeconds = math.min(math.floor(service.headwaySeconds / 2), params.maxWaitSeconds)
  local timeCostCents = math.floor(vot * service.journeySeconds / 3600)
  local waitCostCents = math.floor(vot * waitSeconds * waitWeightPm / 3600000)
  local transferCostCents = math.floor(vot * service.transfers * transferSeconds / 3600)
  local crowdSpan = M.SHARE_SCALE - params.crowdThresholdPpm
  local crowdExcess = util.clamp((service.lagLoadPpm or 0) - params.crowdThresholdPpm, 0, crowdSpan)
  local crowdCostCents = math.floor(timeCostCents * crowdExcess / crowdSpan)
  local comfortCents = service.quality
  local gcCents = math.max(1, service.fareCents + timeCostCents + waitCostCents
    + transferCostCents + crowdCostCents - comfortCents)
  return gcCents, {
    fareCents = service.fareCents,
    timeCostCents = timeCostCents,
    waitCostCents = waitCostCents,
    transferCostCents = transferCostCents,
    crowdCostCents = crowdCostCents,
    comfortCents = comfortCents,
    gcCents = gcCents,
  }
end

-- Interpolated integer exp(-(gc - gcMin)/theta) scaled to 65536. Identical on
-- every machine because only the pinned table and integer division are used.
-- Version 3 assigns no demand beyond the 8-theta cutoff. Version 2 used a
-- weight floor of one; retain that path solely for archived replay parity.
local function logitWeight(gcCents, gcMinCents, thetaCents, cutoffWeight)
  local centinats = math.floor((gcCents - gcMinCents) * 100 / thetaCents)
  if centinats >= 800 then return cutoffWeight end
  if centinats < 0 then centinats = 0 end
  local index = math.floor(centinats / 10)
  local fraction = centinats % 10
  local left = EXP_TABLE[index + 1]
  local right = EXP_TABLE[index + 2]
  return math.max(cutoffWeight, left + math.floor((right - left) * fraction / 10))
end

function M.logitWeight(gcCents, gcMinCents, thetaCents)
  return logitWeight(gcCents, gcMinCents, thetaCents, 0)
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

-- Drift-free integer glide with a carried residual: converges to the exact
-- equilibrium instead of stalling 1000/alpha below it.
local function glideStep(actual, equilibrium, alphaPm, resid)
  local delta = (equilibrium - actual) * alphaPm + resid
  local step = math.floor(delta / 1000)
  return actual + step, delta - step * 1000
end

local function marketServices(state, marketCid)
  local market = state.markets[marketCid]
  local services = {}
  for _, lineCid in ipairs(util.sortedKeys(state.services)) do
    local service = state.services[lineCid]
    if service.enabled and service.marketCid == marketCid then
      local gcCents, factors = M.generalizedCost(state.params, market, service)
      services[#services + 1] = { service = service, cid = lineCid, gcCents = gcCents, factors = factors }
    end
  end
  return services
end

function M.evaluateMarket(state, marketCid)
  local market = state.markets[marketCid]
  if not market then return nil, "unknown market" end
  local params = state.params
  local services = marketServices(state, marketCid)

  local gcMin = market.gcOutsideCents
  for _, option in ipairs(services) do gcMin = math.min(gcMin, option.gcCents) end
  local cutoffWeight = util.integer(state.version, M.VERSION) >= 3 and 0 or 1
  local weightItems = { { cid = "~outside",
    weight = logitWeight(market.gcOutsideCents, gcMin, market.thetaCents, cutoffWeight) } }
  for _, option in ipairs(services) do
    option.weight = logitWeight(option.gcCents, gcMin, market.thetaCents, cutoffWeight)
    weightItems[#weightItems + 1] = { cid = option.cid, weight = option.weight }
  end
  local equilibriumPpm = proportional(M.SHARE_SCALE, weightItems)

  -- Services glide toward equilibrium; the outside option is the residual, so
  -- conservation is exact and a collapsing service dumps its passengers back
  -- to not-traveling immediately while survivors must climb at alphaUp.
  local serviceSharePpm = 0
  for _, option in ipairs(services) do
    local service = option.service
    local equilibrium = equilibriumPpm[option.cid] or 0
    option.equilibriumPpm = equilibrium
    if service.sharePpm == nil then
      service.sharePpm, service.shareResid = equilibrium, 0
    else
      local fareShock = util.integer(state.version, M.VERSION) >= 3
        and (service.lastFareCents == nil or service.fareCents > service.lastFareCents)
      local alphaPm = equilibrium >= service.sharePpm and params.alphaUpPm
        or (fareShock and 1000 or params.alphaDownPm)
      service.sharePpm, service.shareResid =
        glideStep(service.sharePpm, equilibrium, alphaPm, service.shareResid or 0)
      service.sharePpm = util.clamp(service.sharePpm, 0, M.SHARE_SCALE)
    end
    if util.integer(state.version, M.VERSION) >= 3 then
      service.lastFareCents = service.fareCents
    end
    serviceSharePpm = serviceSharePpm + service.sharePpm
  end
  local outsidePpm = math.max(0, M.SHARE_SCALE - serviceSharePpm)

  local active, allocations = {}, {}
  for _, option in ipairs(services) do active[#active + 1] = option end
  local remaining = market.demand
  while remaining > 0 and #active > 0 do
    local previewItems = { { cid = "~outside", weight = outsidePpm } }
    for _, option in ipairs(active) do
      previewItems[#previewItems + 1] = { cid = option.cid, weight = option.service.sharePpm }
    end
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
    kind = market.kind,
    demand = market.demand,
    gcOutsideCents = market.gcOutsideCents,
    thetaCents = market.thetaCents,
    outside = allocations["~outside"] or 0,
    outsidePpm = outsidePpm,
    services = {},
  }
  for _, option in ipairs(services) do
    local service = option.service
    local amount = allocations[option.cid] or 0
    -- Next epoch's crowding responds to this epoch's realised load.
    if service.capacity > 0 then
      service.lagLoadPpm = math.floor(amount * M.SHARE_SCALE / service.capacity)
    else
      service.lagLoadPpm = M.SHARE_SCALE
    end
    result.services[option.cid] = {
      lineCid = option.cid,
      companyCid = service.companyCid,
      name = service.name,
      allocated = amount,
      capacity = service.capacity,
      fareCents = service.fareCents,
      revenueCents = saturatingMultiply(amount, service.fareCents),
      shareBasisPoints = market.demand > 0 and math.floor(amount * 10000 / market.demand) or 0,
      sharePpm = service.sharePpm,
      shareResid = service.shareResid,
      equilibriumPpm = option.equilibriumPpm,
      lagLoadPpm = service.lagLoadPpm,
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
    results.totalDemand = saturatingAdd(results.totalDemand, result.demand)
    for _, lineCid in ipairs(util.sortedKeys(result.services)) do
      local service = result.services[lineCid]
      local company = results.companies[service.companyCid] or { companyCid = service.companyCid, demand = 0, revenueCents = 0 }
      company.demand = saturatingAdd(company.demand, service.allocated)
      company.revenueCents = saturatingAdd(company.revenueCents, service.revenueCents)
      results.companies[service.companyCid] = company
      results.totalRevenueCents = saturatingAdd(results.totalRevenueCents, service.revenueCents)
    end
  end
  state.epoch = (state.epoch or 0) + 1
  results.epoch = state.epoch
  state.lastResults = results
  return results
end

-- The model is deterministic integer arithmetic over replicated state, so the
-- strongest validation of host results is an independent local evaluation and
-- a canonical checksum comparison. On success the local mutation is already
-- the authoritative one; on mismatch the model state has diverged and the
-- caller must fail the session closed.
function M.acceptAuthoritativeResults(state, results)
  if type(results) ~= "table" or type(results.markets) ~= "table" or type(results.companies) ~= "table" then
    return false, "authoritative results are malformed"
  end
  if tonumber(results.epoch) ~= (state.epoch or 0) + 1 then
    return false, "authoritative epoch is not the next epoch"
  end
  -- Evaluate on a copy so a diverging or tampered result rejects without
  -- advancing local stocks; adopt the copy only after the digests agree.
  local preview = util.deepCopy(state)
  local localResults = M.evaluateAll(preview)
  local localDigest = hash.value(localResults)
  local authoritativeDigest = hash.value(results)
  if localDigest ~= authoritativeDigest then
    return false, "authoritative results diverge from deterministic local evaluation: "
      .. tostring(authoritativeDigest) .. " ~= " .. tostring(localDigest)
  end
  state.epoch = preview.epoch
  state.services = preview.services
  state.lastResults = preview.lastResults
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
  state.ledger.totalDemand = saturatingAdd(state.ledger.totalDemand, results.totalDemand)
  state.ledger.totalRevenueCents = saturatingAdd(state.ledger.totalRevenueCents, results.totalRevenueCents)
  state.ledger.companies = state.ledger.companies or {}
  for _, companyCid in ipairs(util.sortedKeys(results.companies or {})) do
    local result = results.companies[companyCid]
    local total = state.ledger.companies[companyCid] or {
      companyCid = companyCid, demand = 0, revenueCents = 0, wins = 0,
    }
    total.demand = saturatingAdd(total.demand, result.demand)
    total.revenueCents = saturatingAdd(total.revenueCents, result.revenueCents)
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
      modelValueCents = saturatingAdd(
        saturatingAdd(saturatingMultiply(revenue, 10), saturatingMultiply(demand, 100)),
        saturatingAdd(saturatingMultiply(reach, 500000), saturatingMultiply(lines, 250000))
      ),
    }
  end
  return result
end

return M
