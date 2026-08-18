local project = assert(arg[1], "project root required"):gsub("\\", "/")
local outputPath = assert(arg[2], "output path required")
package.path = project .. "/tpf2_mp_1/res/scripts/?.lua;" .. package.path

local util = require "tpf2_mp/util"
local hash = require "tpf2_mp/hash"
local json = require "tpf2_mp/json"
local network = require "tpf2_mp/multihop_network"

local function passenger()
  return {
    markets = {
      ["market:a-b"] = { cid = "market:a-b", kind = "passenger", demand = 100,
        metadata = { townA = "town:a", townB = "town:b", directDemand = 100,
          corridorMeters = 10000 } },
      ["market:b-c"] = { cid = "market:b-c", kind = "passenger", demand = 120,
        metadata = { townA = "town:b", townB = "town:c", directDemand = 120,
          corridorMeters = 12000 } },
    },
    towns = { ["town:a"] = { size = 400 }, ["town:b"] = { size = 500 },
      ["town:c"] = { size = 600 } },
    services = {
      ["line:a-b"] = { lineCid = "line:a-b", marketCid = "market:a-b",
        capacity = 90, headwaySeconds = 600, journeySeconds = 900,
        metadata = { endpointTownCids = { "town:a", "town:b" },
          stationGroupCids = { "station_group:a", "station_group:x" },
          distanceMeters = 10000 } },
      ["line:b-c"] = { lineCid = "line:b-c", marketCid = "market:b-c",
        capacity = 80, headwaySeconds = 700, journeySeconds = 1000,
        metadata = { endpointTownCids = { "town:b", "town:c" },
          stationGroupCids = { "station_group:x", "station_group:c" },
          distanceMeters = 12000 } },
    },
  }
end

local function cargo()
  local state = { markets = {}, services = {}, towns = {} }
  local function leg(lineCid, marketCid, first, second, sources, destinations, seconds)
    state.markets[marketCid] = { cid = marketCid, kind = "cargo", demand = 0, metadata = {} }
    state.services[lineCid] = { lineCid = lineCid, marketCid = marketCid,
      capacity = 0, transfers = 0, headwaySeconds = 600, journeySeconds = seconds,
      metadata = { freightNetworkSchema = 1,
        stationGroupCids = { first, second }, distanceMeters = 10000,
        cargoHourlyCapacityByType = { GRAIN = 40 },
        cargoEndpointFacts = {
          { stationGroupCid = first, sources = sources or {}, destinations = {} },
          { stationGroupCid = second, sources = {}, destinations = destinations or {} },
        } } }
  end
  leg("line:source", "market:source", "station_group:s", "station_group:x",
    { { industryCid = "industry:farm", cargoType = "GRAIN", ratePerHour = 30 } },
    nil, 900)
  leg("line:sink", "market:sink", "station_group:x", "station_group:d", nil,
    { { industryCid = "industry:mill", cargoType = "GRAIN",
        stockIndex = 0, ratePerHour = 20 } }, 1000)
  return state
end

local vectors = {}
for _, item in ipairs({ { name = "passenger-transfer", value = passenger() },
    { name = "cargo-transfer", value = cargo(), pinLineCid = "line:source" } }) do
  local input = util.deepCopy(item.value)
  local summary = network.rebuild(item.value)
  if item.pinLineCid then
    local pinned, pinError = network.pinCargoLine(item.value, item.pinLineCid)
    assert(pinned, pinError)
  end
  vectors[#vectors + 1] = { name = item.name, input = input,
    pinLineCid = item.pinLineCid,
    expectedDigest = hash.value(item.value), expectedSummaryDigest = hash.value(summary),
    expectedSummary = summary }
end

local handle = assert(io.open(outputPath, "wb"))
handle:write(json.encode({ schemaVersion = 1, vectors = vectors }))
handle:close()
print("PASS generated " .. tostring(#vectors) .. " transport-network parity vectors")
