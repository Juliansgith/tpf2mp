local M = {}

M.FIELDS = {
  "trackType", "catenary", "length", "tracks", "paramX", "paramY",
}

local function field(value, key)
  local valueType = type(value)
  if valueType ~= "table" and valueType ~= "userdata" then return nil end
  local ok, result = pcall(function() return value[key] end)
  return ok and result or nil
end

local function integer(value)
  value = tonumber(value)
  if not value or value ~= value or value == math.huge or value == -math.huge
    or value ~= math.floor(value) then return nil end
  return value
end

local function layoutInteger(sourceParams, key)
  local raw = field(sourceParams, key)
  if raw == nil then return 0 end
  if key == "catenary" and type(raw) == "boolean" then return raw and 1 or 0 end
  return integer(raw)
end

function M.params(sourceParams)
  local result = {
    year = integer(field(sourceParams, "year")),
    seed = integer(field(sourceParams, "seed")),
  }
  for _, key in ipairs(M.FIELDS) do result[key] = layoutInteger(sourceParams, key) end
  return result
end

function M.inRange(params)
  return (params.trackType == 0 or params.trackType == 1)
    and (params.catenary == 0 or params.catenary == 1)
    and params.length ~= nil and params.length >= 0 and params.length <= 4
    and params.tracks ~= nil and params.tracks >= 0 and params.tracks <= 7
    and params.paramX == 0 and params.paramY == 0
end

local function diagnosticValue(sourceParams, key)
  local raw = field(sourceParams, key)
  if raw == nil then return "missing->0", true, false end
  if key == "catenary" and type(raw) == "boolean" then
    return "bool:" .. tostring(raw) .. "->" .. (raw and "1" or "0"), false, false
  end
  local value = integer(raw)
  if value ~= nil then return tostring(value), false, false end
  return "invalid:" .. type(raw), false, true
end

local function keys(value)
  local result = {}
  if type(value) == "table" then
    for key in pairs(value) do
      if key ~= "__type" and key ~= "__truncated" then result[#result + 1] = tostring(key) end
    end
    table.sort(result)
    while #result > 32 do table.remove(result) end
  end
  return result
end

-- Scalar-only evidence is intentional: diagnosticLog prints scalars and the
-- secure relay retains those lines without receiving native proposal data.
function M.diagnostic(sourceParams, moduleCount, templateMatch)
  if type(sourceParams) ~= "table" and type(sourceParams) ~= "userdata" then
    return {
      params = "unavailable", paramKeys = "none", missingDefaults = "none",
      invalidParams = "params", moduleCount = 0, defaultTemplateMatch = false,
    }
  end
  local params = M.params(sourceParams)
  local values = {
    "year=" .. (params.year == nil and "invalid" or tostring(params.year)),
    "seed=" .. (params.seed == nil and "invalid" or tostring(params.seed)),
  }
  local missing, invalid = {}, {}
  local invalidSet = {}
  local function markInvalid(key)
    if not invalidSet[key] then invalidSet[key] = true; invalid[#invalid + 1] = key end
  end
  for _, key in ipairs(M.FIELDS) do
    local rendered, wasMissing, wasInvalid = diagnosticValue(sourceParams, key)
    values[#values + 1] = key .. "=" .. rendered
    if wasMissing then missing[#missing + 1] = key end
    if wasInvalid then markInvalid(key) end
  end
  if params.year == nil or params.year < 1850 or params.year > 3000 then markInvalid("year") end
  if params.seed == nil or params.seed < 0 or params.seed > 2147483647 then markInvalid("seed") end
  if params.trackType ~= 0 and params.trackType ~= 1 then markInvalid("trackType") end
  if params.catenary ~= 0 and params.catenary ~= 1 then markInvalid("catenary") end
  if params.length == nil or params.length < 0 or params.length > 4 then markInvalid("length") end
  if params.tracks == nil or params.tracks < 0 or params.tracks > 7 then markInvalid("tracks") end
  if params.paramX ~= 0 then markInvalid("paramX") end
  if params.paramY ~= 0 then markInvalid("paramY") end
  local observedKeys = keys(sourceParams)
  return {
    params = table.concat(values, ","),
    paramKeys = #observedKeys > 0 and table.concat(observedKeys, ",") or "none",
    missingDefaults = #missing > 0 and table.concat(missing, ",") or "none",
    invalidParams = #invalid > 0 and table.concat(invalid, ",") or "none",
    moduleCount = tonumber(moduleCount) or 0,
    defaultTemplateMatch = templateMatch and true or false,
  }
end

return M
