-- Read-only Transport Fever 2 console helper for discovering stock GUI trees.
--
-- Usage from the in-game console:
--   TPF2MP_GUI_PROBE_ID = "lineManager.newLine"
--   dofile("C:/Users/Sepgi/Downloads/tf2mod/tools/gui_tree_probe.lua")
--
-- The report is written to %TEMP%/tpf2mp-gui-tree.txt.  The helper deliberately
-- performs no clicks or component mutations.

local rootId = rawget(_G, "TPF2MP_GUI_PROBE_ID") or "lineManager.newLine"
local outputPath = (os.getenv("TEMP") or ".") .. "/tpf2mp-gui-tree.txt"
local maxDepth = tonumber(rawget(_G, "TPF2MP_GUI_PROBE_DEPTH")) or 32

local function safeMethod(value, name, ...)
  if value == nil then return nil end
  local okMember, member = pcall(function() return value[name] end)
  if not okMember or type(member) ~= "function" then return nil end
  local okCall, result = pcall(member, value, ...)
  if not okCall then return nil end
  return result
end

local function clean(value)
  if value == nil then return "-" end
  return tostring(value):gsub("[\r\n\t]", " ")
end

local function describeRect(component)
  local rect = safeMethod(component, "getContentRect")
  if rect == nil then return "-" end
  local values = {}
  for _, key in ipairs({ "x", "y", "w", "h", "width", "height", "left", "top", "right", "bottom" }) do
    local ok, value = pcall(function() return rect[key] end)
    if ok and value ~= nil then values[#values + 1] = key .. ":" .. clean(value) end
  end
  for index = 1, 4 do
    local ok, value = pcall(function() return rect[index] end)
    if ok and value ~= nil then values[#values + 1] = tostring(index) .. ":" .. clean(value) end
  end
  if #values == 0 then return clean(rect) end
  return table.concat(values, ",")
end

local seed = assert(api.gui.util.getById(rootId), "stock GUI component is unavailable: " .. rootId)
local root = seed
local climbed = 0
local ancestors = {}
while climbed < maxDepth do
  ancestors[#ancestors + 1] = string.format(
    "ancestor=%d ptr=%s id=%s name=%s",
    climbed,
    clean(root),
    clean(safeMethod(root, "getId")),
    clean(safeMethod(root, "getName")))
  -- A stock window is the smallest useful self-contained tree.  Stopping
  -- here avoids traversing every HUD icon and unrelated hidden window.
  if safeMethod(root, "getName") == "Window" then break end
  local parent = safeMethod(root, "getParent")
  if not parent or parent == root then break end
  root = parent
  climbed = climbed + 1
end

local lines = {
  "probeId=" .. rootId,
  "seed=" .. clean(seed),
  "root=" .. clean(root),
  "climbed=" .. climbed,
}
for _, ancestor in ipairs(ancestors) do lines[#lines + 1] = ancestor end

local function describe(component, path, depth)
  if component == nil or depth > maxDepth then return end
  local fields = {
    "path=" .. path,
    "depth=" .. depth,
    "ptr=" .. clean(component),
    "id=" .. clean(safeMethod(component, "getId")),
    "text=" .. clean(safeMethod(component, "getText")),
    "name=" .. clean(safeMethod(component, "getName")),
    "tooltip=" .. clean(safeMethod(component, "getTooltip")),
    "rect=" .. describeRect(component),
    "visible=" .. clean(safeMethod(component, "isVisible")),
    "enabled=" .. clean(safeMethod(component, "isEnabled")),
    "click=" .. clean(type((function()
      local ok, member = pcall(function() return component.click end)
      return ok and member or nil
    end)())),
    "toggle=" .. clean(type((function()
      local ok, member = pcall(function() return component.toggle end)
      return ok and member or nil
    end)())),
  }
  lines[#lines + 1] = table.concat(fields, " ")

  local layout = safeMethod(component, "getLayout")
  if not layout and safeMethod(component, "getNumItems") ~= nil then
    -- Several stock widgets place a CBoxLayout directly into a parent layout.
    -- Treat that layout item as its own child container so opaque-looking
    -- editors (notably LineManager::LineEditorComp) remain inspectable.
    layout = component
  end
  if not layout then return end
  local count = tonumber(safeMethod(layout, "getNumItems")) or 0
  lines[#lines + 1] = string.format("layout=%s path=%s items=%d", clean(layout), path, count)
  for index = 0, count - 1 do
    describe(safeMethod(layout, "getItem", index), path .. "." .. index, depth + 1)
  end
end

describe(root, "root", 0)

local file = assert(io.open(outputPath, "wb"))
file:write(table.concat(lines, "\n"), "\n")
file:close()
print("TPF2MP GUI tree written", outputPath, #lines)
