local util = require "tpf2_mp/util"

local M = {}

local function reasonCode(message)
  local value = string.lower(tostring(message or ""))
  if value:find("cargo service", 1, true) then return "cargo-authority-unavailable" end
  if value:find("mixed passenger/cargo", 1, true) then
    return "mixed-transport-authority-unavailable"
  end
  if value:find("line stop mode", 1, true) then return "line-stop-mode-unreadable" end
  if value:find("two distinct towns", 1, true) then return "unsupported-corridor" end
  return "service-facts-unavailable"
end

-- A line can become unsupported after it was already registered (for example
-- an old save whose freight service was previously mistaken for passengers).
-- Carry an ordered disabled copy of the old service so every peer retires its
-- allocation and passenger ledger together. The reason is a portable code;
-- native IDs and machine-specific read diagnostics never enter the wire.
function M.disabledAction(state, lineCid, companyCid, message)
  local economy = state and state.economy or {}
  local existing = economy.services and economy.services[lineCid] or nil
  if type(existing) ~= "table" or existing.companyCid ~= companyCid then return nil end
  local market = economy.markets and economy.markets[existing.marketCid] or nil
  if type(market) ~= "table" then return nil end
  local service = util.deepCopy(existing)
  service.enabled = false
  service.metadata = type(service.metadata) == "table" and service.metadata or {}
  service.metadata.registrationQuarantine = reasonCode(message)
  return {
    type = "line.register", lineCid = lineCid, companyCid = companyCid,
    market = util.deepCopy(market), service = service, vehicleCosts = {},
  }
end

return M
