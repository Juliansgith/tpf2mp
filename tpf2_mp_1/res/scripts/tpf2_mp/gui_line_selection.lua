local M = {}

local CARRIER_FIELDS = {
  "line", "lineId", "lineEntity", "selectedLine", "targetLine",
  "entity", "entityId", "id",
}

function M.candidates(param, safeField)
  assert(type(safeField) == "function", "safe field reader is required")
  local result, seen = {}, {}
  local function add(value)
    local id = tonumber(value)
    if id and id >= 0 and id == math.floor(id) and not seen[id] then
      seen[id] = true
      result[#result + 1] = id
    end
  end
  local function addCarrier(value)
    local kind = type(value)
    if kind == "number" or kind == "string" then
      add(value)
    elseif kind == "table" or kind == "userdata" then
      for _, field in ipairs({ "line", "lineId", "lineEntity", "entity", "entityId", "id" }) do
        add(safeField(value, field))
      end
    end
  end
  local kind = type(param)
  if kind == "number" or kind == "string" then
    add(param)
  elseif kind == "table" or kind == "userdata" then
    for _, field in ipairs(CARRIER_FIELDS) do addCarrier(safeField(param, field)) end
  end
  return result
end

return M
