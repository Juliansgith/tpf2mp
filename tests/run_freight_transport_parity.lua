local project = assert(arg[1], "project root required"):gsub("\\", "/")
local outputPath = assert(arg[2], "output path required")
package.path = project .. "/tpf2_mp_1/res/scripts/?.lua;" .. package.path

local json = require "tpf2_mp/json"
local hash = require "tpf2_mp/hash"
local freight = require "tpf2_mp/freight_industry_model"

local function industry(cid, resource, capacity, stocks, inputs, outputs)
  local value = {
    cid = cid, resource = resource, params = { productionLevel = 0 },
    capacity = capacity, stocks = stocks, inputs = inputs, outputs = outputs,
  }
  value.recipeDigest = hash.value({ resource = value.resource, params = value.params,
    stocks = value.stocks, inputs = value.inputs, outputs = value.outputs,
    capacity = value.capacity })
  return value
end

local recipes = {
  industry("industry:pre:a-farm", "industry/farm.con", 120, {}, { {} },
    { { cargoType = "GRAIN", amount = 1 } }),
  industry("industry:pre:b-mill", "industry/food_processing_plant.con", 60,
    { { index = 0, cargoType = "GRAIN", stockType = "RECEIVING", moreCapacity = 100 } },
    { { { stockIndex = 0, cargoType = "GRAIN", amount = 2 } } },
    { { cargoType = "FOOD", amount = 1 } }),
}
local action = assert(freight.bootstrapAction("edc7a517", 0, recipes))
local state = freight.newState()
assert(freight.applyBootstrap(state, action, { ready = true, digest = "edc7a517" }))
state.industries["industry:pre:a-farm"].outputStock.GRAIN = 100

local identity = {
  contractDigest = "1234abcd", sourceIndustryCid = "industry:pre:a-farm",
  destinationIndustryCid = "industry:pre:b-mill", destinationStockIndex = 0,
  cargoType = "GRAIN", earnedRevenueCents = 0,
}
local snapshots = {
  { ["line:freight:one"] = {
    contractDigest = identity.contractDigest,
    sourceIndustryCid = identity.sourceIndustryCid,
    destinationIndustryCid = identity.destinationIndustryCid,
    destinationStockIndex = identity.destinationStockIndex, cargoType = identity.cargoType,
    boardedUnits = 40, deliveredUnits = 25, earnedRevenueCents = 25000000,
  } },
  {
    ["line:freight:one"] = {
      contractDigest = identity.contractDigest,
      sourceIndustryCid = identity.sourceIndustryCid,
      destinationIndustryCid = identity.destinationIndustryCid,
      destinationStockIndex = identity.destinationStockIndex, cargoType = identity.cargoType,
      boardedUnits = 60, deliveredUnits = 40, earnedRevenueCents = 40000000,
    },
    ["line:freight:two"] = {
      contractDigest = "87654321",
      sourceIndustryCid = identity.sourceIndustryCid,
      destinationIndustryCid = identity.destinationIndustryCid,
      destinationStockIndex = identity.destinationStockIndex, cargoType = identity.cargoType,
      boardedUnits = 10, deliveredUnits = 0, earnedRevenueCents = 0,
    },
  },
  {
    ["line:freight:transfer-in"] = {
      contractDigest = "a1b2c3d4", sourceIndustryCid = identity.sourceIndustryCid,
      destinationIndustryCid = identity.destinationIndustryCid,
      destinationStockIndex = identity.destinationStockIndex, cargoType = identity.cargoType,
      boardedUnits = 5, deliveredUnits = 5, earnedRevenueCents = 5000000,
      transportSchema = 2, pathDigest = "deadbeef", legIndex = 0, legCount = 2,
      sourceKind = "industry", destinationKind = "station",
      sourceStationGroupCid = "station_group:pre:source",
      destinationStationGroupCid = "station_group:pre:transfer",
    },
    ["line:freight:transfer-out"] = {
      contractDigest = "b1c2d3e4", sourceIndustryCid = identity.sourceIndustryCid,
      destinationIndustryCid = identity.destinationIndustryCid,
      destinationStockIndex = identity.destinationStockIndex, cargoType = identity.cargoType,
      boardedUnits = 5, deliveredUnits = 5, earnedRevenueCents = 5000000,
      transportSchema = 2, pathDigest = "deadbeef", legIndex = 1, legCount = 2,
      sourceKind = "station", destinationKind = "industry",
      sourceStationGroupCid = "station_group:pre:transfer",
      destinationStationGroupCid = "station_group:pre:sink",
    },
  },
}
local steps = {}
for epoch, snapshot in ipairs(snapshots) do
  local ok, transport = freight.applyTransportSnapshot(state, snapshot)
  assert(ok, transport)
  local advanced, production = freight.advance(state, epoch, 300)
  assert(advanced, production)
  steps[#steps + 1] = {
    epoch = epoch, cargoLines = snapshot,
    transport = transport, production = production,
    digest = freight.digest(state), digestView = freight.digestView(state),
  }
end
local output = assert(io.open(outputPath, "wb"))
output:write(json.encode({ bootstrap = action, seededOutput = 100, steps = steps }) .. "\n")
output:close()
print("PASS generated " .. tostring(#steps) .. " Lua freight transport parity steps")
