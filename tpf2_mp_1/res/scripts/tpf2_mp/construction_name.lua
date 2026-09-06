-- Native names are semantic input: compound stations use them to initialise
-- their child depot NAME component. An empty replay name can crash hangar UI.
local M = {}
function M.valid(value)
  return type(value) == "string" and #value > 0 and #value <= 240
    and not value:find("[%z\1-\31]")
end
function M.capture(value, field)
  local name = value and field(value, "name")
  if name == nil or name == "" then return nil end
  if not M.valid(name) then return nil, "construction name is invalid" end
  return name
end
return M
