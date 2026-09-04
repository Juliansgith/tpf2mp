local canonical = require "tpf2_mp/canonical"
local proposalCodec = require "tpf2_mp/proposal_codec"
local util = require "tpf2_mp/util"
local world = require "tpf2_mp/world"

local M = {}

-- Exact Build 35924 stock repository identity. Materialisation resolves the
-- resource by name, but physical output matching also verifies the portable
-- index captured by the transaction. Keeping the pinned pair together avoids
-- accepting a different street merely because its endpoints happen to match.
local ROUTE_STREET = {
  index = 15,
  name = "standard/country_small_new.lua",
}

local function finite(value)
  value = tonumber(value)
  return value and value == value and value ~= math.huge and value ~= -math.huge
end

local function position(value)
  if value == nil then return nil end
  local function field(name)
    local ok, result = pcall(function() return value[name] end)
    return ok and tonumber(result) or nil
  end
  local result = { x = field("x"), y = field("y"), z = field("z") }
  if not finite(result.x) or not finite(result.y) or not finite(result.z) then return nil end
  return result
end

local function nativeLocal(state, cid)
  local localId = state and state.canonical
    and canonical.resolveLocal(state.canonical, cid) or nil
  if not localId and state and state.canonical then
    local ok, resolved = pcall(world.findPreExistingLocal, state.canonical, cid, "node")
    if ok then localId = resolved end
  end
  return localId
end

local function nativePosition(state, cid)
  local localId = nativeLocal(state, cid)
  local types = api and api.type and api.type.ComponentType or {}
  local getComponent = api and api.engine and api.engine.getComponent
  -- Build 35924 exposes some engine functions as callable userdata rather
  -- than Lua `function` values. Presence plus protected invocation is the
  -- correct capability check here (the same contract used by world.lua).
  if not localId or getComponent == nil or types.BASE_NODE == nil then return nil end
  local ok, component = pcall(getComponent, localId, types.BASE_NODE)
  if not ok or component == nil then return nil end
  local positionOk, value = pcall(function() return component.position end)
  return positionOk and position(value) or nil
end

function M.resolveNeighbours(state, cid, override)
  if type(override) == "function" then
    local ok, value = pcall(override, cid, state)
    if ok and type(value) == "table" then return value end
  end
  local localId = nativeLocal(state, cid)
  if not localId or type(world.topologyFingerprint) ~= "function" then return {} end
  local ok, _, _, descriptor = pcall(world.topologyFingerprint, localId, "node", {
    registry = state and state.canonical,
    worldState = state and state.world,
  })
  if not ok or type(descriptor) ~= "table" or type(descriptor.neighbours) ~= "table" then
    return {}
  end
  return descriptor.neighbours
end

function M.resolvePositions(state, cids, override)
  local result = {}
  for _, cid in ipairs(cids or {}) do
    local value
    if type(override) == "function" then
      local ok, observed = pcall(override, cid, state)
      if ok then value = position(observed) end
    end
    value = value or nativePosition(state, cid)
    if not value then return nil, "tram node position is unavailable: " .. tostring(cid) end
    result[cid] = value
  end
  return result
end

local function squaredDistance(a, b)
  local x, y, z = a.x - b.x, a.y - b.y, a.z - b.z
  return x * x + y * y + z * z
end

local function routeHeight(x, y, fallback, override)
  if type(override) ~= "function" then return fallback end
  local ok, value = pcall(override, x, y)
  value = ok and tonumber(value) or nil
  return finite(value) and value or fallback
end

local function reference(value, isSlot)
  return isSlot and { slot = value } or { cid = value }
end

local function unitDirection(x, y)
  local magnitude = math.sqrt(x * x + y * y)
  if not finite(magnitude) or magnitude < 0.01 then return nil end
  return { x = x / magnitude, y = y / magnitude }
end

