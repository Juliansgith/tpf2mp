local util = require "tpf2_mp/util"

local M = {}

function M.append(lines, snapshot)
  local services = snapshot.economyPresentation
    and snapshot.economyPresentation.services or {}
  for _, lineCid in ipairs(util.sortedKeys(services)) do
    local service = services[lineCid]
    if service.enabled == false and service.stationAccessSchema == 1 then
      local reached = service.endpointReachableBuildings or {}
      local ready = service.endpointAccessReady or {}
      lines[#lines + 1] = string.format(
        "NO PASSENGER ACCESS: %s is economy-disabled | endpoint buildings %d/%d | catchment reads %s/%s | trains still cost upkeep",
        tostring(service.name or lineCid),
        tonumber(reached[1]) or 0, tonumber(reached[2]) or 0,
        ready[1] == true and "ready" or "unavailable",
        ready[2] == true and "ready" or "unavailable")
    end
  end
end

return M
