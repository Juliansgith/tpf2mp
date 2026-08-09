local hash = require "tpf2_mp/hash"
local json = require "tpf2_mp/json"
local util = require "tpf2_mp/util"

local M = {
  SCHEMA_VERSION = 1,
  MAX_INDUSTRIES = 2048,
  MAX_RECIPE_ITEMS = 32,
  MAX_AMOUNT = 1000000000,
  MAX_ACCUMULATOR = 1000000000000000,
  MAX_BOOTSTRAP_BYTES = 2 * 1024 * 1024,
}

local function exactInteger(value, minimum, maximum)
  return type(value) == "number" and value == math.floor(value)
    and value >= minimum and value <= maximum
end

local function sequence(value, label, maximum)
  if type(value) ~= "table" then return nil, label .. " is not a sequence" end
  local keys = {}
  for key in pairs(value) do
    if type(key) ~= "number" or key < 1 or key ~= math.floor(key) then
      return nil, label .. " has a non-sequence key"
    end
    keys[#keys + 1] = key
  end
  table.sort(keys)
  if #keys > maximum then return nil, label .. " exceeds its size limit" end
  for index, key in ipairs(keys) do
    if index ~= key then return nil, label .. " contains a gap" end
  end
  return keys
end

local function portableValue(value, depth, budget)
  local kind = type(value)
  if value == nil or kind == "boolean" or kind == "string" then return util.deepCopy(value) end
  if kind == "number" then
    if value ~= value or value == math.huge or value == -math.huge then
      return nil, "parameter contains a non-finite number"
    end
    return value
  end
  if kind ~= "table" then return nil, "parameter contains opaque " .. kind end
  if depth <= 0 then return nil, "parameter nesting exceeds the freight limit" end
  local result, count = {}, 0
  for key, nested in pairs(value) do
    if type(key) ~= "string" and type(key) ~= "number" then
      return nil, "parameter has an unsupported key type"
    end
    count = count + 1
    budget.count = budget.count + 1
    if count > 128 or budget.count > 512 then
      return nil, "parameter projection exceeds the freight limit"
    end
    local projected, projectionError = portableValue(nested, depth - 1, budget)
    if projectionError then return nil, projectionError end
    result[key] = projected
  end
  return result
end

local function validCargoType(value)
  return type(value) == "string" and #value >= 1 and #value <= 128
    and value:match("^[A-Z][A-Z0-9_]*$") ~= nil
end

local function normalizeStocks(value)
  local keys, keysError = sequence(value, "industry stocks", M.MAX_RECIPE_ITEMS)
  if not keys then return nil, keysError end
  local result, seen = {}, {}
  for _, key in ipairs(keys) do
    local item = value[key]
    if type(item) ~= "table" then return nil, "industry stock is not a table" end
    local allowed = { index = true, cargoType = true, stockType = true, moreCapacity = true }
    for field in pairs(item) do
      if not allowed[field] then return nil, "industry stock has unknown field " .. tostring(field) end
    end
    if not exactInteger(item.index, 0, M.MAX_RECIPE_ITEMS - 1) or item.index ~= key - 1 then
      return nil, "industry stock index is invalid"
    end
    if seen[item.index] or not validCargoType(item.cargoType) then
      return nil, "industry stock cargo/index is invalid"
    end
    seen[item.index] = true
    if type(item.stockType) ~= "string" or #item.stockType > 128
        or not exactInteger(item.moreCapacity, 0, M.MAX_AMOUNT) then
      return nil, "industry stock metadata is invalid"
    end
    result[#result + 1] = {
      index = item.index, cargoType = item.cargoType,
      stockType = item.stockType, moreCapacity = item.moreCapacity,
    }
  end
  return result
end

local function normalizeInputs(value, stocks)
  local keys, keysError = sequence(value, "industry input alternatives", M.MAX_RECIPE_ITEMS)
  if not keys then return nil, keysError end
  if #keys == 0 then return nil, "industry has no input alternative" end
  local stockByIndex = {}
  for _, stock in ipairs(stocks) do stockByIndex[stock.index] = stock end
  local result = {}
  for _, key in ipairs(keys) do
    local raw = value[key]
    local requirementKeys, requirementError = sequence(
      raw, "industry input requirements", M.MAX_RECIPE_ITEMS)
    if not requirementKeys then return nil, requirementError end
    local requirements, seen = {}, {}
    for _, requirementKey in ipairs(requirementKeys) do
      local item = raw[requirementKey]
      if type(item) ~= "table" then return nil, "industry input requirement is not a table" end
      local allowed = { stockIndex = true, cargoType = true, amount = true }
      for field in pairs(item) do
        if not allowed[field] then
          return nil, "industry input requirement has unknown field " .. tostring(field)
        end
      end
      local stock = exactInteger(item.stockIndex, 0, M.MAX_RECIPE_ITEMS - 1)
        and stockByIndex[item.stockIndex] or nil
      if not stock or seen[item.stockIndex] or item.cargoType ~= stock.cargoType
          or not exactInteger(item.amount, 1, M.MAX_AMOUNT) then
        return nil, "industry input requirement is invalid"
      end
      seen[item.stockIndex] = true
      requirements[#requirements + 1] = {
        stockIndex = item.stockIndex, cargoType = item.cargoType, amount = item.amount,
      }
    end
    table.sort(requirements, function(a, b) return a.stockIndex < b.stockIndex end)
    result[#result + 1] = requirements
  end
  return result
end

local function normalizeOutputs(value)
  local keys, keysError = sequence(value, "industry outputs", M.MAX_RECIPE_ITEMS)
  if not keys then return nil, keysError end
  local result, seen = {}, {}
  for _, key in ipairs(keys) do
    local item = value[key]
    if type(item) ~= "table" then return nil, "industry output is not a table" end
    local allowed = { cargoType = true, amount = true }
    for field in pairs(item) do
      if not allowed[field] then return nil, "industry output has unknown field " .. tostring(field) end
    end
    if not validCargoType(item.cargoType) or seen[item.cargoType]
        or not exactInteger(item.amount, 1, M.MAX_AMOUNT) then
      return nil, "industry output is invalid"
    end
    seen[item.cargoType] = true
    result[#result + 1] = { cargoType = item.cargoType, amount = item.amount }
  end
  table.sort(result, function(a, b) return a.cargoType < b.cargoType end)
  return result
end

function M.normalizeIndustry(value)
  if type(value) ~= "table" then return nil, "industry record is not a table" end
  local allowed = {
    cid = true, resource = true, params = true, recipeDigest = true,
    capacity = true, stocks = true, inputs = true, outputs = true,
  }
  for field in pairs(value) do
    if not allowed[field] then return nil, "industry record has unknown field " .. tostring(field) end
  end
  for field in pairs(allowed) do
    if value[field] == nil then return nil, "industry record is missing " .. field end
  end
  if type(value.cid) ~= "string" or #value.cid > 320
      or not value.cid:match("^industry:") then
    return nil, "industry canonical id is invalid"
  end
  if type(value.resource) ~= "string" or #value.resource > 320
      or not value.resource:match("^[%w_./-]+%.con$") or value.resource:find("..", 1, true) then
    return nil, "industry resource name is invalid"
  end
  if type(value.recipeDigest) ~= "string" or #value.recipeDigest ~= 8
      or not value.recipeDigest:match("^[0-9a-f]+$") then
    return nil, "industry recipe digest is invalid"
  end
  if not exactInteger(value.capacity, 0, M.MAX_AMOUNT) then
    return nil, "industry capacity is invalid"
  end
  local params, paramsError = portableValue(value.params, 6, { count = 0 })
  if paramsError then return nil, paramsError end
  local stocks, stocksError = normalizeStocks(value.stocks)
  if not stocks then return nil, stocksError end
  local inputs, inputsError = normalizeInputs(value.inputs, stocks)
  if not inputs then return nil, inputsError end
  local outputs, outputsError = normalizeOutputs(value.outputs)
  if not outputs then return nil, outputsError end
  local hasFlow = #outputs > 0
  for _, alternative in ipairs(inputs) do
    if #alternative > 0 then hasFlow = true; break end
  end
  if not hasFlow then return nil, "industry has no positive flow" end
  local result = {
    cid = value.cid, resource = value.resource, params = params,
    recipeDigest = value.recipeDigest, capacity = value.capacity,
    stocks = stocks, inputs = inputs, outputs = outputs,
  }
  local expectedRecipeDigest = hash.value({
    resource = result.resource, params = result.params, stocks = result.stocks,
    inputs = result.inputs, outputs = result.outputs, capacity = result.capacity,
  })
  if expectedRecipeDigest ~= result.recipeDigest then
    return nil, "industry recipe digest does not match its normalized fields"
  end
  return result
end

local function bootstrapView(contentDigest, economyEpoch, industries)
  return {
    schemaVersion = M.SCHEMA_VERSION,
    contentDigest = contentDigest,
    economyEpoch = economyEpoch,
    industries = industries,
  }
end

function M.bootstrapAction(contentDigest, economyEpoch, rawIndustries)
  if type(contentDigest) ~= "string" or not contentDigest:match("^[0-9a-f]+$")
      or #contentDigest ~= 8 then return nil, "freight content digest is invalid" end
  if not exactInteger(economyEpoch, 0, M.MAX_AMOUNT) then
    return nil, "freight economy epoch is invalid"
  end
  local keys, keysError = sequence(rawIndustries, "freight industries", M.MAX_INDUSTRIES)
  if not keys then return nil, keysError end
  local industries, seen = {}, {}
  for _, key in ipairs(keys) do
    local industry, industryError = M.normalizeIndustry(rawIndustries[key])
    if not industry then return nil, industryError end
    if seen[industry.cid] then return nil, "freight industry canonical id is duplicated" end
    seen[industry.cid] = true
    industries[#industries + 1] = industry
  end
  table.sort(industries, function(a, b) return a.cid < b.cid end)
  local action = bootstrapView(contentDigest, economyEpoch, industries)
  action.type = "freight.industry_bootstrap"
  action.digest = hash.value(bootstrapView(contentDigest, economyEpoch, industries))
  if #json.encode(action) > M.MAX_BOOTSTRAP_BYTES then
    return nil, "freight bootstrap exceeds 2 MiB"
  end
  return action
end

function M.validateBootstrapAction(action)
  if type(action) ~= "table" then return false, "freight bootstrap action is not a table" end
  local allowed = {
    type = true, schemaVersion = true, contentDigest = true,
    economyEpoch = true, industries = true, digest = true,
  }
  for field in pairs(action) do
    if not allowed[field] then return false, "freight bootstrap has unknown field " .. tostring(field) end
  end
  for field in pairs(allowed) do
    if action[field] == nil then return false, "freight bootstrap is missing " .. field end
  end
  if action.type ~= "freight.industry_bootstrap" or action.schemaVersion ~= M.SCHEMA_VERSION then
    return false, "freight bootstrap header is invalid"
  end
  local rebuilt, rebuildError = M.bootstrapAction(
    action.contentDigest, action.economyEpoch, action.industries)
  if not rebuilt then return false, rebuildError end
  if rebuilt.digest ~= action.digest or hash.value(action.industries) ~= hash.value(rebuilt.industries) then
    return false, "freight bootstrap digest or canonical order is invalid"
  end
  return true, rebuilt
end

function M.newState()
  return {
    schemaVersion = M.SCHEMA_VERSION,
    ready = false,
    contentDigest = nil,
    bootstrapDigest = nil,
    bootstrapEpoch = 0,
    productionEpoch = 0,
    industries = {},
    totalProduced = {},
    totalConsumed = {},
    lastAdvance = nil,
    migrationError = nil,
  }
end

function M.newProbe()
  return {
    status = "waiting-for-content",
    attempts = 0,
    lastAttemptTick = nil,
    industryCount = 0,
    sourceCount = 0,
    processorCount = 0,
    validatedBootstrapDigest = nil,
    validatedIndustryCount = 0,
    lastError = nil,
  }
end

local function stateIndustry(recipe)
  local inputStock = {}
  for _, stock in ipairs(recipe.stocks) do
    inputStock[#inputStock + 1] = {
      index = stock.index, cargoType = stock.cargoType, amount = 0,
    }
  end
  return {
    cid = recipe.cid,
    recipe = util.deepCopy(recipe),
    inputStock = inputStock,
    outputStock = {},
    productionResid = 0,
    totalProduced = {},
    totalConsumed = {},
    lastCycles = 0,
  }
end

function M.applyBootstrap(state, action, content)
  local valid, rebuiltOrError = M.validateBootstrapAction(action)
  if not valid then return false, rebuiltOrError end
  local rebuilt = rebuiltOrError
  if type(content) ~= "table" or content.ready ~= true
      or content.digest ~= rebuilt.contentDigest then
    return false, "freight bootstrap does not match agreed industry content"
  end
  if type(state.migrationError) == "string" then
    return false, "saved freight state is invalid: " .. state.migrationError
  end
  if state.ready then
    if state.bootstrapDigest == rebuilt.digest then return true, M.digestView(state) end
    return false, "freight industries cannot change after bootstrap"
  end
  local industries = {}
  for _, recipe in ipairs(rebuilt.industries) do industries[recipe.cid] = stateIndustry(recipe) end
  state.schemaVersion = M.SCHEMA_VERSION
  state.ready = true
  state.contentDigest = rebuilt.contentDigest
  state.bootstrapDigest = rebuilt.digest
  state.bootstrapEpoch = rebuilt.economyEpoch
  state.productionEpoch = rebuilt.economyEpoch
  state.industries = industries
  state.totalProduced = {}
  state.totalConsumed = {}
  state.lastAdvance = nil
  return true, M.digestView(state)
end

local function saturatingAdd(left, right)
  left, right = math.max(0, math.floor(tonumber(left) or 0)), math.max(0, math.floor(tonumber(right) or 0))
  if left >= M.MAX_ACCUMULATOR - right then return M.MAX_ACCUMULATOR end
  return left + right
end

local function stockByIndex(industry)
  local result = {}
  for _, stock in ipairs(industry.inputStock or {}) do result[stock.index] = stock end
  return result
end

local function feasibleCycles(alternative, stocks, quota)
  local feasible = quota
  for _, requirement in ipairs(alternative) do
    local stock = stocks[requirement.stockIndex]
    if not stock then return 0 end
    feasible = math.min(feasible, math.floor(stock.amount / requirement.amount))
  end
  return feasible
end

function M.advance(state, epoch, periodSeconds)
  if type(state) ~= "table" or state.ready ~= true then return true, { skipped = "not-ready" } end
  if not exactInteger(epoch, 1, M.MAX_AMOUNT) or epoch ~= state.productionEpoch + 1 then
    return false, "freight production epoch is not the next authored epoch"
  end
  if not exactInteger(periodSeconds, 60, 86400) then
    return false, "freight production period is invalid"
  end
  local summary = { epoch = epoch, periodSeconds = periodSeconds, industries = {}, produced = {}, consumed = {} }
  for _, cid in ipairs(util.sortedKeys(state.industries)) do
    local industry = state.industries[cid]
    local recipe = industry.recipe
    local numerator = industry.productionResid + recipe.capacity * periodSeconds
    local quota = math.floor(numerator / 3600)
    industry.productionResid = numerator % 3600
    local stocks = stockByIndex(industry)
    local cycles = 0
    for _, alternative in ipairs(recipe.inputs) do
      local feasible = feasibleCycles(alternative, stocks, quota)
      if feasible > 0 or (#alternative == 0 and quota == 0) then
        cycles = feasible
        if cycles > 0 then
          for _, requirement in ipairs(alternative) do
            local stock = stocks[requirement.stockIndex]
            local consumed = cycles * requirement.amount
            stock.amount = stock.amount - consumed
            industry.totalConsumed[requirement.cargoType] = saturatingAdd(
              industry.totalConsumed[requirement.cargoType], consumed)
            state.totalConsumed[requirement.cargoType] = saturatingAdd(
              state.totalConsumed[requirement.cargoType], consumed)
            summary.consumed[requirement.cargoType] = saturatingAdd(
              summary.consumed[requirement.cargoType], consumed)
          end
        end
        break
      end
    end
    if cycles > 0 then
      for _, output in ipairs(recipe.outputs) do
        local produced = cycles * output.amount
        industry.outputStock[output.cargoType] = saturatingAdd(
          industry.outputStock[output.cargoType], produced)
        industry.totalProduced[output.cargoType] = saturatingAdd(
          industry.totalProduced[output.cargoType], produced)
        state.totalProduced[output.cargoType] = saturatingAdd(
          state.totalProduced[output.cargoType], produced)
        summary.produced[output.cargoType] = saturatingAdd(
          summary.produced[output.cargoType], produced)
      end
    end
    industry.lastCycles = cycles
    summary.industries[cid] = {
      quota = quota, cycles = cycles, productionResid = industry.productionResid,
    }
  end
  state.productionEpoch = epoch
  state.lastAdvance = summary
  return true, util.deepCopy(summary)
end

function M.depositInputAtStock(state, cid, stockIndex, cargoType, amount)
  if type(state) ~= "table" or state.ready ~= true then return false, "freight state is not ready" end
  if not exactInteger(stockIndex, 0, M.MAX_RECIPE_ITEMS - 1)
      or not validCargoType(cargoType) or not exactInteger(amount, 1, M.MAX_AMOUNT) then
    return false, "freight input deposit is invalid"
  end
  local industry = state.industries[cid]
  if not industry then return false, "freight input industry is unknown" end
  for _, stock in ipairs(industry.inputStock) do
    if stock.index == stockIndex and stock.cargoType == cargoType then
      stock.amount = saturatingAdd(stock.amount, amount)
      return true, stock.amount
    end
  end
  return false, "industry stock does not accept cargo " .. cargoType
end

function M.depositInput(state, cid, cargoType, amount)
  local industry = type(state) == "table" and type(state.industries) == "table"
    and state.industries[cid] or nil
  local stockIndex, matches = nil, 0
  for _, stock in ipairs(industry and industry.inputStock or {}) do
    if stock.cargoType == cargoType then stockIndex, matches = stock.index, matches + 1 end
  end
  if matches > 1 then return false, "industry cargo target is ambiguous; stock index is required" end
  return M.depositInputAtStock(state, cid, stockIndex, cargoType, amount)
end

function M.withdrawOutput(state, cid, cargoType, amount)
  if type(state) ~= "table" or state.ready ~= true then return false, "freight state is not ready" end
  if not validCargoType(cargoType) or not exactInteger(amount, 1, M.MAX_AMOUNT) then
    return false, "freight output withdrawal is invalid"
  end
  local industry = state.industries[cid]
  if not industry then return false, "freight output industry is unknown" end
  local available = math.max(0, math.floor(tonumber(industry.outputStock[cargoType]) or 0))
  if available < amount then return false, "industry output stock is insufficient" end
  industry.outputStock[cargoType] = available - amount
  return true, industry.outputStock[cargoType]
end

function M.digestView(state)
  state = type(state) == "table" and state or M.newState()
  local industries = {}
  for _, cid in ipairs(util.sortedKeys(state.industries or {})) do
    local value = state.industries[cid]
    industries[cid] = {
      cid = cid,
      recipe = util.deepCopy(value.recipe),
      inputStock = util.deepCopy(value.inputStock or {}),
      outputStock = util.deepCopy(value.outputStock or {}),
      productionResid = math.max(0, math.floor(tonumber(value.productionResid) or 0)),
      totalProduced = util.deepCopy(value.totalProduced or {}),
      totalConsumed = util.deepCopy(value.totalConsumed or {}),
      lastCycles = math.max(0, math.floor(tonumber(value.lastCycles) or 0)),
    }
  end
  return {
    schemaVersion = M.SCHEMA_VERSION,
    ready = state.ready == true,
    contentDigest = state.contentDigest,
    bootstrapDigest = state.bootstrapDigest,
    bootstrapEpoch = math.max(0, math.floor(tonumber(state.bootstrapEpoch) or 0)),
    productionEpoch = math.max(0, math.floor(tonumber(state.productionEpoch) or 0)),
    industries = industries,
    totalProduced = util.deepCopy(state.totalProduced or {}),
    totalConsumed = util.deepCopy(state.totalConsumed or {}),
    lastAdvance = util.deepCopy(state.lastAdvance),
    migrationError = state.migrationError,
  }
end

function M.digest(state) return hash.value(M.digestView(state)) end

function M.publicView(state)
  state = type(state) == "table" and state or M.newState()
  local inputUnits, outputUnits = 0, 0
  for _, industry in pairs(state.industries or {}) do
    for _, stock in ipairs(industry.inputStock or {}) do
      inputUnits = saturatingAdd(inputUnits, stock.amount)
    end
    for _, amount in pairs(industry.outputStock or {}) do
      outputUnits = saturatingAdd(outputUnits, amount)
    end
  end
  return {
    schemaVersion = M.SCHEMA_VERSION,
    ready = state.ready == true,
    contentDigest = state.contentDigest,
    bootstrapDigest = state.bootstrapDigest,
    productionEpoch = math.max(0, math.floor(tonumber(state.productionEpoch) or 0)),
    industryCount = #util.sortedKeys(state.industries or {}),
    inputUnits = inputUnits,
    outputUnits = outputUnits,
    totalProduced = util.deepCopy(state.totalProduced or {}),
    totalConsumed = util.deepCopy(state.totalConsumed or {}),
    lastAdvance = util.deepCopy(state.lastAdvance),
    migrationError = state.migrationError,
  }
end

function M.migrate(value)
  local function failed(reason)
    local reset = M.newState()
    reset.migrationError = tostring(reason or "saved freight state is malformed")
    return reset, reset.migrationError
  end
  if type(value) ~= "table" then return M.newState() end
  if value.ready ~= true then
    if type(value.migrationError) == "string" then return failed(value.migrationError) end
    return M.newState()
  end
  local recipes = {}
  for _, cid in ipairs(util.sortedKeys(value.industries or {})) do
    local record = value.industries[cid]
    if type(record) ~= "table" or type(record.recipe) ~= "table" then return failed() end
    recipes[#recipes + 1] = record.recipe
  end
  local action, actionError = M.bootstrapAction(
    value.contentDigest, math.max(0, math.floor(tonumber(value.bootstrapEpoch) or 0)), recipes)
  if not action then return failed(actionError) end
  if value.bootstrapDigest ~= action.digest then
    return failed("saved freight bootstrap digest is invalid")
  end
  local result = M.newState()
  local applied = M.applyBootstrap(result, action, { ready = true, digest = action.contentDigest })
  if not applied then return failed("saved freight bootstrap could not be reapplied") end
  for cid, target in pairs(result.industries) do
    local source = value.industries[cid]
    for index, stock in ipairs(target.inputStock) do
      local old = type(source.inputStock) == "table" and source.inputStock[index] or nil
      if type(old) == "table" and old.index == stock.index and old.cargoType == stock.cargoType then
        stock.amount = math.min(M.MAX_ACCUMULATOR, math.max(0, math.floor(tonumber(old.amount) or 0)))
      end
    end
    target.outputStock = util.deepCopy(type(source.outputStock) == "table" and source.outputStock or {})
    target.productionResid = math.max(0, math.floor(tonumber(source.productionResid) or 0)) % 3600
    target.totalProduced = util.deepCopy(type(source.totalProduced) == "table" and source.totalProduced or {})
    target.totalConsumed = util.deepCopy(type(source.totalConsumed) == "table" and source.totalConsumed or {})
    target.lastCycles = math.max(0, math.floor(tonumber(source.lastCycles) or 0))
  end
  result.productionEpoch = math.max(0, math.floor(tonumber(value.productionEpoch) or 0))
  result.totalProduced = util.deepCopy(type(value.totalProduced) == "table" and value.totalProduced or {})
  result.totalConsumed = util.deepCopy(type(value.totalConsumed) == "table" and value.totalConsumed or {})
  result.lastAdvance = util.deepCopy(value.lastAdvance)
  return result
end

return M
