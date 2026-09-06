-- Read-only UI selectors plus camera-only fixture setup. Never call click(),
-- buildProposal(), sendCommand(), or a mod intent handler from this module.
local M = {}
local function call(object, name, ...)
  local ok, method = pcall(function() return object and object[name] end)
  if not ok or type(method) ~= "function" then return nil end
  local success, value = pcall(method, object, ...)
  if success then return value end
end
local function field(object, name)
  local ok, value = pcall(function() return object[name] end)
  if ok then return value end
end
local function rect(object)
  local value = call(object, "getContentRect")
  if not value then return nil end
  local result = {}
  for _, key in ipairs({ "x", "y", "w", "h" }) do
    result[key] = tonumber(field(value, key))
  end
  if result.x and result.y and result.w and result.h then return result end
end
local function get(id)
  local ok, value = pcall(api.gui.util.getById, id)
  return ok and value or nil
end

function M.observe(request, gui)
  if request.action == "camera" then
    local c = request.camera
    assert(type(c) == "table", "camera required")
    for _, key in ipairs({ "x", "y", "distance", "angle", "pitch" }) do
      assert(type(c[key]) == "number" and c[key] == c[key]
        and math.abs(c[key]) < 100000, "invalid camera " .. key)
    end
    assert(c.distance >= 20 and c.distance <= 20000, "invalid camera distance")
    local controller = assert(call(get("mainView"), "getCameraController"), "no camera controller")
    controller:setCameraData(api.type.Vec2f.new(c.x, c.y), c.distance, c.angle, c.pitch)
    return { camera = c }
  end
  assert(request.action == "observe", "unknown UI observer action")
  local root = get("mainView")
  assert(root, "UI root is unavailable")
  for _ = 1, 24 do
      local parent = call(root, "getParent")
      if not parent or parent == root then break end
      root = parent
  end
  local viewport = rect(root)
  -- Entity labels can number in the thousands and exhaust a whole-tree walk
  -- before the toolbar. Exact native IDs are queried directly, never guessed.
  if request.rootId then root = get(request.rootId) end
  local inheritedVisible, ancestor = true, root
  for _ = 1, 40 do
    if not ancestor then break end
    inheritedVisible = inheritedVisible and call(ancestor, "isVisible") ~= false
    local parent = call(ancestor, "getParent")
    if not parent or parent == ancestor then break end
    ancestor = parent
  end
  local nodes, seen, remaining, truncated = {}, {}, 4096, false
  local function visit(object, path, parent, depth, visible)
    if not object or seen[object] then return end
    if remaining == 0 or depth > 40 then truncated = true; return end
    seen[object] = true; remaining = remaining - 1
    local index = #nodes + 1
    visible = visible and call(object, "isVisible") ~= false
    local node = { path = path, parent = parent, id = call(object, "getId"),
      text = call(object, "getText"), rect = rect(object), visible = visible,
      enabled = call(object, "isEnabled") ~= false, selected = call(object, "isSelected") }
    -- Text getters occasionally return non-primitive engine userdata.
    if type(node.id) ~= "string" then node.id = nil end
    if type(node.text) ~= "string" then node.text = nil end
    nodes[index] = node
    if not visible then return end -- Do not enumerate thousands of hidden catalogue rows.
    for _, method in ipairs({ "getContent", "getLayout" }) do
      visit(call(object, method), path .. "/" .. method, index, depth + 1, visible)
    end
    for _, methods in ipairs({ { "getNumItems", "getItem" }, { "getNumChildren", "getChild" } }) do
      local count = tonumber(call(object, methods[1])) or 0
      if count > 512 then truncated = true end
      for i = 0, math.min(count - 1, 511) do
        visit(call(object, methods[2], i), path .. "/" .. methods[2] .. ":" .. i,
          index, depth + 1, visible)
      end
    end
  end
  visit(root, "root", nil, 0, inheritedVisible)
  local correlation = gui.buildCorrelation or {}
  local active = (correlation.previews or {})[tostring(correlation.activeCorrelation)]
  local currentPreview
  if request.includePreview == true and type(active) == "table"
      and active.toolGeneration == correlation.toolGeneration then
    currentPreview = { snapshot = active.proposalSnapshot, sourceId = active.sourceId,
      correlationId = active.correlationId, frame = active.frame }
  end
  local previewAges = {}
  for key, pending in pairs(correlation.previews or {}) do
    previewAges[tostring(key)] = { frame = pending.frame,
      ageFrames = (gui.frames or 0) - (tonumber(pending.frame) or 0),
      sourceId = pending.sourceId, family = pending.family,
      toolGeneration = pending.toolGeneration }
  end
  return { nodes = nodes, truncated = truncated or remaining == 0, viewport = viewport,
    groundCursor = request.includeGround == true
      and require("tpf2_mp/live_ui_ground_cursor").read(api, gui.frames) or nil,
    currentPreview = currentPreview,
    lastBuildCapture = gui.liveUiLastBuildCapture,
    lastBuildReplay = gui.liveUiLastBuildReplay,
    frame = gui.frames, quarantine = gui.proposalReplayQuarantine ~= nil,
    buildCorrelation = { activeCorrelation = correlation.activeCorrelation,
      toolGeneration = correlation.toolGeneration, previews = previewAges,
      invalidations = correlation.invalidations,
      lastInvalidationReason = correlation.lastInvalidationReason } }
end
return M
