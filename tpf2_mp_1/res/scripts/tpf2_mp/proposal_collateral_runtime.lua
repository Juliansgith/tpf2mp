local world = require "tpf2_mp/world"

local M = {}

function M.verifyRemoved(localInputs, worldApi)
  worldApi = worldApi or world
  for _, input in ipairs(type(localInputs) == "table" and localInputs or {}) do
    if input.kind == "construction" or input.kind == "asset" then
      local stillPresent = worldApi.entityExists(input.localId)
        and worldApi.kindOf(input.localId) == input.kind
      if stillPresent then
        return false, "collateral " .. input.kind
          .. " remained after topology replay: " .. tostring(input.cid)
      end
    end
  end
  return true
end

return M
