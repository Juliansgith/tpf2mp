local hash = require "tpf2_mp/hash"
local json = require "tpf2_mp/json"
local util = require "tpf2_mp/util"

local M = {
  SCHEMA_VERSION = 1,
  MAX_RESOURCES = 1024,
  MAX_VARIANTS_PER_RESOURCE = 128,
}

local ignoredParameterKeys = {
  seed = true,
  state = true,
  year = true,
  upgrade = true,
}

function M.canonicalResourceName(fileName)
  local value = tostring(fileName or ""):gsub("\\", "/")
  value = value:gsub("^%./", "")
  value = value:gsub("^res/construction/", "")
  return value
end

local function nonNegativeInteger(value, label)
  local number = tonumber(value)
  if not number or number ~= number or number == math.huge or number == -math.huge
      or number < 0 or number ~= math.floor(number) then
    return nil, tostring(label) .. " must be a non-negative integer"
  end
  return number
end

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
  local result = {}
  local count = 0
  for key, nested in pairs(value) do
    if type(key) ~= "string" and type(key) ~= "number" then
      return nil, "parameter contains an unsupported key type"
    end
    count = count + 1
    budget.count = budget.count + 1
    if count > 128 or budget.count > 512 then
      return nil, "parameter projection exceeds the authority limit"
    end
    local projected, err = projectValue(nested, depth - 1, budget)
    if err then return nil, err end
    result[key] = projected
  end
  return result
end

-- Declared construction parameters are canonicalized to their numeric choice,
-- including omitted defaults. Engine context is excluded from identity: a
-- portable freight recipe must not change with seed/year/upgrade/state. The
-- eager probes and live wrapper feed several contexts through the same key, so
-- an observed violation becomes ambiguous and fails closed.
function M.parameterProjection(params, declarations)
  if type(params) ~= "table" then return nil, "industry parameters are not a table" end
  local source, declared = {}, {}
  for _, declaration in ipairs(declarations or {}) do
    local key = tostring(declaration.key or "")
    if key == "" then return nil, "industry parameter declaration has no key" end
    declared[key] = true
    local value = params[key]
    if value == nil then value = declaration.defaultIndex end
    local selection, selectionError = nonNegativeInteger(value,
      "industry parameter " .. key)
    if not selection then return nil, selectionError end
    if selection >= tonumber(declaration.valueCount or 0) then
      return nil, "industry parameter " .. key .. " is outside its declared choices"
    end
    source[key] = selection
  end
  for key, value in pairs(params) do
    local name = tostring(key)
    if not declared[name] and not ignoredParameterKeys[name] then source[key] = value end
  end
  return projectValue(source, 6, { count = 0 })
end

local function normalizeStocks(stocks)
  if type(stocks) ~= "table" then return nil, "industry stocks are not a table" end
  local keys, keysError = sortedNumericKeys(stocks)
  if not keys then return nil, "industry stocks: " .. keysError end
  local result = {}
  for _, index in ipairs(keys) do
    local stock = stocks[index]
    if type(stock) ~= "table" then return nil, "industry stock is not a table" end
    local cargoType = stock.cargoType
    if type(cargoType) ~= "string" or cargoType == "" then
      return nil, "industry stock has no portable cargo type"
    end
    local moreCapacity = stock.moreCapacity
    if moreCapacity ~= nil then
      moreCapacity, keysError = nonNegativeInteger(moreCapacity, "stock moreCapacity")
      if not moreCapacity then return nil, keysError end
    end
    result[index] = {
      index = index - 1,
      cargoType = cargoType,
      stockType = stock.type ~= nil and tostring(stock.type) or "",
      moreCapacity = moreCapacity or 0,
    }
  end
  return result
end

