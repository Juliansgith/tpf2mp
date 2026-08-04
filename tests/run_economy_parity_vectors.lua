local projectRoot = assert(arg[1], "project root argument required")
local outputPath = assert(arg[2], "output path argument required")

package.path = projectRoot .. "/tpf2_mp_1/res/scripts/?.lua;" .. package.path

local economy = require "tpf2_mp/economy"
local json = require "tpf2_mp/json"
local util = require "tpf2_mp/util"

local function digestView(state)
  local markets, services = {}, {}
  for _, cid in ipairs(util.sortedKeys(state.markets or {})) do
    local value = state.markets[cid]
    markets[cid] = {
      cid = value.cid,
      name = value.name,
      demand = value.demand,
      outsideWeight = value.outsideWeight,
      votCentsPerHour = value.votCentsPerHour,
      gcOutsideCents = value.gcOutsideCents,
      thetaCents = value.thetaCents,
      metadata = util.deepCopy(value.metadata or {}),
    }
  end
  for _, cid in ipairs(util.sortedKeys(state.services or {})) do
    local value = state.services[cid]
    services[cid] = {
      lineCid = value.lineCid,
      marketCid = value.marketCid,
      companyCid = value.companyCid,
      name = value.name,
      headwaySeconds = value.headwaySeconds,
      journeySeconds = value.journeySeconds,
      fareCents = value.fareCents,
      capacity = value.capacity,
      quality = value.quality,
      transfers = value.transfers,
      enabled = value.enabled,
      sharePpm = value.sharePpm,
      shareResid = value.shareResid,
      lagLoadPpm = value.lagLoadPpm,
      lastFareCents = value.lastFareCents,
    }
  end
  return {
    version = state.version,
    epoch = state.epoch,
    params = util.deepCopy(state.params),
    markets = markets,
    services = services,
    lastResults = util.deepCopy(state.lastResults),
    ledger = util.deepCopy(state.ledger),
  }
end

local function applyOverrides(state, overrides)
  for lineCid, values in pairs(overrides or {}) do
    local service = assert(state.services[lineCid], "override references missing service " .. tostring(lineCid))
    if values.sharePpmNull then
      service.sharePpm = nil
    elseif values.sharePpm ~= nil then
      service.sharePpm = values.sharePpm
    end
    if values.shareResid ~= nil then service.shareResid = values.shareResid end
    if values.lagLoadPpm ~= nil then service.lagLoadPpm = values.lagLoadPpm end
  end
end

local scenarios = {}

