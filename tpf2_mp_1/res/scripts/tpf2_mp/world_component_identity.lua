local util = require "tpf2_mp/util"

local M = {}

function M.new(deps)
  deps = deps or {}
  local component = assert(deps.component, "component dependency is required")
  local getApi = deps.getApi or function() return api end

  local function safeField(value, key)
    if type(value) ~= "table" and type(value) ~= "userdata" then return nil end
    local ok, nested = pcall(function() return value[key] end)
    if not ok then return nil end
    return nested
  end

  local function nameOf(id)
    local gameApi = getApi() or {}
    local types = gameApi.type and gameApi.type.ComponentType or {}
    local nameComponent = component(id, types.NAME)
    local name = safeField(nameComponent, "name")
    return name ~= nil and tostring(name) or ""
  end

  local function numericField(value, index, key)
    if value == nil then return nil end
    local ok, nested = pcall(function()
      local indexed = value[index]
      if indexed ~= nil then return indexed end
      return value[key]
    end)
    return ok and tonumber(nested) or nil
  end

  local function quantisedPosition(value)
    local x, y = numericField(value, 1, "x"), numericField(value, 2, "y")
    if x == nil or y == nil then return nil end
    local z = numericField(value, 3, "z")
    local result = { util.integer(x * 10), util.integer(y * 10) }
    if z ~= nil then result[3] = util.integer(z * 10) end
    return result
  end

  -- Build 35924 can access-violate while the broad getEntity binding
  -- materialises a loaded STATION with a null optional native string. This
  -- reader deliberately touches only named components and their known fields.
  local function positionOf(id)
    local gameApi = getApi() or {}
    local types = gameApi.type and gameApi.type.ComponentType or {}
    local construction = component(id, types.CONSTRUCTION)
    local transform = safeField(construction, "transf")
    if transform then
      local cols = safeField(transform, "cols")
      if type(cols) == "function" then
        local ok, position = pcall(cols, transform, 3)
        local quantised = ok and quantisedPosition(position) or nil
        if quantised then return quantised end
      end
    end

    for _, componentName in ipairs({
      "BASE_NODE", "TOWN", "SIM_BUILDING", "STATION_GROUP", "STATION",
      "VEHICLE_DEPOT", "TRANSPORT_VEHICLE",
    }) do
      local value = component(id, types[componentName])
      if value then
        local position = safeField(value, "position") or safeField(value, "pos")
        local quantised = quantisedPosition(position)
        if quantised then return quantised end
      end
    end
    return nil
  end

  return {
    safeField = safeField,
    nameOf = nameOf,
    quantisedPosition = quantisedPosition,
    positionOf = positionOf,
  }
end

return M
