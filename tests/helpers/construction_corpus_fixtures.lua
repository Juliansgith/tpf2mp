local codec = require "tpf2_mp/proposal_codec"
local earlyCapture = require "tpf2_mp/gui_early_build_capture"

local M = {}

local function fail(message)
  error("construction corpus fixture: " .. tostring(message), 0)
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

local function vectorArray(value)
  return { value.x or value[1], value.y or value[2], value.z or value[3] }
end

-- Project a semantic fixture through the same pointer-free shape emitted by
-- the Build 35924 factory hook. This makes the large corpus exercise the
-- native/semantic merge layer, not only the already-canonical codec.
function M.nativeRoundTrip(raw, ordinal)
  local proposal = raw.streetProposal or raw.proposal or raw
  local nodesToAdd = proposal.nodesToAdd or proposal.addedNodes or {}
  local edgesToAdd = proposal.edgesToAdd or proposal.addedSegments or {}
  local nodesToRemove = proposal.nodesToRemove or proposal.removedNodes or {}
  local edgesToRemove = proposal.edgesToRemove or proposal.removedSegments or {}
  local capture = {
    schemaVersion = 1, generation = ordinal + 1, correlation = ordinal + 100,
    captureSource = "factory", factoryCallerRva = 0x9dc750,
    addCallerRva = 0x9d2a00, callerType = "construction-builder",
    factoryThread = 7, addThread = 7, optionFieldsKnown = true,
    withCost = true, ignoreErrors = false, valid = true, error = "",
    addedNodes = {}, removedNodes = {}, addedEdges = {}, removedEdges = {},
    edgeObjectsToAdd = {}, edgeObjectsToRemove = {}, frozenNodeIndices = {},
    segmentTags = {}, constructionsToAdd = {}, constructionsToRemove = {},
  }
  local function appendNode(target, source)
    for _, value in ipairs(source) do
      local comp = value.comp or value
      local position = comp.position or comp.pos
      target[#target + 1] = { e = value.entity, x = position.x, y = position.y,
        z = position.z, f = comp.flags or 0, t = comp.type or 0 }
    end
  end
  local function appendEdge(target, source)
    for _, value in ipairs(source) do
      local comp = value.comp or value
      local carrier = value.type == 1 and 1 or 0
      local result = {
        e = value.entity, n0 = comp.node0, n1 = comp.node1,
        t0 = vectorArray(comp.tangent0), t1 = vectorArray(comp.tangent1),
        carrier = carrier, w28 = comp.type or 0, w2c = comp.typeIndex or 0,
        owned = value.playerOwned and 1 or 0,
        player = value.playerOwned and value.playerOwned.player or 0,
      }
      if carrier == 1 then
        result.trackType = value.trackEdge.trackType
        result.f64 = value.trackEdge.catenary and 1 or 0
      else
        result.streetType = value.streetEdge.streetType
        result.w50 = (value.streetEdge.bus or value.streetEdge.hasBus) and 1 or 0
        result.tramTrackType = value.streetEdge.tramTrackType or 0
      end
      target[#target + 1] = result
    end
  end
  appendNode(capture.addedNodes, nodesToAdd)
  appendNode(capture.removedNodes, nodesToRemove)
  appendEdge(capture.addedEdges, edgesToAdd)
  appendEdge(capture.removedEdges, edgesToRemove)
  for _ in ipairs(proposal.edgeObjectsToAdd or {}) do
    capture.edgeObjectsToAdd[#capture.edgeObjectsToAdd + 1] = 0
  end
  for _, value in ipairs(proposal.edgeObjectsToRemove or {}) do
    capture.edgeObjectsToRemove[#capture.edgeObjectsToRemove + 1] = value
  end
  for _, value in ipairs(raw.__constructionAdditions or raw.constructionsToAdd or {}) do
    capture.constructionsToAdd[#capture.constructionsToAdd + 1] = {
      fileName = value.fileName, transform = value.transf or value.transform,
      frozenNodes = {}, segmentsBefore = 0,
    }
  end
  for _, value in ipairs(raw.__constructionRemovals or raw.constructionsToRemove or {}) do
    capture.constructionsToRemove[#capture.constructionsToRemove + 1] = value
  end
  local merged, mergeError = earlyCapture.merge(raw, capture)
  check(merged, "native merge case " .. tostring(ordinal) .. ": " .. tostring(mergeError))
  return merged
end

M.rotations = {
  { 1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1, 0, 1000, 2000, 5, 1 },
  { 0, 1, 0, 0, -1, 0, 0, 0, 0, 0, 1, 0, 1000, 2000, 5, 1 },
  { -1, 0, 0, 0, 0, -1, 0, 0, 0, 0, 1, 0, 1000, 2000, 5, 1 },
  { 0, -1, 0, 0, 1, 0, 0, 0, 0, 0, 1, 0, 1000, 2000, 5, 1 },
}

function M.stationRaw(params, cargo, head, transform, ordinal)
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

return M
