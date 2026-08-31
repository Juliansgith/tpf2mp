local project = assert(arg[1], "project root argument required"):gsub("\\", "/")
local tempRoot = assert(arg[2], "temporary bridge root required"):gsub("\\", "/")
package.path = project .. "/tpf2_mp_1/res/scripts/?.lua;" .. package.path

local json = require "tpf2_mp/json"
local hash = require "tpf2_mp/hash"
local util = require "tpf2_mp/util"
local canonical = require "tpf2_mp/canonical"
local proposalCodec = require "tpf2_mp/proposal_codec"
local constructionReplayState = require "tpf2_mp/construction_replay_state"
local guiBuildCommandFactory = require "tpf2_mp/gui_build_command_factory"
local operationCodec = require "tpf2_mp/operation_codec"
local guiLineCommandCodec = require "tpf2_mp/gui_line_command_codec"
local economy = require "tpf2_mp/economy"
local economyCosts = require "tpf2_mp/economy_costs"
local economyRevenue = require "tpf2_mp/economy_revenue"
local economyDifficulty = require "tpf2_mp/economy_difficulty"
local economyFeederAccess = require "tpf2_mp/economy_feeder_access"
local economyServiceQuarantine = require "tpf2_mp/economy_service_quarantine"
local economyLineRegistration = require "tpf2_mp/economy_line_registration"
local economySettlementTransaction = require "tpf2_mp/economy_settlement_transaction"
local vehicleResourceFacts = require "tpf2_mp/vehicle_resource_facts"
local industryResourceFacts = require "tpf2_mp/industry_resource_facts"
local industryContentRuntime = require "tpf2_mp/industry_content_runtime"
local freightIndustryModel = require "tpf2_mp/freight_industry_model"
local freightIndustryRuntime = require "tpf2_mp/freight_industry_runtime"
local freightServiceBinding = require "tpf2_mp/freight_service_binding"
local validationContentGate = require "tpf2_mp/validation_content_gate"
local worldIndustryReading = require "tpf2_mp/world_industry_reading"
local corridorBindingModule = require "tpf2_mp/corridor_binding"
local bridge = require "tpf2_mp/bridge"
local finance = require "tpf2_mp/finance"
local world = require "tpf2_mp/world"
local guiView = require "tpf2_mp/gui_view"
local presentation = require "tpf2_mp/presentation"
local passengerPresentation = require "tpf2_mp/passenger_presentation"
local cargoPresentation = require "tpf2_mp/cargo_presentation"
local vehicleSyncPassengers = require "tpf2_mp/vehicle_sync_passengers"
local deliverySnapshot = require "tpf2_mp/delivery_snapshot"
local passengerCosmetics = require "tpf2_mp/passenger_cosmetics"
local nativeHook = require "tpf2_mp/native_hook"
local nativeCommandAuthority = require "tpf2_mp/native_command_authority"
local nativeOwnershipProjection = require "tpf2_mp/native_ownership_projection"
local matchRuntimeModule = require "tpf2_mp/match_runtime"
local stationReadingModule = require "tpf2_mp/world_station_reading"
local stationAccessModule = require "tpf2_mp/world_station_access"
local validationConstruction = require "tpf2_mp/validation_construction"
local performanceRuntime = require "tpf2_mp/performance_runtime"
local guiReplayWorkIndex = require "tpf2_mp/gui_replay_work_index"
local activeRecordIndex = require "tpf2_mp/active_record_index"

local tests, passed = {}, 0

local function test(name, fn)
  tests[#tests + 1] = { name = name, fn = fn }
end

local function equal(actual, expected, message)
  if actual ~= expected then
    error((message or "values differ") .. ": expected " .. tostring(expected) .. ", got " .. tostring(actual), 2)
  end
end

local function truthy(value, message)
  if not value then error(message or "expected truthy value", 2) end
end

test("canonical JSON and cross-language checksum", function()
  local encoded = json.encode({ b = 2, a = "x" })
  equal(encoded, [[{"a":"x","b":2}]])
  equal(hash.text(encoded), "1ec003d2")
  equal(json.encode({ transform = { -0.0, 0.0 } }), [[{"transform":[0,0]}]],
    "canonical JSON retained an IEEE-754 negative zero")
  local decoded = json.decode(encoded)
  equal(decoded.a, "x")
  equal(decoded.b, 2)
end)

test("mod-authored native commands consume and revoke exact visitor tokens", function()
  local previousApi = api
  local previousAuthorize = rawget(_G, "tpf2mp_native_authorize_command")
  local previousRevoke = rawget(_G, "tpf2mp_native_revoke_command")
  local authorized, revoked, sent = {}, {}, {}
  local ok, failure = xpcall(function()
    rawset(_G, "tpf2mp_native_authorize_command", function(tag)
      authorized[#authorized + 1] = tag
    end)
    rawset(_G, "tpf2mp_native_revoke_command", function(tag)
      revoked[#revoked + 1] = tag
    end)
    api = { cmd = { sendCommand = function(command, callback)
      sent[#sent + 1] = command
      if callback then callback(command, true) end
    end } }
    local commandOk, result = nativeCommandAuthority.send(
      19, { kind = "developTown" }, function() end, "test.town-development")
    truthy(commandOk, result)
    equal(authorized[1], "19")
    equal(#revoked, 0)
    equal(sent[1].kind, "developTown")

    api.cmd.sendCommand = function() error("transport failed before visitor") end
    commandOk, result = nativeCommandAuthority.send(
      23, { kind = "freezeIndustry" }, nil, "test.industry-freeze")
    equal(commandOk, false)
    truthy(tostring(result):find("transport failed", 1, true))
    equal(authorized[2], "23")
    equal(revoked[1], "23", "unused native authorization was left armed")

    rawset(_G, "tpf2mp_native_authorize_command", nil)
    rawset(_G, "tpf2mp_native_revoke_command", nil)
    api.cmd.sendCommand = function(command) sent[#sent + 1] = command end
    commandOk, result = nativeCommandAuthority.send(
      20, { kind = "standaloneTownInfo" }, nil, "test.standalone")
    truthy(commandOk, result)
    equal(sent[#sent].kind, "standaloneTownInfo")
  end, debug.traceback)
  api = previousApi
  rawset(_G, "tpf2mp_native_authorize_command", previousAuthorize)
  rawset(_G, "tpf2mp_native_revoke_command", previousRevoke)
  if not ok then error(failure, 0) end
end)

test("industry resource facts normalize and bind evaluated recipes", function()
  local registry = industryResourceFacts.newRegistry()
  local farm = {
    stocks = {},
    rule = { input = { {} }, output = { GRAIN = 1 }, capacity = 200 },
  }
  local captured, facts = industryResourceFacts.capture(
    registry, "industry/farm.con", { productionLevel = 0, seed = 41, year = 1990 }, farm)
  truthy(captured)
  equal(facts.capacity, 200)
  equal(facts.outputs[1].cargoType, "GRAIN")
  equal(facts.outputs[1].amount, 1)
  equal(#facts.stocks, 0)
  equal(#facts.inputs, 1)
  equal(#facts.inputs[1], 0)

  local lookedUp = assert(industryResourceFacts.lookup(
    registry, "industry/farm.con", { productionLevel = 0, seed = 999 }))
  equal(lookedUp.digest, facts.digest,
    "volatile seed unexpectedly became industry recipe identity")

  local mill = {
    stocks = {
      { cargoType = "IRON_ORE", moreCapacity = 100 },
      { cargoType = "COAL", type = "RECEIVING" },
    },
    rule = { input = { { 2, 2 } }, output = { STEEL = 1 }, capacity = 400 },
  }
  truthy(industryResourceFacts.capture(
    registry, "industry/steel_mill.con", { productionLevel = 1 }, mill))
  local steel = assert(industryResourceFacts.lookup(
    registry, "industry/steel_mill.con", { productionLevel = 1 }))
  equal(steel.capacity, 400)
  equal(steel.inputs[1][1].stockIndex, 0)
  equal(steel.inputs[1][1].cargoType, "IRON_ORE")
  equal(steel.inputs[1][1].amount, 2)
  equal(steel.inputs[1][2].cargoType, "COAL")
  equal(steel.stocks[2].stockType, "RECEIVING")

  local digest = industryResourceFacts.digest(registry)
  registry.diagnostics.captureCount = 999999
  registry.diagnostics.failures["local-only"] = true
  equal(industryResourceFacts.digest(registry), digest,
    "local capture diagnostics leaked into content authority")
end)

test("industry resource facts fail closed on hidden callback inputs", function()
  local registry = industryResourceFacts.newRegistry()
  local first = {
    stocks = {}, rule = { input = { {} }, output = { GRAIN = 1 }, capacity = 200 },
  }
  local second = {
    stocks = {}, rule = { input = { {} }, output = { STONE = 1 }, capacity = 200 },
  }
  truthy(industryResourceFacts.capture(
    registry, "mod/seeded.con", { productionLevel = 0, seed = 1 }, first))
  local accepted, errorText = industryResourceFacts.capture(
    registry, "mod/seeded.con", { productionLevel = 0, seed = 2 }, second)
  equal(accepted, false)
  truthy(tostring(errorText):find("non%-persisted"))
  local missing, lookupError = industryResourceFacts.lookup(
    registry, "mod/seeded.con", { productionLevel = 0, seed = 3 })
  equal(missing, nil)
  equal(lookupError, "industry recipe is ambiguous")

  local bad, badError = industryResourceFacts.normalize(
    "mod/fractional.con", {}, {
      stocks = {}, rule = { input = { {} }, output = { OIL = 0.5 }, capacity = 100 },
    })
  equal(bad, nil)
  truthy(tostring(badError):find("non%-negative integer"))

  local sink = assert(industryResourceFacts.normalize("mod/sink.con", {}, {
    stocks = { { cargoType = "GOODS" } },
    rule = { input = { { 1 } }, output = {}, capacity = 100 },
  }))
  equal(#sink.outputs, 0)
  equal(sink.inputs[1][1].cargoType, "GOODS")
  local noFlow, noFlowError = industryResourceFacts.normalize("mod/noop.con", {}, {
    stocks = {}, rule = { input = { {} }, output = {}, capacity = 100 },
  })
  equal(noFlow, nil)
  truthy(tostring(noFlowError):find("no positive input or output", 1, true))
end)

test("industry construction wrapper preserves the native result", function()
  local registry = industryResourceFacts.newRegistry()
  local calls = 0
  local construction = {
    type = 10,
    updateFn = function(params)
      calls = calls + 1
      return {
        marker = params.marker,
        stocks = { { cargoType = "LOGS" } },
        rule = { input = { { 2 } }, output = { PLANKS = 1 }, capacity = 200 },
      }
    end,
  }
  local wrapped, changed = industryResourceFacts.wrap(
    registry, "industry/saw_mill.con", construction)
  equal(wrapped, construction)
  equal(changed, true)
  local result = construction.updateFn({ productionLevel = 0, marker = "kept", seed = 4 })
  equal(calls, 1)
  equal(result.marker, "kept")
  local facts = assert(industryResourceFacts.lookup(
    registry, "industry/saw_mill.con", { productionLevel = 0, marker = "kept" }))
  equal(facts.inputs[1][1].cargoType, "LOGS")
  equal(facts.outputs[1].cargoType, "PLANKS")
end)

test("standard data-only industry variants are captured without callback execution", function()
  local registry = industryResourceFacts.newRegistry()
  local stockListConfig = {
    stocks = { "ORE" },
    rule = { input = { { 2 } }, output = { METAL = 1 }, capacity = 100 },
  }
  local callbackCalls = 0
  local construction = {
    type = "INDUSTRY",
    params = {
      { key = "productionLevel", values = { "1", "2" } },
      { key = "inputEnabled", values = { "off", "on" }, defaultIndex = 1 },
    },
    updateFn = function(params)
      callbackCalls = callbackCalls + 1
      local level = (params.productionLevel or 0) + 1
      local enabled = (params.inputEnabled or 1) == 1
      return {
        stocks = enabled and { { cargoType = stockListConfig.stocks[1] } } or {},
        rule = {
          input = enabled and stockListConfig.rule.input or { {} },
          output = stockListConfig.rule.output,
          capacity = stockListConfig.rule.capacity * level,
        },
      }
    end,
  }
  local _, wrapped = industryResourceFacts.wrap(registry, "mod/processor.con", construction)
  truthy(wrapped)
  local captured, summary = industryResourceFacts.captureStandardVariants(
    registry, "mod/processor.con", construction)
  truthy(captured)
  equal(summary.combinations, 4)
  equal(summary.captured, 4)
  equal(callbackCalls, 0, "static industry capture executed the construction callback")
  local omittedDefaults = assert(industryResourceFacts.lookup(
    registry, "mod/processor.con", { productionLevel = 0, seed = 999 }))
  local explicitDefaults = assert(industryResourceFacts.lookup(
    registry, "mod/processor.con", { productionLevel = 0, inputEnabled = 1 }))
  equal(omittedDefaults.digest, explicitDefaults.digest)
  equal(omittedDefaults.inputs[1][1].cargoType, "ORE")
  local disabled = assert(industryResourceFacts.lookup(
    registry, "mod/processor.con", { productionLevel = 1, inputEnabled = 0 }))
  equal(#disabled.inputs[1], 0)
  equal(disabled.outputs[1].amount, 1)
  equal(disabled.capacity, 200)
end)

test("parallel industry registries merge idempotently and path-portably", function()
  local first = industryResourceFacts.newRegistry()
  local second = industryResourceFacts.newRegistry()
  truthy(industryResourceFacts.capture(first,
    "res/construction/industry/farm.con", { productionLevel = 0 }, {
      stocks = {}, rule = { input = { {} }, output = { GRAIN = 1 }, capacity = 200 },
    }))
  truthy(industryResourceFacts.capture(second,
    "industry/steel_mill.con", { productionLevel = 0 }, {
      stocks = { { cargoType = "IRON_ORE" }, { cargoType = "COAL" } },
      rule = { input = { { 2, 2 } }, output = { STEEL = 1 }, capacity = 200 },
    }))
  local merged = assert(industryResourceFacts.merge(nil, first))
  local once = industryResourceFacts.digest(merged)
  merged = assert(industryResourceFacts.merge(merged, first))
  equal(industryResourceFacts.digest(merged), once,
    "replaying a parallel resource partition changed authority")
  merged = assert(industryResourceFacts.merge(merged, second))
  local reconstructed = assert(industryResourceFacts.fromDigestView(
    industryResourceFacts.digestView(merged)))
  equal(industryResourceFacts.digest(reconstructed), industryResourceFacts.digest(merged),
    "engine-side registry reconstruction changed the content digest")
  truthy(industryResourceFacts.lookup(
    merged, "industry/farm.con", { productionLevel = 0 }),
    "resource-loader and live-entity paths did not canonicalize")
  truthy(industryResourceFacts.lookup(
    merged, "res/construction/industry/steel_mill.con", { productionLevel = 0 }))
  local artifact = assert(industryResourceFacts.resourceArtifact(
    merged, "res/construction/industry/farm.con"))
  equal(artifact.resource.fileName, "industry/farm.con")
  equal(artifact.digest, hash.value({
    schemaVersion = artifact.schemaVersion, resource = artifact.resource,
  }))
  local artifactWritten, artifactPath = industryResourceFacts.writeResourceArtifact(
    merged, "industry/farm.con", tempRoot)
  truthy(artifactWritten, tostring(artifactPath))
  local artifactFile = assert(io.open(artifactPath, "rb"))
  local decodedArtifact = json.decode(artifactFile:read("*a"))
  artifactFile:close()
  equal(decodedArtifact.digest, artifact.digest)

  local conflictA = industryResourceFacts.newRegistry()
  local conflictB = industryResourceFacts.newRegistry()
  truthy(industryResourceFacts.capture(conflictA, "mod/opaque.con", {}, {
    stocks = {}, rule = { input = { {} }, output = { OIL = 1 }, capacity = 100 },
  }))
  truthy(industryResourceFacts.capture(conflictB, "mod/opaque.con", {}, {
    stocks = {}, rule = { input = { {} }, output = { FUEL = 1 }, capacity = 100 },
  }))
  local left = assert(industryResourceFacts.merge(nil, conflictA))
  left = assert(industryResourceFacts.merge(left, conflictB))
  local right = assert(industryResourceFacts.merge(nil, conflictB))
  right = assert(industryResourceFacts.merge(right, conflictA))
  equal(industryResourceFacts.digest(left), industryResourceFacts.digest(right),
    "parallel conflict digest depended on merge order")
  local missing, conflictError = industryResourceFacts.lookup(left, "mod/opaque.con", {})
  equal(missing, nil)
  equal(conflictError, "industry recipe is ambiguous")
end)

test("live industry reader binds construction roots to captured recipes", function()
  local registry = industryResourceFacts.newRegistry()
  truthy(industryResourceFacts.capture(registry, "industry/steel_mill.con",
    { productionLevel = 1, seed = 17 }, {
      stocks = { { cargoType = "IRON_ORE" }, { cargoType = "COAL" } },
      rule = { input = { { 2, 2 } }, output = { STEEL = 1 }, capacity = 400 },
    }))
  local registryDocument = assert(io.open(
    tempRoot .. "/companion_state/industry_registry.json", "wb"))
  registryDocument:write(json.encode({
    schemaVersion = 1,
    session = "industry-reader-test",
    peer = "player1",
    digest = industryResourceFacts.digest(registry),
    resourceCount = 1,
    variantCount = 1,
    ambiguousCount = 0,
    view = industryResourceFacts.digestView(registry),
  }) .. "\n")
  registryDocument:close()
  local callableRoot = setmetatable({}, {
    __call = function(_, entity) return entity == 77 and 900 or nil end,
  })
  local currentGame = {
    config = { tpf2mp = { industryResourceFacts = industryResourceFacts.newRegistry() } },
    interface = { getEntity = function(entity)
      if entity == 900 then return {
        fileName = "industry/steel_mill.con",
        params = { productionLevel = 1, seed = 999 },
      } end
    end },
  }
  local currentApi = {
    res = { getBaseConfig = setmetatable({}, {
      __call = function() return { tpf2mp = { industryResourceFacts = registry } } end,
    }) },
    engine = { system = {
      streetConnectorSystem = { getConstructionEntityForSimBuilding = callableRoot },
    } },
  }
  local canonicalBinding = "industry:pre:steel"
  local reader = worldIndustryReading.new({
    getApi = function() return currentApi end,
    getGame = function() return currentGame end,
    entityNumber = tonumber,
    resourceFacts = industryResourceFacts,
    listIndustries = function() return { 77 } end,
    resolveCanonical = function(_, localId)
      if localId == 77 then return canonicalBinding end
    end,
    getRuntimeIdentity = function() return {
      root = tempRoot, peerId = "player1", sessionId = "industry-reader-test",
    } end,
  })
  local probe = reader.registryProbe()
  truthy(probe.available)
  equal(probe.resourceCount, 1)
  equal(probe.variantCount, 1)
  equal(probe.ambiguousCount, 0)
  equal(probe.source, "companion-sidecar")
  local bound = assert(reader.recipeForIndustry(77))
  equal(bound.constructionId, 900)
  equal(bound.rootSource, "streetConnectorSystem")
  equal(bound.recipe.inputs[1][2].cargoType, "COAL")
  equal(bound.recipe.outputs[1].cargoType, "STEEL")
  local portable = assert(reader.portableFacts({}))
  equal(#portable, 1)
  equal(portable[1].cid, "industry:pre:steel")
  equal(portable[1].recipeDigest, bound.recipe.digest)
  equal(portable[1].constructionId, nil, "local construction id escaped portable facts")
  canonicalBinding = nil
  local missingPortable, portableError = reader.portableFacts({})
  equal(missingPortable, nil)
  truthy(tostring(portableError):find("canonical binding", 1, true))
  canonicalBinding = "industry:pre:steel"

  -- If the convenience system is absent, Build 35924 exposes the same root
  -- through SIM_BUILDING.stockList.
  currentApi = {
    res = { getBaseConfig = function()
      return { tpf2mp = { industryResourceFacts = registry } }
    end },
    type = { ComponentType = { SIM_BUILDING = "SIM_BUILDING" } },
    engine = {
      system = {},
      getComponent = function(entity, componentType)
        if entity == 77 and componentType == "SIM_BUILDING" then return { stockList = 900 } end
      end,
    },
  }
  local fallback = assert(reader.recipeForIndustry(77))
  equal(fallback.rootSource, "SIM_BUILDING.stockList")
end)

local function freightFixture(cid, resource, capacity, stocks, inputs, outputs, params)
  local recipe = {
    cid = cid, resource = resource, params = params or {}, capacity = capacity,
    stocks = stocks or {}, inputs = inputs, outputs = outputs or {},
  }
  recipe.recipeDigest = hash.value({
    resource = recipe.resource, params = recipe.params, stocks = recipe.stocks,
    inputs = recipe.inputs, outputs = recipe.outputs, capacity = recipe.capacity,
  })
  return recipe
end

local function freightFixtures()
  return {
    freightFixture("industry:pre:a-farm", "industry/farm.con", 120,
      {}, { {} }, { { cargoType = "GRAIN", amount = 1 } }, { productionLevel = 0 }),
    freightFixture("industry:pre:b-mill", "industry/food_processing_plant.con", 60,
      { { index = 0, cargoType = "GRAIN", stockType = "RECEIVING", moreCapacity = 100 } },
      { { { stockIndex = 0, cargoType = "GRAIN", amount = 2 } } },
      { { cargoType = "FOOD", amount = 1 } }, { productionLevel = 0 }),
    freightFixture("industry:pre:c-consumer", "mod/consumer.con", 60,
      { { index = 0, cargoType = "FOOD", stockType = "RECEIVING", moreCapacity = 0 } },
      { { { stockIndex = 0, cargoType = "FOOD", amount = 1 } } }, {}, {}),
  }
end

test("freight industries bootstrap, produce, consume, and migrate deterministically", function()
  local action = assert(freightIndustryModel.bootstrapAction("edc7a517", 4, freightFixtures()))
  local valid, rebuilt = freightIndustryModel.validateBootstrapAction(action)
  truthy(valid)
  equal(rebuilt.digest, action.digest)
  local tampered = util.deepCopy(action)
  tampered.industries[1].outputs[1].amount = 2
  local accepted, tamperError = freightIndustryModel.validateBootstrapAction(tampered)
  equal(accepted, false)
  truthy(tostring(tamperError):find("recipe digest", 1, true))

  local state = freightIndustryModel.newState()
  truthy(freightIndustryModel.applyBootstrap(
    state, action, { ready = true, digest = "edc7a517" }))
  equal(state.productionEpoch, 4)
  local advanced, first = freightIndustryModel.advance(state, 5, 300)
  truthy(advanced)
  equal(first.industries["industry:pre:a-farm"].cycles, 10)
  equal(first.industries["industry:pre:b-mill"].cycles, 0)
  equal(state.industries["industry:pre:a-farm"].outputStock.GRAIN, 10)

  local deposited, grainStock = freightIndustryModel.depositInput(
    state, "industry:pre:b-mill", "GRAIN", 20)
  truthy(deposited)
  equal(grainStock, 20)
  truthy(freightIndustryModel.advance(state, 6, 300))
  equal(state.industries["industry:pre:b-mill"].inputStock[1].amount, 10)
  equal(state.industries["industry:pre:b-mill"].outputStock.FOOD, 5)
  equal(state.totalConsumed.GRAIN, 10)
  equal(state.totalProduced.FOOD, 5)

  truthy(freightIndustryModel.depositInput(
    state, "industry:pre:c-consumer", "FOOD", 3))
  truthy(freightIndustryModel.advance(state, 7, 300))
  equal(state.industries["industry:pre:c-consumer"].lastCycles, 3)
  equal(state.industries["industry:pre:c-consumer"].inputStock[1].amount, 0)
  equal(state.totalConsumed.FOOD, 3)
  local withdrawn, remaining = freightIndustryModel.withdrawOutput(
    state, "industry:pre:a-farm", "GRAIN", 7)
  truthy(withdrawn)
  equal(remaining, 23)
  equal(freightIndustryModel.digest(state), "7fe9cd81",
    "Lua freight state diverged from the Python replay vector")

  local beforeMigration = freightIndustryModel.digest(state)
  local migrated, migrationError = freightIndustryModel.migrate(util.deepCopy(state))
  equal(migrationError, nil)
  equal(freightIndustryModel.digest(migrated), beforeMigration)
  local corrupted = util.deepCopy(state)
  corrupted.bootstrapDigest = "00000000"
  local reset, resetError = freightIndustryModel.migrate(corrupted)
  equal(reset.ready, false)
  truthy(tostring(resetError):find("bootstrap digest", 1, true))
  equal(reset.migrationError, resetError)

  local duplicate = freightFixture("industry:pre:duplicate", "mod/duplicate.con", 60,
    {
      { index = 0, cargoType = "GRAIN", stockType = "RECEIVING", moreCapacity = 0 },
      { index = 1, cargoType = "GRAIN", stockType = "RECEIVING", moreCapacity = 0 },
    }, { { { stockIndex = 1, cargoType = "GRAIN", amount = 1 } } }, {}, {})
  local duplicateAction = assert(freightIndustryModel.bootstrapAction("edc7a517", 0, { duplicate }))
  local duplicateState = freightIndustryModel.newState()
  truthy(freightIndustryModel.applyBootstrap(
    duplicateState, duplicateAction, { ready = true, digest = "edc7a517" }))
  local ambiguous, ambiguousError = freightIndustryModel.depositInput(
    duplicateState, duplicate.cid, "GRAIN", 1)
  equal(ambiguous, false)
  truthy(tostring(ambiguousError):find("ambiguous", 1, true))
  truthy(freightIndustryModel.depositInputAtStock(
    duplicateState, duplicate.cid, 1, "GRAIN", 2))
  equal(duplicateState.industries[duplicate.cid].inputStock[2].amount, 2)
end)

test("freight bootstrap runtime is host-authored, epoch-bound, and checkpointed", function()
  local state = {
    tick = 40, initialized = true, networkMode = "network",
    bridge = { peerId = "player1" }, match = { status = "running" }, canonical = {},
    economy = { epoch = 4, scheduler = { epochSeconds = 300 } },
    world = {
      industryContent = { ready = true, digest = "edc7a517" },
      freightIndustry = freightIndustryModel.newState(),
    },
    probes = { freightIndustry = freightIndustryModel.newProbe() },
  }
  local submitted
  local changed = freightIndustryRuntime.maintain(state, {
    readFacts = function() return freightFixtures() end,
    localWorkState = function() return { pending = false } end,
    submitIntent = function(action) submitted = util.deepCopy(action); return true, {} end,
  })
  truthy(changed)
  equal(submitted.type, "freight.industry_bootstrap")
  equal(submitted.economyEpoch, 4)
  equal(state.probes.freightIndustry.status, "bootstrap-submitted")

  state.bridge.peerId = "player2"
  state.probes.freightIndustry = freightIndustryModel.newProbe()
  local clientChanged = freightIndustryRuntime.maintain(state, {
    readFacts = function() error("client must not bind a host action proactively") end,
    localWorkState = function() return { pending = false } end,
    submitIntent = function() error("client must not submit bootstrap") end,
  })
  equal(clientChanged, false)
  equal(state.probes.freightIndustry.status, "waiting-for-host-bootstrap")
  local clientAction, clientError = freightIndustryRuntime.normaliseIntent(
    state, "player2", function() return freightFixtures() end)
  equal(clientAction, nil)
  truthy(tostring(clientError):find("only the host", 1, true))

  state.bridge.peerId = "player1"
  local applied, applyError = freightIndustryRuntime.applyBootstrap(state, submitted, {
    readFacts = function() return freightFixtures() end,
  })
  truthy(applied, applyError)
  equal(state.world.freightIndustry.ready, true)

  local loaded = util.deepCopy(state)
  loaded.probes.freightIndustry = freightIndustryModel.newProbe()
  local maintained = freightIndustryRuntime.maintain(loaded, {
    readFacts = function() return freightFixtures() end,
    localWorkState = function() return { pending = false } end,
    submitIntent = function() error("a saved bootstrap must be revalidated, not resubmitted") end,
  })
  equal(maintained, false)
  equal(loaded.probes.freightIndustry.status, "ready")
  equal(loaded.probes.freightIndustry.validatedBootstrapDigest, submitted.digest)
  local commitProduction, production = freightIndustryRuntime.prepareSettlement(
    loaded, { epoch = 5 })
  truthy(commitProduction, production)
  commitProduction()
  equal(loaded.world.freightIndustry.productionEpoch, 5)

  local unvalidated = util.deepCopy(state)
  unvalidated.probes.freightIndustry = freightIndustryModel.newProbe()
  local blockedCommit, blockedError = freightIndustryRuntime.prepareSettlement(
    unvalidated, { epoch = 5 })
  equal(blockedCommit, nil)
  truthy(tostring(blockedError):find("live industry bindings", 1, true))

  local changedContent = util.deepCopy(state)
  changedContent.world.industryContent.digest = "11111111"
  changedContent.probes.freightIndustry = freightIndustryModel.newProbe()
  freightIndustryRuntime.maintain(changedContent, {
    readFacts = function() return freightFixtures() end,
    localWorkState = function() return { pending = false } end,
    submitIntent = function() error("content mismatch must not submit") end,
  })
  equal(changedContent.world.operationConsensus.sessionFault.errorCode,
    "freight-industry-content-mismatch")

  local changedBinding = util.deepCopy(state)
  changedBinding.probes.freightIndustry = freightIndustryModel.newProbe()
  local changedFixtures = freightFixtures()
  changedFixtures[1] = freightFixture(
    "industry:pre:a-farm", "industry/farm.con", 120, {}, { {} },
    { { cargoType = "STONE", amount = 1 } }, { productionLevel = 0 })
  freightIndustryRuntime.maintain(changedBinding, {
    readFacts = function() return changedFixtures end,
    localWorkState = function() return { pending = false } end,
    submitIntent = function() error("binding mismatch must not submit") end,
  })
  equal(changedBinding.world.operationConsensus.sessionFault.errorCode,
    "freight-industry-binding-mismatch")

  local corruptedSave = util.deepCopy(state)
  corruptedSave.world.freightIndustry = freightIndustryModel.migrate({
    ready = true, bootstrapDigest = "00000000", industries = {},
  })
  freightIndustryRuntime.maintain(corruptedSave, {
    readFacts = function() error("corrupt save must fault before live binding") end,
  })
  equal(corruptedSave.world.operationConsensus.sessionFault.errorCode,
    "freight-industry-save-invalid")

  local staleState = util.deepCopy(state)
  staleState.world.freightIndustry = freightIndustryModel.newState()
  staleState.economy.epoch = 5
  local staleAccepted, staleError = freightIndustryRuntime.applyBootstrap(staleState, submitted, {
    readFacts = function() return freightFixtures() end,
  })
  equal(staleAccepted, false)
  truthy(tostring(staleError):find("local epoch", 1, true))

  local exports = 0
  truthy(freightIndustryRuntime.afterCommit(state, submitted, true, 9,
    function(boundary, reason)
      exports = exports + 1
      equal(boundary, 9)
      equal(reason, "freight-industry-bootstrap")
      return true
    end, function() end))
  equal(exports, 1)
end)

test("industry content attestations converge and fault mismatched peers", function()
  local state = {
    tick = 10,
    bridge = { peerId = "player1" },
    world = {
      industryContent = industryContentRuntime.newState(),
      operationConsensus = { sessionFault = nil, lastOutcome = nil },
    },
    probes = { industryContent = industryContentRuntime.newProbe() },
  }
  local first = {
    type = "content.industry_attest", peer = "player1", digest = "edc7a517",
    resourceCount = 16, variantCount = 160, ambiguousCount = 0,
  }
  local accepted, waiting = industryContentRuntime.apply(state, first)
  truthy(accepted)
  equal(waiting.ready, false)
  equal(state.world.industryContent.ready, false)
  local second = util.deepCopy(first)
  second.peer = "player2"
  local converged, result = industryContentRuntime.apply(state, second)
  truthy(converged)
  truthy(result.ready)
  equal(state.world.industryContent.digest, "edc7a517")
  equal(state.world.operationConsensus.sessionFault, nil)

  local mismatched = industryContentRuntime.newState()
  state.world.industryContent = mismatched
  state.world.operationConsensus = { sessionFault = nil, lastOutcome = nil }
  truthy(industryContentRuntime.apply(state, first))
  second.digest = "11111111"
  truthy(industryContentRuntime.apply(state, second))
  equal(mismatched.ready, false)
  equal(mismatched.fault.errorCode, "industry-content-mismatch")
  equal(state.world.operationConsensus.sessionFault.errorCode,
    "industry-content-mismatch")

  local invalid = util.deepCopy(first)
  invalid.ambiguousCount = "0"
  local valid, validationError = industryContentRuntime.validateAction(invalid)
  equal(valid, false)
  truthy(tostring(validationError):find("ambiguousCount", 1, true))
end)

test("pre-match content consensus defers its financial checkpoint", function()
  local state = {
    tick = 12, initialized = false,
    world = { industryContent = industryContentRuntime.newState() },
  }
  state.world.industryContent.ready = true
  local exports, logs = 0, {}
  local action = { type = "content.industry_attest" }
  truthy(industryContentRuntime.afterCommit(state, action, true, 2,
    function() exports = exports + 1; return true end,
    function(event, payload) logs[#logs + 1] = { event, payload } end))
  equal(exports, 0)
  equal(logs[1][1], "industry-content-checkpoint-deferred")
  equal(logs[1][2].reason, "match-not-initialised")

  state.initialized = true
  truthy(industryContentRuntime.afterCommit(state, action, true, 3,
    function(boundary, reason)
      exports = exports + 1
      equal(boundary, 3)
      equal(reason, "industry-content-ready")
      return true
    end,
    function() end))
  equal(exports, 1)
end)

test("industry content maintenance submits exact sidecar counts only on an idle lane", function()
  local state = {
    tick = 20, networkMode = "network", bridge = { peerId = "player1" },
    world = {
      industryContent = industryContentRuntime.newState(),
      operationConsensus = { sessionFault = nil, lastOutcome = nil },
    },
    probes = { industryContent = industryContentRuntime.newProbe() },
  }
  local submitted
  local changed = industryContentRuntime.maintain(state, {
    readFacts = function() return {
      available = true, source = "companion-sidecar", digest = "edc7a517",
      resourceCount = 16, variantCount = 160, ambiguousCount = 0,
    } end,
    localWorkState = function() return { pending = false } end,
    submitIntent = function(action) submitted = util.deepCopy(action); return true, {} end,
  })
  truthy(changed)
  equal(submitted.resourceCount, 16)
  equal(submitted.variantCount, 160)
  equal(submitted.ambiguousCount, 0)
  equal(state.probes.industryContent.status, "attestation-submitted")
end)

test("network validation waits for content consensus and an idle ordered lane", function()
  local state = {
    tick = 10,
    probes = { industryContent = { localDigest = "edc7a517" } },
    world = { industryContent = { ready = false } },
  }
  local validation = {
    stage = "wait-for-network", stageStartedTick = 10, values = {},
  }
  truthy(validationContentGate.observe(state, validation))
  local pending, submissions, deferred = false, 0, {}
  local deps = {
    awaitingOrder = function() return pending end,
    pendingBarrierReason = function() return nil end,
    submit = function(action, label)
      submissions = submissions + 1
      equal(action.type, "match.initialise")
      equal(label, submissions == 1 and "initial" or "host-match-initialise-retry-queued")
      return { local_seq = 70 + submissions }
    end,
    log = function(event, payload) deferred[#deferred + 1] = { event, payload } end,
  }
  equal(validationContentGate.trySubmit(state, validation, deps, "initial", false), false)
  equal(submissions, 0)
  equal(deferred[1][2].reason, "industry-content-not-ready")

  state.world.industryContent.ready = true
  pending = true
  state.tick = 20
  equal(validationContentGate.trySubmit(state, validation, deps, "initial", false), false)
  equal(deferred[2][2].reason, "ordered-lane-busy")

  pending = false
  state.tick = 21
  truthy(validationContentGate.trySubmit(state, validation, deps, "initial", false))
  equal(submissions, 1)
  state.tick = 80
  equal(validationContentGate.retry(state, validation, deps, 60), false)
  state.tick = 81
  truthy(validationContentGate.retry(state, validation, deps, 60))
  equal(submissions, 2)
  equal(validation.values.initialiseLocalSeq, 72)
end)

test("match runtime preserves ranking and bankruptcy precedence", function()
  local originalScoreboard = economy.scoreboard
  local ok, failure = xpcall(function()
    economy.scoreboard = function()
      return {
        ["company:1"] = {
          companyCid = "company:1", modelValueCents = 100,
          settledRevenueCents = 50, settledDemand = 10, marketWins = 1,
        },
        ["company:2"] = {
          companyCid = "company:2", modelValueCents = 200,
          settledRevenueCents = 60, settledDemand = 12, marketWins = 2,
        },
      }
    end
    local state = {
      initialized = true,
      tick = 77,
      match = { status = "running", rules = {} },
      companies = { ["company:1"] = {}, ["company:2"] = {} },
      companyOrder = { "company:1", "company:2" },
      economy = { epoch = 0 },
      finance = { networkAccounts = { bankruptCid = "company:2" } },
      probes = { bankruptCid = "company:1" },
    }
    local runtime = matchRuntimeModule.new({ getState = function() return state end })
    local winnerCid, ranked = runtime.rankedWinner()
    equal(winnerCid, "company:2")
    equal(ranked[1].companyCid, "company:2")
    local result = runtime.evaluateEnd()
    equal(result.match.finishReason, "bankruptcy")
    equal(result.match.winnerCid, "company:1")
    equal(result.match.finishedTick, 77)
    local running, runningError = runtime.requireRunning()
    equal(running, false)
    equal(runningError, "match is not running")
    equal(state.probes.bankruptCid, "company:1",
      "diagnostic probe was unexpectedly treated as authored bankruptcy state")
  end, debug.traceback)
  economy.scoreboard = originalScoreboard
  if not ok then error(failure, 0) end
end)

test("mod command origins are synchronous and always restored", function()
  local previousApi = api
  local observed
  api = { cmd = { sendCommand = function(command, callback)
    observed = util.currentCommandOrigin()
    if callback then callback(command, true) end
    return "sent"
  end } }
  local callbackSeen = false
  local ok, result = util.sendCommand({ kind = "test" }, function(_, success)
    callbackSeen = success == true and util.currentCommandOrigin() == "mod.test"
  end, "mod.test")
  truthy(ok and result == "sent" and observed == "mod.test" and callbackSeen,
    "command origin was not visible for the complete synchronous issue path")
  equal(util.currentCommandOrigin(), nil, "command origin leaked after success")
  api.cmd.sendCommand = function() error("expected failure") end
  local failed = util.sendCommand({}, nil, "mod.failure")
  equal(failed, false, "throwing sendCommand was not reported")
  equal(util.currentCommandOrigin(), nil, "command origin leaked after failure")
  api = previousApi
end)

test("native hook status retains vehicle capture diagnostics", function()
  local compact = nativeHook.compactStatus({
    gates = {
      commandVisitors = {
        suppressedVehicleCommands = {
          queued = 1, captured = 3, consumed = 2, invalid = 0, dropped = 0,
          lastTag = 13, lastTarget = 100, lastSecondary = 750,
        },
      },
    },
  })
  equal(compact.suppressedVehicleCommands.queued, 1)
  equal(compact.suppressedVehicleCommands.captured, 3)
  equal(compact.suppressedVehicleCommands.consumed, 2)
  equal(compact.suppressedVehicleCommands.lastTag, 13)
  equal(compact.suppressedVehicleCommands.lastSecondary, 750)
end)

test("canonical registry detects identity conflicts", function()
  local state = canonical.newState()
  truthy(canonical.bind(state, "line:event:e:1", "line", 42))
  equal(canonical.resolveLocal(state, "line:event:e:1"), 42)
  equal(canonical.resolveCanonical(state, "line", 42), "line:event:e:1")
  local ok = canonical.bind(state, "line:event:e:2", "line", 42)
  equal(ok, false)
end)

test("canonical digest view excludes divergent engine-local IDs", function()
  local first, second = canonical.newState(), canonical.newState()
  truthy(canonical.bind(first, "town:pre:abc", "town", 101, { name = "Berlin" }))
  truthy(canonical.bind(second, "town:pre:abc", "town", 9001, { name = "Berlin" }))
  equal(hash.value(canonical.digestView(first)), hash.value(canonical.digestView(second)))
  truthy(hash.value(canonical.snapshot(first)) ~= hash.value(canonical.snapshot(second)))
end)

local function linearProposal(edgeId, node0Id, node1Id, carrier, resourceIndex, catenary)
  local carrierField = carrier == "track" and "trackEdge" or "streetEdge"
  local carrierData = carrier == "track"
    and { trackType = resourceIndex, catenary = catenary == true }
    or { streetType = resourceIndex }
  local edge = {
    entity = edgeId,
    type = carrier == "track" and 1 or 0,
    comp = {
      node0 = node0Id,
      node1 = node1Id,
      tangent0 = { x = 80, y = 0, z = 1 },
      tangent1 = { x = 80, y = 0, z = 1 },
      type = 0,
      typeIndex = carrier == "track" and -1 or 0,
    },
  }
  edge[carrierField] = carrierData
  if carrier == "track" then edge.playerOwned = { player = 100 } end
  return {
    __observedCost = 25000,
    streetProposal = {
      edgesToAdd = { edge },
      nodesToAdd = {
        { entity = node0Id, comp = { position = { x = 10, y = 20, z = 3 } } },
        { entity = node1Id, comp = { position = { x = 90, y = 20, z = 4 } } },
      },
      edgesToRemove = {}, nodesToRemove = {}, edgeObjectsToAdd = {}, edgeObjectsToRemove = {},
    },
    constructionsToAdd = {}, constructionsToRemove = {},
  }
end

local function smallestStationProposal(offset, mainBuildingSlot, transform, catenary, nodeCount)
  offset = tonumber(offset) or 0
  mainBuildingSlot = tonumber(mainBuildingSlot) or 3700000
  catenary = catenary == nil and 1 or tonumber(catenary)
  nodeCount = tonumber(nodeCount) or 13
  local nodes, edges = {}, {}
  for index = 1, nodeCount do
    nodes[index] = {
      entity = -(offset + index),
      comp = { position = { x = 100 + index * 2, y = 200, z = 5 } },
    }
  end
  for index = 1, nodeCount - 1 do
    edges[index] = {
      entity = -(offset + nodeCount + index), type = 1,
      comp = {
        node0 = nodes[index].entity, node1 = nodes[index + 1].entity,
        tangent0 = { x = 2, y = 0, z = 0 }, tangent1 = { x = 2, y = 0, z = 0 },
        type = 0, typeIndex = -1,
      },
      trackEdge = { trackType = 1, catenary = catenary == 1 },
      playerOwned = { player = 100 },
    }
  end
  local prefix = "station/rail/modular_station/"
  return {
    __observedCost = 121073,
    proposal = {
      addedNodes = nodes, addedSegments = edges,
      edgesToRemove = {}, nodesToRemove = {}, edgeObjectsToAdd = {}, edgeObjectsToRemove = {},
    },
    __constructionAdditions = {{
      fileName = prefix .. "modular_station.con",
      transf = transform or { 0, -1, 0, 0, 1, 0, 0, 0, 0, 0, 1, 0, 100, 200, 5, 1 },
      params = {
        year = 1992, seed = 2, trackType = 0, catenary = catenary,
        length = 0, tracks = 0, paramX = 0, paramY = 0,
        modules = {
          [mainBuildingSlot] = { name = prefix .. "main_building_1_era_c.module", variant = 0 },
          [7400000] = { name = prefix .. "platform_passenger_era_c.module", variant = 0 },
          [7400010] = { name = prefix .. "platform_passenger_era_c.module", variant = 0 },
          [8401000] = { name = prefix .. (catenary == 1 and "platform_track_catenary.module" or "platform_track.module"), variant = 0 },
          [8401010] = { name = prefix .. (catenary == 1 and "platform_track_catenary.module" or "platform_track.module"), variant = 0 },
          [10400000] = { name = prefix .. "platform_passenger_roof_era_c.module", variant = 0 },
          [10400010] = { name = prefix .. "platform_passenger_roof_era_c.module", variant = 0 },
          [10800000] = { name = prefix .. "addon_platform_passenger_stairs_era_c.module", variant = 0 },
        },
      },
    }},
    __constructionRemovals = {},
  }
end

local function setStationPathGraph(root, pathNodeCounts, catenary)
  local nodes, edges, nextEntity = {}, {}, -10000
  for pathIndex, pathNodeCount in ipairs(pathNodeCounts) do
    local path = {}
    for index = 1, pathNodeCount do
      local entity = nextEntity
      nextEntity = nextEntity - 1
      path[index] = entity
      nodes[#nodes + 1] = {
        entity = entity,
        comp = { position = { x = index * 2, y = pathIndex * 10, z = 5 } },
      }
    end
    for index = 1, pathNodeCount - 1 do
      edges[#edges + 1] = {
        entity = nextEntity, type = 1,
        comp = {
          node0 = path[index], node1 = path[index + 1],
          tangent0 = { x = 2, y = 0, z = 0 }, tangent1 = { x = 2, y = 0, z = 0 },
          type = 0, typeIndex = -1,
        },
        trackEdge = { trackType = 1, catenary = catenary == 1 },
        playerOwned = { player = 100 },
      }
      nextEntity = nextEntity - 1
    end
  end
  root.proposal.addedNodes = nodes
  root.proposal.addedSegments = edges
  return root
end

test("proposal codec removes temporary local IDs and is deterministic across peers", function()
  local first, firstError = proposalCodec.normalise(
    linearProposal(-1, -2, -3, "track", 7, true), "company:2", {
      resourceName = function(kind, index) return kind .. "/" .. index .. ".lua" end,
    }
  )
  truthy(first, firstError)
  local second, secondError = proposalCodec.normalise(
    linearProposal(-91, -501, -777, "track", 7, true), "company:2", {
      resourceName = function(kind, index) return kind .. "/" .. index .. ".lua" end,
    }
  )
  truthy(second, secondError)
  equal(first.digest, second.digest)
  equal(json.encode(first), json.encode(second))
  truthy(not json.encode(first):match("-501"), "wire proposal leaked a temporary local ID")
  equal(first.edges[1].node0.slot, "node:1")
  equal(first.edges[1].node1.slot, "node:2")
  equal(first.edges[1].logicalOwnerCid, "company:2")
  equal(first.edges[1].private, true)
  equal(first.edges[1].catenary, true)
end)

test("canonical operation codec is strict, deterministic, and materialises local references", function()
  local first = assert(operationCodec.make("line.create", "company:1", {
    name = "MP Intercity",
    color = { r = 1000, g = 250, b = 0 },
    line = operationCodec.defaultLine({ "station_group:pre:a", "station_group:pre:b" }),
  }))
  local second = assert(operationCodec.make("line.create", "company:1", {
    name = "MP Intercity",
    color = { r = 1000, g = 250, b = 0 },
    line = operationCodec.defaultLine({ "station_group:pre:a", "station_group:pre:b" }),
  }))
  equal(first.digest, second.digest)
  equal(first.transactionId, "operation:" .. first.digest)
  local tampered = util.deepCopy(first)
  tampered.data.name = "tampered"
  local valid, validationError = operationCodec.validate(tampered)
  equal(valid, false)
  truthy(tostring(validationError):match("digest mismatch"))

  local madeArgs
  local gameApi = {
    type = {
      Line = { new = function() return {} end },
      Vec3f = { new = function(x, y, z) return { x = x, y = y, z = z } end },
    },
  }
  local command = assert(operationCodec.materialise(first, {
    api = gameApi,
    nativePlayerId = 77,
    resolveLocal = function(cid)
      return ({ ["station_group:pre:a"] = 101, ["station_group:pre:b"] = 202 })[cid]
    end,
    factory = function(name)
      equal(name, "createLine")
      return function(...)
        madeArgs = { ... }
        return { kind = "create-line" }
      end
    end,
  }))
  equal(command.tag, 3)
  equal(command.outputKind, "line")
  local native = command.factory(unpack(command.args))
  equal(native.kind, "create-line")
  equal(madeArgs[1], "MP Intercity")
  equal(madeArgs[3], 77)
  equal(madeArgs[4].stops[1].stationGroup, 101)
  equal(madeArgs[4].stops[2].stationGroup, 202)
end)

test("canonical line operations preserve vanilla empty and one-stop editor states", function()
  local empty = assert(operationCodec.make("line.create", "company:1", {
    name = "Line 1",
    color = { r = 950, g = 250, b = 100 },
    line = operationCodec.defaultLine({}),
  }))
  equal(#empty.data.line.stops, 0)
  truthy(operationCodec.validate(empty))

  local oneStop = assert(operationCodec.make("line.update", "company:1", {
    targetCid = "line:event:test:1",
    line = {
      stops = {
        { stationGroupCid = "station_group:pre:a", station = 3, terminal = 4,
          alternativeTerminals = {
            { station = 5, terminal = 6 }, { station = 7, terminal = 8 },
          } },
      },
    },
  }))
  equal(#oneStop.data.line.stops, 1)
  truthy(operationCodec.validate(oneStop))

  local capturedArgs
  local sawEmptyAlternativeInitialisation = false
  local materialised = assert(operationCodec.materialise(oneStop, {
    api = { type = {
      Line = {
        new = function() return {} end,
        Stop = { new = function()
          return setmetatable({}, {
            __newindex = function(target, key, value)
              if key == "alternativeTerminals" then
                truthy(type(value) == "table" and next(value) == nil,
                  "native alternative-terminal vector was bulk-assigned")
                sawEmptyAlternativeInitialisation = true
              end
              rawset(target, key, value)
            end,
          })
        end },
      },
      StationTerminal = { new = function() return {} end },
    } },
    nativePlayerId = 77,
    resolveLocal = function(cid)
      if cid == "line:event:test:1" then return 700 end
      if cid == "station_group:pre:a" then return 901 end
    end,
    factory = function(name)
      equal(name, "updateLine")
      return function(...) capturedArgs = { ... }; return { kind = "update-line" } end
    end,
  }))
  equal(materialised.tag, 5)
  equal(materialised.factory(unpack(materialised.args)).kind, "update-line")
  truthy(sawEmptyAlternativeInitialisation,
    "native alternative-terminal vector was not initialised through its proxy")
  equal(capturedArgs[1], 700)
  equal(capturedArgs[2].stops[1].stationGroup, 901)
  equal(capturedArgs[2].stops[1].station, 3)
  equal(capturedArgs[2].stops[1].terminal, 4)
  equal(capturedArgs[2].stops[1].alternativeTerminals[1].station, 5)
  equal(capturedArgs[2].stops[1].alternativeTerminals[1].terminal, 6)
  equal(capturedArgs[2].stops[1].alternativeTerminals[2].station, 7)
  equal(capturedArgs[2].stops[1].alternativeTerminals[2].terminal, 8)
end)

test("native line mutations retain a usable manual-control target", function()
  local gui = {}
  equal(guiLineCommandCodec.retainSelection(gui, {
    kind = "entity.name", targetLocalId = 700, originLocalId = 700,
  }), 700)
  equal(gui.selectedLineId, 700)
  equal(guiLineCommandCodec.retainSelection(gui, {
    kind = "line.update", targetLocalId = 701, originLocalId = 701,
  }), 701)
  equal(gui.selectedLineId, 701)
  -- Deleting some other line must not discard a still-valid retained target.
  equal(guiLineCommandCodec.retainSelection(gui, {
    kind = "line.delete", targetLocalId = 700,
  }), 701)
  equal(guiLineCommandCodec.retainSelection(gui, {
    kind = "line.delete", targetLocalId = 701,
  }), nil)
  equal(gui.selectedLineId, nil)
end)

test("native line envelopes preserve typed StationTerminal pairs", function()
  local current = assert(guiLineCommandCodec.decode(
    "L3|5|700|-1|0|0|0||1|901,1,2,0.3:4.5", 256, 64))
  equal(current.stops[1].alternativeTerminals[1].station, 0)
  equal(current.stops[1].alternativeTerminals[1].terminal, 3)
  equal(current.stops[1].alternativeTerminals[2].station, 4)
  equal(current.stops[1].alternativeTerminals[2].terminal, 5)

  local legacyFlat = assert(guiLineCommandCodec.decode(
    "L2|5|700|-1|0|0|0||1|901,1,2,0:3:4:5", 256, 64))
  equal(legacyFlat.stops[1].alternativeTerminals[1].station, 0)
  equal(legacyFlat.stops[1].alternativeTerminals[1].terminal, 3)
  truthy(guiLineCommandCodec.decode(
    "L2|5|700|-1|0|0|0||1|901,1,2,0:3:4", 256, 64) == nil,
    "odd legacy flat StationTerminal sequence was accepted")
end)

test("canonical entity naming preserves vanilla empty names", function()
  local emptyName = assert(operationCodec.make("entity.name", "company:1", {
    targetCid = "line:event:test:1",
    name = "",
  }))
  truthy(operationCodec.validate(emptyName))

  local capturedArgs
  local materialised = assert(operationCodec.materialise(emptyName, {
    api = {},
    nativePlayerId = 77,
    resolveLocal = function(cid)
      if cid == "line:event:test:1" then return 700 end
    end,
    factory = function(name)
      equal(name, "setName")
      return function(...) capturedArgs = { ... }; return { kind = "set-name" } end
    end,
  }))
  materialised.factory(unpack(materialised.args))
  equal(capturedArgs[1], 700)
  equal(capturedArgs[2], "")
end)

local function vehicleModelRepository()
  local ids = {
    ["vehicle/train/db_v100.mdl"] = 17,
    ["vehicle/waggon/open_1910.mdl"] = 18,
    ["vehicle/bus/benz.mdl"] = 19,
    ["vehicle/truck/opel_blitz.mdl"] = 20,
    ["vehicle/tram/duewag_gt8.mdl"] = 21,
    ["vehicle/ship/ferry.mdl"] = 22,
    ["vehicle/plane/commuter.mdl"] = 23,
  }
  local loadConfigCounts = {
    [17] = { 1 }, [18] = { 4 }, [19] = { 1 }, [20] = { 2 },
    [21] = { 1 }, [22] = { 3 }, [23] = { 1 },
  }
  return {
    find = function(name)
      return ids[name] or (type(name) == "string"
        and name:match("^vehicle/plane/[a-z0-9_%-]+%.mdl$") and 23
        or (type(name) == "string"
          and name:match("^vehicle/ship/[a-z0-9_%-]+%.mdl$") and 22 or nil))
    end,
    get = function(id)
      local compartments = {}
      for compartment, count in ipairs(loadConfigCounts[id] or {}) do
        local configs = {}
        for index = 1, count do configs[index] = {} end
        compartments[compartment] = { loadConfigs = configs }
      end
      return { metadata = { transportVehicle = { compartments = compartments } } }
    end,
  }
end

test("vehicle operations accept every portable carrier resource and reject local ids", function()
  local stockShips = {
    "barge_big_tanker", "barge_small_tanker", "damen_ferry_v2",
    "ds_schaffhausen_v2", "dunara_castle_v2", "frontenac_v2",
    "gms_axalp_v2", "graf_zeppelin_v2", "herkules_xi_tanker_v3",
    "herkules_xi_universal_v3", "klondike_v2", "merlin_v2", "rigi",
    "srn6_v2", "vandal_v2", "viola_v3", "virgo_tanker_v3",
    "virgo_universal_v3", "votrans_tanker_v2", "votrans_universal_v2",
    "wilhelm_v2", "zoroaster_v4", "zurich_v2",
  }
  local stockAircraft = {
    "airbus_a320_v2", "bae_146_cargo_v2", "bae_146_v2",
    "boeing_737_700_c_v2", "boeing_737_700_v2", "boeing_737_cargo_v2",
    "boeing_737_v2", "boeing_757_cargo_v2", "boeing_757_v2",
    "bombardier_cs300_v2", "bombardier_dhc_8_402pf_v2", "bombardier_q400_v2",
    "bristol_freighter_v2", "canadair_cl_44_v2", "de_havilland_comet_4b_v2",
    "dornier_b_merkur_v2", "douglas_c49_skytrain_v2", "douglas_dc3_v2",
    "douglas_dc4_v2", "hercules_l100_v2", "junkers_f_13_v2",
    "junkers_ju_52_v2", "short_330_v2", "sukhoi_superjet_100_v2",
    "super_connie_cargo_v2", "super_connie_v2", "tupolev_tu_204_cargo_v2",
    "tupolev_tu_204_v2", "vickers_victoria_v2",
  }
  local extracted = operationCodec.vehicleModelNames({
    [2] = "vehicle/tram/duewag_gt8.mdl",
    [1] = "vehicle/bus/benz.mdl",
    nested = {
      "vehicle/truck/opel_blitz.mdl", "vehicle/ship/ferry.mdl",
      "vehicle/plane/commuter.mdl", "vehicle/mod_namespace/custom.mdl",
      "construction/depot.mdl", "vehicle/../construction/depot.mdl",
    },
  })
  equal(#extracted, 6)
  equal(extracted[1], "vehicle/bus/benz.mdl")
  equal(extracted[2], "vehicle/tram/duewag_gt8.mdl")
  equal(extracted[6], "vehicle/mod_namespace/custom.mdl")
  local cyclic = { "vehicle/bus/benz.mdl" }
  cyclic.self = cyclic
  equal(#operationCodec.vehicleModelNames(cyclic), 1)
  local tooMany = {}
  for index = 1, operationCodec.MAX_VEHICLE_PARTS + 1 do
    tooMany[index] = "vehicle/bus/benz.mdl"
  end
  local excessive, excessiveError = operationCodec.vehicleModelNames(tooMany)
  equal(excessive, nil)
  truthy(tostring(excessiveError):match("part count"), excessiveError)
  local deeplyNested = "vehicle/bus/benz.mdl"
  for _ = 1, 17 do deeplyNested = { deeplyNested } end
  local tooDeep, depthError = operationCodec.vehicleModelNames(deeplyNested)
  equal(tooDeep, nil)
  truthy(tostring(depthError):match("nesting limit"), depthError)
  local config = operationCodec.defaultVehicleConfig({
    "vehicle/train/db_v100.mdl", "vehicle/waggon/open_1910.mdl",
  }, { res = { modelRep = vehicleModelRepository() } })
  equal(config.vehicles[1].loadConfig[1], 0)
  equal(config.vehicles[2].loadConfig[1], 0)
  local transaction = assert(operationCodec.make("vehicle.buy", "company:2", {
    depotCid = "depot:pre:abc",
    config = config,
  }))
  truthy(operationCodec.validate(transaction))
  for _, model in ipairs({
    "vehicle/bus/benz.mdl", "vehicle/truck/opel_blitz.mdl",
    "vehicle/tram/duewag_gt8.mdl", "vehicle/ship/ferry.mdl",
    "vehicle/plane/commuter.mdl",
  }) do
    local carrierConfig = operationCodec.defaultVehicleConfig(
      { model }, { res = { modelRep = vehicleModelRepository() } })
    local carrierTransaction = operationCodec.make("vehicle.buy", "company:2", {
      depotCid = "depot:pre:abc", config = carrierConfig,
    })
    truthy(carrierTransaction and operationCodec.validate(carrierTransaction),
      "portable carrier model was rejected: " .. model)
  end
  for _, name in ipairs(stockAircraft) do
    local model = "vehicle/plane/" .. name .. ".mdl"
    local aircraftConfig = operationCodec.defaultVehicleConfig(
      { model }, { res = { modelRep = vehicleModelRepository() } })
    local aircraftTransaction = operationCodec.make("vehicle.buy", "company:2", {
      depotCid = "depot:pre:airport", config = aircraftConfig,
    })
    truthy(aircraftTransaction and operationCodec.validate(aircraftTransaction),
      "stock Build 35924 aircraft was rejected: " .. model)
  end
  equal(#stockAircraft, 29)
  for _, name in ipairs(stockShips) do
    local model = "vehicle/ship/" .. name .. ".mdl"
    local shipConfig = operationCodec.defaultVehicleConfig(
      { model }, { res = { modelRep = vehicleModelRepository() } })
    local shipTransaction = operationCodec.make("vehicle.buy", "company:2", {
      depotCid = "depot:pre:shipyard", config = shipConfig,
    })
    truthy(shipTransaction and operationCodec.validate(shipTransaction),
      "stock Build 35924 ship was rejected: " .. model)
  end
  equal(#stockShips, 23)
  local invalid = util.deepCopy(config)
  invalid.vehicles[1].model = "vehicle/../construction/depot.mdl"
  local rejected, err = operationCodec.make("vehicle.buy", "company:2", {
    depotCid = "depot:pre:abc",
    config = invalid,
  })
  equal(rejected, nil)
  truthy(tostring(err):match("portable vehicle model"))
  local emptyLoadConfig = util.deepCopy(config)
  emptyLoadConfig.vehicles[1].loadConfig = {}
  local emptyRejected, emptyError = operationCodec.make("vehicle.buy", "company:2", {
    depotCid = "depot:pre:abc",
    config = emptyLoadConfig,
  })
  equal(emptyRejected, nil)
  truthy(tostring(emptyError):match("one entry per model compartment"))
  local automaticSentinel = util.deepCopy(config)
  automaticSentinel.vehicles[1].loadConfig = { -1 }
  local sentinelRejected, sentinelError = operationCodec.make("vehicle.buy", "company:2", {
    depotCid = "depot:pre:abc",
    config = automaticSentinel,
  })
  equal(sentinelRejected, nil)
  truthy(tostring(sentinelError):match("selection is invalid"))
  local localTarget = operationCodec.make("vehicle.assign", "company:2", {
    targetCid = 42,
    lineCid = "line:pre:def",
    stopIndex = 0,
  })
  equal(localTarget, nil)
  local automaticStop = assert(operationCodec.make("vehicle.assign", "company:2", {
    targetCid = "vehicle:pre:abc",
    lineCid = "line:pre:def",
    stopIndex = -1,
  }))
  truthy(operationCodec.validate(automaticStop))
  local invalidNegativeStop = operationCodec.make("vehicle.assign", "company:2", {
    targetCid = "vehicle:pre:abc",
    lineCid = "line:pre:def",
    stopIndex = -2,
  })
  equal(invalidNegativeStop, nil)
end)

test("vehicle lifecycle scalar operations share the strict canonical contract", function()
  local targetCid = "vehicle:pre:abc"
  local cases = {
    { "vehicle.reverse", { targetCid = targetCid } },
    { "vehicle.stop", { targetCid = targetCid, stopped = true } },
    { "vehicle.maintenance", { targetCid = targetCid, valueBasisPoints = 8750 } },
    { "vehicle.depart", { targetCid = targetCid } },
    { "vehicle.send_to_depot", { targetCid = targetCid, sellOnArrival = false } },
    { "vehicle.manual_departure", { targetCid = targetCid, manual = true } },
  }
  for _, case in ipairs(cases) do
    local transaction = assert(operationCodec.make(case[1], "company:2", case[2]))
    truthy(operationCodec.validate(transaction), case[1] .. " did not validate")
  end
  equal(operationCodec.make("vehicle.stop", "company:2", {
    targetCid = targetCid, stopped = 1,
  }), nil)
  equal(operationCodec.make("vehicle.maintenance", "company:2", {
    targetCid = targetCid, valueBasisPoints = 10001,
  }), nil)
  equal(operationCodec.make("vehicle.send_to_depot", "company:2", {
    targetCid = targetCid, sellOnArrival = 0,
  }), nil)
  equal(operationCodec.make("vehicle.manual_departure", "company:2", {
    targetCid = targetCid, manual = "yes",
  }), nil)

  local batch = assert(operationCodec.make("vehicle.sell_batch", "company:2", {
    targetCids = { "vehicle:pre:z", "vehicle:pre:a" },
  }))
  equal(batch.schemaVersion, 4)
  equal(batch.data.targetCids[1], "vehicle:pre:a")
  equal(batch.data.targetCids[2], "vehicle:pre:z")
  truthy(operationCodec.validate(batch), "canonical vehicle sale batch did not validate")
  local materialised = assert(operationCodec.materialise(batch, {
    api = {},
    resolveLocal = function(cid)
      return ({ ["vehicle:pre:a"] = 71, ["vehicle:pre:z"] = 72 })[cid]
    end,
    factory = function(name)
      equal(name, "sellVehicle")
      return function(localId) return { kind = "sell", target = localId } end
    end,
  }))
  equal(materialised.tag, 12)
  equal(#materialised.batchArgs, 2)
  equal(materialised.batchArgs[1][1], 71)
  equal(materialised.batchArgs[2][1], 72)
  equal(materialised.factory(materialised.batchArgs[2][1]).target, 72)
  equal(operationCodec.make("vehicle.sell_batch", "company:2", {
    targetCids = { "vehicle:pre:a" },
  }), nil)
  equal(operationCodec.make("vehicle.sell_batch", "company:2", {
    targetCids = { "vehicle:pre:a", "vehicle:pre:a" },
  }), nil)
  local legacyBatch = util.deepCopy(batch)
  legacyBatch.schemaVersion = 3
  equal(operationCodec.validate(legacyBatch), false)
end)

test("railway vehicle materialisation uses the documented nested consist shape", function()
  local transaction = assert(operationCodec.make("vehicle.buy", "company:2", {
    depotCid = "depot:pre:abc",
    config = operationCodec.defaultVehicleConfig({
      "vehicle/train/db_v100.mdl", "vehicle/waggon/open_1910.mdl",
    }, { res = { modelRep = vehicleModelRepository() } }),
  }))
  local madeArgs
  local command = assert(operationCodec.materialise(transaction, {
    api = {
      type = {
        TransportVehicleConfig = { new = function() return {} end },
        TransportVehiclePart = { new = function() return { wrapper = true } end },
        VehiclePart = { new = function() return { part = true } end },
        Vec3f = { new = function(x, y, z) return { x = x, y = y, z = z } end },
      },
      res = {
        modelRep = vehicleModelRepository(),
      },
    },
    nativePlayerId = 88,
    resolveLocal = function(cid) if cid == "depot:pre:abc" then return 303 end end,
    factory = function(name)
      equal(name, "buyVehicle")
      return function(...) madeArgs = { ... }; return { kind = "buy-vehicle" } end
    end,
  }))
  local native = command.factory(unpack(command.args))
  equal(native.kind, "buy-vehicle")
  equal(madeArgs[1], 88)
  equal(madeArgs[2], 303)
  equal(madeArgs[3].vehicles[1].wrapper, true)
  equal(madeArgs[3].vehicles[1].part.part, true)
  equal(madeArgs[3].vehicles[1].part.modelId, 17)
  equal(madeArgs[3].vehicles[2].part.modelId, 18)
  equal(madeArgs[3].vehicles[1].purchaseTime, 0)
  equal(madeArgs[3].vehicles[1].maintenanceState, 1)
  equal(madeArgs[3].vehicles[1].part.loadConfig[1], 0)
  equal(madeArgs[3].vehicles[1].autoLoadConfig[1], 1)
  equal(madeArgs[3].vehicles[2].part.loadConfig[1], 0)
  equal(madeArgs[3].vehicles[2].autoLoadConfig[1], 1)
  equal(madeArgs[3].vehicleGroups[1], 1)
  equal(madeArgs[3].vehicleGroups[2], 1)
end)

test("proposal codec translates existing removals and node references canonically", function()
  local snapshot = {
    __observedCost = 25000,
    streetProposal = {
      edgesToAdd = {{
        entity = -1, type = 1,
        comp = {
          node0 = 201, node1 = 202,
          tangent0 = { x = 60, y = 0, z = 0 }, tangent1 = { x = 60, y = 0, z = 0 },
          type = 0, typeIndex = -1,
        },
        trackEdge = { trackType = 1, catenary = true },
      }},
      nodesToAdd = {},
      edgesToRemove = { 101 },
      nodesToRemove = {},
      edgeObjectsToAdd = {}, edgeObjectsToRemove = {},
    },
    constructionsToAdd = {}, constructionsToRemove = {},
  }
  local map = { [101] = "edge:event:test:1", [201] = "node:pre:a", [202] = "node:pre:b" }
  local tx, err = proposalCodec.normalise(snapshot, "company:1", {
    resolveCanonical = function(_, localId) return map[localId] end,
  })
  truthy(tx, err)
  equal(tx.remove.edges[1], "edge:event:test:1")
  equal(tx.edges[1].node0.cid, "node:pre:a")
  equal(tx.edges[1].node1.cid, "node:pre:b")
  local localNumbers = json.encode(tx)
  equal(#tx.nodes, 0)
  truthy(localNumbers:find('"nodes":{}', 1, true),
    "pure edge replacement did not use the live Lua empty-table wire spelling")
  truthy(not localNumbers:match("101") and not localNumbers:match("201") and not localNumbers:match("202"),
    "canonical upgrade transaction leaked positive machine-local IDs")

  local fakeApi = {
    type = {
      SimpleProposal = { new = function() return { streetProposal = {
        nodesToAdd = {}, edgesToAdd = {}, nodesToRemove = {}, edgesToRemove = {},
      } } end },
      SegmentAndEntity = { new = function() return { comp = {} } end },
      PlayerOwned = { new = function() return {} end },
      NodeAndEntity = { new = function() return { comp = {} } end },
      Vec3f = { new = function(x, y, z) return { x = x, y = y, z = z } end },
      BaseEdgeStreet = { new = function() return {} end },
      BaseEdgeTrack = { new = function() return {} end },
    },
    res = {
      streetTypeRep = { find = function() return 4 end },
      trackTypeRep = { find = function() return 1 end },
    },
  }
  local localMap = {
    ["edge:event:test:1"] = 101,
    ["node:pre:a"] = 201,
    ["node:pre:b"] = 202,
  }
  local proposal, metadata = proposalCodec.materialise(tx, {
    api = fakeApi,
    resolveLocal = function(cid) return localMap[cid] end,
  })
  truthy(proposal)
  equal(#proposal.streetProposal.nodesToAdd, 0)
  equal(proposal.streetProposal.edgesToAdd[1].entity, -1)
  equal(proposal.streetProposal.edgesToAdd[1].comp.node0, 201)
  equal(proposal.streetProposal.edgesToAdd[1].comp.node1, 202)
  equal(proposal.streetProposal.edgesToAdd[1].trackEdge.trackType, 1)
  equal(proposal.streetProposal.edgesToAdd[1].trackEdge.catenary, true)
  equal(proposal.streetProposal.edgesToRemove[1], 101)
  equal(metadata.digest, tx.digest)

  local positions = {
    ["node:pre:a"] = { x = 10, y = 20, z = 3 },
    ["node:pre:b"] = { x = 90, y = 20, z = 4 },
  }
  local matched, matchError = proposalCodec.matchCreated(tx, {}, {{
    localId = 102,
    carrier = "track",
    node0Position = positions["node:pre:a"],
    node1Position = positions["node:pre:b"],
  }}, nil, function(cid) return positions[cid] end)
  truthy(matched, matchError)
  equal(next(matched.nodes), nil)
  equal(matched.edges["edge:1"], 102)
end)

test("proposal codec admits and materialises pure connected-segment removals", function()
  local snapshot = {
    __observedCost = 0,
    proposal = {
      addedNodes = {}, addedSegments = {},
      removedSegments = {
        ["2"] = { entity = 102 },
        ["1"] = { entity = 101 },
      },
      removedNodes = { ["1"] = { entity = 201 } },
      edgeObjectsToAdd = {},
      edgeObjectsToRemove = { ["1"] = { entity = 301 } },
    },
  }
  local canonicalMap = {
    [101] = "edge:event:test:a", [102] = "edge:event:test:b",
    [201] = "node:event:test:junction", [301] = "edge_object:event:test:signal",
  }
  local transaction, transactionError = proposalCodec.normalise(snapshot, "company:1", {
    resolveCanonical = function(_, localId) return canonicalMap[localId] end,
  })
  truthy(transaction, transactionError)
  truthy(proposalCodec.isRemovalOnly(transaction),
    "pure bulldozer shape was not recognized as removal-only")
  equal(#transaction.nodes, 0)
  equal(#transaction.edges, 0)
  equal(transaction.remove.edges[1], "edge:event:test:a")
  equal(transaction.remove.edges[2], "edge:event:test:b")
  equal(transaction.remove.nodes[1], "node:event:test:junction")
  equal(transaction.edgeObjects.remove[1], "edge_object:event:test:signal")
  local diagnostic = proposalCodec.diagnose(snapshot)
  equal(diagnostic.counts.edgesToRemove, 2)
  equal(diagnostic.counts.nodesToRemove, 1)
  equal(diagnostic.counts.edgeObjectsToRemove, 1)

  local fakeApi = {
    type = {
      SimpleProposal = { new = function() return { streetProposal = {
        nodesToAdd = {}, edgesToAdd = {}, nodesToRemove = {}, edgesToRemove = {},
        edgeObjectsToAdd = {}, edgeObjectsToRemove = {},
      } } end },
      SegmentAndEntity = { new = function() return { comp = {} } end },
      NodeAndEntity = { new = function() return { comp = {} } end },
      Vec3f = { new = function(x, y, z) return { x = x, y = y, z = z } end },
      BaseEdgeStreet = { new = function() return {} end },
      BaseEdgeTrack = { new = function() return {} end },
    },
    res = {},
  }
  local localMap = {
    ["edge:event:test:a"] = 101, ["edge:event:test:b"] = 102,
    ["node:event:test:junction"] = 201, ["edge_object:event:test:signal"] = 301,
  }
  local proposal, metadata = proposalCodec.materialise(transaction, {
    api = fakeApi,
    resolveLocal = function(cid) return localMap[cid] end,
  })
  truthy(proposal, metadata)
  equal(#proposal.streetProposal.edgesToAdd, 0)
  equal(proposal.streetProposal.edgesToRemove[1], 101)
  equal(proposal.streetProposal.edgesToRemove[2], 102)
  equal(proposal.streetProposal.nodesToRemove[1], 201)
  equal(proposal.streetProposal.edgeObjectsToRemove[1], 301)
  local matched, matchError = proposalCodec.matchCreated(transaction, {}, {})
  truthy(matched, matchError)
  equal(#matched.unmatchedEdges, 0)

  local malformed = util.deepCopy(transaction)
  malformed.remove.edges = {
    "edge:event:test:b", "edge:event:test:a",
  }
  malformed.digest = proposalCodec.digest(malformed)
  malformed.transactionId = "proposal:" .. malformed.digest
  local valid, validationError = proposalCodec.validate(malformed)
  equal(valid, false)
  truthy(validationError:find("sorted and unique", 1, true), validationError)
end)

test("proposal codec recovers unambiguous carrier selections from builder data", function()
  local snapshot = linearProposal(-1, -2, -3, "track", 7, true)
  snapshot.streetProposal.edgesToAdd[1].trackEdge = "<userdata>"
  snapshot.__builderData = { trackType = 7, catenary = true }
  local transaction, transactionError = proposalCodec.normalise(snapshot, "company:1")
  truthy(transaction, transactionError)
  equal(transaction.edges[1].resource.index, 7)
  equal(transaction.edges[1].catenary, true)

  snapshot.__builderParams = { trackType = 9 }
  local conflicting, conflictError = proposalCodec.normalise(snapshot, "company:1")
  equal(conflicting, nil)
  truthy(tostring(conflictError):match("conflicting trackType"), conflictError)

  snapshot.__builderParams = nil
  snapshot.__builderData.catenary = nil
  local missing, missingError = proposalCodec.normalise(snapshot, "company:1")
  equal(missing, nil)
  truthy(tostring(missingError):match("catenary"), missingError)
end)

test("proposal codec materialises and geometrically binds live-proven linear edges", function()
  local tx = assert(proposalCodec.normalise(linearProposal(-1, -2, -3, "street", 4, false), "company:1"))
  local fakeApi = {
    type = {
      SimpleProposal = { new = function() return { streetProposal = {
        nodesToAdd = {}, edgesToAdd = {}, nodesToRemove = {}, edgesToRemove = {},
      } } end },
      SegmentAndEntity = { new = function() return { comp = {} } end },
      PlayerOwned = { new = function() return {} end },
      NodeAndEntity = { new = function() return { comp = {} } end },
      Vec3f = { new = function(x, y, z) return { x = x, y = y, z = z } end },
      BaseEdgeStreet = { new = function() return {} end },
      BaseEdgeTrack = { new = function() return {} end },
    },
    res = {
      streetTypeRep = { find = function() return 4 end },
      trackTypeRep = { find = function() return 7 end },
    },
  }
  local proposal, metadata = proposalCodec.materialise(tx, { api = fakeApi })
  truthy(proposal)
  equal(proposal.streetProposal.edgesToAdd[1].entity, -1)
  equal(proposal.streetProposal.nodesToAdd[1].entity, -2)
  equal(proposal.streetProposal.nodesToAdd[2].entity, -3)
  equal(proposal.streetProposal.edgesToAdd[1].comp.node0, -2)
  equal(proposal.streetProposal.edgesToAdd[1].streetEdge.streetType, 4)
  equal(tx.edges[1].private, false)
  equal(metadata.digest, tx.digest)

  local privateTx = assert(proposalCodec.normalise(linearProposal(-1, -2, -3, "track", 7, true), "company:1"))
  local privateProposal = assert(proposalCodec.materialise(privateTx, { api = fakeApi, nativePlayerId = 100 }))
  equal(privateProposal.streetProposal.edgesToAdd[1].playerOwned.player, 100)

  local matched, matchError = proposalCodec.matchCreated(tx, {
    { localId = 7002, position = { x = 90, y = 20, z = 4 } },
    { localId = 7001, position = { x = 10, y = 20, z = 3 } },
  }, {{
    localId = 8001, carrier = "street",
    node0Position = { x = 90, y = 20, z = 4 },
    node1Position = { x = 10, y = 20, z = 3 },
  }})
  truthy(matched, matchError)
  equal(matched.nodes["node:1"], 7001)
  equal(matched.nodes["node:2"], 7002)
  equal(matched.edges["edge:1"], 8001)
end)

test("proposal codec replays topology and collateral construction demolition atomically", function()
  local raw = linearProposal(-1, -2, -3, "track", 7, true)
  -- Reverse native order deliberately: canonical source/collateral selection
  -- must not depend on the process-local construction vector order.
  raw.__constructionRemovals = { { entity = 902 }, { entity = 901 } }
  local transaction, transactionError = proposalCodec.normalise(raw, "company:1", {
    resolveCanonical = function(kind, localId)
      if kind == "construction" and localId == 901 then return "construction:pre:house-a" end
      if kind == "construction" and localId == 902 then return "construction:pre:house-b" end
    end,
    entityKind = function() return "construction" end,
    resourceName = function(kind, index) return kind .. "/" .. tostring(index) .. ".lua" end,
  })
  truthy(transaction, transactionError)
  equal(transaction.schemaVersion, proposalCodec.CONSTRUCTION_SCHEMA_VERSION)
  equal(transaction.constructions[1].mode, "remove")
  equal(transaction.constructions[1].sourceCid, "construction:pre:house-a")
  equal(transaction.constructions[1].collateral[1].cid, "construction:pre:house-b")
  truthy(proposalCodec.isTopologyConstructionRemoval(transaction))
  truthy(proposalCodec.validatePortable(transaction))

  local fakeApi = {
    type = {
      SimpleProposal = { new = function() return {
        constructionsToRemove = {},
        streetProposal = {
          nodesToAdd = {}, edgesToAdd = {}, nodesToRemove = {}, edgesToRemove = {},
          edgeObjectsToAdd = {}, edgeObjectsToRemove = {},
        },
      } end },
      SegmentAndEntity = { new = function() return { comp = {} } end },
      PlayerOwned = { new = function() return {} end },
      NodeAndEntity = { new = function() return { comp = {} } end },
      Vec3f = { new = function(x, y, z) return { x = x, y = y, z = z } end },
      BaseEdgeStreet = { new = function() return {} end },
      BaseEdgeTrack = { new = function() return {} end },
    },
    res = {
      streetTypeRep = { find = function() return 4 end },
      trackTypeRep = { find = function() return 7 end },
    },
  }
  local materialised, materialiseError = proposalCodec.materialise(transaction, {
    api = fakeApi,
    nativePlayerId = 100,
    resolveLocal = function(cid)
      if cid == "construction:pre:house-a" then return 901 end
      if cid == "construction:pre:house-b" then return 902 end
    end,
  })
  truthy(materialised, materialiseError)
  equal(materialised.constructionsToRemove[1], 901)
  equal(materialised.constructionsToRemove[2], 902)
  equal(materialised.streetProposal.edgesToAdd[1].trackEdge.trackType, 7)

  local duplicate = util.deepCopy(transaction)
  duplicate.constructions[1].collateral[1] = {
    kind = "construction", cid = duplicate.constructions[1].sourceCid,
  }
  duplicate.digest = proposalCodec.digest(duplicate)
  duplicate.transactionId = "proposal:" .. duplicate.digest
  local duplicateOk, duplicateError = proposalCodec.validate(duplicate)
  equal(duplicateOk, false)
  truthy(tostring(duplicateError):find("source cannot also be collateral", 1, true), duplicateError)
end)

test("construction collateral stages demolition before exact connected replay", function()
  -- Relay regressions mp-748086c41a5e1f9f and mp-5e5d4c732aae691e define both
  -- sides of this boundary.  The helper must wait only for the two houses (not
  -- the road replaced by the eventual terminal); the typed ConstructionEntity
  -- path must not receive live collateral roots because Build 35924 crashes
  -- in its native Lua-table converter before BuildProposalVisitor. Once those
  -- roots have retired, the typed proposal must retain the town-road split.
  local raw = linearProposal(-1, -2, -3, "street", 4, false)
  raw.streetProposal.edgesToAdd[2] = {
    entity = -4, type = 0,
    comp = {
      node0 = 701, node1 = -3,
      tangent0 = { x = 40, y = 10, z = 0 }, tangent1 = { x = 38, y = 12, z = 0 },
      type = 0, typeIndex = -1,
    },
    streetEdge = { streetType = 4 },
  }
  raw.streetProposal.edgesToAdd[3] = {
    entity = -5, type = 0,
    comp = {
      node0 = -3, node1 = 702,
      tangent0 = { x = 25, y = 8, z = 0 }, tangent1 = { x = 24, y = 9, z = 0 },
      type = 0, typeIndex = -1,
    },
    streetEdge = { streetType = 4 },
  }
  raw.streetProposal.edgesToRemove = { 77 }
  raw.__constructionAdditions = { {
    fileName = "station/street/modular_terminal.con",
    transf = { 1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1, 0, 100, 200, 5, 1 },
    params = {
      year = 1940, seed = 0, platL = 1, platR = 1,
      length = 0, tramTrack = 0, paramX = 0, paramY = 0,
      modules = {
        [20009900] = {
          name = "station/street/passenger_platform.module",
          variant = 0, metadata = "<userdata>",
        },
        [20010000] = {
          name = "station/street/passenger_platform.module",
          variant = 0, metadata = "<userdata>",
        },
        [20015503] = {
          name = "station/street/entrance_exit.module",
          variant = 0, metadata = "<userdata>",
        },
      },
    },
  } }
  raw.__constructionRemovals = { { entity = 902 }, { entity = 901 } }
  local canonicalMap = {
    [77] = "edge:pre:town-road",
    [701] = "node:pre:town-road-a",
    [702] = "node:pre:town-road-b",
    [901] = "construction:pre:house-a",
    [902] = "construction:pre:house-b",
  }
  local transaction, transactionError = proposalCodec.normalise(raw, "company:1", {
    resolveCanonical = function(_, localId) return canonicalMap[localId] end,
    entityKind = function(localId)
      return localId == 77 and "edge" or "construction"
    end,
    constructionKind = function() return "station" end,
    resourceName = function(kind, index)
      return kind .. "/" .. tostring(index) .. ".lua"
    end,
    requireResourceName = true,
  })
  truthy(transaction, transactionError)
  truthy(proposalCodec.validatePortable(transaction))
  equal(transaction.constructions[1].mode, "build")
  equal(#transaction.constructions[1].collateral, 2)
  equal(transaction.remove.edges[1], "edge:pre:town-road")

  local record = {
    transaction = transaction,
    localInputs = {
      { kind = "construction", cid = "construction:pre:house-a", localId = 901 },
      { kind = "construction", cid = "construction:pre:house-b", localId = 902 },
      { kind = "edge", cid = "edge:pre:town-road", localId = 77 },
    },
  }
  equal(constructionReplayState.isExact(record, proposalCodec), false,
    "collateral construction escaped the crash-safe helper replay boundary")
  equal(constructionReplayState.isStagedExact(record, proposalCodec), true,
    "collateral construction was not eligible for post-demolition exact replay")
  equal(constructionReplayState.requiresAtomic(record, proposalCodec), true,
    "connected collateral construction lost its atomic topology requirement")
  local collateralInputs = assert(constructionReplayState.collateralInputs(record))
  equal(#collateralInputs, 2)
  equal(collateralInputs[1].localId, 901)
  equal(collateralInputs[2].localId, 902)

  local fakeApi = {
    type = {
      SimpleProposal = {
        ConstructionEntity = { new = function() return {} end },
        new = function()
          local streetProposal = {
            nodesToAdd = {}, edgesToAdd = {}, nodesToRemove = {}, edgesToRemove = {},
            edgeObjectsToAdd = {}, edgeObjectsToRemove = {},
          }
          return { constructionsToAdd = {}, constructionsToRemove = {},
            old2new = {}, streetProposal = streetProposal }
        end,
      },
      SegmentAndEntity = { new = function() return { comp = {} } end },
      PlayerOwned = { new = function() return {} end },
      NodeAndEntity = { new = function() return { comp = {} } end },
      Vec3f = { new = function(x, y, z) return { x = x, y = y, z = z } end },
      Vec4f = { new = function(a, b, c, d) return { a, b, c, d } end },
      Mat4f = { new = function(a, b, c, d) return { a, b, c, d } end },
      BaseEdgeStreet = { new = function() return {} end },
      BaseEdgeTrack = { new = function() return {} end },
    },
    res = {
      streetTypeRep = { find = function() return 4 end },
      trackTypeRep = { find = function() return 1 end },
      moduleRep = {
        find = function() return 1 end,
        get = function() return { metadata = { hydrated = true } } end,
      },
    },
  }
  local proposal, materialisation = proposalCodec.materialise(transaction, {
    api = fakeApi,
    nativePlayerId = 100,
    resolveLocal = function(cid)
      if cid == "edge:pre:town-road" then return 77 end
      if cid == "node:pre:town-road-a" then return 701 end
      if cid == "node:pre:town-road-b" then return 702 end
      if cid == "construction:pre:house-a" then return 901 end
      if cid == "construction:pre:house-b" then return 902 end
    end,
  })
  truthy(proposal, materialisation)
  equal(proposal.streetProposal.edgesToRemove[1], 77)
  equal(#proposal.streetProposal.nodesToAdd, 0,
    "construction topology expanded before the native command processor")
  local function expandedCommand(removals)
    return { proposal = {
      proposal = {
        addedNodes = {
          { entity = -1, comp = { position = { x = 10, y = 20, z = 3 } } },
          { entity = -2, comp = { position = { x = 89, y = 19, z = 4 } } },
        },
        addedSegments = {{
          entity = -3, type = 0,
          comp = {
            node0 = -1, node1 = -2,
            tangent0 = { x = 79, y = 0, z = 1 },
            tangent1 = { x = 79, y = 0, z = 1 },
            type = 0, typeIndex = 0,
          },
          streetEdge = { streetType = 4 },
        }},
        edgeObjectsToAdd = {},
      },
      toRemove = removals,
    } }
  end
  local command, commandError = guiBuildCommandFactory.make(
    function() return expandedCommand({ 901, 902 }) end,
    proposal, transaction, materialisation, function(value, name) return value[name] end)
  truthy(command, commandError)
  local processed = command.proposal.proposal
  equal(#processed.addedNodes, 2, "connected terminal duplicated generated nodes")
  equal(#processed.addedSegments, 3,
    "connected terminal omitted the captured road replacement halves")
  equal(processed.addedNodes[2].comp.position.x, 90,
    "generated terminal entrance did not adopt the captured snapped position")
  equal(processed.addedSegments[2].entity, -4)
  equal(processed.addedSegments[2].comp.node0, 701)
  equal(processed.addedSegments[2].comp.node1, -2)
  equal(processed.addedSegments[3].entity, -5)
  equal(processed.addedSegments[3].comp.node0, -2)
  equal(processed.addedSegments[3].comp.node1, 702)
  equal(proposal.constructionsToRemove[1], 901)
  equal(proposal.constructionsToRemove[2], 902)
  equal(proposal.constructionsToAdd[1].fileName,
    "station/street/modular_terminal.con")
  truthy(proposal.constructionsToAdd[1].params.modules[20009900].metadata.hydrated,
    "atomic terminal replay lost resource-hydrated module metadata")

  local stagedProposal, stagedMaterialisation = proposalCodec.materialise(transaction, {
    api = fakeApi,
    nativePlayerId = 100,
    omitConstructionCollateral = true,
    resolveLocal = function(cid)
      if cid == "edge:pre:town-road" then return 77 end
      if cid == "node:pre:town-road-a" then return 701 end
      if cid == "node:pre:town-road-b" then return 702 end
      if cid == "construction:pre:house-a" then return 901 end
      if cid == "construction:pre:house-b" then return 902 end
    end,
  })
  truthy(stagedProposal, stagedMaterialisation)
  equal(#stagedProposal.constructionsToRemove, 0,
    "post-demolition replay reintroduced crash-prone collateral roots")
  equal(stagedProposal.streetProposal.edgesToRemove[1], 77,
    "post-demolition replay omitted the captured town-road split")
  local stagedCommand, stagedCommandError = guiBuildCommandFactory.make(
    function() return expandedCommand({}) end,
    stagedProposal, transaction, stagedMaterialisation,
    function(value, name) return value[name] end)
  truthy(stagedCommand, stagedCommandError)
  equal(#stagedCommand.proposal.proposal.addedSegments, 3,
    "post-demolition replay omitted captured road replacement topology")
  equal(stagedProposal.constructionsToAdd[1].fileName,
    "station/street/modular_terminal.con")
end)

test("proposal codec keeps removal-only town roads and attached buildings atomic", function()
  -- Live regression shape from flat-medium-soak-20260810: one public town-road
  -- edge, its terminal node, and two attached autonomous constructions were
  -- emitted by one bulldozer click with no replacement topology.
  local raw = {
    __observedCost = 50000,
    streetProposal = {
      nodesToAdd = {}, edgesToAdd = {},
      edgesToRemove = { 77 }, nodesToRemove = { 88 },
      edgeObjectsToAdd = {}, edgeObjectsToRemove = {},
    },
    __constructionRemovals = { { entity = 902 }, { entity = 901 } },
  }
  local canonicalMap = {
    [77] = "edge:pre:town-road", [88] = "node:pre:town-road-end",
    [901] = "construction:pre:house-a", [902] = "construction:pre:house-b",
  }
  local transaction, transactionError = proposalCodec.normalise(raw, "company:1", {
    resolveCanonical = function(_, localId) return canonicalMap[localId] end,
    entityKind = function(localId)
      return localId == 77 and "edge" or (localId == 88 and "node" or "construction")
    end,
    constructionKind = function() return "construction" end,
  })
  truthy(transaction, transactionError)
  equal(transaction.constructions[1].kind, "construction")
  equal(transaction.constructions[1].sourceCid, "construction:pre:house-a")
  equal(transaction.constructions[1].collateral[1].cid, "construction:pre:house-b")
  truthy(proposalCodec.isTopologyConstructionRemoval(transaction),
    "removal-only town-road collateral was routed to the split construction helper")

  local fakeApi = {
    type = {
      SimpleProposal = { new = function() return {
        constructionsToRemove = {},
        streetProposal = {
          nodesToAdd = {}, edgesToAdd = {}, nodesToRemove = {}, edgesToRemove = {},
          edgeObjectsToAdd = {}, edgeObjectsToRemove = {},
        },
      } end },
      SegmentAndEntity = { new = function() return { comp = {} } end },
      NodeAndEntity = { new = function() return { comp = {} } end },
      Vec3f = { new = function(x, y, z) return { x = x, y = y, z = z } end },
      BaseEdgeStreet = { new = function() return {} end },
      BaseEdgeTrack = { new = function() return {} end },
    },
    res = {},
  }
  local localMap = {
    ["edge:pre:town-road"] = 77, ["node:pre:town-road-end"] = 88,
    ["construction:pre:house-a"] = 901, ["construction:pre:house-b"] = 902,
  }
  local materialised, materialiseError = proposalCodec.materialise(transaction, {
    api = fakeApi,
    resolveLocal = function(cid) return localMap[cid] end,
  })
  truthy(materialised, materialiseError)
  equal(materialised.streetProposal.edgesToRemove[1], 77)
  equal(materialised.streetProposal.nodesToRemove[1], 88)
  equal(materialised.constructionsToRemove[1], 901)
  equal(materialised.constructionsToRemove[2], 902)

  local stationRaw = util.deepCopy(raw)
  stationRaw.__constructionRemovals = { { entity = 901 } }
  local stationTransaction, stationError = proposalCodec.normalise(stationRaw, "company:1", {
    resolveCanonical = function(_, localId) return canonicalMap[localId] end,
    entityKind = function(localId)
      return localId == 77 and "edge" or (localId == 88 and "node" or "construction")
    end,
    constructionKind = function() return "station" end,
  })
  truthy(stationTransaction, stationError)
  equal(stationTransaction.constructions[1].kind, "station")
  equal(proposalCodec.isTopologyConstructionRemoval(stationTransaction), false,
    "station generated topology escaped its asynchronous construction helper")
end)

test("proposal codec canonicalises the measured smallest modular passenger station", function()
  local first, firstError = proposalCodec.normalise(smallestStationProposal(0), "company:1", {
    resourceName = function(kind, index) return kind .. "/" .. index .. ".lua" end,
  })
  truthy(first, firstError)
  equal(first.schemaVersion, proposalCodec.CONSTRUCTION_SCHEMA_VERSION)
  equal(#first.nodes, 13)
  equal(#first.edges, 12)
  equal(#first.constructions, 1)
  equal(first.constructions[1].kind, "rail_station")
  equal(first.constructions[1].modules[1].slot, 3700000)
  local second = assert(proposalCodec.normalise(smallestStationProposal(100), "company:1", {
    resourceName = function(kind, index) return kind .. "/" .. index .. ".lua" end,
  }))
  equal(first.digest, second.digest)
  equal(json.encode(first), json.encode(second))
  local spec, specError = proposalCodec.materialiseConstruction(first)
  truthy(spec, specError)
  equal(spec.fileName, "station/rail/modular_station/modular_station.con")
  equal(spec.params.modules[8401000].name,
    "station/rail/modular_station/platform_track_catenary.module")
  equal(spec.params.modules[3700000].metadata.moreCapacity.passenger, 30)
  equal(spec.transform[13], 100)
  local ordinary, ordinaryError = proposalCodec.materialise(first)
  equal(ordinary, nil)
  truthy(tostring(ordinaryError):find("unavailable", 1, true), ordinaryError)

  -- A stock placement may demolish town buildings without being an edit of
  -- those buildings. Keep the station as an absolute build and carry each
  -- obstacle as separately resolved collateral; treating the first house as
  -- an upgrade source makes upgradeConstruction anchor the station there.
  local obstructedRaw = smallestStationProposal(150)
  obstructedRaw.__constructionRemovals = { 902, 901 }
  local obstructed, obstructedError = proposalCodec.normalise(
    obstructedRaw, "company:1", {
      resolveCanonical = function(kind, localId)
        if kind == "construction" and localId == 901 then return "construction:pre:house-a" end
        if kind == "construction" and localId == 902 then return "construction:pre:house-b" end
      end,
      entityKind = function() return "construction" end,
    })
  truthy(obstructed, obstructedError)
  equal(obstructed.constructions[1].mode, "build")
  equal(obstructed.constructions[1].adapter, "stock-rail-station")
  equal(obstructed.constructions[1].sourceCid, "")
  equal(#obstructed.constructions[1].collateral, 2)
  equal(obstructed.constructions[1].collateral[1].cid, "construction:pre:house-a")
  equal(obstructed.constructions[1].collateral[2].cid, "construction:pre:house-b")
  local obstructedSpec = assert(proposalCodec.materialiseConstruction(obstructed))
  equal(obstructedSpec.mode, "build")
  equal(obstructedSpec.transform[13], 100)
  equal(#obstructedSpec.collateral, 2)

  local rotated = assert(proposalCodec.normalise(smallestStationProposal(
    200,
    3400020,
    { 0, 1, 0, 0, -1, 0, 0, 0, 0, 0, 1, 0, 1747.9459228515625, -914.61053466796875, 50.333236694335938, 1 },
    0
  ), "company:1"))
  equal(rotated.constructions[1].modules[1].slot, 3400020)
  local rotatedSpec = assert(proposalCodec.materialiseConstruction(rotated))
  equal(rotatedSpec.params.modules[3400020].metadata.moreCapacity.passenger, 30)
  equal(rotatedSpec.params.modules[8401000].name,
    "station/rail/modular_station/platform_track.module")
  equal(rotatedSpec.transform[2], 1)

  local tampered = smallestStationProposal(0)
  tampered.__constructionAdditions[1].params.modules[8401000].name =
    "station/rail/modular_station/platform_track.module"
  local rejected, rejectError = proposalCodec.normalise(tampered, "company:1")
  equal(rejected, nil)
  truthy(tostring(rejectError):match("module set"), rejectError)

  local prefix = "station/rail/modular_station/"
  local cargoRaw = smallestStationProposal(300, 3400020, nil, 0)
  cargoRaw.__constructionAdditions[1].params.modules = {
    [3400020] = { name = prefix .. "main_building_1_cargo.module", variant = 0 },
    [6400000] = { name = prefix .. "platform_cargo_era_c.module", variant = 0 },
    [6400010] = { name = prefix .. "platform_cargo_era_c.module", variant = 0 },
    [8402000] = { name = prefix .. "platform_track.module", variant = 0 },
    [8402010] = { name = prefix .. "platform_track.module", variant = 0 },
  }
  local cargo = assert(proposalCodec.normalise(cargoRaw, "company:1"))
  equal(#cargo.constructions[1].modules, 5)
  local cargoSpec = assert(proposalCodec.materialiseConstruction(cargo))
  equal(cargoSpec.params.modules[3400020].metadata.moreCapacity.cargo, 20)
  equal(cargoSpec.params.modules[6400000].metadata.cargo_platform, true)

  local longerRaw = smallestStationProposal(400, 3400000, nil, 0, 19)
  longerRaw.__constructionAdditions[1].params.length = 1
  longerRaw.__constructionAdditions[1].params.modules = {
    [3400000] = { name = prefix .. "main_building_1_era_c.module", variant = 0 },
    [7399990] = { name = prefix .. "platform_passenger_era_c.module", variant = 0 },
    [7400000] = { name = prefix .. "platform_passenger_era_c.module", variant = 0 },
    [7400010] = { name = prefix .. "platform_passenger_era_c.module", variant = 0 },
    [8400990] = { name = prefix .. "platform_track.module", variant = 0 },
    [8401000] = { name = prefix .. "platform_track.module", variant = 0 },
    [8401010] = { name = prefix .. "platform_track.module", variant = 0 },
    [10399990] = { name = prefix .. "platform_passenger_roof_era_c.module", variant = 0 },
    [10400000] = { name = prefix .. "platform_passenger_roof_era_c.module", variant = 0 },
    [10400010] = { name = prefix .. "platform_passenger_roof_era_c.module", variant = 0 },
    [10800000] = { name = prefix .. "addon_platform_passenger_stairs_era_c.module", variant = 0 },
  }
  local longer = assert(proposalCodec.normalise(longerRaw, "company:1"))
  equal(#longer.nodes, 19)
  equal(#longer.edges, 18)
  equal(#longer.constructions[1].modules, 11)

  local twoTrackRaw = setStationPathGraph(smallestStationProposal(500, 3701000, nil, 1), { 13, 13 }, 1)
  local twoTrackParams = twoTrackRaw.__constructionAdditions[1].params
  twoTrackParams.trackType, twoTrackParams.tracks = 1, 1
  twoTrackParams.modules = {
    [3701000] = { name = prefix .. "main_building_1_era_c.module", variant = 0 },
    [7400000] = { name = prefix .. "platform_passenger_era_c.module", variant = 0 },
    [7400010] = { name = prefix .. "platform_passenger_era_c.module", variant = 0 },
    [7403000] = { name = prefix .. "platform_passenger_era_c.module", variant = 0 },
    [7403010] = { name = prefix .. "platform_passenger_era_c.module", variant = 0 },
    [8401000] = { name = prefix .. "platform_high_speed_track_catenary.module", variant = 0 },
    [8401010] = { name = prefix .. "platform_high_speed_track_catenary.module", variant = 0 },
    [8402000] = { name = prefix .. "platform_high_speed_track_catenary.module", variant = 0 },
    [8402010] = { name = prefix .. "platform_high_speed_track_catenary.module", variant = 0 },
    [10400000] = { name = prefix .. "platform_passenger_roof_era_c.module", variant = 0 },
    [10400010] = { name = prefix .. "platform_passenger_roof_era_c.module", variant = 0 },
    [10403000] = { name = prefix .. "platform_passenger_roof_era_c.module", variant = 0 },
    [10403010] = { name = prefix .. "platform_passenger_roof_era_c.module", variant = 0 },
    [10800000] = { name = prefix .. "addon_platform_passenger_stairs_era_c.module", variant = 0 },
    [10803000] = { name = prefix .. "addon_platform_passenger_stairs_era_c.module", variant = 0 },
  }
  local twoTrack = assert(proposalCodec.normalise(twoTrackRaw, "company:1"))
  equal(#twoTrack.nodes, 26)
  equal(#twoTrack.edges, 24)
  local twoTrackSpec = assert(proposalCodec.materialiseConstruction(twoTrack))
  equal(twoTrackSpec.params.modules[8402000].metadata.track, true)

  -- Live Build 35924 regression: snapping a stock station to an existing
  -- track endpoint references that positive node directly. The station still
  -- has one complete path, but nodesToAdd is one shorter than the detached
  -- graph (12 new nodes + 1 canonical boundary node, 12 edges).
  local attachedRaw = smallestStationProposal(600)
  local attachedNode = attachedRaw.proposal.addedNodes[1].entity
  table.remove(attachedRaw.proposal.addedNodes, 1)
  attachedRaw.proposal.addedSegments[1].comp.node0 = 7001
  local attached, attachedError = proposalCodec.normalise(attachedRaw, "company:1", {
    resolveCanonical = function(kind, localId)
      if kind == "node" and localId == 7001 then return "node:pre:station-approach" end
    end,
    resourceName = function(kind, index) return kind .. "/" .. index .. ".lua" end,
  })
  truthy(attached, attachedError)
  equal(#attached.nodes, 12)
  equal(#attached.edges, 12)
  equal(attached.edges[1].node0.cid, "node:pre:station-approach")
  truthy(proposalCodec.validatePortable(attached))
  -- Make sure the fixture really replaced the native temporary endpoint.
  truthy(attachedNode < 0)

  local invalidBoundary = util.deepCopy(attached)
  invalidBoundary.edges[#invalidBoundary.edges].node1 = {
    cid = "node:pre:station-approach",
  }
  invalidBoundary.digest = proposalCodec.digest(invalidBoundary)
  invalidBoundary.transactionId = "proposal:" .. invalidBoundary.digest
  local invalidBoundaryOk, invalidBoundaryError = proposalCodec.validatePortable(invalidBoundary)
  equal(invalidBoundaryOk, false)
  truthy(tostring(invalidBoundaryError):find("boundary node", 1, true)
    or tostring(invalidBoundaryError):find("cardinality", 1, true), invalidBoundaryError)
end)

test("proposal codec carries portable depots, arbitrary constructions, upgrades, and removals", function()
  local depot = linearProposal(-1, -2, -3, "track", 1, true)
  depot.__observedCost = 175000
  depot.constructionsToAdd = {{
    entity = -4,
    fileName = "depot/train/modern_depot.con",
    transf = { 1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1, 0, 300, 400, 7, 1 },
    params = {
      year = 1992, catenary = true, trackType = "standard.lua",
      choices = { [1] = "a", [2] = "b" },
    },
  }}
  local depotTx, depotError = proposalCodec.normalise(depot, "company:1", {
    resourceName = function(kind, index)
      if kind == "track" and index == 1 then return "standard.lua" end
    end,
    requireResourceName = true,
  })
  truthy(depotTx, depotError)
  equal(depotTx.schemaVersion, proposalCodec.CONSTRUCTION_SCHEMA_VERSION)
  equal(depotTx.constructions[1].mode, "build")
  equal(depotTx.constructions[1].adapter, "portable-construction")
  equal(depotTx.constructions[1].kind, "depot")
  equal(depotTx.constructions[1].sourceCid, "")
  local depotSpec = assert(proposalCodec.materialiseConstruction(depotTx))
  equal(depotSpec.params.choices[1], "a")
  equal(depotSpec.params.choices[2], "b")

  -- Stock road and tram depots are non-modular STREET_DEPOT constructions,
  -- unlike the modular street terminal below. Pin their exact resource names
  -- and the two tram-catenary variants so a terminal codec change cannot
  -- accidentally narrow ordinary depot support.
  local stockRoadDepotTx, stockTramDepotTx
  for _, depotCase in ipairs({
    { fileName = "depot/road_depot_era_a.con", params = { year = 1990 } },
    { fileName = "depot/tram_depot_era_a.con", params = { year = 1990, tramCatenary = 0 } },
    { fileName = "depot/tram_depot_era_a.con", params = { year = 1990, tramCatenary = 1 } },
  }) do
    local streetDepot = linearProposal(-11, -12, -13, "street", 2, false)
    streetDepot.constructionsToAdd = {{
      entity = -14, fileName = depotCase.fileName,
      transf = { 1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1, 0, 500, 600, 8, 1 },
      params = depotCase.params,
    }}
    local streetDepotTx, streetDepotError = proposalCodec.normalise(
      streetDepot, "company:1", {
        resourceName = function(kind, index) return kind .. "/" .. index .. ".lua" end,
        requireResourceName = true,
      })
    truthy(streetDepotTx, streetDepotError)
    equal(streetDepotTx.constructions[1].kind, "depot")
    local streetDepotSpec = assert(proposalCodec.materialiseConstruction(streetDepotTx))
    equal(streetDepotSpec.fileName, depotCase.fileName)
    equal(streetDepotSpec.params.tramCatenary, depotCase.params.tramCatenary)
    if depotCase.fileName == "depot/road_depot_era_a.con" then
      stockRoadDepotTx = util.deepCopy(streetDepotTx)
    elseif depotCase.params.tramCatenary == 0 then
      stockTramDepotTx = util.deepCopy(streetDepotTx)
    end
  end

  -- The helper cannot receive this explicit existing-road endpoint. Connected
  -- street depots therefore require typed exact replay; connected rail depots
  -- remain fail-closed because their typed output crashes stock selection UI.
  local snappedRoadDepot = util.deepCopy(assert(stockRoadDepotTx))
  snappedRoadDepot.edges[1].node1 = { cid = "node:pre:road-depot-approach" }
  table.remove(snappedRoadDepot.nodes, 2)
  snappedRoadDepot.digest = proposalCodec.digest(snappedRoadDepot)
  snappedRoadDepot.transactionId = "proposal:" .. snappedRoadDepot.digest
  truthy(proposalCodec.validate(snappedRoadDepot),
    "snapped-road-depot fixture is not structurally valid")
  local snappedRoadOk, snappedRoadError = proposalCodec.validatePortable(snappedRoadDepot)
  truthy(snappedRoadOk, snappedRoadError)
  local snappedRoadRecord = { transaction = snappedRoadDepot }
  truthy(constructionReplayState.isExact(snappedRoadRecord, proposalCodec),
    "connected road depot did not retain its explicit endpoint through exact replay")
  truthy(constructionReplayState.requiresAtomic(snappedRoadRecord, proposalCodec),
    "connected road depot could fall back to the detached helper path")
  equal(constructionReplayState.isExact({ transaction = stockRoadDepotTx }, proposalCodec), false,
    "isolated road depot escaped the selectable helper-built path")

  local snappedTramDepot = util.deepCopy(assert(stockTramDepotTx))
  snappedTramDepot.edges[1].node1 = { cid = "node:pre:tram-depot-approach" }
  table.remove(snappedTramDepot.nodes, 2)
  snappedTramDepot.digest = proposalCodec.digest(snappedTramDepot)
  snappedTramDepot.transactionId = "proposal:" .. snappedTramDepot.digest
  truthy(proposalCodec.validatePortable(snappedTramDepot),
    "snapped tram-depot fixture is not portable")
  local snappedTramRecord = { transaction = snappedTramDepot }
  truthy(constructionReplayState.isConnectedStreetDepot(
      snappedTramDepot, snappedTramDepot.constructions[1])
      and constructionReplayState.isExact(snappedTramRecord, proposalCodec)
      and constructionReplayState.requiresAtomic(snappedTramRecord, proposalCodec),
    "connected tram depot did not inherit exact atomic street-depot replay")

  -- The policy is graph-derived, not a depot/station/resource allowlist. A
  -- data-driven or mod-provided construction that exposes the same existing
  -- street endpoint must never fall back to transform-only placement either.
  local genericConnected = util.deepCopy(snappedRoadDepot)
  genericConnected.constructions[1].kind = "construction"
  genericConnected.constructions[1].fileName = "industry/modded_road_facility.con"
  genericConnected.digest = proposalCodec.digest(genericConnected)
  genericConnected.transactionId = "proposal:" .. genericConnected.digest
  truthy(proposalCodec.validatePortable(genericConnected),
    "generic connected construction fixture is not portable")
  local genericRecord = { transaction = genericConnected }
  truthy(constructionReplayState.hasExistingStreetEndpoint(
      genericConnected, genericConnected.constructions[1])
      and constructionReplayState.isExact(genericRecord, proposalCodec)
      and constructionReplayState.requiresAtomic(genericRecord, proposalCodec),
    "generic road-connected construction could detach through helper fallback")

  local decoratedConnected = util.deepCopy(genericConnected)
  decoratedConnected.edgeObjects.add = {{
    slot = "edge_object:1", edge = { slot = "edge:1" }, param = 0.5,
    oneWay = false, left = false, model = "street/bus_stop_v2.mdl",
    name = "", category = 1, logicalOwnerCid = "company:1", private = true,
  }}
  decoratedConnected.digest = proposalCodec.digest(decoratedConnected)
  decoratedConnected.transactionId = "proposal:" .. decoratedConnected.digest
  truthy(proposalCodec.validatePortable(decoratedConnected),
    "decorated connected construction fixture is not portable")
  local decoratedRecord = { transaction = decoratedConnected }
  truthy(constructionReplayState.isExact(decoratedRecord, proposalCodec)
      and constructionReplayState.requiresAtomic(decoratedRecord, proposalCodec),
    "a construction-owned edge object escaped atomic exact replay")

  local isolatedGeneric = util.deepCopy(genericConnected)
  isolatedGeneric.edges[1].node1 = { slot = "node:2" }
  isolatedGeneric.nodes[2] = util.deepCopy(stockRoadDepotTx.nodes[2])
  isolatedGeneric.digest = proposalCodec.digest(isolatedGeneric)
  isolatedGeneric.transactionId = "proposal:" .. isolatedGeneric.digest
  local isolatedGenericRecord = { transaction = isolatedGeneric }
  truthy(constructionReplayState.isExact(isolatedGenericRecord, proposalCodec),
    "isolated generic construction lost exact replay")
  equal(constructionReplayState.requiresAtomic(isolatedGenericRecord, proposalCodec), false,
    "isolated generic construction was unnecessarily forbidden from helper fallback")

  -- Build 35924 exposes every vanilla bus/tram and truck terminal size through
  -- one generic construction resource.  Exercise all six era/type templates,
  -- every platform-count and length value, and all three tram modes without a
  -- per-variant codec.  The first case also proves atomic house collateral.
  local terminalCases = 0
  local function terminalModules(templateIndex, platL, platR, length)
    local modules, cargo = {}, templateIndex >= 3
    local variant = cargo and 1 or 0
    local name = cargo and "station/street/cargo_platform.module"
      or "station/street/passenger_platform.module"
    local function mangle(i, j, kind) return 200000 * (j + 100) + 100 * (i + 100) + kind end
    for i = -1, -platL, -1 do
      for j = 0, length do
        modules[mangle(i, j - math.floor(length / 2), variant)] = {
          name = name, variant = 0, metadata = "<userdata>",
        }
      end
    end
    for i = 0, platR - 1 do
      for j = 0, length do
        modules[mangle(i, j - math.floor(length / 2), variant)] = {
          name = name, variant = 0, metadata = "<userdata>",
        }
      end
    end
    modules[mangle(55, 0, 3)] = {
      name = "station/street/entrance_exit.module", variant = 0, metadata = "<userdata>",
    }
    return modules
  end
  for templateIndex = 0, 5 do
    for platforms = 0, 3 do
      for length = 0, 2 do
        for tramTrack = 0, 2 do
          terminalCases = terminalCases + 1
          local removals = terminalCases == 1 and { 601, 602, 603, 604, 605, 606, 607 } or {}
          local raw = {
            __observedCost = 125000,
            __constructionAdditions = {{
              fileName = "station/street/modular_terminal.con",
              transf = { 1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1, 0, 800, 900, 4, 1 },
              params = {
                templateIndex = templateIndex, year = 1990, seed = 17,
                platL = platforms, platR = 3 - platforms,
                length = length, length2 = length,
                tramTrack = tramTrack, tramTrackType = 0,
                modules = terminalModules(templateIndex, platforms, 3 - platforms, length),
              },
            }},
            __constructionRemovals = removals,
          }
          local transaction, terminalError = proposalCodec.normalise(raw, "company:1", {
            resolveCanonical = function(kind, localId)
              if kind == "construction" and localId >= 601 and localId <= 607 then
                return "construction:pre:house-" .. tostring(localId)
              end
            end,
            entityKind = function() return "construction" end,
          })
          truthy(transaction, terminalError)
          local construction = transaction.constructions[1]
          equal(construction.adapter, "portable-construction")
          equal(construction.kind, "station")
          equal(construction.fileName, "station/street/modular_terminal.con")
          equal(next(construction.modules[1].metadata), nil)
          local spec = assert(proposalCodec.materialiseConstruction(transaction))
          equal(spec.params.templateIndex, templateIndex)
          equal(spec.params.platL, platforms)
          equal(spec.params.platR, 3 - platforms)
          equal(spec.params.length, length)
          equal(spec.params.length2, length)
          equal(spec.params.tramTrack, tramTrack)
          if terminalCases == 1 then equal(#spec.collateral, 7) end
        end
      end
    end
  end
  equal(terminalCases, 216)

  -- Airports use the same portable-construction adapter, but their generated
  -- runway/taxiway graph is much larger than an ordinary station and their
  -- stock options are not rail-style fields. Exercise every passenger/cargo,
  -- hangar, terminal-count and runway-direction combination. One modern
  -- airport deliberately carries 384 nodes and 383 STREET edges so the test
  -- crosses the ordinary 256-edge limit and proves schema 7's airport-sized
  -- construction budget on both normalization and portable validation.
  local airportCases, largeAirport
  airportCases = 0
  local airportFiles = {
    {
      fileName = "station/air/airfield.con",
      years = { 1930 }, directions = { 0 },
      modules = function(templateIndex, hangar)
        local terminalName = templateIndex == 0
          and "station/air/airfield_passenger_terminal.module"
          or "station/air/airfield_cargo_terminal.module"
        local modules = {
          [10001000] = { name = "station/air/airfield_main_building.module", variant = 0 },
          [10070002] = { name = terminalName, variant = 0 },
        }
        if hangar == 0 then
          modules[10002004] = { name = "station/air/airfield_hangar.module", variant = 0 }
        end
        return modules
      end,
    },
    {
      fileName = "station/air/airport.con",
      years = { 1970, 1990 }, directions = { 0, 1 },
      modules = function(templateIndex, hangar, direction, year, terminals)
        local terminalName = templateIndex == 0
          and "station/air/airport_terminal.module"
          or "station/air/airport_cargo_terminal.module"
        local modules = {
          [1002] = { name = "station/air/airport_main_building.module", variant = 0 },
          [templateIndex == 0 and 70006 or 80006] = { name = terminalName, variant = 0 },
          [9001 - direction] = { name = year > 1980
              and "station/air/airport_era_c_landing_direction.module"
              or "station/air/airport_era_b_landing_direction.module",
            variant = direction },
        }
        if hangar == 0 then
          modules[2007 + 3 * (terminals + 1)] = {
            name = "station/air/airport_hangar.module", variant = 0,
          }
        end
        return modules
      end,
    },
  }
  for _, airport in ipairs(airportFiles) do
    for _, year in ipairs(airport.years) do
      for templateIndex = 0, 1 do
        for hangar = 0, 1 do
          for terminals = 0, 2 do
            for _, direction in ipairs(airport.directions) do
              airportCases = airportCases + 1
              local nodes, edges = {}, {}
              local large = airport.fileName == "station/air/airport.con"
                and year == 1990 and templateIndex == 0 and hangar == 0
                and terminals == 2 and direction == 1
              local nodeCount = large and 384 or 0
              for index = 1, nodeCount do
                nodes[index] = {
                  entity = -10000 - index,
                  comp = { position = { x = 2000 + index * 4, y = 3000, z = 8 } },
                }
                if index > 1 then
                  edges[#edges + 1] = {
                    entity = -20000 - #edges - 1, type = 0,
                    comp = {
                      node0 = nodes[index - 1].entity, node1 = nodes[index].entity,
                      tangent0 = { x = 4, y = 0, z = 0 },
                      tangent1 = { x = 4, y = 0, z = 0 }, type = 0, typeIndex = 0,
                    },
                    streetEdge = { streetType = 10 },
                  }
                end
              end
              local airportParams = {
                templateIndex = templateIndex, year = year, seed = 31,
                hangar = hangar, terminals = terminals,
                modules = airport.modules(templateIndex, hangar, direction, year, terminals),
              }
              if airport.fileName == "station/air/airport.con" then
                -- The modern airport exposes landing direction; the 1920
                -- airfield does not.
                airportParams.dir = direction
              end
              local raw = {
                __observedCost = 5000000,
                __constructionAdditions = {{
                  fileName = airport.fileName,
                  transf = { 1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1, 0, 2000, 3000, 8, 1 },
                  params = airportParams,
                }},
                __constructionRemovals = airportCases == 1 and { 701, 702, 703 } or {},
                streetProposal = {
                  nodesToAdd = nodes, edgesToAdd = edges,
                  nodesToRemove = {}, edgesToRemove = {},
                  edgeObjectsToAdd = {}, edgeObjectsToRemove = {},
                },
              }
              local normaliseOptions = {
                resolveCanonical = function(kind, localId)
                  if kind == "construction" and localId >= 701 and localId <= 703 then
                    return "construction:pre:airport-obstruction-" .. tostring(localId)
                  end
                end,
                entityKind = function() return "construction" end,
                resourceName = function(kind, index)
                  if kind == "street" and index == 10 then
                    return "airport/airport_runway_medium.lua"
                  end
                end,
                requireResourceName = true,
              }
              local transaction, airportError = proposalCodec.normalise(
                raw, "company:1", normaliseOptions)
              truthy(transaction, airportError)
              equal(transaction.schemaVersion, proposalCodec.CONSTRUCTION_SCHEMA_VERSION)
              equal(transaction.constructions[1].kind, "station")
              equal(transaction.constructions[1].adapter, "portable-construction")
              local portable, portableError = proposalCodec.validatePortable(transaction)
              truthy(portable, portableError)
              local spec = assert(proposalCodec.materialiseConstruction(transaction))
              equal(spec.fileName, airport.fileName)
              equal(spec.params.templateIndex, templateIndex)
              equal(spec.params.hangar, hangar)
              equal(spec.params.terminals, terminals)
              if airport.fileName == "station/air/airport.con" then
                equal(spec.params.dir, direction)
              else
                equal(spec.params.dir, nil)
              end
              if airportCases == 1 then equal(#spec.collateral, 3) end
              if large then
                equal(#transaction.nodes, 384)
                equal(#transaction.edges, 383)
                equal(transaction.edges[383].resource.name,
                  "airport/airport_runway_medium.lua")
                largeAirport = transaction
              end
            end
          end
        end
      end
    end
  end
  equal(airportCases, 60)
  truthy(largeAirport, "airport variant matrix never exercised the large runway graph")

  -- The modular harbor is a single construction resource with passenger/cargo,
  -- small/large, and 1/2/4-terminal templates. Keep every stock template
  -- portable; modded module names remain data rather than hard-coded topology.
  local harborCases = 0
  for templateIndex = 0, 1 do
    for size = 0, 1 do
      for terminals = 0, 2 do
        harborCases = harborCases + 1
        local modules = validationConstruction.harborModules(
          templateIndex == 1, size == 1, terminals)
        local raw = {
          __observedCost = 750000,
          __constructionAdditions = {{
            fileName = "station/water/harbor_modular.con",
            transf = { 1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1, 0, 2400, 3200, 0, 1 },
            params = {
              templateIndex = templateIndex, size = size, terminals = terminals,
              seed = 41, year = 1990, modules = modules,
            },
          }},
          __constructionRemovals = harborCases == 1 and { 711, 712 } or {},
        }
        local transaction, harborError = proposalCodec.normalise(raw, "company:1", {
          resolveCanonical = function(kind, localId)
            if kind == "construction" and (localId == 711 or localId == 712) then
              return "construction:pre:harbor-obstruction-" .. tostring(localId)
            end
          end,
          entityKind = function() return "construction" end,
        })
        truthy(transaction, harborError)
        equal(transaction.constructions[1].kind, "station")
        equal(transaction.constructions[1].adapter, "portable-construction")
        local portable, portableError = proposalCodec.validatePortable(transaction)
        truthy(portable, portableError)
        local spec = assert(proposalCodec.materialiseConstruction(transaction))
        equal(spec.fileName, "station/water/harbor_modular.con")
        equal(spec.params.templateIndex, templateIndex)
        equal(spec.params.size, size)
        equal(spec.params.terminals, terminals)
        truthy(next(spec.params.modules) ~= nil, "harbor module map was discarded")
        if harborCases == 1 then equal(#spec.collateral, 2) end
      end
    end
  end
  equal(harborCases, 12)

  -- Live relay regression mp-094022e94f4ae9c3: the depot was placed before
  -- the player drew its visible connection, but Build 35924 silently snapped
  -- the generated access edge to a pre-existing canonical track node.  The
  -- public helper cannot replay that endpoint deterministically.
  local snappedDepot = util.deepCopy(depotTx)
  snappedDepot.edges[1].node1 = { cid = "node:pre:depot-approach" }
  table.remove(snappedDepot.nodes, 2)
  snappedDepot.digest = proposalCodec.digest(snappedDepot)
  snappedDepot.transactionId = "proposal:" .. snappedDepot.digest
  truthy(proposalCodec.validate(snappedDepot),
    "snapped-depot fixture is not a structurally valid canonical proposal")
  local snappedOk, snappedError = proposalCodec.validatePortable(snappedDepot)
  equal(snappedOk, false)
  truthy(tostring(snappedError):find("place the depot clear of track", 1, true), snappedError)

  local asset = {
    __observedCost = 500,
    __constructionAdditions = {{
      fileName = "asset/decoration/example.con",
      transf = { 2, 0, 0, 0, 0, 2, 0, 0, 0, 0, 1, 0, 10, 20, 3, 1 },
      params = {
        seed = 4,
        modules = {
          [910000] = {
            name = "asset/decoration/example.module", variant = 2,
            metadata = { capacity = { passenger = 5 } },
          },
        },
      },
    }},
    __constructionRemovals = {},
  }
  local assetTx, assetError = proposalCodec.normalise(asset, "company:1")
  truthy(assetTx, assetError)
  equal(#assetTx.nodes, 0)
  equal(#assetTx.edges, 0)
  equal(assetTx.constructions[1].kind, "asset")
  equal(assetTx.constructions[1].modules[1].slot, 910000)
  local assetSpec = assert(proposalCodec.materialiseConstruction(assetTx))
  equal(assetSpec.params.modules[910000].variant, 2)
  equal(assetSpec.params.modules[910000].metadata.capacity.passenger, 5)

  local upgrade = util.deepCopy(asset)
  upgrade.__observedCost = 250
  upgrade.__constructionRemovals = { 500 }
  upgrade.__constructionAdditions[1].params.seed = 5
  upgrade.__constructionAdditions[1].params.upgrade = true
  local upgradeTx, upgradeError = proposalCodec.normalise(upgrade, "company:1", {
    resolveCanonical = function(kind, localId)
      if kind == "asset" and localId == 500 then return "asset:pre:asset" end
    end,
  })
  truthy(upgradeTx, upgradeError)
  equal(upgradeTx.constructions[1].mode, "upgrade")
  equal(#upgradeTx.constructions[1].collateral, 0)
  equal(upgradeTx.constructions[1].sourceCid, "asset:pre:asset")
  equal(upgradeTx.constructions[1].params.seed, 5)
  equal(upgradeTx.constructions[1].params.upgrade, true)
  local upgradeSpec = assert(proposalCodec.materialiseConstruction(upgradeTx))
  equal(upgradeSpec.mode, "upgrade")
  equal(upgradeSpec.params.seed, nil)
  equal(upgradeSpec.params.upgrade, nil)

  local removalTx, removalError = proposalCodec.normalise({
    __observedCost = -100,
    __constructionAdditions = {},
    __constructionRemovals = { { entity = 500 } },
  }, "company:1", {
    resolveCanonical = function(kind, localId)
      if kind == "asset" and localId == 500 then return "asset:pre:asset" end
    end,
    entityKind = function(localId)
      if localId == 500 then return "asset" end
    end,
  })
  truthy(removalTx, removalError)
  equal(removalTx.constructions[1].mode, "remove")
  equal(#removalTx.edges, 0)
  local removalSpec = assert(proposalCodec.materialiseConstruction(removalTx))
  equal(removalSpec.sourceCid, "asset:pre:asset")

  local opaque = util.deepCopy(asset)
  opaque.__constructionAdditions[1].params.callback = "<function>"
  local rejected, rejectError = proposalCodec.normalise(opaque, "company:1")
  equal(rejected, nil)
  truthy(tostring(rejectError):find("opaque projected value", 1, true), rejectError)

  -- Only Build 35924's exact MetadataMap sentinel is resource-derived. Do not
  -- turn the exception into a general opaque-value bypass for module payloads.
  local opaqueModule = util.deepCopy(asset)
  opaqueModule.__constructionAdditions[1].params.modules[910000].metadata = "<function>"
  local moduleRejected, moduleRejectError = proposalCodec.normalise(opaqueModule, "company:1")
  equal(moduleRejected, nil)
  truthy(tostring(moduleRejectError):find("opaque projected value", 1, true), moduleRejectError)
end)

test("proposal codec fails closed on unsupported or tampered payloads", function()
  local unsupported = linearProposal(-1, -2, -3, "street", 4, false)
  unsupported.constructionsToAdd[1] = {
    entity = -4,
    fileName = "station/rail/modular_station/modular_station.con",
    transf = { 1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1, 0, 100, 200, 5, 1 },
    params = { trackType = 0, catenary = 0, modules = { [1] = { name = "platform.module" } } },
  }
  local value, err = proposalCodec.normalise(unsupported, "company:1")
  equal(value, nil)
  truthy(tostring(err):match("station"))
  local diagnostic = proposalCodec.diagnose(unsupported)
  equal(diagnostic.supported, false)
  equal(diagnostic.counts.constructionsToAdd, 1)
  equal(diagnostic.constructionSamples[1].kindHint, "station")
  equal(diagnostic.constructionSamples[1].fileName,
    "station/rail/modular_station/modular_station.con")
  equal(diagnostic.constructionSamples[1].moduleCount, 1)
  truthy(diagnostic.constructionSamples[1].hasTransform)
  equal(diagnostic.constructionSamples[1].entity, nil)
  equal(#diagnostic.constructionSamples[1].transform, 16)
  equal(diagnostic.constructionSamples[1].transform[13], 100)
  equal(diagnostic.constructionSamples[1].params.trackType, 0)
  equal(diagnostic.constructionSamples[1].params.catenary, 0)
  equal(diagnostic.constructionSamples[1].modules["1"].name, "platform.module")
  local deepOnly = {
    __constructionAdditions = unsupported.constructionsToAdd,
    __observedCost = 100,
  }
  local deepDiagnostic = proposalCodec.diagnose(deepOnly)
  equal(deepDiagnostic.supported, false)
  equal(deepDiagnostic.counts.constructionsToAdd, 1)
  equal(deepDiagnostic.constructionSamples[1].fileName,
    "station/rail/modular_station/modular_station.con")

  local signal = linearProposal(-1, -2, -3, "track", 1, false)
  signal.streetProposal.edgesToAdd[1].comp.objects = { { -4, 2 } }
  signal.streetProposal.edgeObjectsToAdd[1] = {
    entity = -4,
    edgeEntity = -1,
    param = 0.42,
    oneWay = true,
    left = false,
    model = "railroad/signal_path_a.mdl",
    playerEntity = 100,
    name = "Block 1",
  }
  local signalValue, signalError = proposalCodec.normalise(signal, "company:1")
  truthy(signalValue, signalError)
  equal(signalValue.edgeObjects.add[1].edge.slot, "edge:1")
  equal(signalValue.edgeObjects.add[1].model, "railroad/signal_path_a.mdl")
  equal(signalValue.edgeObjects.add[1].category, 2)
  equal(signalValue.edgeObjects.add[1].private, true)
  local signalDiagnostic = proposalCodec.diagnose(signal)
  equal(signalDiagnostic.supported, true)
  equal(signalDiagnostic.counts.edgeObjectsToAdd, 1)

  -- Build 35924's genuine streetTerminalBuilder callback exposes the
  -- processed StreetProposal shape: modelInstance + segmentEntity, with no
  -- public SimpleStreetProposal param/model fields. Recover a portable model
  -- filename and spline parameter from that native output.
  local processedSignal = linearProposal(-1, -2, -3, "track", 1, false)
  processedSignal.streetProposal.edgesToAdd[1].comp.objects = { { -1, 2 } }
  processedSignal.streetProposal.edgeObjectsToAdd[1] = {
    segmentEntity = -1,
    category = 2,
    left = true,
    modelInstance = {
      modelId = 2014,
      transform = { -1, 0, 0, 0, 0, -1, 0, 0, 0, 0, 1, 0, 50, 20, 3.5, 1 },
    },
    playerEntity = 100,
    name = "Processed signal",
  }
  local processedValue, processedError = proposalCodec.normalise(
    processedSignal, "company:1", {
      resourceName = function(kind, index)
        if kind == "track" and index == 1 then return "standard.lua" end
        if kind == "model" and index == 2014 then return "railroad/signal_path_c.mdl" end
      end,
      requireResourceName = true,
    })
  truthy(processedValue, processedError)
  equal(processedValue.edgeObjects.add[1].model, "railroad/signal_path_c.mdl")
  truthy(math.abs(processedValue.edgeObjects.add[1].param - 0.5) < 0.0001,
    processedValue.edgeObjects.add[1].param)
  equal(processedValue.edgeObjects.add[1].oneWay, false)
  equal(processedValue.edgeObjects.add[1].left, true)

  local processedSentinel = linearProposal(-1, -2, -3, "track", 1, false)
  processedSentinel.streetProposal.edgesToAdd[1].comp.objects = { { -1, 2 } }
  processedSentinel.streetProposal.edgeObjectsToAdd[1] = {
    segmentEntity = -1,
    category = 2,
    param = -1,
    left = false,
    modelInstance = {
      modelId = 2014,
      transform = { -1, 0, 0, 0, 0, -1, 0, 0, 0, 0, 1, 0, 70, 20, 3.75, 1 },
    },
    playerEntity = 100,
  }
  local sentinelValue, sentinelError = proposalCodec.normalise(
    processedSentinel, "company:1", {
      resourceName = function(kind, index)
        if kind == "track" and index == 1 then return "standard.lua" end
        if kind == "model" and index == 2014 then return "railroad/signal_path_c.mdl" end
      end,
      requireResourceName = true,
    })
  truthy(sentinelValue, sentinelError)
  truthy(math.abs(sentinelValue.edgeObjects.add[1].param - 0.75) < 0.0001,
    sentinelValue.edgeObjects.add[1].param)
  local sentinelDiagnostic = proposalCodec.diagnose(processedSentinel)
  equal(sentinelDiagnostic.edgeObjectSamples[1].param, -1)
  equal(sentinelDiagnostic.edgeObjectSamples[1].modelId, 2014)
  equal(sentinelDiagnostic.edgeObjectSamples[1].modelTransform[13], 70)

  local invalidSentinel = linearProposal(-1, -2, -3, "track", 1, false)
  invalidSentinel.streetProposal.edgesToAdd[1].comp.objects = { { -1, 2 } }
  invalidSentinel.streetProposal.edgeObjectsToAdd[1] = {
    segmentEntity = -1, category = 2, param = -1, left = false,
    model = "railroad/signal_path_c.mdl", playerEntity = 100,
  }
  local invalidValue, invalidError = proposalCodec.normalise(invalidSentinel, "company:1")
  equal(invalidValue, nil)
  truthy(tostring(invalidError):match("outside %[%s*0,1%s*%]") ~= nil, invalidError)

  local signalObjectVectorAssignments = 0
  local function signalSegment()
    local backing = { objects = {} }
    local comp = newproxy(true)
    local meta = getmetatable(comp)
    meta.__index = function(_, key) return backing[key] end
    meta.__newindex = function(_, key, value)
      if key == "objects" then signalObjectVectorAssignments = signalObjectVectorAssignments + 1 end
      backing[key] = value
    end
    return { comp = comp }
  end
  local signalApi = {
    type = {
      SimpleProposal = { new = function() return { streetProposal = {
        nodesToAdd = {}, edgesToAdd = {}, nodesToRemove = {}, edgesToRemove = {},
        edgeObjectsToAdd = {}, edgeObjectsToRemove = {},
      } } end },
      -- Build 35924's generated BaseEdge binding requires its whole-vector
      -- setter. An indexed write can mutate the exposed proxy without creating
      -- a typed native pair, so model that boundary with opaque userdata.
      SegmentAndEntity = { new = signalSegment },
      SimpleStreetProposal = { EdgeObject = { new = function() return {} end } },
      EdgeObject = { new = function() return {} end },
      PlayerOwned = { new = function() return {} end },
      NodeAndEntity = { new = function() return { comp = {} } end },
      Vec3f = { new = function(x, y, z) return { x = x, y = y, z = z } end },
      BaseEdgeStreet = { new = function() return {} end },
      BaseEdgeTrack = { new = function() return {} end },
    },
    res = {
      streetTypeRep = { find = function() return 4 end },
      trackTypeRep = { find = function() return 1 end },
      modelRep = { find = function(name)
        return name == "railroad/signal_path_a.mdl" and 71 or -1
      end },
    },
  }
  local signalProposal, signalMetadata = proposalCodec.materialise(signalValue, {
    api = signalApi, nativePlayerId = 100,
  })
  truthy(signalProposal, signalMetadata)
  -- SimpleStreetProposal edge objects have a vector-local negative index
  -- space; the first object is -1 even though edge/node temporary ids occupy
  -- -1 through -3 in the captured proposal.
  equal(signalProposal.streetProposal.edgesToAdd[1].comp.objects[1][1], -1)
  equal(signalProposal.streetProposal.edgesToAdd[1].comp.objects[1][2], 2)
  equal(signalObjectVectorAssignments, 1)
  equal(signalProposal.streetProposal.edgeObjectsToAdd[1].edgeEntity, -1)
  equal(signalProposal.streetProposal.edgeObjectsToAdd[1].model, "railroad/signal_path_a.mdl")
  equal(signalProposal.streetProposal.edgeObjectsToAdd[1].playerEntity, 100)
  local signalMatch, signalMatchError = proposalCodec.matchCreated(signalValue, {
    { localId = 7001, position = { x = 10, y = 20, z = 3 } },
    { localId = 7002, position = { x = 90, y = 20, z = 4 } },
  }, {{
    localId = 8001, carrier = "track",
    node0Position = { x = 10, y = 20, z = 3 },
    node1Position = { x = 90, y = 20, z = 4 },
    objects = { { localId = 9001, category = 2 } },
  }})
  truthy(signalMatch, signalMatchError)
  equal(signalMatch.edgeObjects["edge_object:1"], 9001)

  local tx = assert(proposalCodec.normalise(linearProposal(-1, -2, -3, "track", 1, false), "company:1"))
  tx.edges[1].catenary = true
  local valid, validationError = proposalCodec.validate(tx)
  equal(valid, false)
  truthy(tostring(validationError):match("digest mismatch"))
end)

test("network resource preflight accepts callable engine repository methods", function()
  local transaction = assert(proposalCodec.normalise(
    linearProposal(-1, -2, -3, "track", 1, false),
    "company:1",
    { resourceName = function() return "standard.lua" end, requireResourceName = true }
  ))
  local callableFind = setmetatable({}, {
    __call = function(_, name) return name == "standard.lua" and 7 or -1 end,
  })
  local resolved = assert(proposalCodec.preflightResources(transaction, {
    res = { trackTypeRep = { find = callableFind } },
  }))
  equal(resolved.edges[1], 7)
end)

test("mobility telemetry exposes canonical aggregate counts without local entity IDs", function()
  local previousApi, previousGame = api, game
  game = {
    interface = {
      getEntity = function(id) return { id = id, type = "LINE", name = id == 10 and "A" or "B" } end,
      getLines = function() return { 10, 20 } end,
      getVehicles = function() return {} end,
    },
  }
  api = {
    type = { ComponentType = { NAME = "NAME", LINE = "LINE", TRANSPORT_VEHICLE = "TRANSPORT_VEHICLE" } },
    engine = {
      getComponent = function(id, kind)
        if kind == "NAME" then return { name = id == 10 and "A" or "B" } end
        return nil
      end,
      system = {
        lineSystem = { getLines = function() return { 10, 20 } end },
        transportVehicleSystem = { getLineVehicles = function(id) return id == 10 and { 100, 101 } or { 102 } end },
        simPersonSystem = {
          getCount = function() return 50 end,
          getSimPersonsForLine = function(id) return id == 10 and { 1, 2, 3 } or { 4 } end,
        },
        simCargoSystem = {
          getSimCargosForLine = function(id) return id == 10 and { 11, 12 } or {} end,
        },
        simPersonAtTerminalSystem = {
          getEdgeInfoMap = function() return { edgeA = {}, edgeB = {} } end,
          getNumFreePlaces = function(edge) return edge == "edgeA" and 7 or 5 end,
        },
      },
    },
  }
  local registry = canonical.newState()
  local snapshot = world.mobilitySnapshot(registry)
  api, game = previousApi, previousGame
  equal(snapshot.totalPersons, 50)
  equal(snapshot.totals.passengerLineUses, 4)
  equal(snapshot.totals.cargoLineUses, 2)
  equal(snapshot.totals.vehicles, 3)
  equal(snapshot.terminalEdges, 2)
  equal(snapshot.terminalFreePlaces, 12)
  equal(#snapshot.lines, 2)
  truthy(not json.encode(snapshot):match("localId"), "mobility payload leaked machine-local IDs")
end)

test("mobility telemetry accepts generated callable system methods", function()
  local previousApi, previousGame = api, game
  local function callable(fn)
    return setmetatable({}, { __call = function(_, ...) return fn(...) end })
  end
  game = { interface = {
    getEntity = function(id) return { id = id, type = "LINE", name = "Callable" } end,
    getLines = function() return { 10 } end,
    getVehicles = function() return {} end,
  } }
  api = {
    type = { ComponentType = {
      NAME = "NAME", LINE = "LINE", TRANSPORT_VEHICLE = "TRANSPORT_VEHICLE",
    } },
    engine = {
      getComponent = function(id, kind)
        if kind == "NAME" then return { name = "Callable" } end
      end,
      system = {
        lineSystem = { getLines = function() return { 10 } end },
        transportVehicleSystem = { getLineVehicles = function() return {} end },
        simPersonSystem = {
          getCount = callable(function() return 12 end),
          getSimPersonsForLine = callable(function(id)
            return id == 10 and { 101, 102, 103 } or {}
          end),
        },
        simCargoSystem = {
          getSimCargosForLine = callable(function(id)
            return id == 10 and { 201, 202 } or {}
          end),
        },
        simPersonAtTerminalSystem = {
          getEdgeInfoMap = callable(function() return {} end),
          getNumFreePlaces = callable(function() return 0 end),
        },
      },
    },
  }
  local snapshot = world.mobilitySnapshot(canonical.newState())
  local capabilities = world.capabilityProbe()
  api, game = previousApi, previousGame
  equal(snapshot.totalPersons, 12)
  equal(snapshot.totals.passengerLineUses, 3)
  equal(snapshot.totals.cargoLineUses, 2)
  truthy(snapshot.availability.totalPersons)
  truthy(snapshot.availability.linePassengers)
  truthy(snapshot.availability.lineCargo)
  truthy(capabilities.simPersonCount)
  truthy(capabilities.simPersonsForLine)
  truthy(capabilities.simCargosForLine)
  truthy(capabilities.simPersonTerminalInfo)
end)

test("mobility telemetry falls back to direct populated-world components", function()
  local previousApi, previousGame = api, game
  local componentTypes = {
    NAME = "NAME", LINE = "LINE", TRANSPORT_VEHICLE = "TRANSPORT_VEHICLE",
    SIM_PERSON = "SIM_PERSON", SIM_CARGO = "SIM_CARGO",
    SIM_ENTITY_AT_VEHICLE = "SIM_ENTITY_AT_VEHICLE",
    SIM_PERSON_AT_VEHICLE = "SIM_PERSON_AT_VEHICLE",
    SIM_ENTITY_AT_TERMINAL = "SIM_ENTITY_AT_TERMINAL",
    SIM_PERSON_AT_TERMINAL = "SIM_PERSON_AT_TERMINAL",
    SIM_CARGO_AT_TERMINAL = "SIM_CARGO_AT_TERMINAL",
  }
  local components = {
    NAME = { [10] = { name = "Passenger" }, [20] = { name = "Cargo" } },
    SIM_PERSON = { [1001] = {}, [1002] = {}, [1003] = {}, [1004] = {} },
    SIM_CARGO = { [2001] = {}, [2002] = {}, [2003] = {} },
    SIM_ENTITY_AT_VEHICLE = {
      [1001] = { line = 10, vehicle = 101 },
      [1002] = { line = 10, vehicle = 101 },
      [2001] = { line = 20, vehicle = 201 },
    },
    SIM_PERSON_AT_VEHICLE = { [1001] = {}, [1002] = {} },
    SIM_ENTITY_AT_TERMINAL = {
      [1003] = { line = 10, vehicle = -1 },
      [2002] = { line = 20, vehicle = -1 },
      [2003] = { line = 20, vehicle = -1 },
    },
    SIM_PERSON_AT_TERMINAL = { [1003] = {} },
    SIM_CARGO_AT_TERMINAL = { [2002] = {}, [2003] = {} },
  }
  game = {
    interface = {
      getEntity = function(id) return { id = id, type = "LINE", name = tostring(id) } end,
      getLines = function() return { 10, 20 } end,
      getVehicles = function() return {} end,
    },
  }
  api = {
    type = { ComponentType = componentTypes },
    engine = {
      getComponent = function(id, kind) return components[kind] and components[kind][id] or nil end,
      forEachEntityWithComponent = function(callback, kind)
        for id in pairs(components[kind] or {}) do callback(id) end
      end,
      system = {
        lineSystem = { getLines = function() return { 10, 20 } end },
        transportVehicleSystem = { getLineVehicles = function() return {} end },
      },
    },
  }
  local snapshot = world.mobilitySnapshot(canonical.newState())
  api, game = previousApi, previousGame
  equal(snapshot.schemaVersion, 5)
  equal(snapshot.totalPersons, 4)
  equal(snapshot.totals.directCargoEntities, 3)
  equal(snapshot.totals.passengersOnVehicle, 2)
  equal(snapshot.totals.passengersWaiting, 1)
  equal(snapshot.totals.cargoOnVehicle, 1)
  equal(snapshot.totals.cargoWaiting, 2)
  equal(snapshot.totals.passengerLineUses, 3)
  equal(snapshot.totals.cargoLineUses, 3)
  truthy(snapshot.availability.directEntitiesAtVehicle)
  truthy(snapshot.availability.directEntitiesAtTerminal)
  truthy(not json.encode(snapshot):match("1001"), "mobility payload leaked a person entity ID")
  truthy(not json.encode(snapshot):match("2001"), "mobility payload leaked a cargo entity ID")
end)

test("vehicle lifecycle normalizes barrier stop actuation and separates route phase", function()
  local previousApi, previousGame = api, game
  local stopIndex = 1
  local nativeUserStopped = false
  local nativeState = 1
  game = {
    interface = {
      getEntity = function(id)
        if id == 10 then return { id = id, type = "LINE", name = "Main" } end
        return { id = id, type = "TRANSPORT_VEHICLE", name = "Train" }
      end,
      getLines = function() return { 10 } end,
      getVehicles = function() return { 101 } end,
    },
  }
  api = {
    type = { ComponentType = {
      NAME = "NAME", LINE = "LINE", TRANSPORT_VEHICLE = "TRANSPORT_VEHICLE",
    } },
    res = { modelRep = {
      getName = function(modelId)
        return modelId == 17 and "vehicle/train/db_v100_v2.mdl"
          or "vehicle/waggon/open_1910.mdl"
      end,
    } },
    engine = {
      entityExists = function(id) return id == 10 or id == 101 end,
      getComponent = function(id, kind)
        if kind == "NAME" then return { name = id == 10 and "Main" or "Train" } end
        if kind == "TRANSPORT_VEHICLE" and id == 101 then
          return {
            line = 10,
            state = nativeState,
            stopIndex = stopIndex,
            userStopped = nativeUserStopped,
            sellOnArrival = false,
            transportVehicleConfig = { vehicles = {
              { part = { modelId = 17 } },
              { part = { modelId = 18 } },
            } },
          }
        end
      end,
      system = {
        lineSystem = { getLines = function() return { 10 } end },
        transportVehicleSystem = { getLineVehicles = function() return { 101 } end },
      },
    },
  }
  local registry = canonical.newState()
  local priming = world.mobilitySnapshot(registry)
  local vehicleCid = priming.vehiclePhases[1].vehicleCid
  local lineCid = priming.vehiclePhases[1].lineCid
  local worldState = { vehicleSync = { vehicles = { [vehicleCid] = {
    vehicleCid = vehicleCid, lineCid = lineCid, lastAuthorizedRound = 2,
    stopIndex = 0,
  } } } }
  local runtimeState = { [vehicleCid] = {
    lineCid = lineCid, round = 2, phase = "enroute", stopIndex = 0,
    departedSinceRelease = true, releaseReportPending = false,
  } }
  local first = world.mobilitySnapshot(registry, worldState, runtimeState)
  stopIndex = 2
  nativeUserStopped = true
  nativeState = 2
  worldState.vehicleSync.vehicles[vehicleCid].stopIndex = 2
  runtimeState[vehicleCid] = {
    lineCid = lineCid, round = 2, phase = "release-armed", stopIndex = 2,
    departedSinceRelease = false, releaseReportPending = false,
  }
  local second = world.mobilitySnapshot(registry, worldState, runtimeState)
  runtimeState[vehicleCid].phase = "holding"
  local unsafe = world.mobilitySnapshot(registry, worldState, runtimeState)
  api, game = previousApi, previousGame
  equal(first.schemaVersion, 5)
  equal(#first.vehicleLifecycle, 1)
  equal(first.vehicleLifecycle[1].vehicleParts, 2)
  equal(first.vehicleLifecycle[1].consistModels[2], "vehicle/waggon/open_1910.mdl")
  equal(first.vehicleLifecycle[1].requestedStopped, false)
  equal(first.vehicleLifecycleDigest, second.vehicleLifecycleDigest)
  equal(first.vehicleStopDiagnostics[1].nativeUserStopped, false)
  equal(second.vehicleStopDiagnostics[1].nativeUserStopped, true)
  truthy(first.vehicleRestoreSafe)
  truthy(second.vehicleRestoreSafe)
  truthy(not unsafe.vehicleRestoreSafe)
  truthy(unsafe.vehicleRestoreUnsafeVehicles[1].reason:match("transient"))
  truthy(first.vehiclePhaseDigest ~= second.vehiclePhaseDigest,
    "moving to another route stop did not change the vehicle phase digest")
  truthy(not json.encode(first):match('"vehicleCid":101'),
    "vehicle mobility payload leaked a machine-local vehicle id")
end)

test("pre-existing world manifest ignores local ids and fails closed on ambiguity", function()
  local previousApi, previousGame = api, game
  local function sample(ids)
    local names = {
      [ids[1]] = "Central", [ids[2]] = "Harbour", [ids[3]] = "Duplicate",
      [ids[4]] = "Duplicate",
    }
    local positions = {
      [ids[1]] = { 100, 200 }, [ids[2]] = { 300, 400 },
      [ids[3]] = { 500, 600 }, [ids[4]] = { 500, 600 },
    }
    game = { interface = {
      getEntity = function(id)
        return { id = id, type = "STATION_GROUP", name = names[id], position = positions[id] }
      end,
      getTowns = function() return {} end,
      getLines = function() return {} end,
      getVehicles = function() return {} end,
      getDepots = function() return {} end,
    } }
    api = {
      type = { ComponentType = {
        NAME = "NAME", STATION_GROUP = "STATION_GROUP", STATION = "STATION",
        SIM_BUILDING = "SIM_BUILDING",
      } },
      engine = {
        getComponent = function(id, kind)
          if kind == "NAME" then return { name = names[id] } end
          if kind == "STATION_GROUP" and names[id] then return {} end
          return nil
        end,
        forEachEntityWithComponent = function(callback, kind)
          if kind == "STATION_GROUP" then for _, id in ipairs(ids) do callback(id) end end
        end,
        system = { lineSystem = { getLines = function() return {} end } },
      },
    }
    local registry = canonical.newState()
    local manifest = world.canonicalManifest(registry)
    return manifest, registry
  end
  local first, firstRegistry = sample({ 10, 20, 30, 40 })
  local second, secondRegistry = sample({ 110, 220, 330, 440 })
  api, game = previousApi, previousGame
  equal(first.digest, second.digest)
  equal(first.ambiguousCount, 1)
  equal(first.uniqueBound, 2)
  equal(second.uniqueBound, 2)
  equal(#canonical.snapshot(firstRegistry), 2)
  equal(#canonical.snapshot(secondRegistry), 2)
  for _, binding in ipairs(canonical.snapshot(firstRegistry)) do
    truthy(binding.metadata.manifestBound == true)
  end
end)

test("pre-existing world manifest never broad-projects loaded station entities", function()
  local previousApi, previousGame = api, game
  local broadProjectionCalls = 0
  game = { interface = {
    getEntity = function()
      broadProjectionCalls = broadProjectionCalls + 1
      error("loaded STATION broad projection is native-unsafe")
    end,
    getTowns = function() return {} end,
    getLines = function() return {} end,
    getVehicles = function() return {} end,
    getDepots = function() return {} end,
  } }
  api = {
    type = { ComponentType = {
      NAME = "NAME", STATION_GROUP = "STATION_GROUP", STATION = "STATION",
      SIM_BUILDING = "SIM_BUILDING", PLAYER_OWNED = "PLAYER_OWNED",
    } },
    engine = {
      getComponent = function(id, kind)
        if kind == "STATION" and (id == 41 or id == 42) then return {} end
        if kind == "PLAYER_OWNED" and (id == 41 or id == 42) then
          return { player = 7 }
        end
        return nil
      end,
      forEachEntityWithComponent = function(callback, kind)
        if kind == "STATION" or kind == "PLAYER_OWNED" then
          callback(41); callback(42)
        end
      end,
      entityExists = function(id) return id == 41 or id == 42 end,
      system = { lineSystem = { getLines = function() return {} end } },
    },
  }
  local registry = canonical.newState()
  local manifest = world.canonicalManifest(registry)
  equal(broadProjectionCalls, 0)
  equal(manifest.total, 2)
  equal(manifest.ambiguousCount, 1)
  equal(#canonical.snapshot(registry), 0)
  local structural = world.structuralSnapshot(registry, { logicalOwners = {} }, {})
  equal(broadProjectionCalls, 0)
  equal(#structural.objects, 2)
  api, game = previousApi, previousGame
end)

test("world manifest binds private starting topology across divergent local ids", function()
  local previousApi, previousGame = api, game
  local function sample(node0, node1, edgeId)
    local entities = {
      [node0] = { type = "BASE_NODE", position = { 10, 20 } },
      [node1] = { type = "BASE_NODE", position = { 30, 40 } },
      [edgeId] = { type = "BASE_EDGE" },
    }
    local components = {
      BASE_NODE = { [node0] = { position = { x = 10, y = 20 } },
        [node1] = { position = { x = 30, y = 40 } } },
      BASE_EDGE = { [edgeId] = { node0 = node0, node1 = node1 } },
    }
    game = { interface = {
      getEntity = function(id) return entities[id] end,
      getTowns = function() return {} end,
      getLines = function() return {} end,
      getVehicles = function() return {} end,
      getDepots = function() return {} end,
    } }
    api = {
      type = { ComponentType = {
        BASE_NODE = "BASE_NODE", BASE_EDGE = "BASE_EDGE",
        STATION_GROUP = "STATION_GROUP", STATION = "STATION",
        SIM_BUILDING = "SIM_BUILDING",
      } },
      engine = {
        getComponent = function(id, kind)
          return components[kind] and components[kind][id] or nil
        end,
        forEachEntityWithComponent = function() end,
        system = { lineSystem = { getLines = function() return {} end } },
      },
    }
    local registry = canonical.newState()
    local manifest = world.canonicalManifest(registry, { logicalOwners = {
      [tostring(node0)] = "company:1",
      [tostring(node1)] = "company:1",
      [tostring(edgeId)] = "company:1",
    } })
    return manifest, registry
  end
  local first, firstRegistry = sample(10, 11, 12)
  local second, secondRegistry = sample(110, 111, 112)
  api, game = previousApi, previousGame
  equal(first.digest, second.digest)
  equal(first.uniqueBound, 3)
  equal(second.uniqueBound, 3)
  for _, binding in ipairs(canonical.snapshot(firstRegistry)) do
    truthy(binding.metadata.manifestBound == true)
  end
  for _, binding in ipairs(canonical.snapshot(secondRegistry)) do
    truthy(binding.metadata.manifestBound == true)
  end
end)

test("world manifest defers decorative assets and constructions until selected", function()
  local previousApi, previousGame = api, game
  local entities = {
    [10] = { type = "STATION_GROUP", name = "Central", position = { 10, 20 } },
    [20] = { type = "ASSET_GROUP", name = "Bench", position = { 30, 40 } },
    [30] = { type = "CONSTRUCTION", name = "Town house", position = { 50, 60 } },
  }
  local components = {
    STATION_GROUP = { [10] = {} },
    ASSET_GROUP = { [20] = {} },
    CONSTRUCTION = { [30] = { fileName = "building/house.con", params = {} } },
    NAME = {
      [10] = { name = "Central" }, [20] = { name = "Bench" },
      [30] = { name = "Town house" },
    },
  }
  game = { interface = {
    getEntity = function(id) return entities[id] end,
    getTowns = function() return {} end,
    getLines = function() return {} end,
    getVehicles = function() return {} end,
    getDepots = function() return {} end,
  } }
  api = {
    type = { ComponentType = {
      NAME = "NAME", STATION_GROUP = "STATION_GROUP", STATION = "STATION",
      SIM_BUILDING = "SIM_BUILDING", ASSET_GROUP = "ASSET_GROUP",
      CONSTRUCTION = "CONSTRUCTION", PLAYER_OWNED = "PLAYER_OWNED",
    } },
    engine = {
      getComponent = function(id, kind)
        return components[kind] and components[kind][id] or nil
      end,
      forEachEntityWithComponent = function(callback, kind)
        for id in pairs(components[kind] or {}) do callback(id) end
      end,
      system = { lineSystem = { getLines = function() return {} end } },
    },
  }
  local registry = canonical.newState()
  local manifest = world.canonicalManifest(registry)
  equal(manifest.uniqueBound, 1)
  equal(manifest.deferredUnique, 2)
  equal(#canonical.snapshot(registry), 1)
  local assetCid, assetError = world.bindExisting(registry, 20, "asset")
  truthy(assetCid, assetError)
  equal(#canonical.snapshot(registry), 2)
  api, game = previousApi, previousGame
end)

test("pre-existing road nodes resolve lazily by geometry across divergent local ids", function()
  local previousApi, previousGame = api, game
  local function install(nodes)
    game = { interface = {
      getEntity = function(id) return { id = id, type = "BASE_NODE" } end,
      getTowns = function() return {} end,
      getLines = function() return {} end,
      getVehicles = function() return {} end,
      getDepots = function() return {} end,
    } }
    api = {
      type = { ComponentType = {
        NAME = "NAME", BASE_NODE = "BASE_NODE", BASE_EDGE = "BASE_EDGE",
      } },
      engine = {
        getComponent = function(id, kind)
          return kind == "BASE_NODE" and nodes[id] or nil
        end,
        forEachEntityWithComponent = function(callback, kind)
          if kind == "BASE_NODE" then for id in pairs(nodes) do callback(id) end end
        end,
        system = { lineSystem = { getLines = function() return {} end } },
      },
    }
  end

  install({ [10] = { position = { x = 123.4, y = -55.6, z = 7.8 } } })
  local origin = canonical.newState()
  local cid = assert(world.bindExisting(origin, 10, "node"))
  truthy(cid:match("^node:pre:"), "origin node did not receive a pre-existing identity")

  install({ [9910] = { position = { x = 123.4, y = -55.6, z = 7.8 } } })
  local remote = canonical.newState()
  equal(world.findPreExistingLocal(remote, cid, "node"), 9910)
  equal(world.resolvePreExisting(remote, cid, "node", { owner = "company:1" }), 9910)
  equal(canonical.resolveLocal(remote, cid), 9910)
  equal(remote.byCanonical[cid].metadata.owner, "company:1")

  install({
    [9910] = { position = { x = 123.4, y = -55.6, z = 7.8 } },
    [9911] = { position = { x = 123.4, y = -55.6, z = 7.8 } },
  })
  local ambiguous, ambiguity = world.findPreExistingLocal(canonical.newState(), cid, "node")
  api, game = previousApi, previousGame
  truthy(ambiguous == nil and tostring(ambiguity):find("ambiguous") ~= nil,
    "stacked public nodes were not rejected as an ambiguous locator")
end)

test("co-located crossing nodes use portable incident-edge anchors", function()
  local previousApi, previousGame = api, game
  local function install(nodes, edges)
    game = { interface = {
      getEntity = function(id)
        if nodes[id] then return { id = id, type = "BASE_NODE" } end
        if edges[id] then return { id = id, type = "BASE_EDGE" } end
        return nil
      end,
      getTowns = function() return {} end,
      getLines = function() return {} end,
      getVehicles = function() return {} end,
      getDepots = function() return {} end,
    } }
    api = {
      type = { ComponentType = {
        NAME = "NAME", BASE_NODE = "BASE_NODE", BASE_EDGE = "BASE_EDGE",
      } },
      engine = {
        getComponent = function(id, kind)
          if kind == "BASE_NODE" then return nodes[id] end
          if kind == "BASE_EDGE" then return edges[id] end
          return nil
        end,
        forEachEntityWithComponent = function(callback, kind)
          local values = kind == "BASE_NODE" and nodes
            or kind == "BASE_EDGE" and edges or {}
          for id in pairs(values) do callback(id) end
        end,
        system = { lineSystem = { getLines = function() return {} end } },
      },
    }
  end

  local originNodes = {
    [10] = { position = { x = 100, y = 100, z = 0 } },
    [11] = { position = { x = 100, y = 100, z = 0 } },
    [12] = { position = { x = 180, y = 100, z = 0 } },
    [13] = { position = { x = 100, y = 180, z = 0 } },
  }
  local originEdges = {
    [20] = { node0 = 10, node1 = 12 },
    [21] = { node0 = 11, node1 = 13 },
  }
  install(originNodes, originEdges)
  local origin = canonical.newState()
  local horizontalCid, horizontalError = world.identifyExisting(origin, 10, "node")
  local verticalCid, verticalError = world.identifyExisting(origin, 11, "node")
  truthy(horizontalCid, horizontalError)
  truthy(verticalCid, verticalError)
  truthy(horizontalCid:match(
    "^node:pre:[0-9a-f]+:anchor:edge:pre:[0-9a-f]+$"),
    "horizontal crossing node has no portable edge anchor")
  truthy(verticalCid:match(
    "^node:pre:[0-9a-f]+:anchor:edge:pre:[0-9a-f]+$"),
    "vertical crossing node has no portable edge anchor")
  truthy(horizontalCid ~= verticalCid,
    "co-located crossing nodes collapsed to one canonical identity")
  equal(#canonical.snapshot(origin), 0,
    "pre-consensus anchored lookup mutated the origin registry")

  local proposal = linearProposal(-1, -2, -3, "track", 1, false)
  table.remove(proposal.streetProposal.nodesToAdd, 1)
  proposal.streetProposal.edgesToAdd[1].comp.node0 = 10
  proposal.streetProposal.edgesToRemove = { 21 }
  proposal.streetProposal.nodesToRemove = { 11 }
  local transaction, transactionError = proposalCodec.normalise(
    proposal, "company:1", {
      resolveCanonical = function(kind, localId)
        return world.identifyExisting(origin, localId, kind)
      end,
    })
  truthy(transaction, transactionError)
  equal(transaction.edges[1].node0.cid, horizontalCid)
  equal(transaction.remove.nodes[1], verticalCid)
  equal(transaction.remove.edges[1], assert(world.identifyExisting(origin, 21, "edge")))
  truthy(not json.encode(transaction):match('"localId"'),
    "anchored crossing proposal leaked a machine-local node id")

  local remoteNodes = {
    [1010] = { position = { x = 100, y = 100, z = 0 } },
    [1011] = { position = { x = 100, y = 100, z = 0 } },
    [1012] = { position = { x = 180, y = 100, z = 0 } },
    [1013] = { position = { x = 100, y = 180, z = 0 } },
  }
  local remoteEdges = {
    [2020] = { node0 = 1010, node1 = 1012 },
    [2021] = { node0 = 1011, node1 = 1013 },
  }
  install(remoteNodes, remoteEdges)
  local remote = canonical.newState()
  equal(world.findPreExistingLocal(remote, horizontalCid, "node"), 1010)
  equal(world.findPreExistingLocal(remote, verticalCid, "node"), 1011)
  equal(world.resolvePreExisting(remote, horizontalCid, "node", {
    owner = "company:1",
  }), 1010)
  equal(world.resolvePreExisting(remote, verticalCid, "node", {
    owner = "company:1",
  }), 1011)
  equal(remote.byCanonical[horizontalCid].metadata.owner, "company:1")
  truthy(remote.byCanonical[horizontalCid].metadata.anchorEdgeCid:match("^edge:pre:"))

  install(originNodes, originEdges)
  local eventOrigin = canonical.newState()
  truthy(canonical.bind(eventOrigin, "edge:event:crossing:1", "edge", 20))
  local eventNodeCid = assert(world.identifyExisting(eventOrigin, 10, "node"))
  truthy(eventNodeCid:find(":anchor:edge:event:crossing:1", 1, true) ~= nil,
    "event-created incident edge was not usable as a node anchor")
  install(remoteNodes, remoteEdges)
  local eventRemote = canonical.newState()
  truthy(canonical.bind(eventRemote, "edge:event:crossing:1", "edge", 2020))
  equal(world.findPreExistingLocal(eventRemote, eventNodeCid, "node"), 1010)

  local distantFingerprint = world.fingerprint(1013, "node")
  local forged = "node:pre:" .. distantFingerprint .. ":anchor:edge:event:crossing:1"
  local forgedLocal, forgedError = world.findPreExistingLocal(eventRemote, forged, "node")
  api, game = previousApi, previousGame
  truthy(forgedLocal == nil and tostring(forgedError):find("no endpoint") ~= nil,
    "an anchor edge admitted a node fingerprint absent from its endpoints")
end)

test("structural snapshots use exact construction attestations without native component reads", function()
  local previousApi, previousGame = api, game
  local componentReads = 0
  local types = {
    PLAYER_OWNED = "PLAYER_OWNED", CONSTRUCTION = "CONSTRUCTION",
    STATION = "STATION", STATION_GROUP = "STATION_GROUP",
    VEHICLE_DEPOT = "VEHICLE_DEPOT", ASSET_GROUP = "ASSET_GROUP",
    SIGNAL_LIST = "SIGNAL_LIST", BASE_NODE = "BASE_NODE",
    BASE_EDGE = "BASE_EDGE", SIM_BUILDING = "SIM_BUILDING",
  }
  api = {
    type = { ComponentType = types },
    engine = {
      entityExists = function(id) return id == 99 end,
      getComponent = function()
        componentReads = componentReads + 1
        error("fresh exact construction component must not be read")
      end,
      forEachEntityWithComponent = function(callback, componentType)
        if componentType == types.PLAYER_OWNED or componentType == types.CONSTRUCTION then
          callback(99)
        end
      end,
      system = { lineSystem = { getLines = function() return {} end } },
    },
  }
  game = { interface = {
    getTowns = function() return {} end,
    getLines = function() return {} end,
    getVehicles = function() return {} end,
    getDepots = function() return {} end,
    getEntity = function() error("fresh exact construction entity must not be read") end,
  } }
  local registry = canonical.newState()
  truthy(canonical.bind(registry, "construction:event:test:1", "construction", 99, {
    owner = "company:1", fingerprint = "proposal:construction:1",
    nativeReadUnsafe = true,
  }))
  local snapshot = world.structuralSnapshot(registry, {
    logicalOwners = { ["99"] = "company:1" },
    logicalOwnershipAuthoritative = true,
  }, { ["company:1"] = { playerId = 7 } })
  api, game = previousApi, previousGame
  equal(componentReads, 0,
    "structural snapshot re-entered an attested exact construction component")
  equal(#snapshot.objects, 1)
  equal(snapshot.objects[1].fingerprint, "proposal:construction:1")
  equal(snapshot.objects[1].owner, "company:1")
  equal(snapshot.constructionCount, 1)
end)

test("pre-consensus existing identity lookup never mutates the origin registry", function()
  local previousApi, previousGame = api, game
  local nodes = {
    [10] = { position = { x = 123.4, y = -55.6, z = 7.8 } },
    [20] = { position = { x = 700.1, y = 800.2, z = 9.3 } },
  }
  game = { interface = {
    getEntity = function(id) return nodes[id] and { id = id, type = "BASE_NODE" } or nil end,
    getTowns = function() return {} end,
    getLines = function() return {} end,
    getVehicles = function() return {} end,
    getDepots = function() return {} end,
  } }
  api = {
    type = { ComponentType = { NAME = "NAME", BASE_NODE = "BASE_NODE", BASE_EDGE = "BASE_EDGE" } },
    engine = {
      getComponent = function(id, kind) return kind == "BASE_NODE" and nodes[id] or nil end,
      forEachEntityWithComponent = function(callback, kind)
        if kind == "BASE_NODE" then for id in pairs(nodes) do callback(id) end end
      end,
      system = { lineSystem = { getLines = function() return {} end } },
    },
  }

  local registry = canonical.newState()
  local boundCid = assert(world.bindExisting(registry, 10, "node", {
    fingerprint = world.fingerprint(10, "node"), manifestBound = true,
  }))
  local beforeBound = hash.value(canonical.digestView(registry))
  equal(world.identifyExisting(registry, 10, "node"), boundCid)
  equal(hash.value(canonical.digestView(registry)), beforeBound)
  truthy(registry.byCanonical[boundCid].metadata.owner == nil,
    "read-only identity lookup enriched existing metadata on the origin")

  local beforeLazy = hash.value(canonical.digestView(registry))
  local lazyCid, lazyError = world.identifyExisting(registry, 20, "node")
  truthy(lazyCid and lazyCid:match("^node:pre:"), lazyError)
  equal(hash.value(canonical.digestView(registry)), beforeLazy)
  truthy(canonical.resolveLocal(registry, lazyCid) == nil,
    "read-only identity lookup bound a lazy node before consensus")
  equal(world.resolvePreExisting(registry, lazyCid, "node", {
    owner = "company:1", resolvedForProposal = "event:test",
  }), 20)
  equal(registry.byCanonical[lazyCid].metadata.owner, "company:1")

  nodes[21] = { position = { x = 700.1, y = 800.2, z = 9.3 } }
  local ambiguous, ambiguity = world.identifyExisting(canonical.newState(), 20, "node")
  api, game = previousApi, previousGame
  truthy(ambiguous == nil and tostring(ambiguity):find("ambiguous") ~= nil,
    "pre-consensus identity lookup admitted an ambiguous local node")
end)

local function marketState(demand)
  local state = economy.newState()
  economy.upsertMarket(state, {
    cid = "market:a-b", demand = demand or 1000,
    votCentsPerHour = 450, gcOutsideCents = 2500, thetaCents = 250,
  })
  return state
end

local function corridorService(state, key, companyCid, overrides)
  local service = {
    lineCid = "line:" .. key, marketCid = "market:a-b", companyCid = companyCid,
    headwaySeconds = 900, journeySeconds = 1800, fareCents = 1000,
    capacity = 1000, quality = 100, transfers = 0,
  }
  for field, value in pairs(overrides or {}) do service[field] = value end
  return economy.upsertService(state, service)
end

-- Shares are stocks that climb from zero, so competitive comparisons are made
-- at glided steady state rather than on the first epoch.
local function scenario(fareA, capacityA, capacityB)
  local state = marketState(1000)
  corridorService(state, "a", "company:1", { fareCents = fareA, capacity = capacityA or 1000 })
  corridorService(state, "b", "company:2", { capacity = capacityB or 1000 })
  local results
  for _ = 1, 60 do results = economy.evaluateAll(state) end
  return results
end

test("economy conserves demand and respects capacity", function()
  local result = scenario(1000, 200, 300).markets["market:a-b"]
  local allocated = result.outside
  for _, service in pairs(result.services) do
    truthy(service.allocated <= service.availableCapacity, "interval capacity exceeded")
    allocated = allocated + service.allocated
  end
  equal(allocated + result.queued, result.demand, "demand was not conserved")
  equal(result.services["line:a"].allocated, 17)
  equal(result.services["line:b"].allocated, 25)
  equal(result.services["line:a"].requested,
    result.services["line:a"].allocated + result.services["line:a"].capacityOverflow)
  truthy(result.queued > 0, "capacity-constrained demand did not enter the waiting class")
end)

test("lower fares improve allocation deterministically", function()
  local equalFare = scenario(1000).markets["market:a-b"].services["line:a"].allocated
  local lowerFare = scenario(500).markets["market:a-b"].services["line:a"].allocated
  truthy(lowerFare > equalFare, "lower fare should attract more modeled demand")
  equal(scenario(500).markets["market:a-b"].services["line:a"].allocated, lowerFare)
end)

test("generalized cost is legible cents and induces demand from the outside option", function()
  local state = marketState(1000)
  corridorService(state, "a", "company:1", {})
  local first = economy.evaluateAll(state).markets["market:a-b"]
  local factors = first.services["line:a"].factors
  equal(factors.gcCents, factors.fareCents + factors.timeCostCents + factors.waitCostCents
    + factors.transferCostCents + factors.crowdCostCents - factors.comfortCents,
    "generalized cost is not the sum of its cent factors")
  local slowOutside = first.outside

  local fast = marketState(1000)
  corridorService(fast, "a", "company:1", { journeySeconds = 900, headwaySeconds = 300 })
  local better = economy.evaluateAll(fast).markets["market:a-b"]
  truthy(better.outside < slowOutside,
    "improving the best service must shrink the outside option (induced demand)")
end)

test("share is a stock: entrants climb from zero and conservation is exact", function()
  local state = marketState(1000)
  corridorService(state, "a", "company:1", {})
  for _ = 1, 5 do economy.evaluateAll(state) end
  corridorService(state, "b", "company:2", { fareCents = 800 })
  equal(state.services["line:b"].sharePpm, 0, "a new entrant must start with zero share")

  local previous = 0
  local lastResult
  for epoch = 1, 60 do
    lastResult = economy.evaluateAll(state).markets["market:a-b"]
    local total = lastResult.outside
    for _, service in pairs(lastResult.services) do total = total + service.allocated end
    equal(total + lastResult.queued, lastResult.demand,
      "conservation broke at epoch " .. epoch)
    local share = lastResult.services["line:b"].sharePpm
    truthy(share >= previous, "entrant share must climb monotonically toward equilibrium")
    previous = share
  end
  local entrant = lastResult.services["line:b"]
  truthy(entrant.sharePpm >= entrant.equilibriumPpm * 9 / 10,
    "entrant did not reach 90% of equilibrium after 60 epochs")
end)

test("asymmetric glide punishes fare milking", function()
  local state = marketState(1000)
  corridorService(state, "a", "company:1", {})
  corridorService(state, "b", "company:2", {})
  for _ = 1, 30 do economy.evaluateAll(state) end
  local settled = state.services["line:b"].sharePpm

  economy.setFare(state, "line:b", 5000)
  local hikeResult = economy.evaluateAll(state)
  local afterHike = state.services["line:b"].sharePpm
  local hikeLoss = settled - afterHike
  truthy(hikeLoss > 0, "a fare hike must bleed share")
  equal(afterHike, hikeResult.markets["market:a-b"].services["line:b"].equilibriumPpm,
    "a deteriorating service must adopt its lower equilibrium immediately")

  economy.setFare(state, "line:b", 1000)
  economy.evaluateAll(state)
  local afterRevert = state.services["line:b"].sharePpm
  local revertGain = afterRevert - afterHike
  truthy(revertGain >= 0, "reverting the fare must start recovery")
  truthy(hikeLoss > revertGain * 2,
    "losing share must be materially faster than regaining it (milking defense)")
end)

test("extreme fares cannot harvest retained or cutoff demand", function()
  local state = marketState(1000)
  corridorService(state, "a", "company:1", { capacity = 600 })
  corridorService(state, "b", "company:2", { fareCents = 900, capacity = 600 })
  for _ = 1, 600 do economy.evaluateAll(state) end
  truthy(state.services["line:a"].sharePpm > 0, "audit service never established share")

  economy.setFare(state, "line:a", 100000000)
  local result = economy.evaluateAll(state).markets["market:a-b"].services["line:a"]
  equal(result.equilibriumPpm, 0, "8-theta cutoff retained a dominated service weight")
  equal(result.sharePpm, 0, "fare hike retained harvestable share for one epoch")
  equal(result.allocated, 0, "dominated max-fare service received rounding demand")
  equal(result.revenueCents, 0, "dominated max-fare service earned revenue")
end)

test("economy v2 migration arms the first-settlement fare guard", function()
  local state = marketState(1000)
  corridorService(state, "a", "company:1", {})
  state.version = 2
  state.params.alphaDownPm = 250
  local migrated = economy.migrate(state)
  equal(migrated.version, 10)
  equal(migrated.params.alphaDownPm, 500)
  equal(migrated.services["line:a"].lastFareCents, nil)
  -- The version-4 market step must be passenger-equivalent: same wait weight and
  -- transfer time the version-3 evaluator hardcoded.
  local market = migrated.markets["market:a-b"]
  equal(market.kind, "passenger")
  equal(market.waitWeightPm, 2000)
  equal(market.transferSeconds, 480)
  equal(migrated.services["line:a"].enabled, false,
    "a legacy passenger line remained revenue-eligible without an access proof")
  equal(migrated.services["line:a"].metadata.stationAccessSource,
    "legacy-unverified")
end)

test("local road and tram lines improve only their own connected corridor endpoints", function()
  local state = economy.newState()
  economy.upsertMarket(state, {
    cid = "market:corridor", kind = "passenger", demand = 1200,
    gcOutsideCents = 2500, thetaCents = 250,
    metadata = { marketScope = "corridor", townA = "town:a", townB = "town:b" },
  })
  economy.upsertMarket(state, {
    cid = "market:local:a", kind = "passenger", demand = 400,
    gcOutsideCents = 2500, thetaCents = 250,
    metadata = { marketScope = "local", townA = "town:a", townB = "town:a" },
  })
  local function service(lineCid, marketCid, companyCid, metadata)
    return economy.upsertService(state, {
      lineCid = lineCid, marketCid = marketCid, companyCid = companyCid,
      headwaySeconds = 600, journeySeconds = 1200, fareCents = 1000,
      capacity = 600, quality = 100, transfers = 0, metadata = metadata,
    })
  end
  service("line:rail:a", "market:corridor", "company:1", {
    carrier = "RAIL", marketScope = "corridor",
    endpointTownCids = { "town:a", "town:b" },
    stationGroupCids = { "station:a", "station:b" },
  })
  service("line:rail:b", "market:corridor", "company:2", {
    carrier = "RAIL", marketScope = "corridor",
    endpointTownCids = { "town:a", "town:b" },
    stationGroupCids = { "station:a", "station:b" },
  })
  local feeder = service("line:bus", "market:local:a", "company:1", {
    carrier = "ROAD", marketScope = "local",
    endpointTownCids = { "town:a", "town:a" },
    stationGroupCids = { "station:suburb", "station:a" },
  })
  service("line:rival-bus", "market:local:a", "company:3", {
    carrier = "TRAM", marketScope = "local",
    endpointTownCids = { "town:a", "town:a" },
    stationGroupCids = { "station:a", "station:remote" },
  })

  local index = economyFeederAccess.buildIndex(state)
  local access, endpoints = economyFeederAccess.cents(
    state.markets["market:corridor"], state.services["line:rail:a"], index)
  equal(access, 150)
  equal(endpoints, 1)
  equal(economyFeederAccess.cents(
    state.markets["market:corridor"], state.services["line:rail:b"], index), 0,
    "another company's feeder leaked across ownership")

  local result = economy.evaluateAll(state).markets["market:corridor"].services
  truthy(result["line:rail:a"].equilibriumPpm > result["line:rail:b"].equilibriumPpm,
    "the connected corridor received no competitive access benefit")
  equal(result["line:rail:a"].factors.baseComfortCents, 100)
  equal(result["line:rail:a"].factors.feederAccessCents, 150)
  equal(result["line:rail:a"].factors.comfortCents, 250)

  feeder.enabled = false
  equal(economyFeederAccess.cents(state.markets["market:corridor"],
    state.services["line:rail:a"], economyFeederAccess.buildIndex(state)), 0,
    "a disabled feeder retained its access benefit")
  feeder.enabled, feeder.capacity, feeder.headwaySeconds = true, 80, 1800
  equal(economyFeederAccess.cents(state.markets["market:corridor"],
    state.services["line:rail:a"], economyFeederAccess.buildIndex(state)), 50,
    "a low-frequency feeder received the full access benefit")
  feeder.capacity = 0
  equal(economyFeederAccess.cents(state.markets["market:corridor"],
    state.services["line:rail:a"], economyFeederAccess.buildIndex(state)), 0,
    "a zero-capacity feeder retained its access benefit")
end)

test("economy v7 replay does not acquire v8 feeder fields or arithmetic", function()
  local state = economy.newState()
  state.version = 7
  economy.upsertMarket(state, { cid = "market:legacy", demand = 100,
    metadata = { marketScope = "corridor", townA = "town:a", townB = "town:b" } })
  economy.upsertService(state, { lineCid = "line:legacy", marketCid = "market:legacy",
    companyCid = "company:1", headwaySeconds = 600, journeySeconds = 1200,
    fareCents = 1000, capacity = 100, quality = 100,
    metadata = { marketScope = "corridor", endpointTownCids = { "town:a", "town:b" },
      stationGroupCids = { "station:a", "station:b" } } })
  local factors = economy.evaluateAll(state).markets["market:legacy"]
    .services["line:legacy"].factors
  equal(factors.comfortCents, 100)
  equal(factors.baseComfortCents, nil)
  equal(factors.feederAccessCents, nil)
  equal(factors.feederAccessEndpoints, nil)
end)

test("cargo markets weight waiting and transfers as freight", function()
  local state = economy.newState()
  economy.upsertMarket(state, { cid = "market:pax", kind = "passenger", demand = 1000,
    votCentsPerHour = 450, gcOutsideCents = 2500, thetaCents = 250 })
  economy.upsertMarket(state, { cid = "market:cargo", kind = "cargo", demand = 1000,
    votCentsPerHour = 450, gcOutsideCents = 2500, thetaCents = 250 })
  for _, item in ipairs({ { "market:pax", "line:pax" }, { "market:cargo", "line:cargo" } }) do
    economy.upsertService(state, {
      lineCid = item[2], marketCid = item[1], companyCid = "company:1",
      headwaySeconds = 1600, journeySeconds = 3600, fareCents = 1000,
      capacity = 800, quality = 100, transfers = 1,
    })
  end
  local results = economy.evaluateAll(state).markets
  local pax = results["market:pax"].services["line:pax"].factors
  local cargo = results["market:cargo"].services["line:cargo"].factors
  equal(cargo.waitCostCents * 2, pax.waitCostCents, "cargo must weight waiting at half the passenger rate")
  equal(pax.transferCostCents, 60)
  equal(cargo.transferCostCents, 225, "cargo transshipment must cost 1800 seconds per transfer")
  equal(results["market:cargo"].kind, "cargo")
  equal(results["market:pax"].kind, "passenger")
end)

test("cargo kind defaults value time low and compete with trucking", function()
  local state = economy.newState()
  local market = economy.upsertMarket(state, { cid = "market:freight", kind = "cargo", demand = 500 })
  equal(market.votCentsPerHour, 60)
  equal(market.gcOutsideCents, 1800)
  equal(market.thetaCents, 200)
  equal(market.waitWeightPm, 1000)
  equal(market.transferSeconds, 1800)
  local unknown = economy.upsertMarket(state, { cid = "market:odd", kind = "hyperloop", demand = 10 })
  equal(unknown.kind, "passenger", "unknown kinds must fall back to passenger")
end)

test("gravity demand scales with town capacities over distance and clamps", function()
  local near = world.gravityDemand(300, 300, 2000)
  local far = world.gravityDemand(300, 300, 20000)
  truthy(near > far, "closer towns must generate more corridor demand")
  equal(world.gravityDemand(10, 10, 1000000), world.SERVICE_FACTS.minDemand)
  equal(world.gravityDemand(1000000, 1000000, 1000), world.SERVICE_FACTS.maxDemand)
end)

test("station-group town reading prefers direct station queries", function()
  local mapRead = false
  local fakeApi = {
    type = { ComponentType = { STATION = "STATION" } },
    engine = { system = {
      stationSystem = {
        forEach = function(visitor) visitor(41); visitor(42) end,
        getTown = function(stationId) return stationId == 41 and 701 or 702 end,
        getStation2TownMap = function() mapRead = true; return {} end,
      },
      stationGroupSystem = {
        getStationGroup = function(stationId) return stationId == 41 and 901 or 902 end,
      },
    } },
  }
  local reader = stationReadingModule.new({
    getApi = function() return fakeApi end,
    entityNumber = tonumber,
  })
  local townId, source = reader.stationGroupTown(902)
  equal(townId, 702)
  equal(source, "stationSystem.forEach/getTown")
  equal(mapRead, false, "direct station lookup unexpectedly fell through to the map")
end)

test("station-group town reading keeps the station map as a fallback", function()
  local fakeApi = { engine = { system = {
    stationSystem = { getStation2TownMap = function() return { [51] = 801 } end },
    stationGroupSystem = { getStationGroup = function() return 903 end },
  } } }
  local reader = stationReadingModule.new({
    getApi = function() return fakeApi end,
    entityNumber = tonumber,
  })
  local townId, source = reader.stationGroupTown(903)
  equal(townId, 801)
  equal(source, "station-to-town map")
  local missing, diagnostic = reader.stationGroupTown(904)
  equal(missing, nil)
  truthy(diagnostic:find("examined=1", 1, true), "failure omitted station enumeration evidence")
  truthy(diagnostic:find("matched=0", 1, true), "failure omitted group-match evidence")
end)

test("station access counts only town buildings on native reachable street edges", function()
  local components = {
    STATION_GROUP = {
      [901] = { stations = { 41, 42 } },
      [902] = { stations = { 43 } },
    },
    TOWN_BUILDING = {
      [501] = { town = 700, parcels = { 601 } },
      [502] = { town = 700, parcels = { 602, 603 } },
      [503] = { town = 700, parcels = { 604 } },
      [504] = { town = 701, parcels = { 605 } },
    },
    PARCEL = {
      [601] = { streetSegment = { entity = 1001, index = 0 } },
      [602] = { streetSegment = { entity = 1002, index = 0 } },
      [603] = { streetSegment = { entity = 1001, index = 1 } },
      [604] = { streetSegment = { entity = 1999, index = 0 } },
      [605] = { streetSegment = { entity = 1001, index = 0 } },
    },
  }
  local fakeApi = {
    type = { ComponentType = {
      STATION_GROUP = "STATION_GROUP", TOWN_BUILDING = "TOWN_BUILDING",
      PARCEL = "PARCEL",
    } },
    engine = {
      getComponent = function(id, kind)
        return components[kind] and components[kind][id] or nil
      end,
      forEachEntityWithComponent = function(visitor, kind)
        for id in pairs(components[kind] or {}) do visitor(id) end
      end,
      system = { catchmentAreaSystem = { getStation2edgesMap = function()
        return {
          [41] = { { { entity = 1001, index = 0 }, 5 } },
          -- Exercise the zero-based pair spelling observed in engine userdata.
          [42] = { { [0] = { entity = 1002, index = 1 }, [1] = 9 } },
        }
      end } },
    },
  }
  local reader = stationAccessModule.new({
    getApi = function() return fakeApi end,
    entityNumber = function(value)
      if type(value) == "number" then return value end
      return type(value) == "table" and tonumber(value.entity or value.id) or nil
    end,
    sortedNumbers = function(values)
      local result = {}
      for _, value in pairs(type(values) == "table" and values or {}) do
        result[#result + 1] = tonumber(value)
      end
      table.sort(result)
      return result
    end,
  })
  local access = reader.stationGroupPassengerAccess(901, 700)
  truthy(access.ready)
  equal(access.stationCount, 2)
  equal(access.catchmentEdgeCount, 2)
  equal(access.townBuildingCount, 3)
  equal(access.reachableBuildings, 2,
    "a multi-parcel building was counted more than once or another town leaked in")
  local isolated = reader.stationGroupPassengerAccess(902, 700)
  truthy(isolated.ready, "a valid isolated station is a zero-access fact, not a read failure")
  equal(isolated.catchmentEdgeCount, 0)
  equal(isolated.reachableBuildings, 0)
end)

test("station access fails closed when the native catchment API is unavailable", function()
  local reader = stationAccessModule.new({
    getApi = function() return { engine = { system = {} } } end,
    entityNumber = tonumber,
    sortedNumbers = function() return {} end,
  })
  local access = reader.stationGroupPassengerAccess(901, 700)
  equal(access.ready, false)
  equal(access.reachableBuildings, 0)
  equal(access.errorCode, "catchment-api-unavailable")
end)

test("line transport-mode reading distinguishes passenger, cargo, and indexed mixed groups", function()
  local components = {
    LINE = {
      [100] = { stops = {
        { stationGroup = 901, station = 0 }, { stationGroup = 902, station = 0 },
      } },
      [101] = { stops = {
        { stationGroup = 903, station = 1 }, { stationGroup = 904, station = 0 },
      } },
      [102] = { stops = {
        { stationGroup = 903 }, { stationGroup = 904, station = 0 },
      } },
      [103] = { stops = {
        { stationGroup = 905, station = 0 }, { stationGroup = 904, station = 0 },
      } },
    },
    STATION_GROUP = {
      [901] = { stations = { 41 } }, [902] = { stations = { 42 } },
      [903] = { stations = { 43, 44 } }, [904] = { stations = { 45 } },
      [905] = { stations = { [0] = 46, [1] = 47 } },
    },
    STATION = {
      [41] = { cargo = false }, [42] = { cargo = false },
      [43] = { cargo = false }, [44] = { cargo = true }, [45] = { cargo = true },
      [46] = { cargo = true }, [47] = { cargo = false },
    },
  }
  local fakeApi = {
    type = { ComponentType = {
      LINE = "LINE", STATION_GROUP = "STATION_GROUP", STATION = "STATION",
    } },
    engine = {
      getComponent = function(id, kind)
        return components[kind] and components[kind][id] or nil
      end,
      system = {},
    },
  }
  local lineReading = require("tpf2_mp/world_line_reading").new({
    getApi = function() return fakeApi end, entityNumber = tonumber,
  })
  local passenger, passengerDetail = lineReading.lineServiceKind(100)
  truthy(passenger == "passenger", "passenger line classification failed: " .. tostring(passengerDetail))
  local groupPassenger, groupPassengerDetail = lineReading.stationGroupKind(901, 0)
  truthy(groupPassenger == "passenger",
    "direct passenger station-group classification failed: " .. tostring(groupPassengerDetail))
  equal(lineReading.stationGroupKind(903, 1), "cargo",
    "direct zero-based station-group classification selected the wrong platform")
  equal(lineReading.stationGroupKind(905, 0), "cargo",
    "direct native-zero-based station-group classification selected the wrong platform")
  equal(lineReading.lineServiceKind(101), "cargo",
    "zero-based stop.station did not select the cargo platform in a mixed group")
  equal(lineReading.lineServiceKind(103), "cargo",
    "native zero-based station containers selected the adjacent platform")
  local unreadable, detail = lineReading.lineServiceKind(102)
  equal(unreadable, nil)
  truthy(detail:find("mixed", 1, true), "ambiguous mixed group did not fail closed")
end)

test("validation construction emits stock passenger and cargo station templates", function()
  local passenger = assert(validationConstruction.spec("station", 2000, false))
  local cargo = assert(validationConstruction.spec("cargo_station", 2000, false))
  local airfield = assert(validationConstruction.spec("airfield", 1850, false))
  local cargoAirfield = assert(validationConstruction.spec("cargo_airfield", 1850, false))
  local airport = assert(validationConstruction.spec("airport", 1850, false))
  local cargoAirport = assert(validationConstruction.spec("cargo_airport", 1850, false))
  local passengerHarbor = assert(validationConstruction.spec("passenger_harbor", 1850, false))
  local cargoHarbor = assert(validationConstruction.spec("cargo_harbor", 1850, false))
  local shipyard = assert(validationConstruction.spec("shipyard", 1850, false))
  equal(passenger.fileName, "station/rail/modular_station/modular_station.con")
  equal(cargo.fileName, passenger.fileName)
  equal(passenger.params.modules[7400000].metadata.passenger_platform, true)
  equal(passenger.params.modules[8401000].metadata.track, true)
  equal(cargo.params.modules[3400020].metadata.era, 5)
  equal(cargo.params.modules[3400020].metadata.moreCapacity.cargo, 20)
  equal(cargo.params.modules[6400000].metadata.cargo_platform, true)
  equal(cargo.params.modules[8402000].metadata.track, true)
  equal(cargo.params.modules[7400000], nil)
  equal(airfield.fileName, "station/air/airfield.con")
  equal(airfield.params.templateIndex, 0)
  equal(airfield.params.year, 1920)
  equal(airfield.params.seed, 0)
  equal(airfield.params.modules[10070002].metadata.moreCapacity.passenger, 20)
  equal(airfield.params.modules[10002004].name,
    "station/air/airfield_hangar.module")
  equal(cargoAirfield.fileName, airfield.fileName)
  equal(cargoAirfield.params.templateIndex, 1)
  equal(airport.fileName, "station/air/airport.con")
  equal(airport.params.templateIndex, 0)
  equal(airport.params.dir, 0)
  equal(airport.params.year, 1950)
  equal(airport.params.seed, 0)
  equal(airport.params.modules[70006].metadata.moreCapacity.passenger, 100)
  equal(airport.params.modules[2010].name, "station/air/airport_hangar.module")
  equal(cargoAirport.params.modules[80006].metadata.cargo, true)
  equal(cargoAirport.fileName, airport.fileName)
  equal(cargoAirport.params.templateIndex, 1)
  equal(passengerHarbor.fileName, "station/water/harbor_modular.con")
  equal(passengerHarbor.params.templateIndex, 0)
  equal(passengerHarbor.params.size, 0)
  equal(passengerHarbor.params.terminals, 0)
  equal(passengerHarbor.params.modules[100009604].metadata.passenger, true)
  equal(passengerHarbor.params.modules[100009536].metadata.pier, true)
  equal(cargoHarbor.fileName, passengerHarbor.fileName)
  equal(cargoHarbor.params.templateIndex, 1)
  equal(cargoHarbor.params.modules[100009604].metadata.cargo, true)
  equal(cargoHarbor.params.modules[100010028].metadata.moreCapacity.cargo, 200)
  equal(shipyard.fileName, "depot/shipyard_era_a.con")
end)

test("freight service binding fails closed without a named cargo consist", function()
  local binding = corridorBindingModule.new({
    bindExisting = function() return "line:event:cargo:1" end,
    lineStopGroups = function() return { 901, 902 } end,
    lineServiceKind = function() return "cargo", "indexed station" end,
    stationGroupTown = function() error("cargo line reached passenger town binding") end,
    stationGroupPassengerAccess = function()
      error("cargo line reached passenger access binding")
    end,
    townCapacity = function() return 100 end,
    townBuildingCount = function() return 100 end,
    lineVehicleCount = function() return 0 end,
    lineVehicleIds = function() return {} end,
    nameOf = tostring,
    safeEntity = function() return nil end,
    positionOfEntity = function() return { 0, 0 } end,
    developmentPositionsOfTown = function() return {} end,
    resolveLocal = function() return nil end,
    resolveCanonical = function() return nil end,
  })
  local state = economy.newState()
  local ok, message = binding.makeLineService({}, economy, state, 77, "company:1")
  equal(ok, false)
  truthy(message:find("cargo", 1, true), "freight rejection was not actionable")
  equal(next(state.markets), nil, "freight line created a passenger market before rejection")
  equal(next(state.services), nil, "freight line created a passenger service before rejection")
end)

test("freight service binding authors a nearest compatible industry contract", function()
  local economyState = economy.newState()
  local freightState = {
    ready = true,
    industries = {
      ["industry:source"] = {
        recipe = { capacity = 100, inputs = { {} },
          outputs = { { cargoType = "GRAIN", amount = 2 } } },
        inputStock = {}, outputStock = { GRAIN = 0 },
      },
      ["industry:sink"] = {
        recipe = { capacity = 75,
          inputs = { { { stockIndex = 0, cargoType = "GRAIN", amount = 2 } } },
          outputs = {} },
        inputStock = { { index = 0, cargoType = "GRAIN", amount = 0 } },
        outputStock = {},
      },
      ["industry:far"] = {
        recipe = { capacity = 500, inputs = { {} },
          outputs = { { cargoType = "GRAIN", amount = 1 } } },
        inputStock = {}, outputStock = { GRAIN = 0 },
      },
    },
  }
  local localIds = {
    ["industry:source"] = 1001, ["industry:sink"] = 1002,
    ["industry:far"] = 1003,
  }
  local positions = {
    [901] = { 0, 0 }, [902] = { 5000, 0 },
    [1001] = { 100, 0 }, [1002] = { 4900, 0 }, [1003] = { 2000, 0 },
  }
  local ok, result = freightServiceBinding.register({
    registry = {}, economyModule = economy, economyState = economyState,
    worldState = { freightIndustry = freightState },
    lineId = 77, lineCid = "line:event:cargo:1", companyCid = "company:1",
    groups = { 901, 902 },
    stationGroupCids = { "station_group:a", "station_group:b" },
    vehicleCids = { "vehicle:event:1", "vehicle:event:2" }, vehicles = 2,
    consistFacts = {
      cargoCapacityByType = { GRAIN = 96 },
      cargoCapacityByVehicleCid = {
        ["vehicle:event:1"] = { GRAIN = 24 },
        ["vehicle:event:2"] = { GRAIN = 72 },
      },
    },
    computed = { distanceMeters = 6000, headwaySeconds = 1200,
      journeySeconds = 600, topSpeedKmh = 80, cruiseSpeedKmh = 56,
      cycleSeconds = 1440, departuresPerHourPerDirection = 3 },
    annualVehicleUpkeepCents = 200000, pricedVehicles = 2,
    resolveLocal = function(_, cid) return localIds[cid] end,
    positionOfEntity = function(id) return positions[id] end,
    nameOf = function(id) return "entity-" .. tostring(id) end,
  })
  truthy(ok, result)
  equal(result.cargoType, "GRAIN")
  equal(result.sourceIndustryCid, "industry:source")
  equal(result.destinationIndustryCid, "industry:sink")
  local market = economyState.markets[result.marketCid]
  equal(market.kind, "cargo")
  equal(market.demand, 150, "freight demand must be limited by destination input rate")
  local service = economyState.services["line:event:cargo:1"]
  equal(service.capacity, 144,
    "heterogeneous fleet capacity was not prorated over fleet departures")
  equal(service.metadata.cargoAverageCapacityByType.GRAIN, 48)
  equal(service.metadata.cargoCapacityByVehicleCid[
    "vehicle:event:1"].GRAIN, 24)
  equal(service.metadata.cargoCapacityByVehicleCid[
    "vehicle:event:2"].GRAIN, 72)
  equal(service.metadata.freightContractSchema, 2)
  equal(service.metadata.freightLegIndex, 0)
  equal(service.metadata.freightLegCount, 1)
  equal(service.metadata.destinationStockIndex, 0)
  equal(service.metadata.sourceStopIndex, 0)
  equal(service.metadata.destinationStopIndex, 1)
end)

test("an unsupported edit orders a portable disabled copy of an existing service", function()
  local state = { economy = economy.newState() }
  economy.upsertMarket(state.economy, {
    cid = "market:old", kind = "passenger", demand = 100,
  })
  economy.upsertService(state.economy, {
    lineCid = "line:event:old", marketCid = "market:old", companyCid = "company:1",
    enabled = true, capacity = 80,
  })
  local action = economyServiceQuarantine.disabledAction(
    state, "line:event:old", "company:1",
    "line endpoints do not map to two distinct towns (both resolve to town 987654)")
  truthy(action and action.service.enabled == false,
    "unsupported existing service did not produce an ordered disable action")
  equal(action.service.metadata.registrationQuarantine, "unsupported-corridor")
  truthy(not json.encode(action):find("987654", 1, true),
    "machine-local route diagnostic leaked into a portable quarantine action")
  equal(state.economy.services["line:event:old"].enabled, true,
    "quarantine action construction mutated authoritative state before ordering")
end)

-- The crowd policy scales native building capacity at load, and gravity demand
-- goes as the product of two town sizes -- so sizing towns by capacity let a
-- cosmetic setting rescale the whole match economy by roughly its square. Town
-- size is a building count instead, and this pins the property that makes a
-- count safe: the capacity floor keeps every populated building populated
-- under every policy, so the building set itself never moves.
test("model town size is independent of the native crowd policy", function()
  local buildings = { 640, 137, 40, 12, 3, 1 }
  local counts, sums = {}, {}
  for _, name in ipairs({ "vanilla", "skeleton", "empty" }) do
    local policy = presentation.mode(name)
    local populated, total = 0, 0
    for _, capacity in ipairs(buildings) do
      local scaled = presentation.scaledCapacity(capacity, policy)
      if scaled > 0 then populated = populated + 1 end
      total = total + scaled
    end
    counts[#counts + 1] = populated
    sums[#sums + 1] = total
  end
  equal(counts[1], #buildings, "every populated building counts under vanilla")
  equal(counts[2], counts[1], "skeleton must not change the building set")
  equal(counts[3], counts[1], "minimum-safe must not change the building set")

  -- The negative half, kept deliberately: this is precisely why summing native
  -- capacity into the economy was wrong, and why the boundary check forbids it.
  truthy(sums[1] > sums[2], "capacity sums do move with the crowd policy")
  equal(sums[2], sums[3],
    "both reduced modes keep one slot per building; recomputation policy distinguishes them")
  truthy(
    world.gravityDemand(sums[1], sums[1], 5000)
      > world.gravityDemand(sums[3], sums[3], 5000),
    "capacity-sized demand would depend on a cosmetic setting")
end)

test("computed service facts derive journey, headway, and capacity from geometry", function()
  local previousGame, previousApi = game, api
  local positions = {
    [11] = { x = 0, y = 0 },
    [12] = { x = 10000, y = 0 },
  }
  game = { interface = { getEntity = function(id)
    local p = positions[id]
    return p and { id = id, position = { p.x, p.y } } or nil
  end } }
  api = { type = { ComponentType = { CONSTRUCTION = "CONSTRUCTION", BASE_NODE = "BASE_NODE" } },
    engine = { getComponent = function() return nil end } }
  local facts = world.computedServiceFacts({ 11, 12 }, 2, { seats = 200, limitSpeedMs = 40 })
  local slowFacts = world.computedServiceFacts({ 11, 12 }, 2, { seats = 200, limitSpeedMs = 20 })
  local noStock = world.computedServiceFacts({ 11, 12 }, 0, { seats = 200, limitSpeedMs = 40 })
  local unresolved = world.computedServiceFacts({ 11, 13 }, 2, { seats = 200, limitSpeedMs = 40 })
  game, api = previousGame, previousApi
  truthy(facts, "computed facts require only positions and a consist")
  equal(noStock.capacity, 0, "a line with no rolling stock must carry nobody")
  equal(unresolved, nil, "an unresolvable stop must fail the computed path, not fabricate geometry")
  -- 10 km euclidean * 1.25 route factor = 12.5 km at 28 m/s sustained plus
  -- two 45 s dwells: journey 536 s; cycle 1312 s over two vehicles: 656 s.
  equal(facts.distanceMeters, 12500)
  equal(facts.journeySeconds, 536)
  equal(facts.headwaySeconds, 656)
  -- Five fleet-wide departures per direction, each with 200 seats.
  equal(facts.capacity, 200 * 5 * 2,
    "fleet count was applied twice after already shortening headway")
  truthy(slowFacts.journeySeconds > facts.journeySeconds
      and slowFacts.headwaySeconds > facts.headwaySeconds
      and slowFacts.departuresPerHourPerDirection < facts.departuresPerHourPerDirection
      and slowFacts.capacity < facts.capacity,
    "a faster consist did not improve journey, frequency, and usable capacity")
  local repeatFacts
  game = { interface = { getEntity = function(id)
    local p = positions[id]
    return p and { id = id, position = { p.x, p.y } } or nil
  end } }
  repeatFacts = world.computedServiceFacts({ 11, 12 }, 2, { seats = 200, limitSpeedMs = 40 })
  game = previousGame
  equal(hash.value(facts), hash.value(repeatFacts), "computed facts must be repeatable")
end)

test("vehicle replacement automatically refreshes its assigned service facts", function()
  local registry = canonical.newState()
  truthy(canonical.bind(registry, "line:event:replace", "line", 700,
    { owner = "company:1" }))
  truthy(canonical.bind(registry, "vehicle:event:replace", "vehicle", 701,
    { owner = "company:1", lineCid = "line:event:replace" }))
  local state = {
    tick = 43, networkMode = "network", canonical = registry,
    economy = { services = {
      ["line:event:replace"] = { companyCid = "company:1" },
    } },
  }
  local submitted = {}
  local queued = world.autoRegisterLine(state, {
    kind = "vehicle.replace", companyCid = "company:1",
    data = { targetCid = "vehicle:event:replace" },
  }, nil, {
    activeCompany = function() return "company:1" end,
    submit = function(action) submitted[#submitted + 1] = action; return true, {} end,
  })
  truthy(queued)
  equal(#submitted, 1)
  equal(submitted[1].type, "line.register")
  equal(submitted[1].lineCid, "line:event:replace")
  equal(submitted[1].companyCid, "company:1")
  world.autoRegisterLine(state, {
    kind = "vehicle.replace", companyCid = "company:1",
    data = { targetCid = "vehicle:event:replace" },
  }, nil, {
    activeCompany = function() return "company:2" end,
    submit = function(action) submitted[#submitted + 1] = action; return true, {} end,
  })
  equal(#submitted, 1, "the non-owning peer independently derived replacement facts")
end)

test("only station and street topology changes request passenger access refresh", function()
  truthy(world.proposalMayChangePassengerAccess({
    edges = { { carrier = "street" } }, remove = { edges = {} },
  }))
  truthy(world.proposalMayChangePassengerAccess({
    edges = {}, remove = { edges = {} }, constructions = { { kind = "station" } },
  }))
  truthy(world.proposalMayChangePassengerAccess({
    edges = {}, remove = { edges = { "edge:pre:unknown-carrier" } },
  }), "an untyped removed road could silently retain stale access")
  equal(world.proposalMayChangePassengerAccess({
    edges = { { carrier = "track" } }, remove = { edges = {} },
  }), false, "ordinary rail construction caused a registration storm")
end)

test("initial checkpoint revalidates every runnable pre-existing company line", function()
  local registry = canonical.newState()
  truthy(canonical.bind(registry, "line:pre:own", "line", 700))
  truthy(canonical.bind(registry, "line:pre:idle", "line", 701))
  truthy(canonical.bind(registry, "line:pre:rival", "line", 702))
  truthy(canonical.bind(registry, "line:pre:registered", "line", 703))
  local state = {
    tick = 44,
    canonical = registry,
    economy = { services = { ["line:pre:registered"] = { companyCid = "company:1" } } },
    probes = { structural = { lines = {
      { cid = "line:pre:own", owner = "company:1", stops = { "a", "b" }, vehicles = 1 },
      { cid = "line:pre:idle", owner = "company:1", stops = { "a", "b" }, vehicles = 0 },
      { cid = "line:pre:rival", owner = "company:2", stops = { "a", "b" }, vehicles = 1 },
      { cid = "line:pre:registered", owner = "company:1", stops = { "a", "b" }, vehicles = 1 },
    } } },
  }
  local submitted, diagnostics = {}, {}
  local queued, summary = world.autoRegisterExistingServices(state, {
    activeCompany = function() return "company:1" end,
    submit = function(action) submitted[#submitted + 1] = action; return true, { queued = true } end,
    log = function(event, values) diagnostics[#diagnostics + 1] = { event = event, values = values } end,
    reason = "match-initialised",
  })
  equal(queued, 2)
  equal(summary.queued, 2)
  equal(summary.skipped, 2)
  equal(summary.failed, 0)
  equal(#submitted, 2)
  equal(submitted[1].type, "line.register")
  equal(submitted[1].lineCid, "line:pre:own")
  equal(submitted[1].companyCid, "company:1")
  equal(submitted[2].lineCid, "line:pre:registered",
    "a saved service was not revalidated against current transport facts")
  equal(diagnostics[#diagnostics].event, "existing-service-register-scan")
end)

test("consist transport facts read repository metadata fail-soft", function()
  local previousApi = api
  local models = {
    -- Some powered/non-capacity mod parts omit carrier; a named coach still
    -- determines the consist rather than turning it into a false MIXED fleet.
    ["loco.mdl"] = { metadata = { transportVehicle = { topSpeed = 44,
      compartmentsList = { { loadConfigs = { { cargoEntries = { { capacity = 0 } } } } } } } } },
    ["coach.mdl"] = { metadata = { transportVehicle = { carrier = "RAIL", topSpeed = 50,
      compartmentsList = {
        { loadConfigs = { { cargoEntries = {
          { capacity = 40, type = "PASSENGERS" },
          { capacity = 40, type = "PASSENGERS" },
        } } } },
        { loadConfigs = { { cargoEntries = { { capacity = 24, type = "PASSENGERS" } } },
                          { cargoEntries = { { capacity = 80, type = "PASSENGERS" } } } } },
      } } } },
    ["freight.mdl"] = { metadata = { transportVehicle = { carrier = "RAIL", topSpeed = 35,
      compartmentsList = { { loadConfigs = {
        { cargoEntries = { { capacity = 48, type = "COAL" } } },
        { cargoEntries = { { capacity = 48, type = "STONE" } } },
      } } } } } },
    ["ambiguous.mdl"] = { metadata = { transportVehicle = { carrier = "ROAD", topSpeed = 30,
      compartmentsList = { { loadConfigs = {
        { cargoEntries = { { capacity = 30 } } },
      } } } } } },
  }
  local names = { "loco.mdl", "coach.mdl" }
  local indexByName = {
    ["loco.mdl"] = 1, ["coach.mdl"] = 2,
    ["freight.mdl"] = 3, ["ambiguous.mdl"] = 4,
  }
  local byIndex = {
    models["loco.mdl"], models["coach.mdl"],
    models["freight.mdl"], models["ambiguous.mdl"],
  }
  api = { res = { modelRep = {
    find = function(name) return indexByName[name] or -1 end,
    get = function(index) return byIndex[index] end,
  } } }
  local facts = world.consistTransportFacts(names)
  truthy(facts, "metadata-backed consist facts were not produced")
  -- coach: compartment one 80 seats, compartment two best config 80 seats.
  equal(facts.seats, 160)
  equal(facts.kind, "passenger")
  equal(facts.cargoCapacity, 0)
  equal(facts.limitSpeedMs, 44, "the slowest part limits the consist")
  equal(facts.carrier, "RAIL")
  local freight = world.consistTransportFacts({ "loco.mdl", "freight.mdl" })
  equal(freight.kind, "cargo")
  equal(freight.seats, 0, "freight capacity leaked into passenger seats")
  equal(freight.cargoCapacity, 48)
  equal(freight.cargoCapacityByType.COAL, 48)
  equal(freight.cargoCapacityByType.STONE, 48)
  local ambiguous = world.consistTransportFacts({ "loco.mdl", "ambiguous.mdl" })
  equal(ambiguous.kind, "unknown")
  equal(ambiguous.unknownCapacity, 30)
  local shortCoach = vehicleResourceFacts.consist({ "coach.mdl" })
  local mixedFleet = vehicleResourceFacts.combine({ facts, freight })
  equal(mixedFleet.kind, "mixed", "a passenger-first freight fleet was not rejected")
  equal(mixedFleet.carrier, "RAIL")
  equal(mixedFleet.consistCount, 2)
  equal(mixedFleet.cargoCapacityPerVehicleByType.COAL, 24,
    "fleet-average named cargo capacity was not preserved")
  local passengerFleet = vehicleResourceFacts.combine({ facts, shortCoach })
  equal(passengerFleet.kind, "passenger")
  equal(passengerFleet.seats, 160, "heterogeneous fleet seats were not averaged")
  equal(passengerFleet.limitSpeedMs, 44, "fleet speed did not retain its slowest consist")
  local mixedCarrier = vehicleResourceFacts.combine({ facts, ambiguous })
  equal(mixedCarrier.carrier, "MIXED", "cross-carrier fleet identity was hidden")
  api = { res = {} }
  equal(world.consistTransportFacts(names), nil, "missing repository must fail soft")
  api = previousApi
end)

test("same-town road service registers a local authored passenger market", function()
  local previousApi = api
  local busModel = "vehicle/bus/local_test.mdl"
  local model = { metadata = { transportVehicle = {
    carrier = "ROAD", topSpeed = 20,
    compartmentsList = { { loadConfigs = { { cargoEntries = {
      { capacity = 40, type = "PASSENGERS" },
    } } } } },
  } } }
  api = {
    type = { ComponentType = {
      TRANSPORT_VEHICLE = "TRANSPORT_VEHICLE", MAINTENANCE_COST = "MAINTENANCE_COST",
    } },
    res = { modelRep = {
      find = function(name) return name == busModel and 19 or -1 end,
      get = function(id) return id == 19 and model or nil end,
      getName = function(id) return id == 19 and busModel or nil end,
    } },
    engine = { getComponent = function(id, kind)
      if id == 501 and kind == "TRANSPORT_VEHICLE" then
        return { transportVehicleConfig = { vehicles = { { part = { modelId = 19 } } } } }
      end
      if id == 501 and kind == "MAINTENANCE_COST" then return { maintenanceCost = 1000 } end
    end },
  }
  local ids = {
    [77] = "line:event:bus:1", [901] = "station_group:event:bus:a",
    [902] = "station_group:event:bus:b", [700] = "town:pre:local",
  }
  local registry = { byCanonical = {
    ["vehicle:event:bus:1"] = {
      kind = "vehicle", localId = 501,
      metadata = { owner = "company:1", annualVehicleUpkeepCents = 100000 },
    },
  } }
  local accessByGroup = {
    [901] = { ready = true, reachableBuildings = 25, townBuildingCount = 100 },
    [902] = { ready = true, reachableBuildings = 25, townBuildingCount = 100 },
  }
  local binding = corridorBindingModule.new({
    bindExisting = function(_, localId) return ids[localId] end,
    lineStopGroups = function() return { 901, 902 } end,
    lineServiceKind = function() return "passenger", "indexed station" end,
    stationGroupTown = function() return 700 end,
    stationGroupPassengerAccess = function(groupId) return accessByGroup[groupId] end,
    townCapacity = function() return 100, { 100, 100, 100 } end,
    townBuildingCount = function() return 100 end,
    lineVehicleIds = function() return { 501 } end,
    nameOf = function(id) return id == 700 and "Testville" or tostring(id) end,
    safeEntity = function() return nil end,
    positionOfEntity = function(id) return id == 901 and { 0, 0 } or { 1000, 0 } end,
    developmentPositionsOfTown = function() return {} end,
    resolveLocal = function() return nil end,
    resolveCanonical = function(_, kind, localId)
      return kind == "vehicle" and localId == 501 and "vehicle:event:bus:1" or nil
    end,
  })
  local economyState = economy.newState()
  local ok, result = binding.makeLineService(
    registry, economy, economyState, 77, "company:1", {})
  truthy(ok, result)
  truthy(result.marketCid:match("^market:local:"), "same-town service used a corridor market")
  equal(result.marketScope, "local")
  equal(result.carrier, "ROAD")
  local market = economyState.markets[result.marketCid]
  equal(market.metadata.townA, "town:pre:local")
  equal(market.metadata.townB, "town:pre:local")
  equal(market.metadata.marketScope, "local")
  local service = economyState.services["line:event:bus:1"]
  equal(service.metadata.carrier, "ROAD")
  equal(service.metadata.marketScope, "local")
  truthy(service.capacity > 0, "local road service received no authored capacity")
  truthy(service.enabled, "a line with reachable buildings was quarantined")
  equal(service.metadata.endpointReachableBuildings[1], 25)
  equal(service.metadata.endpointReachableBuildings[2], 25)
  equal(service.metadata.stationAccessEligible, true)
  local presentation = passengerPresentation.newState()
  local reconciled, line = passengerPresentation.reconcileService(
    presentation, economyState, "line:event:bus:1")
  truthy(reconciled and line, "local road service did not enter passenger presentation")
  local growth = require("tpf2_mp/economy_town_demand").advance(economyState, {
    markets = { [result.marketCid] = { services = {
      ["line:event:bus:1"] = { delivered = 125 },
    } } },
  })
  equal(growth.towns["town:pre:local"].carried, 125,
    "a same-town trip was split away instead of credited once to its town")
  equal(economyState.towns["town:pre:local"].size, 401)
  equal(economyState.towns["town:pre:local"].growthResid, 100)

  economyState.deliveryCursors["line:event:bus:1"] = {
    deliveredPassengers = 125, earnedRevenueCents = 50000,
  }
  accessByGroup[902] = {
    ready = true, reachableBuildings = 0, townBuildingCount = 100,
  }
  local isolatedOk, isolatedResult = binding.makeLineService(
    registry, economy, economyState, 77, "company:1", {})
  truthy(isolatedOk, isolatedResult)
  local isolatedService = economyState.services["line:event:bus:1"]
  equal(isolatedService.enabled, false,
    "a station endpoint with no reachable buildings remained revenue-eligible")
  equal(isolatedService.metadata.stationAccessEligible, false)
  equal(isolatedService.metadata.endpointReachableBuildings[2], 0)
  equal(economyState.deliveryCursors["line:event:bus:1"], nil,
    "retiring the presentation retained a payable delivery cursor")

  local emptyFallback = corridorBindingModule.new({
    bindExisting = function(_, localId) return ids[localId] end,
    lineStopGroups = function() return { 901, 902 } end,
    lineServiceKind = function() return "passenger", "indexed station" end,
    stationGroupTown = function() return 700 end,
    stationGroupPassengerAccess = function()
      return { ready = true, reachableBuildings = 25, townBuildingCount = 100 }
    end,
    townCapacity = function() return 100, { 100, 100, 100 } end,
    townBuildingCount = function() return 100 end,
    lineVehicleIds = function() return {} end,
    nameOf = function(id) return id == 700 and "Testville" or tostring(id) end,
    safeEntity = function() return { frequency = 1 / 300, rate = 999 } end,
    positionOfEntity = function() return nil end,
    developmentPositionsOfTown = function() return {} end,
    resolveLocal = function() return nil end,
    resolveCanonical = function() return nil end,
  })
  local fallbackState = economy.newState()
  local fallbackOk, fallbackResult = emptyFallback.makeLineService(
    { byCanonical = {} }, economy, fallbackState, 77, "company:1", {})
  api = previousApi
  truthy(fallbackOk, fallbackResult)
  local fallbackService = fallbackState.services["line:event:bus:1"]
  equal(fallbackService.metadata.factsSource, "estimated-legacy")
  equal(fallbackService.capacity, 0,
    "legacy frequency/rate fallback invented capacity for an empty line")
end)

test("air service registers, settles, and synchronizes at every airport stop", function()
  local previousApi = api
  local planeModel = "vehicle/plane/commuter.mdl"
  local model = { metadata = { transportVehicle = {
    carrier = "AIR", topSpeed = 150,
    compartmentsList = { { loadConfigs = { { cargoEntries = {
      { capacity = 60, type = "PASSENGERS" },
    } } } } },
  } } }
  api = {
    type = { ComponentType = {
      TRANSPORT_VEHICLE = "TRANSPORT_VEHICLE", MAINTENANCE_COST = "MAINTENANCE_COST",
    } },
    res = { modelRep = {
      find = function(name) return name == planeModel and 29 or -1 end,
      get = function(id) return id == 29 and model or nil end,
      getName = function(id) return id == 29 and planeModel or nil end,
    } },
    engine = { getComponent = function(id, kind)
      if id == 601 and kind == "TRANSPORT_VEHICLE" then
        return { transportVehicleConfig = { vehicles = { { part = { modelId = 29 } } } } }
      end
      if id == 601 and kind == "MAINTENANCE_COST" then
        return { maintenanceCost = 2500000 }
      end
    end },
  }
  local ids = {
    [88] = "line:event:air:1",
    [951] = "station_group:event:airport:a",
    [952] = "station_group:event:airport:b",
    [701] = "town:pre:airport-a",
    [702] = "town:pre:airport-b",
  }
  local registry = { byCanonical = {
    ["vehicle:event:air:1"] = {
      kind = "vehicle", localId = 601,
      metadata = { owner = "company:1", annualVehicleUpkeepCents = 250000000 },
    },
  } }
  local binding = corridorBindingModule.new({
    bindExisting = function(_, localId) return ids[localId] end,
    lineStopGroups = function() return { 951, 952 } end,
    lineServiceKind = function() return "passenger", "airport passenger terminals" end,
    stationGroupTown = function(groupId) return groupId == 951 and 701 or 702 end,
    stationGroupPassengerAccess = function(groupId)
      return {
        ready = true,
        reachableBuildings = groupId == 951 and 40 or 50,
        townBuildingCount = groupId == 951 and 120 or 150,
      }
    end,
    townCapacity = function(townId)
      return townId == 701 and 360 or 450, { 120, 120, 120 }
    end,
    townBuildingCount = function(townId) return townId == 701 and 120 or 150 end,
    lineVehicleIds = function() return { 601 } end,
    nameOf = function(id) return ({ [701] = "Aero A", [702] = "Aero B" })[id] or tostring(id) end,
    safeEntity = function() return nil end,
    positionOfEntity = function(id) return id == 951 and { 0, 0 } or { 100000, 0 } end,
    developmentPositionsOfTown = function() return {} end,
    resolveLocal = function() return nil end,
    resolveCanonical = function(_, kind, localId)
      return kind == "vehicle" and localId == 601 and "vehicle:event:air:1" or nil
    end,
  })
  local economyState = economy.newState()
  local ok, result = binding.makeLineService(
    registry, economy, economyState, 88, "company:1", {})
  api = previousApi
  truthy(ok, result)
  equal(result.carrier, "AIR")
  equal(result.marketScope, "corridor")
  truthy(not result.marketCid:match("^market:local:"),
    "intercity air service became a local feeder market")
  local service = economyState.services["line:event:air:1"]
  equal(service.metadata.carrier, "AIR")
  equal(service.metadata.factsSource, "computed-consist")
  equal(service.metadata.seatsPerVehicle, 60)
  equal(service.metadata.topSpeedKmh, 540)
  equal(service.metadata.stationAccessEligible, true)
  truthy(service.capacity > 0 and service.enabled,
    "road-connected passenger airports produced no authoritative capacity")
  truthy(economyState.vehicleCosts["vehicle:event:air:1"],
    "aircraft upkeep did not enter the authored economy")
  local settled
  for _ = 1, 30 do settled = economy.evaluateAll(economyState) end
  local row = settled.markets[result.marketCid].services["line:event:air:1"]
  truthy(row.allocated > 0, "eligible air corridor received no passengers")
  truthy(row.revenueCents > 0, "eligible air corridor earned no authored fare revenue")
  local syncState = require "tpf2_mp/vehicle_sync_state"
  -- Unlike dense curb-stop ROAD/TRAM services, AIR remains conservative: every
  -- airport stop is an all-peer rendezvous until human flight evidence proves a
  -- cheaper policy safe.
  service.metadata.stationGroupCids = {
    "station_group:event:airport:a", "station_group:event:airport:hub",
    "station_group:event:airport:b",
  }
  truthy(syncState.synchronizesStop(economyState, "line:event:air:1", 0))
  truthy(syncState.synchronizesStop(economyState, "line:event:air:1", 1))
  truthy(syncState.synchronizesStop(economyState, "line:event:air:1", 2))
end)

test("water service registers, settles, and synchronizes at every harbor stop", function()
  local previousApi = api
  local shipModel = "vehicle/ship/damen_ferry_v2.mdl"
  api = {
    type = { ComponentType = {
      TRANSPORT_VEHICLE = "TRANSPORT_VEHICLE", MAINTENANCE_COST = "MAINTENANCE_COST",
    } },
    res = { modelRep = {
      find = function(name) return name == shipModel and 31 or -1 end,
      get = function(id) return id == 31 and { metadata = { transportVehicle = {
        carrier = "WATER", topSpeed = 10,
        compartmentsList = { { loadConfigs = { { cargoEntries = {
          { capacity = 80, type = "PASSENGERS" },
        } } } } },
      } } } or nil end,
      getName = function(id) return id == 31 and shipModel or nil end,
    } },
    engine = { getComponent = function(id, kind)
      if id == 611 and kind == "TRANSPORT_VEHICLE" then
        return { transportVehicleConfig = { vehicles = { { part = { modelId = 31 } } } } }
      end
      if id == 611 and kind == "MAINTENANCE_COST" then
        return { maintenanceCost = 900000 }
      end
    end },
  }
  local ids = {
    [89] = "line:event:water:1",
    [961] = "station_group:event:harbor:a",
    [962] = "station_group:event:harbor:b",
    [711] = "town:pre:harbor-a",
    [712] = "town:pre:harbor-b",
  }
  local registry = { byCanonical = {
    ["vehicle:event:water:1"] = {
      kind = "vehicle", localId = 611,
      metadata = { owner = "company:1", annualVehicleUpkeepCents = 90000000 },
    },
  } }
  local binding = corridorBindingModule.new({
    bindExisting = function(_, localId) return ids[localId] end,
    lineStopGroups = function() return { 961, 962 } end,
    lineServiceKind = function() return "passenger", "harbor passenger terminals" end,
    stationGroupTown = function(groupId) return groupId == 961 and 711 or 712 end,
    stationGroupPassengerAccess = function(groupId)
      return {
        ready = true, reachableBuildings = groupId == 961 and 35 or 45,
        townBuildingCount = groupId == 961 and 110 or 140,
      }
    end,
    townCapacity = function(townId)
      return townId == 711 and 330 or 420, { 110, 110, 110 }
    end,
    townBuildingCount = function(townId) return townId == 711 and 110 or 140 end,
    lineVehicleIds = function() return { 611 } end,
    nameOf = function(id) return ({ [711] = "Harbor A", [712] = "Harbor B" })[id]
      or tostring(id) end,
    safeEntity = function() return nil end,
    positionOfEntity = function(id) return id == 961 and { 0, 0 } or { 20000, 0 } end,
    developmentPositionsOfTown = function() return {} end,
    resolveLocal = function() return nil end,
    resolveCanonical = function(_, kind, localId)
      return kind == "vehicle" and localId == 611 and "vehicle:event:water:1" or nil
    end,
  })
  local economyState = economy.newState()
  local ok, result = binding.makeLineService(
    registry, economy, economyState, 89, "company:1", {})
  api = previousApi
  truthy(ok, result)
  equal(result.carrier, "WATER")
  equal(result.marketScope, "corridor")
  local service = economyState.services["line:event:water:1"]
  equal(service.metadata.carrier, "WATER")
  equal(service.metadata.factsSource, "computed-consist")
  equal(service.metadata.seatsPerVehicle, 80)
  equal(service.metadata.topSpeedKmh, 36)
  truthy(service.capacity > 0 and service.enabled,
    "road-connected passenger harbors produced no authoritative capacity")
  truthy(economyState.vehicleCosts["vehicle:event:water:1"],
    "ship upkeep did not enter the authored economy")
  local settled
  for _ = 1, 30 do settled = economy.evaluateAll(economyState) end
  local row = settled.markets[result.marketCid].services["line:event:water:1"]
  truthy(row.allocated > 0 and row.revenueCents > 0,
    "eligible water corridor produced no passenger revenue")
  local syncState = require "tpf2_mp/vehicle_sync_state"
  service.metadata.stationGroupCids = {
    "station_group:event:harbor:a", "station_group:event:harbor:hub",
    "station_group:event:harbor:b",
  }
  truthy(syncState.synchronizesStop(economyState, "line:event:water:1", 0))
  truthy(syncState.synchronizesStop(economyState, "line:event:water:1", 1))
  truthy(syncState.synchronizesStop(economyState, "line:event:water:1", 2))
end)

test("station boards aggregate model allocations per station group", function()
  local state = marketState(1000)
  corridorService(state, "a", "company:1", {})
  state.services["line:a"].metadata = { stationGroupCids = { "sg:alpha", "sg:beta" } }
  for _ = 1, 30 do economy.evaluateAll(state) end
  local registry = { byCanonical = { ["sg:alpha"] = { metadata = { name = "Alpha Central" } } } }
  local boards = world.stationBoards(state, registry)
  truthy(boards["sg:alpha"] and boards["sg:beta"], "both stops must have boards")
  equal(boards["sg:alpha"].name, "Alpha Central")
  equal(boards["sg:beta"].name, "sg:beta", "unnamed stops fall back to the cid")
  local allocated = state.lastResults.markets["market:a-b"].services["line:a"].allocated
  -- Boards distribute a line's load across its stops: summing every board of
  -- a single service must reproduce that service's load, never multiply it.
  equal(boards["sg:alpha"].throughput + boards["sg:beta"].throughput, allocated - allocated % 2,
    "per-stop throughput must sum back to the line's own allocation")
  truthy(boards["sg:alpha"].waiting <= allocated, "momentary waiting cannot exceed epoch throughput")
  equal(boards["sg:alpha"].waiting, boards["sg:beta"].waiting, "same service, same board contribution")
  equal(boards["sg:alpha"].lines[1].lineAllocated, allocated,
    "the per-line row still reports the whole service load")
end)

local function passengerPresentationEconomy(kind, allocation, requested)
  local state = economy.newState()
  economy.upsertMarket(state, {
    cid = "market:presentation", kind = kind or "passenger", demand = 100,
    votCentsPerHour = 450, gcOutsideCents = 2500, thetaCents = 250,
  })
  economy.upsertService(state, {
    lineCid = "line:presentation", marketCid = "market:presentation",
    companyCid = "company:1", headwaySeconds = 900, journeySeconds = 1200,
    fareCents = 500, capacity = 320, quality = 100, transfers = 0,
    metadata = {
      stationGroupCids = { "station:a", "station:middle", "station:b" },
      seatsPerVehicle = 40, vehicleCount = 2,
    },
  })
  state.epoch = 1
  state.scheduler.lastBoundaryGameTimeSeconds = 300
  state.lastResults = { intervalSeconds = 300, boundaryGameTimeSeconds = 300, markets = {
    ["market:presentation"] = { intervalSeconds = 300, services = {
      ["line:presentation"] = {
        allocated = allocation or 65,
        requested = requested or allocation or 65,
        capacityOverflow = math.max(0, (requested or allocation or 65) - (allocation or 65)),
      },
    } },
  }, companies = {} }
  return state
end

local function passengerRelease(vehicleCid, round, stopIndex, releaseAtGameTime)
  return {
    type = "vehicle.sync_release", vehicleCid = vehicleCid,
    lineCid = "line:presentation", round = round, stopIndex = stopIndex,
    releaseAtGameTime = releaseAtGameTime or 600,
  }
end

test("passenger presentation conserves queues and loads across ordered releases", function()
  local economyState = passengerPresentationEconomy("passenger", 65)
  local state = passengerPresentation.newState()
  local ok, result = passengerPresentation.beginEpoch(state, economyState)
  truthy(ok, result)
  local line = state.lines["line:presentation"]
  equal(line.waitingAToB, 0)
  equal(line.waitingBToA, 0,
    "the demand rate must not appear as an instantaneous settlement batch")
  equal(line.departuresPlanned, 1)
  equal(line.seatsPerVehicle, 40)

  ok, result = passengerPresentation.applyRelease(state, economyState,
    passengerRelease("vehicle:one", 1, 0), { owner = "company:1" })
  truthy(ok, result)
  equal(result.boarded, 32)
  equal(result.aboard, 32)
  equal(line.waitingAToB, 0)

  ok, result = passengerPresentation.applyRelease(state, economyState,
    passengerRelease("vehicle:one", 2, 1), { owner = "company:1" })
  truthy(ok, result)
  equal(result.boarded, 0, "intermediate stops must preserve the terminal load")
  equal(result.alighted, 0)
  equal(result.aboard, 32)

  ok, result = passengerPresentation.applyRelease(state, economyState,
    passengerRelease("vehicle:one", 3, 2), { owner = "company:1" })
  truthy(ok, result)
  equal(result.alighted, 32)
  equal(result.boarded, 33)
  equal(result.aboard, 33)
  equal(line.earnedRevenueCents, 16000000,
    "completed passenger cohorts did not accrue boarding-time fare")

  local beforeDuplicate = hash.value(passengerPresentation.digestView(state))
  ok, result = passengerPresentation.applyRelease(state, economyState,
    passengerRelease("vehicle:one", 3, 2), { owner = "company:1" })
  truthy(ok and result.duplicate, "the same committed release must be idempotent")
  equal(hash.value(passengerPresentation.digestView(state)), beforeDuplicate,
    "a duplicate release changed the authored ledger")

  ok, result = passengerPresentation.applyRelease(state, economyState,
    passengerRelease("vehicle:two", 1, 0), { owner = "company:1" })
  truthy(ok, result)
  equal(result.boarded, 0)
  local waiting = line.waitingAToB + line.waitingBToA
  local aboard = state.vehicles["vehicle:one"].aboard
    + state.vehicles["vehicle:two"].aboard
  equal(waiting + aboard + line.alightedTotal, 65,
    "passengers were created or lost between queue, train, and completed trip")

  local registry = canonical.newState()
  for cid, localId in pairs({
    ["line:presentation"] = 11, ["vehicle:one"] = 21, ["vehicle:two"] = 22,
    ["station:a"] = 31, ["station:middle"] = 32, ["station:b"] = 33,
  }) do
    registry.byCanonical[cid] = { localId = localId, metadata = { name = cid .. " name" } }
  end
  local public = passengerPresentation.publicView(state, economyState, registry)
  equal(public.localVehicles["21"], "vehicle:one")
  equal(public.localStations["31"], "station:a")
  equal(public.localStations["32"], "station:middle")
  equal(public.stations["station:middle"].waiting, 0,
    "an intermediate station needs an exact zero board, not a missing display")
  equal(public.localLines["11"], "line:presentation")
  equal(public.totals.aboard, aboard)
  equal(public.totals.waiting, waiting)
end)

test("passenger arrivals fill physical seats and leave capacity overflow waiting", function()
  local economyState = passengerPresentationEconomy("passenger", 30, 45)
  economyState.services["line:presentation"].metadata.seatsPerVehicle = 20
  economyState.services["line:presentation"].headwaySeconds = 389
  local state = passengerPresentation.newState()
  truthy(passengerPresentation.beginEpoch(state, economyState))

  local ok, result = passengerPresentation.applyRelease(state, economyState,
    passengerRelease("vehicle:full", 1, 0, 689), { owner = "company:1" })
  truthy(ok, result)
  equal(result.boarded, 20, "a busy departure did not fill its twenty physical seats")
  equal(result.capacity, 20)
  equal(result.requested, 45)
  equal(result.allocated, 30)
  truthy(result.waitingAToB >= 8,
    "capacity-constrained riders disappeared instead of remaining at the station")
  equal(state.lines["line:presentation"].capacityOverflow, 15)
  equal(state.lines["line:presentation"].generatedTotal,
    result.generatedAToB + result.generatedBToA)
end)

test("passenger presentation carries backlog, invalidates edited routes, and excludes cargo", function()
  local economyState = passengerPresentationEconomy("passenger", 65)
  local state = passengerPresentation.newState()
  truthy(passengerPresentation.beginEpoch(state, economyState))
  truthy(passengerPresentation.applyRelease(state, economyState,
    passengerRelease("vehicle:one", 1, 0), { owner = "company:1" }))

  economyState.epoch = 2
  economyState.scheduler.lastBoundaryGameTimeSeconds = 600
  economyState.lastResults.boundaryGameTimeSeconds = 600
  economyState.lastResults.markets["market:presentation"].services
    ["line:presentation"].allocated = 20
  economyState.lastResults.markets["market:presentation"].services
    ["line:presentation"].requested = 20
  economyState.lastResults.markets["market:presentation"].services
    ["line:presentation"].capacityOverflow = 0
  truthy(passengerPresentation.beginEpoch(state, economyState))
  local line = state.lines["line:presentation"]
  equal(line.waitingAToB, 0)
  equal(line.waitingBToA, 33, "the opposite-terminal backlog was not carried")
  equal(state.vehicles["vehicle:one"].aboard, 32,
    "settlement must not teleport a train empty")

  economyState.services["line:presentation"].metadata.stationGroupCids = {
    "station:a", "station:new-middle", "station:c",
  }
  truthy(passengerPresentation.reconcileService(state, economyState, "line:presentation"))
  line = state.lines["line:presentation"]
  equal(line.waitingAToB, 0)
  equal(line.waitingBToA, 0)
  equal(line.overflowTotal, 33, "edited-route queues must be accounted, not teleported")
  equal(state.vehicles["vehicle:one"].aboard, 0)
  equal(state.vehicles["vehicle:one"].discardedTotal, 32)
  equal(line.discardedTotal, 32,
    "edited-route onboard passengers were absent from the line ledger")
  equal(line.boardedTotal,
    line.alightedTotal + line.discardedTotal + state.vehicles["vehicle:one"].aboard,
    "route editing broke passenger conservation")

  local cargoEconomy = passengerPresentationEconomy("cargo", 65)
  local cargoState = passengerPresentation.newState()
  truthy(passengerPresentation.beginEpoch(cargoState, cargoEconomy))
  equal(next(cargoState.lines), nil, "cargo demand entered the passenger ledger")

  local disabledEconomy = passengerPresentationEconomy("passenger", 65)
  disabledEconomy.services["line:presentation"].enabled = false
  local disabledState = passengerPresentation.newState()
  truthy(passengerPresentation.beginEpoch(disabledState, disabledEconomy))
  equal(next(disabledState.lines), nil,
    "a quarantined disabled service retained a passenger queue")
end)

test("atomic vehicle sale batches retire every authored presentation entry", function()
  local transaction = {
    kind = "vehicle.sell_batch",
    data = { targetCids = { "vehicle:batch:a", "vehicle:batch:b" } },
  }
  local passengerState = passengerPresentation.newState()
  passengerState.lines["line:batch"] = {
    boardedTotal = 15, alightedTotal = 0, discardedTotal = 0,
  }
  passengerState.vehicles = {
    ["vehicle:batch:a"] = {
      vehicleCid = "vehicle:batch:a", lineCid = "line:batch", aboard = 3,
      boardedTotal = 3, alightedTotal = 0, discardedTotal = 0,
    },
    ["vehicle:batch:b"] = {
      vehicleCid = "vehicle:batch:b", lineCid = "line:batch", aboard = 5,
      boardedTotal = 5, alightedTotal = 0, discardedTotal = 0,
    },
    ["vehicle:batch:keep"] = {
      vehicleCid = "vehicle:batch:keep", lineCid = "line:batch", aboard = 7,
      boardedTotal = 7, alightedTotal = 0, discardedTotal = 0,
    },
  }
  local passengerOk, passengerResult = passengerPresentation.onOperation(
    passengerState, economy.newState(), transaction, "company:1")
  truthy(passengerOk, passengerResult)
  equal(passengerResult.vehicles["vehicle:batch:a"], nil)
  equal(passengerResult.vehicles["vehicle:batch:b"], nil)
  truthy(passengerResult.vehicles["vehicle:batch:keep"],
    "batch sale retired an unselected passenger vehicle")
  equal(passengerResult.lines["line:batch"].discardedTotal, 8,
    "batch sale silently lost passengers aboard the retired vehicles")
  equal(passengerResult.lines["line:batch"].boardedTotal,
    passengerResult.lines["line:batch"].discardedTotal
      + passengerResult.vehicles["vehicle:batch:keep"].aboard,
    "passenger sale did not preserve the line conservation equation")

  local cargoState = cargoPresentation.newState()
  cargoState.lines["line:batch"] = { discardedTotal = 4 }
  cargoState.vehicles = {
    ["vehicle:batch:a"] = { lineCid = "line:batch", aboard = 3 },
    ["vehicle:batch:b"] = { lineCid = "line:batch", aboard = 5 },
    ["vehicle:batch:keep"] = { lineCid = "line:batch", aboard = 7 },
  }
  local cargoOk, cargoResult = cargoPresentation.onOperation(
    cargoState, economy.newState(), transaction, "company:1")
  truthy(cargoOk, cargoResult)
  equal(cargoResult.vehicles["vehicle:batch:a"], nil)
  equal(cargoResult.vehicles["vehicle:batch:b"], nil)
  truthy(cargoResult.vehicles["vehicle:batch:keep"],
    "batch sale retired an unselected cargo vehicle")
  equal(cargoResult.lines["line:batch"].discardedTotal, 12,
    "batch sale did not account every retired onboard cargo unit")
end)

test("passenger reassignment retires the old trip before starting a fresh ledger", function()
  local economyState = passengerPresentationEconomy("passenger", 65)
  local state = passengerPresentation.newState()
  state.lines["line:old"] = {
    boardedTotal = 6, alightedTotal = 0, discardedTotal = 0,
  }
  state.vehicles["vehicle:moving"] = {
    vehicleCid = "vehicle:moving", lineCid = "line:old", companyCid = "company:1",
    capacity = 20, aboard = 6, lastRound = 1,
    boardedTotal = 6, alightedTotal = 0, discardedTotal = 0,
  }
  local ok, result = passengerPresentation.onOperation(state, economyState, {
    kind = "vehicle.assign",
    data = { targetCid = "vehicle:moving", lineCid = "line:presentation" },
  }, "company:1")
  truthy(ok, result)
  equal(result.lines["line:old"].discardedTotal, 6,
    "reassignment did not account the old line's onboard passengers")
  equal(result.lines["line:old"].boardedTotal,
    result.lines["line:old"].alightedTotal + result.lines["line:old"].discardedTotal)
  local vehicle = result.vehicles["vehicle:moving"]
  equal(vehicle.lineCid, "line:presentation")
  equal(vehicle.aboard, 0)
  equal(vehicle.boardedTotal, 0)
  equal(vehicle.alightedTotal, 0)
  equal(vehicle.discardedTotal, 0)
end)

test("passenger schema migration recovers the historical sold-vehicle residue", function()
  local migrated = passengerPresentation.migrate({
    schemaVersion = 3, epoch = 4,
    lines = {
      ["line:legacy"] = {
        boardedTotal = 1513, alightedTotal = 1498, discardedTotal = 0,
      },
      ["line:current"] = {
        boardedTotal = 0, alightedTotal = 0, discardedTotal = 0,
      },
    },
    vehicles = {
      ["vehicle:active"] = {
        lineCid = "line:legacy", aboard = 2, boardedTotal = 20,
        alightedTotal = 18, discardedTotal = 0,
      },
      ["vehicle:reassigned"] = {
        lineCid = "line:current", aboard = 0, boardedTotal = 0,
        alightedTotal = 0, discardedTotal = 6,
      },
    },
  })
  equal(migrated.schemaVersion, 4)
  equal(migrated.lines["line:legacy"].discardedTotal, 13,
    "schema migration did not recover the exact unexplained passenger residue")
  equal(migrated.lines["line:legacy"].boardedTotal,
    migrated.lines["line:legacy"].alightedTotal
      + migrated.lines["line:legacy"].discardedTotal
      + migrated.vehicles["vehicle:active"].aboard)
  equal(migrated.vehicles["vehicle:reassigned"].discardedTotal, 0,
    "migration retained a previous line's discard count on a fresh vehicle ledger")
end)

test("passenger presentation aligns pre-ledger saves but rejects real-state drift", function()
  local economyState = passengerPresentationEconomy("passenger", 65)
  local state = passengerPresentation.newState()
  local sync = { vehicles = { ["vehicle:old"] = {
    vehicleCid = "vehicle:old", lineCid = "line:presentation", companyCid = "company:1",
    lastAuthorizedRound = 7, stopIndex = 2,
  } } }
  local ok, result = passengerPresentation.alignWithVehicleSync(state, economyState, sync)
  truthy(ok, result)
  equal(state.vehicles["vehicle:old"].lastRound, 7)
  equal(state.vehicles["vehicle:old"].lastStopIndex, 2)
  equal(state.vehicles["vehicle:old"].lastStationGroupCid, "station:b")
  equal(state.vehicles["vehicle:old"].aboard, 0,
    "migration must not invent historical passengers")

  state.vehicles["vehicle:old"].aboard = 1
  sync.vehicles["vehicle:old"].lastAuthorizedRound = 8
  ok, result = passengerPresentation.alignWithVehicleSync(state, economyState, sync)
  equal(ok, false, "a live passenger ledger mismatch was silently repaired")
  truthy(tostring(result):find("lags", 1, true) ~= nil)
end)

local function cargoPresentationFixture()
  local economyState = economy.newState()
  economy.upsertMarket(economyState, {
    cid = "market:freight:test", kind = "cargo", demand = 720,
  })
  economy.upsertService(economyState, {
    lineCid = "line:freight:test", marketCid = "market:freight:test",
    companyCid = "company:1", headwaySeconds = 900, journeySeconds = 600,
    fareCents = 1000, capacity = 480,
    metadata = {
      freightContractSchema = 1, freightContractDigest = "1234abcd",
      sourceIndustryCid = "industry:source",
      destinationIndustryCid = "industry:sink", destinationStockIndex = 0,
      cargoType = "GRAIN", sourceStationGroupCid = "station_group:source",
      destinationStationGroupCid = "station_group:sink",
      sourceStopIndex = 0, destinationStopIndex = 1,
      cargoCapacityPerVehicle = 40, distanceMeters = 10000,
      cargoCapacityByVehicleCid = { ["vehicle:freight:test"] = 40 },
      stationGroupCids = { "station_group:source", "station_group:sink" },
      vehicleCids = { "vehicle:freight:test" }, vehicleCount = 1,
    },
  })
  economyState.epoch = 1
  economyState.lastResults = { markets = {
    ["market:freight:test"] = { services = {
      ["line:freight:test"] = { allocated = 60 },
    } },
  } }
  local sourceRecipe = freightFixture(
    "industry:source", "industry/test_source.con", 60,
    {}, { {} }, { { cargoType = "GRAIN", amount = 1 } }, {})
  local sinkRecipe = freightFixture(
    "industry:sink", "industry/test_sink.con", 60,
    { { index = 0, cargoType = "GRAIN", stockType = "RECEIVING",
        moreCapacity = 0 } },
    { { { stockIndex = 0, cargoType = "GRAIN", amount = 1 } } }, {}, {})
  local bootstrap = assert(freightIndustryModel.bootstrapAction(
    "edc7a517", 0, { sourceRecipe, sinkRecipe }))
  local freight = freightIndustryModel.newState()
  truthy(freightIndustryModel.applyBootstrap(
    freight, bootstrap, { ready = true, digest = "edc7a517" }))
  freight.industries["industry:source"].outputStock.GRAIN = 100
  return economyState, freight
end

test("cargo presentation conserves stock, vehicle load, delivery, and revenue", function()
  local economyState, freight = cargoPresentationFixture()
  local state = cargoPresentation.newState()
  truthy(cargoPresentation.beginEpoch(state, economyState))
  local function release(round, stopIndex)
    local ok, result = cargoPresentation.applyRelease(state, economyState, freight, {
      type = "vehicle.sync_release", vehicleCid = "vehicle:freight:test",
      lineCid = "line:freight:test", round = round, stopIndex = stopIndex,
    }, { owner = "company:1" })
    truthy(ok, result)
    return result
  end
  local loaded = release(1, 0)
  equal(loaded.boarded, 40)
  equal(loaded.aboard, 40)
  local unloaded = release(2, 1)
  equal(unloaded.delivered, 40)
  equal(unloaded.aboard, 0)
  local loadedAgain = release(3, 0)
  equal(loadedAgain.boarded, 20, "epoch allocation did not cap a second departure")
  local beforeDuplicate = hash.value(cargoPresentation.digestView(state))
  local duplicate = release(3, 0)
  truthy(duplicate.duplicate)
  equal(hash.value(cargoPresentation.digestView(state)), beforeDuplicate)

  local passenger = passengerPresentation.economySnapshot(passengerPresentation.newState())
  passenger.presentationEpoch = 1
  local snapshot, snapshotError = deliverySnapshot.combine(
    passenger, cargoPresentation.economySnapshot(state))
  truthy(snapshot, snapshotError)
  equal(snapshotError, nil, "valid delivery snapshot retained a false validation error")
  local candidate = util.deepCopy(freight)
  local transported, summary = freightIndustryModel.applyTransportSnapshot(
    candidate, snapshot.cargoLines)
  truthy(transported, summary)
  equal(candidate.industries["industry:source"].outputStock.GRAIN, 40)
  equal(candidate.industries["industry:sink"].inputStock[1].amount, 40)
  equal(candidate.transportCursors["line:freight:test"].boardedUnits, 60)
  equal(candidate.transportCursors["line:freight:test"].deliveredUnits, 40)
  equal(snapshot.cargoLines["line:freight:test"].earnedRevenueCents, 40000000)

  local unknownSchema = util.deepCopy(snapshot.cargoLines)
  unknownSchema["line:freight:test"].transportSchema = 3
  local invalid, invalidError = freightIndustryModel.applyTransportSnapshot(
    util.deepCopy(freight), unknownSchema)
  equal(invalid, false, "unknown freight transport schema was accepted")
  truthy(tostring(invalidError):match("malformed"), invalidError)

  local evaluated = economy.evaluateAll(economyState, nil, snapshot)
  local result = evaluated.markets["market:freight:test"].services["line:freight:test"]
  equal(result.delivered, 40)
  equal(result.grossRevenueCents, 40000000,
    "cargo settlement did not use completed synchronized deliveries")
  local registry = canonical.newState()
  registry.byCanonical["station_group:source"] = {
    localId = 901, metadata = { name = "Farm Freight" },
  }
  registry.byCanonical["station_group:sink"] = {
    localId = 902, metadata = { name = "Mill Freight" },
  }
  local public = cargoPresentation.publicView(state, economyState, candidate, registry)
  equal(public.localStations["901"], "station_group:source")
  equal(public.localStations["902"], "station_group:sink")
  equal(public.stations["station_group:source"].waiting, 0)
  equal(public.stations["station_group:sink"].delivered, 40,
    "destination station omitted completed cargo deliveries")
end)

test("air freight uses the conserved cargo ledger without rail-only assumptions", function()
  local economyState, freight = cargoPresentationFixture()
  local lineCid = "line:freight:test"
  local aircraftCid = "vehicle:air-freight:test"
  local service = economyState.services[lineCid]
  service.metadata.carrier = "AIR"
  service.metadata.vehicleCids = { aircraftCid }
  service.metadata.vehicleCount = 1
  service.metadata.cargoCapacityPerVehicle = 40
  service.metadata.cargoCapacityByVehicleCid = { [aircraftCid] = 40 }

  local cargo = cargoPresentation.newState()
  truthy(cargoPresentation.beginEpoch(cargo, economyState))
  local function release(round, stopIndex)
    local ok, result = cargoPresentation.applyRelease(
      cargo, economyState, freight, {
        type = "vehicle.sync_release", vehicleCid = aircraftCid,
        lineCid = lineCid, round = round, stopIndex = stopIndex,
      }, { owner = "company:1" })
    truthy(ok, result)
    return result
  end
  local boarded = release(1, 0)
  local delivered = release(2, 1)
  equal(boarded.boarded, 40)
  equal(boarded.capacity, 40)
  equal(delivered.delivered, 40)
  equal(delivered.aboard, 0)

  local passenger = passengerPresentation.economySnapshot(
    passengerPresentation.newState())
  passenger.presentationEpoch = 1
  local snapshot, snapshotError = deliverySnapshot.combine(
    passenger, cargoPresentation.economySnapshot(cargo))
  truthy(snapshot, snapshotError)
  local candidate = util.deepCopy(freight)
  local transported, summary = freightIndustryModel.applyTransportSnapshot(
    candidate, snapshot.cargoLines)
  truthy(transported, summary)
  equal(candidate.industries["industry:source"].outputStock.GRAIN, 60)
  equal(candidate.industries["industry:sink"].inputStock[1].amount, 40)

  local settled = economy.evaluateAll(economyState, nil, snapshot)
  local result = settled.markets["market:freight:test"].services[lineCid]
  equal(result.delivered, 40)
  equal(result.grossRevenueCents, 40000000,
    "AIR carrier changed freight delivery or revenue conservation")
end)

test("water freight uses the conserved cargo ledger without rail-only assumptions", function()
  local economyState, freight = cargoPresentationFixture()
  local lineCid = "line:freight:test"
  local shipCid = "vehicle:water-freight:test"
  local service = economyState.services[lineCid]
  service.metadata.carrier = "WATER"
  service.metadata.vehicleCids = { shipCid }
  service.metadata.vehicleCount = 1
  service.metadata.cargoCapacityPerVehicle = 40
  service.metadata.cargoCapacityByVehicleCid = { [shipCid] = 40 }

  local cargo = cargoPresentation.newState()
  truthy(cargoPresentation.beginEpoch(cargo, economyState))
  local function release(round, stopIndex)
    local ok, result = cargoPresentation.applyRelease(
      cargo, economyState, freight, {
        type = "vehicle.sync_release", vehicleCid = shipCid,
        lineCid = lineCid, round = round, stopIndex = stopIndex,
      }, { owner = "company:1" })
    truthy(ok, result)
    return result
  end
  local boarded = release(1, 0)
  local delivered = release(2, 1)
  equal(boarded.boarded, 40)
  equal(boarded.capacity, 40)
  equal(delivered.delivered, 40)
  equal(delivered.aboard, 0)

  local passenger = passengerPresentation.economySnapshot(
    passengerPresentation.newState())
  passenger.presentationEpoch = 1
  local snapshot, snapshotError = deliverySnapshot.combine(
    passenger, cargoPresentation.economySnapshot(cargo))
  truthy(snapshot, snapshotError)
  local candidate = util.deepCopy(freight)
  local transported, summary = freightIndustryModel.applyTransportSnapshot(
    candidate, snapshot.cargoLines)
  truthy(transported, summary)
  equal(candidate.industries["industry:source"].outputStock.GRAIN, 60)
  equal(candidate.industries["industry:sink"].inputStock[1].amount, 40)

  local settled = economy.evaluateAll(economyState, nil, snapshot)
  local result = settled.markets["market:freight:test"].services[lineCid]
  equal(result.delivered, 40)
  equal(result.grossRevenueCents, 40000000,
    "WATER carrier changed freight delivery or revenue conservation")
end)

test("deleting a freight line retires its authoritative transport cursor", function()
  local economyState, freight = cargoPresentationFixture()
  local lineCid = "line:freight:test"
  freight.transportCursors[lineCid] = {
    contractDigest = "1234abcd", sourceIndustryCid = "industry:source",
    destinationIndustryCid = "industry:sink", destinationStockIndex = 0,
    cargoType = "GRAIN", boardedUnits = 60, deliveredUnits = 40,
  }
  freight.totalTransported.GRAIN = 60
  freight.totalDelivered.GRAIN = 40
  local cargo = cargoPresentation.newState()
  truthy(cargoPresentation.beginEpoch(cargo, economyState))
  local worldState = {
    freightIndustry = freight,
    passengerPresentation = passengerPresentation.newState(),
    cargoPresentation = cargo,
  }
  local ok, result = vehicleSyncPassengers.applyOperation(
    worldState, economyState, {
      kind = "line.delete", data = { targetCid = lineCid },
    }, "company:1")
  truthy(ok, result)
  equal(result.freight.retired, true)
  equal(worldState.freightIndustry.transportCursors[lineCid], nil,
    "deleted cargo line retained its cumulative cursor")
  equal(worldState.freightIndustry.totalTransported.GRAIN, 60,
    "cursor retirement erased historical transported totals")
  equal(worldState.freightIndustry.totalDelivered.GRAIN, 40,
    "cursor retirement erased historical delivered totals")
  equal(worldState.freightIndustry.retiredTransported.GRAIN, 60,
    "cursor retirement did not preserve transported history provenance")
  equal(worldState.freightIndustry.retiredDelivered.GRAIN, 40,
    "cursor retirement did not preserve delivered history provenance")
  equal(worldState.freightIndustry.lastTransport, nil,
    "cursor retirement retained an impossible active-line delta summary")
  local migrated, migrationError = freightIndustryModel.migrate(
    util.deepCopy(worldState.freightIndustry))
  equal(migrationError, nil, "retired freight history did not survive strict migration")
  equal(migrated.retiredTransported.GRAIN, 60)
  equal(worldState.cargoPresentation.lines[lineCid].retired, true,
    "cargo presentation did not retire beside the authoritative cursor")
end)

test("cargo presentation uses each heterogeneous consist's exact capacity", function()
  local economyState, freight = cargoPresentationFixture()
  local service = economyState.services["line:freight:test"]
  service.metadata.vehicleCids = { "vehicle:freight:small", "vehicle:freight:large" }
  service.metadata.vehicleCount = 2
  service.metadata.cargoCapacityPerVehicle = 36
  service.metadata.cargoCapacityByVehicleCid = {
    ["vehicle:freight:small"] = 12,
    ["vehicle:freight:large"] = 60,
  }
  local state = cargoPresentation.newState()
  truthy(cargoPresentation.beginEpoch(state, economyState))
  local function board(vehicleCid)
    local ok, result = cargoPresentation.applyRelease(
      state, economyState, freight, {
        type = "vehicle.sync_release", vehicleCid = vehicleCid,
        lineCid = "line:freight:test", round = 1, stopIndex = 0,
      }, { owner = "company:1" })
    truthy(ok, result)
    return result
  end
  equal(board("vehicle:freight:small").boarded, 12)
  equal(board("vehicle:freight:large").boarded, 48,
    "large consist did not consume the remainder of the shared epoch allocation")
  equal(state.vehicles["vehicle:freight:small"].capacity, 12)
  equal(state.vehicles["vehicle:freight:large"].capacity, 60)
end)

test("changing a cargo line to passenger retires every onboard unit explicitly", function()
  local economyState, freight = cargoPresentationFixture()
  local state = cargoPresentation.newState()
  truthy(cargoPresentation.beginEpoch(state, economyState))
  local ok, loaded = cargoPresentation.applyRelease(
    state, economyState, freight, {
      type = "vehicle.sync_release", vehicleCid = "vehicle:freight:test",
      lineCid = "line:freight:test", round = 1, stopIndex = 0,
    }, { owner = "company:1" })
  truthy(ok, loaded)
  equal(loaded.boarded, 40)
  economyState.markets["market:freight:test"].kind = "passenger"
  truthy(cargoPresentation.beginEpoch(state, economyState))
  equal(state.vehicles["vehicle:freight:test"], nil)
  equal(state.lines["line:freight:test"].retired, true)
  equal(state.lines["line:freight:test"].discardedTotal, 40)
  equal(state.lines["line:freight:test"].boardedTotal,
    state.lines["line:freight:test"].deliveredTotal
      + state.lines["line:freight:test"].discardedTotal)
end)

test("rejected freight re-registration leaves every authored ledger unchanged", function()
  local economyState, freight = cargoPresentationFixture()
  local state = {
    economy = economyState,
    canonical = { byCanonical = {}, byLocal = {} },
    world = {
      freightIndustry = freight,
      passengerPresentation = passengerPresentation.newState(),
      cargoPresentation = cargoPresentation.newState(),
    },
  }
  truthy(cargoPresentation.beginEpoch(
    state.world.cargoPresentation, state.economy))
  state.world.cargoPresentation.lines["line:freight:test"].boardedTotal = 1
  local action = {
    type = "line.register", lineCid = "line:freight:test",
    companyCid = "company:1", vehicleCosts = {},
    market = util.deepCopy(state.economy.markets["market:freight:test"]),
    service = util.deepCopy(state.economy.services["line:freight:test"]),
  }
  action.service.metadata.freightContractDigest = "deadbeef"
  local before = {
    economy = hash.value(state.economy),
    canonical = hash.value(state.canonical),
    passenger = hash.value(state.world.passengerPresentation),
    cargo = hash.value(state.world.cargoPresentation),
  }
  local candidate, rejection = economyLineRegistration.prepare(
    state, {}, economy, passengerPresentation, cargoPresentation,
    action, 1, "company:1")
  equal(candidate, nil)
  truthy(tostring(rejection):find("active freight line", 1, true) ~= nil)
  equal(hash.value(state.economy), before.economy)
  equal(hash.value(state.canonical), before.canonical)
  equal(hash.value(state.world.passengerPresentation), before.passenger)
  equal(hash.value(state.world.cargoPresentation), before.cargo)
end)

test("reusing a line for a different market resets incompatible cursor stock", function()
  local state = economy.newState()
  economy.upsertMarket(state, { cid = "market:passenger", kind = "passenger", demand = 100 })
  economy.upsertService(state, {
    lineCid = "line:reused", marketCid = "market:passenger",
    companyCid = "company:1", sharePpm = 700000,
  })
  state.deliveryCursors["line:reused"] = {
    deliveredPassengers = 12, earnedRevenueCents = 3456,
  }
  economy.upsertMarket(state, { cid = "market:cargo", kind = "cargo", demand = 100 })
  economy.upsertService(state, {
    lineCid = "line:reused", marketCid = "market:cargo",
    companyCid = "company:1", sharePpm = 0,
  })
  equal(state.deliveryCursors["line:reused"], nil)
  equal(state.services["line:reused"].sharePpm, 0)
  equal(state.services["line:reused"].shareResid, 0)
  equal(state.services["line:reused"].lagLoadPpm, 0)
end)

test("freight transport settlement rejects aggregate over-withdrawal atomically", function()
  local _, freight = cargoPresentationFixture()
  local before = hash.value(freight)
  local rows = {}
  for index = 1, 2 do
    rows["line:freight:" .. index] = {
      contractDigest = string.format("1234abc%d", index),
      sourceIndustryCid = "industry:source",
      destinationIndustryCid = "industry:sink", destinationStockIndex = 0,
      cargoType = "GRAIN", boardedUnits = 60, deliveredUnits = 0,
      earnedRevenueCents = 0,
    }
  end
  local ok, message = freightIndustryModel.applyTransportSnapshot(freight, rows)
  equal(ok, false)
  truthy(tostring(message):find("aggregate", 1, true))
  equal(hash.value(freight), before, "rejected freight transfer partially changed stock")
end)

test("an idle freight snapshot does not permanently bind a transport cursor", function()
  local _, freight = cargoPresentationFixture()
  local row = {
    contractDigest = "1234abcd", sourceIndustryCid = "industry:source",
    destinationIndustryCid = "industry:sink", destinationStockIndex = 0,
    cargoType = "GRAIN", boardedUnits = 0, deliveredUnits = 0,
    earnedRevenueCents = 0,
  }
  local ok, summary = freightIndustryModel.applyTransportSnapshot(
    freight, { ["line:freight:idle"] = row })
  truthy(ok, summary)
  equal(summary.lines, 0)
  equal(freight.transportCursors["line:freight:idle"], nil,
    "zero movement made an unused line contract permanent")
end)

test("cargo settlement rejection leaves every authored ledger at its prior epoch", function()
  local bootstrap = assert(freightIndustryModel.bootstrapAction(
    "edc7a517", 0, freightFixtures()))
  local freight = freightIndustryModel.newState()
  truthy(freightIndustryModel.applyBootstrap(
    freight, bootstrap, { ready = true, digest = "edc7a517" }))
  freight.industries["industry:pre:a-farm"].outputStock.GRAIN = 100
  local economyState = economy.newState()
  local state = {
    economy = economyState,
    world = {
      industryContent = { ready = true, digest = "edc7a517" },
      freightIndustry = freight,
      passengerPresentation = passengerPresentation.newState(),
      cargoPresentation = cargoPresentation.newState(),
    },
    probes = { freightIndustry = {
      validatedBootstrapDigest = bootstrap.digest,
    } },
  }
  local rows = {}
  for index = 1, 2 do
    rows["line:overdraw:" .. index] = {
      contractDigest = string.format("8765432%d", index),
      sourceIndustryCid = "industry:pre:a-farm",
      destinationIndustryCid = "industry:pre:b-mill",
      destinationStockIndex = 0, cargoType = "GRAIN",
      boardedUnits = 60, deliveredUnits = 0, earnedRevenueCents = 0,
    }
  end
  local delivery = {
    schemaVersion = 2, presentationEpoch = 0,
    passengerLines = {}, cargoLines = rows,
  }
  local before = {
    economy = hash.value(state.economy),
    freight = hash.value(state.world.freightIndustry),
    passenger = hash.value(state.world.passengerPresentation),
    cargo = hash.value(state.world.cargoPresentation),
  }
  local candidate, candidateError = economySettlementTransaction.prepare(
    state, economy, passengerPresentation, cargoPresentation,
    freightIndustryRuntime, { type = "economy.settle" }, delivery)
  equal(candidate, nil)
  truthy(tostring(candidateError):find("aggregate", 1, true), candidateError)
  equal(hash.value(state.economy), before.economy)
  equal(hash.value(state.world.freightIndustry), before.freight)
  equal(hash.value(state.world.passengerPresentation), before.passenger)
  equal(hash.value(state.world.cargoPresentation), before.cargo)

  delivery.cargoLines["line:overdraw:2"].boardedUnits = 40
  candidate = assert(economySettlementTransaction.prepare(
    state, economy, passengerPresentation, cargoPresentation,
    freightIndustryRuntime, { type = "economy.settle" }, delivery))
  equal(candidate.economy.epoch, 1)
  equal(candidate.passengerPresentation.epoch, 1)
  equal(candidate.cargoPresentation.epoch, 1)
  equal(candidate.freightIndustry.industries[
    "industry:pre:a-farm"].outputStock.GRAIN, 10,
    "transport must withdraw before the same-boundary production step")
  equal(state.economy.epoch, 0, "a valid candidate was adopted before commit")
  local migrated, migrationError = freightIndustryModel.migrate(
    util.deepCopy(candidate.freightIndustry))
  truthy(migrated.ready, migrationError)
  local tampered = util.deepCopy(candidate.freightIndustry)
  tampered.totalTransported.GRAIN = 99
  local rejected, transportMigrationError = freightIndustryModel.migrate(tampered)
  equal(rejected.ready, false)
  truthy(tostring(transportMigrationError):find("totals disagree", 1, true),
    transportMigrationError)
end)

test("native passenger cosmetics are telemetry-only and never issue a command", function()
  local previousApi = api
  local sent, made, enumerations = 0, 0, 0
  local types = {
    SIM_PERSON = "SIM_PERSON", SIM_PERSON_AT_VEHICLE = "SIM_PERSON_AT_VEHICLE",
    SIM_PERSON_AT_TERMINAL = "SIM_PERSON_AT_TERMINAL",
    SIM_ENTITY_AT_VEHICLE = "SIM_ENTITY_AT_VEHICLE",
    SIM_ENTITY_AT_TERMINAL = "SIM_ENTITY_AT_TERMINAL",
  }
  local entities = {
    SIM_PERSON = { 1, 2, 3 },
    SIM_ENTITY_AT_VEHICLE = { 1, 99 },
    SIM_ENTITY_AT_TERMINAL = { 2, 3 },
  }
  api = {
    type = { ComponentType = types },
    engine = {
      forEachEntityWithComponent = function(callback, componentType)
        enumerations = enumerations + 1
        for _, entity in ipairs(entities[componentType] or {}) do callback(entity) end
      end,
      getComponent = function(entity, componentType)
        if componentType == types.SIM_PERSON and entity <= 3 then return {} end
        return nil
      end,
    },
    cmd = {
      make = { debugSetSimPersonState = function(entity, active)
        made = made + 1
        return { entity = entity, active = active }
      end },
      sendCommand = function() sent = sent + 1 end,
    },
  }
  local ok, probe = passengerCosmetics.applyDesiredCounts(nil, {
    totals = { aboard = 1200, waiting = 3400 },
  })
  truthy(ok)
  equal(probe.nativeAboard, 1)
  equal(probe.nativeWaiting, 2)
  equal(probe.requestedAboard, 1200)
  equal(probe.requestedWaiting, 3400)
  equal(probe.appliedWrites, 0)
  equal(probe.targetWritesEnabled, false)
  equal(probe.targetAddressable, false)
  equal(probe.lastError, nil, "successful native passenger readers retained a false error")
  local sampledEnumerations = enumerations
  local cachedOk, cachedProbe = passengerCosmetics.applyDesiredCounts(probe, {
    totals = { aboard = 1300, waiting = 3500 },
  }, { sampleNative = false })
  api = previousApi
  equal(made, 2, "the shape probe must only construct the two boolean variants")
  equal(sent, 0, "the unsafe untargeted debug command was issued")
  truthy(cachedOk)
  equal(cachedProbe.requestedAboard, 1300)
  equal(enumerations, sampledEnumerations,
    "cached cosmetic refresh re-enumerated every native passenger component")
end)

test("town growth targets are deterministic, split, capped, and quiet when idle", function()
  local carried = { ["town:a"] = 400, ["town:b"] = 400 }
  local capacities = { ["town:a"] = { 100, 100, 100 }, ["town:b"] = { 99980, 99990, 99999 } }
  local targets = world.townGrowthTargets(carried, capacities)
  -- 400 carried * 5% = 20 growth points: 12 residential, 5 commercial,
  -- 3 industrial.
  equal(targets["town:a"][1], 112)
  equal(targets["town:a"][2], 105)
  equal(targets["town:a"][3], 103)
  equal(targets["town:b"][1], 99992, "growth must respect the capacity cap headroom")
  equal(targets["town:b"][3], 100000, "growth must clamp at the capacity cap")
  equal(world.townGrowthTargets({}, capacities)["town:a"], nil, "no carried demand, no growth")
  local unchanged = world.townGrowthTargets({ ["town:a"] = 0 }, capacities)
  equal(unchanged["town:a"], nil, "zero carried passengers must not emit a target")
  local big = world.townGrowthTargets({ ["town:a"] = 1000000 }, capacities)
  equal(big["town:a"][1], 150, "per-settle growth is step-limited")
end)

test("carried-by-town splits corridor allocations between digested endpoints", function()
  local results = { markets = { ["market:x"] = { services = {
    ["line:1"] = { allocated = 301 }, ["line:2"] = { allocated = 100 },
  } } } }
  local markets = { ["market:x"] = { metadata = { townA = "town:a", townB = "town:b" } } }
  local carried = world.carriedByTown(results, markets)
  equal(carried["town:a"], 200)
  equal(carried["town:b"], 201, "odd totals keep every passenger somewhere")
  equal(next(world.carriedByTown(results, {})), nil, "markets without town metadata grow nothing")
end)

test("departure slots remain model-only while train synchronization is prompt", function()
  local service = { lineCid = "line:slot-test", headwaySeconds = 600,
    journeySeconds = 900, metadata = { stationGroupCids = { "station:a", "station:b" } } }
  local slot = world.departureSlots(service, 5000, 0)
  equal(slot.periodSeconds, 600)
  truthy(slot.phaseSeconds >= 0 and slot.phaseSeconds < 600, "phase must sit inside the period")
  truthy(slot.nextDepartureAt > 5000, "the next departure is in the future")
  truthy(slot.holdSeconds > 0 and slot.holdSeconds <= 600, "hold time is bounded by one period")
  local later = world.departureSlots(service, slot.nextDepartureAt, 0)
  equal(later.nextDepartureAt, slot.nextDepartureAt + 600, "slots advance by exactly one period")
  equal(later.slotIndex, slot.slotIndex + 1)
  local repeated = world.departureSlots(service, 5000, 0)
  equal(repeated.phaseSeconds, slot.phaseSeconds, "phase must be a pure function of the line")
  local opposite = world.departureSlots(service, 5000, 1)
  truthy(opposite.phaseSeconds ~= slot.phaseSeconds,
    "different stops must receive a deterministic journey offset")
  local registered = world.synchronizationSchedule(service.lineCid, service, 0)
  equal(registered.enabled, false,
    "registered service headway must not become an artificial native dwell")
  local fallbackA = world.synchronizationSchedule("line:fallback", nil, 0)
  local fallbackB = world.synchronizationSchedule("line:fallback", nil, 1)
  equal(fallbackA.enabled, false,
    "ordinary lines must rendezvous without an invented timetable dwell")
  equal(hash.value(fallbackA), hash.value(fallbackB),
    "an unscheduled line must report the same disabled policy at every stop")
  local disabledService = util.deepCopy(service)
  disabledService.enabled = false
  equal(world.synchronizationSchedule(service.lineCid, disabledService, 0).enabled, false,
    "a disabled competitive service must not leak its old timetable into train control")
end)

test("applying town growth issues one deterministic setTownInfo per grown town", function()
  local previousApi, previousGame = api, game
  local sent = {}
  api = { cmd = {
    make = { setTownInfo = function(townId, capacities)
      return { kind = "setTownInfo", townId = townId, capacities = capacities }
    end },
    sendCommand = function(command, callback)
      sent[#sent + 1] = command
      if callback then callback(command, true) end
    end,
  }, engine = { system = { townBuildingSystem = {
    getLandUsePersonCapacities = function() return { 100, 100, 100 } end,
  } } } }
  game = { interface = {} }
  local registry = canonical.newState()
  local economyState = economy.newState()
  economy.upsertMarket(economyState, { cid = "market:grow", demand = 1000,
    votCentsPerHour = 450, gcOutsideCents = 2500, thetaCents = 250,
    metadata = { townA = "town:pre:alpha", townB = "town:pre:beta" } })
  registry.byCanonical["town:pre:alpha"] = { localId = 71, kind = "town" }
  registry.byCanonical["town:pre:beta"] = { localId = 72, kind = "town" }
  registry.byLocal["71"] = "town:pre:alpha"
  registry.byLocal["72"] = "town:pre:beta"
  local results = { markets = { ["market:grow"] = { services = {
    ["line:g"] = { allocated = 400 },
  } } } }
  local outcome = world.applyTownGrowth(registry, economyState, results)
  api, game = previousApi, previousGame
  equal(outcome.towns, 2, "both endpoint towns must grow")
  equal(#outcome.errors, 0)
  equal(#sent, 2)
  table.sort(sent, function(a, b) return a.townId < b.townId end)
  equal(sent[1].townId, 71)
  equal(sent[1].capacities[1], 106, "200 carried at 5% -> 10 points -> 6 residential")
  equal(sent[1].capacities[2], 102)
  equal(sent[1].capacities[3], 101)
end)

test("agent presentation policy scales capacity deterministically per mode", function()
  local skeleton = presentation.mode("skeleton")
  local vanilla = presentation.mode("vanilla")
  local empty = presentation.mode("empty")
  equal(presentation.mode("nonsense").label, "skeleton", "unknown modes fall back to the default")

  -- Vanilla is an exact identity: no rounding, no floor, no surprises.
  equal(presentation.scaledCapacity(137, vanilla), 137)
  -- Skeleton keeps every populated building alive with at least one person.
  equal(presentation.scaledCapacity(640, skeleton), 1,
    "skeleton mode keeps exactly one native inhabitant per populated building")
  equal(presentation.scaledCapacity(30, skeleton), 1, "a small building keeps one inhabitant")
  equal(presentation.scaledCapacity(0, skeleton), 0, "an empty building stays empty")
  -- Empty removes the crowd entirely.
  equal(presentation.scaledCapacity(640, empty), 1,
    "Build 35924 requires a PersonCapacity component on populated town buildings")
  equal(presentation.scaledCapacity(0, empty), 0,
    "a natively empty building stays empty in minimum-safe mode")

  truthy(presentation.fingerprint(skeleton) ~= presentation.fingerprint(vanilla)
    and presentation.fingerprint(skeleton) ~= presentation.fingerprint(empty),
    "each policy must have a distinct match fingerprint")
  equal(presentation.fingerprint(skeleton), presentation.fingerprint(presentation.mode("skeleton")),
    "the same policy must fingerprint identically")
  truthy(vanilla.pinLoadSpeed == false and skeleton.pinLoadSpeed == true,
    "only the reduced policies pin dwell")
  truthy(vanilla.simulateCargoWeight == true and skeleton.simulateCargoWeight == false,
    "reduced policies must decouple load from vehicle physics")
end)

test("applying the agent policy verifies by readback and reports the outcome", function()
  local previousApi, previousGame = api, game
  local capacities = { [71] = { 640, 320, 160 } }
  local sent = {}
  api = { cmd = {
    make = { setTownInfo = function(townId, values)
      return { townId = townId, values = values }
    end },
    sendCommand = function(command, callback)
      sent[#sent + 1] = command
      -- A cooperative build applies the write, so the readback should agree.
      capacities[command.townId] = { command.values[1], command.values[2], command.values[3] }
      if callback then callback(command, true) end
    end,
  } }
  game = { interface = { getTowns = function() return { 71 } end } }
  local deps = {
    listTowns = function() return { 71 } end,
    townCapacity = function(townId)
      local values = capacities[townId]
      return (values[1] or 0) + (values[2] or 0) + (values[3] or 0), values
    end,
  }
  local worldState = {}
  local outcome = presentation.applyToWorld(worldState, presentation.mode("skeleton"), deps)
  api, game = previousApi, previousGame

  equal(outcome.towns, 1)
  equal(outcome.applied, 1)
  equal(outcome.verified, 1, "a readback that matches the target is the proof")
  equal(outcome.runtimeScalingWorks, true)
  equal(#outcome.errors, 0)
  equal(sent[1].values[1], 1, "640 residents become one native decoration under skeleton policy")
  equal(worldState.agentPolicy.mode, "skeleton", "the outcome is recorded on world state")

  -- A build that ignores the write must be reported as such, not assumed.
  previousApi, previousGame = api, game
  local stubborn = { [71] = { 640, 320, 160 } }
  api = { cmd = {
    make = { setTownInfo = function(townId, values) return { townId = townId, values = values } end },
    sendCommand = function(command, callback)
      if callback then callback(command, true) end
      return true
    end,
  } }
  game = { interface = { getTowns = function() return { 71 } end } }
  local stubbornDeps = {
    listTowns = function() return { 71 } end,
    townCapacity = function(townId)
      local values = stubborn[townId]
      return (values[1] or 0) + (values[2] or 0) + (values[3] or 0), values
    end,
  }
  local ignored = presentation.applyToWorld({}, presentation.mode("skeleton"), stubbornDeps)
  api, game = previousApi, previousGame
  equal(ignored.applied, 1)
  equal(ignored.verified, 0, "an unchanged readback must not count as verified")
  equal(ignored.runtimeScalingWorks, false,
    "the probe must report that runtime scaling does not work on this build")
end)

test("the vanilla policy leaves an existing world untouched", function()
  local previousApi, previousGame = api, game
  api = { cmd = { make = {}, sendCommand = function() error("vanilla policy must issue no commands") end } }
  game = { interface = { getTowns = function() return { 71 } end } }
  local outcome = presentation.applyToWorld({}, presentation.mode("vanilla"), {
    listTowns = function() error("vanilla policy must not enumerate towns") end,
    townCapacity = function() error("vanilla policy must not read capacities") end,
  })
  api, game = previousApi, previousGame
  equal(outcome.applied, 0)
  truthy(outcome.skipped ~= nil, "the vanilla policy must explain why it did nothing")
end)

test("configured agent policy never runtime-mutates an existing network world", function()
  local previousApi, previousGame = api, game
  api = { cmd = {
    make = { setTownInfo = function() error("configured policy must not construct setTownInfo") end },
    sendCommand = function() error("configured policy must not issue native commands") end,
  } }
  game = { interface = { getTowns = function() return { 71, 72 } end } }
  local state = { world = {}, probes = {}, tick = 4 }
  local outcome = presentation.applyConfiguredPolicy(state, {
    agentMode = "skeleton", agentPolicyFingerprint = "agents:skeleton:test",
  }, {
    listTowns = function() return { 71, 72 } end,
    townCapacity = function() error("configured policy must not read back unsafe writes") end,
  })
  api, game = previousApi, previousGame

  equal(outcome.towns, 2)
  equal(outcome.applied, 0)
  equal(outcome.verified, 0)
  equal(outcome.runtimeScalingWorks, false)
  equal(outcome.constructionScalingActive, true)
  truthy(outcome.skipped:find("unsafe", 1, true) ~= nil,
    "the probe should preserve the live engine finding")
  equal(state.world.agentPolicy.mode, "skeleton")
  equal(state.probes.agentPolicy.configuredFingerprint, "agents:skeleton:test")
end)

test("credit limits follow earned revenue, not ambition", function()
  local fresh = finance.creditLimit(nil, 1)
  equal(fresh, finance.CREDIT.baseLimitCents, "an untraded company gets only the base line")
  -- 4 settlements averaging 250000 cents each, at a 4x multiple.
  local earned = finance.creditLimit({ revenueCents = 1000000 }, 4)
  equal(earned, finance.CREDIT.baseLimitCents + 250000 * 4)
  truthy(earned > fresh, "trading successfully must extend credit")
  local hourlyExact = finance.creditLimit({ revenueCents = 1200000 }, 4)
  local fiveMinute = finance.creditLimit({ revenueCents = 300000 }, 12, nil, 300)
  equal(fiveMinute, hourlyExact,
    "five-minute settlement history did not annualise to the hourly credit basis")
end)

test("credit charges interest and bankruptcy takes three consecutive breaches", function()
  local state = finance.newState()
  finance.initialiseNetworkAccounts(state, { "company:1", "company:2" }, 0, { reason = "test" })
  local ledger = { settlementCount = 1, companies = {} }

  -- Solvent companies pay nothing and never approach a countdown.
  local report, bankrupt = finance.chargeCreditAndAssessSolvency(
    state, { "company:1", "company:2" }, ledger, {})
  equal(bankrupt, nil)
  equal(report["company:1"].interestCents, 0)
  equal(report["company:1"].breached, false)

  -- Draw well past the limit and the countdown starts, with interest.
  local overdrawn = -(finance.CREDIT.baseLimitCents * 2)
  truthy(finance.applyNetworkDelta(state, "company:1", overdrawn, { kind = "test" }))
  local first
  first, bankrupt = finance.chargeCreditAndAssessSolvency(
    state, { "company:1", "company:2" }, ledger, {})
  equal(bankrupt, nil, "one bad settlement must not end a match")
  equal(first["company:1"].breached, true)
  equal(first["company:1"].insolventSettlements, 1)
  truthy(first["company:1"].interestCents > 0, "drawn credit must cost interest")
  equal(first["company:2"].insolventSettlements, 0, "a solvent rival is untouched")

  local second
  second, bankrupt = finance.chargeCreditAndAssessSolvency(
    state, { "company:1", "company:2" }, ledger, {})
  equal(bankrupt, nil)
  equal(second["company:1"].insolventSettlements, 2)
  local third
  third, bankrupt = finance.chargeCreditAndAssessSolvency(
    state, { "company:1", "company:2" }, ledger, {})
  equal(third["company:1"].insolventSettlements, 3)
  equal(bankrupt, "company:1", "the third consecutive breach is bankruptcy")

  -- Interest compounds against the debtor, never against the rival.
  truthy(finance.networkAccount(state, "company:1").balance < overdrawn,
    "interest must accumulate on drawn credit")
  equal(finance.networkAccount(state, "company:2").balance, 0)
end)

test("loss conditions are match rules and elimination can be switched off", function()
  local function overdrawn(rules)
    local state = finance.newState()
    finance.initialiseNetworkAccounts(state, { "company:1" }, 0, { reason = "test" })
    truthy(finance.applyNetworkDelta(state, "company:1",
      -(finance.CREDIT.baseLimitCents * 4), { kind = "test" }))
    local ledger = { settlementCount = 1, companies = {} }
    local report, bankrupt
    for _ = 1, 6 do
      report, bankrupt = finance.chargeCreditAndAssessSolvency(
        state, { "company:1" }, ledger, {}, rules)
    end
    return report["company:1"], bankrupt
  end

  local defaultReport, defaultBankrupt = overdrawn(nil)
  equal(defaultBankrupt, "company:1", "the default ruleset still eliminates")

  local offReport, offBankrupt = overdrawn({ bankruptcyEnabled = false })
  equal(offBankrupt, nil, "bankruptcy off must never eliminate a company")
  truthy(offReport.breached, "debt is still recorded as a breach")
  truthy(offReport.interestCents > 0, "credit still costs interest when elimination is off")

  local zeroReport, zeroBankrupt = overdrawn({ insolventSettlements = 0 })
  equal(zeroBankrupt, nil, "a zero threshold also disables elimination")
  truthy(zeroReport.interestCents > 0)

  local harsh = overdrawn({ insolventSettlements = 1 })
  truthy(harsh.insolventSettlements >= 1)
  local _, harshBankrupt = overdrawn({ insolventSettlements = 1 })
  equal(harshBankrupt, "company:1", "a one-settlement threshold eliminates immediately")

  -- Credit profiles are rules too: a tighter line means a smaller limit.
  local tight = finance.creditLimit({ revenueCents = 0 }, 1, { creditBaseLimitCents = 1000 })
  equal(tight, 1000)
  truthy(tight < finance.creditLimit({ revenueCents = 0 }, 1, nil),
    "a tightened credit rule must reduce the available line")
end)

test("recovering before the third breach clears the countdown", function()
  local state = finance.newState()
  finance.initialiseNetworkAccounts(state, { "company:1" }, 0, { reason = "test" })
  local ledger = { settlementCount = 1, companies = {} }
  truthy(finance.applyNetworkDelta(state, "company:1",
    -(finance.CREDIT.baseLimitCents * 2), { kind = "test" }))
  local report = finance.chargeCreditAndAssessSolvency(state, { "company:1" }, ledger, {})
  equal(report["company:1"].insolventSettlements, 1)
  -- Repay everything; the very next settlement must forgive the countdown.
  local account = finance.networkAccount(state, "company:1")
  truthy(finance.applyNetworkDelta(state, "company:1", -account.balance, { kind = "test" }))
  local recovered, bankrupt = finance.chargeCreditAndAssessSolvency(
    state, { "company:1" }, ledger, {})
  equal(recovered["company:1"].insolventSettlements, 0, "solvency must be forgiving")
  equal(recovered["company:1"].breached, false)
  equal(bankrupt, nil)
end)

test("solvency state is digest-projected so peers agree on who is failing", function()
  local state = finance.newState()
  finance.initialiseNetworkAccounts(state, { "company:1" }, 0, { reason = "test" })
  truthy(finance.applyNetworkDelta(state, "company:1",
    -(finance.CREDIT.baseLimitCents * 2), { kind = "test" }))
  local before = hash.value(finance.networkDigestView(state))
  finance.chargeCreditAndAssessSolvency(state, { "company:1" },
    { settlementCount = 1, companies = {} }, {})
  local after = hash.value(finance.networkDigestView(state))
  truthy(before ~= after, "advancing a countdown must change the authored digest")
  local view = finance.networkDigestView(state)
  equal(view.accounts["company:1"].insolventSettlements, 1)
  truthy(view.accounts["company:1"].creditLimit > 0)
end)

test("bankruptcy verdict is authored and digest-projected", function()
  local state = finance.newState()
  finance.initialiseNetworkAccounts(state, { "company:1" }, 0, { reason = "test" })
  truthy(finance.applyNetworkDelta(state, "company:1",
    -(finance.CREDIT.baseLimitCents * 2), { kind = "test" }))
  local before = hash.value(finance.networkDigestView(state))
  local bankrupt
  for _ = 1, finance.CREDIT.insolventSettlements do
    _, bankrupt = finance.chargeCreditAndAssessSolvency(
      state, { "company:1" }, { settlementCount = 1, companies = {} }, {})
  end
  equal(bankrupt, "company:1")
  equal(finance.networkDigestView(state).bankruptCid, "company:1")
  truthy(hash.value(finance.networkDigestView(state)) ~= before,
    "bankruptcy verdict did not change the authored digest")
end)

test("development points accumulate, spend in whole buildings, and stay bounded", function()
  local worldState = {}
  local constants = world.TOWN_DEVELOPMENT
  -- A quiet corridor banks progress instead of losing it.
  local none = world.accumulateDevelopment(worldState, { ["town:a"] = 150 })
  equal(next(none), nil, "a trickle of demand must not yet buy a building")
  equal(worldState.townDevelopment.points["town:a"], 150)

  local due = world.accumulateDevelopment(worldState, { ["town:a"] = 300 })
  equal(due["town:a"], 1, "accumulated points buy exactly one building")
  equal(worldState.townDevelopment.points["town:a"], 50, "the remainder carries forward")

  -- A boom is capped so one settlement cannot flood a town.
  local boom = world.accumulateDevelopment(worldState, { ["town:a"] = 100000 })
  equal(boom["town:a"], constants.maxCallsPerSettle)
  truthy(worldState.townDevelopment.points["town:a"] <= constants.maxPointsCarried,
    "the accumulator must stay bounded")

  local repeated = world.accumulateDevelopment({}, { ["town:a"] = 800 })
  equal(repeated["town:a"], 2, "the same input always produces the same batch")
end)

test("ordered town development issues one native call per due building", function()
  local previousApi, previousGame = api, game
  local calls, toggles = {}, {}
  local buildingVector = newproxy(true)
  local buildingVectorMeta = getmetatable(buildingVector)
  buildingVectorMeta.__len = function() return 2 end
  buildingVectorMeta.__index = function() return nil end
  api = {
    type = {
      Vec2f = { new = function(x, y) return { x = x, y = y } end },
      ComponentType = { TOWN_BUILDING = 91 },
    },
    engine = {
      system = { townBuildingSystem = {
        getTown2BuildingMap = setmetatable({}, { __call = function()
          return { [71] = buildingVector }
        end }),
      } },
      forEachEntityWithComponent = function(visitor, componentType)
        equal(componentType, 91)
        visitor(701); visitor(999); visitor(702)
      end,
    },
    cmd = {
    make = { developTown = function(position) return { position = position } end },
    sendCommand = function(command, callback)
      calls[#calls + 1] = command.position
      if callback then callback(command, true) end
    end,
  } }
  game = { interface = {
    getEntity = function(id)
      if id == 71 then return { id = id, position = { 123.4, -56.7 } } end
      if id == 701 then return { id = id, town = 71 } end
      if id == 702 then return { id = id, town = 71 } end
      if id == 999 then return { id = id, town = 72, position = { 50, 60 } } end
      if id == 1701 then return { id = id, position = { 30, 40 } } end
      if id == 1702 then return { id = id, position = { 10, 20 } } end
    end,
    getConstructionEntity = function(id)
      if id == 701 then return 1701 end
      if id == 702 then return 1702 end
      return -1
    end,
    setTownDevelopmentActive = function(id, active)
      toggles[#toggles + 1] = { id = id, active = active }
    end,
  } }
  local registry = canonical.newState()
  registry.byCanonical["town:pre:alpha"] = { localId = 71, kind = "town" }
  registry.byLocal["71"] = "town:pre:alpha"
  local worldState = {
    townDevelopment = {
      schemaVersion = 1, enabled = true, points = {},
      cursor = { ["town:pre:alpha"] = 3 },
    },
  }
  local outcome = world.applyTownDevelopment(
    registry, { ["town:pre:alpha"] = 2 }, worldState)
  api, game = previousApi, previousGame
  equal(outcome.towns, 1)
  equal(outcome.calls, 2, "two due buildings means two native calls")
  equal(#calls, 2)
  equal(calls[1].x, 30)
  equal(calls[1].y, 40)
  equal(calls[2].x, 10)
  equal(calls[2].y, 20)
  equal(outcome.candidatePositions["town:pre:alpha"], 2)
  equal(outcome.positionDiagnostics["town:pre:alpha"].buildingIds, 0)
  equal(outcome.positionDiagnostics["town:pre:alpha"].componentScanVisited, 3)
  equal(outcome.positionDiagnostics["town:pre:alpha"].componentScanMatched, 2)
  equal(outcome.positionDiagnostics["town:pre:alpha"].componentPositionSources.construction, 2)
  equal(outcome.positionDiagnostics["town:pre:alpha"].usedFallback, false)
  equal(outcome.activated, 1)
  equal(outcome.refrozen, 1)
  equal(toggles[1].active, true)
  equal(toggles[2].active, false)
  equal(worldState.townDevelopment.cursor["town:pre:alpha"], 5,
    "the committed batch advances the authored position cursor")
  equal(#outcome.errors, 0)
end)

test("town development reports unmapped towns instead of guessing", function()
  local previousApi, previousGame = api, game
  api = { cmd = {
    make = { developTown = function(townId) return { townId = townId } end },
    sendCommand = function(_, callback) if callback then callback({}, true) end end,
  } }
  game = { interface = {} }
  local outcome = world.applyTownDevelopment(canonical.newState(), { ["town:missing"] = 1 })
  api, game = previousApi, previousGame
  equal(outcome.calls, 0)
  truthy(#outcome.errors == 1 and outcome.errors[1]:find("not mapped locally"),
    "an unmapped town must be reported, not silently developed")
end)

test("crowd icons bucket by magnitude", function()
  equal(guiView.crowdIcons(0), "")
  equal(guiView.crowdIcons(15), "·")
  equal(guiView.crowdIcons(45), "▪▪")
  equal(guiView.crowdIcons(120), "◼▪")
  equal(guiView.crowdIcons(1240), "██◼◼▪▪")
end)

test("cargo shares conserve demand and obey the fare-shock latch", function()
  local state = economy.newState()
  economy.upsertMarket(state, { cid = "market:freight", kind = "cargo", demand = 800 })
  economy.upsertService(state, { lineCid = "line:f1", marketCid = "market:freight",
    companyCid = "company:1", headwaySeconds = 3600, journeySeconds = 5400,
    fareCents = 700, capacity = 400, quality = 100, transfers = 0 })
  economy.upsertService(state, { lineCid = "line:f2", marketCid = "market:freight",
    companyCid = "company:2", headwaySeconds = 2700, journeySeconds = 4800,
    fareCents = 800, capacity = 400, quality = 100, transfers = 0 })
  local result
  for epoch = 1, 40 do
    result = economy.evaluateAll(state).markets["market:freight"]
    local total = result.outside
    for _, service in pairs(result.services) do total = total + service.allocated end
    equal(total + result.queued, result.demand,
      "cargo conservation broke at epoch " .. epoch)
  end
  local settled = state.services["line:f1"].sharePpm
  truthy(settled > 0, "freight service failed to earn share")
  economy.setFare(state, "line:f1", 5000)
  result = economy.evaluateAll(state).markets["market:freight"]
  equal(state.services["line:f1"].sharePpm, result.services["line:f1"].equilibriumPpm,
    "a cargo fare hike must adopt the lower equilibrium immediately")
  truthy(state.services["line:f1"].sharePpm < settled, "the hiked freight service kept its share")
end)

test("integer glide converges exactly without stalling", function()
  local state = marketState(1000)
  corridorService(state, "a", "company:1", {})
  corridorService(state, "b", "company:2", { fareCents = 1200 })
  local final
  for _ = 1, 400 do final = economy.evaluateAll(state).markets["market:a-b"] end
  for _, lineCid in ipairs({ "line:a", "line:b" }) do
    local service = final.services[lineCid]
    equal(service.sharePpm, service.equilibriumPpm,
      lineCid .. " stalled short of its exact integer equilibrium")
  end
end)

test("lagged crowding repels demand from an undersized service without oscillating", function()
  local state = marketState(1000)
  corridorService(state, "a", "company:1", { fareCents = 400, capacity = 100 })
  corridorService(state, "b", "company:2", { fareCents = 1200, capacity = 900 })
  local first = economy.evaluateAll(state).markets["market:a-b"]
  equal(first.services["line:a"].factors.crowdCostCents, 0, "crowding must lag one epoch")

  local result
  for _ = 1, 200 do result = economy.evaluateAll(state).markets["market:a-b"] end
  truthy(result.services["line:a"].factors.crowdCostCents > 0,
    "a full service must carry a crowding penalty")
  local shares = {}
  for epoch = 1, 20 do
    result = economy.evaluateAll(state).markets["market:a-b"]
    shares[epoch] = result.services["line:a"].sharePpm
  end
  local low, high = shares[1], shares[1]
  for _, share in ipairs(shares) do
    low, high = math.min(low, share), math.max(high, share)
  end
  -- One passenger of allocation quantum moves crowding by about a cent and
  -- the coupled equilibria by a few hundred ppm; a relay-style limit cycle
  -- would swing tens of thousands. Bound the dither at 0.1% of the market.
  truthy(high - low <= 1000, "crowded steady state oscillates beyond allocation-quantum dither")
end)

test("model evaluation is deterministic across independent replays", function()
  local function run()
    local state = marketState(1000)
    corridorService(state, "a", "company:1", {})
    corridorService(state, "b", "company:2", { fareCents = 800 })
    for _ = 1, 25 do economy.evaluateAll(state) end
    economy.setFare(state, "line:a", 700)
    for _ = 1, 25 do economy.evaluateAll(state) end
    return state
  end
  local first, second = run(), run()
  equal(hash.value(first.services), hash.value(second.services),
    "independent replays diverged in service stocks")
  equal(hash.value(first.lastResults), hash.value(second.lastResults),
    "independent replays diverged in results")
end)

test("authored hourly upkeep conserves the exact annual cost", function()
  local annual = economyCosts.vehicleAnnualUpkeepCents(7200000)
  equal(annual, 120000000,
    "the documented automatic running-cost ratio changed")
  local total, residual = 0, 0
  for _ = 1, economyCosts.HOURS_PER_YEAR do
    local charge
    charge, residual = economyCosts.hourlyCharge(annual, residual)
    total = total + charge
  end
  equal(total, annual, "hourly rounding lost or created annual vehicle upkeep")
  equal(residual, 0, "annual vehicle-upkeep residual did not close")

  local allocated = economyCosts.allocateCapital(
    { "edge:c", "edge:a", "edge:b", "edge:a" }, 100)
  equal(allocated["edge:a"], 34, "capital remainder was not canonically ordered")
  equal(allocated["edge:b"], 33)
  equal(allocated["edge:c"], 33)

  local wallet = economy.newState()
  local first, firstResid = economy.walletDeltaDollars(wallet, "company:1", -1)
  local second, secondResid = economy.walletDeltaDollars(wallet, "company:1", -99)
  local third, thirdResid = economy.walletDeltaDollars(wallet, "company:1", 199)
  local fourth, fourthResid = economy.walletDeltaDollars(wallet, "company:1", 1)
  equal(first, 0, "a one-cent loss was rounded into a one-dollar debit")
  equal(firstResid, -1)
  equal(second, -1)
  equal(secondResid, 0)
  equal(third, 1)
  equal(thirdResid, 99)
  equal(fourth, 1)
  equal(fourthResid, 0)
  equal(first + second + third + fourth, 1,
    "signed cent carry did not conserve the cumulative native-wallet delta")
end)

test("five-minute passenger accounting hits the playable payback envelope", function()
  local state = economy.newState()
  economy.upsertMarket(state, { cid = "market:balance", kind = "passenger",
    demand = 12000, gcOutsideCents = 100000000, thetaCents = 200 })
  economy.upsertService(state, { lineCid = "line:balance", marketCid = "market:balance",
    companyCid = "company:1", fareCents = 950, capacity = 320,
    headwaySeconds = 900, journeySeconds = 600, quality = 100,
    annualVehicleUpkeepCents = 120000000 })
  local allocated, gross, upkeep, net = 0, 0, 0, 0
  for _ = 1, 12 do
    local row = economy.evaluateAll(state).markets["market:balance"].services["line:balance"]
    allocated, gross = allocated + row.allocated, gross + row.grossRevenueCents
    upkeep, net = upkeep + row.vehicleUpkeepCents, net + row.netRevenueCents
  end
  equal(allocated, 320, "hourly bidirectional capacity was not conserved across 5m ticks")
  equal(gross, 304000000, "40-seat corridor no longer grosses $3.04m per authored hour")
  equal(upkeep, 40000000, "$1.2m native annual upkeep was not compressed to $400k/hour")
  equal(net, 264000000, "healthy passenger service left the intended payback envelope")
  equal(economyRevenue.defaultFareCents(3000, "passenger"), 950)
end)

test("save-owned economy difficulties scale revenue but not demand or upkeep", function()
  truthy(economy.validateDifficultyRule({ economyDifficulty = "easy",
    revenueMultiplierPpm = 1500000 }))
  local valid, difficultyError = economy.validateDifficultyRule({
    economyDifficulty = "hard", revenueMultiplierPpm = 1000000,
  })
  equal(valid, false)
  truthy(tostring(difficultyError):find("inconsistent", 1, true) ~= nil)
  local function run(key)
    local state = economy.newState()
    economy.setDifficulty(state, key)
    economy.upsertMarket(state, { cid = "market:difficulty", kind = "passenger",
      demand = 12000, gcOutsideCents = 100000000, thetaCents = 200 })
    economy.upsertService(state, { lineCid = "line:difficulty",
      marketCid = "market:difficulty", companyCid = "company:1",
      fareCents = 950, capacity = 320, headwaySeconds = 900,
      journeySeconds = 600, quality = 100,
      annualVehicleUpkeepCents = 120000000 })
    local allocated, rawGross, gross, upkeep = 0, 0, 0, 0
    for _ = 1, 12 do
      local row = economy.evaluateAll(state).markets["market:difficulty"]
        .services["line:difficulty"]
      allocated = allocated + row.allocated
      rawGross = rawGross + row.rawGrossRevenueCents
      gross = gross + row.grossRevenueCents
      upkeep = upkeep + row.vehicleUpkeepCents
    end
    return state, allocated, rawGross, gross, upkeep
  end
  local expected = {
    hard = 182400000, normal = 304000000,
    easy = 456000000, relaxed = 608000000,
  }
  for _, key in ipairs(economyDifficulty.ORDER) do
    local state, allocated, rawGross, gross, upkeep = run(key)
    equal(allocated, 320, key .. " changed service capacity or demand")
    equal(rawGross, 304000000, key .. " changed the fare-derived raw revenue")
    equal(gross, expected[key], key .. " applied the wrong revenue multiplier")
    equal(upkeep, 40000000, key .. " changed native-derived upkeep")
    equal(state.params.economyDifficulty, key)
    equal(state.params.revenueMultiplierPpm,
      economyDifficulty.PRESETS[key].revenueMultiplierPpm)
  end
  local first, resid = economyDifficulty.apply(1, 600000, 0)
  local second, finalResid = economyDifficulty.apply(1, 600000, resid)
  equal(first, 0)
  equal(second, 1)
  equal(finalResid, 200000,
    "difficulty residual did not conserve repeated sub-cent-scaled revenue")
end)

test("delivered demand grows canonical towns and refreshes every corridor", function()
  local function build()
    local state = economy.newState()
    economy.upsertMarket(state, {
      cid = "market:growth", kind = "passenger", demand = 533,
      gcOutsideCents = 100000000, thetaCents = 200,
      metadata = { townA = "town:a", townB = "town:b",
        townSizeA = 200, townSizeB = 200, corridorMeters = 3000 },
    })
    economy.upsertService(state, {
      lineCid = "line:growth", marketCid = "market:growth",
      companyCid = "company:1", fareCents = 950, capacity = 320,
      headwaySeconds = 900, journeySeconds = 600, quality = 100,
    })
    return state
  end
  local first, second = build(), build()
  local final
  for _ = 1, 12 do
    final = economy.evaluateAll(first)
    economy.evaluateAll(second)
  end
  equal(hash.value(first), hash.value(second),
    "canonical town growth was not deterministic")
  truthy(first.towns["town:a"].size > 200 and first.towns["town:b"].size > 200,
    "carried passengers did not grow the endpoint towns")
  truthy(first.markets["market:growth"].demand > 533,
    "town growth did not refresh future corridor demand")
  truthy(type(final.townGrowth) == "table"
      and type(final.townGrowth.towns["town:a"]) == "table",
    "settlement did not disclose its authored demographic transition")
  equal(first.markets["market:growth"].metadata.townSizeA,
    first.towns["town:a"].size)
end)

test("passenger revenue is paid once from completed synchronized legs", function()
  local state = marketState(12000)
  corridorService(state, "a", "company:1", { fareCents = 950, capacity = 320 })
  local snapshot = { schemaVersion = 1, presentationEpoch = 1, lines = {
    ["line:a"] = { deliveredPassengers = 40, earnedRevenueCents = 38000000 },
  } }
  local first = economy.evaluateAll(state, nil, snapshot)
    .markets["market:a-b"].services["line:a"]
  equal(first.delivered, 40)
  equal(first.grossRevenueCents, 38000000)
  local second = economy.evaluateAll(state, nil, snapshot)
    .markets["market:a-b"].services["line:a"]
  equal(second.delivered, 0, "an unchanged completion cursor paid passengers twice")
  equal(second.grossRevenueCents, 0, "an unchanged completion cursor created money")
  snapshot.lines["line:a"].deliveredPassengers = 39
  local ok, err = pcall(economy.evaluateAll, state, nil, snapshot)
  equal(ok, false, "a backwards passenger delivery cursor was accepted")
  truthy(tostring(err):find("moved backwards", 1, true) ~= nil)
end)

test("cargo baseline pays one thousand dollars per unit-kilometre", function()
  local state = economy.newState()
  economy.upsertMarket(state, { cid = "market:cargo-balance", kind = "cargo",
    demand = 4800, gcOutsideCents = 100000000, thetaCents = 200 })
  economy.upsertService(state, { lineCid = "line:cargo-balance",
    marketCid = "market:cargo-balance", companyCid = "company:1",
    fareCents = 1000, capacity = 4800, headwaySeconds = 300,
    journeySeconds = 1200, quality = 100,
    metadata = { distanceMeters = 50000 } })
  local row = economy.evaluateAll(state).markets["market:cargo-balance"]
    .services["line:cargo-balance"]
  equal(row.delivered, 400)
  equal(row.grossRevenueCents, 2000000000,
    "400 cargo units over 50km should gross $20m at baseline fare")
end)

test("scheduled settlements charge costs, allow losses, and reject atomically", function()
  local state = economy.newState()
  economy.startScheduler(state, 100, 3600)
  economy.upsertMarket(state, {
    cid = "market:loss", demand = 100, outsideWeight = 100,
  })
  economy.upsertService(state, {
    lineCid = "line:loss", marketCid = "market:loss", companyCid = "company:1",
    fareCents = 0, capacity = 100, headwaySeconds = 600,
    journeySeconds = 1200, quality = 100,
    annualVehicleUpkeepCents = 15000,
  })
  -- A $300 capital basis produces $30 nominal annual upkeep. With a three-hour
  -- competitive financial year, one authored hour costs exactly $10.
  economy.applyInfrastructureChange(state, "company:1", 0, 30000)
  local result = economy.evaluateAll(state, 3700)
  local company = result.companies["company:1"]
  equal(company.grossRevenueCents, 0)
  equal(company.vehicleUpkeepCents, 5000)
  equal(company.infrastructureUpkeepCents, 1000)
  equal(company.operatingCostCents, 6000)
  equal(company.netRevenueCents, -6000)
  equal(result.boundaryGameTimeSeconds, 3700)
  equal(economy.nextBoundary(state), 7300)
  truthy(economy.recordSettlement(state, result))
  equal(state.ledger.companies["company:1"].netRevenueCents, -6000,
    "a losing hour was clamped instead of debited")

  local before = hash.value(state)
  local ok, err = pcall(economy.evaluateAll, state, 9999)
  equal(ok, false, "an out-of-order economy boundary was accepted")
  truthy(tostring(err):find("next scheduled accounting interval", 1, true) ~= nil)
  equal(hash.value(state), before,
    "a rejected economy boundary mutated shares, residuals, or scheduler state")
end)

test("settlement ledger is idempotent and produces a scoreboard", function()
  local state = economy.newState()
  economy.upsertMarket(state, { cid = "market", demand = 100, outsideWeight = 100 })
  economy.upsertService(state, {
    lineCid = "line", marketCid = "market", companyCid = "company:1",
    fareCents = 500, capacity = 100, headwaySeconds = 600, journeySeconds = 1200, quality = 100,
  })
  local result = economy.evaluateAll(state)
  truthy(economy.recordSettlement(state, result))
  equal(economy.recordSettlement(state, result), false)
  local scores = economy.scoreboard(state, { ["company:1"] = { name = "One" } })
  equal(scores["company:1"].activeLines, 1)
  equal(scores["company:1"].marketsReached, 1)
  truthy(scores["company:1"].modelValueCents > 0)
end)

test("authoritative settlement results are validated before acceptance", function()
  local host = economy.newState()
  economy.upsertMarket(host, { cid = "market", demand = 100, outsideWeight = 100 })
  economy.upsertService(host, {
    lineCid = "line", marketCid = "market", companyCid = "company:1",
    fareCents = 500, capacity = 100, headwaySeconds = 600, journeySeconds = 1200, quality = 100,
  })
  local authoritative = economy.evaluateAll(util.deepCopy(host))
  truthy(economy.acceptAuthoritativeResults(host, authoritative))
  equal(host.epoch, 1)
  equal(host.markets.market.demandResid, 1200,
    "accepted results discarded the hourly-demand residual")

  local nextResults = economy.evaluateAll(util.deepCopy(host))
  nextResults.totalRevenueCents = nextResults.totalRevenueCents + 1
  equal(economy.acceptAuthoritativeResults(host, nextResults), false)
  equal(host.epoch, 1, "rejected results mutated state")
end)

test("network peer maps its original native player to its canonical company", function()
  local previousGame, previousApi = game, api
  local nextPlayer = 100
  game = {
    interface = {
      getPlayer = function() return 100 end,
      addPlayer = function() nextPlayer = nextPlayer + 1; return nextPlayer end,
      setName = function() end,
    },
  }
  api = { type = { ComponentType = {} } }
  local registry = canonical.newState()
  local worldState = { playerIds = {}, logicalOwners = {} }
  local ok, result = world.initialiseCompanies(worldState, registry, 2, {
    proxyMode = false,
    localCompanyIndex = 2,
  })
  truthy(ok, result)
  equal(result.companyPlayerIds[1], 101, "remote Company 1 should use an added local player")
  equal(result.companyPlayerIds[2], 100, "peer2 original player should represent canonical Company 2")
  equal(canonical.resolveLocal(registry, "company:1"), 101)
  equal(canonical.resolveLocal(registry, "company:2"), 100)
  nextPlayer = 100
  local hostRegistry = canonical.newState()
  local hostWorld = { playerIds = {}, logicalOwners = {} }
  local hostOk, hostResult = world.initialiseCompanies(hostWorld, hostRegistry, 2, {
    proxyMode = false,
    localCompanyIndex = 1,
  })
  nextPlayer = 100
  local proxyRegistry = canonical.newState()
  local proxyWorld = { playerIds = {}, logicalOwners = {} }
  local proxyOk, proxyResult = world.initialiseCompanies(
    proxyWorld, proxyRegistry, 2, {
      proxyMode = true,
      localCompanyIndex = 2,
    })
  api, game = previousApi, previousGame
  truthy(hostOk, hostResult)
  truthy(proxyOk, proxyResult)
  equal(hostResult.companyPlayerIds[1], 100)
  equal(hostResult.companyPlayerIds[2], 101)
  equal(proxyResult.localCompanyIndex, nil,
    "proxy company bootstrap leaked a non-authoritative local company index")
  equal(hash.value(canonical.digestView(hostRegistry)), hash.value(canonical.digestView(registry)),
    "peer-local player order changed the canonical registry digest")
end)

test("fresh network bootstrap rehomes saved manager entities to each peer company", function()
  local previousGame, previousApi = game, api
  local function bootstrap(localCompanyIndex)
    local owners = { [10] = 200 }
    local players = {
      [100] = { id = 100, type = "PLAYER" },
      [200] = { id = 200, type = "PLAYER" },
    }
    local nextPlayer = 300
    game = {
      interface = {
        getPlayer = function() return 100 end,
        getEntity = function(id)
          return players[id] or (id == 10 and { id = 10, type = "LINE" } or nil)
        end,
        addPlayer = function()
          nextPlayer = nextPlayer + 1
          players[nextPlayer] = { id = nextPlayer, type = "PLAYER" }
          return nextPlayer
        end,
        setName = function() end,
        setPlayer = function(id, playerId) owners[id] = playerId end,
      },
    }
    api = {
      type = { ComponentType = {
        PLAYER_OWNED = "PLAYER_OWNED", PLAYER = "PLAYER", LINE = "LINE",
      } },
      engine = {
        getComponent = function(id, kind)
          if kind == "PLAYER_OWNED" and owners[id] then return { player = owners[id] } end
          if kind == "PLAYER" and players[id] then return players[id] end
          if kind == "LINE" and id == 10 then return { stops = {} } end
          return nil
        end,
        forEachEntityWithComponent = function(callback, kind)
          if kind == "PLAYER_OWNED" then
            for id in pairs(owners) do callback(id) end
          end
        end,
      },
    }
    local registry = canonical.newState()
    local worldState = {
      playerIds = {}, logicalOwners = {},
      startingOwnershipHints = {
        schemaVersion = 1,
        companyPlayerIds = { 200, 100 },
        logicalOwners = { ["10"] = "company:1" },
      },
    }
    local ok, result = world.initialiseCompanies(worldState, registry, 2, {
      proxyMode = false,
      localCompanyIndex = localCompanyIndex,
      canonicalNetworkOwnership = true,
    })
    return ok, result, registry, worldState, owners[10]
  end

  local hostOk, host, hostRegistry, hostWorld, hostLineOwner = bootstrap(1)
  local clientOk, client, clientRegistry, clientWorld, clientLineOwner = bootstrap(2)
  api, game = previousApi, previousGame
  truthy(hostOk, host)
  truthy(clientOk, client)
  equal(host.companyPlayerIds[1], 100, "host UI player did not represent Company 1")
  equal(hostLineOwner, 100, "host line remained attached to the saved remote native player")
  equal(client.companyPlayerIds[1], 200, "client did not reuse the saved remote Company 1 player")
  equal(client.companyPlayerIds[2], 100, "client UI player did not represent Company 2")
  equal(clientLineOwner, 200, "client changed the correctly mapped remote Company 1 line")
  equal(host.nativeOwnershipProjection.projected, 1)
  equal(client.nativeOwnershipProjection.unchanged, 1)
  equal(hostWorld.logicalOwners["10"], "company:1")
  equal(clientWorld.logicalOwners["10"], "company:1")
  equal(hash.value(canonical.digestView(hostRegistry)), hash.value(canonical.digestView(clientRegistry)),
    "save/load native projection changed the canonical company digest")
end)

test("native company projection retains signals under logical custody", function()
  local ok, report = nativeOwnershipProjection.apply({
    logicalOwners = { ["11"] = "company:1" },
  }, { 100, 200 }, {
    listOwned = function() return { 11 } end,
    ownerOf = function() return 100 end,
    kindOf = function() return "edge_object" end,
    setPlayer = function() error("Build 35924 edge-object setter must not be called") end,
  })
  truthy(ok, report)
  equal(report.required, 1)
  equal(report.retainedEdges, 1)
  equal(report.projected, 0)
  equal(#report.failures, 0)
end)

local function financeHarness(failPlayer)
  local balances = { [1] = 800, [2] = 1000 }
  api = {
    type = {
      JournalEntryCategory = { new = function() return {} end },
      JournalEntry = { new = function() return {} end },
    },
    cmd = {
      make = {
        bookJournalEntry = function(player, journal)
          return { player = player, amount = journal.amount }
        end,
      },
      sendCommand = function(command)
        if command.player == failPlayer then error("injected journal failure") end
        balances[command.player] = balances[command.player] + command.amount
      end,
    },
  }
  return balances
end

test("proxy settlement restores the desk and applies only the gameplay delta", function()
  local previousApi = api
  local balances = financeHarness(nil)
  local state = finance.newState()
  local ok, record = finance.settleProxyTurn(state, 1, 2, 1000, 800, 2000, { source = "test" })
  api = previousApi
  truthy(ok)
  equal(record.nativeDelta, -200)
  equal(balances[1], 2000, "control desk baseline was not restored")
  equal(balances[2], 800, "company did not receive the turn cost")
  equal(state.transfers.totalAbsolute, 200)
end)

test("proxy settlement rolls the desk back when the company journal fails", function()
  local previousApi = api
  local balances = financeHarness(2)
  local state = finance.newState()
  local ok, record = finance.settleProxyTurn(state, 1, 2, 1000, 800, 2000, { source = "test" })
  api = previousApi
  equal(ok, false)
  truthy(record.rollbackOk, "control rollback was not reported")
  equal(balances[1], 800, "failed settlement did not restore the pre-settlement desk balance")
  equal(balances[2], 1000, "failed company journal changed the company balance")
  equal(state.transfers.failures, 1)
end)

test("canonical network accounts own balances and reconcile native wallet caches", function()
  local previousApi, previousGame = api, game
  local balances = financeHarness(nil)
  game = {
    interface = {
      getEntity = function(playerId)
        return balances[playerId] and { balance = balances[playerId], loan = 0 } or nil
      end,
    },
  }
  local state = finance.newState()
  finance.initialiseNetworkAccounts(state, { "company:1", "company:2" }, 1000, { reason = "test" })
  local applied, entry = finance.applyNetworkDelta(state, "company:1", -125, { kind = "proposal" })
  truthy(applied, entry)
  equal(finance.networkAccount(state, "company:1").balance, 875)
  equal(finance.networkDigestView(state).accounts["company:2"].balance, 1000)
  local reconciled, run = finance.reconcileNetworkAccounts(state, {
    ["company:1"] = { playerId = 1 },
    ["company:2"] = { playerId = 2 },
  }, { reason = "ordered-outcome" })
  local verified, verifyRun = finance.reconcileNetworkAccounts(state, {
    ["company:1"] = { playerId = 1 },
    ["company:2"] = { playerId = 2 },
  }, { reason = "later-update" })
  api, game = previousApi, previousGame
  truthy(reconciled, run)
  truthy(verified, verifyRun)
  equal(balances[1], 875, "company 1 native wallet did not follow the canonical debit")
  equal(balances[2], 1000, "company 2 native wallet changed without a canonical entry")
  equal(state.networkAccounts.reconciliation.commands, 1)
  equal(run.accounts["company:1"].error, nil,
    "successful native wallet reconciliation retained a false error")
  truthy(run.accounts["company:1"].commandIssued,
    "wallet correction was not explicitly reported as asynchronous")
  equal(run.accounts["company:1"].after, 800,
    "wallet reconciliation performed a forbidden immediate post-book read")
  truthy(verifyRun.accounts["company:1"].settledImmediately,
    "a later reconciliation pass did not observe the completed journal entry")
end)

test("network wallet reconciliation never reads a PLAYER after issuing a journal command", function()
  local previousApi, previousGame = api, game
  local balances = { [1] = 100, [2] = 200 }
  local mutationIssued = false
  api = {
    type = {
      JournalEntryCategory = { new = function() return {} end },
      JournalEntry = { new = function() return {} end },
    },
    cmd = {
      make = {
        bookJournalEntry = function(player, journal)
          return { player = player, amount = journal.amount }
        end,
      },
      sendCommand = function(command)
        balances[command.player] = balances[command.player] + command.amount
        mutationIssued = true
      end,
    },
  }
  game = {
    interface = {
      getEntity = function(playerId)
        assert(not mutationIssued,
          "Build 35924 PLAYER read occurred in the journal mutation window")
        return { balance = balances[playerId], loan = 0 }
      end,
    },
  }
  local state = finance.newState()
  finance.initialiseNetworkAccounts(state, { "company:1", "company:2" }, 500, { reason = "test" })
  local ok, run = finance.reconcileNetworkAccounts(state, {
    ["company:1"] = { playerId = 1 },
    ["company:2"] = { playerId = 2 },
  }, { reason = "mutation-window", companyCid = "company:2", tick = 10 })
  api, game = previousApi, previousGame
  truthy(ok, run)
  equal(balances[1], 100, "more than one native wallet was mutated in one update")
  equal(balances[2], 500, "preferred company wallet was not reconciled")
  truthy(run.accounts["company:1"].deferred,
    "the second native correction was not explicitly deferred")
  truthy(run.accounts["company:2"].commandIssued,
    "the preferred correction did not issue its journal command")
end)

test("file bridge signs, emits, verifies, and polls in sequence", function()
  local state = bridge.newState({ protocol = 1, root = tempRoot, peerId = "player1", sessionId = "test-session" })
  local ok, outbound = bridge.emit(state, "intent", { action = { type = "test.action" } }, 7)
  truthy(ok, outbound)
  equal(outbound.local_seq, 1)
  truthy(bridge.verify(outbound))

  local savedRemove, savedRename = os.remove, os.rename
  os.remove, os.rename = nil, nil
  local fallbackOk, fallbackOutbound = bridge.emit(state, "telemetry", { liveRuntimeFallback = true }, 8)
  os.remove, os.rename = savedRemove, savedRename
  truthy(fallbackOk, fallbackOutbound)
  equal(fallbackOutbound.local_seq, 2, "direct-write fallback sequence")
  local fallbackFile = assert(io.open(tempRoot .. "/game_outbox/000000000002.json", "rb"))
  local fallbackRaw = fallbackFile:read("*a")
  fallbackFile:close()
  local fallbackDecoded = json.decode(fallbackRaw)
  truthy(bridge.verify(fallbackDecoded), "direct-write fallback produced a valid envelope")

  local restarted = bridge.newState({
    protocol = 1, root = tempRoot, peerId = "player1", sessionId = "test-session",
  })
  local restartOk, restartOutbound = bridge.emit(restarted, "telemetry", { restarted = true }, 9)
  truthy(restartOk, restartOutbound)
  equal(restartOutbound.local_seq, 3, "fresh script state overwrote an existing outbox sequence")

  local network = bridge.newState({
    protocol = 1, root = tempRoot, peerId = "player1",
    sessionId = "test-session", startNetwork = true,
  })
  local heartbeatOk, heartbeatReason = bridge.emit(
    network, "clock_health", { effectiveSpeed = 3 }, 10)
  equal(heartbeatOk, false,
    "a disconnected network bridge persisted replaceable clock telemetry")
  truthy(tostring(heartbeatReason):find("coalesced", 1, true) ~= nil)
  equal(network.nextOutSeq, 1,
    "coalescing replaceable telemetry consumed the durable sequence space")
  equal(network.coalesced, 1)
  equal(network.coalescedByKind.clock_health, 1)

  local durableOk, durable = bridge.emit(
    network, "intent", { action = { type = "test.action" } }, 11)
  truthy(durableOk, durable)
  equal(durable.local_seq, 4,
    "a disconnected bridge dropped or overwrote a durable action")
  network.companion = {
    connected = true, role = "host", status = "running", outboxCursor = 4,
  }
  local syncOk, sync = bridge.emit(
    network, "vehicle_sync", { latest = true }, 12)
  truthy(syncOk, sync)
  equal(sync.local_seq, 5,
    "replaceable vehicle telemetry did not resume after reconnection")

  network.nextOutSeq = 300
  network.companion.outboxCursor = 0
  local overflowOk = bridge.emit(
    network, "vehicle_sync", { overloaded = true }, 13)
  equal(overflowOk, false,
    "replaceable telemetry exceeded the bounded disconnected backlog")
  equal(network.nextOutSeq, 300,
    "bounded telemetry coalescing created a numbered queue gap")
  equal(network.coalescedByKind.vehicle_sync, 1)

  local inbound = {
    protocol = 1,
    session = "test-session",
    seq = 1,
    kind = "commit",
    origin_peer = "player1",
    origin_local_seq = 1,
    tick = 7,
    payload = { action = { type = "test.action" } },
  }
  inbound.checksum = hash.value(inbound)
  local file = assert(io.open(tempRoot .. "/game_inbox/000000000001.json", "wb"))
  file:write(json.encode(inbound) .. "\n")
  file:close()
  local received = bridge.poll(state, 4)
  equal(#received, 1)
  equal(received[1].payload.action.type, "test.action")
  equal(state.nextInSeq, 2)

  state.nextOutSeq, state.nextInSeq = 99, 77
  state.emitted, state.received = 12, 34
  local changed = bridge.reconfigure(state, {
    protocol = 1, root = tempRoot .. "/recovery", peerId = "player2",
    sessionId = "recovered-session",
  }, true)
  truthy(changed, "bridge identity change was not detected")
  equal(state.nextOutSeq, 1, "recovery bridge kept the previous outbox cursor")
  equal(state.nextInSeq, 1, "recovery bridge kept the previous inbox cursor")
  equal(state.emitted, 0, "recovery bridge kept the previous emitted count")
  equal(state.received, 0, "recovery bridge kept the previous received count")
  equal(state.peerId, "player2")
  equal(state.sessionId, "recovered-session")
end)

test("file bridge uses the native asynchronous FIFO without simulation-thread files", function()
  local priorConfigure = rawget(_G, "tpf2mp_native_bridge_configure")
  local priorEmit = rawget(_G, "tpf2mp_native_bridge_emit")
  local priorTake = rawget(_G, "tpf2mp_native_bridge_take")
  local priorStatus = rawget(_G, "tpf2mp_native_bridge_status")
  local emitted, inbound = {}, {
    protocol = 1, session = "native-session", seq = 1, kind = "commit",
    origin_peer = "player1", origin_local_seq = 41, tick = 12,
    payload = { action = { type = "native.test" } },
  }
  inbound.checksum = hash.value(inbound)
  tpf2mp_native_bridge_configure = function(root, nextOut, nextIn)
    equal(root, tempRoot .. "/native-mock")
    equal(nextOut, "1")
    equal(nextIn, "1")
    return "A1|41"
  end
  tpf2mp_native_bridge_emit = function(sequence, raw)
    emitted[#emitted + 1] = { sequence = sequence, raw = raw }
    return "A1"
  end
  local takeCount = 0
  tpf2mp_native_bridge_take = function()
    takeCount = takeCount + 1
    if takeCount == 1 then return "I1|1|" .. json.encode(inbound) .. "\n" end
    return nil
  end
  tpf2mp_native_bridge_status = function()
    return '{"schemaVersion":1,"configured":true,"outboundQueued":0}'
  end

  local state = bridge.newState({
    protocol = 1, root = tempRoot .. "/native-mock",
    peerId = "player1", sessionId = "native-session",
  })
  local ok, envelope = bridge.emit(state, "intent", {
    action = { type = "native.test" },
  }, 12)
  truthy(ok, envelope)
  equal(envelope.local_seq, 41, "native configuration did not advance past durable residue")
  equal(emitted[1].sequence, "41")
  equal(json.decode(emitted[1].raw).checksum, envelope.checksum)
  local received = bridge.poll(state, 4)
  equal(#received, 1)
  equal(received[1].payload.action.type, "native.test")
  equal(state.nextInSeq, 2)
  truthy(bridge.isNative(state))
  local status = bridge.nativeStatus(state)
  truthy(status.active and status.configured and status.outboundQueued == 0)

  tpf2mp_native_bridge_configure = priorConfigure
  tpf2mp_native_bridge_emit = priorEmit
  tpf2mp_native_bridge_take = priorTake
  tpf2mp_native_bridge_status = priorStatus
end)

test("performance runtime schedules idle work and exposes bounded timings", function()
  local previousClock = rawget(_G, "tpf2mp_native_monotonic_us")
  local current = 1000
  tpf2mp_native_monotonic_us = function()
    current = current + 100
    return tostring(current)
  end
  local state = { tick = 0, probes = {} }
  local runtime = performanceRuntime.new({ getState = function() return state end })
  truthy(runtime.due("idle", 3), "first scheduled call must run")
  equal(runtime.due("idle", 3), false, "same-tick idle work ran twice")
  state.tick = 3
  truthy(runtime.due("idle", 3), "scheduled work did not wake at its stride")
  local invoked, value = runtime.run("measured", function() return "ok" end)
  truthy(invoked)
  equal(value, "ok")
  equal(state.probes.performance.tasks.measured.calls, 1)
  equal(state.probes.performance.tasks.measured.lastUs, 100)
  runtime.setNativeBridge({ active = true, outboundQueued = 2 })
  equal(state.probes.performance.nativeBridge.outboundQueued, 2)
  equal(state.probes.performance.nativeBridge.sampleTick, 3)
  tpf2mp_native_monotonic_us = previousClock
end)

test("performance runtime does not depend on the engine global unpack", function()
  local previousUnpack = rawget(_G, "unpack")
  unpack = nil
  local state = { tick = 0, probes = {} }
  local runtime = performanceRuntime.new({ getState = function() return state end })
  local invoked, first, second, third, fourth = runtime.run(
    "unpack-free", function(a, b, c) return a, b, nil, c end,
    "alpha", nil, "omega")
  unpack = previousUnpack
  truthy(invoked)
  equal(first, "alpha")
  equal(second, nil)
  equal(third, nil)
  equal(fourth, "omega")
end)

test("performance runtime forwards failures without packed hot-path values", function()
  local state = { tick = 0, probes = {} }
  local runtime = performanceRuntime.new({ getState = function() return state end })
  local invoked, message = runtime.run("failure", function(value)
    error("failed-" .. value)
  end, "cleanly")
  equal(invoked, false)
  truthy(tostring(message):find("failed%-cleanly") ~= nil)
  equal(state.probes.performance.tasks.failure.failures, 1)
end)

test("performance sampling removes hot-path clock observer overhead", function()
  local previousClock = rawget(_G, "tpf2mp_native_monotonic_us")
  local reads = 0
  tpf2mp_native_monotonic_us = function()
    reads = reads + 1
    return tostring(reads * 100)
  end
  local state = { tick = 0, probes = {} }
  local runtime = performanceRuntime.new({ getState = function() return state end })
  for _ = 1, 20 do truthy(runtime.run("sampled", function() return true end)) end
  local task = state.probes.performance.tasks.sampled
  equal(task.calls, 20)
  equal(task.measuredCalls, 6, "profiler did not use warmup-plus-strided sampling")
  equal(reads, 12, "profiler still called the native clock around every task")
  equal(task.averageUs, 100)
  tpf2mp_native_monotonic_us = previousClock
end)

test("GUI replay work index does not sort an unchanged idle history", function()
  local index = guiReplayWorkIndex.new()
  local container = { queued = 0, byId = {
    ["proposal:b"] = { status = "applied" },
    ["proposal:a"] = { status = "failed" },
  } }
  local issued = {}
  for _ = 1, 100 do equal(#index.candidates(container, issued), 0) end
  equal(index.status().rebuilds, 1, "idle GUI history was repeatedly re-sorted")
  container.byId["proposal:c"] = { status = "queued" }
  container.queued = 1
  equal(index.candidates(container, issued)[1], "proposal:c")
  issued["proposal:c"] = true
  equal(#index.candidates(container, issued), 0)
  container.byId["proposal:0"] = { status = "queued" }
  container.queued = 2
  equal(index.candidates(container, issued)[1], "proposal:0",
    "new replay work did not preserve sorted selection")
  equal(index.status().rebuilds, 3)
end)

test("engine active-record indexes sleep after proving an idle queue", function()
  local index = activeRecordIndex.new(function(record)
    return type(record) == "table" and record.status == "active"
  end)
  local container = { queued = 0, byId = { old = { status = "complete" } } }
  for _ = 1, 100 do equal(#index.candidates(container), 0) end
  equal(index.status().scans, 1, "idle engine records were scanned every update")
  container.byId.fresh = { status = "active" }
  container.queued = 1
  equal(index.candidates(container)[1], "fresh")
  container.byId.fresh.status = "complete"
  equal(#index.candidates(container), 0)
  local scans = index.status().scans
  for _ = 1, 100 do equal(#index.candidates(container), 0) end
  equal(index.status().scans, scans)
  container.byId.old.status = "active"
  index.invalidate()
  equal(index.candidates(container)[1], "old",
    "an explicit same-generation transition was not discovered")
end)

for _, item in ipairs(tests) do
  local ok, err = xpcall(item.fn, debug.traceback)
  if not ok then
    io.stderr:write("FAIL " .. item.name .. "\n" .. tostring(err) .. "\n")
    os.exit(1)
  end
  passed = passed + 1
  print("PASS " .. item.name)
end

print(string.format("Lua tests: %d/%d passed", passed, #tests))
