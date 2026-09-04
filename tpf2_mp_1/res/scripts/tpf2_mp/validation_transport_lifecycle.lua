local proposalCodec = require "tpf2_mp/proposal_codec"
local constructionSpec = require "tpf2_mp/validation_construction"
local operationCodec = require "tpf2_mp/operation_codec"
local depotRuntime = require "tpf2_mp/validation_connected_road_depot_runtime"
local tramNetwork = require "tpf2_mp/validation_tram_network"
local util = require "tpf2_mp/util"

local M = {}

local function finite(value)
  value = tonumber(value)
  return value and value == value and value ~= math.huge and value ~= -math.huge
end

local function terrainHeight(x, y, override)
  if type(override) == "function" then return override(x, y) end
  local interface = game and game.interface or {}
  if type(interface.getHeight) ~= "function" then return nil end
  local ok, value = pcall(interface.getHeight, { x, y })
  return ok and tonumber(value) or nil
end

local function tramTerminalSpec(year, seed)
  local prefix = "station/street/"
  return {
    fileName = prefix .. "modular_terminal.con",
    params = {
      year = year, seed = seed, templateIndex = 1,
      platL = 1, platR = 1, length = 0, length2 = 0,
      tramTrack = 2, tramTrackType = 0, paramX = 0, paramY = 0,
      modules = {
        [20009900] = { name = prefix .. "passenger_platform.module", variant = 0 },
        [20010000] = { name = prefix .. "passenger_platform.module", variant = 0 },
        [20015503] = { name = prefix .. "entrance_exit.module", variant = 0 },
      },
    },
  }
end

function M.facilityTransaction(kind, x, y, companyCid, options)
  options = options or {}
  x, y = tonumber(x), tonumber(y)
  if not finite(x) or not finite(y) then return nil, "facility coordinates are invalid" end
  local z = terrainHeight(x, y, options.height)
  if not finite(z) then return nil, "facility terrain height is unavailable" end
  local year = math.floor(tonumber(options.year) or constructionSpec.year())
  local spec
  if kind == "tram_terminal" then
    spec = tramTerminalSpec(year, math.floor(tonumber(options.seed) or 0))
  else
    spec = constructionSpec.spec(kind, year)
  end
  if type(spec) ~= "table" then return nil, "unsupported validation facility " .. tostring(kind) end
  local raw = {
    __observedCost = math.floor(tonumber(options.cost) or 0),
    proposal = {
      addedNodes = {}, addedSegments = {}, edgesToRemove = {}, nodesToRemove = {},
      edgeObjectsToAdd = {}, edgeObjectsToRemove = {},
    },
    __constructionAdditions = {{
      fileName = spec.fileName,
      transf = { 1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1, 0, x, y, z, 1 },
      params = util.deepCopy(spec.params or {}),
    }},
    __constructionRemovals = {},
  }
  return proposalCodec.normalise(raw, companyCid, {
    resourceName = options.resourceName,
  })
end

function M.tramNetworkTransaction(depotNodeCids, companyCid, options)
  return tramNetwork.transaction(depotNodeCids, companyCid, options)
end

function M.tramConnectorTransaction(approachCid, routeStartCid, companyCid, options)
  return tramNetwork.connectorTransaction(approachCid, routeStartCid, companyCid, options)
end

function M.tramStopTransaction(routeTransaction, bindings, companyCid)
  return tramNetwork.stopTransaction(routeTransaction, bindings, companyCid)
end

