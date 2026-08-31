local canonical = require "tpf2_mp/canonical"
local constructionMaterializerOk, constructionProposalMaterializer =
  pcall(require, "tpf2_mp/construction_proposal_materializer")
if not constructionMaterializerOk then
  constructionProposalMaterializer = require "tpf2_mp_probe/construction_proposal_materializer"
end
local hash = require "tpf2_mp/hash"
local util = require "tpf2_mp/util"

-- Canonical, pointer-free BuildProposal vertical slice.  The native proposal
-- types contain process-local entity IDs and userdata; none of those values
-- may cross the network unchanged.  This module currently supports the
-- physical core measured on Build 35924: street/track edges and their nodes,
-- including live-proven topology-preserving upgrades and automated
-- removal-only bulldozer proposals. Schema 5 adds
-- canonical edge objects (signals/waypoints), while schema 7 adds portable
-- construction build/upgrade/remove records, including ASSET_DEFAULT roots
-- that have ASSET_GROUP but no CONSTRUCTION component. Every data-driven resource is
-- addressed by repository name; native entity and repository ids stay local.
local M = {
  SCHEMA_VERSION = 5,
  CONSTRUCTION_SCHEMA_VERSION = 7,
  MAX_NODES = 256,
  MAX_EDGES = 256,
  MAX_EDGE_OBJECTS = 256,
  MAX_CONSTRUCTION_NODES = 1024,
  MAX_CONSTRUCTION_EDGES = 1024,
  MAX_REMOVALS = 512,
  MAX_CONSTRUCTIONS = 1,
  MAX_CONSTRUCTION_COLLATERAL = 64,
  MAX_CONSTRUCTION_PARAM_VALUES = 8192,
  MAX_CONSTRUCTION_PARAM_DEPTH = 16,
}

local function safeField(value, key)
  local valueType = type(value)
  if valueType ~= "table" and valueType ~= "userdata" then return nil end
  local ok, result = pcall(function() return value[key] end)
  if not ok then return nil end
  return result
end

local function finite(value)
  value = tonumber(value)
  if not value or value ~= value or value == math.huge or value == -math.huge then return nil end
  return value
end

local function integer(value)
  value = finite(value)
  if not value or value ~= math.floor(value) then return nil end
  return value
end

