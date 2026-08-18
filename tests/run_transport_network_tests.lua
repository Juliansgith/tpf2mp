local project = assert(arg[1], "project root argument required"):gsub("\\", "/")
package.path = project .. "/tpf2_mp_1/res/scripts/?.lua;" .. package.path

local economy = require "tpf2_mp/economy"
local cargoPresentation = require "tpf2_mp/cargo_presentation"
local freightIndustry = require "tpf2_mp/freight_industry_model"
local freightSettlement = require "tpf2_mp/freight_transport_settlement"
local multihop = require "tpf2_mp/multihop_network"
local proposalCodec = require "tpf2_mp/proposal_codec"
local resourceCompatibility = require "tpf2_mp/resource_compatibility"

local tests = {}
local function test(name, fn) tests[#tests + 1] = { name = name, fn = fn } end
local function equal(actual, expected, message)
  if actual ~= expected then error((message or "values differ")
    .. ": expected " .. tostring(expected) .. ", got " .. tostring(actual), 2) end
end
local function truthy(value, message) if not value then error(message or "expected truthy value", 2) end end

local function passengerLeg(state, lineCid, marketCid, townA, townB, stationA, stationB)
  economy.upsertMarket(state, { cid = marketCid, name = marketCid, kind = "passenger",
    demand = 100, metadata = { townA = townA, townB = townB,
      townSizeA = 400, townSizeB = 400, corridorMeters = 10000 } })
  economy.upsertService(state, { lineCid = lineCid, marketCid = marketCid,
    companyCid = "company:1", capacity = 100, headwaySeconds = 600,
    journeySeconds = 900, metadata = { endpointTownCids = { townA, townB },
      stationGroupCids = { stationA, stationB }, distanceMeters = 10000 } })
end

test("passenger corridors create and remove deterministic through-demand", function()
  local state = economy.newState()
  passengerLeg(state, "line:a-b", "market:a-b", "town:a", "town:b",
    "station:a", "station:transfer")
  passengerLeg(state, "line:b-c", "market:b-c", "town:b", "town:c",
    "station:transfer", "station:c")
  local rebuilt = multihop.rebuildPassenger(state)
  equal(rebuilt.routeCount, 1)
  equal(#rebuilt.routes[1].lines, 2)
  equal(rebuilt.routes[1].transfers, 1)
  local first = state.markets["market:a-b"].metadata.networkDemand
  truthy(first > 0, "through-route did not add demand to the first leg")
  equal(state.markets["market:b-c"].metadata.networkDemand, first)
  economy.removeService(state, "line:b-c")
  equal(state.markets["market:a-b"].metadata.networkDemand, 0)
  equal(multihop.publicView(state).passengerRouteCount, 0)
end)

test("passenger transfers may use an intermediate stop on a through line", function()
  local state = economy.newState()
  passengerLeg(state, "line:a-c", "market:a-c", "town:a", "town:c",
    "station_group:a", "station_group:c")
  state.services["line:a-c"].metadata.stationGroupCids = {
    "station_group:a", "station_group:hub", "station_group:c" }
  passengerLeg(state, "line:b-d", "market:b-d", "town:b", "town:d",
    "station_group:hub", "station_group:d")
  local rebuilt = multihop.rebuildPassenger(state)
  local found = false
  for _, route in ipairs(rebuilt.routes) do
    if route.sourceTownCid == "town:a" and route.destinationTownCid == "town:d" then
      found = route.segments[1][1] == 0 and route.segments[1][2] == 1
    end
  end
  truthy(found, "intermediate passenger interchange was not routed")
end)

local function cargoLeg(state, lineCid, marketCid, stationA, stationB,
    sourcesA, sinksA, sourcesB, sinksB, vehicleCid, capacity)
  economy.upsertMarket(state, { cid = marketCid, name = marketCid,
    kind = "cargo", demand = 0 })
  economy.upsertService(state, { lineCid = lineCid, marketCid = marketCid,
    companyCid = "company:1", capacity = 0, headwaySeconds = 600,
    journeySeconds = 900, fareCents = 1000, metadata = {
      freightNetworkSchema = 1, stationGroupCids = { stationA, stationB },
      distanceMeters = 10000, vehicleCids = { vehicleCid },
      cargoCapacityByType = { GRAIN = capacity },
      cargoHourlyCapacityByType = { GRAIN = capacity },
      cargoAverageCapacityByType = { GRAIN = capacity },
      cargoCapacityByVehicleCid = { [vehicleCid] = { GRAIN = capacity } },
      cargoEndpointFacts = {
        { stationGroupCid = stationA, stopIndex = 0,
          sources = sourcesA or {}, destinations = sinksA or {} },
        { stationGroupCid = stationB, stopIndex = 1,
          sources = sourcesB or {}, destinations = sinksB or {} },
      },
    } })
end

test("cargo waits for a destination then conserves stock over two physical legs", function()
  local state = economy.newState()
  cargoLeg(state, "line:source-transfer", "market:source-transfer",
    "station_group:source", "station_group:transfer",
    { { industryCid = "industry:source", cargoType = "GRAIN", ratePerHour = 20 } },
    {}, {}, {}, "vehicle:first", 10)
  local unresolved = multihop.rebuildCargo(state)
  equal(unresolved.routeCount, 0)
  equal(unresolved.unroutedLines, 1)
  equal(state.services["line:source-transfer"].capacity, 0)

  cargoLeg(state, "line:transfer-sink", "market:transfer-sink",
    "station_group:transfer", "station_group:sink", {}, {}, {},
    { { industryCid = "industry:sink", cargoType = "GRAIN",
        stockIndex = 0, ratePerHour = 20 } }, "vehicle:second", 10)
  local routed = multihop.rebuildCargo(state)
  equal(routed.routeCount, 1)
  equal(routed.routes[1].transfers, 1)
  equal(state.services["line:source-transfer"].metadata.destinationTransportKind, "station")
  equal(state.services["line:transfer-sink"].metadata.sourceTransportKind, "station")

  state.lastResults.markets = {
    ["market:source-transfer"] = { services = {
      ["line:source-transfer"] = { allocated = 10 } } },
    ["market:transfer-sink"] = { services = {
      ["line:transfer-sink"] = { allocated = 10 } } },
  }
  local freight = freightIndustry.newState()
  freight.ready = true
  freight.industries = {
    ["industry:source"] = { recipe = { outputs = {
      { cargoType = "GRAIN", amount = 1 } } }, inputStock = {},
      outputStock = { GRAIN = 20 } },
    ["industry:sink"] = { recipe = { outputs = {} }, inputStock = {
      { index = 0, cargoType = "GRAIN", amount = 0 } }, outputStock = {} },
  }
  local presentation = cargoPresentation.newState()
  local ok, result = cargoPresentation.applyRelease(presentation, state, freight,
    { lineCid = "line:source-transfer", vehicleCid = "vehicle:first",
      stopIndex = 0, round = 1 }, { owner = "company:1" })
  truthy(ok, result); equal(result.boarded, 10)
  ok, result = cargoPresentation.applyRelease(presentation, state, freight,
    { lineCid = "line:source-transfer", vehicleCid = "vehicle:first",
      stopIndex = 1, round = 2 }, { owner = "company:1" })
  truthy(ok, result); equal(result.transferred, 10)
  equal(presentation.stationStock["station_group:transfer"].GRAIN, 10)
  ok, result = cargoPresentation.applyRelease(presentation, state, freight,
    { lineCid = "line:transfer-sink", vehicleCid = "vehicle:second",
      stopIndex = 0, round = 1 }, { owner = "company:1" })
  truthy(ok, result); equal(result.boarded, 10)
  equal(presentation.stationStock["station_group:transfer"].GRAIN, 0)
  ok, result = cargoPresentation.applyRelease(presentation, state, freight,
    { lineCid = "line:transfer-sink", vehicleCid = "vehicle:second",
      stopIndex = 1, round = 2 }, { owner = "company:1" })
  truthy(ok, result); equal(result.delivered, 10)

  local snapshot = cargoPresentation.economySnapshot(presentation)
  local settled, summary = freightSettlement.apply(freight, snapshot.lines)
  truthy(settled, summary)
  equal(freight.industries["industry:source"].outputStock.GRAIN, 10)
  equal(freight.industries["industry:sink"].inputStock[1].amount, 10)
  equal(freight.totalTransported.GRAIN, 20)
  equal(freight.totalDelivered.GRAIN, 10)
  equal(summary.transferred.GRAIN, 10)
  local vehicleSync = { vehicles = {
    ["vehicle:first"] = { lineCid = "line:source-transfer", companyCid = "company:1",
      lastAuthorizedRound = 2, stopIndex = 1 },
    ["vehicle:second"] = { lineCid = "line:transfer-sink", companyCid = "company:1",
      lastAuthorizedRound = 2, stopIndex = 1 },
  } }
  local valid, validationError = cargoPresentation.validateState(
    presentation, state, freight, vehicleSync)
  truthy(valid, validationError)
  presentation.stationStock["station_group:transfer"].GRAIN = 1
  valid = cargoPresentation.validateState(presentation, state, freight, vehicleSync)
  equal(valid, false, "tampered transfer inventory was accepted")
end)

test("an established freight path cannot silently reroute through a new line", function()
  local state = economy.newState()
  cargoLeg(state, "line:source-transfer", "market:source-transfer",
    "station_group:source", "station_group:transfer",
    { { industryCid = "industry:source", cargoType = "GRAIN", ratePerHour = 20 } },
    {}, {}, {}, "vehicle:first", 10)
  cargoLeg(state, "line:old-sink", "market:old-sink",
    "station_group:transfer", "station_group:sink", {}, {}, {},
    { { industryCid = "industry:sink", cargoType = "GRAIN",
        stockIndex = 0, ratePerHour = 20 } }, "vehicle:old", 10)
  state.services["line:old-sink"].journeySeconds = 4000
  local initial = multihop.rebuildCargo(state)
  equal(initial.routeCount, 1)
  local pinned = state.services["line:source-transfer"].metadata.freightPathDigest
  equal(state.services["line:source-transfer"].metadata.freightPinnedPathDigest, nil,
    "an unused freight route was pinned before operation")
  local pinOk, pinResult = multihop.pinCargoLine(state, "line:source-transfer")
  truthy(pinOk, pinResult)
  equal(pinResult.pinned, 2)

  cargoLeg(state, "line:new-sink", "market:new-sink",
    "station_group:transfer", "station_group:sink", {}, {}, {},
    { { industryCid = "industry:sink", cargoType = "GRAIN",
        stockIndex = 0, ratePerHour = 20 } }, "vehicle:new", 10)
  state.services["line:new-sink"].journeySeconds = 100
  local rebuilt = multihop.rebuildCargo(state)
  equal(rebuilt.routeCount, 1)
  equal(state.services["line:source-transfer"].metadata.freightPathDigest, pinned)
  equal(state.services["line:old-sink"].metadata.freightPathDigest, pinned)
  equal(state.services["line:new-sink"].metadata.networkStatus,
    "awaiting-compatible-path")

  economy.removeService(state, "line:old-sink")
  equal(state.services["line:source-transfer"].metadata.networkStatus,
    "pinned-path-unavailable")
  equal(state.services["line:source-transfer"].capacity, 0)
end)

test("an unused freight path may replan before its first vehicle release", function()
  local state = economy.newState()
  cargoLeg(state, "line:source-transfer", "market:source-transfer",
    "station_group:source", "station_group:transfer",
    { { industryCid = "industry:source", cargoType = "GRAIN", ratePerHour = 20 } },
    {}, {}, {}, "vehicle:first", 10)
  cargoLeg(state, "line:old-sink", "market:old-sink",
    "station_group:transfer", "station_group:sink", {}, {}, {},
    { { industryCid = "industry:sink", cargoType = "GRAIN",
        stockIndex = 0, ratePerHour = 20 } }, "vehicle:old", 10)
  state.services["line:old-sink"].journeySeconds = 4000
  multihop.rebuildCargo(state)
  local original = state.services["line:source-transfer"].metadata.freightPathDigest

  cargoLeg(state, "line:new-sink", "market:new-sink",
    "station_group:transfer", "station_group:sink", {}, {}, {},
    { { industryCid = "industry:sink", cargoType = "GRAIN",
        stockIndex = 0, ratePerHour = 20 } }, "vehicle:new", 10)
  state.services["line:new-sink"].journeySeconds = 100
  local rebuilt = multihop.rebuildCargo(state)
  equal(rebuilt.routeCount, 1)
  truthy(state.services["line:source-transfer"].metadata.freightPathDigest ~= original,
    "unused route did not adopt the cheaper compatible leg")
  equal(state.services["line:new-sink"].metadata.networkStatus, "routed")
  equal(state.services["line:old-sink"].metadata.networkStatus,
    "awaiting-compatible-path")
end)

test("cargo may transfer at an intermediate stop of a through service", function()
  local state = economy.newState()
  cargoLeg(state, "line:through", "market:through",
    "station_group:source", "station_group:terminal",
    { { industryCid = "industry:source", cargoType = "GRAIN", ratePerHour = 20 } },
    {}, {}, {}, "vehicle:through", 10)
  local metadata = state.services["line:through"].metadata
  metadata.stationGroupCids = {
    "station_group:source", "station_group:hub", "station_group:terminal" }
  metadata.cargoEndpointFacts[2].stationGroupCid = "station_group:terminal"
  metadata.cargoEndpointFacts[#metadata.cargoEndpointFacts + 1] = {
    stationGroupCid = "station_group:hub", stopIndex = 1,
    sources = {}, destinations = {} }
  cargoLeg(state, "line:final", "market:final",
    "station_group:hub", "station_group:sink", {}, {}, {},
    { { industryCid = "industry:sink", cargoType = "GRAIN",
        stockIndex = 0, ratePerHour = 20 } }, "vehicle:final", 10)
  local rebuilt = multihop.rebuildCargo(state)
  equal(rebuilt.routeCount, 1)
  equal(state.services["line:through"].metadata.destinationStopIndex, 1)
  equal(rebuilt.routes[1].segments[1][2], 1)
end)

test("compatibility manager inventories named vanilla and mod resources alike", function()
  local transaction = { schemaVersion = proposalCodec.SCHEMA_VERSION,
    companyCid = "company:1", cost = 0,
    nodes = { { slot = "node:1", position = { x = 0, y = 0, z = 0 } },
      { slot = "node:2", position = { x = 10, y = 0, z = 0 } } },
    edges = { { slot = "edge:1", carrier = "track", node0 = { slot = "node:1" },
      node1 = { slot = "node:2" }, tangent0 = { x = 10, y = 0, z = 0 },
      tangent1 = { x = 10, y = 0, z = 0 }, type = 0, typeIndex = 0,
      resource = { index = 42, name = "track/modded_high_speed.lua" },
      logicalOwnerCid = "company:1", private = true, catenary = true } },
    edgeObjects = { add = {}, retain = {}, remove = {} },
    remove = { edges = {}, nodes = {} } }
  transaction.digest = proposalCodec.digest(transaction)
  transaction.transactionId = "proposal:" .. transaction.digest
  local probe = resourceCompatibility.newProbe()
  local ok, _, observed = resourceCompatibility.observe(probe, transaction)
  truthy(ok)
  local view = resourceCompatibility.publicView(observed)
  equal(view.resourceCount, 1)
  equal(view.resources[1].name, "track/modded_high_speed.lua")
  equal(view.resources[1].status, "portable-by-name")
end)

local passed = 0
for _, item in ipairs(tests) do
  local ok, err = xpcall(item.fn, debug.traceback)
  if not ok then io.stderr:write("FAIL " .. item.name .. "\n" .. tostring(err) .. "\n"); os.exit(1) end
  passed = passed + 1
  print("PASS " .. item.name)
end
print(string.format("Transport-network tests: %d/%d passed", passed, #tests))
