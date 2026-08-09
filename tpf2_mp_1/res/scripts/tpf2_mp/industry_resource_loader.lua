local util = require "tpf2_mp/util"

local M = {}

local function recordFailure(registry, fileName, failure)
  registry.diagnostics = registry.diagnostics or { captureCount = 0, failures = {} }
  registry.diagnostics.failures = registry.diagnostics.failures or {}
  registry.diagnostics.failures[tostring(fileName or "<unknown>")
    .. ":" .. tostring(failure)] = true
end

function M.wrap(facts, registry, fileName, data, onCapture)
  if type(data) ~= "table" or not util.isCallable(data.updateFn) then return data, false end
  local kind = data.type
  local portableName = tostring(fileName or ""):gsub("\\", "/"):lower()
  if kind ~= "INDUSTRY" and tostring(kind) ~= "INDUSTRY" and tonumber(kind) ~= 10
      and not portableName:match("^industry/") and not portableName:match("/industry/") then
    return data, false
  end
  facts.declare(registry, fileName, data.params or {})
  local inner = data.updateFn
  data.updateFn = function(params)
    local result = inner(params)
    local ok, acceptedOrError = pcall(facts.capture, registry, fileName, params or {}, result)
    if not ok then recordFailure(registry, fileName, acceptedOrError) end
    if util.isCallable(onCapture) then
      local callbackOk, callbackError = pcall(onCapture, fileName, registry)
      if not callbackOk then recordFailure(registry, fileName, callbackError) end
    end
    return result
  end
  return data, true
end

local function namedUpvalue(fn, wanted, depth, seen)
  if type(fn) ~= "function" or depth <= 0 or seen[fn]
      or not (debug and type(debug.getupvalue) == "function") then return nil end
  seen[fn] = true
  for index = 1, 64 do
    local name, value = debug.getupvalue(fn, index)
    if not name then break end
    if name == wanted and type(value) == "table" then return value end
    if type(value) == "function" then
      local nested = namedUpvalue(value, wanted, depth - 1, seen)
      if nested then return nested end
    end
  end
  return nil
end

local function combinations(facts, declared)
  local result = { {} }
  for _, parameter in ipairs(declared or {}) do
    local expanded = {}
    for _, combination in ipairs(result) do
      for selection = 0, parameter.valueCount - 1 do
        local nextCombination = util.deepCopy(combination)
        nextCombination[parameter.key] = selection
        expanded[#expanded + 1] = nextCombination
        if #expanded > facts.MAX_VARIANTS_PER_RESOURCE then
          return nil, "declared industry parameter space exceeds the variant limit"
        end
      end
    end
    result = expanded
  end
  return result
end

function M.captureStandardVariants(facts, registry, fileName, data)
  local declarationOk, declared = facts.declare(registry, fileName,
    type(data) == "table" and data.params or {})
  if not declarationOk then return false, declared end
  local stockListConfig = type(data) == "table"
    and namedUpvalue(data.updateFn, "stockListConfig", 8, {}) or nil
  if type(stockListConfig) ~= "table" or type(stockListConfig.rule) ~= "table" then
    registry.diagnostics = registry.diagnostics or {}
    registry.diagnostics.standardMisses = registry.diagnostics.standardMisses or {}
    registry.diagnostics.standardMisses[tostring(fileName)] = true
    return false, "industry does not expose the standard data-only recipe closure"
  end
  local variants, variantsError = combinations(facts, declared)
  if not variants then registry.overflow = true; return false, variantsError end
  local captured = 0
  for _, params in ipairs(variants) do
    local level = (tonumber(params.productionLevel) or 0) + 1
    local inputEnabled = params.inputEnabled == nil or tonumber(params.inputEnabled) == 1
    local stocks = {}
    if inputEnabled then
      for _, cargoType in ipairs(stockListConfig.stocks or {}) do
        stocks[#stocks + 1] = { cargoType = cargoType }
      end
    end
    local accepted = facts.capture(registry, fileName, params, {
      stocks = stocks,
      rule = {
        input = inputEnabled and stockListConfig.rule.input or { {} },
        output = stockListConfig.rule.output or {},
        capacity = (tonumber(stockListConfig.rule.capacity) or 0) * level,
      },
    })
    if accepted then captured = captured + 1 end
  end
  return captured == #variants, {
    combinations = #variants, captured = captured,
    source = "industryutil.stockListConfig",
  }
end

return M
