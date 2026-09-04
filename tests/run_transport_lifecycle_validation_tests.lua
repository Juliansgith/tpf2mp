local root = assert(arg[1], "project root is required")
package.path = root .. "/tpf2_mp_1/res/scripts/?.lua;"
  .. root .. "/tpf2_mp_1/res/scripts/?/init.lua;" .. package.path

util = require "tpf2_mp/util"
local lifecycleModule = require "tpf2_mp/validation_transport_lifecycle"
local codec = require "tpf2_mp/proposal_codec"
local generatedTopology = require "tpf2_mp/construction_generated_topology"

game = { interface = {
  getHeight = function() return 7 end,
  getGameTime = function() return { date = { year = 1990 } } end,
} }
api = { res = { modelRep = {
  find = function() return 1 end,
  get = function()
    return { metadata = { transportVehicle = { compartments = {
      { loadConfigs = { {} } },
    } } } }
  end,
} } }

local function truthy(value, message)
  assert(value, message or "expected truthy value")
end

local function newDriver(carrier)
  local state = {
    bridge = { peerId = "player1" },
    validation = { values = {} },
    world = {
      proposalConsensus = { completed = 0, rejected = 0, failed = 0 },
      operationConsensus = { completed = 0, rejected = 0, failed = 0 },
      proposals = { byId = {} }, operations = { byId = {} },
    },
  }
  local checks, submissions, stage, finished = {}, {}, nil, nil
  local lastCheckpointId
  local deps = {
    getState = function() return state end,
    transition = function(value) stage = value end,
    check = function(name, passed, details)
      checks[name] = { passed = passed == true, details = details }
      assert(passed == true, "validation check failed: " .. tostring(name))
    end,
    submit = function(action)
      submissions[#submissions + 1] = action
      return { local_seq = #submissions }
    end,
    checkpoint = function(predicate)
      local record = { proposalId = lastCheckpointId, success = true, boundarySeq = 100 }
      if predicate(record) then return record end
    end,
    finish = function(boundary) finished = boundary end,
    nodePosition = function(cid)
      local positions = {
        ["node:pre:410b0cf7"] = { x = -1084, y = -1035, z = 8 },
        ["node:tram:1:a"] = { x = -1300, y = -910, z = 8 },
        ["node:tram:1:b"] = { x = -1300, y = -890, z = 8 },
        ["node:tram:2:a"] = { x = -1550, y = -910, z = 8 },
        ["node:tram:2:b"] = { x = -1550, y = -890, z = 8 },
        ["node:tram:helper"] = { x = -1084, y = -1035, z = 8 },
        ["node:tram:route:1"] = { x = -1036, y = -1028, z = 8 },
        ["node:tram:route:2"] = { x = -1092, y = -1036, z = 8 },
      }
      return positions[cid]
    end,
    terrainHeight = function() return 8 end,
    nodeTopology = function(cid)
      if cid ~= "node:pre:410b0cf7" and cid ~= "node:tram:helper" then return {} end
      return {
        { other = { x = -1082, y = -1047, z = 8 } },
        { other = { x = -1120, y = -1040, z = 8 } },
        { other = { x = -1050, y = -1030, z = 8 } },
      }
    end,
  }
  local options
  if carrier == "AIR" then
    options = {
      carrier = "AIR", prefix = "air-route",
      facilities = {
        { kind = "airport", x = -1400, y = -1400, year = 1990 },
        { kind = "airport", x = 1400, y = -1400, year = 1990 },
      },
      models = { "vehicle/plane/junkers_f_13_v2.mdl" },
    }
  else
    options = {
      carrier = "TRAM", prefix = "tram-route",
      facilities = {
        { kind = "tram_terminal", x = -1300, y = -900, year = 1990 },
        { kind = "tram_terminal", x = -1550, y = -900, year = 1990 },
      },
      tramApproachCid = "node:pre:410b0cf7",
      tramDepotEntrancePosition = { x = -1082, y = -1047, z = 8 },
      tramBranchSide = -1, tramRouteSpacing = 56, tramConnectorGap = 32,
      models = { "vehicle/tram/typ1_v2.mdl" },
    }
  end
  local runtime = lifecycleModule.new(deps, options)

  local function proposal(outputs, replayPath)
    local id = "proposal:test:" .. tostring(state.world.proposalConsensus.completed + 1)
    state.world.proposalConsensus.completed = state.world.proposalConsensus.completed + 1
    state.world.proposalConsensus.lastOutcome = { proposalId = id, success = true }
    state.world.proposals.byId[id] = { result = {
      outputs = outputs, constructionReplayPath = replayPath or "gui-build-proposal",
    } }
    lastCheckpointId = id
    truthy(runtime.maintain(stage), "proposal consensus stage was not consumed")
    truthy(runtime.maintain(stage), "proposal checkpoint stage was not consumed")
  end

  local function operation(kind, outputs, postcondition)
    local id = "operation:test:" .. tostring(state.world.operationConsensus.completed + 1)
    state.world.operationConsensus.completed = state.world.operationConsensus.completed + 1
    state.world.operationConsensus.lastOutcome = { operationId = id, success = true }
    state.world.operations.byId[id] = { result = {
      kind = kind, outputs = outputs or {}, postcondition = postcondition,
    } }
    lastCheckpointId = id
    truthy(runtime.maintain(stage), "operation consensus stage was not consumed")
    truthy(runtime.maintain(stage), "operation checkpoint stage was not consumed")
  end

  return {
    begin = runtime.begin,
    proposal = proposal,
    operation = operation,
    stage = function() return stage end,
    submissions = submissions,
    checks = checks,
    finished = function() return finished end,
    state = state,
  }
end

local airport = assert(lifecycleModule.facilityTransaction(
  "airport", 10, 20, "company:1", { year = 1990 }))
truthy(codec.validatePortable(airport), "airport validation transaction is not portable")
assert(airport.constructions[1].fileName == "station/air/airport.con")
assert(#airport.constructions[1].modules == 4)

local airfield = assert(lifecycleModule.facilityTransaction(
  "airfield", 10, 20, "company:1", { year = 1940 }))
truthy(codec.validatePortable(airfield), "airfield validation transaction is not portable")
assert(airfield.constructions[1].fileName == "station/air/airfield.con")
assert(#airfield.constructions[1].modules == 3)

local generatedRecord = {
  replayPath = "helper-fallback", transaction = airfield, localInputs = {},
}
truthy(generatedTopology.eligible(generatedRecord, codec),
  "isolated airfield helper fallback was not eligible")
local destructiveRecord = util.deepCopy(generatedRecord)
destructiveRecord.localInputs = { { kind = "construction", localId = 9 } }
assert(not generatedTopology.eligible(destructiveRecord, codec),
  "generated-topology fallback accepted an existing-world input")
local attestation = assert(generatedTopology.attest({ 1, 2 }, { 3 }, { 4 }, { 5, 6 }, {
  fingerprint = function(id, kind) return kind .. ":portable:" .. tostring(id % 2) end,
  inspectEdges = function() return { {
    localId = 3, carrier = "track", resourceIndex = 4, catenary = false,
    objects = {},
  } } end,
}))
assert(attestation.nodeCount == 2 and attestation.edgeCount == 1
  and attestation.edgeObjectCount == 1
  and attestation.removedSceneryCount == 2
  and type(attestation.digest) == "string")
assert(generatedTopology.deltaReady({}, { asset = 18, node = 0 }))
assert(not generatedTopology.deltaReady({}, { asset = 18, construction = 1 }))
assert(generatedTopology.removedAssetsSafe({ 5 }, {
  resolveCanonical = function() return nil end, logicalOwners = {}, pinnedCustody = {},
}))
assert(not generatedTopology.removedAssetsSafe({ 5 }, {
  resolveCanonical = function() return "asset:managed" end,
  logicalOwners = {}, pinnedCustody = {},
}))
local generatedBindings, generatedByLocal = {}, {}
local generatedBound = assert(generatedTopology.bindOutputs({
  eventId = "session:peer:7", companyCid = "company:1",
  nativeOwnerPlayerId = 100,
  transaction = { digest = "1234abcd" },
}, { 12, 11 }, { 22, 21 }, { 32, 31 }, {
  fingerprint = function(id, kind)
    if kind == "node" then return id == 11 and "a" or "b" end
    return kind == "edge" and "same-edge" or "same-object"
  end,
  resolveCanonical = function(kind, localId)
    return generatedByLocal[kind .. ":" .. tostring(localId)]
  end,
  createdId = function(kind, eventId, index)
    return kind .. ":event:" .. eventId .. ":" .. tostring(index)
  end,
  bind = function(cid, kind, localId, metadata)
    generatedBindings[cid] = { kind = kind, localId = localId, metadata = metadata }
    generatedByLocal[kind .. ":" .. tostring(localId)] = cid
    return true
  end,
  ownerOf = function() return nil end,
  logicalOwners = {}, pinnedCustody = {}, requestedPlayerId = 101,
}))
assert(#generatedBound == 6
  and generatedBound[1].localId == 11 and generatedBound[2].localId == 12
  and generatedBindings["edge:event:session:peer:7:1"].localId == 21
  and generatedBindings["edge_object:event:session:peer:7:2"].localId == 32,
  "generated topology was not bound in deterministic event-derived order")

local terminal = assert(lifecycleModule.facilityTransaction(
  "tram_terminal", 30, 40, "company:1", { year = 1990 }))
truthy(codec.validatePortable(terminal), "tram-terminal validation transaction is not portable")
assert(terminal.constructions[1].fileName == "station/street/modular_terminal.con")
assert(terminal.constructions[1].params.tramTrack == 2)
local tramNetwork = assert(lifecycleModule.tramNetworkTransaction({
  "node:pre:410b0cf7",
}, "company:1", {
  depotOrigin = { x = -1082, y = -1047, z = 8 },
  height = function() return 8 end,
  positions = {
    ["node:pre:410b0cf7"] = { x = -1084, y = -1035, z = 8 },
  },
  neighbours = {
    { other = { x = -1082, y = -1047, z = 8 } },
    { other = { x = -1120, y = -1040, z = 8 } },
    { other = { x = -1050, y = -1030, z = 8 } },
  },
  branchSide = -1, spacing = 56, gap = 32,
}))
truthy(codec.validatePortable(tramNetwork), "tram network transaction is not portable")
assert(#tramNetwork.nodes == 4 and #tramNetwork.edges == 4
  and #tramNetwork.edgeObjects.add == 2
  and tramNetwork.edges[1].node0.cid == "node:pre:410b0cf7"
  and tramNetwork.edges[1].resource.name == "street_depot/entrance_old.lua"
  and tramNetwork.edges[1].typeIndex == 0 and tramNetwork.edges[4].typeIndex == 0)
for _, edge in ipairs(tramNetwork.edges) do
  assert(edge.tramTrackType == codec.TRAM_TRACK_ELECTRIC,
    "electric validation tram route contains a non-electrified edge")
end
assert(tramNetwork.edgeObjects.add[1].model == "station/bus/small_mid.mdl"
  and tramNetwork.edgeObjects.add[1].category == 0
  and tramNetwork.edgeObjects.add[1].left == false
  and tramNetwork.edgeObjects.add[2].left == true)
assert(tramNetwork.nodes[1].position.x < -1084,
  "connected tram route did not branch away from the occupied approach axis")
local bareTramNetwork = assert(lifecycleModule.tramNetworkTransaction({
  "node:pre:410b0cf7",
}, "company:1", {
  depotOrigin = { x = -1082, y = -1047, z = 8 },
  height = function() return 8 end,
  positions = { ["node:pre:410b0cf7"] = { x = -1084, y = -1035, z = 8 } },
  neighbours = { { other = { x = -1082, y = -1047, z = 8 } } },
  spacing = 56, gap = 32, connectApproach = false, includeStops = false,
}))
assert(#bareTramNetwork.edgeObjects.add == 0)
assert(#bareTramNetwork.edges == 3
  and bareTramNetwork.edges[1].node0.slot == "node:1",
  "standalone tram route unexpectedly retained its orientation anchor")
for _, edge in ipairs(bareTramNetwork.edges) do
  assert(edge.tramTrackType == codec.TRAM_TRACK_ELECTRIC,
    "standalone validation tram route contains a non-electrified edge")
end
local tramStops = assert(lifecycleModule.tramStopTransaction(bareTramNetwork, {
  nodes = {
    ["node:1"] = "node:route:1", ["node:2"] = "node:route:2",
    ["node:3"] = "node:route:3", ["node:4"] = "node:route:4",
  },
  edges = {
    ["edge:1"] = "edge:route:1", ["edge:2"] = "edge:route:2",
    ["edge:3"] = "edge:route:3", ["edge:4"] = "edge:route:4",
  },
}, "company:1"))
truthy(codec.validatePortable(tramStops), "tram stop replacement is not portable")
assert(#tramStops.edges == 2 and #tramStops.edgeObjects.add == 2
  and #tramStops.remove.edges == 2
  and tramStops.edgeObjects.add[1].left == false
  and tramStops.edgeObjects.add[2].left == true
  and tramStops.edges[1].node0.cid == "node:route:1")
local tramConnector = assert(lifecycleModule.tramConnectorTransaction(
  "node:pre:410b0cf7", "node:tram:route:1", "company:1", { positions = {
    ["node:pre:410b0cf7"] = { x = -1084, y = -1035, z = 8 },
    ["node:tram:route:1"] = { x = -1036, y = -1028, z = 8 },
  } }))
truthy(codec.validatePortable(tramConnector), "tram connector transaction is not portable")
assert(#tramConnector.nodes == 0 and #tramConnector.edges == 1
  and tramConnector.edges[1].tramTrackType == codec.TRAM_TRACK_ELECTRIC)

local air = newDriver("AIR")
air.begin()
for index = 1, 2 do
  air.proposal({
    { kind = "construction", cid = "construction:air:" .. index },
    { kind = "station", cid = "station:air:" .. index },
    { kind = "station_group", cid = "station_group:air:" .. index },
    { kind = "depot", cid = "depot:air:" .. index },
  })
end
air.operation("line.create", { { kind = "line", cid = "line:air" } })
air.operation("vehicle.buy", { { kind = "vehicle", cid = "vehicle:air" } })
air.operation("vehicle.assign", {}, { lineCid = "line:air" })
assert(air.finished() == 100 and air.checks["air-route-vehicle-assigned"].passed)
assert(#air.submissions == 5, "air lifecycle did not submit two builds and three operations")

local tram = newDriver("TRAM")
tram.begin()
for index = 1, 2 do
  tram.proposal({
    { kind = "construction", cid = "construction:tram:" .. index },
    { kind = "station", cid = "station:tram:" .. index },
    { kind = "station_group", cid = "station_group:tram:" .. index },
    { kind = "node", cid = "node:tram:" .. index .. ":a" },
    { kind = "node", cid = "node:tram:" .. index .. ":b" },
  })
end
tram.proposal({
  { kind = "edge", slot = "edge:1", cid = "edge:tram:network:1" },
  { kind = "edge", slot = "edge:2", cid = "edge:tram:network:2" },
  { kind = "edge", slot = "edge:3", cid = "edge:tram:network:3" },
  { kind = "node", slot = "node:1", cid = "node:tram:route:1" },
  { kind = "node", slot = "node:2", cid = "node:tram:route:2" },
  { kind = "node", slot = "node:3", cid = "node:tram:route:3" },
  { kind = "node", slot = "node:4", cid = "node:tram:route:4" },
  { kind = "edge_object", cid = "edge_object:tram:stop:1" },
  { kind = "edge_object", cid = "edge_object:tram:stop:2" },
  { kind = "station", cid = "station:tram:stop:1" },
  { kind = "station", cid = "station:tram:stop:2" },
  { kind = "station_group", cid = "station_group:tram:stop:1" },
  { kind = "station_group", cid = "station_group:tram:stop:2" },
})
local tramRouteSubmission = tram.submissions[3]
assert(tramRouteSubmission and tramRouteSubmission.transaction)
for _, edge in ipairs(tramRouteSubmission.transaction.edges or {}) do
  assert(edge.tramTrackType == codec.TRAM_TRACK_ELECTRIC,
    "tram lifecycle submitted a non-electrified route edge")
end
local tramDepotSubmission = tram.submissions[4]
assert(tramDepotSubmission and tramDepotSubmission.transaction
    and tramDepotSubmission.transaction.edges[1].tramTrackType
      == codec.TRAM_TRACK_ELECTRIC,
  "tram lifecycle submitted a non-electrified depot approach")
tram.proposal({
  { kind = "construction", slot = "construction:1", cid = "construction:tram:depot" },
  { kind = "depot", slot = "depot:1", cid = "depot:tram" },
  { kind = "edge", slot = "edge:1", cid = "edge:tram:1" },
  { kind = "node", slot = "node:1", cid = "node:tram:1" },
  { kind = "node", slot = "node:helper:1", cid = "node:tram:helper" },
  { kind = "edge", slot = "edge:helper:1", cid = "edge:tram:helper" },
}, "helper-connected-depot")
tram.operation("line.create", { { kind = "line", cid = "line:tram" } })
tram.operation("vehicle.buy", { { kind = "vehicle", cid = "vehicle:tram" } })
tram.operation("vehicle.assign", {}, { lineCid = "line:tram" })
assert(tram.finished() == 100 and tram.checks["tram-route-vehicle-assigned"].passed)
assert(#tram.submissions == 7,
  "tram lifecycle did not submit terminals, route/stops, depot, line, buy, and assign")

print("PASS two-peer validation state machines cover airport/plane and tram lifecycles")
