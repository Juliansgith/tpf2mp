local M = {}

function M.integer(value, low, high)
  local number = tonumber(value)
  if not number or number ~= math.floor(number) or number < low or number > high then
    return nil
  end
  return number
end

function M.decodeName(value)
  value = tostring(value or "")
  if #value % 2 ~= 0 or #value > 320 or value:find("[^0-9a-fA-F]") then return nil end
  local result = {}
  for index = 1, #value, 2 do
    local byte = tonumber(value:sub(index, index + 1), 16)
    if not byte or byte == 0 then return nil end
    result[#result + 1] = string.char(byte)
  end
  return table.concat(result)
end

function M.retainSelection(gui, capture)
  if type(gui) ~= "table" or type(capture) ~= "table" then return nil end
  if capture.kind == "line.delete" then
    if gui.selectedLineId == capture.targetLocalId then gui.selectedLineId = nil end
  else
    gui.selectedLineId = tonumber(capture.originLocalId or capture.targetLocalId)
      or gui.selectedLineId
  end
  return gui.selectedLineId
end

local function alternatives(text, maximum, version)
  if text == "" then return {} end
  local result, encoded, flat = {}, {}, {}
  for value in text:gmatch("[^:]+") do
    if version == "L2" then
      local scalar = M.integer(value, 0, 4095)
      if not scalar or #flat >= maximum * 2 then return nil end
      flat[#flat + 1] = scalar
      encoded[#encoded + 1] = tostring(scalar)
    else
      local stationText, terminalText = value:match("^(%d+)%.(%d+)$")
      local station = M.integer(stationText, 0, 4095)
      local terminal = M.integer(terminalText, 0, 4095)
      if not station or not terminal or #result >= maximum then return nil end
      result[#result + 1] = { station = station, terminal = terminal }
      encoded[#encoded + 1] = tostring(station) .. "." .. tostring(terminal)
    end
  end
  if table.concat(encoded, ":") ~= text then return nil end
  if version == "L2" then
    if #flat % 2 ~= 0 then return nil end
    for index = 1, #flat, 2 do
      result[#result + 1] = { station = flat[index], terminal = flat[index + 1] }
    end
  end
  return result
end

function M.decode(raw, maxStops, maxAlternativeTerminals)
  if type(raw) ~= "string" or #raw > 65536 then
    return nil, "invalid native line envelope"
  end
  local fields, cursor = {}, 1
  for index = 1, 9 do
    local boundary = raw:find("|", cursor, true)
    if not boundary then return nil, "truncated native line envelope" end
    fields[index] = raw:sub(cursor, boundary - 1)
    cursor = boundary + 1
  end
  fields[10] = raw:sub(cursor)
  local version = fields[1]
  if version ~= "L1" and version ~= "L2" and version ~= "L3" then
    return nil, "unsupported native line envelope version"
  end
  local tag = M.integer(fields[2], 3, 29)
  if tag ~= 3 and tag ~= 4 and tag ~= 5 and tag ~= 28 and tag ~= 29 then tag = nil end
  local target = M.integer(fields[3], -1, 2147483647)
  local player = M.integer(fields[4], -1, 2147483647)
  local r = M.integer(fields[5], 0, 1000)
  local g = M.integer(fields[6], 0, 1000)
  local b = M.integer(fields[7], 0, 1000)
  local name = M.decodeName(fields[8])
  local count = M.integer(fields[9], 0, maxStops)
  if not tag or not target or not player or not r or not g or not b
    or name == nil or not count then
    return nil, "native line envelope contains invalid scalar fields"
  end

  local stops, encodedStops, totalAlternatives = {}, {}, 0
  if count == 0 then
    if fields[10] ~= "" then return nil, "empty native line envelope contains stop bytes" end
  else
    for encoded in fields[10]:gmatch("[^;]+") do
      local groupText, stationText, terminalText, alternativeText
      if version == "L1" then
        groupText, stationText, terminalText =
          encoded:match("^(-?%d+),(-?%d+),(-?%d+)$")
        alternativeText = ""
      else
        groupText, stationText, terminalText, alternativeText =
          encoded:match("^(-?%d+),(-?%d+),(-?%d+),(.*)$")
      end
      local stationGroup = M.integer(groupText, 0, 2147483647)
      local station = M.integer(stationText, 0, 4095)
      local terminal = M.integer(terminalText, 0, 4095)
      local alternate = alternatives(
        alternativeText or "", maxAlternativeTerminals, version)
      if not stationGroup or not station or not terminal or not alternate then
        return nil, "native line envelope contains an invalid stop"
      end
      totalAlternatives = totalAlternatives + #alternate
      if totalAlternatives > 1024 then
        return nil, "native line envelope contains too many alternative terminals"
      end
      stops[#stops + 1] = {
        stationGroupLocalId = stationGroup,
        station = station,
        terminal = terminal,
        alternativeTerminals = alternate,
      }
      encodedStops[#encodedStops + 1] = encoded
    end
    if #stops ~= count or table.concat(encodedStops, ";") ~= fields[10] then
      return nil, "native line envelope stop count mismatch"
    end
  end
  if tag == 3 and (target ~= -1 or player < 0) then
    return nil, "native CreateLine envelope has invalid identity fields"
  elseif (tag == 4 or tag == 5 or tag == 28 or tag == 29) and target < 0 then
    return nil, "native line mutation envelope has no target"
  end
  return {
    tag = tag,
    targetLocalId = target,
    nativePlayerId = player,
    name = name,
    color = { r = r, g = g, b = b },
    stops = stops,
  }
end

return M
