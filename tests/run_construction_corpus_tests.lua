local project = assert(arg[1], "project root is required"):gsub("\\", "/")
package.path = project .. "/tpf2_mp_1/res/scripts/?.lua;"
  .. project .. "/tpf2_mp_1/res/scripts/?/init.lua;" .. package.path

local codec = require "tpf2_mp/proposal_codec"

local function fail(message)
  error("construction corpus: " .. tostring(message), 0)
end

local function check(value, message)
  if not value then fail(message) end
  return value
end

local function count(value)
  local result = 0
  for _ in pairs(value or {}) do result = result + 1 end
  return result
end

local rotations = {
  { 1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1, 0, 1000, 2000, 5, 1 },
  { 0, 1, 0, 0, -1, 0, 0, 0, 0, 0, 1, 0, 1000, 2000, 5, 1 },
  { -1, 0, 0, 0, 0, -1, 0, 0, 0, 0, 1, 0, 1000, 2000, 5, 1 },
  { 0, -1, 0, 0, 1, 0, 0, 0, 0, 0, 1, 0, 1000, 2000, 5, 1 },
}

local function stationRaw(params, cargo, head, transform, ordinal)
  local names, templateError = codec.stockStationTemplate(params, cargo, head)
  check(names, templateError)
  local modules = {}
  for slot, name in pairs(names) do
    modules[slot] = { name = name, variant = 0, metadata = "<userdata>" }
  end
  local nodes, edges, nextId = {}, {}, -1000000 - ordinal * 100
  for track = 1, params.tracks + 1 do
    local first, second = nextId, nextId - 1
    nextId = nextId - 2
    nodes[#nodes + 1] = {
      entity = first,
      comp = { position = { x = 1000, y = 2000 + track * 8, z = 5 } },
    }
    nodes[#nodes + 1] = {
      entity = second,
      comp = { position = { x = 1080, y = 2000 + track * 8, z = 5 } },
    }
    edges[#edges + 1] = {
      entity = nextId, type = 1,
      comp = {
        node0 = first, node1 = second,
        tangent0 = { x = 80, y = 0, z = 0 },
        tangent1 = { x = 80, y = 0, z = 0 },
        type = 0, typeIndex = -1,
      },
      trackEdge = { trackType = params.trackType, catenary = params.catenary == 1 },
      playerOwned = { player = 100 },
    }
    nextId = nextId - 1
  end
  return {
    __observedCost = 100000 + ordinal,
    proposal = {
      addedNodes = nodes, addedSegments = edges,
      removedNodes = {}, removedSegments = {},
      edgeObjectsToAdd = {}, edgeObjectsToRemove = {},
    },
    __constructionAdditions = {{
      fileName = "station/rail/modular_station/modular_station.con",
      transf = transform,
      params = {
        year = params.year, seed = params.seed,
        trackType = params.trackType, catenary = params.catenary,
        length = params.length, tracks = params.tracks,
        paramX = 0, paramY = 0, modules = modules,
      },
    }},
    __constructionRemovals = {},
  }, count(modules)
end

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
  local transaction, chainError = codec.normalise(networkChain(carrier, 192), "company:2", {
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

print("PASS construction corpus: 2560 rail layouts; long curved/graded track and road")
