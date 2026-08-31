local M = {}

local function existingEndpoint(reference)
  return type(reference) == "table"
    and type(reference.cid) == "string" and reference.cid ~= ""
end

-- A construction helper receives only filename, parameters and transform. It
-- cannot reproduce this captured relation to a pre-existing road node. Keep
-- the predicate structural so stock variants and data-driven mod resources
-- receive the same treatment without a filename allowlist.
function M.hasExistingStreetEndpoint(transaction, construction)
  if type(transaction) ~= "table" or type(construction) ~= "table"
    or construction.mode ~= "build" then return false end
  for _, edge in ipairs(type(transaction.edges) == "table" and transaction.edges or {}) do
    if edge.carrier == "street"
      and (existingEndpoint(edge.node0) or existingEndpoint(edge.node1)) then
      return true
    end
  end
  return false
end

local function streetOnly(transaction)
  local edges = type(transaction) == "table" and transaction.edges or nil
  if type(edges) ~= "table" or #edges < 1 then return false end
  for _, edge in ipairs(edges) do
    if type(edge) ~= "table" or edge.carrier ~= "street" then return false end
  end
  return true
end

-- Typed exact replay is safe for the stock STREET_DEPOT family (road and
-- tram). Any depot graph containing track remains on the separately guarded
-- path because Build 35924's stock rail-depot selection UI crashes on typed
-- rail-depot output.
function M.isConnectedStreetDepot(transaction, construction)
  return type(construction) == "table" and construction.kind == "depot"
    and streetOnly(transaction)
    and M.hasExistingStreetEndpoint(transaction, construction)
end

return M
