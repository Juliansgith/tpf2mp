-- Wire and file layer of the social channel (see docs/SOCIAL_CHANNEL.md):
-- the two atomic JSON documents under the per-peer bridge root, and the exact
-- bounded item shapes that cross them. Both peers are trusted, yet every
-- received field is still checked here: an item that fails any check is
-- dropped, never repaired. Nothing in this module touches the GUI or the game.
local preview = require "tpf2_mp/gui_social_preview"

local M = {}

M.SCHEMA_VERSION = 1
M.MAX_TEXT = 240
M.MAX_FILE = 128
M.MAX_OUT_ITEMS = 32
M.MAX_IN_ITEMS = 64
local MAX_DOCUMENT_BYTES = 262144

M.PING_LABELS = {
  wait = "wait", ready = "ready", look = "look here", pause = "pause please",
}

-- Chat crosses a process boundary and lands in a GUI label, so it is reduced
-- to printable ASCII and bounded before it is ever stored, shown or sent.
function M.sanitize(text)
  if type(text) ~= "string" then return nil end
  if #text > M.MAX_TEXT * 4 then text = text:sub(1, M.MAX_TEXT * 4) end
  local cleaned = text:gsub("[^\32-\126]", " "):gsub("^%s+", ""):gsub("%s+$", "")
  if cleaned == "" then return nil end
  if #cleaned > M.MAX_TEXT then cleaned = cleaned:sub(1, M.MAX_TEXT) end
  return cleaned
end

function M.read(path)
  local file = io.open(path, "rb")
  if not file then return nil end
  local body = file:read(MAX_DOCUMENT_BYTES)
  file:close()
  return body
end

-- A reader must never see a half-written file: write beside the target and
-- rename over it. Windows refuses a rename onto an existing name, so the
-- second attempt removes the target first. The game's script Lua exposes
-- io.open but omits os.rename/os.remove (see bridge.lua), so there the body
-- is written directly in one call; readers ignore a file that fails to parse.
function M.write(path, body)
  if not (os and type(os.remove) == "function" and type(os.rename) == "function") then
    local direct = io.open(path, "wb")
    if not direct then return false end
    local ok = direct:write(body)
    direct:close()
    return ok ~= nil
  end
  local temporary = path .. ".tmp"
  local file = io.open(temporary, "wb")
  if not file then return false end
  local written = file:write(body)
  local closed = file:close()
  if not written or not closed then
    os.remove(temporary)
    return false
  end
  if os.rename(temporary, path) then return true end
  os.remove(path)
  if os.rename(temporary, path) then return true end
  os.remove(temporary)
  return false
end

local function validCurves(body)
  if type(body.curves) ~= "table" then return nil end
  local count = #body.curves
  if count < 1 or count > preview.MAX_CURVES then return nil end
  local curves = {}
  for index = 1, count do
    local source = body.curves[index]
    if type(source) ~= "table" or #source ~= 8 then return nil end
    local curve = {}
    for field = 1, 8 do
      curve[field] = preview.finite(source[field])
      if not curve[field] then return nil end
    end
    curves[index] = curve
  end
  return curves
end

local function validConstruction(body)
  if type(body.file) ~= "string" or #body.file > M.MAX_FILE then return nil end
  if not body.file:match("^[%w_./%-]+%.con$") then return nil end
  if type(body.transf) ~= "table" or #body.transf ~= 16 then return nil end
  local transf = {}
  for index = 1, 16 do
    transf[index] = preview.finite(body.transf[index])
    if not transf[index] then return nil end
  end
  local x, y, z = preview.finite(body.x), preview.finite(body.y), preview.finite(body.z)
  if not x or not y or not z then return nil end
  return { kind = "construction", invalid = body.invalid == true,
    file = body.file, x = x, y = y, z = z, transf = transf }
end

-- Returns a fresh body holding exactly the contract's key set, or nil.
function M.validBody(channel, body)
  if type(body) ~= "table" then return nil end
  if channel == "chat" then
    local text = M.sanitize(body.text)
    if not text then return nil end
    return { text = text }
  end
  if channel == "ping" then
    if M.PING_LABELS[body.kind] == nil then return nil end
    local result = { kind = body.kind }
    if body.kind == "look" then
      local x, y = preview.finite(body.x), preview.finite(body.y)
      if x and y then result.x, result.y = x, y end
    end
    return result
  end
  if channel ~= "preview" then return nil end
  if body.kind == "off" then return { kind = "off" } end
  if body.kind == "road" or body.kind == "rail" then
    local curves = validCurves(body)
    if not curves then return nil end
    return { kind = body.kind, invalid = body.invalid == true, curves = curves }
  end
  if body.kind ~= "construction" then return nil end
  return validConstruction(body)
end

-- Yields every acceptable item of a decoded social_in.json in file order.
-- `peerId` is this peer: its own items are never echoed back to it.
function M.eachIncoming(document, peerId, seen, handler)
  if type(document) ~= "table" or document.schemaVersion ~= M.SCHEMA_VERSION then return end
  if type(document.items) ~= "table" then return end
  for index = 1, math.min(#document.items, M.MAX_IN_ITEMS) do
    local item = document.items[index]
    if type(item) == "table" then
      local id = preview.finite(item.id, 1e15)
      local origin = item.peer
      local known = (origin == "player1" or origin == "player2") and origin ~= peerId
      if id and id == math.floor(id) and known
        and (seen[origin] == nil or id > seen[origin]) then
        seen[origin] = id
        local body = M.validBody(item.channel, item.body)
        if body then handler(origin, item.channel, body) end
      end
    end
  end
end

return M
