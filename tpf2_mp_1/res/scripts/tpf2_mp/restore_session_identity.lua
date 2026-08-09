local hash = require "tpf2_mp/hash"

local M = {}

local MAX_EXACT_INTEGER = 9007199254740991
local MAX_SESSION_LENGTH = 64

local function validSession(value)
  return type(value) == "string" and #value >= 1 and #value <= MAX_SESSION_LENGTH
    and value:match("^[%w][%w_.%-]*$") ~= nil
end

function M.derive(sourceSession, boundarySeq)
  if not validSession(sourceSession) then
    return nil, "restore source session is invalid"
  end
  if type(boundarySeq) ~= "number" or boundarySeq ~= math.floor(boundarySeq)
      or boundarySeq < 1 or boundarySeq > MAX_EXACT_INTEGER then
    return nil, "restore boundary is invalid"
  end
  local boundary = string.format("%.0f", boundarySeq)
  local readable = sourceSession .. "-r" .. boundary
  if #readable <= MAX_SESSION_LENGTH then return readable end
  local token = hash.text("resume:" .. sourceSession .. ":" .. boundary)
    .. hash.text("source:" .. sourceSession)
  local suffix = "-h" .. token .. "-r" .. boundary
  local prefixLength = MAX_SESSION_LENGTH - #suffix
  if prefixLength < 1 then
    return nil, "restore boundary cannot fit a bounded session identity"
  end
  return sourceSession:sub(1, prefixLength) .. suffix
end

return M
