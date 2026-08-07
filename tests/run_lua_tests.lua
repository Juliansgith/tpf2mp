local project = assert(arg[1], "project root argument required"):gsub("\\", "/")
local tempRoot = assert(arg[2], "temporary bridge root required"):gsub("\\", "/")
package.path = project .. "/tpf2_mp_1/res/scripts/?.lua;" .. package.path

local json = require "tpf2_mp/json"
local hash = require "tpf2_mp/hash"
local util = require "tpf2_mp/util"
local canonical = require "tpf2_mp/canonical"
local proposalCodec = require "tpf2_mp/proposal_codec"
local operationCodec = require "tpf2_mp/operation_codec"
local guiLineCommandCodec = require "tpf2_mp/gui_line_command_codec"
local economy = require "tpf2_mp/economy"
local economyCosts = require "tpf2_mp/economy_costs"
local economyRevenue = require "tpf2_mp/economy_revenue"
local economyDifficulty = require "tpf2_mp/economy_difficulty"
local bridge = require "tpf2_mp/bridge"
local finance = require "tpf2_mp/finance"
local world = require "tpf2_mp/world"
local guiView = require "tpf2_mp/gui_view"
local presentation = require "tpf2_mp/presentation"
local passengerPresentation = require "tpf2_mp/passenger_presentation"
local passengerCosmetics = require "tpf2_mp/passenger_cosmetics"
local nativeHook = require "tpf2_mp/native_hook"
local nativeOwnershipProjection = require "tpf2_mp/native_ownership_projection"
local matchRuntimeModule = require "tpf2_mp/match_runtime"
local stationReadingModule = require "tpf2_mp/world_station_reading"

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
  }
  local loadConfigCounts = { [17] = { 1 }, [18] = { 4 }, [19] = { 1 } }
  return {
    find = function(name) return ids[name] end,
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
  local roadConfig = operationCodec.defaultVehicleConfig({
    "vehicle/bus/benz.mdl",
  }, { res = { modelRep = vehicleModelRepository() } })
  local roadTransaction = operationCodec.make("vehicle.buy", "company:2", {
    depotCid = "depot:pre:abc",
    config = roadConfig,
  })
  truthy(roadTransaction, "a valid non-rail vehicle resource was rejected")
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
  truthy(tostring(ordinaryError):match("engine%-thread"), ordinaryError)

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
  equal(snapshot.schemaVersion, 4)
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
  local first = world.mobilitySnapshot(registry)
  stopIndex = 2
  nativeUserStopped = true
  local second = world.mobilitySnapshot(registry)
  api, game = previousApi, previousGame
  equal(#first.vehicleLifecycle, 1)
  equal(first.vehicleLifecycle[1].vehicleParts, 2)
  equal(first.vehicleLifecycle[1].consistModels[2], "vehicle/waggon/open_1910.mdl")
  equal(first.vehicleLifecycle[1].requestedStopped, false)
  equal(first.vehicleLifecycleDigest, second.vehicleLifecycleDigest)
  equal(first.vehicleStopDiagnostics[1].nativeUserStopped, false)
  equal(second.vehicleStopDiagnostics[1].nativeUserStopped, true)
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
  equal(allocated, result.demand, "demand was not conserved")
  equal(result.services["line:a"].allocated, 17)
  equal(result.services["line:b"].allocated, 25)
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
    equal(total, lastResult.demand, "conservation broke at epoch " .. epoch)
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
  equal(migrated.version, 7)
  equal(migrated.params.alphaDownPm, 500)
  equal(migrated.services["line:a"].lastFareCents, nil)
  -- The version-4 market step must be passenger-equivalent: same wait weight and
  -- transfer time the version-3 evaluator hardcoded.
  local market = migrated.markets["market:a-b"]
  equal(market.kind, "passenger")
  equal(market.waitWeightPm, 2000)
  equal(market.transferSeconds, 480)
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
  truthy(sums[2] > sums[3], "capacity sums keep moving with the crowd policy")
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

test("initial checkpoint bootstraps only runnable pre-existing company lines", function()
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
  equal(queued, 1)
  equal(summary.queued, 1)
  equal(summary.skipped, 3)
  equal(summary.failed, 0)
  equal(#submitted, 1)
  equal(submitted[1].type, "line.register")
  equal(submitted[1].lineCid, "line:pre:own")
  equal(submitted[1].companyCid, "company:1")
  equal(diagnostics[#diagnostics].event, "existing-service-register-scan")
end)

test("consist transport facts read repository metadata fail-soft", function()
  local previousApi = api
  local models = {
    ["loco.mdl"] = { metadata = { transportVehicle = { topSpeed = 44,
      compartmentsList = { { loadConfigs = { { cargoEntries = { { capacity = 0 } } } } } } } } },
    ["coach.mdl"] = { metadata = { transportVehicle = { topSpeed = 50,
      compartmentsList = {
        { loadConfigs = { { cargoEntries = { { capacity = 40 }, { capacity = 40 } } } } },
        { loadConfigs = { { cargoEntries = { { capacity = 24 } } },
                          { cargoEntries = { { capacity = 80 } } } } },
      } } } },
  }
  local names = { "loco.mdl", "coach.mdl" }
  local indexByName = { ["loco.mdl"] = 1, ["coach.mdl"] = 2 }
  local byIndex = { models["loco.mdl"], models["coach.mdl"] }
  api = { res = { modelRep = {
    find = function(name) return indexByName[name] or -1 end,
    get = function(index) return byIndex[index] end,
  } } }
  local facts = world.consistTransportFacts(names)
  api = previousApi
  truthy(facts, "metadata-backed consist facts were not produced")
  -- coach: compartment one 80 seats, compartment two best config 80 seats.
  equal(facts.seats, 160)
  equal(facts.limitSpeedMs, 44, "the slowest part limits the consist")
  api = { res = {} }
  equal(world.consistTransportFacts(names), nil, "missing repository must fail soft")
  api = previousApi
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

local function passengerPresentationEconomy(kind, allocation)
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
  state.lastResults = { markets = {
    ["market:presentation"] = { services = {
      ["line:presentation"] = { allocated = allocation or 65 },
    } },
  }, companies = {} }
  return state
end

local function passengerRelease(vehicleCid, round, stopIndex)
  return {
    type = "vehicle.sync_release", vehicleCid = vehicleCid,
    lineCid = "line:presentation", round = round, stopIndex = stopIndex,
  }
end

test("passenger presentation conserves queues and loads across ordered releases", function()
  local economyState = passengerPresentationEconomy("passenger", 65)
  local state = passengerPresentation.newState()
  local ok, result = passengerPresentation.beginEpoch(state, economyState)
  truthy(ok, result)
  local line = state.lines["line:presentation"]
  equal(line.waitingAToB, 32)
  equal(line.waitingBToA, 33, "the odd passenger must stay in the ledger")
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

test("passenger presentation carries backlog, invalidates edited routes, and excludes cargo", function()
  local economyState = passengerPresentationEconomy("passenger", 65)
  local state = passengerPresentation.newState()
  truthy(passengerPresentation.beginEpoch(state, economyState))
  truthy(passengerPresentation.applyRelease(state, economyState,
    passengerRelease("vehicle:one", 1, 0), { owner = "company:1" }))

  economyState.epoch = 2
  economyState.lastResults.markets["market:presentation"].services
    ["line:presentation"].allocated = 20
  truthy(passengerPresentation.beginEpoch(state, economyState))
  local line = state.lines["line:presentation"]
  equal(line.waitingAToB, 10, "old queue plus new terminal demand was not carried")
  equal(line.waitingBToA, 43)
  equal(state.vehicles["vehicle:one"].aboard, 32,
    "settlement must not teleport a train empty")

  economyState.services["line:presentation"].metadata.stationGroupCids = {
    "station:a", "station:new-middle", "station:c",
  }
  truthy(passengerPresentation.reconcileService(state, economyState, "line:presentation"))
  line = state.lines["line:presentation"]
  equal(line.waitingAToB, 10)
  equal(line.waitingBToA, 10)
  equal(line.overflowTotal, 53, "edited-route queues must be accounted, not teleported")
  equal(state.vehicles["vehicle:one"].aboard, 0)
  equal(state.vehicles["vehicle:one"].discardedTotal, 32)

  local cargoEconomy = passengerPresentationEconomy("cargo", 65)
  local cargoState = passengerPresentation.newState()
  truthy(passengerPresentation.beginEpoch(cargoState, cargoEconomy))
  equal(next(cargoState.lines), nil, "cargo demand entered the passenger ledger")
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

test("native passenger cosmetics are telemetry-only and never issue a command", function()
  local previousApi = api
  local sent, made = 0, 0
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
  api = previousApi
  truthy(ok)
  equal(probe.nativeAboard, 1)
  equal(probe.nativeWaiting, 2)
  equal(probe.requestedAboard, 1200)
  equal(probe.requestedWaiting, 3400)
  equal(probe.appliedWrites, 0)
  equal(probe.targetWritesEnabled, false)
  equal(probe.targetAddressable, false)
  equal(made, 2, "the shape probe must only construct the two boolean variants")
  equal(sent, 0, "the unsafe untargeted debug command was issued")
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
  equal(presentation.scaledCapacity(640, skeleton), 10)
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
  equal(sent[1].values[1], 10, "640 residents become 10 under the skeleton policy")
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
    equal(total, result.demand, "cargo conservation broke at epoch " .. epoch)
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
  api, game = previousApi, previousGame
  truthy(hostOk, hostResult)
  equal(hostResult.companyPlayerIds[1], 100)
  equal(hostResult.companyPlayerIds[2], 101)
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
  api, game = previousApi, previousGame
  truthy(reconciled, run)
  equal(balances[1], 875, "company 1 native wallet did not follow the canonical debit")
  equal(balances[2], 1000, "company 2 native wallet changed without a canonical entry")
  equal(state.networkAccounts.reconciliation.commands, 1)
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
