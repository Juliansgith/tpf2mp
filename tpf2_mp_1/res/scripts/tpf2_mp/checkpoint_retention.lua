local util = require "tpf2_mp/util"
local M = {}

function M.prune(consensus, maximum)
  maximum = math.max(1, util.integer(maximum, 128))
  local finalized, protected = {}, {}
  local agreed = consensus.lastAgreed
  if type(agreed) == "table" then protected[tostring(agreed.boundarySeq)] = true end
  for key, record in pairs(consensus.byBoundary or {}) do
    if type(record) == "table" and record.status ~= "pending" then
      finalized[#finalized + 1] = {
        key = key, boundary = util.integer(record.boundarySeq, tonumber(key) or 0),
      }
    end
  end
  table.sort(finalized, function(left, right)
    if left.boundary ~= right.boundary then return left.boundary < right.boundary end
    return tostring(left.key) < tostring(right.key)
  end)
  local removed = 0
  for _, item in ipairs(finalized) do
    if #finalized - removed <= maximum then break end
    if not protected[tostring(item.key)] then
      consensus.byBoundary[item.key] = nil
      removed = removed + 1
    end
  end
  return removed
end

return M
