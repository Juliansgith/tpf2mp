-- Bounded Transport Fever 2 console helper for acting on a discovered stock
-- GUI control.  This is intended for exact-process automation after a
-- read-only gui_tree_probe.lua capture has pinned the path.
--
-- Required globals:
--   TPF2MP_GUI_ACTION_ID     stable component id or "__gameUI__"
--   TPF2MP_GUI_ACTION_PATH   zero-based layout item indices
--   TPF2MP_GUI_ACTION        "setText", "selectAll", or "click"
-- Optional:
--   TPF2MP_GUI_ACTION_VALUE  value for setText

local rootId = assert(rawget(_G, "TPF2MP_GUI_ACTION_ID"), "GUI action id is required")
local path = assert(rawget(_G, "TPF2MP_GUI_ACTION_PATH"), "GUI action path is required")
local action = assert(rawget(_G, "TPF2MP_GUI_ACTION"), "GUI action is required")
local value = rawget(_G, "TPF2MP_GUI_ACTION_VALUE")

local function layoutOf(component)
  local ok, layout = pcall(function() return component:getLayout() end)
  if ok and layout ~= nil then return layout end
  return component
end

local component = nil
if rootId == "__gameUI__" then
  component = assert(api.gui.util.getGameUI(), "stock game GUI root is unavailable")
else
  component = assert(api.gui.util.getById(rootId), "stock GUI component is unavailable: " .. rootId)
end

-- Match gui_tree_probe.lua's top-ancestor root so a recorded path resolves to
-- the same object even for the un-id'd stock SavegameDialog.
for _ = 1, 32 do
  local okParent, parent = pcall(function() return component:getParent() end)
  if not okParent or not parent or parent == component then break end
  component = parent
end

for _, index in ipairs(path) do
  component = assert(layoutOf(component):getItem(index),
    "GUI action path has no item " .. tostring(index))
end

if action == "setText" then
  assert(type(value) == "string", "setText requires a string value")
  -- Build 35924 exposes TextInputField::setText(text, notify).  Notify the
  -- owning SavegameDialog so its model and Save-button validation receive the
  -- exact value; changing only the rendered field leaves the dialog's model
  -- empty and click() becomes a harmless no-op.
  component:setText(value, true)
elseif action == "selectAll" then
  component:selectAll()
elseif action == "click" then
  component:click()
else
  error("unsupported GUI action: " .. tostring(action))
end

print("TPF2MP GUI action completed", rootId, table.concat(path, "."), action)