local function addScenario(spec)
  local state = economy.newState()
  if spec.version then
    state.version = spec.version
    if spec.version == 2 then state.params.alphaDownPm = 250 end
  end
  if spec.params then
    for key, value in pairs(spec.params) do state.params[key] = value end
  end
  for _, market in ipairs(spec.markets) do economy.upsertMarket(state, market) end
  for _, service in ipairs(spec.services) do economy.upsertService(state, service) end
  applyOverrides(state, spec.overrides)
  for _, service in ipairs(spec.reupserts or {}) do economy.upsertService(state, service) end

  local companies = {}
  for _, service in ipairs(spec.services) do
    companies[service.companyCid] = companies[service.companyCid]
      or { cid = service.companyCid, name = "Company " .. service.companyCid }
  end

  local record = {
    id = spec.id,
    params = util.deepCopy(spec.params or {}),
    markets = util.deepCopy(spec.markets),
    services = util.deepCopy(spec.services),
    overrides = util.deepCopy(spec.overrides or {}),
    reupserts = util.deepCopy(spec.reupserts or {}),
    fareSchedule = util.deepCopy(spec.fareSchedule or {}),
    epochs = spec.epochs,
    initial = digestView(state),
    results = {},
    companies = companies,
  }
  for index = 1, spec.epochs do
    for lineCid, fareCents in pairs((spec.fareSchedule or {})[index] or {}) do
      assert(economy.setFare(state, lineCid, fareCents))
    end
    local result = economy.evaluateAll(state)
    record.results[index] = util.deepCopy(result)
    assert(economy.recordSettlement(state, result))
  end
  record.final = digestView(state)
  record.scoreboard = economy.scoreboard(state, companies)
  scenarios[#scenarios + 1] = record
end

addScenario({
  id = "demo-trajectory",
  markets = {
    { cid = "market:demo", name = "Demo", demand = 1000, votCentsPerHour = 450,
      gcOutsideCents = 2500, thetaCents = 250, metadata = { source = "parity" } },
  },
  services = {
    { lineCid = "line:a", marketCid = "market:demo", companyCid = "company:1", name = "A",
      headwaySeconds = 900, journeySeconds = 2400, fareCents = 1000, capacity = 600,
      quality = 100, transfers = 0 },
    { lineCid = "line:b", marketCid = "market:demo", companyCid = "company:2", name = "B",
      headwaySeconds = 1100, journeySeconds = 2200, fareCents = 900, capacity = 600,
      quality = 100, transfers = 0 },
  },
  epochs = 40,
})

addScenario({
  id = "legacy-v2-cutoff-replay",
  version = 2,
  markets = {
    { cid = "market:legacy", demand = 1000, votCentsPerHour = 450,
      gcOutsideCents = 2500, thetaCents = 200 },
  },
  services = {
    { lineCid = "line:legacy", marketCid = "market:legacy", companyCid = "company:1",
      headwaySeconds = 900, journeySeconds = 2400, fareCents = 100000000,
      capacity = 600, quality = 100, transfers = 0 },
  },
  overrides = { ["line:legacy"] = { sharePpmNull = true } },
  epochs = 2,
})

addScenario({
  id = "v3-fare-shock-and-zero-cutoff",
  markets = {
    { cid = "market:fare-guard", demand = 1000, votCentsPerHour = 450,
      gcOutsideCents = 2500, thetaCents = 200 },
  },
  services = {
    { lineCid = "line:guard", marketCid = "market:fare-guard", companyCid = "company:1",
      headwaySeconds = 900, journeySeconds = 2400, fareCents = 1000,
      capacity = 600, quality = 100, transfers = 0 },
    { lineCid = "line:rival", marketCid = "market:fare-guard", companyCid = "company:2",
      headwaySeconds = 1100, journeySeconds = 2200, fareCents = 900,
      capacity = 600, quality = 100, transfers = 0 },
  },
  overrides = {
    ["line:guard"] = { sharePpm = 400000, shareResid = 731, lagLoadPpm = 600000 },
    ["line:rival"] = { sharePpm = 500000, shareResid = 197, lagLoadPpm = 700000 },
  },
  fareSchedule = {
    { ["line:guard"] = 100000000 },
    { ["line:guard"] = 1000 },
  },
  epochs = 2,
})

addScenario({
  id = "maximum-revenue-boundary",
  markets = {
    { cid = "market:max", demand = 999999937, votCentsPerHour = 30,
      gcOutsideCents = 100000000, thetaCents = 50 },
  },
  services = {
    { lineCid = "line:max", marketCid = "market:max", companyCid = "company:1",
      headwaySeconds = 30, journeySeconds = 30, fareCents = 99999989,
      capacity = 1000000000, quality = 1000, transfers = 0 },
  },
  overrides = { ["line:max"] = { sharePpmNull = true } },
  epochs = 3,
})

addScenario({
  id = "negative-glide-and-capacity-cascade",
  params = { alphaUpPm = 83, alphaDownPm = 257, maxWaitSeconds = 1799,
    transferSeconds = 481, crowdThresholdPpm = 699999 },
  markets = {
    { cid = "market:cascade", demand = 10007, votCentsPerHour = 99999,
      gcOutsideCents = 7777777, thetaCents = 913 },
  },
  services = {
    { lineCid = "line:c", marketCid = "market:cascade", companyCid = "company:1",
      headwaySeconds = 86399, journeySeconds = 604799, fareCents = 1000003,
      capacity = 7, quality = 1, transfers = 8 },
    { lineCid = "line:d", marketCid = "market:cascade", companyCid = "company:2",
      headwaySeconds = 31, journeySeconds = 31, fareCents = 3,
      capacity = 17, quality = 999, transfers = 1 },
    { lineCid = "line:e", marketCid = "market:cascade", companyCid = "company:3",
      headwaySeconds = 1777, journeySeconds = 3555, fareCents = 4567,
      capacity = 999999, quality = 301, transfers = 3 },
  },
  overrides = {
    ["line:c"] = { sharePpm = 900001, shareResid = 999, lagLoadPpm = 1000000 },
    ["line:d"] = { sharePpm = 90000, shareResid = 1, lagLoadPpm = 999999 },
    ["line:e"] = { sharePpm = 9999, shareResid = 731, lagLoadPpm = 0 },
  },
  epochs = 12,
})

addScenario({
  id = "upsert-clamps-and-stock-preservation",
  markets = {
    { cid = "market:clamp", demand = -17, votCentsPerHour = 1,
      gcOutsideCents = 0, thetaCents = 9999999 },
  },
  services = {
    { lineCid = "line:clamp", marketCid = "market:clamp", companyCid = "company:1",
      headwaySeconds = 0, journeySeconds = 9999999, fareCents = -1,
      capacity = 2000000000, quality = 2000, transfers = -3 },
  },
  overrides = {
    ["line:clamp"] = { sharePpm = 123456, shareResid = 789, lagLoadPpm = 987654 },
  },
  reupserts = {
    { lineCid = "line:clamp", marketCid = "market:clamp", companyCid = "company:1",
      name = "Re-upserted", headwaySeconds = 31, journeySeconds = 61,
      fareCents = 101, capacity = 202, quality = 303, transfers = 4 },
  },
  epochs = 4,
})

addScenario({
  id = "migrated-null-stock-reupsert",
  markets = {
    { cid = "market:migrated", demand = 101, votCentsPerHour = 451,
      gcOutsideCents = 2501, thetaCents = 251 },
  },
  services = {
    { lineCid = "line:migrated", marketCid = "market:migrated", companyCid = "company:2",
      headwaySeconds = 901, journeySeconds = 2401, fareCents = 1001,
      capacity = 601, quality = 101, transfers = 1 },
  },
  overrides = {
    ["line:migrated"] = { sharePpmNull = true, shareResid = 0, lagLoadPpm = 0 },
  },
  reupserts = {
    { lineCid = "line:migrated", marketCid = "market:migrated", companyCid = "company:2",
      headwaySeconds = 902, journeySeconds = 2402, fareCents = 1002,
      capacity = 602, quality = 102, transfers = 2 },
  },
  epochs = 2,
})

local seed = 20260804
local function nextValue(limit)
  seed = (seed * 48271) % 2147483647
  return seed % limit
end
local demands = { 0, 1, 17, 999, 1000, 10007, 999999, 999999937 }
local fares = { 0, 1, 99, 1000, 99999, 1000003, 99999989 }
local capacities = { 0, 1, 7, 17, 599, 600, 10007, 999999937 }
local headways = { 30, 31, 899, 900, 1799, 3601, 86399, 86400 }
local journeys = { 30, 31, 1799, 2400, 3601, 77777, 604799, 604800 }
local qualities = { 0, 1, 99, 100, 333, 999, 1000 }
local outsideCosts = { 1, 50, 2499, 2500, 999999, 100000000 }
local thetas = { 50, 51, 249, 250, 913, 999999 }
local vots = { 30, 31, 449, 450, 12345, 99999, 100000 }

for scenarioIndex = 1, 64 do
  local marketCid = "market:fuzz-" .. scenarioIndex
  local market = {
    cid = marketCid,
    name = "Fuzz " .. scenarioIndex,
    demand = demands[nextValue(#demands) + 1],
    votCentsPerHour = vots[nextValue(#vots) + 1],
    gcOutsideCents = outsideCosts[nextValue(#outsideCosts) + 1],
    thetaCents = thetas[nextValue(#thetas) + 1],
    metadata = { vector = scenarioIndex },
  }
  local services, overrides = {}, {}
  local serviceCount = nextValue(4) + 1
  for serviceIndex = 1, serviceCount do
    local lineCid = "line:fuzz-" .. scenarioIndex .. "-" .. serviceIndex
    services[#services + 1] = {
      lineCid = lineCid,
      marketCid = marketCid,
      companyCid = "company:" .. ((serviceIndex % 3) + 1),
      name = "Service " .. serviceIndex,
      headwaySeconds = headways[nextValue(#headways) + 1],
      journeySeconds = journeys[nextValue(#journeys) + 1],
      fareCents = fares[nextValue(#fares) + 1],
      capacity = capacities[nextValue(#capacities) + 1],
      quality = qualities[nextValue(#qualities) + 1],
      transfers = nextValue(9),
      enabled = nextValue(5) ~= 0,
    }
    local stockKind = nextValue(5)
    if stockKind == 0 then
      overrides[lineCid] = { sharePpmNull = true, shareResid = 0, lagLoadPpm = 0 }
    else
      overrides[lineCid] = {
        sharePpm = nextValue(1000001),
        shareResid = nextValue(1000),
        lagLoadPpm = nextValue(1200001),
      }
    end
  end
  addScenario({
    id = "fuzz-" .. scenarioIndex,
    markets = { market },
    services = services,
    overrides = overrides,
    epochs = nextValue(6) + 1,
  })
end

local handle = assert(io.open(outputPath, "wb"))
handle:write(json.encode({ schema = 1, scenarios = scenarios }))
handle:write("\n")
handle:close()
print("PASS generated " .. #scenarios .. " Lua economy parity scenarios")
