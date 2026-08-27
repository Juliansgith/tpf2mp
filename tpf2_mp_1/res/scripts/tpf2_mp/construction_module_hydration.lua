local M = {}

local function portableCopy(value, label, depth, seen, budget)
  depth, seen, budget = depth or 0, seen or {}, budget or { remaining = 512 }
  if depth > 8 then return nil, tostring(label) .. " exceeds the resource-data depth limit" end
  if budget.remaining <= 0 then return nil, tostring(label) .. " exceeds the resource-data value limit" end
  budget.remaining = budget.remaining - 1
  local valueType = type(value)
  if valueType == "nil" or valueType == "boolean" or valueType == "string" then return value end
  if valueType == "number" then
    if value ~= value or value == math.huge or value == -math.huge then
      return nil, tostring(label) .. " contains a non-finite number"
    end
    return value
  end
  -- Never forward an engine-owned userdata/table member by reference.  The
  -- Build 35924 command converter recursively calls lua_next over this graph;
  -- session mp-5e5d4c732aae691e proved that a resource-owned nested value can
  -- become an access violation instead of a catchable Lua error.
  if valueType ~= "table" then
    return nil, tostring(label) .. " contains non-portable " .. valueType
  end
  if seen[value] then return nil, tostring(label) .. " contains a cycle" end
  seen[value] = true
  local copy = {}
  for key, nested in pairs(value) do
    local keyType = type(key)
    if keyType ~= "string" and keyType ~= "number" and keyType ~= "boolean" then
      seen[value] = nil
      return nil, tostring(label) .. " contains a non-portable key"
    end
    local copied, copyError = portableCopy(
      nested, tostring(label) .. "." .. tostring(key), depth + 1, seen, budget)
    if copyError then seen[value] = nil; return nil, copyError end
    copy[key] = copied
  end
  seen[value] = nil
  return copy
end

local function safeField(value, key)
  local valueType = type(value)
  if valueType ~= "table" and valueType ~= "userdata" then return nil end
  local ok, nested = pcall(function() return value[key] end)
  return ok and nested or nil
end

local function resource(gameApi, name)
  local repository = gameApi and gameApi.res and gameApi.res.moduleRep or nil
  if not (repository and repository.find ~= nil and repository.get ~= nil) then
    return nil, "construction module resource API is unavailable"
  end
  local findOk, rawIndex = pcall(repository.find, name)
  local index = findOk and tonumber(rawIndex) or nil
  if not index or index < 0 or index ~= math.floor(index) then
    return nil, "construction module resource is unavailable locally: " .. tostring(name)
  end
  local getOk, value = pcall(repository.get, index)
  if not getOk or (type(value) ~= "table" and type(value) ~= "userdata") then
    return nil, "construction module resource data is unavailable locally: " .. tostring(name)
  end
  return value
end

-- Module metadata and dynamic update scripts are immutable resource facts.
-- Canonical proposals carry the content-attested module name and variant;
-- resolve those facts locally, but cross the native boundary only with a fresh
-- pointer-free Lua graph.  If a resource exposes opaque data, fail here so the
-- caller can select the helper path instead of risking a native converter
-- crash.
function M.apply(params, gameApi)
  if type(params) ~= "table" or type(params.modules) ~= "table"
    or next(params.modules) == nil then return true end
  for slot, module in pairs(params.modules) do
    if type(module) ~= "table" or type(module.name) ~= "string" then
      return nil, "construction module payload is invalid at slot " .. tostring(slot)
    end
    local descriptor, descriptorError = resource(gameApi, module.name)
    if not descriptor then return nil, descriptorError end
    local capturedMetadata, capturedError = portableCopy(
      module.metadata or {}, "captured construction module metadata at slot " .. tostring(slot))
    if not capturedMetadata then return nil, capturedError end
    local metadata = capturedMetadata
    if next(metadata) == nil then
      -- Only the exact native `<userdata>` sentinel is reduced to an empty map
      -- by the codec.  Resolve that missing fact locally.  A real captured map
      -- is instance data and must not be replaced by a generic descriptor.
      local resourceMetadata = safeField(descriptor, "metadata")
      if resourceMetadata ~= nil then
        local metadataError
        metadata, metadataError = portableCopy(
          resourceMetadata, "construction module metadata at slot " .. tostring(slot))
        if not metadata then return nil, metadataError end
      end
    end
    module.metadata = metadata
    local updateScript = safeField(descriptor, "updateScript")
    if updateScript ~= nil then
      local fileName = safeField(updateScript, "fileName")
      if fileName ~= nil and fileName ~= "" then
        if type(fileName) ~= "string" then
          return nil, "construction module update script name is invalid at slot " .. tostring(slot)
        end
        local scriptParams, scriptError = portableCopy(
          safeField(updateScript, "params") or {},
          "construction module update script params at slot " .. tostring(slot))
        if not scriptParams then return nil, scriptError end
        module.updateScript = { fileName = fileName, params = scriptParams }
      end
    end
  end
  return true
end

return M
