local util = require "tpf2_mp/util"
local M = {}

-- Expand an existing-node snap BEFORE PREPARE. The helper cannot replace its
-- own entrance; its external node must become the junction instead. Putting
-- every incident road in the authored transaction lets ordinary ownership,
-- identity, removal and checkpoint checks cover the entire replacement.
function M.target(transaction)
  local construction = transaction.constructions and transaction.constructions[1]
  if not construction or #transaction.constructions ~= 1 or construction.kind ~= "depot"
    or construction.mode ~= "build" or #transaction.nodes ~= 1 or #transaction.edges ~= 1
    or #transaction.remove.nodes ~= 0 or #transaction.remove.edges ~= 0 then return nil end
  local edge = transaction.edges[1]
  if edge.carrier ~= "street" then return nil end
  local slot = transaction.nodes[1].slot
  if edge.node0.slot == slot and edge.node1.cid then return edge.node1.cid end
  if edge.node1.slot == slot and edge.node0.cid then return edge.node0.cid end
end

function M.expand(transaction, junction, codec)
  local cid = M.target(transaction)
  if not cid then return transaction end
  if type(junction) ~= "table" or junction.cid ~= cid or not junction.position
    or type(junction.branches) ~= "table" or #junction.branches < 1
    or #junction.branches > 16 then return nil, "depot junction neighbourhood is unavailable" end
  local result = util.deepCopy(transaction)
  result.nodes[2] = { slot = "node:2", position = util.deepCopy(junction.position) }
  local entrance = result.edges[1]
  if entrance.node0.cid == cid then entrance.node0 = { slot = "node:2" }
  else entrance.node1 = { slot = "node:2" } end
  local branches, seen = util.deepCopy(junction.branches), {}
  table.sort(branches, function(a, b) return tostring(a.cid) < tostring(b.cid) end)
  for _, branch in ipairs(branches) do
    local edge = branch.edge
    if type(branch.cid) ~= "string" or not branch.cid:match("^edge:") or seen[branch.cid]
      or type(edge) ~= "table" or edge.carrier ~= "street" then
      return nil, "depot junction has invalid or duplicate road branches"
    end
    seen[branch.cid] = true
    local first, second = edge.node0.cid == cid, edge.node1.cid == cid
    if first == second then return nil, "depot junction branch is detached or looping" end
    if first then edge.node0 = { slot = "node:2" }
    else edge.node1 = { slot = "node:2" } end
    edge.slot = "edge:" .. tostring(#result.edges + 1)
    result.edges[#result.edges + 1] = edge
    result.remove.edges[#result.remove.edges + 1] = branch.cid
  end
  result.remove.nodes = { cid }
  result.digest = codec.digest(result)
  result.transactionId = "proposal:" .. result.digest
  local valid, err = codec.validatePortable(result)
  if not valid then return nil, err end
  return result
end

return M
