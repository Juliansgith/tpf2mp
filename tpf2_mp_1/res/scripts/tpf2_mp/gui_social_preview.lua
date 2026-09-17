-- Geometry half of the social channel (see docs/SOCIAL_CHANNEL.md): read the
-- planned route out of an open builder proposal, and turn a remote peer's
-- planned route back into flat ground outlines. Everything here is advisory:
-- it never evaluates a proposal, never touches api.cmd, and never writes an
-- entity.
--
-- Two passes read a proposal. The XY pass is the base contract and always
-- produces the flat ribbons. The optional detail pass adds heights, terrain
-- class and resource NAMES, which is exactly what the native renderer needs to
-- draw the vanilla builder ghost; a receiver without that renderer ignores it
-- and still draws ribbons. A construction's parameter table is copied out of
-- the proposal through gui_social_params, because the builder hands it over as
-- engine userdata that must never be retained past the event.
local params = require "tpf2_mp/gui_social_params"

local M = {}

-- One cubic Hermite per new segment, matching the wire contract.
M.MAX_CURVES = 24
M.CONSTRUCTION_MARKER_METRES = 10
-- A track/street/bridge/tunnel/construction resource NAME. Resource indices
-- differ between clients and are never sent; each peer resolves its own.
M.MAX_RESOURCE = 128

local TOOL_KIND = { streetBuilder = "road", trackBuilder = "rail" }
local SEGMENT_TYPE = { road = 0, rail = 1 }

-- Coordinates cross a process boundary, so every number is bounded here and
-- again on the way back in. NaN fails the self-comparison.
function M.finite(value, limit)
  if type(value) ~= "number" or value ~= value then return nil end
  if math.abs(value) > (limit or 1000000) then return nil end
  return value
end

-- A ground outline needs centimetres, not doubles. Rounding before the wire
-- keeps a full 24-curve preview far under the companion's 32 KiB frame limit
-- and makes an unchanged proposal encode identically every frame.
function M.round(value, places)
  local scale = 10 ^ (places or 2)
  local scaled = value * scale
  if scaled >= 0 then return math.floor(scaled + 0.5) / scale end
  return -math.floor(-scaled + 0.5) / scale
end

-- Proposal geometry arrives as engine userdata whose fields may be absent or
-- raise on access, so every read is guarded and both layouts are accepted.
local function xy(value)
  if value == nil then return nil end
  local x, y
  pcall(function() x, y = M.finite(value.x), M.finite(value.y) end)
  if not x or not y then
    pcall(function() x, y = M.finite(value[1]), M.finite(value[2]) end)
  end
  if x and y then return x, y end
  return nil
end
M.xy = xy

local function xyz(value)
  if value == nil then return nil end
  local x, y, z
  pcall(function() x, y, z = M.finite(value.x), M.finite(value.y), M.finite(value.z) end)
  if not x or not y or not z then
    pcall(function()
      x, y, z = M.finite(value[1]), M.finite(value[2]), M.finite(value[3])
    end)
  end
  if x and y and z then return x, y, z end
  return nil
end
M.xyz = xyz

-- Proposal fields may be absent or raise on access, so every read is guarded.
local function field(value, key)
  if value == nil then return nil end
  local ok, result = pcall(function() return value[key] end)
  if not ok then return nil end
  return result
end
M.field = field

-- A small non-negative whole number: terrain class, bus flag, tram kind.
function M.whole(value, limit)
  local number = M.finite(value, limit)
  if not number or number < 0 or number ~= math.floor(number) then return nil end
  return number
end

function M.resourceName(value)
  if type(value) ~= "string" then return nil end
  if #value < 1 or #value > M.MAX_RESOURCE then return nil end
  if not value:match("^[%w_./%-]+$") then return nil end
  return value
end

local function repFunction(name, key)
  local resources = api and api.res
  if resources == nil then return nil end
  local rep = field(resources, name)
  local value = field(rep, key)
  -- The game binds repository functions as callable userdata, not Lua
  -- functions (see util.isCallable), so accept any callable type.
  local valueType = type(value)
  if valueType ~= "function" and valueType ~= "userdata" and valueType ~= "table" then
    return nil
  end
  return value
end
M.repFunction = repFunction

local STRUCTURE_REP = { [1] = "bridgeTypeRep", [2] = "tunnelTypeRep" }