local function entries(value)
  local result = {}
  if type(value) == "table" then
    for key, item in pairs(value) do
      if key ~= "__type" and key ~= "__truncated" then
        local order = tonumber(key)
        if item ~= nil and order and order >= 1 and order == math.floor(order) then
          result[#result + 1] = { order = order, value = item }
        end
      end
    end
  elseif type(value) == "userdata" then
    local lengthOk, length = pcall(function() return #value end)
    if lengthOk and integer(length) then
      for index = 1, math.min(length,
        M.MAX_REMOVALS + M.MAX_EDGES + M.MAX_NODES + M.MAX_EDGE_OBJECTS) do
        local readOk, item = pcall(function() return value[index] end)
        if readOk and item ~= nil then result[#result + 1] = { order = index, value = item } end
      end
    end
  end
  table.sort(result, function(a, b) return a.order < b.order end)
  return result
end

local function nonEmpty(value)
  return #entries(value) > 0
end

local function findField(root, names, maxDepth)
  local wanted = {}
  for _, name in ipairs(names) do wanted[name] = true end
  local seen = {}
  local function walk(value, depth)
    local valueType = type(value)
    if (valueType ~= "table" and valueType ~= "userdata") or seen[value] or depth > (maxDepth or 8) then
      return nil
    end
    seen[value] = true
    for _, name in ipairs(names) do
      local nested = safeField(value, name)
      if nested ~= nil and nonEmpty(nested) then return nested, name end
    end
    if valueType == "table" then
      local keys = util.sortedKeys(value)
      for _, key in ipairs(keys) do
        if key ~= "__type" and key ~= "__truncated" and not wanted[tostring(key)] then
          local found, name = walk(value[key], depth + 1)
          if found then return found, name end
        end
      end
    else
      for _, name in ipairs({ "proposal", "data", "streetProposal" }) do
        local found, field = walk(safeField(value, name), depth + 1)
        if found then return found, field end
      end
    end
    return nil
  end
  return walk(root, 0)
end

local function vec3(value, label)
  local x = finite(safeField(value, "x") or safeField(value, 1))
  local y = finite(safeField(value, "y") or safeField(value, 2))
  local z = finite(safeField(value, "z") or safeField(value, 3))
  if not x or not y or not z then return nil, tostring(label) .. " is not a finite Vec3" end
  if math.abs(x) > 10000000 or math.abs(y) > 10000000 or math.abs(z) > 10000000 then
    return nil, tostring(label) .. " is outside the supported coordinate range"
  end
  return { x = x, y = y, z = z }
end

local function entityId(value)
  local direct = integer(value)
  if direct then return direct end
  return integer(safeField(value, "entity") or safeField(value, "entityId") or safeField(value, "id"))
end

local function canonicalReference(kind, localId, slots, options)
  if localId == nil then return nil, kind .. " reference is missing" end
  if localId < 0 then
    local slot = slots[localId]
    if not slot then return nil, "unknown temporary " .. kind .. " id " .. tostring(localId) end
    return { slot = slot }
  end
  local cid
  if type(options.resolveCanonical) == "function" then
    local ok, value, resolveError = pcall(options.resolveCanonical, kind, localId)
    if not ok then return nil, tostring(value) end
    if value == nil then return nil, tostring(resolveError or ("unmapped existing " .. kind .. " " .. localId)) end
    cid = value
  elseif options.registry then
    cid = canonical.resolveCanonical(options.registry, kind, localId)
  end
  if type(cid) ~= "string" or cid == "" then
    return nil, "existing " .. kind .. " " .. tostring(localId) .. " has no canonical mapping"
  end
  return { cid = cid }
end

local function uniqueScalarField(root, field, expectedType)
  local seen, values = {}, {}
  local function add(value)
    if expectedType == "integer" then value = integer(value)
    elseif type(value) ~= expectedType then value = nil end
    if value ~= nil then values[tostring(value)] = value end
  end
  local function walk(value, depth)
    local valueType = type(value)
    if (valueType ~= "table" and valueType ~= "userdata") or seen[value] or depth > 10 then return end
    seen[value] = true
    add(safeField(value, field))
    if valueType == "table" then
      for _, key in ipairs(util.sortedKeys(value)) do
        if key ~= "__type" and key ~= "__truncated" then walk(value[key], depth + 1) end
      end
    else
      for _, name in ipairs({
        "proposal", "data", "context", "params", "streetProposal", "edgesToAdd", "addedSegments",
        "streetEdge", "trackEdge", "__builderData", "__builderParams", "__builderContext",
      }) do
        walk(safeField(value, name), depth + 1)
      end
    end
  end
  walk(root, 0)
  local keys = util.sortedKeys(values)
  if #keys == 1 then return values[keys[1]] end
  if #keys > 1 then return nil, "proposal contains conflicting " .. field .. " selections" end
  return nil
end

local function resource(kind, component, options, root)
  local field = kind == "street" and "streetType" or "trackType"
  local index = integer(safeField(component, field))
  local fallbackError
  if index == nil then index, fallbackError = uniqueScalarField(root, field, "integer") end
  if index == nil then return nil, fallbackError or (kind .. " edge has no " .. field) end
  local result = { index = index }
  if type(options.resourceName) == "function" then
    local ok, name = pcall(options.resourceName, kind, index)
    if ok and type(name) == "string" and name ~= "" then result.name = name end
  end
  if options.requireResourceName == true and result.name == nil then
    return nil, kind .. " resource " .. tostring(index)
      .. " has no stable repository filename; refusing a machine-local network identity"
  end
  return result
end

local function removalList(root, names, kind, options)
  local container = findField(root, names)
  if not container then return {} end
  local result, seen = {}, {}
  for _, entry in ipairs(entries(container)) do
    local localId = entityId(entry.value)
    if localId and localId >= 0 and not seen[localId] then
      local reference, err = canonicalReference(kind, localId, {}, options)
      if not reference then return nil, err end
      seen[localId] = true
      result[#result + 1] = reference.cid
    elseif localId and localId < 0 then
      return nil, "removal list contains temporary " .. kind .. " id " .. tostring(localId)
    end
  end
  table.sort(result)
  if #result > M.MAX_REMOVALS then return nil, "too many " .. kind .. " removals" end
  return result
end

local function constructionAdditions(root)
  -- The general projection can expose a shallow/opaque `toAdd` before the
  -- independently budgeted construction projection. Always prefer the latter
  -- when it exists; it is the only Build 35924 capture with the full 4x4
  -- transform and module table.
  local deep = findField(root, { "__constructionAdditions" })
  if deep and nonEmpty(deep) then return deep end
  return findField(root, { "constructionsToAdd", "toAdd" })
end

local function constructionRemovals(root)
  local deep = findField(root, { "__constructionRemovals" })
  if deep and nonEmpty(deep) then return deep end
  return findField(root, { "constructionsToRemove", "toRemove" })
end

local function unsupported(root, allowConstructionAddition, allowConstructionRemoval)
  local additions = constructionAdditions(root)
  if additions and nonEmpty(additions) and not allowConstructionAddition then
    return "construction additions are not supported by proposal schema 5"
  end
  local removals = constructionRemovals(root)
  if removals and nonEmpty(removals) and not allowConstructionRemoval then
    return "construction removals are not supported by proposal schema 7"
  end
  return nil
end

local DIAGNOSTIC_LOCAL_FIELDS = {
  entity = true, entityId = true, id = true, localId = true,
  player = true, playerEntity = true, owner = true, playerOwned = true,
}

local function diagnosticKeys(value, maximum)
  local result = {}
  if type(value) == "table" then
    for _, key in ipairs(util.sortedKeys(value)) do
      if key ~= "__type" and key ~= "__truncated" then
        result[#result + 1] = tostring(key)
        if #result >= (maximum or 64) then break end
      end
    end
  end
  return result
end

local function indexedField(value, index)
  return safeField(value, index) or safeField(value, tostring(index))
end

local function diagnosticTransform(value)
  local function read(first)
    local result = {}
    for offset = 0, 15 do
      local item = finite(indexedField(value, first + offset))
      if item == nil then return nil end
      result[#result + 1] = item
    end
    return result
  end
  return read(1) or read(0)
end

-- Preserve bounded scalar construction facts while deliberately dropping
-- machine-local entity/player identifiers.  This is discovery evidence, not
-- a replay payload; the eventual codec still needs an allow-list, canonical
-- graph binding and postcondition consensus before constructions can pass.
local function diagnosticProjection(value, depth, seen, budget)
  depth, seen, budget = depth or 0, seen or {}, budget or { remaining = 192 }
  if budget.remaining <= 0 or depth > 6 then return nil end
  local valueType = type(value)
  if valueType == "boolean" then return value end
  if valueType == "number" then return finite(value) end
  if valueType == "string" then
    if value:sub(1, 1) == "<" and value:sub(-1) == ">" then return nil end
    return #value <= 240 and value or value:sub(1, 237) .. "..."
  end
  if valueType ~= "table" and valueType ~= "userdata" then return nil end
  if seen[value] then return nil end
  seen[value] = true
  budget.remaining = budget.remaining - 1
  local result, count = {}, 0
  if valueType == "table" then
    for _, key in ipairs(util.sortedKeys(value)) do
      local keyText = tostring(key)
      if keyText ~= "__type" and keyText ~= "__truncated" and not DIAGNOSTIC_LOCAL_FIELDS[keyText] then
        local projected = diagnosticProjection(value[key], depth + 1, seen, budget)
        if projected ~= nil then
          result[keyText] = projected
          count = count + 1
          if count >= 96 or budget.remaining <= 0 then break end
        end
      end
    end
  else
    -- Live values should normally have passed through the GUI's pointer-free
    -- projection already. Keep a small userdata fallback for direct probes.
    for _, key in ipairs({ "fileName", "params", "modules", "metadata", "trackType", "streetType",
      "catenary", "stationType", "depotType", "terminal", "cargo", "passenger", "capacity" }) do
      local nested = safeField(value, key)
      local projected = diagnosticProjection(nested, depth + 1, seen, budget)
      if projected ~= nil then result[key] = projected; count = count + 1 end
    end
  end
  seen[value] = nil
  return count > 0 and result or nil
end

local function constructionDiagnostic(value)
  local fileName = safeField(value, "fileName") or safeField(value, "name")
  local transform = safeField(value, "transf") or safeField(value, "transform")
  local params = safeField(value, "params") or safeField(value, "param")
  local text = type(fileName) == "string" and fileName or nil
  local lower = text and string.lower(text) or ""
  local modules = safeField(params, "modules")
  return {
    fileName = text,
    kindHint = lower:find("station", 1, true) and "station"
      or (lower:find("depot", 1, true) and "depot" or nil),
    hasTransform = type(transform) == "table" or type(transform) == "userdata",
    transformKeys = diagnosticKeys(transform, 20),
    transform = diagnosticTransform(transform),
    hasParams = type(params) == "table" or type(params) == "userdata",
    paramKeys = diagnosticKeys(params, 96),
    params = diagnosticProjection(params),
    moduleCount = #entries(modules),
    modules = diagnosticProjection(modules),
  }
end

local function edgeObjectDiagnostic(value)
  local instance = safeField(value, "modelInstance")
  local transform = safeField(instance, "transf") or safeField(instance, "transform")
  return {
    entity = integer(safeField(value, "entity") or safeField(value, "entityId")),
    edgeEntity = integer(safeField(value, "edgeEntity")
      or safeField(value, "segmentEntity") or safeField(value, "edge")),
    param = finite(safeField(value, "param")),
    position = finite(safeField(value, "position")),
    category = integer(safeField(value, "category") or safeField(value, "type")),
    left = type(safeField(value, "left")) == "boolean" and safeField(value, "left") or nil,
    oneWay = type(safeField(value, "oneWay")) == "boolean" and safeField(value, "oneWay") or nil,
    model = safeField(value, "model") or safeField(value, "fileName")
      or safeField(value, "modelName"),
    modelId = integer(safeField(value, "modelId") or safeField(instance, "modelId")),
    modelTransform = diagnosticTransform(transform),
  }
end

-- Local-only discovery summary for unsupported vanilla proposal categories.
-- It deliberately exposes shape/resource facts, not a replay payload. This is
-- persisted in research evidence when a station/depot attempt fails closed,
-- so the next codec slice can be based on measured Build 35924 data.
function M.diagnose(root)
  if type(root) ~= "table" and type(root) ~= "userdata" then
    return { supported = false, error = "proposal root is unavailable" }
  end
  local nodeContainer = findField(root, { "nodesToAdd", "addedNodes" })
  local edgeContainer = findField(root, { "edgesToAdd", "addedSegments" })
  local nodeRemovals = findField(root, { "nodesToRemove", "removedNodes" })
  local edgeRemovals = findField(root, { "edgesToRemove", "removedSegments" })
  local constructionAdds = constructionAdditions(root)
  local constructionRemovals = constructionRemovals(root)
  local edgeObjectAdds = findField(root, { "edgeObjectsToAdd" })
  local edgeObjectRemovals = findField(root, { "edgeObjectsToRemove" })
  local result = {
    schemaVersion = M.SCHEMA_VERSION,
    supported = unsupported(root) == nil,
    unsupportedReason = unsupported(root),
    counts = {
      nodesToAdd = #entries(nodeContainer),
      edgesToAdd = #entries(edgeContainer),
      nodesToRemove = #entries(nodeRemovals),
      edgesToRemove = #entries(edgeRemovals),
      constructionsToAdd = #entries(constructionAdds),
      constructionsToRemove = #entries(constructionRemovals),
      edgeObjectsToAdd = #entries(edgeObjectAdds),
      edgeObjectsToRemove = #entries(edgeObjectRemovals),
    },
    constructionSamples = {},
    edgeObjectSamples = {},
  }
  for index, entry in ipairs(entries(constructionAdds)) do
    if index > 8 then break end
    result.constructionSamples[#result.constructionSamples + 1] = constructionDiagnostic(entry.value)
  end
  for index, entry in ipairs(entries(edgeObjectAdds)) do
    if index > 8 then break end
    result.edgeObjectSamples[#result.edgeObjectSamples + 1] = edgeObjectDiagnostic(entry.value)
  end
  return result
end

local STATION_FILE = "station/rail/modular_station/modular_station.con"
local STATION_PREFIX = "station/rail/modular_station/"
local STATION_MAX_MODULES = 256

local function stationEra(year)
  return year < 1920 and "a" or (year < 1980 and "b" or "c")
end

-- Port of Build 35924 modular_station.con:createTemplateFn. Keeping this
-- deterministic generator on both sides of the wire lets us accept the stock
-- menu's complete station family without accepting arbitrary module maps.
local function stockStationModules(params, cargo, head)
  local result = {}
  local era = stationEra(params.year)
  local variant = cargo and "cargo" or ("era_" .. era)
  local layoutLengths = { 1, 2, 3, 5, 7 }
  local layoutLength = layoutLengths[params.length + 1]
  if not layoutLength then return nil end
  local s = -math.floor(layoutLength / 2)
  local e = math.ceil(layoutLength / 2)
  local even = (e - s) % 2 == 0
  local offset, level, mainBuilding = 1, 3,
    STATION_PREFIX .. "main_building_3_" .. variant .. ".module"
  if params.tracks < 3 then
    offset, level = 0, 1
    mainBuilding = STATION_PREFIX .. "main_building_1_" .. variant .. ".module"
  elseif params.tracks < 6 then
    offset, level = 0, 2
    mainBuilding = STATION_PREFIX .. "main_building_2_" .. variant .. ".module"
  end

  local function mainId(subtype, i, j, k, o)
    o = o or 0
    if subtype == "headLeft" then return 3400000 + 300000 + 1000 * i + 20 * j + o end
    if subtype == "headRight" then return 3400000 + 400000 + 1000 * i + 20 * j + o end
    if subtype == "throughFront" then return 3400000 + 200000 + 3000 * i + 40 * j + 10 * k + o end
    return 3400000 + 3000 * i + 40 * j + 10 * k + o
  end
  local function trackId(i, j) return 8400000 + 1000 * i + 10 * j end
  local function platformId(isCargo, i, j)
    return (isCargo and 6400000 or 7400000) + 1000 * i + 10 * j
  end
  local function addonId(roof, i, j)
    return (roof and 10400000 or 10800000) + 1000 * i + 10 * j
  end
  local function addTrack(i)
    local track
    if params.trackType == 0 then
      track = params.catenary == 1 and "platform_track_catenary.module" or "platform_track.module"
    else
      track = params.catenary == 1 and "platform_high_speed_track_catenary.module"
        or "platform_high_speed_track.module"
    end
    for j = s, e do result[trackId(i, j)] = STATION_PREFIX .. track end
  end
  local function addCargo(i)
    for j = s, e do
      result[platformId(true, i, j)] = STATION_PREFIX .. "platform_cargo_era_" .. era .. ".module"
    end
  end
  local function addPassenger(i)
    local center = math.floor((e - s) / 2) + s
    local dist = e - s
    local roof = STATION_PREFIX .. "platform_passenger_roof_era_" .. era .. ".module"
    local curvedRoof = level == 3 and era == "c"
      and STATION_PREFIX .. "platform_passenger_roof_curved_era_c.module" or roof
    local underpass = STATION_PREFIX .. "addon_platform_passenger_stairs_era_" .. era .. ".module"
    local platform = STATION_PREFIX .. "platform_passenger_era_" .. era .. ".module"
    for j = s, e do
      result[platformId(false, i, j)] = platform
      if not head then
        if j == center or (dist > 3 and j == s + 1) or (dist > 3 and j == e - 1) then
          result[addonId(false, i, j)] = underpass
        end
        if (j ~= s and j ~= e) or e - s <= 3 then
          result[addonId(true, i, j)] = ((not even and (j == center or j == center + 1)) or j == center)
            and curvedRoof or roof
        end
      else
        if j == center or j == s or (dist > 3 and j == e - 1) then
          result[addonId(false, i, j)] = underpass
        end
        if j ~= e or j == s or j == s + 1 then
          result[addonId(true, i, j)] = j == s and curvedRoof or roof
        end
      end
    end
  end
  local function sideModule(sideLevel)
    local sideOffset = 4 + sideLevel
    if sideLevel == 3 and variant ~= "era_c" then sideOffset = 6 end
    return STATION_PREFIX .. "side_building_" .. sideLevel .. "_" .. variant .. ".module", sideOffset
  end

  if head then
    local multiplier = cargo and 2 or 1
    local c = (math.floor((params.tracks + 1) / 2) + 1) * multiplier + 1 + params.tracks
    c = math.floor(c / 2) - 1
    result[mainId("headLeft", c, -math.floor(layoutLength / 2), nil, offset)] = mainBuilding
  else
    local k = even and 0 or 2
    result[3400000 + 10 * k + offset] = mainBuilding
    if level >= 3 then
      local i = variant == "era_c" and 2 or 0
      if layoutLength > 5 then
        local module, o = sideModule(level - 2)
        result[mainId("throughBack", 0, 2, k + i, o)] = module
        result[mainId("throughBack", 0, -2, k - 1 - i, o)] = module
        module, o = sideModule(level - 1)
        result[mainId("throughBack", 0, 2, k - 1 + i, o)] = module
        result[mainId("throughBack", 0, -2, k + 1 - i, o)] = module
        result[mainId("throughBack", 0, 1, k + 1 + i, o)] = module
        result[mainId("throughBack", 0, -1, k - 1 - i, o)] = module
        module, o = sideModule(level)
        result[mainId("throughBack", 0, 1, k - 1 + i / 2, o)] = module
        result[mainId("throughBack", 0, -1, k + 1 - i / 2, o)] = module
      elseif layoutLength > 4 then
        local module, o = sideModule(level - 2)
        result[mainId("throughBack", 0, 2, k - 2 + i, o)] = module
        result[mainId("throughBack", 0, -2, k + 1 - i, o)] = module
        module, o = sideModule(level - 1)
        result[mainId("throughBack", 0, 1, k + 1 + i, o)] = module
        result[mainId("throughBack", 0, -1, k - 1 - i, o)] = module
        module, o = sideModule(level)
        result[mainId("throughBack", 0, 1, k - 1 + i / 2, o)] = module
        result[mainId("throughBack", 0, -1, k + 1 - i / 2, o)] = module
      elseif layoutLength > 3 then
        local module, o = sideModule(level - 2)
        result[mainId("throughBack", 0, 1, k, o)] = module
        result[mainId("throughBack", 0, -1, k - 1, o)] = module
        module, o = sideModule(level - 1)
        result[mainId("throughBack", 0, 1, k - 1, o)] = module
        result[mainId("throughBack", 0, -1, k + 1, o)] = module
      elseif layoutLength > 1 then
        local module, o = sideModule(level - 1)
        result[mainId("throughBack", 0, 1, k - 1, o)] = module
        result[mainId("throughBack", 0, -1, k + 1, o)] = module
      end
    elseif level >= 2 then
      if layoutLength > 4 then
        local module, o = sideModule(2)
        result[mainId("throughBack", 0, 0, k + 2, o)] = module
        result[mainId("throughBack", 0, -1, k + 2, o)] = module
        module, o = sideModule(1)
        result[mainId("throughBack", 0, 1, k - 1, o)] = module
        result[mainId("throughBack", 0, -1, k, o)] = module
      elseif layoutLength > 2 then
        local module, o = sideModule(1)
        result[mainId("throughBack", 0, 0, k + 1, o)] = module
        result[mainId("throughBack", 0, 0, k - 2, o)] = module
      end
    else
      if layoutLength > 2 then
        local module, o = sideModule(1)
        result[mainId("throughBack", 0, 0, k + 1, o)] = module
        result[mainId("throughBack", 0, 0, k - 2, o)] = module
      end
      if layoutLength > 4 then
        local module, o = sideModule(1)
        result[mainId("throughBack", 0, 0, k + 2, o)] = module
        result[mainId("throughBack", 0, -1, k + 1, o)] = module
      end
    end
  end

  if cargo then
    addCargo(0); addTrack(2)
    if params.tracks >= 1 then addTrack(3); addCargo(4) end
    if params.tracks >= 2 then addTrack(6) end
    if params.tracks >= 3 then addTrack(7); addCargo(8) end
    if params.tracks >= 4 then addTrack(10) end
    if params.tracks >= 5 then addTrack(11); addCargo(12) end
    if params.tracks >= 6 then addTrack(14) end
    if params.tracks >= 7 then addTrack(15); addCargo(16) end
  else
    addPassenger(0); addTrack(1)
    if params.tracks >= 1 then addTrack(2); addPassenger(3) end
    if params.tracks >= 2 then addTrack(4) end
    if params.tracks >= 3 then addTrack(5); addPassenger(6) end
    if params.tracks >= 4 then addTrack(7) end
    if params.tracks >= 5 then addTrack(8); addPassenger(9) end
    if params.tracks >= 6 then addTrack(10) end
    if params.tracks >= 7 then addTrack(11); addPassenger(12) end
  end
  return result
end

local function matchStockStationModules(moduleEntries, params)
  for _, cargo in ipairs({ false, true }) do
    for _, head in ipairs({ false, true }) do
      local candidate = stockStationModules(params, cargo, head)
      local matches = candidate and #moduleEntries == util.tableCount(candidate)
      if matches then
        for _, entry in ipairs(moduleEntries) do
          local module = entry.value
          local slot = integer(entry.order)
          local name = safeField(module, "name") or safeField(module, "fileName")
          local variant = integer(safeField(module, "variant") or 0)
          if not slot or variant ~= 0 or candidate[slot] ~= name then matches = false; break end
        end
      end
      if matches then return candidate, { cargo = cargo, head = head } end
    end
  end
  return nil
end

local function affineTransform(value)
  local transform = diagnosticTransform(value)
  if not transform then return nil, "station construction transform is not a finite 4x4 matrix" end
  for _, item in ipairs(transform) do
    if math.abs(item) > 10000000 then return nil, "station construction transform is outside the supported range" end
  end
  local epsilon = 0.002
  for _, index in ipairs({ 3, 4, 7, 8, 9, 10, 12 }) do
    if math.abs(transform[index]) > epsilon then return nil, "station construction transform is not planar affine" end
  end
  if math.abs(transform[11] - 1) > epsilon or math.abs(transform[16] - 1) > epsilon then
    return nil, "station construction transform has an invalid homogeneous axis"
  end
  local a, b, c, d = transform[1], transform[2], transform[5], transform[6]
  if math.abs(a * a + b * b - 1) > epsilon
    or math.abs(c * c + d * d - 1) > epsilon
    or math.abs(a * c + b * d) > epsilon
    or math.abs(a * d - b * c - 1) > epsilon then
    return nil, "station construction transform contains scale, skew, or reflection"
  end
  return transform
end

local function normaliseStationConstruction(value)
  local fileName = safeField(value, "fileName") or safeField(value, "name")
  if fileName ~= STATION_FILE then
    return nil, "only the stock modular rail station is supported"
  end
  local transform, transformError = affineTransform(safeField(value, "transf") or safeField(value, "transform"))
  if not transform then return nil, transformError end
  local sourceParams = safeField(value, "params") or safeField(value, "param")
  if type(sourceParams) ~= "table" and type(sourceParams) ~= "userdata" then
    return nil, "station construction params are unavailable"
  end
  local params = {
    year = integer(safeField(sourceParams, "year")),
    seed = integer(safeField(sourceParams, "seed")),
    trackType = integer(safeField(sourceParams, "trackType")),
    catenary = integer(safeField(sourceParams, "catenary")),
    length = integer(safeField(sourceParams, "length")),
    tracks = integer(safeField(sourceParams, "tracks")),
    paramX = integer(safeField(sourceParams, "paramX")),
    paramY = integer(safeField(sourceParams, "paramY")),
  }
  if not params.year or params.year < 1850 or params.year > 3000 then return nil, "station year is invalid" end
  if not params.seed or params.seed < 0 or params.seed > 2147483647 then return nil, "station seed is invalid" end
  if (params.trackType ~= 0 and params.trackType ~= 1)
    or (params.catenary ~= 0 and params.catenary ~= 1)
    or not params.length or params.length < 0 or params.length > 4
    or not params.tracks or params.tracks < 0 or params.tracks > 7
    or params.paramX ~= 0 or params.paramY ~= 0 then
    return nil, "station layout parameters are outside the stock modular menu range"
  end
  local moduleEntries = entries(safeField(sourceParams, "modules"))
  if #moduleEntries == 0 or #moduleEntries > STATION_MAX_MODULES then
    return nil, "station template module count is outside the supported range"
  end
  local expected = matchStockStationModules(moduleEntries, params)
  if not expected then return nil, "station module set does not match the supported stock template" end
  local modules = {}
  for index, entry in ipairs(moduleEntries) do
    local slot = integer(entry.order)
    local module = entry.value
    local name = safeField(module, "name") or safeField(module, "fileName")
    local variant = integer(safeField(module, "variant") or 0)
    if variant ~= 0 then return nil, "station module variants are not supported" end
    modules[index] = { slot = slot, name = name, variant = 0, metadata = {} }
  end
  return {
    slot = "construction:1",
    kind = "rail_station",
    fileName = STATION_FILE,
    transform = transform,
    params = params,
    modules = modules,
  }
end

local function validateStationGraph(nodes, edges, params)
  local trackCount = params.tracks + 1
  if #nodes == 0 or #edges == 0 then
    return false, "station graph is empty"
  end
  local adjacency, boundary = {}, {}
  for _, node in ipairs(nodes) do adjacency["slot:" .. node.slot] = {} end
  local function vertex(reference)
    if type(reference) ~= "table" then return nil end
    if reference.slot ~= nil then
      local key = "slot:" .. tostring(reference.slot)
      return adjacency[key] and key or nil
    end
    if type(reference.cid) == "string" and reference.cid:match("^node:") then
      local key = "cid:" .. reference.cid
      if adjacency[key] == nil then adjacency[key], boundary[key] = {}, true end
      return key
    end
    return nil
  end
  for _, edge in ipairs(edges) do
    if edge.carrier ~= "track" then return false, "station graph contains a non-track edge" end
    if edge.private ~= true then return false, "station graph edges must remain player-owned" end
    if edge.catenary ~= (params.catenary == 1) then
      return false, "station graph catenary differs from its module template"
    end
    local node0, node1 = vertex(edge.node0), vertex(edge.node1)
    if not node0 or not node1 or node0 == node1 or not adjacency[node0] or not adjacency[node1] then
      return false, "station graph must reference distinct new or canonical boundary nodes"
    end
    adjacency[node0][#adjacency[node0] + 1] = node1
    adjacency[node1][#adjacency[node1] + 1] = node0
  end
  local boundaryCount = util.tableCount(boundary)
  -- A station snapped to an existing track endpoint omits that endpoint from
  -- nodesToAdd and references its canonical node directly. Count those
  -- boundary vertices when proving that the captured graph is still exactly
  -- one simple path per platform track. This remains resource-agnostic and the
  -- preparation stage separately resolves and ownership-checks every cid.
  if #nodes + boundaryCount ~= #edges + trackCount then
    return false, "station graph cardinality does not match its track count"
  end
  for slot in pairs(boundary) do
    if #adjacency[slot] ~= 1 then
      return false, "station canonical boundary node must be a path endpoint"
    end
  end
  local visited, components = {}, 0
  for slot, neighbours in pairs(adjacency) do
    local degree = #neighbours
    if degree < 1 or degree > 2 then return false, "station track graph is not a set of simple paths" end
    if not visited[slot] then
      components = components + 1
      local pending, cursor, endpoints = { slot }, 1, 0
      visited[slot] = true
      while pending[cursor] do
        local current = pending[cursor]
        cursor = cursor + 1
        if #adjacency[current] == 1 then endpoints = endpoints + 1 end
        for _, neighbour in ipairs(adjacency[current]) do
          if not visited[neighbour] then
            visited[neighbour] = true
            pending[#pending + 1] = neighbour
          end
        end
      end
      if endpoints ~= 2 then return false, "station track component is not an open path" end
    end
  end
  if components ~= trackCount then return false, "station graph component count differs from its track count" end
  return true
end

local function portableResourceName(name, extension, label)
  if type(name) ~= "string" or name == "" or #name > 240
    or name:find("..", 1, true) or name:sub(1, 1) == "/"
    or name:match("^[A-Za-z]:") or name:find("\\", 1, true)
    or name:find("[%z\1-\31]") then
    return nil, tostring(label) .. " resource name is invalid"
  end
  if extension and name:sub(-#extension) ~= extension then
    return nil, tostring(label) .. " resource must end in " .. extension
  end
  return name
end

local PORTABLE_LOCAL_PARAM_FIELDS = {
  entity = true, entityId = true, localId = true,
  playerEntity = true, playerOwned = true,
}

local function portableTransform(value, label)
  local transform = diagnosticTransform(value)
  if not transform then return nil, tostring(label) .. " transform is not a finite 4x4 matrix" end
  for _, item in ipairs(transform) do
    if math.abs(item) > 10000000 then
      return nil, tostring(label) .. " transform is outside the supported range"
    end
  end
  return transform
end

-- GUI proposal snapshots are pointer-free but deliberately generic. Preserve
-- bounded scalar/table parameters exactly, canonicalise every key to text for
-- JSON, and reject values that prove the projection was opaque or truncated.
-- Numeric keys are restored by materialisePlainValue on each machine.
local function normalisePlainValue(value, label, depth, seen, budget, skipModules)
  depth, seen = depth or 0, seen or {}
  budget = budget or { remaining = M.MAX_CONSTRUCTION_PARAM_VALUES }
  if budget.remaining <= 0 then return nil, tostring(label) .. " exceeds the value limit" end
  if depth > M.MAX_CONSTRUCTION_PARAM_DEPTH then return nil, tostring(label) .. " exceeds the depth limit" end
  budget.remaining = budget.remaining - 1
  local valueType = type(value)
  if valueType == "boolean" then return value end
  if valueType == "number" then
    local number = finite(value)
    if number == nil or math.abs(number) > 1000000000000 then
      return nil, tostring(label) .. " contains an invalid number"
    end
    return number
  end
  if valueType == "string" then
    if #value > 4096 or value:find("[%z\1-\31]") then
      return nil, tostring(label) .. " contains an invalid string"
    end
    if value:sub(1, 1) == "<" and value:sub(-1) == ">" then
      return nil, tostring(label) .. " contains an opaque projected value"
    end
    return value
  end
  if valueType ~= "table" then
    return nil, tostring(label) .. " contains a non-portable " .. valueType
  end
  if safeField(value, "__truncated") then return nil, tostring(label) .. " was truncated during capture" end
  if seen[value] then return nil, tostring(label) .. " contains a cycle" end
  seen[value] = true
  local result = {}
  for _, key in ipairs(util.sortedKeys(value)) do
    local keyType = type(key)
    local keyText
    if keyType == "number" and integer(key) ~= nil then keyText = tostring(integer(key))
    elseif keyType == "string" then keyText = key
    else
      seen[value] = nil
      return nil, tostring(label) .. " contains a non-portable table key"
    end
    if keyText ~= "__type" and keyText ~= "__truncated"
      and not (skipModules and keyText == "modules") then
      if #keyText == 0 or #keyText > 240 or keyText:find("[%z\1-\31]") then
        seen[value] = nil
        return nil, tostring(label) .. " contains an invalid table key"
      end
      if PORTABLE_LOCAL_PARAM_FIELDS[keyText] then
        seen[value] = nil
        return nil, tostring(label) .. " contains machine-local field " .. keyText
      end
      local projected, projectError = normalisePlainValue(
        value[key], tostring(label) .. "." .. keyText, depth + 1, seen, budget, false)
      if projectError then seen[value] = nil; return nil, projectError end
      result[keyText] = projected
    end
  end
  seen[value] = nil
  return result
end

local function materialisePlainValue(value, depth)
  depth = depth or 0
  if type(value) ~= "table" then return value end
  if depth > M.MAX_CONSTRUCTION_PARAM_DEPTH then return nil end
  local result = {}
  for key, nested in pairs(value) do
    local restoredKey = key
    if type(key) == "string" and key:match("^-?%d+$") then
      local candidate = integer(key)
      if candidate ~= nil and tostring(candidate) == key then restoredKey = candidate end
    end
    result[restoredKey] = materialisePlainValue(nested, depth + 1)
  end
  return result
end

local function isResourceDerivedModuleMetadata(value)
  -- Build 35924 projects an empty/native MetadataMap as this exact sentinel.
  -- Module metadata is static resource data, not player-authored proposal
  -- state: construction_proposal_materializer resolves it again from the
  -- content-attested module name before assigning the native proposal. Keep
  -- every other opaque/truncated shape fail-closed.
  return value == "<userdata>"
end

local function normaliseConstructionModules(sourceParams)
  local moduleEntries = entries(safeField(sourceParams, "modules"))
  if #moduleEntries > STATION_MAX_MODULES then return nil, "construction module limit exceeded" end
  local modules, seenSlots = {}, {}
  for _, entry in ipairs(moduleEntries) do
    local slot = integer(entry.order)
    local module = entry.value
    if not slot or slot < 1 or seenSlots[slot] then return nil, "construction module slot is invalid" end
    seenSlots[slot] = true
    local name, nameError = portableResourceName(
      safeField(module, "name") or safeField(module, "fileName"), ".module", "construction module")
    if not name then return nil, nameError end
    local variant = integer(safeField(module, "variant") or 0)
    if variant == nil or variant < 0 or variant > 65535 then return nil, "construction module variant is invalid" end
    local metadataSource = safeField(module, "metadata")
    local metadata = {}
    if metadataSource ~= nil and not isResourceDerivedModuleMetadata(metadataSource) then
      local metadataError
      metadata, metadataError = normalisePlainValue(
        metadataSource, "construction module metadata", 0, nil,
        { remaining = M.MAX_CONSTRUCTION_PARAM_VALUES }, false)
      if not metadata then return nil, metadataError end
    end
    modules[#modules + 1] = { slot = slot, name = name, variant = variant, metadata = metadata }
  end
  table.sort(modules, function(a, b) return a.slot < b.slot end)
  return modules
end

local function constructionKind(fileName)
  local lower = string.lower(fileName or "")
  if lower:find("asset/", 1, true) == 1 then return "asset" end
  if lower:find("depot", 1, true) then return "depot" end
  if lower:find("station", 1, true) then return "station" end
  return "construction"
end

local function constructionRootKind(kind)
  return kind == "asset" and "asset" or "construction"
end

local function constructionSourceCid(entry, options, preferredKind)
  local localId = entityId(entry and entry.value)
  if localId == nil or localId < 0 then return nil, "construction removal has no existing entity id" end
  local rootKind = preferredKind and constructionRootKind(preferredKind) or nil
  if not rootKind and type(options.entityKind) == "function" then
    local ok, observed = pcall(options.entityKind, localId)
    if ok and (observed == "asset" or observed == "construction") then rootKind = observed end
  end
  rootKind = rootKind or "construction"
  local reference, referenceError = canonicalReference(rootKind, localId, {}, options)
  local proposalKind = rootKind
  if rootKind == "construction" and type(options.constructionKind) == "function" then
    local ok, observed = pcall(options.constructionKind, localId)
    if ok and (observed == "rail_station" or observed == "station"
      or observed == "depot" or observed == "construction") then
      proposalKind = observed
    end
  end
  return reference and reference.cid or nil, referenceError, rootKind, proposalKind
end

local function normaliseConstructionSources(removals, options)
  local result, seen = {}, {}
  for _, removal in ipairs(removals) do
    local cid, removalError, rootKind, proposalKind = constructionSourceCid(removal, options, nil)
    if not cid then return nil, removalError end
    local kind = rootKind == "asset" and "asset" or "construction"
    local key = kind .. ":" .. cid
    if seen[key] then return nil, "construction collateral contains a duplicate source" end
    seen[key] = true
    result[#result + 1] = { kind = kind, cid = cid, proposalKind = proposalKind }
  end
  table.sort(result, function(a, b)
    if a.kind ~= b.kind then return a.kind < b.kind end
    return a.cid < b.cid
  end)
  return result
end

local function normaliseConstructionCollateral(removals, options)
  local sources, sourceError = normaliseConstructionSources(removals, options)
  if not sources then return nil, sourceError end
  local result = {}
  for _, source in ipairs(sources) do
    result[#result + 1] = { kind = source.kind, cid = source.cid }
  end
  return result
end

local function normaliseConstructionChange(additions, removals, options)
  if #additions > M.MAX_CONSTRUCTIONS or #removals > M.MAX_CONSTRUCTION_COLLATERAL then
    return nil, "canonical construction proposal exceeds its bounded change limit"
  end
  if #additions == 0 and #removals < 1 then
    return nil, "a canonical bulldoze must name at least one construction root"
  end
  local value = #additions == 1 and additions[1].value or nil
  local rawFileName = value and (safeField(value, "fileName") or safeField(value, "name")) or nil
  local prospectiveKind = rawFileName and constructionKind(rawFileName) or nil
  local sourceParams = value and (safeField(value, "params") or safeField(value, "param")) or nil
  local explicitUpgrade = value ~= nil and safeField(sourceParams, "upgrade") == true
  if explicitUpgrade and #removals ~= 1 then
    return nil, "a construction upgrade must name exactly one canonical source"
  end
  local mode = value == nil and "remove" or (explicitUpgrade and "upgrade" or "build")
  local sourceCid = ""
  local sourceRootKind
  local sourceProposalKind
  local collateral = {}
  if mode == "build" then
    local collateralError
    collateral, collateralError = normaliseConstructionCollateral(removals, options)
    if not collateral then return nil, collateralError end
  elseif mode == "remove" then
    -- A road/track BuildProposal can atomically replace topology and bulldoze
    -- one or more obstructing constructions.  Schema 7 has one primary root,
    -- so choose it from the canonically sorted removal set and retain the rest
    -- as collateral.  The distinction is representational only: materialise()
    -- writes every entry back to constructionsToRemove in one native command.
    local removalsCanonical, removalError = normaliseConstructionSources(removals, options)
    if not removalsCanonical then return nil, removalError end
    local primary = table.remove(removalsCanonical, 1)
    sourceCid = primary.cid
    sourceRootKind = primary.kind
    sourceProposalKind = primary.proposalKind
    for _, removal in ipairs(removalsCanonical) do
      collateral[#collateral + 1] = { kind = removal.kind, cid = removal.cid }
    end
  elseif #removals == 1 then
    local sourceError
    sourceCid, sourceError, sourceRootKind = constructionSourceCid(
      removals[1], options, prospectiveKind)
    if not sourceCid then return nil, sourceError end
  end
  if mode == "remove" then
    return {
      slot = "construction:1", mode = mode, adapter = "portable-construction",
      kind = sourceRootKind == "asset" and "asset" or sourceProposalKind or "construction",
      sourceCid = sourceCid, fileName = "",
      transform = {}, params = {}, modules = {}, collateral = collateral,
    }
  end

  if mode == "build" and rawFileName == STATION_FILE then
    local station, stationError = normaliseStationConstruction(value)
    if not station then return nil, stationError end
    station.mode = mode
    station.adapter = "stock-rail-station"
    station.sourceCid = sourceCid
    station.collateral = collateral
    return station
  end
  local fileName, fileError = portableResourceName(rawFileName, ".con", "construction")
  if not fileName then return nil, fileError end
  local transform, transformError = portableTransform(
    safeField(value, "transf") or safeField(value, "transform"), "construction")
  if not transform then return nil, transformError end
  local sourceParams = safeField(value, "params") or safeField(value, "param")
  if type(sourceParams) ~= "table" then return nil, "construction params are unavailable or opaque" end
  local params, paramsError = normalisePlainValue(
    sourceParams, "construction params", 0, nil,
    { remaining = M.MAX_CONSTRUCTION_PARAM_VALUES }, true)
  if not params then return nil, paramsError end
  local modules, modulesError = normaliseConstructionModules(sourceParams)
  if not modules then return nil, modulesError end
  return {
    slot = "construction:1", mode = mode, adapter = "portable-construction",
    kind = constructionKind(fileName), sourceCid = sourceCid, fileName = fileName,
    transform = transform, params = params, modules = modules, collateral = collateral,
  }
end

local function edgeObjectModel(value, options)
  local model = safeField(value, "model") or safeField(value, "fileName")
    or safeField(value, "modelName")
  local modelInstance = safeField(value, "modelInstance")
  if model == nil then
    model = safeField(modelInstance, "model") or safeField(modelInstance, "fileName")
      or safeField(modelInstance, "modelName")
  end
  if type(model) == "string" then return portableResourceName(model, ".mdl", "edge-object model") end
  local index = integer(model or safeField(value, "modelId") or safeField(modelInstance, "modelId"))
  if index ~= nil and type(options.resourceName) == "function" then
    local ok, name = pcall(options.resourceName, "model", index)
    if ok then return portableResourceName(name, ".mdl", "edge-object model") end
  end
  return nil, "edge-object model has no stable repository filename"
end

local function edgeObjectWorldPosition(value)
  local instance = safeField(value, "modelInstance")
  local transform = safeField(instance, "transf") or safeField(instance, "transform")
  if transform == nil and type(instance) == "table" then transform = instance.transform end
  local matrix = transform and diagnosticTransform(transform) or nil
  if not matrix then return nil end
  return vec3({ matrix[13], matrix[14], matrix[15] }, "edge-object model position")
end

local function cubicPoint(p0, p1, tangent0, tangent1, t)
  local tt, ttt = t * t, t * t * t
  local h00 = 2 * ttt - 3 * tt + 1
  local h10 = ttt - 2 * tt + t
  local h01 = -2 * ttt + 3 * tt
  local h11 = ttt - tt
  return {
    x = h00 * p0.x + h10 * tangent0.x + h01 * p1.x + h11 * tangent1.x,
    y = h00 * p0.y + h10 * tangent0.y + h01 * p1.y + h11 * tangent1.y,
    z = h00 * p0.z + h10 * tangent0.z + h01 * p1.z + h11 * tangent1.z,
  }
end

local function distanceSquared(a, b)
  local x, y, z = a.x - b.x, a.y - b.y, a.z - b.z
  return x * x + y * y + z * z
end

local function closestSplineParam(position, p0, p1, tangent0, tangent1)
  -- Coarse global scan followed by a bounded golden-section refinement. Edge
  -- object models can be laterally offset from the carrier, so minimise the
  -- 3-D distance to the Hermite spline instead of assuming a straight edge.
  local samples, bestT, bestDistance = 96, 0, math.huge
  for index = 0, samples do
    local t = index / samples
    local distance = distanceSquared(position, cubicPoint(p0, p1, tangent0, tangent1, t))
    if distance < bestDistance then bestT, bestDistance = t, distance end
  end
  local low = math.max(0, bestT - 1 / samples)
  local high = math.min(1, bestT + 1 / samples)
  local ratio = (math.sqrt(5) - 1) * 0.5
  local left = high - (high - low) * ratio
  local right = low + (high - low) * ratio
  local leftDistance = distanceSquared(position, cubicPoint(p0, p1, tangent0, tangent1, left))
  local rightDistance = distanceSquared(position, cubicPoint(p0, p1, tangent0, tangent1, right))
  for _ = 1, 28 do
    if leftDistance <= rightDistance then
      high, right, rightDistance = right, left, leftDistance
      left = high - (high - low) * ratio
      leftDistance = distanceSquared(position, cubicPoint(p0, p1, tangent0, tangent1, left))
    else
      low, left, leftDistance = left, right, rightDistance
      right = low + (high - low) * ratio
      rightDistance = distanceSquared(position, cubicPoint(p0, p1, tangent0, tangent1, right))
    end
  end
  local param = (low + high) * 0.5
  return param, distanceSquared(position, cubicPoint(p0, p1, tangent0, tangent1, param))
end

local function normaliseEdgeObjects(
  root, edgeEntries, edgeSlots, companyCid, options, nodeEntries)
  local additions = entries(findField(root, { "edgeObjectsToAdd" }))
  if #additions > M.MAX_EDGE_OBJECTS then return nil, nil, "proposal exceeds edge-object limit" end
  local edgeObjectRefs, retained, retainedSeen = {}, {}, {}
  for edgeIndex, edgeEntry in ipairs(edgeEntries) do
    local segment = edgeEntry.value
    local comp = safeField(segment, "comp") or segment
    for _, objectEntry in ipairs(entries(safeField(comp, "objects"))) do
      local pair = objectEntry.value
      local temporaryId = integer(indexedField(pair, 1)
        or safeField(pair, "entity") or safeField(pair, "entityId"))
      local category = integer(indexedField(pair, 2) or safeField(pair, "category")
        or safeField(pair, "type"))
      if category == nil or category < 0 or category > 32 then
        return nil, nil, "edge-object category is invalid"
      end
      if temporaryId == nil then return nil, nil, "edge object reference has no entity id" end
      if temporaryId < 0 then
        edgeObjectRefs[#edgeObjectRefs + 1] = {
          edgeSlot = "edge:" .. tostring(edgeIndex),
          temporaryId = temporaryId,
          category = category,
        }
      else
        local reference, referenceError = canonicalReference(
          "edge_object", temporaryId, {}, options)
        if not reference then return nil, nil, referenceError end
        if retainedSeen[reference.cid] then
          return nil, nil, "proposal retains the same edge object more than once"
        end
        retainedSeen[reference.cid] = true
        retained[#retained + 1] = {
          cid = reference.cid,
          edge = { slot = "edge:" .. tostring(edgeIndex) },
          category = category,
        }
      end
    end
  end
  if #edgeObjectRefs ~= #additions then
    return nil, nil, "edge-object additions do not match the temporary edge object references"
  end
  local newNodePositions = {}
  for _, nodeEntry in ipairs(nodeEntries or {}) do
    local id = entityId(nodeEntry.value)
    local comp = safeField(nodeEntry.value, "comp") or nodeEntry.value
    local position = vec3(safeField(comp, "position") or safeField(comp, "pos"), "node position")
    if id ~= nil and position then newNodePositions[id] = position end
  end
  local function nodePosition(localId)
    if newNodePositions[localId] then return newNodePositions[localId] end
    if type(options.entityPosition) == "function" then
      local ok, position = pcall(options.entityPosition, "node", localId)
      if ok and position ~= nil then return vec3(position, "existing node position") end
    end
    return nil
  end
  local seenTemporary, result = {}, {}
  for index, entry in ipairs(additions) do
    local value, reference = entry.value, edgeObjectRefs[index]
    if seenTemporary[reference.temporaryId] then return nil, nil, "duplicate temporary edge-object id" end
    seenTemporary[reference.temporaryId] = true
    local edgeId = integer(safeField(value, "edgeEntity") or safeField(value, "segmentEntity")
      or safeField(value, "edge"))
    local edgeReference, edgeError = canonicalReference("edge", edgeId, edgeSlots, options)
    if not edgeReference then return nil, nil, edgeError end
    if edgeReference.slot ~= reference.edgeSlot then
      return nil, nil, "edge-object vector order does not match its edge reference"
    end
    local param = finite(safeField(value, "param") or safeField(value, "position"))
    -- Build 35924's processed signal/waypoint output can retain an out-of-range
    -- SimpleStreetProposal sentinel even though modelInstance contains the
    -- committed world position. Treat that sentinel exactly like a missing
    -- public param and reconstruct its position on the referenced spline.
    if param == nil or param < 0 or param > 1 then
      local modelPosition = edgeObjectWorldPosition(value)
      local segment = edgeEntries[index] and edgeEntries[index].value or nil
      -- Vector order has already been proven above. Use the referenced edge,
      -- not merely the same list index, when one proposal carries multiple
      -- objects on different segments.
      for edgeIndex, candidate in ipairs(edgeEntries) do
        if "edge:" .. tostring(edgeIndex) == reference.edgeSlot then segment = candidate.value; break end
      end
      local comp = safeField(segment, "comp") or segment
      local p0 = nodePosition(integer(safeField(comp, "node0")))
      local p1 = nodePosition(integer(safeField(comp, "node1")))
      local tangent0 = vec3(safeField(comp, "tangent0"), "edge tangent0")
      local tangent1 = vec3(safeField(comp, "tangent1"), "edge tangent1")
      if modelPosition and p0 and p1 and tangent0 and tangent1 then
        local distance
        param, distance = closestSplineParam(modelPosition, p0, p1, tangent0, tangent1)
        if distance > 10000 then
          return nil, nil, "processed edge-object model is too far from its carrier edge"
        end
      end
    end
    if param == nil or param < 0 or param > 1 then return nil, nil, "edge-object param is outside [0,1]" end
    local model, modelError = edgeObjectModel(value, options)
    if not model then return nil, nil, modelError end
    local left, oneWay = safeField(value, "left"), safeField(value, "oneWay")
    if type(oneWay) ~= "boolean" then
      -- The processed GUI proposal omits this simple-input flag. Stock and
      -- data-driven mod resources conventionally encode the variant in the
      -- stable model name; callers may override metadata inference when a mod
      -- uses a different convention.
      if type(options.edgeObjectOneWay) == "function" then
        local ok, inferred = pcall(options.edgeObjectOneWay, model)
        if ok and type(inferred) == "boolean" then oneWay = inferred end
      end
      if type(oneWay) ~= "boolean" then
        oneWay = model:lower():match("_one_way%.mdl$") ~= nil
      end
    end
    if type(left) ~= "boolean" then
      return nil, nil, "edge-object side flag is unavailable"
    end
    local objectName = safeField(value, "name")
    if objectName == nil then objectName = "" end
    if type(objectName) ~= "string" or #objectName > 240 or objectName:find("[%z\1-\31]") then
      return nil, nil, "edge-object name is invalid"
    end
    local player = integer(safeField(value, "playerEntity") or safeField(value, "player"))
    result[#result + 1] = {
      slot = "edge_object:" .. tostring(index),
      edge = edgeReference,
      param = param,
      oneWay = oneWay,
      left = left,
      model = model,
      name = objectName,
      category = reference.category,
      logicalOwnerCid = companyCid,
      private = player ~= nil and player >= 0,
    }
  end
  local removals, removalError = removalList(
    root, { "edgeObjectsToRemove" }, "edge_object", options)
  if not removals then return nil, nil, removalError end
  table.sort(retained, function(a, b)
    if a.edge.slot ~= b.edge.slot then return a.edge.slot < b.edge.slot end
    if a.category ~= b.category then return a.category < b.category end
    return a.cid < b.cid
  end)
  return result, removals, nil, retained
end

local function contentView(transaction)
  local result = {
    schemaVersion = transaction.schemaVersion,
    companyCid = transaction.companyCid,
    cost = transaction.cost,
    nodes = util.deepCopy(transaction.nodes or {}),
    edges = util.deepCopy(transaction.edges or {}),
    edgeObjects = util.deepCopy(transaction.edgeObjects or { add = {}, retain = {}, remove = {} }),
    remove = util.deepCopy(transaction.remove or {}),
  }
  if transaction.schemaVersion == M.CONSTRUCTION_SCHEMA_VERSION then
    result.constructions = util.deepCopy(transaction.constructions or {})
  end
  return result
end

function M.digest(transaction)
  return hash.value(contentView(transaction))
end

function M.normalise(root, companyCid, options)
  options = options or {}
  if type(companyCid) ~= "string" or not companyCid:match("^company:%d+$") then
    return nil, "canonical companyCid is required"
  end
  if type(root) ~= "table" and type(root) ~= "userdata" then return nil, "proposal root is unavailable" end
  local constructionContainer = constructionAdditions(root)
  local constructionEntries = entries(constructionContainer)
  local hasConstruction = #constructionEntries > 0
  local constructionRemovalEntries = entries(constructionRemovals(root))
  local hasConstructionRemoval = #constructionRemovalEntries > 0
  local hasConstructionChange = hasConstruction or hasConstructionRemoval
  local unsupportedError = unsupported(root, hasConstruction, hasConstructionRemoval)
  if unsupportedError then return nil, unsupportedError end
  local quotedCost = integer(safeField(root, "__observedCost"))
  if quotedCost == nil then quotedCost = uniqueScalarField(root, "costs", "integer") end
  if quotedCost == nil then return nil, "proposal has no authoritative quoted cost" end
  if math.abs(quotedCost) > 1000000000000 then return nil, "proposal quoted cost is outside the supported range" end

  local nodeContainer = findField(root, { "nodesToAdd", "addedNodes" })
  local edgeContainer = findField(root, { "edgesToAdd", "addedSegments" })
  local nodeEntries, edgeEntries = entries(nodeContainer), entries(edgeContainer)
  local nodeLimit = hasConstructionChange and M.MAX_CONSTRUCTION_NODES or M.MAX_NODES
  local edgeLimit = hasConstructionChange and M.MAX_CONSTRUCTION_EDGES or M.MAX_EDGES
  if #nodeEntries > nodeLimit then return nil, "proposal exceeds node limit" end
  if #edgeEntries > edgeLimit then return nil, "proposal exceeds edge limit" end
  local nodeSlots, edgeSlots = {}, {}
  for index, entry in ipairs(nodeEntries) do
    local id = entityId(entry.value)
    if not id or id >= 0 then return nil, "added node " .. index .. " lacks a temporary negative entity id" end
    if nodeSlots[id] then return nil, "duplicate temporary node id " .. tostring(id) end
    nodeSlots[id] = "node:" .. tostring(index)
  end
  for index, entry in ipairs(edgeEntries) do
    local id = entityId(entry.value)
    if not id or id >= 0 then return nil, "added edge " .. index .. " lacks a temporary negative entity id" end
    if edgeSlots[id] then return nil, "duplicate temporary edge id " .. tostring(id) end
    edgeSlots[id] = "edge:" .. tostring(index)
  end

  local nodes = {}
  for index, entry in ipairs(nodeEntries) do
    local comp = safeField(entry.value, "comp") or entry.value
    local position, positionError = vec3(safeField(comp, "position") or safeField(comp, "pos"), "node position")
    if not position then return nil, positionError end
    nodes[#nodes + 1] = { slot = "node:" .. tostring(index), position = position }
  end

  local edges = {}
  for index, entry in ipairs(edgeEntries) do
    local segment = entry.value
    local comp = safeField(segment, "comp")
    if not comp then return nil, "edge " .. index .. " has no base-edge component" end
    local node0Id = integer(safeField(comp, "node0"))
    local node1Id = integer(safeField(comp, "node1"))
    local node0, node0Error = canonicalReference("node", node0Id, nodeSlots, options)
    if not node0 then return nil, node0Error end
    local node1, node1Error = canonicalReference("node", node1Id, nodeSlots, options)
    if not node1 then return nil, node1Error end
    local tangent0, tangent0Error = vec3(safeField(comp, "tangent0"), "edge tangent0")
    if not tangent0 then return nil, tangent0Error end
    local tangent1, tangent1Error = vec3(safeField(comp, "tangent1"), "edge tangent1")
    if not tangent1 then return nil, tangent1Error end
    local carrierValue = integer(safeField(segment, "type"))
    local carrier = carrierValue == 0 and "street" or carrierValue == 1 and "track" or nil
    if not carrier then return nil, "edge " .. index .. " uses unsupported carrier " .. tostring(carrierValue) end
    local carrierComponent = safeField(segment, carrier == "street" and "streetEdge" or "trackEdge")
    local resourceValue, resourceError = resource(carrier, carrierComponent, options, root)
    if not resourceValue then return nil, resourceError end
    local edge = {
      slot = "edge:" .. tostring(index),
      carrier = carrier,
      node0 = node0,
      node1 = node1,
      tangent0 = tangent0,
      tangent1 = tangent1,
      type = integer(safeField(comp, "type")) or 0,
      typeIndex = integer(safeField(comp, "typeIndex")) or (carrier == "track" and -1 or 0),
      resource = resourceValue,
      logicalOwnerCid = companyCid,
      -- SegmentAndEntity.playerOwned exists in Build 35924 even though it is
      -- absent from the generated public type table. Preserve only the
      -- portable access policy, never the process-local native player ID.
      private = (function()
        local owned = safeField(segment, "playerOwned")
        local player = integer(safeField(owned, "player") or safeField(owned, "playerEntity"))
        return player ~= nil and player >= 0
      end)(),
    }
    if carrier == "track" then
      local catenary = safeField(carrierComponent, "catenary")
      local catenaryError
      if type(catenary) ~= "boolean" then
        catenary, catenaryError = uniqueScalarField(root, "catenary", "boolean")
      end
      if type(catenary) ~= "boolean" then
        return nil, catenaryError or "track edge has no catenary selection"
      end
      edge.catenary = catenary
    end
    edges[#edges + 1] = edge
  end

  local edgeObjects, removeEdgeObjects, edgeObjectError, retainEdgeObjects = normaliseEdgeObjects(
    root, edgeEntries, edgeSlots, companyCid, options, nodeEntries)
  if not edgeObjects then return nil, edgeObjectError end

  local removeEdges, removeEdgeError = removalList(root, { "edgesToRemove", "removedSegments" }, "edge", options)
  if not removeEdges then return nil, removeEdgeError end
  local removeNodes, removeNodeError = removalList(root, { "nodesToRemove", "removedNodes" }, "node", options)
  if not removeNodes then return nil, removeNodeError end
  local constructions
  if hasConstructionChange then
    local construction, constructionError = normaliseConstructionChange(
      constructionEntries, constructionRemovalEntries, options)
    if not construction then return nil, constructionError end
    if construction.adapter == "stock-rail-station" then
      if #removeEdges > 0 or #removeNodes > 0 then
        return nil, "stock station placement cannot replace existing topology"
      end
      local graphValid, graphError = validateStationGraph(nodes, edges, construction.params)
      if not graphValid then return nil, graphError end
    end
    constructions = { construction }
  end
  local transaction = {
    schemaVersion = hasConstructionChange and M.CONSTRUCTION_SCHEMA_VERSION or M.SCHEMA_VERSION,
    companyCid = companyCid,
    cost = quotedCost,
    nodes = nodes,
    edges = edges,
    edgeObjects = { add = edgeObjects, retain = retainEdgeObjects, remove = removeEdgeObjects },
    remove = { edges = removeEdges, nodes = removeNodes },
  }
  if constructions then transaction.constructions = constructions end
  transaction.digest = M.digest(transaction)
  transaction.transactionId = "proposal:" .. transaction.digest
  local valid, validationError = M.validate(transaction)
  if not valid then return nil, validationError end
  return transaction
end

local function validateReference(reference, nodeSlots)
  if type(reference) ~= "table" then return false, "edge node reference is not an object" end
  local hasSlot, hasCid = type(reference.slot) == "string", type(reference.cid) == "string"
  if hasSlot == hasCid then return false, "edge node reference must contain exactly one of slot or cid" end
  if hasSlot and not nodeSlots[reference.slot] then return false, "edge references unknown node slot" end
  if hasCid and not reference.cid:match("^node:") then return false, "edge contains a non-node canonical reference" end
  return true
end

local function validateEdgeReference(reference, edgeSlots)
  if type(reference) ~= "table" then return false, "edge-object edge reference is not an object" end
  local hasSlot, hasCid = type(reference.slot) == "string", type(reference.cid) == "string"
  if hasSlot == hasCid then return false, "edge-object edge reference must contain exactly one of slot or cid" end
  if hasSlot and not edgeSlots[reference.slot] then return false, "edge-object references unknown edge slot" end
  if hasCid and not reference.cid:match("^edge:") then return false, "edge-object contains a non-edge canonical reference" end
  return true
end

local function exactFields(value, names)
  if type(value) ~= "table" then return false end
  local expected = {}
  for _, name in ipairs(names) do expected[name] = true end
  for key in pairs(value) do if not expected[key] then return false end end
  for name in pairs(expected) do if value[name] == nil then return false end end
  return true
end

local function exactList(value, length)
  if type(value) ~= "table" or #value ~= length then return false end
  local count = 0
  for key in pairs(value) do
    if type(key) ~= "number" or integer(key) == nil or key < 1 or key > length then return false end
    count = count + 1
  end
  return count == length
end

local function boundedListLength(value, maximum)
  if type(value) ~= "table" then return nil end
  local count, highest = 0, 0
  for key in pairs(value) do
    local index = integer(key)
    if not index or index < 1 or index > maximum then return nil end
    count = count + 1
    if index > highest then highest = index end
  end
  if count < 1 or highest ~= count then return nil end
  for index = 1, count do if value[index] == nil then return nil end end
  return count
end

function M.validate(transaction)
  if type(transaction) ~= "table" then return false, "proposal transaction must be an object" end
  if transaction.schemaVersion ~= M.SCHEMA_VERSION
    and transaction.schemaVersion ~= M.CONSTRUCTION_SCHEMA_VERSION then
    return false, "unsupported proposal schemaVersion"
  end
  if type(transaction.companyCid) ~= "string" or not transaction.companyCid:match("^company:%d+$") then
    return false, "invalid proposal companyCid"
  end
  if integer(transaction.cost) == nil or math.abs(transaction.cost) > 1000000000000 then
    return false, "invalid proposal quoted cost"
  end
  local nodeLimit = transaction.schemaVersion == M.CONSTRUCTION_SCHEMA_VERSION
    and M.MAX_CONSTRUCTION_NODES or M.MAX_NODES
  local edgeLimit = transaction.schemaVersion == M.CONSTRUCTION_SCHEMA_VERSION
    and M.MAX_CONSTRUCTION_EDGES or M.MAX_EDGES
  if type(transaction.nodes) ~= "table" or #transaction.nodes > nodeLimit then return false, "invalid proposal nodes" end
  if type(transaction.edges) ~= "table" or #transaction.edges > edgeLimit then
    return false, "invalid proposal edges"
  end
  local nodeSlots, edgeSlots = {}, {}
  for index, node in ipairs(transaction.nodes) do
    if type(node) ~= "table" or node.slot ~= "node:" .. tostring(index) or nodeSlots[node.slot] then
      return false, "proposal node slots must be unique and sequential"
    end
    local position, err = vec3(node.position, "node position")
    if not position then return false, err end
    nodeSlots[node.slot] = true
  end
  for index, edge in ipairs(transaction.edges) do
    if type(edge) ~= "table" or edge.slot ~= "edge:" .. tostring(index) or edgeSlots[edge.slot] then
      return false, "proposal edge slots must be unique and sequential"
    end
    edgeSlots[edge.slot] = true
    if edge.carrier ~= "street" and edge.carrier ~= "track" then return false, "invalid edge carrier" end
    local ok, err = validateReference(edge.node0, nodeSlots)
    if not ok then return false, err end
    ok, err = validateReference(edge.node1, nodeSlots)
    if not ok then return false, err end
    if not vec3(edge.tangent0, "edge tangent0") or not vec3(edge.tangent1, "edge tangent1") then
      return false, "invalid edge tangent"
    end
    if integer(edge.type) == nil or integer(edge.typeIndex) == nil then return false, "invalid edge type fields" end
    if type(edge.resource) ~= "table" or integer(edge.resource.index) == nil then return false, "invalid edge resource" end
    if edge.resource.name ~= nil and (type(edge.resource.name) ~= "string" or #edge.resource.name > 240) then
      return false, "invalid edge resource name"
    end
    if edge.logicalOwnerCid ~= transaction.companyCid then return false, "edge logical owner differs from transaction company" end
    if type(edge.private) ~= "boolean" then return false, "edge private flag must be boolean" end
    if edge.carrier == "track" and type(edge.catenary) ~= "boolean" then return false, "track catenary must be boolean" end
  end
  local edgeObjects = transaction.edgeObjects
  if type(edgeObjects) ~= "table" or not exactFields(edgeObjects, { "add", "retain", "remove" })
    or type(edgeObjects.add) ~= "table" or type(edgeObjects.retain) ~= "table"
    or type(edgeObjects.remove) ~= "table" then
    return false, "invalid edge-object lists"
  end
  if #edgeObjects.add > M.MAX_EDGE_OBJECTS or #edgeObjects.retain > M.MAX_EDGE_OBJECTS
    or #edgeObjects.remove > M.MAX_REMOVALS then
    return false, "proposal edge-object limit exceeded"
  end
  local retainedCids, previousRetainedKey = {}, nil
  for _, object in ipairs(edgeObjects.retain) do
    if not exactFields(object, { "cid", "edge", "category" })
      or type(object.cid) ~= "string" or not object.cid:match("^edge_object:") then
      return false, "invalid retained edge-object entry"
    end
    local referenceOk, referenceError = validateEdgeReference(object.edge, edgeSlots)
    if not referenceOk then return false, referenceError end
    if object.edge.slot == nil then return false, "retained edge object must reference a new edge slot" end
    if integer(object.category) == nil or object.category < 0 or object.category > 32 then
      return false, "invalid retained edge-object category"
    end
    if retainedCids[object.cid] then return false, "retained edge objects must be unique" end
    retainedCids[object.cid] = true
    local orderKey = object.edge.slot .. ":" .. string.format("%03d", object.category) .. ":" .. object.cid
    if previousRetainedKey and orderKey <= previousRetainedKey then
      return false, "retained edge objects must be canonically sorted"
    end
    previousRetainedKey = orderKey
  end
  for index, object in ipairs(edgeObjects.add) do
    if not exactFields(object, {
      "slot", "edge", "param", "oneWay", "left", "model", "name", "category",
      "logicalOwnerCid", "private",
    }) or object.slot ~= "edge_object:" .. tostring(index) then
      return false, "edge-object slots must be unique and sequential"
    end
    local referenceOk, referenceError = validateEdgeReference(object.edge, edgeSlots)
    if not referenceOk then return false, referenceError end
    if object.edge.slot == nil then return false, "new edge object must reference a new edge slot" end
    local param = finite(object.param)
    if not param or param < 0 or param > 1 then return false, "invalid edge-object param" end
    if type(object.oneWay) ~= "boolean" or type(object.left) ~= "boolean"
      or type(object.private) ~= "boolean" then return false, "invalid edge-object flags" end
    local model, modelError = portableResourceName(object.model, ".mdl", "edge-object model")
    if not model then return false, modelError end
    if type(object.name) ~= "string" or #object.name > 240 or object.name:find("[%z\1-\31]") then
      return false, "invalid edge-object name"
    end
    if integer(object.category) == nil or object.category < 0 or object.category > 32 then
      return false, "invalid edge-object category"
    end
    if object.logicalOwnerCid ~= transaction.companyCid then
      return false, "edge-object logical owner differs from transaction company"
    end
  end
  local previousObjectCid
  for _, cid in ipairs(edgeObjects.remove) do
    if type(cid) ~= "string" or not cid:match("^edge_object:") then
      return false, "invalid canonical edge-object removal"
    end
    if previousObjectCid and cid <= previousObjectCid then
      return false, "edge-object removals must be sorted and unique"
    end
    previousObjectCid = cid
    if retainedCids[cid] then return false, "edge object cannot be retained and removed together" end
  end
  local remove = transaction.remove
  if type(remove) ~= "table" or type(remove.edges) ~= "table" or type(remove.nodes) ~= "table" then
    return false, "invalid removal lists"
  end
  if #remove.edges > M.MAX_REMOVALS or #remove.nodes > M.MAX_REMOVALS then return false, "proposal removal limit exceeded" end
  if not exactList(remove.edges, #remove.edges) or not exactList(remove.nodes, #remove.nodes) then
    return false, "proposal removal lists must be contiguous arrays"
  end
  local previousEdgeCid
  for _, cid in ipairs(remove.edges) do
    if type(cid) ~= "string" or not cid:match("^edge:") then return false, "invalid canonical edge removal" end
    if previousEdgeCid and cid <= previousEdgeCid then
      return false, "edge removals must be sorted and unique"
    end
    previousEdgeCid = cid
  end
  local previousNodeCid
  for _, cid in ipairs(remove.nodes) do
    if type(cid) ~= "string" or not cid:match("^node:") then return false, "invalid canonical node removal" end
    if previousNodeCid and cid <= previousNodeCid then
      return false, "node removals must be sorted and unique"
    end
    previousNodeCid = cid
  end
  if transaction.schemaVersion == M.SCHEMA_VERSION then
    if transaction.constructions ~= nil then return false, "schema 5 proposal cannot contain constructions" end
    if #transaction.edges == 0 and #remove.edges == 0 and #remove.nodes == 0
      and #edgeObjects.add == 0 and #edgeObjects.remove == 0 then
      return false, "schema 5 proposal contains no world change"
    end
  else
    if not exactList(transaction.constructions, 1) then
      return false, "schema 7 proposal requires one construction change"
    end
    local construction = transaction.constructions[1]
    if not exactFields(construction, {
      "slot", "mode", "adapter", "kind", "sourceCid", "fileName",
      "transform", "params", "modules", "collateral",
    }) or construction.slot ~= "construction:1" then
      return false, "invalid schema 7 construction record"
    end
    if construction.mode ~= "build" and construction.mode ~= "upgrade" and construction.mode ~= "remove" then
      return false, "invalid construction change mode"
    end
    if construction.adapter ~= "stock-rail-station"
      and construction.adapter ~= "portable-construction" then
      return false, "unknown construction adapter"
    end
    if construction.kind ~= "rail_station" and construction.kind ~= "station"
      and construction.kind ~= "depot" and construction.kind ~= "construction"
      and construction.kind ~= "asset" then
      return false, "invalid construction kind"
    end
    if construction.mode == "build" then
      if construction.sourceCid ~= "" then return false, "construction build cannot contain a source" end
    else
      local sourcePrefix = construction.kind == "asset" and "asset:" or "construction:"
      if type(construction.sourceCid) ~= "string"
        or construction.sourceCid:sub(1, #sourcePrefix) ~= sourcePrefix then
        return false, "construction upgrade/removal has no canonical source"
      end
    end
    local collateralCount = type(construction.collateral) == "table"
      and #construction.collateral or -1
    if collateralCount < 0 or collateralCount > M.MAX_CONSTRUCTION_COLLATERAL
      or not exactList(construction.collateral, collateralCount) then
      return false, "construction collateral list is invalid"
    end
    if construction.mode == "upgrade" and collateralCount > 0 then
      return false, "construction upgrade cannot contain collateral demolition"
    end
    local previousCollateralKey
    for _, collateral in ipairs(construction.collateral) do
      if not exactFields(collateral, { "kind", "cid" })
        or (collateral.kind ~= "construction" and collateral.kind ~= "asset") then
        return false, "construction collateral entry is invalid"
      end
      local prefix = collateral.kind .. ":"
      if type(collateral.cid) ~= "string"
        or collateral.cid:sub(1, #prefix) ~= prefix then
        return false, "construction collateral has no canonical source"
      end
      local key = collateral.kind .. ":" .. collateral.cid
      local sourceKind = construction.kind == "asset" and "asset" or "construction"
      if construction.mode ~= "build" and collateral.kind == sourceKind
        and collateral.cid == construction.sourceCid then
        return false, "construction source cannot also be collateral"
      end
      if previousCollateralKey and key <= previousCollateralKey then
        return false, "construction collateral must be sorted and unique"
      end
      previousCollateralKey = key
    end
    if construction.mode == "remove" then
      if construction.fileName ~= "" or not exactList(construction.transform, 0)
        or not exactFields(construction.params, {}) or not exactList(construction.modules, 0) then
        return false, "construction removal contains build payload"
      end
    else
      local fileName, fileError = portableResourceName(construction.fileName, ".con", "construction")
      if not fileName then return false, fileError end
      if not exactList(construction.transform, 16) then
        return false, "construction transform must contain exactly 16 values"
      end
      local transform, transformError = portableTransform(construction.transform, "construction")
      if not transform then return false, transformError end
      if type(construction.params) ~= "table" then return false, "construction params are invalid" end
      local rebuiltParams, paramsError = normalisePlainValue(
        construction.params, "construction params", 0, nil,
        { remaining = M.MAX_CONSTRUCTION_PARAM_VALUES }, false)
      if not rebuiltParams then return false, paramsError end
      if hash.value(rebuiltParams) ~= hash.value(construction.params) then
        return false, "construction params are not in canonical form"
      end
      local moduleCount = #construction.modules
      if moduleCount > STATION_MAX_MODULES or not exactList(construction.modules, moduleCount) then
        return false, "construction module list is invalid"
      end
      local lastModuleSlot
      for _, module in ipairs(construction.modules) do
        if not exactFields(module, { "slot", "name", "variant", "metadata" })
          or integer(module.slot) == nil or module.slot < 1
          or integer(module.variant) == nil or module.variant < 0 or module.variant > 65535
          or type(module.metadata) ~= "table" then
          return false, "construction module entry is invalid"
        end
        local moduleName, moduleNameError = portableResourceName(
          module.name, ".module", "construction module")
        if not moduleName then return false, moduleNameError end
        if lastModuleSlot and module.slot <= lastModuleSlot then
          return false, "construction modules must be sorted by unique slot"
        end
        lastModuleSlot = module.slot
        local rebuiltMetadata, metadataError = normalisePlainValue(
          module.metadata, "construction module metadata", 0, nil,
          { remaining = M.MAX_CONSTRUCTION_PARAM_VALUES }, false)
        if not rebuiltMetadata then return false, metadataError end
        if hash.value(rebuiltMetadata) ~= hash.value(module.metadata) then
          return false, "construction module metadata is not canonical"
        end
      end
    end
    if construction.adapter == "stock-rail-station" then
      if construction.mode ~= "build" or construction.kind ~= "rail_station"
        or construction.fileName ~= STATION_FILE then
        return false, "stock station adapter only supports station placement"
      end
      local params = construction.params
      if not exactFields(params, { "year", "seed", "trackType", "catenary", "length", "tracks", "paramX", "paramY" }) then
        return false, "stock station params have unknown or missing fields"
      end
      local synthetic = {
        fileName = construction.fileName,
        transf = construction.transform,
        params = util.deepCopy(params),
      }
      synthetic.params.modules = {}
      if #construction.modules < 1 then return false, "stock station module list is empty" end
      for _, module in ipairs(construction.modules) do
        if integer(module.variant) ~= 0 or next(module.metadata) ~= nil then
          return false, "stock station module entry is invalid"
        end
        synthetic.params.modules[module.slot] = { name = module.name, variant = module.variant }
      end
      local rebuilt, constructionError = normaliseStationConstruction(synthetic)
      if not rebuilt then return false, constructionError end
      local graphValid, graphError = validateStationGraph(transaction.nodes, transaction.edges, rebuilt.params)
      if not graphValid then return false, graphError end
    end
  end
  local expectedDigest = M.digest(transaction)
  if transaction.digest ~= expectedDigest then return false, "proposal digest mismatch" end
  if transaction.transactionId ~= "proposal:" .. expectedDigest then return false, "proposal transactionId mismatch" end
  return true
end

-- True only for the native atomic shape used when a street/track edit also
-- bulldozes obstructing buildings. Standalone station/depot bulldozes remain
-- on the engine-thread helper path because their generated topology retires
-- asynchronously. A removal-only public road edit can nevertheless carry
-- explicit edge/node removals plus autonomous buildings; that is still one
-- native GUI BuildProposal and must never be split into helper calls.
function M.isTopologyConstructionRemoval(transaction)
  if type(transaction) ~= "table"
    or transaction.schemaVersion ~= M.CONSTRUCTION_SCHEMA_VERSION then return false end
  local construction = type(transaction.constructions) == "table"
    and transaction.constructions[1] or nil
  if type(construction) ~= "table" or construction.mode ~= "remove" then return false end
  local edgeObjects = type(transaction.edgeObjects) == "table" and transaction.edgeObjects or {}
  local addsTopology = #(transaction.nodes or {}) > 0 or #(transaction.edges or {}) > 0
    or #(edgeObjects.add or {}) > 0 or #(edgeObjects.retain or {}) > 0
  if addsTopology then return true end
  local remove = type(transaction.remove) == "table" and transaction.remove or {}
  local removesTopology = #(remove.edges or {}) > 0 or #(remove.nodes or {}) > 0
    or #(edgeObjects.remove or {}) > 0
  if not removesTopology then return false end
  -- Stock station/depot removals include their generated graph in the captured
  -- snapshot, but the supported engine helper owns that graph's delayed
  -- retirement. Generic constructions are autonomous obstacles (for example
  -- town houses attached to a road) and their topology removals belong to the
  -- original atomic GUI command.
  return construction.kind ~= "rail_station" and construction.kind ~= "station"
    and construction.kind ~= "depot"
end

-- Removal-only street proposals are a normal Build 35924 bulldozer shape:
-- there need not be a replacement edge or node. Keep this predicate narrow so
-- replacement proposals may still reuse an input entity id for a new output.
function M.isRemovalOnly(transaction)
  if type(transaction) ~= "table" or transaction.schemaVersion ~= M.SCHEMA_VERSION then
    return false
  end
  local objects = type(transaction.edgeObjects) == "table" and transaction.edgeObjects or {}
  local remove = type(transaction.remove) == "table" and transaction.remove or {}
  local changes = #(remove.edges or {}) + #(remove.nodes or {}) + #(objects.remove or {})
  return changes > 0 and #(transaction.nodes or {}) == 0 and #(transaction.edges or {}) == 0
    and #(objects.add or {}) == 0 and #(objects.retain or {}) == 0
end

-- Network proposals must identify data-driven resources by repository name.
-- Numeric repository indices are retained as a capture diagnostic and a
-- standalone compatibility fallback, but are never sufficient authority for
-- replay on another installation (mod load order can legally change them).
function M.validatePortable(transaction)
  local valid, validationError = M.validate(transaction)
  if not valid then return false, validationError end
  for index, edge in ipairs(transaction.edges) do
    local name = edge.resource and edge.resource.name
    if type(name) ~= "string" or name == "" then
      return false, "proposal edge:" .. tostring(index)
        .. " has only a machine-local resource index"
    end
  end
  for index, object in ipairs(transaction.edgeObjects.add) do
    if type(object.model) ~= "string" or object.model == "" then
      return false, "proposal edge_object:" .. tostring(index) .. " has no stable model filename"
    end
  end
  if transaction.schemaVersion == M.CONSTRUCTION_SCHEMA_VERSION then
    local construction = transaction.constructions[1]
    -- Build 35924's buildConstruction helper receives only
    -- filename/params/transform, so it cannot reproduce a captured existing
    -- endpoint for any depot. Connected street depots remain portable because
    -- replay routes them through the typed exact-graph path; connected rail
    -- depots stay rejected because typed rail-depot outputs crash the stock
    -- context helper when selected. An isolated depot followed by a separate
    -- road/track build remains portable through the selectable helper path.
    if construction.mode == "build" and construction.kind == "depot" then
      for _, edge in ipairs(transaction.edges) do
        local node0, node1 = edge.node0 or {}, edge.node1 or {}
        if edge.carrier == "track"
          and (type(node0.cid) == "string" or type(node1.cid) == "string") then
          return false, "network depot snapped to existing track; place the depot clear of track, wait for synchronization, then connect it with a separate track build"
        end
      end
    end
    if construction.mode ~= "remove" then
      local fileName, fileError = portableResourceName(construction.fileName, ".con", "construction")
      if not fileName then return false, fileError end
      for index, module in ipairs(construction.modules) do
        local moduleName, moduleError = portableResourceName(
          module.name, ".module", "construction module " .. tostring(index))
        if not moduleName then return false, moduleError end
      end
    end
  end
  return true
end

local function findRepositoryResource(repository, name)
  -- Engine repository functions may be callable bound objects rather than
  -- plain Lua functions. Do not reject a valid method based on type().
  if not (repository and repository.find ~= nil) then
    return nil, "resource repository lookup is unavailable"
  end
  local ok, value = pcall(repository.find, name)
  value = ok and integer(value) or nil
  if value == nil or value < 0 then return nil, "resource is unavailable locally: " .. tostring(name) end
  return value
end

-- Pure local readiness check for the prepare/commit barrier. It performs
-- repository lookup but does not create entities, issue commands, or mutate a
-- canonical registry.
function M.preflightResources(transaction, gameApi)
  local portable, portableError = M.validatePortable(transaction)
  if not portable then return nil, portableError end
  gameApi = gameApi or api
  if not (gameApi and gameApi.res) then return nil, "resource API is unavailable" end
  local resolved = { edges = {}, edgeObjects = {}, construction = nil, modules = {} }
  for index, edge in ipairs(transaction.edges) do
    local repository = edge.carrier == "street"
      and gameApi.res.streetTypeRep or gameApi.res.trackTypeRep
    local resourceIndex, resourceError = findRepositoryResource(repository, edge.resource.name)
    if resourceIndex == nil then return nil, resourceError end
    resolved.edges[index] = resourceIndex
  end
  for index, object in ipairs(transaction.edgeObjects.add) do
    local modelIndex, modelError = findRepositoryResource(gameApi.res.modelRep, object.model)
    if modelIndex == nil then return nil, modelError end
    resolved.edgeObjects[index] = modelIndex
  end
  if transaction.schemaVersion == M.CONSTRUCTION_SCHEMA_VERSION then
    local construction = transaction.constructions[1]
    if construction.mode ~= "remove" then
      if not (gameApi.res.constructionRep and gameApi.res.constructionRep.find ~= nil) then
        return nil, "construction repository lookup is unavailable"
      end
      local constructionIndex, constructionError = findRepositoryResource(
        gameApi.res.constructionRep, construction.fileName)
      if constructionIndex == nil then return nil, constructionError end
      resolved.construction = constructionIndex
    end
    if construction.mode ~= "remove" and #construction.modules > 0 then
      if not (gameApi.res.moduleRep and gameApi.res.moduleRep.find ~= nil) then
        return nil, "construction module repository lookup is unavailable"
      end
      for index, module in ipairs(construction.modules) do
        local moduleIndex, moduleError = findRepositoryResource(gameApi.res.moduleRep, module.name)
        if moduleIndex == nil then return nil, moduleError end
        resolved.modules[index] = moduleIndex
      end
    end
  end
  return resolved
end

local function resolveLocalReference(reference, slotIds, options)
  if reference.slot then return slotIds[reference.slot] end
  if type(options.resolveLocal) == "function" then
    local ok, value, resolveError = pcall(options.resolveLocal, reference.cid)
    if not ok then return nil, tostring(value) end
    if value == nil then return nil, tostring(resolveError or ("canonical identity is not mapped: " .. reference.cid)) end
    return integer(value), resolveError
  end
  if options.registry then return canonical.resolveLocal(options.registry, reference.cid) end
  return nil, "no canonical local resolver"
end

local function resourceId(edge, gameApi)
  local repository = edge.carrier == "street" and gameApi.res.streetTypeRep or gameApi.res.trackTypeRep
  if type(edge.resource.name) == "string" and edge.resource.name ~= "" then
    local value, resourceError = findRepositoryResource(repository, edge.resource.name)
    if value == nil then return nil, resourceError end
    return value
  end
  return integer(edge.resource.index)
end

local function edgeObjectConstructor(gameApi)
  local candidates = {}
  local function add(label, factory, modelKind)
    if factory and factory.new ~= nil then
      candidates[#candidates + 1] = { label = label, factory = factory, modelKind = modelKind }
    end
  end
  pcall(function()
    add("SimpleStreetProposal.EdgeObject", gameApi.type.SimpleStreetProposal.EdgeObject, "name")
  end)
  pcall(function()
    add("StreetProposal.EdgeObject", gameApi.type.StreetProposal.EdgeObject, "name")
  end)
  pcall(function() add("EdgeObject", gameApi.type.EdgeObject, "index") end)
  for _, candidate in ipairs(candidates) do
    local ok, value = pcall(candidate.factory.new)
    if ok and value ~= nil then return value, candidate end
  end
  return nil, nil
end

function M.materialise(transaction, options)
  options = options or {}
  local valid, validationError = M.validate(transaction)
  if not valid then return nil, validationError end
  local gameApi = options.api or api
  if not (gameApi and gameApi.type and gameApi.type.SimpleProposal and gameApi.type.SegmentAndEntity
    and gameApi.type.NodeAndEntity and gameApi.type.Vec3f and gameApi.type.BaseEdgeStreet
    and gameApi.type.BaseEdgeTrack and gameApi.res) then
    return nil, "BuildProposal materialisation API is unavailable"
  end
  local construction = transaction.schemaVersion == M.CONSTRUCTION_SCHEMA_VERSION
    and type(transaction.constructions) == "table" and transaction.constructions[1] or nil
  local nativeGeneratedTopology = type(construction) == "table" and construction.mode == "build"
  if #transaction.edgeObjects.add > 0 then
    local probe = edgeObjectConstructor(gameApi)
    if not probe then return nil, "EdgeObject materialisation API is unavailable" end
  end

  local proposal = gameApi.type.SimpleProposal.new()
  local exactTopology = { nodes = {}, edges = {}, objects = {} }
  local slotIds, nextId = {}, -1
  for _, edge in ipairs(transaction.edges) do slotIds[edge.slot], nextId = nextId, nextId - 1 end
  for _, node in ipairs(transaction.nodes) do slotIds[node.slot], nextId = nextId, nextId - 1 end
  -- SimpleStreetProposal edge-object references use a vector-local negative
  -- index space.  The first object is -1 even when the first new edge is also
  -- -1 (this is the shape in Urban Games' supported build_street example).
  -- Treating objects as part of the edge/node entity sequence makes the native
  -- builder resolve an untyped entity and assert in GetEdgeObjectType.
  local nextObjectId = -1
  for _, object in ipairs(transaction.edgeObjects.add) do
    slotIds[object.slot], nextObjectId = nextObjectId, nextObjectId - 1
  end

  for index, node in ipairs(transaction.nodes) do
    local value = gameApi.type.NodeAndEntity.new()
    value.entity = slotIds[node.slot]
    value.comp.position = gameApi.type.Vec3f.new(node.position.x, node.position.y, node.position.z)
    exactTopology.nodes[index] = value
    if not nativeGeneratedTopology then proposal.streetProposal.nodesToAdd[index] = value end
  end
  for index, edge in ipairs(transaction.edges) do
    local node0, node0Error = resolveLocalReference(edge.node0, slotIds, options)
    if node0 == nil then return nil, node0Error end
    local node1, node1Error = resolveLocalReference(edge.node1, slotIds, options)
    if node1 == nil then return nil, node1Error end
    local value = gameApi.type.SegmentAndEntity.new()
    value.entity = slotIds[edge.slot]
    value.comp.node0 = node0
    value.comp.node1 = node1
    value.comp.tangent0 = gameApi.type.Vec3f.new(edge.tangent0.x, edge.tangent0.y, edge.tangent0.z)
    value.comp.tangent1 = gameApi.type.Vec3f.new(edge.tangent1.x, edge.tangent1.y, edge.tangent1.z)
    value.comp.type = edge.type
    value.comp.typeIndex = edge.typeIndex
    local objectReferences = {}
    for _, retained in ipairs(transaction.edgeObjects.retain) do
      if retained.edge.slot == edge.slot then
        local retainedId, retainedError = resolveLocalReference(
          { cid = retained.cid }, slotIds, options)
        if retainedId == nil then return nil, retainedError end
        objectReferences[#objectReferences + 1] = { retainedId, retained.category }
      end
    end
    for _, object in ipairs(transaction.edgeObjects.add) do
      if object.edge.slot == edge.slot then
        objectReferences[#objectReferences + 1] = { slotIds[object.slot], object.category }
      end
    end
    if #objectReferences > 0 then
      -- Build 35924 exposes BaseEdge.objects as a generated C++ vector proxy.
      -- Mutating proxy[index] with a plain Lua pair appears to work but does not
      -- run the binding's pair-vector conversion; the native builder later sees
      -- an untyped temporary entity and asserts in GetEdgeObjectType.  The
      -- whole-vector setter is the live-proven supported shape.
      local assigned, assignError = pcall(function()
        value.comp.objects = objectReferences
      end)
      if not assigned then
        return nil, "edge object reference vector assignment failed: " .. tostring(assignError)
      end
      local materialisedObjects = safeField(value.comp, "objects")
      if materialisedObjects == nil then return nil, "edge object reference vector is unavailable" end
      local lengthOk, length = pcall(function() return #materialisedObjects end)
      if not lengthOk or tonumber(length) ~= #objectReferences then
        return nil, "edge object reference vector did not round-trip"
      end
      for objectIndex, expected in ipairs(objectReferences) do
        local pairOk, objectId, category = pcall(function()
          local pair = materialisedObjects[objectIndex]
          return pair[1], pair[2]
        end)
        if not pairOk or integer(objectId) ~= expected[1] or integer(category) ~= expected[2] then
          return nil, "edge object reference pair did not round-trip"
        end
      end
    elseif safeField(value.comp, "objects") == nil and type(value.comp) == "table" then
      value.comp.objects = {}
    end
    if edge.private then
      local nativePlayerId = integer(options.nativePlayerId)
      if not nativePlayerId or nativePlayerId < 0 then return nil, "private edge requires a local native player" end
      if not (gameApi.type.PlayerOwned and gameApi.type.PlayerOwned.new) then
        return nil, "PlayerOwned materialisation API is unavailable"
      end
      value.playerOwned = gameApi.type.PlayerOwned.new()
      value.playerOwned.player = nativePlayerId
    end
    local selectedResource, resourceError = resourceId(edge, gameApi)
    if selectedResource == nil or selectedResource < 0 then
      return nil, resourceError or "edge resource is unavailable locally"
    end
    if edge.carrier == "street" then
      value.type = 0
      value.streetEdge = gameApi.type.BaseEdgeStreet.new()
      value.streetEdge.streetType = selectedResource
    else
      value.type = 1
      value.trackEdge = gameApi.type.BaseEdgeTrack.new()
      value.trackEdge.trackType = selectedResource
      value.trackEdge.catenary = edge.catenary
    end
    exactTopology.edges[index] = value
    if not nativeGeneratedTopology then proposal.streetProposal.edgesToAdd[index] = value end
  end
  for index, object in ipairs(transaction.edgeObjects.add) do
    local edgeId, edgeError = resolveLocalReference(object.edge, slotIds, options)
    if edgeId == nil then return nil, edgeError end
    local value, constructor = edgeObjectConstructor(gameApi)
    if not value then return nil, "EdgeObject materialisation API is unavailable" end
    value.edgeEntity = edgeId
    value.param = object.param
    value.oneWay = object.oneWay
    value.left = object.left
    -- The wire identity is always the stable `.mdl` name. Build 35924 exposes
    -- the usable GUI constructor as SimpleStreetProposal.EdgeObject, whose
    -- `model` field takes that filename. The separately documented top-level
    -- EdgeObject (available in some test/engine bindings) takes the local index.
    local modelIndex, modelError = findRepositoryResource(gameApi.res.modelRep, object.model)
    if modelIndex == nil then return nil, modelError end
    value.model = constructor.modelKind == "name" and object.model or modelIndex
    value.playerEntity = object.private and integer(options.nativePlayerId) or -1
    value.name = object.name
    exactTopology.objects[index] = value
    if not nativeGeneratedTopology then proposal.streetProposal.edgeObjectsToAdd[index] = value end
  end
  for index, cid in ipairs(transaction.remove.edges) do
    local localId, err = resolveLocalReference({ cid = cid }, slotIds, options)
    if localId == nil then return nil, err end
    proposal.streetProposal.edgesToRemove[index] = localId
  end
  for index, cid in ipairs(transaction.remove.nodes) do
    local localId, err = resolveLocalReference({ cid = cid }, slotIds, options)
    if localId == nil then return nil, err end
    proposal.streetProposal.nodesToRemove[index] = localId
  end
  for index, cid in ipairs(transaction.edgeObjects.remove) do
    local localId, err = resolveLocalReference({ cid = cid }, slotIds, options)
    if localId == nil then return nil, err end
    proposal.streetProposal.edgeObjectsToRemove[index] = localId
  end
  local constructionMaterialisation
  if transaction.schemaVersion == M.CONSTRUCTION_SCHEMA_VERSION then
    local spec, specError = M.materialiseConstruction(transaction, { exactProposal = true })
    if not spec then return nil, specError end
    local applied, applyError = constructionProposalMaterializer.apply(proposal, spec, {
      api = gameApi,
      nativePlayerId = options.nativePlayerId,
      resolveLocal = options.resolveLocal,
      omitCollateralRemovals = options.omitConstructionCollateral == true,
    })
    if not applied then return nil, applyError end
    constructionMaterialisation = applied
    if nativeGeneratedTopology then
      -- ConstructionEntity expands only inside api.cmd.make.buildProposal.
      -- Carry these local typed values to the GUI command factory, where the
      -- generated prefix is visible and can be reconciled before sendCommand.
      constructionMaterialisation.exactTopology = {
        nodes = #exactTopology.nodes, edges = #exactTopology.edges,
        edgeObjects = #exactTopology.objects, typed = exactTopology,
      }
    end
  end
  return proposal, {
    slotIds = slotIds, digest = transaction.digest,
    construction = constructionMaterialisation,
    nativeGeneratedTopology = nativeGeneratedTopology,
  }
end

local function stationModuleMetadata(name, year)
  local era = stationEra(year)
  if type(name) ~= "string" or name:sub(1, #STATION_PREFIX) ~= STATION_PREFIX then return nil end
  local relative = name:sub(#STATION_PREFIX + 1)
  local buildingKind, levelText, variant = relative:match("^(main_building)_([123])_(.+)%.module$")
  if not buildingKind then
    buildingKind, levelText, variant = relative:match("^(side_building)_([123])_(.+)%.module$")
  end
  if buildingKind then
    local level = tonumber(levelText)
    local cargo = variant == "cargo"
    if not cargo and variant ~= "era_" .. era then return nil end
    local eraIndex = cargo and 5 or (era == "a" and 0 or (era == "b" and 1 or 2))
    local passengerMain = {
      a = { 20, 40, 100 }, b = { 25, 45, 150 }, c = { 30, 50, 200 },
    }
    local passengerSide = {
      a = { 10, 30, 80 }, b = { 15, 35, 100 }, c = { 20, 40, 150 },
    }
    local cargoCapacity = buildingKind == "main_building"
      and ({ 20, 40, 80 })[level] or ({ 10, 30, 60 })[level]
    local passengerCapacity = buildingKind == "main_building"
      and passengerMain[era][level] or passengerSide[era][level]
    local metadata = {
      era = eraIndex,
      level = level,
      span = level == 1 and { buildingKind == "main_building" and 1 or 2, 2 }
        or (level == 2 and { 1, 2 } or { 0, 3 }),
      moreCapacity = {
        cargo = cargo and cargoCapacity or 0,
        passenger = cargo and 0 or passengerCapacity,
      },
    }
    if buildingKind == "side_building" and level == 3 and (cargo or era ~= "c") then
      metadata.level = cargo and 2 or 3
      metadata.span = { 1, 2 }
    elseif level == 3 and not cargo and era == "c" then
      metadata.has_roof = true
    end
    if buildingKind == "main_building" then
      local distance = ({ 14, 20, 35 })[level]
      metadata.snapPoint = { 0, -1, 0, 0, 1, 0, 0, 0, 0, 0, 1, 0, -distance, 0, 0, 1 }
    end
    return metadata
  end
  if relative:find("platform_passenger_era_", 1, true) then
    return { platform = true, passenger_platform = true }
  end
  if relative:find("platform_cargo_era_", 1, true) then
    return { platform = true, cargo_platform = true }
  end
  if relative == "platform_track.module" or relative == "platform_track_catenary.module"
    or relative == "platform_high_speed_track.module"
    or relative == "platform_high_speed_track_catenary.module" then return { track = true } end
  if relative == "platform_passenger_roof_curved_era_c.module" then
    return { platform_roof = true, platform_roof_curved = true }
  end
  if relative:find("platform_passenger_roof_", 1, true) then return { platform_roof = true } end
  if relative:find("addon_platform_passenger_stairs_", 1, true) then return { underground = true } end
  return nil
end

function M.materialiseConstruction(transaction, options)
  options = options or {}
  local valid, validationError = M.validate(transaction)
  if not valid then return nil, validationError end
  if transaction.schemaVersion ~= M.CONSTRUCTION_SCHEMA_VERSION then
    return nil, "proposal is not a construction transaction"
  end
  local source = transaction.constructions[1]
  if source.mode == "remove" then
    return {
      mode = source.mode, adapter = source.adapter, kind = source.kind,
      slot = source.slot, sourceCid = source.sourceCid,
      collateral = util.deepCopy(source.collateral),
    }
  end
  local params = source.adapter == "stock-rail-station"
    and util.deepCopy(source.params) or materialisePlainValue(source.params)
  if type(params) ~= "table" then return nil, "construction params could not be materialised" end
  if source.mode == "upgrade" and options.exactProposal ~= true then
    -- Build 35924's legacy upgradeConstruction helper owns these two control
    -- fields.  Native GUI proposals expose them in the prepared addition, but
    -- passing them back to the helper makes its lua::Table builder insert a
    -- duplicate key (Value.cpp:38, Assertion `pr.second').  The shipped
    -- constructionupgrader.lua likewise removes seed before invoking the
    -- helper.  Retain both values in the canonical transaction for audit and
    -- digest stability, but never re-supply them at this engine boundary.
    params.seed = nil
    params.upgrade = nil
  end
  params.modules = {}
  for _, module in ipairs(source.modules) do
    local metadata = materialisePlainValue(module.metadata)
    if source.adapter == "stock-rail-station" or (type(metadata) == "table" and next(metadata) == nil) then
      local year = tonumber(params.year)
      metadata = (year and stationModuleMetadata(module.name, year)) or metadata
    end
    if source.adapter == "stock-rail-station" and not metadata then
      return nil, "station module metadata is unavailable"
    end
    params.modules[module.slot] = {
      name = module.name, variant = module.variant, metadata = metadata or {},
    }
  end
  return {
    mode = source.mode,
    adapter = source.adapter,
    kind = source.kind,
    slot = source.slot,
    sourceCid = source.sourceCid,
    collateral = util.deepCopy(source.collateral),
    fileName = source.fileName,
    transform = util.deepCopy(source.transform),
    params = params,
  }
end

local function squaredDistance(a, b)
  local dx, dy, dz = a.x - b.x, a.y - b.y, a.z - b.z
  return dx * dx + dy * dy + dz * dz
end

-- Bind committed output IDs by stable geometry, never by creation order.  The
-- callback's result entity vector is empty for live-proven street/track builds
-- on Build 35924, so callers enumerate before/after component sets and pass
-- their inspected records here.
function M.matchCreated(transaction, createdNodes, createdEdges, tolerance, resolveNodePosition, resolveLocal)
  local valid, validationError = M.validate(transaction)
  if not valid then return nil, validationError end
  tolerance = finite(tolerance) or 0.35
  local limit = tolerance * tolerance
  local result = {
    nodes = {}, edges = {}, edgeObjects = {},
    unmatchedNodes = {}, unmatchedEdges = {}, unmatchedEdgeObjects = {},
  }
  local usedNodes, usedEdges = {}, {}
  for _, expected in ipairs(transaction.nodes) do
    local matches = {}
    for _, observed in ipairs(createdNodes or {}) do
      if not usedNodes[observed.localId] and type(observed.position) == "table"
        and squaredDistance(expected.position, observed.position) <= limit then
        matches[#matches + 1] = observed
      end
    end
    if #matches ~= 1 then return nil, "node output slot " .. expected.slot .. " did not have one geometric match" end
    usedNodes[matches[1].localId] = true
    result.nodes[expected.slot] = matches[1].localId
  end
  local expectedNodePositions = {}
  for _, node in ipairs(transaction.nodes) do expectedNodePositions[node.slot] = node.position end
  local function expectedPosition(reference)
    if reference.slot then return expectedNodePositions[reference.slot] end
    if reference.cid and type(resolveNodePosition) == "function" then
      local ok, position = pcall(resolveNodePosition, reference.cid)
      if ok then return position end
    end
    return nil
  end
  for _, expected in ipairs(transaction.edges) do
    local expected0 = expectedPosition(expected.node0)
    local expected1 = expectedPosition(expected.node1)
    if not expected0 or not expected1 then
      return nil, "edge output slot " .. expected.slot .. " has an unresolved endpoint position"
    end
    local matches = {}
    for _, observed in ipairs(createdEdges or {}) do
      if not usedEdges[observed.localId] and observed.carrier == expected.carrier then
        local resourceMatches = observed.resourceIndex == nil
          or tonumber(observed.resourceIndex) == tonumber(expected.resource and expected.resource.index)
        local catenaryMatches = expected.carrier ~= "track" or observed.catenary == nil
          or observed.catenary == expected.catenary
        local observed0, observed1 = observed.node0Position, observed.node1Position
        local direct = expected0 and expected1 and observed0 and observed1
          and squaredDistance(expected0, observed0) <= limit and squaredDistance(expected1, observed1) <= limit
        local reversed = expected0 and expected1 and observed0 and observed1
          and squaredDistance(expected0, observed1) <= limit and squaredDistance(expected1, observed0) <= limit
        if resourceMatches and catenaryMatches and (direct or reversed) then matches[#matches + 1] = observed end
      end
    end
    if #matches ~= 1 then return nil, "edge output slot " .. expected.slot .. " did not have one geometric match" end
    usedEdges[matches[1].localId] = true
    result.edges[expected.slot] = matches[1].localId
  end
  for _, observed in ipairs(createdNodes or {}) do
    if not usedNodes[observed.localId] then result.unmatchedNodes[#result.unmatchedNodes + 1] = observed.localId end
  end
  for _, observed in ipairs(createdEdges or {}) do
    if not usedEdges[observed.localId] then result.unmatchedEdges[#result.unmatchedEdges + 1] = observed.localId end
  end
  local usedObjects = {}
  for _, retained in ipairs(transaction.edgeObjects and transaction.edgeObjects.retain or {}) do
    local expectedEdgeId = retained.edge.slot and result.edges[retained.edge.slot] or nil
    if not expectedEdgeId then return nil, "retained edge object has an unresolved edge" end
    local retainedId
    if type(resolveLocal) == "function" then
      local ok, value = pcall(resolveLocal, retained.cid)
      if ok then retainedId = integer(value) end
    end
    if retainedId == nil then
      return nil, "retained edge object is not mapped locally: " .. tostring(retained.cid)
    end
    local found = false
    for _, candidate in ipairs(createdEdges or {}) do
      if candidate.localId == expectedEdgeId then
        for _, object in ipairs(candidate.objects or {}) do
          if integer(object.localId) == retainedId and integer(object.category) == retained.category then
            found = true
            usedObjects[retainedId] = true
            break
          end
        end
      end
      if found then break end
    end
    if not found then
      return nil, "retained edge object was not preserved on its replacement edge"
    end
  end
  for _, expected in ipairs(transaction.edgeObjects and transaction.edgeObjects.add or {}) do
    local expectedEdgeId = expected.edge.slot and result.edges[expected.edge.slot] or nil
    if not expectedEdgeId then
      return nil, "edge-object output slot " .. expected.slot .. " has an unresolved edge"
    end
    local observedEdge
    for _, candidate in ipairs(createdEdges or {}) do
      if candidate.localId == expectedEdgeId then observedEdge = candidate; break end
    end
    local matches = {}
    for _, object in ipairs(observedEdge and observedEdge.objects or {}) do
      if not usedObjects[object.localId] and integer(object.category) == expected.category then
        matches[#matches + 1] = object
      end
    end
    if #matches ~= 1 then
      return nil, "edge-object output slot " .. expected.slot .. " did not have one edge/category match"
    end
    usedObjects[matches[1].localId] = true
    result.edgeObjects[expected.slot] = matches[1].localId
  end
  for _, observed in ipairs(createdEdges or {}) do
    for _, object in ipairs(observed.objects or {}) do
      if not usedObjects[object.localId] then
        result.unmatchedEdgeObjects[#result.unmatchedEdgeObjects + 1] = object.localId
      end
    end
  end
  table.sort(result.unmatchedNodes)
  table.sort(result.unmatchedEdges)
  table.sort(result.unmatchedEdgeObjects)
  return result
end

return M
