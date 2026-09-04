local hash = require "tpf2_mp/hash"
local util = require "tpf2_mp/util"

local M = { SCHEMA_VERSION = 1, MAX_NEIGHBOURS = 64 }

local function safeField(value, key)
  if type(value) ~= "table" and type(value) ~= "userdata" then return nil end
  local ok, nested = pcall(function() return value[key] end)
  return ok and nested or nil
end

local function finite(value)
  local number = tonumber(value)
  if not number or number ~= number or number == math.huge or number == -math.huge then
    return nil
  end
  return number
end

local function quantised(value)
  local number = finite(value)
  return number and util.integer(number * 100000) or nil
end

local function vector(value)
  if value == nil then return nil end
  local function coordinate(name, one, zero)
    return quantised(safeField(value, name) or safeField(value, one) or safeField(value, zero))
  end
  local x, y, z = coordinate("x", 1, 0), coordinate("y", 2, 1), coordinate("z", 3, 2)
  if x == nil or y == nil then return nil end
  return { x, y, z or 0 }
end

-- world_component_identity already projects entity positions to portable
-- decimetre integers. Preserve that projection instead of quantising it a
-- second time; native tangents/transforms still use the finer projection above.
local function stablePosition(value)
  if value == nil then return nil end
  local function coordinate(name, one, zero)
    local number = finite(safeField(value, name) or safeField(value, one) or safeField(value, zero))
    return number and util.integer(number) or nil
  end
  local x, y, z = coordinate("x", 1, 0), coordinate("y", 2, 1), coordinate("z", 3, 2)
  if x == nil or y == nil then return nil end
  return { x, y, z or 0 }
end

local function matrix(value)
  if value == nil then return nil end
  local result = {}
  for index = 1, 16 do
    local item = quantised(safeField(value, index) or safeField(value, index - 1))
    if item == nil then return nil end
    result[index] = item
  end
  return result
end

function M.expectedConstructionFingerprint(spec, owner)
  if type(spec) ~= "table" or type(spec.fileName) ~= "string"
      or spec.fileName == "" then return nil end
  local transform = matrix(spec.transform or spec.transf)
  if not transform then return nil end
  local ok, paramsDigest = pcall(hash.value, spec.params or {})
  if not ok then return nil end
  return hash.value({
    schemaVersion = M.SCHEMA_VERSION,
    kind = "construction",
    owner = owner,
    resource = spec.fileName,
    transform = transform,
    paramsDigest = paramsDigest,
  })
end