local function outputsOf(result, kind)
  local values = {}
  for _, output in ipairs(type(result) == "table" and result.outputs or {}) do
    if output.kind == kind and type(output.cid) == "string" then
      values[#values + 1] = output.cid
    end
  end
  table.sort(values)
  return values
end

local function outputBySlot(result, kind, slot)
  for _, output in ipairs(type(result) == "table" and result.outputs or {}) do
    if output.kind == kind and output.slot == slot and type(output.cid) == "string" then
      return output.cid
    end
  end
  return nil
end

local function changed(consensus, baseline)
  return (consensus.completed or 0) > (baseline.completed or 0)
    or (consensus.rejected or 0) > (baseline.rejected or 0)
    or (consensus.failed or 0) > (baseline.failed or 0)
end

function M.new(deps, options)
  options = options or {}
  local getState = assert(deps.getState, "transport lifecycle validation state is required")
  local transition = assert(deps.transition, "transport lifecycle transition is required")
  local check = assert(deps.check, "transport lifecycle check is required")
  local submit = assert(deps.submit, "transport lifecycle submit is required")
  local checkpoint = assert(deps.checkpoint, "transport lifecycle checkpoint is required")
  local finish = assert(deps.finish, "transport lifecycle finish is required")
  local resourceName = deps.resourceName
  local carrier = assert(options.carrier, "transport lifecycle carrier is required")
  local prefix = assert(options.prefix, "transport lifecycle prefix is required")
  local patternPrefix = prefix:gsub("(%W)", "%%%1")
  local key = prefix:gsub("[^%w]", "_")
  local facilities = assert(options.facilities, "transport lifecycle facilities are required")
  local models = assert(options.models, "transport lifecycle vehicle models are required")
  local queueLine, queueBuy, queueAssign, queueTramNetwork, queueTramStops

  local tramDepot
  local tramDepotFixtureOptions
  if carrier == "TRAM" then
    local tramDeps = {}
    for name, value in pairs(deps) do tramDeps[name] = value end
    tramDeps.validationKey = key .. "TramDepot"
    tramDeps.stagePrefix = prefix .. "-tram-depot"
    tramDeps.checkPrefix = prefix .. "-tram-depot"
    tramDepotFixtureOptions = {
      fileName = "depot/tram_depot_era_a.con",
      params = { tramCatenary = 1 },
      typeIndex = -1,
      -- The validation fleet is electrically powered. Build 35924 accepts the
      -- topology with plain rails but then rejects SetLine because the depot
      -- cannot route that vehicle onto a non-electrified approach.
      tramTrackType = proposalCodec.TRAM_TRACK_ELECTRIC,
      connectionResourceIndex = 15,
      connectionResourceName = "standard/country_small_new.lua",
      -- Leave a straight segment beyond the construction-generated helper
      -- road.  The stock tram depot's internal helper is longer than the
      -- twelve-metre entrance captured from the road-depot fixture; placing
      -- the root at that original distance makes the derived final segment
      -- point backwards and BuildProposal rejects it.  This bounded gap keeps
      -- the complete rigid construction behind the route endpoint and gives
      -- the topology-only repair an unambiguous forward connector.
      connectionGap = tonumber(options.tramDepotConnectionGap) or 24,
      terrainHeight = function(x, y)
        return terrainHeight(x, y, deps.terrainHeight)
      end,
    }
    tramDeps.fixtureOptions = tramDepotFixtureOptions
    tramDeps.afterCheckpoint = function(depotCid, _, _, helperNodeCid)
      local state = getState()
      state.validation.values[key .. "DepotCid"] = depotCid
      state.validation.values[key .. "TramApproachCid"] = helperNodeCid
      queueLine()
    end
    tramDepot = depotRuntime.new(tramDeps)
  end

  local function queueFacility(index)
    local state = getState()
    local consensus = state.world.proposalConsensus
    state.validation.values[key .. "FacilityIndex"] = index
    state.validation.values[key .. "FacilityBaseline"] = {
      completed = consensus.completed or 0,
      rejected = consensus.rejected or 0,
      failed = consensus.failed or 0,
    }
    if state.bridge.peerId == "player1" then
      local item = facilities[index]
      local transaction, transactionError = M.facilityTransaction(
        item.kind, item.x, item.y, "company:1", {
          year = item.year, seed = index, resourceName = resourceName,
        })
      check(prefix .. "-facility-transaction-valid-" .. tostring(index),
        transaction ~= nil, { error = transactionError,
          digest = transaction and transaction.digest or nil, kind = item.kind })
      local result = submit({ type = "proposal.prepare", transaction = transaction },
        prefix .. "-facility-" .. tostring(index) .. "-queued")
      state.validation.values[key .. "FacilityLocalSeq"] = result and result.local_seq
    end
    transition("wait-for-" .. prefix .. "-facility-" .. tostring(index) .. "-consensus")
  end

  local function queueOperation(phase, makeTransaction)
    local state = getState()
    local consensus = state.world.operationConsensus
    state.validation.values[key .. "OperationPhase"] = phase
    state.validation.values[key .. "OperationBaseline"] = {
      completed = consensus.completed or 0,
      rejected = consensus.rejected or 0,
      failed = consensus.failed or 0,
    }
    if state.bridge.peerId == "player1" then
      local transaction, transactionError = makeTransaction()
      check(prefix .. "-" .. phase .. "-transaction-valid", transaction ~= nil, {
        error = transactionError, digest = transaction and transaction.digest or nil,
      })
      local result = submit({ type = "operation.execute", transaction = transaction },
        prefix .. "-" .. phase .. "-queued")
      state.validation.values[key .. "OperationLocalSeq"] = result and result.local_seq
    end
    transition("wait-for-" .. prefix .. "-" .. phase .. "-consensus")
  end

  queueLine = function()
    queueOperation("line-create", function()
      local values = getState().validation.values
      return operationCodec.make("line.create", "company:1", {
        name = carrier == "AIR" and "TPF2MP automated air route"
          or "TPF2MP automated tram route",
        color = carrier == "AIR" and { r = 1000, g = 500, b = 0 }
          or { r = 250, g = 250, b = 1000 },
        line = operationCodec.defaultLine(values[key .. "StationGroupCids"]),
      })
    end)
  end

  queueBuy = function()
    queueOperation("vehicle-buy", function()
      local config, configError
      for _, model in ipairs(models) do
        config, configError = operationCodec.defaultVehicleConfig({ model }, api)
        if config then break end
      end
      if not config then return nil, configError end
      return operationCodec.make("vehicle.buy", "company:1", {
        depotCid = getState().validation.values[key .. "DepotCid"], config = config,
      })
    end)
  end

  queueAssign = function()
    queueOperation("vehicle-assign", function()
      local values = getState().validation.values
      return operationCodec.make("vehicle.assign", "company:1", {
        targetCid = values[key .. "VehicleCid"],
        lineCid = values[key .. "LineCid"], stopIndex = -1,
      })
    end)
  end

  queueTramNetwork = function()
    local state = getState()
    local consensus = state.world.proposalConsensus
    state.validation.values[key .. "TramNetworkBaseline"] = {
      completed = consensus.completed or 0, rejected = consensus.rejected or 0,
      failed = consensus.failed or 0,
    }
    if state.bridge.peerId == "player1" then
      local approachCid = state.validation.values[key .. "TramApproachCid"]
        or options.tramApproachCid or "node:pre:410b0cf7"
      local cids = { approachCid }
      local positions, positionError = tramNetwork.resolvePositions(
        state, cids, deps.nodePosition)
      local neighbours = tramNetwork.resolveNeighbours(
        state, approachCid, deps.nodeTopology)
      local transaction, transactionError, geometry
      if positions then
        transaction, transactionError, geometry = M.tramNetworkTransaction(
          cids, "company:1", {
            positions = positions,
            neighbours = neighbours,
            depotOrigin = options.tramDepotEntrancePosition,
            branchSide = options.tramBranchSide,
            spacing = options.tramRouteSpacing,
            gap = options.tramConnectorGap,
            connectApproach = false,
            includeStops = true,
            height = function(x, y) return terrainHeight(x, y, deps.terrainHeight) end,
          })
      else
        transactionError = positionError
      end
      check(prefix .. "-tram-network-transaction-valid", transaction ~= nil,
        { error = transactionError, digest = transaction and transaction.digest or nil,
          geometry = geometry })
      state.validation.values[key .. "TramNetworkTransaction"] =
        transaction and util.deepCopy(transaction) or nil
      submit({ type = "proposal.prepare", transaction = transaction },
        prefix .. "-tram-network-queued")
    end
    transition("wait-for-" .. prefix .. "-tram-network-consensus")
  end

  queueTramStops = function()
    local state = getState()
    local consensus = state.world.proposalConsensus
    state.validation.values[key .. "TramStopsBaseline"] = {
      completed = consensus.completed or 0, rejected = consensus.rejected or 0,
      failed = consensus.failed or 0,
    }
    if state.bridge.peerId == "player1" then
      local values = state.validation.values
      local transaction, transactionError = M.tramStopTransaction(
        values[key .. "TramNetworkTransaction"],
        values[key .. "TramRouteBindings"], "company:1")
      check(prefix .. "-tram-stops-transaction-valid", transaction ~= nil, {
        error = transactionError, digest = transaction and transaction.digest or nil,
      })
      submit({ type = "proposal.prepare", transaction = transaction },
        prefix .. "-tram-stops-queued")
    end
    transition("wait-for-" .. prefix .. "-tram-stops-consensus")
  end

  local function begin()
    local state = getState()
    state.validation.values[key .. "StationGroupCids"] = {}
    state.validation.values[key .. "FacilityProposalIds"] = {}
    state.validation.values[key .. "FacilityNodeCids"] = {}
    queueFacility(1)
  end

  local function maintain(stage)
    if tramDepot and tramDepot.maintain(stage) then return true end
    local state = getState()
    local facilityIndex = tonumber(tostring(stage):match(
      "^wait%-for%-" .. patternPrefix .. "%-facility%-(%d+)%-consensus$"))
    if facilityIndex then
      local consensus = state.world.proposalConsensus
      if not changed(consensus, state.validation.values[key .. "FacilityBaseline"] or {}) then
        return true
      end
      local outcome = consensus.lastOutcome
      local record = outcome and state.world.proposals.byId[outcome.proposalId] or nil
      local result = record and record.result or nil
      local stationGroups = outputsOf(result, "station_group")
      local depots = outputsOf(result, "depot")
      local nodes = outputsOf(result, "node")
      check(prefix .. "-facility-physical-consensus-" .. tostring(facilityIndex),
        outcome and outcome.success == true, outcome)
      check(prefix .. "-facility-created-station-group-" .. tostring(facilityIndex),
        #stationGroups == 1, { stationGroups = stationGroups, result = result })
      local groups = state.validation.values[key .. "StationGroupCids"]
      groups[#groups + 1] = stationGroups[1]
      state.validation.values[key .. "FacilityNodeCids"][facilityIndex] = nodes
      if carrier == "TRAM" then
        check(prefix .. "-facility-created-road-endpoints-" .. tostring(facilityIndex),
          #nodes == 2, { nodes = nodes, result = result })
      end
      if carrier == "AIR" and facilityIndex == 1 then
        check(prefix .. "-facility-created-aircraft-depot", #depots >= 1,
          { depots = depots, result = result })
        state.validation.values[key .. "DepotCid"] = depots[1]
      end
      state.validation.values[key .. "FacilityProposalIds"][facilityIndex] =
        outcome and outcome.proposalId or nil
      transition("wait-for-" .. prefix .. "-facility-" .. tostring(facilityIndex)
        .. "-checkpoint")
      return true
    end

    facilityIndex = tonumber(tostring(stage):match(
      "^wait%-for%-" .. patternPrefix .. "%-facility%-(%d+)%-checkpoint$"))
    if facilityIndex then
      local wanted = state.validation.values[key .. "FacilityProposalIds"][facilityIndex]
      local agreed = checkpoint(function(record)
        return wanted ~= nil and tostring(record.proposalId or "") == tostring(wanted)
      end)
      if not agreed then return true end
      check(prefix .. "-facility-checkpoint-consensus-" .. tostring(facilityIndex),
        agreed.success == true, agreed)
      if facilityIndex < #facilities then
        queueFacility(facilityIndex + 1)
      elseif carrier == "TRAM" then
        queueTramNetwork()
      else
        queueLine()
      end
      return true
    end

    if stage == "wait-for-" .. prefix .. "-tram-network-consensus" then
      local consensus = state.world.proposalConsensus
      if not changed(consensus,
          state.validation.values[key .. "TramNetworkBaseline"] or {}) then return true end
      local outcome = consensus.lastOutcome
      local record = outcome and state.world.proposals.byId[outcome.proposalId] or nil
      local result = record and record.result or nil
      local edges = outputsOf(result, "edge")
      local nodes = outputsOf(result, "node")
      local objects = outputsOf(result, "edge_object")
      local stationGroups = outputsOf(result, "station_group")
      check(prefix .. "-tram-network-physical-consensus",
        outcome and outcome.success == true, outcome)
      check(prefix .. "-tram-network-created-routable-edges", #edges == 3,
        { edges = edges, expected = 3, result = result })
      check(prefix .. "-tram-network-created-route-nodes", #nodes == 4,
        { nodes = nodes, result = result })
      check(prefix .. "-tram-network-created-curb-stops", #objects == 2,
        { objects = objects, result = result })
      check(prefix .. "-tram-network-created-station-groups", #stationGroups == 2,
        { stationGroups = stationGroups, result = result })
      state.validation.values[key .. "StationGroupCids"] = stationGroups
      local routeBindings = { nodes = {}, edges = {} }
      for index = 1, 4 do
        routeBindings.nodes["node:" .. tostring(index)] =
          outputBySlot(result, "node", "node:" .. tostring(index))
      end
      for index = 1, 3 do
        routeBindings.edges["edge:" .. tostring(index)] =
          outputBySlot(result, "edge", "edge:" .. tostring(index))
      end
      state.validation.values[key .. "TramRouteBindings"] = routeBindings
      state.validation.values[key .. "RouteStartCid"] =
        outputBySlot(result, "node", "node:1")
      state.validation.values[key .. "RouteNextCid"] =
        outputBySlot(result, "node", "node:2")
      check(prefix .. "-tram-network-bound-route-start",
        type(state.validation.values[key .. "RouteStartCid"]) == "string"
          and type(state.validation.values[key .. "RouteNextCid"]) == "string", result)
      state.validation.values[key .. "TramNetworkProposalId"] =
        outcome and outcome.proposalId or nil
      transition("wait-for-" .. prefix .. "-tram-network-checkpoint")
      return true
    end
    if stage == "wait-for-" .. prefix .. "-tram-network-checkpoint" then
      local wanted = state.validation.values[key .. "TramNetworkProposalId"]
      local agreed = checkpoint(function(record)
        return wanted ~= nil and tostring(record.proposalId or "") == tostring(wanted)
      end)
      if not agreed then return true end
      check(prefix .. "-tram-network-checkpoint-consensus", agreed.success == true, agreed)
      local values = state.validation.values
      local routeStartCid = values[key .. "RouteStartCid"]
      local routeNextCid = values[key .. "RouteNextCid"]
      local positions, positionError = tramNetwork.resolvePositions(
        state, { routeStartCid, routeNextCid }, deps.nodePosition)
      local startPosition = positions and positions[routeStartCid] or nil
      local nextPosition = positions and positions[routeNextCid] or nil
      local routeTangent = startPosition and nextPosition and {
        x = nextPosition.x - startPosition.x,
        y = nextPosition.y - startPosition.y,
        z = nextPosition.z - startPosition.z,
      } or nil
      check(prefix .. "-tram-depot-route-anchor-available",
        type(routeStartCid) == "string" and type(startPosition) == "table"
          and type(routeTangent) == "table", {
          routeStartCid = routeStartCid, position = startPosition,
          routeNextCid = routeNextCid, tangent = routeTangent, error = positionError,
        })
      tramDepotFixtureOptions.connectNodeCid = routeStartCid
      tramDepotFixtureOptions.connectPosition = util.deepCopy(startPosition)
      tramDepotFixtureOptions.connectTangent = util.deepCopy(routeTangent)
      tramDepot.begin()
      return true
    end

    if stage == "wait-for-" .. prefix .. "-tram-stops-consensus" then
      local consensus = state.world.proposalConsensus
      if not changed(consensus,
          state.validation.values[key .. "TramStopsBaseline"] or {}) then return true end
      local outcome = consensus.lastOutcome
      local record = outcome and state.world.proposals.byId[outcome.proposalId] or nil
      local result = record and record.result or nil
      local edges = outputsOf(result, "edge")
      local objects = outputsOf(result, "edge_object")
      local stationGroups = outputsOf(result, "station_group")
      check(prefix .. "-tram-stops-physical-consensus",
        outcome and outcome.success == true, outcome)
      check(prefix .. "-tram-stops-replaced-two-edges", #edges == 2,
        { edges = edges, result = result })
      check(prefix .. "-tram-stops-created-curb-stops", #objects == 2,
        { objects = objects, result = result })
      check(prefix .. "-tram-stops-created-station-groups", #stationGroups == 2,
        { stationGroups = stationGroups, result = result })
      state.validation.values[key .. "StationGroupCids"] = stationGroups
      state.validation.values[key .. "TramStopsProposalId"] =
        outcome and outcome.proposalId or nil
      transition("wait-for-" .. prefix .. "-tram-stops-checkpoint")
      return true
    end
    if stage == "wait-for-" .. prefix .. "-tram-stops-checkpoint" then
      local wanted = state.validation.values[key .. "TramStopsProposalId"]
      local agreed = checkpoint(function(record)
        return wanted ~= nil and tostring(record.proposalId or "") == tostring(wanted)
      end)
      if not agreed then return true end
      check(prefix .. "-tram-stops-checkpoint-consensus", agreed.success == true, agreed)
      queueLine()
      return true
    end

    local phase = tostring(stage):match("^wait%-for%-" .. patternPrefix .. "%-(.+)%-consensus$")
    if phase == "line-create" or phase == "vehicle-buy" or phase == "vehicle-assign" then
      local consensus = state.world.operationConsensus
      if not changed(consensus, state.validation.values[key .. "OperationBaseline"] or {}) then
        return true
      end
      local outcome = consensus.lastOutcome
      local record = outcome and state.world.operations.byId[outcome.operationId] or nil
      local result = record and record.result or nil
      check(prefix .. "-" .. phase .. "-physical-consensus",
        outcome and outcome.success == true, outcome)
      if phase == "line-create" then
        local lines = outputsOf(result, "line")
        check(prefix .. "-line-created", #lines == 1, { lines = lines, result = result })
        state.validation.values[key .. "LineCid"] = lines[1]
      elseif phase == "vehicle-buy" then
        local vehicles = outputsOf(result, "vehicle")
        check(prefix .. "-vehicle-created", #vehicles == 1,
          { vehicles = vehicles, result = result })
        state.validation.values[key .. "VehicleCid"] = vehicles[1]
      else
        check(prefix .. "-vehicle-assigned", result and result.postcondition
          and result.postcondition.lineCid == state.validation.values[key .. "LineCid"], result)
      end
      state.validation.values[key .. "OperationId"] = outcome and outcome.operationId or nil
      transition("wait-for-" .. prefix .. "-" .. phase .. "-checkpoint")
      return true
    end

    phase = tostring(stage):match("^wait%-for%-" .. patternPrefix .. "%-(.+)%-checkpoint$")
    if phase == "line-create" or phase == "vehicle-buy" or phase == "vehicle-assign" then
      local wanted = state.validation.values[key .. "OperationId"]
      local agreed = checkpoint(function(record)
        return wanted ~= nil and tostring(record.proposalId or "") == tostring(wanted)
      end)
      if not agreed then return true end
      check(prefix .. "-" .. phase .. "-checkpoint-consensus", agreed.success == true, agreed)
      if phase == "line-create" then queueBuy()
      elseif phase == "vehicle-buy" then queueAssign()
      else finish(agreed.boundarySeq) end
      return true
    end
    return false
  end

  return { begin = begin, maintain = maintain }
end

return M
