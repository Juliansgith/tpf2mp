local M = {}

local BASE_INTERNAL = { x = -1082.250244140625, y = -1047.3646240234375,
  z = 8.6015548706054688 }
local BASE_ORIGIN = { x = -1079.1402587890625, y = -1067.9305419921875,
  z = 8.6015548706054688 }
local BASE_TANGENT = { x = -1.8242249488830566, y = 12.063109397888184, z = 0 }
local BASE_END_TANGENT = { x = -1.82421875, y = 12.0631103515625, z = 0 }
local BASE_X_AXIS = { x = -0.98875820636749268, y = -0.14952342212200165 }
local BASE_Y_AXIS = { x = 0.14952342212200165, y = -0.98875820636749268 }

local function finitePosition(value)
  if type(value) ~= "table" then return nil end
  local result = {}
  for _, key in ipairs({ "x", "y", "z" }) do
    local number = tonumber(value[key])
    if not number or number ~= number or number == math.huge
      or number == -math.huge or math.abs(number) > 10000000 then return nil end
    result[key] = number
  end
  return result
end

local function rotateXY(value, cosine, sine)
  return { x = cosine * value.x - sine * value.y,
    y = sine * value.x + cosine * value.y, z = tonumber(value.z) or 0 }
end

local function horizontal(value)
  return math.sqrt(value.x * value.x + value.y * value.y)
end

local function alignmentRotation(target)
  target = finitePosition(target)
  if not target then return nil, nil, "connected depot target tangent is invalid" end
  local baseLength, targetLength = horizontal(BASE_TANGENT), horizontal(target)
  if baseLength < 0.000001 or targetLength < 0.000001 then
    return nil, nil, "connected depot target tangent has no horizontal direction"
  end
  local cosine = (BASE_TANGENT.x * target.x + BASE_TANGENT.y * target.y)
    / (baseLength * targetLength)
  local sine = (BASE_TANGENT.x * target.y - BASE_TANGENT.y * target.x)
    / (baseLength * targetLength)
  return cosine, sine, nil, target.z / targetLength
end

function M.resolve(options)
  options = type(options) == "table" and options or {}
  local connectNodeCid = options.connectNodeCid or "node:pre:410b0cf7"
  if type(connectNodeCid) ~= "string" or not connectNodeCid:match("^node:") then
    return nil, "connected depot target node is invalid"
  end
  local connectPosition = finitePosition(options.connectPosition)
  local internal = { x = BASE_INTERNAL.x, y = BASE_INTERNAL.y, z = BASE_INTERNAL.z }
  local origin = { x = BASE_ORIGIN.x, y = BASE_ORIGIN.y, z = BASE_ORIGIN.z }
  local entrance = { x = BASE_TANGENT.x, y = BASE_TANGENT.y, z = BASE_TANGENT.z }
  local endpoint = { x = BASE_END_TANGENT.x, y = BASE_END_TANGENT.y,
    z = BASE_END_TANGENT.z }
  local xAxis = { x = BASE_X_AXIS.x, y = BASE_X_AXIS.y }
  local yAxis = { x = BASE_Y_AXIS.x, y = BASE_Y_AXIS.y }
  local slope = 0
  local offset = { x = BASE_ORIGIN.x - BASE_INTERNAL.x,
    y = BASE_ORIGIN.y - BASE_INTERNAL.y, z = BASE_ORIGIN.z - BASE_INTERNAL.z }

  if options.connectTangent ~= nil then
    local cosine, sine, rotationError
    cosine, sine, rotationError, slope = alignmentRotation(options.connectTangent)
    if not cosine then return nil, rotationError end
    if math.abs(slope) > 0.25 then
      return nil, "connected depot target tangent grade exceeds 25 percent"
    end
    entrance, endpoint = rotateXY(BASE_TANGENT, cosine, sine),
      rotateXY(BASE_END_TANGENT, cosine, sine)
    xAxis, yAxis = rotateXY(BASE_X_AXIS, cosine, sine), rotateXY(BASE_Y_AXIS, cosine, sine)
    offset = rotateXY(offset, cosine, sine)
    entrance.z, endpoint.z = horizontal(entrance) * slope, horizontal(endpoint) * slope
    local wanted = assert(finitePosition(options.connectTangent))
    local lengths = horizontal(entrance) * horizontal(wanted)
    local dot = entrance.x * wanted.x + entrance.y * wanted.y
    if lengths < 0.000001 or dot / lengths < 0.9999 then
      return nil, "connected depot template could not align with route topology"
    end
  end

  local gap = tonumber(options.connectionGap) or 0
  if gap ~= gap or gap == math.huge or gap == -math.huge or gap < 0 or gap > 100 then
    return nil, "connected depot connection gap is outside [0,100]"
  end
  if gap > 0 then
    local length = horizontal(entrance)
    if length < 0.000001 then return nil, "connected depot entrance has no horizontal direction" end
    local x, y = gap * entrance.x / length, gap * entrance.y / length
    entrance.x, entrance.y = entrance.x + x, entrance.y + y
    endpoint.x, endpoint.y = endpoint.x + x, endpoint.y + y
    entrance.z, endpoint.z = entrance.z + gap * slope, endpoint.z + gap * slope
  end

  if options.connectPosition ~= nil then
    if not connectPosition then return nil, "connected depot target position is invalid" end
    internal = { x = connectPosition.x - entrance.x, y = connectPosition.y - entrance.y,
      z = connectPosition.z - entrance.z }
    origin = { x = internal.x + offset.x, y = internal.y + offset.y,
      z = internal.z + offset.z }
    if type(options.terrainHeight) == "function" then
      local ok, ground = pcall(options.terrainHeight, origin.x, origin.y)
      ground = ok and tonumber(ground) or nil
      if not ground or ground ~= ground or ground == math.huge or ground == -math.huge then
        return nil, "connected depot terrain height is unavailable"
      end
      -- Keep the generated construction and its internal node as one rigid
      -- transform; the explicit entrance segment alone carries local grade.
      origin.z, internal.z = ground, ground + offset.z
      entrance.z = connectPosition.z - internal.z
      endpoint.z = entrance.z
      if horizontal(entrance) < 0.000001
        or math.abs(entrance.z) / horizontal(entrance) > 0.25 then
        return nil, "connected depot terrain grade exceeds 25 percent"
      end
    end
  end

  return {
    connectNodeCid = connectNodeCid, internal = internal, origin = origin,
    entrance = entrance, endpoint = endpoint, xAxis = xAxis, yAxis = yAxis,
  }
end

return M
