local M = {}

local function field(value, key)
  if type(value) ~= "table" and type(value) ~= "userdata" then return nil end
  local ok, result = pcall(function() return value[key] end)
  return ok and result or nil
end

local function assign(value, key, replacement, label)
  local ok, err = pcall(function() value[key] = replacement end)
  if not ok then return nil, label .. " assignment failed: " .. tostring(err) end
  return true
end

local function number(value)
  local result = tonumber(value)
  return result and result == math.floor(result) and result or nil
end

local function vector(owner, names, label)
  for _, name in ipairs(names) do
    local value = field(owner, name)
    if value ~= nil then
      local ok, count = pcall(function() return #value end)
      count = ok and number(count) or nil
      if count and count >= 0 then return value, count end
      return nil, nil, label .. " length is unavailable"
    end
  end
  return nil, nil, label .. " vector is unavailable"
end

function M.rewriteConstruction(processed, nativePlayerId)
  nativePlayerId = number(nativePlayerId)
  if not nativePlayerId or nativePlayerId < 0 then
    return nil, "processed construction owner is unavailable"
  end
  local constructions, count, vectorError = vector(processed,
    { "toAdd", "constructionsToAdd" }, "processed constructions")
  if not constructions then return nil, vectorError end
  if count ~= 1 then
    return nil, "processed construction replay must contain exactly one addition"
  end
  local construction = field(constructions, 1)
  local ok, err = assign(construction, "playerEntity", nativePlayerId,
    "processed construction owner")
  if not ok then return nil, err end
  if number(field(construction, "playerEntity")) ~= nativePlayerId then
    return nil, "processed construction owner did not round-trip"
  end
  return true
end

function M.rewriteEdge(observed, expected, nativePlayerId)
  local expectedOwned, observedOwned = field(expected, "playerOwned"), field(observed, "playerOwned")
  if expectedOwned ~= nil then
    local expectedPlayer = number(field(expectedOwned, "player"))
    if not expectedPlayer or expectedPlayer ~= nativePlayerId then
      return nil, "captured construction edge has an unexpected native owner"
    end
    if observedOwned == nil then
      local ok, err = assign(observed, "playerOwned", expectedOwned,
        "generated edge ownership component")
      if not ok then return nil, err end
      observedOwned = field(observed, "playerOwned")
    else
      local ok, err = assign(observedOwned, "player", nativePlayerId,
        "generated edge owner")
      if not ok then return nil, err end
    end
    if number(field(observedOwned, "player")) ~= nativePlayerId then
      return nil, "generated edge owner did not round-trip"
    end
  elseif observedOwned ~= nil and number(field(observedOwned, "player")) ~= nil
      and number(field(observedOwned, "player")) >= 0 then
    local ok, err = assign(observedOwned, "player", -1, "generated public edge owner")
    if not ok then return nil, err end
    if number(field(observedOwned, "player")) ~= -1 then
      return nil, "generated public edge owner did not clear"
    end
  end
  return true
end

return M
