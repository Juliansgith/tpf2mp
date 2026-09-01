local hash = require "tpf2_mp/hash"
local util = require "tpf2_mp/util"

local M = { MAX_REFERENCES = 1024, MAX_EDGE_OBJECTS = 256 }

local function safeField(value, key)
  if type(value) ~= "table" and type(value) ~= "userdata" then return nil end
  local ok, nested = pcall(function() return value[key] end)
  return ok and nested or nil
end

local function integer(value)
  local number = tonumber(value)
  if not number or number ~= number or number == math.huge or number == -math.huge
    or number ~= math.floor(number) then return nil end
  return number
end

local function quantised(value)
  local number = tonumber(value)
  if not number or number ~= number or number == math.huge or number == -math.huge then
    return nil
  end
  return util.integer(number * 100000)
end

local function vector(value)
  if value == nil then return nil end
  local function coordinate(oneBased, zeroBased, name)
    return quantised(safeField(value, name)
      or safeField(value, oneBased) or safeField(value, zeroBased))
  end
  local x, y, z = coordinate(1, 0, "x"), coordinate(2, 1, "y"), coordinate(3, 2, "z")
  if x == nil or y == nil then return nil end
  return { x, y, z or 0 }
end

local function matrix(value)
  if value == nil then return nil end
  local result = {}
  for index = 1, 16 do
    local number = quantised(safeField(value, index) or safeField(value, index - 1))
    if number == nil then return nil end
    result[index] = number
  end
  return result
end

local function entityNumber(value)
  local number = integer(value)
  if number ~= nil then return number end
  return integer(safeField(value, "entity") or safeField(value, "entityId")
    or safeField(value, "id") or safeField(value, 1) or safeField(value, 0))
end

