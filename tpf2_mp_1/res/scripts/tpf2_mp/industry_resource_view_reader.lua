local hash = require "tpf2_mp/hash"
local json = require "tpf2_mp/json"
local util = require "tpf2_mp/util"

local M = {}

local function sortedNumericKeys(value)
  local keys = {}
  for key in pairs(value or {}) do
    if type(key) ~= "number" or key < 1 or key ~= math.floor(key) then
      return nil, "expected a one-based sequence"
    end
    keys[#keys + 1] = key
  end
  table.sort(keys)
  for index, key in ipairs(keys) do
    if key ~= index then return nil, "sequence contains a gap" end
  end
  return keys
end

local function projectValue(value, depth, budget)
  local kind = type(value)
  if value == nil or kind == "boolean" or kind == "string" then return value end
  if kind == "number" then
    if value ~= value or value == math.huge or value == -math.huge then
      return nil, "parameter contains a non-finite number"
    end
    return value
  end
  if kind ~= "table" then return nil, "parameter contains opaque " .. kind end
  if depth <= 0 then return nil, "parameter nesting exceeds the authority limit" end
  local result, count = {}, 0
  for key, nested in pairs(value) do
    if type(key) ~= "string" and type(key) ~= "number" then
      return nil, "parameter contains an unsupported key type"
    end
    count, budget.count = count + 1, budget.count + 1
    if count > 128 or budget.count > 512 then
      return nil, "parameter projection exceeds the authority limit"
    end
    local projected, err = projectValue(nested, depth - 1, budget)
    if err then return nil, err end
    result[key] = projected
  end
  return result
end

local function ensureResource(registry, fileName)
  local resource = registry.resources[fileName]
  if not resource then
    resource = { parameters = {}, variants = {}, declarationAmbiguous = false }
    registry.resources[fileName] = resource
  end
  return resource
end

function M.fromDigestView(facts, view)
  if type(view) ~= "table" or tonumber(view.schemaVersion) ~= facts.SCHEMA_VERSION
      or view.overflow == true or type(view.resources) ~= "table" then
    return nil, "industry registry view is invalid or overflowed"
  end
  local resourceKeys, sequenceError = sortedNumericKeys(view.resources)
  if not resourceKeys then return nil, "industry resources: " .. tostring(sequenceError) end
  if #resourceKeys > facts.MAX_RESOURCES then return nil, "industry resource registry overflow" end
  local registry, previousName = facts.newRegistry(), nil
  for _, resourceIndex in ipairs(resourceKeys) do
    local source = view.resources[resourceIndex]
    if type(source) ~= "table" then return nil, "industry resource entry is invalid" end
    if type(source.declarationAmbiguous) ~= "boolean" then
      return nil, "industry resource ambiguity flag is invalid"
    end
    local fileName = facts.canonicalResourceName(source.fileName)
    if fileName == "" or fileName ~= tostring(source.fileName or "")
        or (previousName and fileName <= previousName) then
      return nil, "industry resources are not uniquely and canonically ordered"
    end
    previousName = fileName
    local declarations = source.parameters
    local declarationKeys = type(declarations) == "table"
      and sortedNumericKeys(declarations) or nil
    if not declarationKeys or #declarationKeys > 32 then
      return nil, "industry parameter declarations are invalid"
    end
    local normalizedDeclarations, declarationNames = {}, {}
    for _, declarationIndex in ipairs(declarationKeys) do
      local declaration = declarations[declarationIndex]
      local key = type(declaration) == "table" and declaration.key or nil
      local valueCount = declaration and tonumber(declaration.valueCount) or nil
      local defaultIndex = declaration and tonumber(declaration.defaultIndex) or nil
      if type(key) ~= "string" or key == "" or declarationNames[key]
          or not valueCount or valueCount < 1 or valueCount ~= math.floor(valueCount)
          or not defaultIndex or defaultIndex < 0 or defaultIndex ~= math.floor(defaultIndex)
          or defaultIndex >= valueCount then
        return nil, "industry parameter declaration is invalid"
      end
      declarationNames[key] = true
      normalizedDeclarations[#normalizedDeclarations + 1] = {
        key = key, valueCount = valueCount, defaultIndex = defaultIndex,
      }
    end
    table.sort(normalizedDeclarations, function(a, b) return a.key < b.key end)
    if hash.value(normalizedDeclarations) ~= hash.value(declarations) then
      return nil, "industry parameter declarations are not canonical"
    end
    local resource = assert(ensureResource(registry, fileName))
    resource.parameters = normalizedDeclarations
    resource.declared = true
    resource.declarationAmbiguous = source.declarationAmbiguous == true
    local variantKeys = type(source.variants) == "table"
      and sortedNumericKeys(source.variants) or nil
    if not variantKeys or #variantKeys > facts.MAX_VARIANTS_PER_RESOURCE then
      return nil, "industry resource variants are invalid"
    end
    local previousParameterKey = nil
    for _, variantIndex in ipairs(variantKeys) do
      local variant = source.variants[variantIndex]
      if type(variant) ~= "table" or type(variant.params) ~= "table"
          or type(variant.recipeDigests) ~= "table"
          or type(variant.ambiguous) ~= "boolean" then
        return nil, "industry variant is invalid"
      end
      local projected, projectionError = projectValue(variant.params, 6, { count = 0 })
      if not projected then return nil, projectionError end
      local parameterKey = json.encode(projected)
      if previousParameterKey and parameterKey <= previousParameterKey then
        return nil, "industry variants are not uniquely and canonically ordered"
      end
      previousParameterKey = parameterKey
      local digestKeys = sortedNumericKeys(variant.recipeDigests)
      local digests, seenDigests = {}, {}
      if not digestKeys or #digestKeys == 0 then return nil, "industry recipe digest list is invalid" end
      for _, digestIndex in ipairs(digestKeys) do
        local digest = variant.recipeDigests[digestIndex]
        if type(digest) ~= "string" or not digest:match("^[0-9a-f][0-9a-f]+$")
            or #digest ~= 8 or seenDigests[digest] then
          return nil, "industry recipe digest is invalid"
        end
        seenDigests[digest] = true
        digests[#digests + 1] = digest
      end
      table.sort(digests)
      if hash.value(digests) ~= hash.value(variant.recipeDigests) then
        return nil, "industry recipe digests are not canonical"
      end
      local ambiguous = variant.ambiguous == true
      local recipe = variant.recipe
      if ambiguous then
        if #digests < 2 or type(recipe) ~= "table" or next(recipe) ~= nil then
          return nil, "ambiguous industry variant retained a recipe"
        end
        recipe = {}
      else
        if #digests ~= 1 or type(recipe) ~= "table"
            or facts.canonicalResourceName(recipe.resource) ~= fileName
            or hash.value(recipe.params or {}) ~= hash.value(projected) then
          return nil, "industry recipe identity is invalid"
        end
        local recipeCore = util.deepCopy(recipe)
        local recipeDigest = recipeCore.digest
        recipeCore.digest = nil
        if recipeDigest ~= digests[1] or hash.value(recipeCore) ~= recipeDigest then
          return nil, "industry recipe content digest is invalid"
        end
        local updateResult = { stocks = {}, rule = { input = {}, output = {}, capacity = recipe.capacity } }
        local stockKeys = type(recipe.stocks) == "table" and sortedNumericKeys(recipe.stocks) or nil
        local inputKeys = type(recipe.inputs) == "table" and sortedNumericKeys(recipe.inputs) or nil
        local outputKeys = type(recipe.outputs) == "table" and sortedNumericKeys(recipe.outputs) or nil
        if not stockKeys or not inputKeys or not outputKeys then
          return nil, "industry recipe sequences are invalid"
        end
        for _, stockIndex in ipairs(stockKeys) do
          local stock = recipe.stocks[stockIndex]
          if type(stock) ~= "table" or stock.index ~= stockIndex - 1
              or type(stock.cargoType) ~= "string" or stock.cargoType == ""
              or type(stock.stockType) ~= "string" then
            return nil, "industry recipe stock is invalid"
          end
          updateResult.stocks[stockIndex] = {
            cargoType = stock.cargoType,
            type = stock.stockType,
            moreCapacity = stock.moreCapacity,
          }
        end
        for _, alternativeIndex in ipairs(inputKeys) do
          local alternative = recipe.inputs[alternativeIndex]
          local requirementKeys = type(alternative) == "table"
            and sortedNumericKeys(alternative) or nil
          if not requirementKeys then return nil, "industry recipe input is invalid" end
          local amounts = {}
          for stockIndex = 1, #stockKeys do amounts[stockIndex] = 0 end
          for _, requirementIndex in ipairs(requirementKeys) do
            local requirement = alternative[requirementIndex]
            local stockIndex = type(requirement) == "table"
              and tonumber(requirement.stockIndex) or nil
            if not stockIndex or stockIndex < 0 or stockIndex ~= math.floor(stockIndex)
                or not updateResult.stocks[stockIndex + 1]
                or requirement.cargoType ~= updateResult.stocks[stockIndex + 1].cargoType
                or type(requirement.amount) ~= "number" or requirement.amount < 1
                or requirement.amount ~= math.floor(requirement.amount) then
              return nil, "industry recipe input requirement is invalid"
            end
            amounts[stockIndex + 1] = requirement.amount
          end
          updateResult.rule.input[alternativeIndex] = amounts
        end
        for _, outputIndex in ipairs(outputKeys) do
          local output = recipe.outputs[outputIndex]
          if type(output) ~= "table" or type(output.cargoType) ~= "string"
              or output.cargoType == "" or type(output.amount) ~= "number"
              or output.amount < 1 or output.amount ~= math.floor(output.amount)
              or updateResult.rule.output[output.cargoType] ~= nil then
            return nil, "industry recipe output is invalid"
          end
          updateResult.rule.output[output.cargoType] = output.amount
        end
        local rebuilt, rebuildError = facts.normalize(
          fileName, projected, updateResult, normalizedDeclarations)
        if not rebuilt or hash.value(rebuilt) ~= hash.value(recipe) then
          return nil, "industry recipe normalization failed: " .. tostring(rebuildError or "mismatch")
        end
        recipe = rebuilt
      end
      resource.variants[parameterKey] = {
        params = projected,
        recipe = recipe,
        recipeDigests = digests,
        ambiguous = ambiguous,
      }
    end
  end
  return registry
end

return M
