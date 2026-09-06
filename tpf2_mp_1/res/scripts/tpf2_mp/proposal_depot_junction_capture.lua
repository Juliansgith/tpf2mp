local junction = require "tpf2_mp/proposal_depot_junction"
local util = require "tpf2_mp/util"
local M = {}

local function field(value, key)
  local ok, result = pcall(function() return value[key] end)
  if ok then return result end
end

local function vector(value)
  if not value then return nil end
  return { x = field(value, "x") or field(value, 1),
    y = field(value, "y") or field(value, 2), z = field(value, "z") or field(value, 3) }
end

local function requireUnfrozen(getter, id)
  if not util.isCallable(getter) then return nil, "construction attachment lookup is unavailable" end
  local ok, owner = pcall(getter, id)
  if not ok or (owner ~= nil and (type(owner) ~= "number" or owner ~= owner
      or owner == math.huge or owner < -1 or owner ~= math.floor(owner))) then
    return nil, "construction attachment could not be verified"
  end
  if owner and owner >= 0 then
    return nil, "depot junction touches construction-owned infrastructure; replacement is not yet supported"
  end
  return true
end

function M.normalise(transaction, deps)
  local cid = junction.target(transaction)
  if not cid then return transaction end
  local nodeId, resolveError = deps.resolveLocal(cid, "node")
  if not nodeId then return nil, resolveError end
  local apiValue, codec = deps.api, deps.codec
  local types = apiValue and apiValue.type and apiValue.type.ComponentType or {}
  local connector = apiValue and apiValue.engine and apiValue.engine.system
    and apiValue.engine.system.streetConnectorSystem or {}
  local unfrozen, frozenError = requireUnfrozen(connector.getStreetConnectorEntity, nodeId)
  if not unfrozen then return nil, frozenError end
  local function component(id, kind)
    local componentType = types[kind]
    if not componentType then return nil end
    local ok, result = pcall(apiValue.engine.getComponent, id, componentType)
    return ok and result or nil
  end
  local node = component(nodeId, "BASE_NODE")
  local position = vector(field(node, "position") or field(node, "pos"))
  if not position then return nil, "depot junction position is unavailable" end
  local incident, incomplete = {}, nil
  -- A one-shot scan at the suppressed click, never a per-frame preview scan.
  -- Enumerate the full adjacency: missing one branch would leave a live edge
  -- referencing the removed node. Engine node wrappers don't all expose edges.
  local scanned, scanError = pcall(function()
    apiValue.engine.forEachEntityWithComponent(function(id)
      local edge = component(id, "BASE_EDGE")
      if not edge or type(field(edge, "node0")) ~= "number"
        or type(field(edge, "node1")) ~= "number" then
        incomplete = "road adjacency changed or could not be read"
        return
      end
      if field(edge, "node0") == nodeId or field(edge, "node1") == nodeId then
        if #incident >= 16 then incomplete = "depot junction exceeds 16 road branches"
        else incident[#incident + 1] = tonumber(id) end
      end
    end, types.BASE_EDGE)
  end)
  if not scanned then return nil, "cannot inspect depot junction: " .. tostring(scanError) end
  if incomplete then return nil, incomplete end
  table.sort(incident)
  local branches = {}
  for _, id in ipairs(incident) do
    -- Do not replace another depot/station's frozen entrance merely because
    -- the same company owns it. A road junction can already serve a building.
    local freeEdge, edgeOwnerError = requireUnfrozen(connector.getConstructionEntityForEdge, id)
    if not freeEdge then return nil, edgeOwnerError end
    local edge, street = component(id, "BASE_EDGE"), component(id, "BASE_EDGE_STREET")
    if not street or component(id, "BASE_EDGE_TRACK") then
      return nil, "depot junction includes non-road infrastructure"
    end
    local objects = field(edge, "objects")
    local objectsOk, objectCount = pcall(function() return objects and #objects or 0 end)
    if objects == nil or not objectsOk or objectCount ~= 0 then
      return nil, "depot junction road carries edge objects; replacement is not yet supported"
    end
    local owned = component(id, "PLAYER_OWNED")
    local raw = { costs = 0, nodesToAdd = {}, edgesToAdd = {{
      entity = -1, type = 0,
      comp = { node0 = field(edge, "node0"), node1 = field(edge, "node1"),
        tangent0 = vector(field(edge, "tangent0")), tangent1 = vector(field(edge, "tangent1")),
        type = field(edge, "type"), typeIndex = field(edge, "typeIndex"), objects = {} },
      streetEdge = { streetType = field(street, "streetType"),
        tramTrackType = field(street, "tramTrackType"), hasBus = field(street, "hasBus") },
      playerOwned = owned and { player = field(owned, "player") } or nil,
    }}, edgesToRemove = {}, nodesToRemove = {} }
    local captured, captureError = codec.normalise(raw, transaction.companyCid, deps.options)
    if not captured then return nil, captureError end
    local edgeCid, edgeError = deps.options.resolveCanonical("edge", id)
    if not edgeCid then return nil, edgeError end
    branches[#branches + 1] = { cid = edgeCid, edge = captured.edges[1] }
  end
  return junction.expand(transaction, { cid = cid, position = position, branches = branches }, codec)
end

return M