local function boundedEntities(values)
  local result, seen = {}, {}
  local function add(value)
    local id = entityNumber(value)
    if id ~= nil and id >= 0 and not seen[id] then
      seen[id], result[#result + 1] = true, id
    end
  end
  if type(values) == "table" then
    for _, value in pairs(values) do
      if #result >= M.MAX_EDGE_OBJECTS then break end
      add(value)
    end
  elseif type(values) == "userdata" then
    local lengthOk, length = pcall(function() return #values end)
    length = lengthOk and integer(length) or nil
    if length and length >= 0 then
      for _, base in ipairs({ 0, 1 }) do
        for offset = 0, math.min(length, M.MAX_EDGE_OBJECTS) - 1 do
          local ok, value = pcall(function() return values[base + offset] end)
          if ok and value ~= nil then add(value) end
        end
      end
    else
      local misses = 0
      for index = 0, M.MAX_EDGE_OBJECTS - 1 do
        local ok, value = pcall(function() return values[index] end)
        if ok and value ~= nil then add(value); misses = 0 else misses = misses + 1 end
        if misses >= 8 then break end
      end
    end
  end
  table.sort(result)
  return result
end

local function resourceIdentity(value)
  if value == nil then return nil end
  local number = integer(value)
  if number ~= nil then return number end
  for _, field in ipairs({ "index", "id", "fileName", "name" }) do
    local nested = safeField(value, field)
    if type(nested) == "string" then return nested end
    number = integer(nested)
    if number ~= nil then return number end
  end
  return "opaque"
end

local function component(gameApi, id, componentType)
  local reader = gameApi and gameApi.engine and gameApi.engine.getComponent
  if not (componentType and util.isCallable(reader)) then return nil end
  local ok, value = pcall(reader, id, componentType)
  return ok and value or nil
end

local function entityExists(gameApi, id)
  local reader = gameApi and gameApi.engine and gameApi.engine.entityExists
  if not util.isCallable(reader) then return true end
  local ok, exists = pcall(reader, id)
  return ok and exists == true
end

local function ownerProjection(gameApi, id, types)
  local owned = component(gameApi, id, types.PLAYER_OWNED)
  return owned and integer(safeField(owned, "player") or safeField(owned, "playerEntity")) or nil
end

local function signature(gameApi, id, kind)
  local types = gameApi and gameApi.type and gameApi.type.ComponentType or {}
  if not entityExists(gameApi, id) then return nil, "entity disappeared" end
  local value = { kind = kind, id = id }
  if kind == "node" then
    local node = component(gameApi, id, types.BASE_NODE)
    if not node then return nil, "BASE_NODE is unavailable" end
    value.position = vector(safeField(node, "position") or safeField(node, "pos"))
    if not value.position then return nil, "BASE_NODE position is unavailable" end
  elseif kind == "edge" then
    local edge = component(gameApi, id, types.BASE_EDGE)
    if not edge then return nil, "BASE_EDGE is unavailable" end
    value.node0, value.node1 = integer(safeField(edge, "node0")), integer(safeField(edge, "node1"))
    value.tangent0, value.tangent1 = vector(safeField(edge, "tangent0")), vector(safeField(edge, "tangent1"))
    value.type = integer(safeField(edge, "type"))
    value.typeIndex = integer(safeField(edge, "typeIndex"))
    value.objects = boundedEntities(safeField(edge, "objects"))
    if value.node0 == nil or value.node1 == nil or value.node0 == value.node1
      or not value.tangent0 or not value.tangent1 then
      return nil, "BASE_EDGE geometry is incomplete"
    end
    local street = component(gameApi, id, types.BASE_EDGE_STREET)
    local track = component(gameApi, id, types.BASE_EDGE_TRACK)
    if street and track then return nil, "edge has two carrier components" end
    if street then
      value.carrier = "street"
      value.resource = resourceIdentity(safeField(street, "streetType"))
    elseif track then
      value.carrier = "track"
      value.resource = resourceIdentity(safeField(track, "trackType"))
      value.catenary = safeField(track, "catenary") == true
    else
      return nil, "edge has no carrier component"
    end
    value.owner = ownerProjection(gameApi, id, types)
  elseif kind == "construction" then
    local construction = component(gameApi, id, types.CONSTRUCTION)
    if not construction then return nil, "CONSTRUCTION is unavailable" end
    value.fileName = tostring(safeField(construction, "fileName") or "")
    value.transform = matrix(safeField(construction, "transf") or safeField(construction, "transform"))
    value.owner = ownerProjection(gameApi, id, types)
  elseif kind == "asset" then
    if types.ASSET_GROUP and not component(gameApi, id, types.ASSET_GROUP) then
      return nil, "ASSET_GROUP is unavailable"
    end
    value.owner = ownerProjection(gameApi, id, types)
  elseif kind == "edge_object" then
    value.owner = ownerProjection(gameApi, id, types)
  else
    value.owner = ownerProjection(gameApi, id, types)
  end
  return hash.value(value), value
end

local function inferredKind(cid, fallback)
  local kind = type(cid) == "string" and cid:match("^([a-z_]+):") or nil
  return kind or fallback
end

function M.references(transaction, options)
  options = options or {}
  local byCid = {}
  local function add(cid, kind)
    if type(cid) == "string" and cid ~= "" then byCid[cid] = inferredKind(cid, kind) end
  end
  for _, edge in ipairs(type(transaction) == "table" and transaction.edges or {}) do
    for _, reference in ipairs({ edge.node0, edge.node1 }) do
      add(type(reference) == "table" and reference.cid or nil, "node")
    end
  end
  local remove = type(transaction) == "table" and transaction.remove or {}
  for _, cid in ipairs(type(remove) == "table" and remove.edges or {}) do add(cid, "edge") end
  for _, cid in ipairs(type(remove) == "table" and remove.nodes or {}) do add(cid, "node") end
  local objects = type(transaction) == "table" and transaction.edgeObjects or {}
  for _, object in ipairs(type(objects) == "table" and objects.add or {}) do
    add(type(object.edge) == "table" and object.edge.cid or nil, "edge")
  end
  for _, object in ipairs(type(objects) == "table" and objects.retain or {}) do
    add(object.cid, "edge_object")
    add(type(object.edge) == "table" and object.edge.cid or nil, "edge")
  end
  for _, cid in ipairs(type(objects) == "table" and objects.remove or {}) do add(cid, "edge_object") end
  for _, construction in ipairs(type(transaction) == "table" and transaction.constructions or {}) do
    add(construction.sourceCid, "construction")
    if options.omitConstructionCollateral ~= true then
      for _, collateral in ipairs(type(construction.collateral) == "table"
          and construction.collateral or {}) do
        add(collateral.cid, collateral.kind)
      end
    end
  end
  local result = {}
  for cid, kind in pairs(byCid) do result[#result + 1] = { cid = cid, kind = kind } end
  table.sort(result, function(a, b) return a.cid < b.cid end)
  return result
end

function M.validateReference(reference, localRefs, gameApi, options)
  options = options or {}
  local cid, kind = reference.cid, reference.kind
  local localId = localRefs and integer(localRefs[cid]) or nil
  if localId == nil or localId < 0 then
    return nil, "canonical " .. tostring(kind)
      .. " is not mapped immediately before replay: " .. tostring(cid)
  end
  local engine = gameApi and gameApi.engine
  local types = gameApi and gameApi.type and gameApi.type.ComponentType or {}
  if not (engine and util.isCallable(engine.getComponent)) then
    return nil, "canonical reference preflight API is unavailable"
  end
  if util.isCallable(engine.entityExists) then
    local existsOk, exists = pcall(engine.entityExists, localId)
    if not existsOk or exists ~= true then
      return nil, "canonical " .. tostring(kind)
        .. " disappeared immediately before replay: " .. tostring(cid)
    end
  end
  local required = kind == "node" and types.BASE_NODE
    or kind == "edge" and types.BASE_EDGE
    or kind == "construction" and types.CONSTRUCTION
    or kind == "asset" and types.ASSET_GROUP or nil
  if required and not component(gameApi, localId, required) then
    return nil, "canonical " .. tostring(kind)
      .. " lost its native component immediately before replay: " .. tostring(cid)
  end
  if (kind == "node" or kind == "edge") and type(options.fingerprint) == "function" then
    local expected = cid:match("^" .. kind .. ":pre:([0-9a-f]+)")
    if expected then
      local fingerprintOk, observed = pcall(options.fingerprint, localId, kind)
      if not fingerprintOk or observed ~= expected then
        return nil, "canonical " .. tostring(kind)
          .. " fingerprint changed immediately before replay: " .. tostring(cid)
      end
    end
  end
  if kind == "edge" and types.BASE_EDGE then
    local edge = component(gameApi, localId, types.BASE_EDGE)
    local node0, node1 = edge and integer(safeField(edge, "node0")),
      edge and integer(safeField(edge, "node1"))
    if node0 == nil or node1 == nil or node0 < 0 or node1 < 0 or node0 == node1 then
      return nil, "canonical edge has invalid endpoints immediately before replay: "
        .. tostring(cid)
    end
    if types.BASE_NODE then
      for _, nodeId in ipairs({ node0, node1 }) do
        if not component(gameApi, nodeId, types.BASE_NODE) then
          return nil, "canonical edge endpoint lost BASE_NODE immediately before replay: "
            .. tostring(cid)
        end
      end
    end
  end
  return true
end

local function addEntry(entries, seen, id, kind, cid)
  id = integer(id)
  if id == nil or id < 0 then return nil, "canonical reference is not mapped: " .. tostring(cid) end
  local key = tostring(kind) .. ":" .. tostring(id)
  if not seen[key] then
    if #entries >= M.MAX_REFERENCES then return nil, "native topology guard reference limit exceeded" end
    seen[key] = true
    entries[#entries + 1] = { key = key, id = id, kind = kind, cid = cid }
  end
  return true
end

function M.capture(transaction, localRefs, gameApi, options)
  local references = M.references(transaction, options)
  if #references == 0 then return { entries = {}, signatures = {}, digest = hash.value({}) } end
  local entries, seen = {}, {}
  for _, reference in ipairs(references) do
    local ok, err = addEntry(entries, seen, localRefs and localRefs[reference.cid],
      reference.kind, reference.cid)
    if not ok then return nil, err end
  end
  local types = gameApi and gameApi.type and gameApi.type.ComponentType or {}
  -- An input edge's endpoint nodes are native StreetGeometry inputs even when
  -- the canonical transaction named only the edge for removal/replacement.
  local initialCount = #entries
  for index = 1, initialCount do
    local entry = entries[index]
    if entry.kind == "edge" then
      local edge = component(gameApi, entry.id, types.BASE_EDGE)
      if not edge then return nil, "referenced edge lost BASE_EDGE: " .. tostring(entry.cid) end
      for _, field in ipairs({ "node0", "node1" }) do
        local id = integer(safeField(edge, field))
        local ok, err = addEntry(entries, seen, id, "node",
          tostring(entry.cid) .. "." .. field)
        if not ok then return nil, err end
      end
    end
  end
  table.sort(entries, function(a, b) return a.key < b.key end)
  local signatures = {}
  for _, entry in ipairs(entries) do
    local digest, detail = signature(gameApi, entry.id, entry.kind)
    if not digest then
      return nil, tostring(entry.cid) .. ": " .. tostring(detail)
    end
    signatures[entry.key] = digest
  end
  return { entries = entries, signatures = signatures, digest = hash.value(signatures) }
end

function M.recapture(before, gameApi)
  if type(before) ~= "table" or type(before.entries) ~= "table" then
    return nil, "native topology guard snapshot is missing"
  end
  local signatures = {}
  for _, entry in ipairs(before.entries) do
    local digest, detail = signature(gameApi, entry.id, entry.kind)
    if not digest then
      return nil, tostring(entry.cid) .. ": " .. tostring(detail)
    end
    signatures[entry.key] = digest
  end
  return { entries = before.entries, signatures = signatures, digest = hash.value(signatures) }
end

function M.compare(before, after)
  if type(before) ~= "table" or type(after) ~= "table" then
    return false, "native topology attestation is unavailable"
  end
  if before.digest == after.digest then return true end
  local changed = {}
  for key, digest in pairs(before.signatures or {}) do
    if (after.signatures or {})[key] ~= digest then changed[#changed + 1] = key end
  end
  for key in pairs(after.signatures or {}) do
    if (before.signatures or {})[key] == nil then changed[#changed + 1] = key end
  end
  table.sort(changed)
  while #changed > 12 do table.remove(changed) end
  return false, "native rejection changed referenced topology: " .. table.concat(changed, ",")
end

M.signature = signature

return M
