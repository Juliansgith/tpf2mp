local project = assert(arg[1]):gsub("\\", "/")
package.path = project .. "/tpf2_mp_1/res/scripts/?.lua;" .. package.path
local codec = require "tpf2_mp/proposal_codec"
local util = require "tpf2_mp/util"
local junction = require "tpf2_mp/proposal_depot_junction"
local capture = require "tpf2_mp/proposal_depot_junction_capture"
local graph = require "tpf2_mp/construction_depot_connection_graph"
local fixture = require "tpf2_mp/validation_connected_road_depot_proposal"

-- Exact entrance geometry from failed player-input proposal 2899460b,
-- localhost-manual-20260906-145621. Existing-node attachment, NOT road split.
local tx = assert(fixture.transaction("company:1"))
tx.nodes[1].position = { x = -794.819763, y = -1123.23572, z = 16.4464035 }
tx.edges[1].node1 = { cid = "node:pre:415c0cfc" }
tx.edges[1].tangent0 = { x = -9.55625439, y = -3.56715083, z = 0 }
tx.edges[1].tangent1 = { x = -9.55621338, y = -3.5672605, z = 0 }
tx.constructions[1].transform = { .34970966,-.936858118,0,0,.936858118,.34970966,0,0,
  0,0,1,0,-775.333374,-1115.96191,16.4464035,1 }
tx.cost = 18987
tx.digest = codec.digest(tx); tx.transactionId = "proposal:" .. tx.digest
assert(codec.validatePortable(tx))
local before = util.deepCopy(tx)
local cid = assert(junction.target(tx))
local position = { x = -804.37601739, y = -1126.80287083, z = 16.4464035 }
local function branch(name, reverse)
  local edge = util.deepCopy(tx.edges[1])
  edge.private = false
  edge.node0 = { cid = reverse and name or cid }
  edge.node1 = { cid = reverse and cid or name }
  edge.tangent0 = { x = 30, y = -50, z = .2 }
  edge.tangent1 = util.deepCopy(edge.tangent0)
  return { cid = "edge:" .. name, edge = edge }
end
local neighbourhood = { cid = cid, position = position,
  branches = { branch("node:b", false), branch("node:a", true) } }
