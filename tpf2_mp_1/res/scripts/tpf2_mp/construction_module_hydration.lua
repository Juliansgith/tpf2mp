local M = {}

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
-- hydrate engine-owned values from that named resource immediately before the
-- typed ConstructionEntity crosses back into native code.
function M.apply(params, gameApi)
  if type(params) ~= "table" or type(params.modules) ~= "table"
    or next(params.modules) == nil then return true end
  for slot, module in pairs(params.modules) do
    if type(module) ~= "table" or type(module.name) ~= "string" then
      return nil, "construction module payload is invalid at slot " .. tostring(slot)
    end
    local descriptor, descriptorError = resource(gameApi, module.name)
    if not descriptor then return nil, descriptorError end
    -- ModuleDesc normally exposes an empty MetadataMap when no metadata was
    -- declared. Keep an explicit portable map only as a compatibility fallback
    -- and never pass nil into the stock modulesutil.addCosts implementation.
    module.metadata = safeField(descriptor, "metadata") or module.metadata or {}
    local updateScript = safeField(descriptor, "updateScript")
    if updateScript ~= nil then module.updateScript = updateScript end
  end
  return true
end

return M
