local project = assert(arg[1], "project root is required"):gsub("\\", "/")
package.path = project .. "/tpf2_mp_1/res/scripts/?.lua;"
  .. project .. "/tpf2_mp_1/res/scripts/?/init.lua;" .. package.path

local codec = require "tpf2_mp/proposal_codec"
local fixtures = dofile(project .. "/tests/helpers/construction_corpus_fixtures.lua")

local function fail(message)
  error("construction corpus: " .. tostring(message), 0)
end

local function check(value, message)
  if not value then fail(message) end
  return value
end

local nativeRoundTrip, rotations, stationRaw =
  fixtures.nativeRoundTrip, fixtures.rotations, fixtures.stationRaw

-- Every stock modular rail-station choice: passenger/cargo, through/terminus,
-- five lengths, one through eight tracks, standard/high-speed, catenary on/off,
-- and four cardinal orientations.  The codec itself supplies the expected
-- module map, while this test independently builds and validates the graph.
local stationCases = 0
for _, cargo in ipairs({ false, true }) do
  for _, head in ipairs({ false, true }) do
    for length = 0, 4 do
      for tracks = 0, 7 do
        for trackType = 0, 1 do
          for catenary = 0, 1 do
            for _, transform in ipairs(rotations) do
              stationCases = stationCases + 1
              local params = {
                year = 1990, seed = stationCases, length = length,
                tracks = tracks, trackType = trackType, catenary = catenary,
              }
              local raw, moduleCount = stationRaw(
                params, cargo, head, transform, stationCases)
              -- A stale shallow preview beside the exact nested proposal was
              -- the live regression that disabled station/depot families.
              raw.nodesToAdd = { { entity = -9, comp = {
                position = { x = -9, y = -9, z = -9 },
              } } }
              raw.edgesToAdd = {}
              raw = nativeRoundTrip(raw, stationCases)
              local transaction, normaliseError = codec.normalise(raw, "company:1", {
                resourceName = function(kind, index)
                  if kind == "track" and index == trackType then
                    return index == 0 and "standard.lua" or "high_speed.lua"
                  end
                end,
                requireResourceName = true,
              })
              check(transaction, "rail matrix case " .. stationCases .. ": "
                .. tostring(normaliseError))
              local portable, portableError = codec.validatePortable(transaction)
              check(portable, "rail matrix portability case " .. stationCases .. ": "
                .. tostring(portableError))
              local construction = transaction.constructions[1]
              check(construction.kind == "rail_station", "rail station kind changed")
              check(#construction.modules == moduleCount, "rail station module map changed")
              check(#transaction.edges == tracks + 1, "rail station graph track count changed")
              local spec, materialiseError = codec.materialiseConstruction(transaction)
              check(spec, materialiseError)
              check(spec.params.length == length and spec.params.tracks == tracks,
                "rail station layout selectors changed")
              check(spec.params.trackType == trackType
                and spec.params.catenary == catenary,
                "rail station carrier selectors changed")
            end
          end
        end
      end
    end
  end
end
check(stationCases == 2560, "rail station matrix did not contain 2560 cases")

-- A long, curved, vertically graded chain exercises the generic data-driven
-- topology path at a size large enough to catch accidental single-segment or
-- flat-world assumptions. Structure selectors model ordinary, bridge, and
-- tunnel segments without naming a specific map coordinate.
local function networkChain(carrier, edgeCount)
  local nodes, edges = {}, {}
  for index = 0, edgeCount do
    local angle = index * 0.035
    nodes[index + 1] = {
      entity = -2000000 - index,
      comp = { position = {
        x = index * 35,
        y = 240 * math.sin(angle),
        z = 12 + 18 * math.sin(index * 0.08),
      } },
    }
  end
  for index = 1, edgeCount do
    local first = nodes[index].comp.position
    local second = nodes[index + 1].comp.position
    local segment = {
      entity = -2100000 - index,
      type = carrier == "track" and 1 or 0,
      comp = {
        node0 = nodes[index].entity, node1 = nodes[index + 1].entity,
        tangent0 = {
          x = second.x - first.x, y = second.y - first.y + 4,
          z = second.z - first.z,
        },
        tangent1 = {
          x = second.x - first.x, y = second.y - first.y - 4,
          z = second.z - first.z,
        },
        type = index % 19 == 0 and 2 or (index % 13 == 0 and 1 or 0),
        typeIndex = index % 19 == 0 and 1 or (index % 13 == 0 and 2 or -1),
      },
    }
    if carrier == "track" then
      segment.trackEdge = { trackType = 1, catenary = index % 2 == 0 }
      segment.playerOwned = { player = 100 }
    else
      segment.streetEdge = { streetType = 4, hasBus = false, tramTrackType = 0 }
    end
    edges[index] = segment
  end
  return {
    __observedCost = 9000000,
    streetProposal = {
      nodesToAdd = nodes, edgesToAdd = edges,
      nodesToRemove = {}, edgesToRemove = {},
      edgeObjectsToAdd = {}, edgeObjectsToRemove = {},
    },
    constructionsToAdd = {}, constructionsToRemove = {},
  }
end

for _, carrier in ipairs({ "track", "street" }) do
  local raw = networkChain(carrier, 192)
  raw.nodesToAdd = { raw.streetProposal.nodesToAdd[1] }
  raw.edgesToAdd = {}
  raw = nativeRoundTrip(raw, 3000 + (carrier == "track" and 1 or 2))
  local transaction, chainError = codec.normalise(raw, "company:2", {
    resourceName = function(kind, index)
      if kind == "track" and index == 1 then return "high_speed.lua" end
      if kind == "street" and index == 4 then return "standard/town_medium_new.lua" end
    end,
    requireResourceName = true,
  })
  check(transaction, carrier .. " long-chain: " .. tostring(chainError))
  check(#transaction.nodes == 193 and #transaction.edges == 192,
    carrier .. " long-chain cardinality changed")
  local portable, portableError = codec.validatePortable(transaction)
  check(portable, carrier .. " long-chain portability: " .. tostring(portableError))
end

-- A mixed-carrier crossing replaces a public road while adding private rail.
-- This exact family regressed when normalisation rediscovered a shallow GUI
-- alias and then reported that the street edge had no tram selector.
local crossingNodes = {
  { entity = -1, comp = { position = { x = 0, y = -30, z = 5 } } },
  { entity = -2, comp = { position = { x = 0, y = 0, z = 5 } } },
  { entity = -3, comp = { position = { x = 0, y = 30, z = 5 } } },
  { entity = -4, comp = { position = { x = 30, y = 0, z = 5 } } },
}
local function crossingEdge(entity, carrier, node0, node1)
  local value = {
    entity = entity, type = carrier == "track" and 1 or 0,
    comp = { node0 = node0, node1 = node1,
      tangent0 = { x = 20, y = 0, z = 0 },
      tangent1 = { x = 20, y = 0, z = 0 }, type = 0, typeIndex = -1 },
  }
  if carrier == "track" then
    value.trackEdge = { trackType = 0, catenary = false }
    value.playerOwned = { player = 100 }
  else
    value.streetEdge = { streetType = 22, hasBus = false, tramTrackType = 0 }
  end
  return value
end
local crossing = {
  __observedCost = 27000,
  streetProposal = {
    nodesToAdd = crossingNodes,
    edgesToAdd = {
      crossingEdge(-11, "track", -1, -2),
      crossingEdge(-12, "track", -2, -3),
      crossingEdge(-13, "street", -2, 101),
      crossingEdge(-14, "street", 102, -4),
      crossingEdge(-15, "street", -4, -2),
    },
    nodesToRemove = {
      { entity = 103, comp = { position = { x = 0, y = 0, z = 5 } } },
    },
    edgesToRemove = {
      crossingEdge(201, "street", 101, 103),
      crossingEdge(202, "street", 103, 102),
    },
    edgeObjectsToAdd = {}, edgeObjectsToRemove = {},
  },
  constructionsToAdd = {}, constructionsToRemove = {},
  nodesToAdd = { crossingNodes[1] }, edgesToAdd = {},
}
crossing = nativeRoundTrip(crossing, 4000)
local crossingCids = {
  node = { [101] = "node:pre:101", [102] = "node:pre:102", [103] = "node:pre:103" },
  edge = { [201] = "edge:pre:201", [202] = "edge:pre:202" },
}
local crossingTx, crossingError = codec.normalise(crossing, "company:1", {
  resolveCanonical = function(kind, localId)
    return crossingCids[kind] and crossingCids[kind][localId]
  end,
  entityPosition = function(kind, localId)
    if kind == "node" and crossingCids.node[localId] then
      return { x = localId == 101 and -30 or 30, y = 0, z = 5 }
    end
  end,
  resourceName = function(kind, index)
    if kind == "track" and index == 0 then return "standard.lua" end
    if kind == "street" and index == 22 then return "standard/town_medium_new.lua" end
  end,
  requireResourceName = true,
})
check(crossingTx, "mixed road/rail crossing: " .. tostring(crossingError))
local tracks, streets = 0, 0
for _, edge in ipairs(crossingTx.edges) do
  if edge.carrier == "track" then tracks = tracks + 1 else streets = streets + 1 end
end
check(tracks == 2 and streets == 3 and #crossingTx.remove.edges == 2
    and #crossingTx.remove.nodes == 1,
  "mixed crossing lost carrier topology or public-road removals")
local crossingPortable, crossingPortableError = codec.validatePortable(crossingTx)
check(crossingPortable, "mixed crossing portability: " .. tostring(crossingPortableError))

print("PASS construction corpus: 2560 rail layouts; long curved/graded networks; mixed road/rail crossing")