local function openBranchDirection(external, internal, neighbours)
  local occupied = {}
  local function add(other)
    other = position(other)
    if not other then return end
    local direction = unitDirection(other.x - external.x, other.y - external.y)
    if direction then occupied[#occupied + 1] = direction end
  end
  add(internal)
  for _, neighbour in ipairs(type(neighbours) == "table" and neighbours or {}) do
    add(neighbour.other)
  end
  -- A degree-one approach must continue straight away from its sole incident
  -- edge. Turning it ninety degrees creates a degree-two kink which the native
  -- road builder rejects. At a real junction, choose the centre of the largest
  -- free angular sector instead of overlapping an existing arm.
  if #occupied == 1 then
    return { x = -occupied[1].x, y = -occupied[1].y }, occupied
  end
  if #occupied == 0 then return nil, occupied end
  local best, bestClosest
  for index = 0, 31 do
    local angle = index * 2 * math.pi / 32
    local candidate = { x = math.cos(angle), y = math.sin(angle) }
    local closest = -2
    for _, direction in ipairs(occupied) do
      closest = math.max(closest, candidate.x * direction.x + candidate.y * direction.y)
    end
    if bestClosest == nil or closest < bestClosest - 1e-12 then
      best, bestClosest = candidate, closest
    end
  end
  return best, occupied
end

-- Build a small, physically routable tram system outwards from the access
-- edge generated by an isolated stock tram depot.  This deliberately avoids
-- joining two independently generated terminal graphs: Build 35924 can assert
-- while resolving that cross-construction junction even when both endpoints
-- are exact.  The terminals remain covered by their own replicated builds;
-- the curb stops below cover actual line/vehicle operation safely.
function M.transaction(depotNodeCids, companyCid, options)
  options = options or {}
  local nodes = type(depotNodeCids) == "table" and depotNodeCids or {}
  local positions = type(options.positions) == "table" and options.positions or {}
  local origin = position(options.depotOrigin)
  if (#nodes ~= 1 and #nodes ~= 2) or not origin or not positions[nodes[1]]
    or (#nodes == 2 and not positions[nodes[2]]) then
    return nil, "tram depot route endpoints are unavailable"
  end

  local externalCid, internalCid, internal
  local branchFromConnectedApproach = #nodes == 1
  local includeConnector = branchFromConnectedApproach and options.connectApproach ~= false
  if #nodes == 1 then
    -- The live-proven connected-depot repair exposes its world-side approach
    -- as a pre-existing canonical node.  Its captured entrance point supplies
    -- the inward direction without depending on a helper-generated node ID.
    externalCid, internalCid, internal = nodes[1], "captured-depot-entrance", origin
  else
    local first, second = nodes[1], nodes[2]
    local firstDistance = squaredDistance(positions[first], origin)
    local secondDistance = squaredDistance(positions[second], origin)
    if firstDistance > secondDistance or (firstDistance == secondDistance and first < second) then
      externalCid, internalCid = first, second
    else
      externalCid, internalCid = second, first
    end
    internal = positions[internalCid]
  end
  local external = positions[externalCid]
  local dx, dy = external.x - internal.x, external.y - internal.y
  local magnitude = math.sqrt(dx * dx + dy * dy)
  if not finite(magnitude) or magnitude < 0.01 then
    return nil, "tram depot access direction is degenerate"
  end
  dx, dy = dx / magnitude, dy / magnitude
  if branchFromConnectedApproach then
    -- The captured approach already continues along the depot entrance axis.
    -- Extending that vector overlays the existing street and BuildProposal
    -- rejects it. Branch clockwise into fresh terrain while preserving a
    -- routable intersection at the exact canonical approach node.
    local branchSide = tonumber(options.branchSide) or 1
    if branchSide ~= 1 and branchSide ~= -1 then
      return nil, "tram route branch side must be -1 or 1"
    end
    local open, occupied
    if includeConnector then
      open, occupied = openBranchDirection(external, internal, options.neighbours)
    end
    if open then
      dx, dy = open.x, open.y
    elseif branchSide == 1 then
      dx, dy = dy, -dx
    else
      dx, dy = -dy, dx
    end
    options.__occupiedDirections = occupied
  end
  local spacing = tonumber(options.spacing) or 72
  if not finite(spacing) or spacing < 40 or spacing > 160 then
    return nil, "tram route spacing is outside [40,160]"
  end

  local gap = tonumber(options.gap) or 48
  if not finite(gap) or gap < 20 or gap > 100 then
    return nil, "tram connector gap is outside [20,100]"
  end
  local addedNodes = {}
  for index = 1, 4 do
    local distance = gap + spacing * (index - 1)
    local x, y = external.x + dx * distance, external.y + dy * distance
    addedNodes[index] = {
      slot = "node:" .. tostring(index),
      position = {
        x = x, y = y,
        z = routeHeight(x, y, external.z, options.height),
      },
    }
  end

  local edges = {}
  local edgeOffset = 0
  if includeConnector then
    local to = addedNodes[1].position
    local tangent = {
      x = to.x - external.x, y = to.y - external.y, z = to.z - external.z,
    }
    edges[1] = {
      slot = "edge:1", carrier = "street",
      node0 = { cid = externalCid }, node1 = { slot = "node:1" },
      tangent0 = tangent, tangent1 = tangent,
      type = 0, typeIndex = 0,
      bus = false, tramTrackType = proposalCodec.TRAM_TRACK_ELECTRIC,
      -- Build 35924 rejects a stock road resource when it is attached directly
      -- to the repaired street-depot junction. Continue the depot's own
      -- entrance resource for this short connector, then transition to the
      -- ordinary tram road on the following new-node edge.
      resource = { index = 29, name = "street_depot/entrance_old.lua" },
      logicalOwnerCid = companyCid, private = true,
    }
    edgeOffset = 1
  end
  for index = 1, 3 do
    local from = addedNodes[index].position
    local to = addedNodes[index + 1].position
    local tangent = { x = to.x - from.x, y = to.y - from.y, z = to.z - from.z }
    local edgeIndex = index + edgeOffset
    edges[edgeIndex] = {
      slot = "edge:" .. tostring(edgeIndex), carrier = "street",
      node0 = reference("node:" .. tostring(index), true),
      node1 = reference("node:" .. tostring(index + 1), true),
      tangent0 = tangent, tangent1 = tangent,
      type = 0, typeIndex = 0,
      bus = false, tramTrackType = proposalCodec.TRAM_TRACK_ELECTRIC,
      resource = { index = ROUTE_STREET.index, name = ROUTE_STREET.name },
      logicalOwnerCid = companyCid, private = true,
    }
  end

  local edgeObjects = {}
  if options.includeStops ~= false then
    for index, stop in ipairs({
      { edge = 1 + edgeOffset, param = 0.70, left = false },
      -- A road line is cyclic even when the vehicle reverses at its visible
      -- endpoints. Putting both synthetic stops on the same carriageway makes
      -- the return leg unroutable and SetLine rejects the otherwise healthy
      -- tram. The far stop belongs to the opposite carriageway.
      { edge = 3 + edgeOffset, param = 0.30, left = true },
    }) do
      edgeObjects[index] = {
        slot = "edge_object:" .. tostring(index),
        edge = { slot = "edge:" .. tostring(stop.edge) }, param = stop.param,
        oneWay = false, left = stop.left, model = "station/bus/small_mid.mdl",
        name = "", category = 0, logicalOwnerCid = companyCid, private = true,
      }
    end
  end

  local transaction = {
    schemaVersion = proposalCodec.SCHEMA_VERSION, companyCid = companyCid, cost = 0,
    nodes = addedNodes, edges = edges,
    edgeObjects = { add = edgeObjects, retain = {}, remove = {} },
    remove = { edges = {}, nodes = {} },
  }
  transaction.digest = proposalCodec.digest(transaction)
  transaction.transactionId = "proposal:" .. transaction.digest
  local valid, validationError = proposalCodec.validate(transaction)
  if not valid then return nil, validationError end
  return transaction, nil, {
    external = externalCid, internal = internalCid, origin = origin,
    direction = { x = dx, y = dy }, spacing = spacing, gap = gap,
    routeStart = addedNodes[1].position,
    connectorIncluded = includeConnector,
    occupiedDirections = options.__occupiedDirections,
  }
end

local function reboundReference(referenceValue, nodeBindings)
  if type(referenceValue) ~= "table" then return nil end
  if type(referenceValue.cid) == "string" then return { cid = referenceValue.cid } end
  local cid = type(referenceValue.slot) == "string"
    and nodeBindings[referenceValue.slot] or nil
  return type(cid) == "string" and { cid = cid } or nil
end

-- Add the curb stops in a second native proposal. Build 35924 rejects the
-- compound shape which both attaches a road to an existing depot node and
-- creates edge objects. Replacing two already-converged route segments is the
-- same safe topology used by ordinary signal/waypoint placement.
function M.stopTransaction(routeTransaction, bindings, companyCid)
  bindings = type(bindings) == "table" and bindings or {}
  local nodeBindings = type(bindings.nodes) == "table" and bindings.nodes or {}
  local edgeBindings = type(bindings.edges) == "table" and bindings.edges or {}
  local sourceEdges = type(routeTransaction) == "table" and routeTransaction.edges or {}
  if #sourceEdges ~= 3 and #sourceEdges ~= 4 then
    return nil, "tram stop source route must contain three or four edges"
  end
  local edges, objects, removed = {}, {}, {}
  local stopEdges = #sourceEdges == 3 and { 1, 3 } or { 2, 4 }
  for index, sourceIndex in ipairs(stopEdges) do
    local source = sourceEdges[sourceIndex]
    local removedCid = edgeBindings[source.slot]
    local node0 = reboundReference(source.node0, nodeBindings)
    local node1 = reboundReference(source.node1, nodeBindings)
    if type(removedCid) ~= "string" or not removedCid:match("^edge:")
      or not node0 or not node1 then
      return nil, "tram stop route bindings are incomplete"
    end
    local edge = util.deepCopy(source)
    edge.slot = "edge:" .. tostring(index)
    edge.node0, edge.node1 = node0, node1
    edges[index] = edge
    objects[index] = {
      slot = "edge_object:" .. tostring(index), edge = { slot = edge.slot },
      param = index == 1 and 0.70 or 0.30,
      oneWay = false, left = index == 2, model = "station/bus/small_mid.mdl",
      name = "", category = 0, logicalOwnerCid = companyCid, private = true,
    }
    removed[index] = removedCid
  end
  table.sort(removed)
  local transaction = {
    schemaVersion = proposalCodec.SCHEMA_VERSION,
    companyCid = companyCid, cost = 0, nodes = {}, edges = edges,
    edgeObjects = { add = objects, retain = {}, remove = {} },
    remove = { edges = removed, nodes = {} },
  }
  transaction.digest = proposalCodec.digest(transaction)
  transaction.transactionId = "proposal:" .. transaction.digest
  local valid, validationError = proposalCodec.validate(transaction)
  if not valid then return nil, validationError end
  return transaction
end

function M.connectorTransaction(approachCid, routeStartCid, companyCid, options)
  options = options or {}
  local positions = type(options.positions) == "table" and options.positions or {}
  local approach, routeStart = positions[approachCid], positions[routeStartCid]
  if type(approachCid) ~= "string" or not approachCid:match("^node:")
    or type(routeStartCid) ~= "string" or not routeStartCid:match("^node:")
    or not position(approach) or not position(routeStart) then
    return nil, "tram connector endpoints are unavailable"
  end
  local tangent = {
    x = routeStart.x - approach.x,
    y = routeStart.y - approach.y,
    z = routeStart.z - approach.z,
  }
  local transaction = {
    schemaVersion = proposalCodec.SCHEMA_VERSION, companyCid = companyCid, cost = 0,
    nodes = {}, edges = {{
      slot = "edge:1", carrier = "street",
      node0 = { cid = approachCid }, node1 = { cid = routeStartCid },
      tangent0 = tangent, tangent1 = tangent,
      type = 0, typeIndex = 0,
      bus = false, tramTrackType = proposalCodec.TRAM_TRACK_ELECTRIC,
      resource = { index = ROUTE_STREET.index, name = ROUTE_STREET.name },
      logicalOwnerCid = companyCid, private = true,
    }},
    edgeObjects = { add = {}, retain = {}, remove = {} },
    remove = { edges = {}, nodes = {} },
  }
  transaction.digest = proposalCodec.digest(transaction)
  transaction.transactionId = "proposal:" .. transaction.digest
  local valid, validationError = proposalCodec.validate(transaction)
  if not valid then return nil, validationError end
  return transaction
end

return M
