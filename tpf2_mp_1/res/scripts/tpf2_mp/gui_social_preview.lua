-- Geometry half of the social channel (see docs/SOCIAL_CHANNEL.md): read the
-- planned route out of an open builder proposal, and turn a remote peer's
-- planned route back into flat ground outlines. Everything here is advisory:
-- it never evaluates a proposal, never touches api.cmd, and never writes an
-- entity. Heights, bridges and tunnels are deliberately dropped; only the
-- horizontal route is shared.
local M = {}

-- One cubic Hermite per new segment, matching the wire contract.
M.MAX_CURVES = 24
M.CONSTRUCTION_MARKER_METRES = 10

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
  return { kind = "construction", invalid = false, file = file,
    x = transf[13], y = transf[14], z = transf[15], transf = transf }
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