local expanded = assert(junction.expand(tx, neighbourhood, codec))
assert(codec.validatePortable(expanded))
assert(expanded.cost == tx.cost and expanded.constructions[1].transform[13] == tx.constructions[1].transform[13])
assert(#expanded.nodes == 2 and #expanded.edges == 3 and expanded.remove.nodes[1] == cid)
assert(expanded.remove.edges[1] == "edge:node:a" and expanded.remove.edges[2] == "edge:node:b")
assert(expanded.edges[1].node1.slot == "node:2" and expanded.edges[2].node1.slot == "node:2"
  and expanded.edges[3].node0.slot == "node:2" and not expanded.edges[2].private)
assert(codec.digest(tx) == codec.digest(before), "normalisation mutated the captured transaction")
assert(junction.target(expanded) == nil, "normalisation is not idempotent")
local reversed = util.deepCopy(neighbourhood)
reversed.branches[1], reversed.branches[2] = reversed.branches[2], reversed.branches[1]
assert(assert(junction.expand(tx, reversed, codec)).digest == expanded.digest)

local record = { transaction = tx, constructionPending = { depotConnectionRepair = {
  internalNodeSlot = "node:1", internalNodeId = 800,
  sourceInternalPosition = util.deepCopy(tx.nodes[1].position),
  helperInternalPosition = { x = -794.81976318359375, y = -1123.2357177734375, z = 16.446403503417969 },
  helperExternalPosition = { x = -803.82818603515625, y = -1126.598388671875, z = 16.446403503417969 },
  helperNodeIds = { 801 }, helperEdgeIds = { 802 },
} } }
local broken = assert(graph.build(record, codec))
local t = broken.edges[1].tangent0
assert(math.sqrt(t.x*t.x+t.y*t.y+t.z*t.z) < .59, "incident no longer reproduces the residual micro-edge")
record.transaction = expanded
local physical, _, err, plan = graph.build(record, codec)
assert(physical, err)
assert(plan.coalesced and #physical.nodes == 0 and #physical.edges == 2)
assert(physical.remove.nodes[1] == cid and #physical.remove.edges == 2)
assert(physical.edges[1].node1.cid == "node:repair:depot-external"
  and physical.edges[2].node0.cid == "node:repair:depot-external")
local deadEnd = util.deepCopy(neighbourhood); deadEnd.branches[2] = nil
record.transaction = assert(junction.expand(tx, deadEnd, codec))
assert(select(4, graph.build(record, codec)).coalesced, "existing road endpoint retained a micro-edge")
local invalid = util.deepCopy(neighbourhood); invalid.branches[2] = invalid.branches[1]
assert(not junction.expand(tx, invalid, codec), "duplicate adjacency accepted")
invalid = util.deepCopy(neighbourhood); invalid.branches[1].edge.carrier = "track"
assert(not junction.expand(tx, invalid, codec), "mixed-carrier adjacency accepted")
invalid = util.deepCopy(neighbourhood); invalid.branches[1].edge.node0.cid = "node:unrelated"
assert(not junction.expand(tx, invalid, codec), "detached adjacency accepted")

local types = { BASE_NODE = "node", BASE_EDGE = "edge", BASE_EDGE_STREET = "street",
  BASE_EDGE_TRACK = "track", PLAYER_OWNED = "owned" }
local components = {
  [700] = { node = { position = position } },
  [710] = { edge = { node0 = 700, node1 = 701, tangent0 = {x=50,y=0,z=0},
      tangent1 = {x=50,y=0,z=0}, type = 0, typeIndex = -1, objects = {} },
    street = { streetType = 29, tramTrackType = 2, hasBus = true } },
  [711] = { edge = { node0 = 702, node1 = 700, tangent0 = {x=50,y=0,z=0},
      tangent1 = {x=50,y=0,z=0}, type = 0, typeIndex = -1, objects = {} },
    street = { streetType = 29, tramTrackType = 0, hasBus = false }, owned = { player = 100 } },
  [799] = { edge = { node0 = 798, node1 = 797 } },
}
local reads = 0
local deps = { codec = codec, resolveLocal = function(value) assert(value == cid); return 700 end,
  options = { resolveCanonical = function(kind, id)
    return id == 700 and cid or kind .. ":pre:" .. tostring(id)
  end, resourceName = function() return "standard/town_small_old.lua" end, requireResourceName = true },
  api = { type = { ComponentType = types }, engine = {
    system = { streetConnectorSystem = {
      getStreetConnectorEntity = function() return -1 end,
      getConstructionEntityForEdge = function() return -1 end,
    } },
    getComponent = function(id, kind) reads = reads + 1; return components[id] and components[id][kind] end,
    forEachEntityWithComponent = function(callback) for _, id in ipairs({799,711,710}) do callback(id) end end,
  } },
}
local live = assert(capture.normalise(tx, deps))
assert(#live.edges == 3 and live.edges[2].tramTrackType == 2 and live.edges[2].bus
  and live.edges[3].private, "native road features/ownership were lost")
assert(reads < 40)
reads = 0; assert(capture.normalise(live, deps) == live and reads == 0)
components[710].edge.objects = {{123,0}}
assert(not capture.normalise(tx, deps), "junction carrying unhandled edge objects was accepted")
components[710].edge.objects = {}
local savedEdge = components[710].edge
components[710].edge = nil
assert(not capture.normalise(tx, deps), "missing adjacency component was silently skipped")
components[710].edge = savedEdge
local connector = deps.api.engine.system.streetConnectorSystem
connector.getConstructionEntityForEdge = function(id) return id == 710 and 900 or -1 end
assert(not capture.normalise(tx, deps), "another construction's frozen entrance was captured for removal")
connector.getConstructionEntityForEdge = function() return -1 end
connector.getStreetConnectorEntity = function() return 900 end
assert(not capture.normalise(tx, deps), "a frozen construction node was captured for removal")
connector.getStreetConnectorEntity = nil
assert(not capture.normalise(tx, deps), "missing construction attachment lookup was treated as unfrozen")
connector.getStreetConnectorEntity = function() return -1 end
deps.api.engine.forEachEntityWithComponent = function() error("enumeration unavailable") end
assert(not capture.normalise(tx, deps), "incomplete adjacency accepted")
print("PASS depot existing-junction expansion, incident geometry, endpoint, parity, features and fail-closed tests")
