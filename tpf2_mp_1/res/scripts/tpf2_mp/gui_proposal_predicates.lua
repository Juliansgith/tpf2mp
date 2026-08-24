local M = {}

local CHANGE_FIELDS = {
  "edgesToAdd", "addedSegments", "edgesToRemove", "removedSegments",
  "nodesToAdd", "addedNodes", "nodesToRemove", "removedNodes",
  "constructionsToAdd", "toAdd", "constructionsToRemove", "toRemove",
  "__constructionAdditions", "__constructionRemovals",
  "edgeObjectsToAdd", "edgeObjectsToRemove",
}

local CONSTRUCTION_FIELDS = {
  "constructionsToAdd", "toAdd", "constructionsToRemove", "toRemove",
  "__constructionAdditions", "__constructionRemovals",
}

local WRAPPER_FIELDS = {
  "proposal", "streetProposal", "simpleProposal", "resultProposal",
  "proposalData", "resultProposalData", "data", "context",
}

local function nonEmpty(value)
  if type(value) ~= "table" then return false end
  for key, nested in pairs(value) do
    if key ~= "__type" and key ~= "__truncated" and nested ~= nil then return true end
  end
  return false
end

local function knownContainers(root)
  local result, seen = {}, {}
  local function add(value)
    if type(value) ~= "table" or seen[value] or #result >= 24 then return end
    seen[value] = true
    result[#result + 1] = value
  end
  add(root)
  local index = 1
  while index <= #result do
    local value = result[index]
    for _, field in ipairs(WRAPPER_FIELDS) do add(value[field]) end
    index = index + 1
  end
  return result
end

local function knownHas(root, fields)
  local recognised = false
  for _, container in ipairs(knownContainers(root)) do
    for _, field in ipairs(fields) do
      if container[field] ~= nil then recognised = true end
      if nonEmpty(container[field]) then return true, true end
    end
  end
  return false, recognised
end

-- This fallback exists for compatible/modded builders that wrap SimpleProposal
-- under an as-yet unknown key. Stock Build 35924 always exits through the
-- constant-size known-container path above, so a 320 m station's node/edge graph
-- is never recursively walked merely to answer "does this proposal change?".
local function fallbackHas(root, wanted)
  local seen, remaining = {}, 256
  local function walk(value, depth)
    if type(value) ~= "table" or seen[value] or depth > 8 or remaining <= 0 then return false end
    seen[value], remaining = true, remaining - 1
    for key, nested in pairs(value) do
      if wanted[tostring(key)] and nonEmpty(nested) then return true end
    end
    for key, nested in pairs(value) do
      if key ~= "__type" and key ~= "__truncated" and walk(nested, depth + 1) then return true end
    end
    return false
  end
  return walk(root, 0)
end

local function lookup(cache, root, fields, wanted)
  if type(root) ~= "table" then return false end
  local cached = cache[root]
  if cached ~= nil then return cached end
  local result, recognised = knownHas(root, fields)
  -- Stock and normally shaped mod proposals expose the vector fields even
  -- while they are empty. In that overwhelmingly common hover case, an empty
  -- answer is complete and the bounded compatibility walk is unnecessary.
  if not result and not recognised then result = fallbackHas(root, wanted) end
  cache[root] = result
  return result
end

function M.install(gui)
  local anyCache = setmetatable({}, { __mode = "k" })
  local constructionCache = setmetatable({}, { __mode = "k" })
  local anyWanted, constructionWanted = {}, {}
  for _, field in ipairs(CHANGE_FIELDS) do anyWanted[field] = true end
  for _, field in ipairs(CONSTRUCTION_FIELDS) do constructionWanted[field] = true end

  gui.proposalSnapshotHasChange = function(root)
    return lookup(anyCache, root, CHANGE_FIELDS, anyWanted)
  end
  gui.proposalSnapshotHasConstructionChange = function(root)
    return lookup(constructionCache, root, CONSTRUCTION_FIELDS, constructionWanted)
  end
end

return M
