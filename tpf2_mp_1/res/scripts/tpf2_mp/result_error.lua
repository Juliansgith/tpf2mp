local M = {}

local fields = { "error", "errorCode", "detail", "message", "reason" }

local function text(value, depth)
  local kind = type(value)
  if kind == "string" or kind == "number" or kind == "boolean" then
    local rendered = tostring(value)
    if rendered ~= "" then return rendered end
  elseif kind == "table" and depth < 2 then
    for _, field in ipairs(fields) do
      local rendered = text(value[field], depth + 1)
      if rendered then return rendered end
    end
  end
  return nil
end

function M.text(value)
  return text(value, 0) or "action failed without error detail"
end

return M
