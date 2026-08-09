local hash = require "tpf2_mp/hash"
local util = require "tpf2_mp/util"

local M = {}

local function valid(facts, registry)
  return type(registry) == "table"
    and tonumber(registry.schemaVersion) == facts.SCHEMA_VERSION
    and type(registry.resources) == "table"
end

local function ensureResource(facts, registry, fileName)
  local resource = registry.resources[fileName]
  if resource then return resource end
  if #util.sortedKeys(registry.resources) >= facts.MAX_RESOURCES then
    registry.overflow = true
    return nil, "industry resource registry overflow"
  end
  resource = { parameters = {}, variants = {}, declarationAmbiguous = false }
  registry.resources[fileName] = resource
  return resource
end

local function mergeSet(target, source)
  for key, value in pairs(source or {}) do if value then target[key] = true end end
end

local function mergeDiagnostics(target, source)
  target.diagnostics, source = target.diagnostics or {}, source or {}
  for _, field in ipairs({
    "captureCount", "loadConstructionCount", "industryConstructionCount",
  }) do
    target.diagnostics[field] = math.max(
      tonumber(target.diagnostics[field]) or 0, tonumber(source[field]) or 0)
  end
  target.diagnostics.failures = target.diagnostics.failures or {}
  target.diagnostics.standardMisses = target.diagnostics.standardMisses or {}
  target.diagnostics.typeCounts = target.diagnostics.typeCounts or {}
  mergeSet(target.diagnostics.failures, source.failures)
  mergeSet(target.diagnostics.standardMisses, source.standardMisses)
  for kind, count in pairs(source.typeCounts or {}) do
    target.diagnostics.typeCounts[kind] = math.max(
      tonumber(target.diagnostics.typeCounts[kind]) or 0, tonumber(count) or 0)
  end
end

function M.merge(facts, target, source)
  if not valid(facts, source) then return nil, "source industry registry is invalid" end
  if target == nil then target = facts.newRegistry() end
  if not valid(facts, target) then return nil, "target industry registry is invalid" end
  target.overflow = target.overflow == true or source.overflow == true
  for _, fileName in ipairs(util.sortedKeys(source.resources)) do
    local sourceResource = source.resources[fileName]
    local targetResource, resourceError = ensureResource(facts, target, fileName)
    if not targetResource then return nil, resourceError end
    local sourceParameters = util.deepCopy(sourceResource.parameters or {})
    if targetResource.declared then
      if hash.value(targetResource.parameters or {}) ~= hash.value(sourceParameters) then
        targetResource.declarationAmbiguous, targetResource.parameters = true, {}
      end
    else
      targetResource.parameters = sourceParameters
      targetResource.declared = sourceResource.declared == true
    end
    if sourceResource.declarationAmbiguous then
      targetResource.declarationAmbiguous, targetResource.parameters = true, {}
    end
    targetResource.variants = targetResource.variants or {}
    for _, parameterKey in ipairs(util.sortedKeys(sourceResource.variants or {})) do
      local sourceVariant = sourceResource.variants[parameterKey]
      local targetVariant = targetResource.variants[parameterKey]
      if not targetVariant then
        if #util.sortedKeys(targetResource.variants) >= facts.MAX_VARIANTS_PER_RESOURCE then
          target.overflow = true
          return nil, "industry resource variant registry overflow"
        end
        targetResource.variants[parameterKey] = util.deepCopy(sourceVariant)
      else
        local digestSet = {}
        for _, digest in ipairs(targetVariant.recipeDigests or {}) do digestSet[digest] = true end
        for _, digest in ipairs(sourceVariant.recipeDigests or {}) do digestSet[digest] = true end
        targetVariant.recipeDigests = util.sortedKeys(digestSet)
        targetVariant.ambiguous = targetVariant.ambiguous == true
          or sourceVariant.ambiguous == true
          or hash.value(targetVariant.params or {}) ~= hash.value(sourceVariant.params or {})
          or #targetVariant.recipeDigests ~= 1
        if targetVariant.ambiguous then targetVariant.recipe = {}
        elseif type(targetVariant.recipe) ~= "table" then
          targetVariant.recipe = util.deepCopy(sourceVariant.recipe or {})
        end
      end
    end
  end
  mergeDiagnostics(target, source.diagnostics)
  return target
end

return M
