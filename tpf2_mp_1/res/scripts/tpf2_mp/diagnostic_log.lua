local json = require "tpf2_mp/json"

local M = {}

function M.new(stateVersion)
  return function(event, values)
    local record = { event = tostring(event), stateVersion = stateVersion }
    for key, value in pairs(values or {}) do
      local kind = type(value)
      if kind == "string" or kind == "number" or kind == "boolean" then record[key] = value end
    end
    local ok, encoded = pcall(json.encode, record)
    print("[TPF2MP] " .. (ok and encoded or tostring(event)))
  end
end

return M
