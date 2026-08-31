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

local function freshOwned(expected, factory)
  local owned = field(expected, "playerOwned")
  if owned ~= nil then return owned end
  if type(factory) ~= "function" then
    return nil, "private edge ownership component factory is unavailable"
  end
  local ok, value = pcall(factory)
  if not ok or value == nil then
    return nil, "private edge ownership component could not be materialised"
  end
  return value
end

-- The canonical owner is a plain-Lua plan derived from the validated wire
-- transaction before api.cmd.make.buildProposal runs. Build 35924 is allowed
-- to mutate both its input PlayerOwned userdata and the generated edge prefix,
-- so neither is an authority source at this boundary.
function M.rewriteEdge(observed, expected, canonicalOwner, nativePlayerId, factory)
  nativePlayerId, canonicalOwner = number(nativePlayerId), number(canonicalOwner)
  if not nativePlayerId or nativePlayerId < 0
      or (canonicalOwner ~= -1 and canonicalOwner ~= nativePlayerId) then
    return nil, "canonical construction edge ownership plan is invalid"
  end

  local observedOwned = field(observed, "playerOwned")
  if canonicalOwner == nativePlayerId then
    if observedOwned == nil then
      local component, componentError = freshOwned(expected, factory)
      if not component then return nil, componentError end
      local ownerOk, ownerError = assign(component, "player", canonicalOwner,
        "generated private edge owner")
      if not ownerOk then return nil, ownerError end
      local componentOk, componentAssignment = assign(observed, "playerOwned", component,
        "generated private edge ownership component")
      if not componentOk then return nil, componentAssignment end
      observedOwned = field(observed, "playerOwned")
    else
      local ownerOk, ownerError = assign(observedOwned, "player", canonicalOwner,
        "generated private edge owner")
      if not ownerOk then return nil, ownerError end
    end
    if number(field(observedOwned, "player")) ~= canonicalOwner then
      return nil, "generated private edge owner did not round-trip"
    end
  elseif observedOwned ~= nil then
    -- A native construction expansion may attach the local command issuer to
    -- a canonical public road. Clear it even when the pre-write value is an
    -- opaque or otherwise unreadable userdata field.
    local ownerOk, ownerError = assign(observedOwned, "player", -1,
      "generated public edge owner")
    if not ownerOk then return nil, ownerError end
    if number(field(observedOwned, "player")) ~= -1 then
      return nil, "generated public edge owner did not clear"
    end
  end
  return true
end

return M
