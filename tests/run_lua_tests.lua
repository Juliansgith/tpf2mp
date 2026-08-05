local project = assert(arg[1], "project root argument required"):gsub("\\", "/")
local tempRoot = assert(arg[2], "temporary bridge root required"):gsub("\\", "/")
package.path = project .. "/tpf2_mp_1/res/scripts/?.lua;" .. package.path

local json = require "tpf2_mp/json"
local hash = require "tpf2_mp/hash"
local util = require "tpf2_mp/util"
local canonical = require "tpf2_mp/canonical"
local proposalCodec = require "tpf2_mp/proposal_codec"
local operationCodec = require "tpf2_mp/operation_codec"
local economy = require "tpf2_mp/economy"
local bridge = require "tpf2_mp/bridge"
local finance = require "tpf2_mp/finance"
local world = require "tpf2_mp/world"
local guiView = require "tpf2_mp/gui_view"
local nativeHook = require "tpf2_mp/native_hook"

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
        { stationGroupCid = "station_group:pre:a", station = 3, terminal = 4 },
      },
    },
  }))
  equal(#oneStop.data.line.stops, 1)
  truthy(operationCodec.validate(oneStop))

  local capturedArgs
  local materialised = assert(operationCodec.materialise(oneStop, {
    api = { type = { Line = { new = function() return {} end } } },
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
  equal(capturedArgs[1], 700)
  equal(capturedArgs[2].stops[1].stationGroup, 901)
  equal(capturedArgs[2].stops[1].station, 3)
  equal(capturedArgs[2].stops[1].terminal, 4)
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

local function railwayModelRepository()
  local ids = {
    ["vehicle/train/db_v100.mdl"] = 17,
    ["vehicle/waggon/open_1910.mdl"] = 18,
  }
  local loadConfigCounts = { [17] = { 1 }, [18] = { 4 } }
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

test("railway vehicle operations reject local ids and non-train resources", function()
  local config = operationCodec.defaultVehicleConfig({
    "vehicle/train/db_v100.mdl", "vehicle/waggon/open_1910.mdl",
  }, { res = { modelRep = railwayModelRepository() } })
  equal(config.vehicles[1].loadConfig[1], 0)
  equal(config.vehicles[2].loadConfig[1], 0)
  local transaction = assert(operationCodec.make("vehicle.buy", "company:2", {
    depotCid = "depot:pre:abc",
    config = config,
  }))
  truthy(operationCodec.validate(transaction))
  local invalid = util.deepCopy(config)
  invalid.vehicles[1].model = "vehicle/bus/benz.mdl"
  local rejected, err = operationCodec.make("vehicle.buy", "company:2", {
    depotCid = "depot:pre:abc",
    config = invalid,
  })
  equal(rejected, nil)
  truthy(tostring(err):match("railway model"))
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
    }, { res = { modelRep = railwayModelRepository() } }),
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
        modelRep = railwayModelRepository(),
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
  equal(snapshot.schemaVersion, 3)
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

test("vehicle lifecycle and route phase have separate canonical mobility digests", function()
  local previousApi, previousGame = api, game
  local stopIndex = 1
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
            userStopped = false,
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
  local second = world.mobilitySnapshot(registry)
  api, game = previousApi, previousGame
  equal(#first.vehicleLifecycle, 1)
  equal(first.vehicleLifecycle[1].vehicleParts, 2)
  equal(first.vehicleLifecycle[1].consistModels[2], "vehicle/waggon/open_1910.mdl")
  equal(first.vehicleLifecycleDigest, second.vehicleLifecycleDigest)
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
    truthy(service.allocated <= service.capacity, "capacity exceeded")
    allocated = allocated + service.allocated
  end
  equal(allocated, result.demand, "demand was not conserved")
  equal(result.services["line:a"].allocated, 200)
  equal(result.services["line:b"].allocated, 300)
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
  equal(migrated.version, 4)
  equal(migrated.params.alphaDownPm, 250)
  equal(migrated.services["line:a"].lastFareCents, nil)
  -- The version-4 step must be passenger-equivalent: same wait weight and
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

test("computed service facts derive journey, headway, and capacity from geometry", function()
  local previousGame = game
  local positions = {
    [11] = { x = 0, y = 0 },
    [12] = { x = 10000, y = 0 },
  }
  game = { interface = { getEntity = function(id)
    local p = positions[id]
    return p and { id = id, position = { p.x, p.y } } or nil
  end } }
  local facts = world.computedServiceFacts({ 11, 12 }, 2, { seats = 200, limitSpeedMs = 40 })
  game = previousGame
  truthy(facts, "computed facts require only positions and a consist")
  -- 10 km euclidean * 1.25 route factor = 12.5 km at 28 m/s sustained plus
  -- two 45 s dwells: journey 536 s; cycle 1312 s over two vehicles: 656 s.
  equal(facts.distanceMeters, 12500)
  equal(facts.journeySeconds, 536)
  equal(facts.headwaySeconds, 656)
  -- 5 departures per authored hour, two consists of 200 seats.
  equal(facts.capacity, 200 * 2 * 5)
  local repeatFacts
  game = { interface = { getEntity = function(id)
    local p = positions[id]
    return p and { id = id, position = { p.x, p.y } } or nil
  end } }
  repeatFacts = world.computedServiceFacts({ 11, 12 }, 2, { seats = 200, limitSpeedMs = 40 })
  game = previousGame
  equal(hash.value(facts), hash.value(repeatFacts), "computed facts must be repeatable")
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
  equal(boards["sg:alpha"].throughput, allocated)
  truthy(boards["sg:alpha"].waiting <= allocated, "momentary waiting cannot exceed epoch throughput")
  equal(boards["sg:alpha"].waiting, boards["sg:beta"].waiting, "same service, same board contribution")
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

test("departure slots are periodic, phased, and future-dated", function()
  local service = { lineCid = "line:slot-test", headwaySeconds = 600 }
  local slot = world.departureSlots(service, 5000)
  equal(slot.periodSeconds, 600)
  truthy(slot.phaseSeconds >= 0 and slot.phaseSeconds < 600, "phase must sit inside the period")
  truthy(slot.nextDepartureAt > 5000, "the next departure is in the future")
  truthy(slot.holdSeconds > 0 and slot.holdSeconds <= 600, "hold time is bounded by one period")
  local later = world.departureSlots(service, slot.nextDepartureAt)
  equal(later.nextDepartureAt, slot.nextDepartureAt + 600, "slots advance by exactly one period")
  local repeated = world.departureSlots(service, 5000)
  equal(repeated.phaseSeconds, slot.phaseSeconds, "phase must be a pure function of the line")
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
