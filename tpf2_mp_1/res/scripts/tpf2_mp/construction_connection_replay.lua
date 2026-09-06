local M = {}

local function existingEndpoint(reference)
  return type(reference) == "table"
    and type(reference.cid) == "string" and reference.cid ~= ""
end

-- A construction helper receives only filename, parameters and transform. It
-- cannot reproduce this captured relation to a pre-existing road node. Keep
-- the predicate structural so stock variants and data-driven mod resources
-- receive the same treatment without a filename allowlist.
function M.hasExistingCarrierEndpoint(transaction, construction)
  if type(transaction) ~= "table" or type(construction) ~= "table"
    or construction.mode ~= "build" then return false end
  for _, edge in ipairs(type(transaction.edges) == "table" and transaction.edges or {}) do
    if (edge.carrier == "street" or edge.carrier == "track")
      and (existingEndpoint(edge.node0) or existingEndpoint(edge.node1)) then
      return true
    end
  end
  return false
end

local function singleCarrier(transaction)
  local edges = type(transaction) == "table" and transaction.edges or nil
  if type(edges) ~= "table" or #edges < 1 then return nil end
  local carrier
  for _, edge in ipairs(edges) do
    if type(edge) ~= "table" or (edge.carrier ~= "street" and edge.carrier ~= "track") then
      return nil
    end
    carrier = carrier or edge.carrier
    if edge.carrier ~= carrier then return nil end
  end
  return carrier
end

-- A connected road, tram or rail depot needs two native stages. Its construction root
-- must come from buildConstruction (typed depot roots crash Build 35924's
-- stock context helper), while its captured connection graph cannot be
-- reproduced by that transform-only helper. The repair stage is deliberately
-- classified from graph shape rather than a stock/mod filename allowlist.
function M.connectedDepotCarrier(transaction, construction)
  local carrier = singleCarrier(transaction)
  if type(construction) ~= "table" or construction.kind ~= "depot"
    or not carrier or not M.hasExistingCarrierEndpoint(transaction, construction) then
    return nil
  end
  return carrier
end

function M.isConnectedDepot(transaction, construction)
  return M.connectedDepotCarrier(transaction, construction) ~= nil
end

return M