local function normalizeInputs(input, stocks)
  if type(input) ~= "table" then return nil, "industry input rule is not a table" end
  local alternativeKeys, keysError = sortedNumericKeys(input)
  if not alternativeKeys then return nil, "industry input rule: " .. keysError end
  local alternatives = {}
  for _, alternativeIndex in ipairs(alternativeKeys) do
    local raw = input[alternativeIndex]
    if type(raw) ~= "table" then return nil, "industry input alternative is not a table" end
    local amountKeys, amountError = sortedNumericKeys(raw)
    if not amountKeys then return nil, "industry input alternative: " .. amountError end
    if #amountKeys > #stocks then return nil, "industry input references an unknown stock" end
    local requirements = {}
    for _, stockIndex in ipairs(amountKeys) do
      local amount, amountFailure = nonNegativeInteger(raw[stockIndex], "input amount")
      if not amount then return nil, amountFailure end
      if amount > 0 then
        requirements[#requirements + 1] = {
          stockIndex = stockIndex - 1,
          cargoType = stocks[stockIndex].cargoType,
          amount = amount,
        }
      end
    end
    alternatives[#alternatives + 1] = requirements
  end
  if #alternatives == 0 then return nil, "industry has no input alternative" end
  return alternatives
end

local function normalizeOutputs(output)
  if type(output) ~= "table" then return nil, "industry output rule is not a table" end
  local result = {}
  for cargoType, rawAmount in pairs(output) do
    if type(cargoType) ~= "string" or cargoType == "" then
      return nil, "industry output has no portable cargo type"
    end
    local amount, err = nonNegativeInteger(rawAmount, "output amount")
    if not amount then return nil, err end
    if amount > 0 then result[#result + 1] = { cargoType = cargoType, amount = amount } end
  end
  table.sort(result, function(a, b) return a.cargoType < b.cargoType end)
  return result
end

function M.normalize(fileName, params, updateResult, declarations)
  fileName = M.canonicalResourceName(fileName)
  if fileName == "" then
    return nil, "industry resource name is required"
  end
  if type(updateResult) ~= "table" or type(updateResult.rule) ~= "table" then
    return nil, "industry update result has no rule"
  end
  local projected, projectionError = M.parameterProjection(params, declarations)
  if not projected then return nil, projectionError end
  local stocks, stocksError = normalizeStocks(updateResult.stocks or {})
  if not stocks then return nil, stocksError end
  local inputs, inputsError = normalizeInputs(updateResult.rule.input, stocks)
  if not inputs then return nil, inputsError end
  local outputs, outputsError = normalizeOutputs(updateResult.rule.output)
  if not outputs then return nil, outputsError end
  local hasFlow = #outputs > 0
  for _, alternative in ipairs(inputs) do
    if #alternative > 0 then hasFlow = true; break end
  end
  if not hasFlow then return nil, "industry has no positive input or output" end
  local capacity, capacityError = nonNegativeInteger(updateResult.rule.capacity, "industry capacity")
  if not capacity then return nil, capacityError end
  local recipe = {
    resource = fileName,
    params = projected,
    stocks = stocks,
    inputs = inputs,
    outputs = outputs,
    capacity = capacity,
  }
  recipe.digest = hash.value(recipe)
  return recipe
end

function M.newRegistry()
  return {
    schemaVersion = M.SCHEMA_VERSION,
    resources = {},
    overflow = false,
    diagnostics = { captureCount = 0, failures = {}, standardMisses = {} },
  }
end

local function validRegistry(registry)
  return type(registry) == "table"
    and tonumber(registry.schemaVersion) == M.SCHEMA_VERSION
    and type(registry.resources) == "table"
end

local function ensureResource(registry, fileName)
  fileName = M.canonicalResourceName(fileName)
  if fileName == "" then
    return nil, "industry resource name is required"
  end
  local resource = registry.resources[fileName]
  if resource then return resource end
  if #util.sortedKeys(registry.resources) >= M.MAX_RESOURCES then
    registry.overflow = true
    return nil, "industry resource registry overflow"
  end
  resource = { parameters = {}, variants = {}, declarationAmbiguous = false }
  registry.resources[fileName] = resource
  return resource
end

local function normalizeDeclarations(raw)
  if raw == nil then return {} end
  if type(raw) ~= "table" then return nil, "industry parameter declarations are not a table" end
  local keys, keysError = sortedNumericKeys(raw)
  if not keys then return nil, "industry parameter declarations: " .. keysError end
  if #keys > 32 then return nil, "industry declares too many parameters" end
  local result, seen = {}, {}
  for _, index in ipairs(keys) do
    local item = raw[index]
    if type(item) ~= "table" or type(item.key) ~= "string" or item.key == "" then
      return nil, "industry parameter declaration is invalid"
    end
    if seen[item.key] then return nil, "industry parameter key is duplicated" end
    seen[item.key] = true
    local valueKeys, valueError = sortedNumericKeys(item.values or {})
    if not valueKeys or #valueKeys == 0 then
      return nil, "industry parameter " .. item.key .. ": "
        .. tostring(valueError or "has no choices")
    end
    local defaultIndex, defaultError = nonNegativeInteger(
      item.defaultIndex == nil and 0 or item.defaultIndex,
      "industry parameter " .. item.key .. " defaultIndex")
    if not defaultIndex then return nil, defaultError end
    if defaultIndex >= #valueKeys then
      return nil, "industry parameter " .. item.key .. " default is outside its choices"
    end
    result[#result + 1] = {
      key = item.key,
      valueCount = #valueKeys,
      defaultIndex = defaultIndex,
    }
  end
  table.sort(result, function(a, b) return a.key < b.key end)
  return result
end

local recordFailure

function M.declare(registry, fileName, rawDeclarations)
  if not validRegistry(registry) then return false, "industry registry is invalid" end
  local resource, resourceError = ensureResource(registry, fileName)
  if not resource then return false, resourceError end
  local declarations, declarationError = normalizeDeclarations(rawDeclarations)
  if not declarations then
    recordFailure(registry, fileName, declarationError)
    return false, declarationError
  end
  if resource.declared then
    if hash.value(resource.parameters or {}) ~= hash.value(declarations) then
      resource.declarationAmbiguous = true
      -- An ambiguous declaration is never usable. Erase the order-dependent
      -- first value so parallel loader merge order cannot affect the digest.
      resource.parameters = {}
      recordFailure(registry, fileName, "conflicting parameter declarations")
      return false, "industry parameter declaration changed"
    end
    return not resource.declarationAmbiguous, util.deepCopy(resource.parameters)
  end
  resource.parameters = declarations
  resource.declared = true
  return true, util.deepCopy(declarations)
end

recordFailure = function(registry, fileName, failure)
  if not validRegistry(registry) then return end
  registry.diagnostics = registry.diagnostics or { captureCount = 0, failures = {} }
  registry.diagnostics.failures = registry.diagnostics.failures or {}
  local key = tostring(fileName or "<unknown>") .. ":" .. tostring(failure)
  registry.diagnostics.failures[key] = true
end

function M.capture(registry, fileName, params, updateResult)
  if not validRegistry(registry) then return false, "industry registry is invalid" end
  registry.diagnostics = registry.diagnostics or { captureCount = 0, failures = {} }
  registry.diagnostics.captureCount = (tonumber(registry.diagnostics.captureCount) or 0) + 1
  local resource, resourceError = ensureResource(registry, fileName)
  if not resource then return false, resourceError end
  local recipe, normalizeError = M.normalize(
    fileName, params, updateResult, resource.parameters)
  if not recipe then
    recordFailure(registry, fileName, normalizeError)
    return false, normalizeError
  end
  local parameterKey = json.encode(recipe.params)
  local variant = resource.variants[parameterKey]
  if not variant then
    if #util.sortedKeys(resource.variants) >= M.MAX_VARIANTS_PER_RESOURCE then
      registry.overflow = true
      return false, "industry resource variant registry overflow"
    end
    resource.variants[parameterKey] = {
      params = util.deepCopy(recipe.params),
      recipe = util.deepCopy(recipe),
      recipeDigests = { recipe.digest },
      ambiguous = false,
    }
    return true, recipe
  end
  local known = {}
  for _, digest in ipairs(variant.recipeDigests or {}) do known[digest] = true end
  if not known[recipe.digest] then
    variant.recipeDigests = variant.recipeDigests or {}
    variant.recipeDigests[#variant.recipeDigests + 1] = recipe.digest
    table.sort(variant.recipeDigests)
    variant.ambiguous = true
    -- The recipe is rejected once ambiguous. Keeping whichever loader result
    -- happened to arrive first would make the checkpoint digest order-dependent.
    variant.recipe = {}
    recordFailure(registry, fileName, "same persisted parameters produced multiple recipes")
    return false, "industry recipe depends on non-persisted parameters"
  end
  return not variant.ambiguous, variant.ambiguous
    and "industry recipe is ambiguous" or util.deepCopy(variant.recipe)
end

function M.lookup(registry, fileName, params)
  if not validRegistry(registry) then return nil, "industry registry is unavailable" end
  if registry.overflow then return nil, "industry registry overflowed" end
  local resource = registry.resources[M.canonicalResourceName(fileName)]
  if not resource then return nil, "industry resource was not captured" end
  if resource.declarationAmbiguous then return nil, "industry parameter declaration is ambiguous" end
  local projected, projectionError = M.parameterProjection(params or {}, resource.parameters)
  if not projected then return nil, projectionError end
  local variant = resource.variants and resource.variants[json.encode(projected)] or nil
  if not variant then return nil, "industry parameter variant was not captured" end
  if variant.ambiguous then return nil, "industry recipe is ambiguous" end
  if type(variant.recipe) ~= "table" then return nil, "industry recipe is missing" end
  return util.deepCopy(variant.recipe)
end

-- Merge is isolated because parallel loader partitions can arrive in any order.
function M.merge(target, source)
  return require("tpf2_mp/industry_resource_merge").merge(M, target, source)
end

function M.resourceArtifact(registry, fileName)
  return require("tpf2_mp/industry_resource_artifact").resourceArtifact(M, registry, fileName)
end

function M.writeResourceArtifact(registry, fileName, bridgeDirectory)
  return require("tpf2_mp/industry_resource_artifact").write(
    M, registry, fileName, bridgeDirectory)
end

function M.fromDigestView(view)
  return require("tpf2_mp/industry_resource_view_reader").fromDigestView(M, view)
end

function M.digestView(registry)
  if not validRegistry(registry) then return { schemaVersion = M.SCHEMA_VERSION, invalid = true } end
  local result = {
    schemaVersion = M.SCHEMA_VERSION,
    overflow = registry.overflow == true,
    resources = {},
  }
  for _, fileName in ipairs(util.sortedKeys(registry.resources)) do
    local resource = registry.resources[fileName]
    result.resources[#result.resources + 1] = require(
      "tpf2_mp/industry_resource_artifact").resourceView(M, fileName, resource)
  end
  return result
end

function M.digest(registry)
  return hash.value(M.digestView(registry))
end

function M.wrap(registry, fileName, data, onCapture)
  return require("tpf2_mp/industry_resource_loader").wrap(
    M, registry, fileName, data, onCapture)
end

function M.captureStandardVariants(registry, fileName, data)
  return require("tpf2_mp/industry_resource_loader").captureStandardVariants(
    M, registry, fileName, data)
end

return M