-- The base game's mission/proposalutil.lua uses this event layout:
-- param.proposal.proposal.{addedNodes,addedSegments,new2oldSegments}.
function M.extractStreet(id, param)
  local kind = TOOL_KIND[id]
  if not kind then return nil end
  local simple = param and param.proposal and param.proposal.proposal
  if not simple or not simple.addedSegments or not simple.addedNodes then return nil end
  if #simple.addedSegments > 256 or #simple.addedNodes > 512 then return nil end
  local nodes, curves = {}, {}
  for _, node in ipairs(simple.addedNodes) do
    if type(node.entity) == "number" and node.comp then
      local x, y = xy(node.comp.position)
      if x then nodes[node.entity] = { x, y } end
    end
  end
  -- Negative ids belong to the proposal itself; positive ones are pre-existing
  -- nodes this peer resolves locally. No entity id ever leaves the machine.
  local function position(nodeId)
    if type(nodeId) ~= "number" or nodeId ~= math.floor(nodeId) then return nil end
    local known = nodes[nodeId]
    if known then return known[1], known[2] end
    if nodeId < 0 then return nil end
    local ok, component = pcall(function()
      if type(api.engine.entityExists) == "function"
        and not api.engine.entityExists(nodeId) then return nil end
      return api.engine.getComponent(nodeId, api.type.ComponentType.BASE_NODE)
    end)
    if not ok or not component then return nil end
    local x, y = xy(component.position)
    if not x then return nil end
    nodes[nodeId] = { x, y }
    return x, y
  end
  local wanted = SEGMENT_TYPE[kind]
  for _, segment in ipairs(simple.addedSegments) do
    local replaced = false
    if simple.new2oldSegments ~= nil and segment.entity ~= nil then
      replaced = simple.new2oldSegments[segment.entity] ~= nil
    end
    -- Companion replacements at crossings are not the planned route.
    if segment.type == wanted and not replaced then
      local comp = segment.comp
      if not comp then return nil end
      local x0, y0 = position(comp.node0)
      local x1, y1 = position(comp.node1)
      local tx0, ty0 = xy(comp.tangent0)
      local tx1, ty1 = xy(comp.tangent1)
      if not x0 or not x1 or not tx0 or not tx1 then return nil end
      local curve = { x0, y0, x1, y1, tx0, ty0, tx1, ty1 }
      for index = 1, 8 do curve[index] = M.round(curve[index], 2) end
      curves[#curves + 1] = curve
      if #curves > M.MAX_CURVES then return nil end
    end
  end
  if #curves == 0 then return nil end
  return { kind = kind, invalid = false, curves = curves }
end

-- The optional 3D half of the same capture, in the same segment order: entry i
-- belongs to curve i, so this pass filters segments exactly as M.extractStreet
-- does. Only plain numbers and resource names are copied out; no userdata, no
-- resource index and no entity id survives the call. Any unreadable field
-- abandons the whole detail set, and the peer keeps its flat ribbons.
function M.extractDetails(id, param)
  local kind = TOOL_KIND[id]
  if kind ~= "road" and kind ~= "rail" then return nil end
  local simple = param and param.proposal and param.proposal.proposal
  if not simple or not simple.addedSegments or not simple.addedNodes then return nil end
  if #simple.addedSegments > 256 or #simple.addedNodes > 512 then return nil end
  local rail = (kind == "rail")
  local typeRepName = "streetTypeRep"
  if rail then typeRepName = "trackTypeRep" end
  -- Without the resource repository no name can be resolved, so give up before
  -- walking the proposal at all.
  if not repFunction(typeRepName, "getName") then return nil end
  local heights = {}
  for _, node in ipairs(simple.addedNodes) do
    if type(node.entity) == "number" and node.comp then
      local _, _, z = xyz(node.comp.position)
      if z then heights[node.entity] = z end
    end
  end
  local function height(nodeId)
    if type(nodeId) ~= "number" or nodeId ~= math.floor(nodeId) then return nil end
    local known = heights[nodeId]
    if known ~= nil then return known end
    if nodeId < 0 then return nil end
    local ok, component = pcall(function()
      if type(api.engine.entityExists) == "function"
        and not api.engine.entityExists(nodeId) then return nil end
      return api.engine.getComponent(nodeId, api.type.ComponentType.BASE_NODE)
    end)
    if not ok or not component then return nil end
    local _, _, z = xyz(component.position)
    if not z then return nil end
    heights[nodeId] = z
    return z
  end
  -- The resolved name is read back from the index so a stale or out-of-range
  -- index becomes a dropped detail set rather than a wrong resource.
  local function resolvedName(repName, index)
    local bounded = M.whole(index, 1000000)
    if not bounded then return nil end
    local getName = repFunction(repName, "getName")
    if not getName then return nil end
    local ok, name = pcall(getName, bounded)
    if not ok then return nil end
    return M.resourceName(name)
  end
  local wanted, details = SEGMENT_TYPE[kind], {}
  for _, segment in ipairs(simple.addedSegments) do
    local replaced = false
    if simple.new2oldSegments ~= nil and segment.entity ~= nil then
      replaced = simple.new2oldSegments[segment.entity] ~= nil
    end
    if segment.type == wanted and not replaced then
      local comp = segment.comp
      if not comp then return nil end
      local z0, z1 = height(comp.node0), height(comp.node1)
      local _, _, tz0 = xyz(comp.tangent0)
      local _, _, tz1 = xyz(comp.tangent1)
      local terrain = M.whole(field(comp, "type"), 2)
      if not z0 or not z1 or not tz0 or not tz1 or not terrain then return nil end
      local trackEdge, streetEdge = field(segment, "trackEdge"), field(segment, "streetEdge")
      local file, bus, tram, catenary
      if rail then
        file = resolvedName("trackTypeRep", field(trackEdge, "trackType"))
        bus, tram, catenary = 0, 0, 0
        if field(trackEdge, "catenary") == true then catenary = 1 end
      else
        file = resolvedName("streetTypeRep", field(streetEdge, "streetType"))
        bus, tram, catenary = 0, M.whole(field(streetEdge, "tramTrackType"), 2), 0
        if field(streetEdge, "hasBus") == true then bus = 1 end
      end
      local structure = ""
      if terrain > 0 then
        structure = resolvedName(STRUCTURE_REP[terrain], field(comp, "typeIndex"))
      end
      if not file or not tram or not structure then return nil end
      details[#details + 1] = {
        M.round(z0, 2), M.round(z1, 2), M.round(tz0, 2), M.round(tz1, 2),
        terrain, file, bus, tram, catenary, structure,
      }
      if #details > M.MAX_CURVES then return nil end
    end
  end
  if #details == 0 then return nil end
  return details
end

function M.extractConstruction(param)
  local proposal = param and param.proposal
  if not proposal or type(proposal.toAdd) ~= "table" or #proposal.toAdd ~= 1 then return nil end
  -- Editing an existing modular station is a replacement, not a new placement.
  if proposal.toRemove ~= nil and #proposal.toRemove > 0 then return nil end
  local entry = proposal.toAdd[1]
  local file = entry and entry.fileName
  if type(file) ~= "string" or #file > 128 then return nil end
  if not file:match("^[%w_./%-]+%.con$") then return nil end
  local transf = {}
  for index = 1, 16 do
    local limit = 1000
    if index >= 13 and index <= 15 then limit = 1000000 end
    local value
    pcall(function() value = M.finite(entry.transf[index], limit) end)
    if not value then return nil end
    -- Translation is metres; the rotation/scale block needs finer places.
    local places = 6
    if index >= 13 then places = 2 end
    transf[index] = M.round(value, places)
  end
  local body = { kind = "construction", invalid = false, file = file,
    x = transf[13], y = transf[14], z = transf[15], transf = transf }
  -- The builder's parameter table is engine userdata: copy it into a bounded
  -- printable string here and never hold the original past this call. Without
  -- it the remote peer still gets the placement marker.
  local encoded = params.encode(field(entry, "params"))
  if type(encoded) == "string" and #encoded >= 1 then body.params = encoded end
  return body
end

function M.extract(id, param)
  if id == "constructionBuilder" then return M.extractConstruction(param) end
  return M.extractStreet(id, param)
end

-- Build 35924 proposalCreate carries data.errorState. The native renderer's
-- red flag comes from nonempty error messages, not from the warnings list.
-- An unreadable state stays unknown; it never becomes a valid preview.
function M.invalidFlag(param)
  local errorState = param and param.data and param.data.errorState
  if not errorState or errorState.messages == nil then return nil end
  local kind = type(errorState.messages)
  if kind ~= "table" and kind ~= "userdata" then return nil end
  return #errorState.messages > 0
end

-- Measured on build 35924: cancelling a builder sends no GUI event. The
-- unnamed BuildControlComp survives, but its CancelButton/CostsLabel/
-- ErrorLabel turn invisible. Only the renderer's small action layer is
-- inspected, never the full HUD, and no callback is ever replaced.
function M.controlsVisible()
  local helpers = api and api.gui and api.gui.util
  if type(helpers) ~= "table" or type(helpers.getGameUI) ~= "function" then return nil end
  local ok, result = pcall(function()
    local layers = helpers.getGameUI():getMainRendererComponent():getLayout()
    if not layers then return false end
    local count = 0
    local function visible(item, depth)
      count = count + 1
      if not item or depth > 8 or count > 96 then return false end
      item = helpers.downcast(item)
      local name, shown, layout, items
      pcall(function()
        name, shown, layout = item:getName(), item:isVisible(), item:getLayout()
      end)
      if shown == false then return false end
      if name == "BuildControlComp::CancelButton"
        or name == "BuildControlComp::CostsLabel"
        or name == "BuildControlComp::ErrorLabel" then return shown == true end
      if layout then return visible(layout, depth + 1) end
      pcall(function() items = item:getNumItems() end)
      if items then
        for index = 0, math.min(items, 32) - 1 do
          if visible(item:getItem(index), depth + 1) then return true end
        end
      end
      return false
    end
    for index = 0, math.min(layers:getNumItems(), 8) - 1 do
      local layer = helpers.downcast(layers:getItem(index))
      if layer:getName() == "RendererComponent::Layer1" then return visible(layer, 0) end
    end
    return false
  end)
  if not ok then return nil end
  return result == true
end

-- A thin ribbon around the actual Hermite curve. setZone paints on the ground,
-- so a bridge or tunnel shows its horizontal route, never its height.
function M.polygon(curve, width)
  for index = 1, 8 do
    if not M.finite(curve[index]) then return nil end
  end
  local length = math.sqrt((curve[3] - curve[1]) ^ 2 + (curve[4] - curve[2]) ^ 2)
  local samples = math.max(8, math.min(48, math.ceil(length / 15)))
  local left, right = {}, {}
  for index = 0, samples do
    local t = index / samples
    local h0, h1 = 2 * t ^ 3 - 3 * t ^ 2 + 1, -2 * t ^ 3 + 3 * t ^ 2
    local h2, h3 = t ^ 3 - 2 * t ^ 2 + t, t ^ 3 - t ^ 2
    local x = h0 * curve[1] + h1 * curve[3] + h2 * curve[5] + h3 * curve[7]
    local y = h0 * curve[2] + h1 * curve[4] + h2 * curve[6] + h3 * curve[8]
    local d0, d1 = 6 * t * t - 6 * t, -6 * t * t + 6 * t
    local d2, d3 = 3 * t * t - 4 * t + 1, 3 * t * t - 2 * t
    local dx = d0 * curve[1] + d1 * curve[3] + d2 * curve[5] + d3 * curve[7]
    local dy = d0 * curve[2] + d1 * curve[4] + d2 * curve[6] + d3 * curve[8]
    local norm = math.sqrt(dx * dx + dy * dy)
    if norm < 0.001 then
      dx, dy, norm = curve[3] - curve[1], curve[4] - curve[2], length
    end
    if norm < 0.001 then return nil end
    local nx, ny = -dy / norm * width, dx / norm * width
    left[#left + 1] = { x + nx, y + ny }
    right[#right + 1] = { x - nx, y - ny }
  end
  for index = #right, 1, -1 do left[#left + 1] = right[index] end
  return left
end

-- A small oriented placement marker, NOT an asserted building footprint.
function M.quad(body, metres)
  local transf = body and body.transf
  if type(transf) ~= "table" then return nil end
  local half = (metres or M.CONSTRUCTION_MARKER_METRES) / 2
  local points = {}
  for _, corner in ipairs({ { -1, -1 }, { 1, -1 }, { 1, 1 }, { -1, 1 } }) do
    local px, py = corner[1] * half, corner[2] * half
    points[#points + 1] = {
      transf[13] + px * transf[1] + py * transf[5],
      transf[14] + px * transf[2] + py * transf[6],
    }
  end
  return points
end

-- An annulus, drawn as one outer loop followed by the inner loop reversed, so
-- a single filled zone reads as a ring.
function M.ring(x, y, radius, thickness)
  if not M.finite(x) or not M.finite(y) then return nil end
  local inner = math.max(0.5, radius - thickness)
  local points, reverse = {}, {}
  for index = 0, 24 do
    local angle = index / 24 * math.pi * 2
    local cosine, sine = math.cos(angle), math.sin(angle)
    points[#points + 1] = { x + cosine * radius, y + sine * radius }
    reverse[#reverse + 1] = { x + cosine * inner, y + sine * inner }
  end
  for index = #reverse, 1, -1 do points[#points + 1] = reverse[index] end
  return points
end

return M
