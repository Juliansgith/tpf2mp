local M = {
  MAX_DEPTH = 8,
  MAX_VISITED = 64,
}

local WRAPPERS = { "proposal", "data", "context", "params", "streetProposal" }
local TOPOLOGY_FIELDS = {
  "nodesToAdd", "addedNodes", "edgesToAdd", "addedSegments",
  "nodesToRemove", "removedNodes", "edgesToRemove", "removedSegments",
  "edgeObjectsToAdd", "edgeObjectsToRemove",
}

local function safeField(value, key)
  local valueType = type(value)
  if valueType ~= "table" and valueType ~= "userdata" then return nil end
  local ok, result = pcall(function() return value[key] end)
  if not ok then return nil end
  return result
end

local function traversable(value)
  return type(value) == "table" or type(value) == "userdata"
end

function M.hasTopology(value)
  if not traversable(value) then return false end
  for _, field in ipairs(TOPOLOGY_FIELDS) do
    if traversable(safeField(value, field)) then return true end
  end
  return false
end

-- Live builders wrap SimpleStreetProposal differently (and sometimes retain
-- an older hover alias beside the apply payload). Walk only known envelope
-- fields, choose the deepest unique topology, and fail closed when two peers
-- could make an arbitrary choice. The hard limits and identity set also make
-- cyclic or adversarial mod tables safe to inspect on a GUI frame.
function M.select(root)
  if not traversable(root) then return nil, "proposal wrapper root is unavailable" end
  local seen, visited = {}, 0
  local best, bestDepth, bestPath, ambiguous
  local exceededDepth, exceededCount = false, false

  local function walk(value, depth, path)
    if exceededCount or not traversable(value) or seen[value] then return end
    seen[value] = true
    visited = visited + 1
    if visited > M.MAX_VISITED then exceededCount = true; return end

    if M.hasTopology(value) then
      if best == nil or depth > bestDepth then
        best, bestDepth, bestPath, ambiguous = value, depth, path, nil
      elseif depth == bestDepth and value ~= best then
        ambiguous = { bestPath, path }
      end
    end

    for _, name in ipairs(WRAPPERS) do
      local nested = safeField(value, name)
      if traversable(nested) and not seen[nested] then
        if depth >= M.MAX_DEPTH then
          exceededDepth = true
        else
          walk(nested, depth + 1, path .. "." .. name)
        end
      end
    end
  end

  walk(root, 0, "root")
  if exceededCount then
    return nil, "proposal wrapper traversal exceeds the node limit"
  end
  if exceededDepth then
    return nil, "proposal wrapper traversal exceeds the depth limit"
  end
  if ambiguous then
    return nil, "proposal contains ambiguous topology wrappers at "
      .. ambiguous[1] .. " and " .. ambiguous[2]
  end
  return best or root, nil, {
    path = bestPath or "root",
    depth = bestDepth or 0,
    visited = visited,
    fallback = best == nil,
  }
end

return M