local function boundedIds(value)
  local result, seen = {}, {}
  local function add(raw)
    local id = tonumber(raw)
      or tonumber(safeField(raw, "entity")) or tonumber(safeField(raw, "id"))
      or tonumber(safeField(raw, 1)) or tonumber(safeField(raw, 0))
    if id and id >= 0 and id == math.floor(id) and not seen[id] then
      seen[id], result[#result + 1] = true, id
    end
  end
  if type(value) == "table" then
    for _, raw in pairs(value) do
      if #result >= M.MAX_NEIGHBOURS then break end
      add(raw)
    end
  elseif type(value) == "userdata" then
    local ok, length = pcall(function() return #value end)
    length = ok and tonumber(length) or 0
    for _, base in ipairs({ 0, 1 }) do
      for offset = 0, math.min(M.MAX_NEIGHBOURS, length or 0) - 1 do
        local read, raw = pcall(function() return value[base + offset] end)
        if read and raw ~= nil then add(raw) end
      end
    end
  end
  table.sort(result)
  return result
end

function M.new(deps)
  local component = assert(deps.component, "component dependency is required")
  local getApi = assert(deps.getApi, "getApi dependency is required")
  local positionOf = assert(deps.positionOf, "positionOf dependency is required")
  local stableName = assert(deps.stableName, "stableName dependency is required")
  local ownerCid = assert(deps.ownerCid, "ownerCid dependency is required")

  local function resourceName(repository, raw)
    if type(raw) == "string" and raw ~= "" then return raw end
    local index = tonumber(raw) or tonumber(safeField(raw, "index"))
    if index and repository and util.isCallable(repository.getName) then
      local ok, name = pcall(repository.getName, index)
      if ok and name ~= nil and tostring(name) ~= "" then return tostring(name) end
    end
    return index and ("index:" .. tostring(util.integer(index, -1))) or "unavailable"
  end

  local function carrier(edgeId, types, apiValue)
    local street = component(edgeId, types.BASE_EDGE_STREET)
    local track = component(edgeId, types.BASE_EDGE_TRACK)
    if street and track then return { kind = "invalid-dual-carrier" } end
    if street then
      return {
        kind = "street",
        resource = resourceName(apiValue.res and apiValue.res.streetTypeRep,
          safeField(street, "streetType")),
        bus = safeField(street, "hasBus") == true,
        tramTrackType = util.integer(safeField(street, "tramTrackType"), 0),
      }
    end
    if track then
      return {
        kind = "track",
        resource = resourceName(apiValue.res and apiValue.res.trackTypeRep,
          safeField(track, "trackType")),
        catenary = safeField(track, "catenary") == true,
      }
    end
    return { kind = "none" }
  end

  local function endpoint(edge, field, tangentField)
    local nodeId = tonumber(safeField(edge, field))
    if not nodeId then return nil end
    return {
      position = stablePosition(positionOf(nodeId)),
      tangent = vector(safeField(edge, tangentField)),
    }
  end

  local function neighbourStubs(nodeId, excludedEdgeId, types, apiValue)
    local node = component(nodeId, types.BASE_NODE)
    local ids = boundedIds(safeField(node, "edges") or safeField(node, "edgeIds"))
    local result = {}
    for _, edgeId in ipairs(ids) do
      if tonumber(edgeId) ~= tonumber(excludedEdgeId) then
        local edge = component(edgeId, types.BASE_EDGE)
        if edge then
          local node0, node1 = tonumber(safeField(edge, "node0")), tonumber(safeField(edge, "node1"))
          local other = node0 == tonumber(nodeId) and node1 or node0
          local tangentField = node0 == tonumber(nodeId) and "tangent0" or "tangent1"
          result[#result + 1] = {
            other = other and stablePosition(positionOf(other)) or nil,
            tangent = vector(safeField(edge, tangentField)),
            carrier = carrier(edgeId, types, apiValue),
          }
        end
      end
    end
    table.sort(result, function(a, b) return hash.value(a) < hash.value(b) end)
    return result
  end

  local function describe(id, kind, options)
    options = options or {}
    local apiValue = getApi() or {}
    local types = apiValue.type and apiValue.type.ComponentType or {}
    local value = {
      schemaVersion = M.SCHEMA_VERSION,
      kind = tostring(kind),
      owner = ownerCid(id, kind, options),
    }
    if kind == "node" then
      local node = component(id, types.BASE_NODE)
      if not node then return nil, "BASE_NODE is unavailable" end
      value.position = stablePosition(positionOf(id))
      if options.includeNeighbours ~= false then
        value.neighbours = neighbourStubs(id, nil, types, apiValue)
      end
      if not value.position then return nil, "node position is unavailable" end
    elseif kind == "edge" then
      local edge = component(id, types.BASE_EDGE)
      if not edge then return nil, "BASE_EDGE is unavailable" end
      local first = endpoint(edge, "node0", "tangent0")
      local second = endpoint(edge, "node1", "tangent1")
      if not first or not second or not first.position or not second.position
        or not first.tangent or not second.tangent then
        return nil, "edge geometry is incomplete"
      end
      if hash.value(second.position) < hash.value(first.position) then first, second = second, first end
      value.endpoints = { first, second }
      value.carrier = carrier(id, types, apiValue)
      local node0, node1 = tonumber(safeField(edge, "node0")), tonumber(safeField(edge, "node1"))
      if options.includeNeighbours ~= false then
        value.neighbours = {
          node0 and neighbourStubs(node0, id, types, apiValue) or {},
          node1 and neighbourStubs(node1, id, types, apiValue) or {},
        }
        if hash.value(value.neighbours[2]) < hash.value(value.neighbours[1]) then
          value.neighbours[1], value.neighbours[2] = value.neighbours[2], value.neighbours[1]
        end
      end
    elseif kind == "construction" then
      local construction = component(id, types.CONSTRUCTION)
      if not construction then return nil, "CONSTRUCTION is unavailable" end
      value.resource = tostring(safeField(construction, "fileName") or "")
      value.transform = matrix(safeField(construction, "transf")
        or safeField(construction, "transform"))
      local ok, digest = pcall(hash.value, safeField(construction, "params"))
      if ok then value.paramsDigest = digest end
    elseif kind == "edge_object" then
      value.name = stableName(id)
      value.position = stablePosition(positionOf(id))
    else
      value.name = stableName(id)
    end
    return value
  end

  local function fingerprints(id, kind, options)
    local value, err = describe(id, kind, options)
    if not value then return nil, nil, err end
    local intrinsic = util.deepCopy(value)
    local neighbours = intrinsic.neighbours
    intrinsic.neighbours = nil
    return hash.value(intrinsic), neighbours and hash.value(neighbours) or nil, nil, value
  end

  return {
    describe = describe,
    fingerprints = fingerprints,
    fingerprint = function(id, kind, options)
      local intrinsicOptions = util.deepCopy(options or {})
      intrinsicOptions.includeNeighbours = false
      local value, err = describe(id, kind, intrinsicOptions)
      if not value then return nil, err end
      value.neighbours = nil
      return hash.value(value), nil, value
    end,
    neighbourFingerprint = function(id, kind, options)
      local _, neighbours, err, value = fingerprints(id, kind, options)
      return neighbours, err, value
    end,
    expectedConstructionFingerprint = M.expectedConstructionFingerprint,
  }
end

return M
