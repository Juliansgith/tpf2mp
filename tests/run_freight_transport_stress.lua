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

local routes = {
  {
    cargoType = "GRAIN", product = "FOOD", rate = 1500000,
    sourceCid = "industry:pre:a-farm", destinationCid = "industry:pre:d-food",
    source = industry("industry:pre:a-farm", "industry/farm.con", 180, {}, { {} },
      { { cargoType = "GRAIN", amount = 1 } }),
    destination = industry("industry:pre:d-food", "industry/food.con", 90,
      { { index = 0, cargoType = "GRAIN", stockType = "RECEIVING", moreCapacity = 100 } },
      { { { stockIndex = 0, cargoType = "GRAIN", amount = 2 } } },
      { { cargoType = "FOOD", amount = 1 } }),
  },
  {
    cargoType = "CRUDE", product = "OIL", rate = 2200000,
    sourceCid = "industry:pre:b-oil-well", destinationCid = "industry:pre:e-refinery",
    source = industry("industry:pre:b-oil-well", "industry/oil_well.con", 160, {}, { {} },
      { { cargoType = "CRUDE", amount = 1 } }),
    destination = industry("industry:pre:e-refinery", "industry/refinery.con", 80,
      { { index = 0, cargoType = "CRUDE", stockType = "RECEIVING", moreCapacity = 100 } },
      { { { stockIndex = 0, cargoType = "CRUDE", amount = 2 } } },
      { { cargoType = "OIL", amount = 1 } }),
  },
  {
    cargoType = "LOGS", product = "PLANKS", rate = 1800000,
    sourceCid = "industry:pre:c-forest", destinationCid = "industry:pre:f-sawmill",
    source = industry("industry:pre:c-forest", "industry/forest.con", 200, {}, { {} },
      { { cargoType = "LOGS", amount = 1 } }),
    destination = industry("industry:pre:f-sawmill", "industry/sawmill.con", 100,
      { { index = 0, cargoType = "LOGS", stockType = "RECEIVING", moreCapacity = 100 } },
      { { { stockIndex = 0, cargoType = "LOGS", amount = 2 } } },
      { { cargoType = "PLANKS", amount = 1 } }),
  },
}

local recipes, seededOutput = {}, {}
for _, route in ipairs(routes) do
  recipes[#recipes + 1] = route.source
  recipes[#recipes + 1] = route.destination
  seededOutput[route.sourceCid] = { [route.cargoType] = 250000 }
end
local action = assert(freight.bootstrapAction("feedbeef", 0, recipes))
local state = freight.newState()
assert(freight.applyBootstrap(state, action, { ready = true, digest = "feedbeef" }))
for industryCid, stocks in pairs(seededOutput) do
  for cargoType, amount in pairs(stocks) do
    state.industries[industryCid].outputStock[cargoType] = amount
  end
end

local lines = {}
for routeIndex, route in ipairs(routes) do
  for lineIndex = 1, 4 do
    local lineCid = string.format("line:freight:%s:%02d", route.cargoType:lower(), lineIndex)
    lines[#lines + 1] = {
      lineCid = lineCid, route = route,
      contractDigest = hash.value({ lineCid = lineCid, source = route.sourceCid,
        destination = route.destinationCid, cargoType = route.cargoType, stockIndex = 0 }),
      activeAfter = lineIndex == 4 and 64 or 1,
      boardedUnits = 0, deliveredUnits = 0, earnedRevenueCents = 0,
    }
  end
end

-- Park-Miller stays below Lua 5.1's exact integer ceiling at every multiply.
local randomState = 104729
local function nextInt(limit)
  randomState = (randomState * 48271) % 2147483647
  return randomState % limit
end

local function snapshotRow(line)
  return {
    contractDigest = line.contractDigest,
    sourceIndustryCid = line.route.sourceCid,
    destinationIndustryCid = line.route.destinationCid,
    destinationStockIndex = 0,
    cargoType = line.route.cargoType,
    boardedUnits = line.boardedUnits,
    deliveredUnits = line.deliveredUnits,
    earnedRevenueCents = line.earnedRevenueCents,
  }
end

local steps = {}
for epoch = 1, 256 do
  local frozenBoundary = epoch % 17 == 0
  local snapshot = {}
  for _, line in ipairs(lines) do
    if epoch >= line.activeAfter and not frozenBoundary then
      local boarded = nextInt(13)
      line.boardedUnits = line.boardedUnits + boarded
      local aboard = line.boardedUnits - line.deliveredUnits
      local delivered = nextInt(math.min(aboard, 15) + 1)
      line.deliveredUnits = line.deliveredUnits + delivered
      line.earnedRevenueCents = line.earnedRevenueCents + delivered * line.route.rate
    end
    snapshot[line.lineCid] = snapshotRow(line)
  end
  -- This zero-movement contract changes halfway through the trace. It must
  -- remain unpinned because an idle line never acquires a transport cursor.
  local idleRoute = epoch < 128 and routes[1] or routes[2]
  snapshot["line:freight:idle"] = {
    contractDigest = epoch < 128 and "11111111" or "22222222",
    sourceIndustryCid = idleRoute.sourceCid,
    destinationIndustryCid = idleRoute.destinationCid,
    destinationStockIndex = 0, cargoType = idleRoute.cargoType,
    boardedUnits = 0, deliveredUnits = 0, earnedRevenueCents = 0,
  }
  local ok, transport = freight.applyTransportSnapshot(state, snapshot)
  assert(ok, transport)
  local advanced, production = freight.advance(state, epoch, 300)
  assert(advanced, production)
  steps[#steps + 1] = {
    epoch = epoch, cargoLines = snapshot,
    transport = transport, production = production,
    digest = freight.digest(state),
  }
end
assert(state.transportCursors["line:freight:idle"] == nil)

local output = assert(io.open(outputPath, "wb"))
output:write(json.encode({
  bootstrap = action, seededOutput = seededOutput, steps = steps,
  finalDigest = freight.digest(state), finalDigestView = freight.digestView(state),
  idleLineCid = "line:freight:idle",
}) .. "\n")
output:close()
print("PASS generated " .. tostring(#steps)
  .. " deterministic multi-cargo freight stress steps at " .. freight.digest(state))
