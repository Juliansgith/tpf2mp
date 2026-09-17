-- Typed value codec for a construction's parameter set (see
-- docs/SOCIAL_CHANNEL.md). Three parts of the social channel need it and none
-- of them owns it: the capture encodes the builder's parameter table out of
-- engine userdata, the wire codec validates the string that arrives, and the
-- native renderer decodes it back into a table for the preview proposal. It
-- therefore stands alone and depends on nothing.
--
-- The format is length-prefixed and typed: "t"/"f" for booleans, "n<number>:"
-- for numbers, "s<hex length>:<hex>" for strings and "m<count>:" followed by
-- alternating keys and values for tables. Decoding never calls load or eval,
-- so a parameter set from the other peer is data and can never be executed.
-- Keys are sorted, so an unchanged parameter set encodes identically every
-- frame and the five-hertz publisher stays quiet. Every limit is applied
-- during traversal, before a wire body is built, which also bounds cyclic or
-- hostile input.
local M = {}

M.MAX_BYTES = 4096
M.MAX_NODES = 512
M.MAX_KEYS = 128
M.MAX_DEPTH = 8
M.MAX_STRING = 512

local MAX_NUMBER = 2 ^ 53 - 1

local function finite(value)
  if type(value) ~= "number" or value ~= value then return false end
  return math.abs(value) <= MAX_NUMBER
end

function M.encode(value)
  local seen, count, bytes = {}, 0, 0
  local function put(text)
    bytes = bytes + #text
    assert(bytes <= M.MAX_BYTES)
    return text
  end
  local function visit(item, depth)
    count = count + 1
    assert(count <= M.MAX_NODES and depth <= M.MAX_DEPTH)
    local kind = type(item)
    if kind == "number" then
      assert(finite(item))
      return put("n" .. string.format("%.17g", item) .. ":")
    end
    if kind == "boolean" then
      if item then return put("t") end
      return put("f")
    end
    if kind == "string" then
      assert(#item <= M.MAX_STRING)
      local hex = item:gsub(".", function(char) return string.format("%02x", char:byte()) end)
      return put("s" .. #hex .. ":" .. hex)
    end
    assert((kind == "table" or kind == "userdata") and not seen[item])
    seen[item] = true
    local keys = {}
    for key in pairs(item) do
      assert(type(key) == "string" or type(key) == "number")
      keys[#keys + 1] = key
      assert(#keys <= M.MAX_KEYS)
    end
    table.sort(keys, function(left, right)
      if type(left) ~= type(right) then return type(left) < type(right) end
      return left < right
    end)
    local parts = { put("m" .. #keys .. ":") }
    for _, key in ipairs(keys) do
      parts[#parts + 1] = visit(key, depth + 1)
      parts[#parts + 1] = visit(item[key], depth + 1)
    end
    seen[item] = nil
    return table.concat(parts)
  end
  local ok, result = pcall(visit, value, 0)
  if ok then return result end
  return nil
end

function M.decode(text)
  if type(text) ~= "string" or #text < 1 or #text > M.MAX_BYTES then return nil end
  local at, count = 1, 0
  local function visit(depth)
    count = count + 1
    assert(count <= M.MAX_NODES and depth <= M.MAX_DEPTH)
    local tag = text:sub(at, at)
    at = at + 1
    if tag == "t" then return true end
    if tag == "f" then return false end
    local finish = text:find(":", at, true)
    assert(finish and finish - at <= 32)
    local number = tonumber(text:sub(at, finish - 1))
    at = finish + 1
    assert(finite(number))
    if tag == "n" then return number end
    assert(number >= 0 and number == math.floor(number))
    if tag == "s" then
      assert(number <= M.MAX_STRING * 2 and number % 2 == 0 and at + number - 1 <= #text)
      local hex = text:sub(at, at + number - 1)
      at = at + number
      assert(not hex:find("[^%da-f]"))
      return (hex:gsub("..", function(pair) return string.char(tonumber(pair, 16)) end))
    end
    assert(tag == "m" and number <= M.MAX_KEYS)
    local result = {}
    for _ = 1, number do
      local key = visit(depth + 1)
      assert(type(key) == "number" or type(key) == "string")
      assert(result[key] == nil)
      result[key] = visit(depth + 1)
    end
    return result
  end
  local ok, value = pcall(visit, 0)
  if ok and at == #text + 1 then return value end
  return nil
end

return M
