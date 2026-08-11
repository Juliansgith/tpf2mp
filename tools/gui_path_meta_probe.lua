-- Read-only helper for inspecting a stock GUI object that has no stable id.
--
-- Usage from the in-game console:
--   TPF2MP_GUI_META_ID = "lineManager.newLine"
--   TPF2MP_GUI_META_PATH = { 1, 0, 0, 2, 0, 1, 0, 0, 0, 0, 0, 0, 2, 0, 0, 0, 0 }
--   dofile("C:/Users/Sepgi/Downloads/tf2mod/tools/gui_path_meta_probe.lua")
--
-- A path step traverses getLayout():getItem(index).  Stock layouts are also
-- allowed directly as path objects because several vanilla controls embed a
-- CBoxLayout where a component would normally appear.

local rootId = assert(rawget(_G, "TPF2MP_GUI_META_ID"), "TPF2MP_GUI_META_ID is required")
local path = assert(rawget(_G, "TPF2MP_GUI_META_PATH"), "TPF2MP_GUI_META_PATH is required")
local outputPath = (os.getenv("TEMP") or ".") .. "/tpf2mp-gui-meta.txt"

local function layoutOf(value)
  local ok, layout = pcall(function() return value:getLayout() end)
  if ok and layout ~= nil then return layout end
  return value
end

local seed = nil
if rootId == "__gameUI__" then
  seed = assert(api.gui.util.getGameUI(), "stock game GUI root is unavailable")
else
  seed = assert(api.gui.util.getById(rootId), "stock GUI component is unavailable: " .. rootId)
end
local root = seed
for _ = 1, 32 do
  local ok, name = pcall(function() return root:getName() end)
  if ok and name == "Window" then break end
  local okParent, parent = pcall(function() return root:getParent() end)
  if not okParent or not parent or parent == root then break end
  root = parent
end

local value = root
for _, index in ipairs(path) do
  value = assert(layoutOf(value):getItem(index), "GUI path has no item " .. tostring(index))
end

local lines = {
  "rootId=" .. rootId,
  "path=" .. table.concat(path, "."),
  "value=" .. tostring(value),
}

local okMeta, meta = pcall(getmetatable, value)
if okMeta and meta ~= nil then
  local keys = {}
  for key in pairs(meta) do keys[#keys + 1] = tostring(key) end
  table.sort(keys)
  for _, key in ipairs(keys) do
    local ok, member = pcall(function() return meta[key] end)
    lines[#lines + 1] = key .. "=" .. (ok and tostring(member) or "<unreadable>")
  end
else
  lines[#lines + 1] = "metatable=<unavailable>"
end

local file = assert(io.open(outputPath, "wb"))
file:write(table.concat(lines, "\n"), "\n")
file:close()
print("TPF2MP GUI meta written", outputPath, #lines)
