local util = require "tpf2_mp/util"
local json = require "tpf2_mp/json"
local hash = require "tpf2_mp/hash"

local M = {}

local function slash(path)
  return tostring(path or "."):gsub("\\", "/"):gsub("/+$", "")
end

local function fileName(seq)
  return string.format("%012d.json", seq)
end

local function readFile(path)
  local file, err = io.open(path, "rb")
  if not file then return nil, err end
  local data = file:read("*a")
  file:close()
  return data
end

local function fileExists(path)
  local file = io.open(path, "rb")
  if not file then return false end
  file:close()
  return true
end

local function writeAtomic(path, data)
  -- Transport Fever's game-script Lua exposes io.open but intentionally omits
  -- os.remove/os.rename. Use the stronger temp+rename path in the standalone
  -- Lua test/runtime and a close-before-publish direct write in the game.
  if not (os and type(os.remove) == "function" and type(os.rename) == "function") then
    local direct, directErr = io.open(path, "wb")
    if not direct then return false, directErr end
    local directOk, directWriteErr = direct:write(data)
    direct:close()
    if not directOk then return false, directWriteErr end
    return true
  end
  local temp = path .. ".tmp"
  local file, err = io.open(temp, "wb")
  if not file then return false, err end
  local ok, writeErr = file:write(data)
  file:close()
  if not ok then os.remove(temp); return false, writeErr end
  os.remove(path)
  local renamed, renameErr = os.rename(temp, path)
  if not renamed then os.remove(temp); return false, renameErr end
  return true
end

function M.newState(config)
  return {
    protocol = config.protocol or 1,
    root = slash(config.root),
    peerId = tostring(config.peerId or "player1"),
    sessionId = tostring(config.sessionId or "local-dev"),
    nextOutSeq = 1,
    nextInSeq = 1,
    emitted = 0,
    received = 0,
    lastError = nil,
    lastInboundKind = nil,
    companion = {
      available = false,
      status = "not-running",
    },
  }
end

function M.reconfigure(state, config, resetOnIdentityChange)
  local nextRoot = slash(config.root or state.root)
  local nextPeer = tostring(config.peerId or state.peerId)
  local nextSession = tostring(config.sessionId or state.sessionId)
  local changed = nextRoot ~= slash(state.root)
    or nextPeer ~= tostring(state.peerId)
    or nextSession ~= tostring(state.sessionId)
  state.protocol = config.protocol or state.protocol or 1
  state.root = nextRoot
  state.peerId = nextPeer
  state.sessionId = nextSession
  if changed and resetOnIdentityChange == true then
    -- A numbered file queue is scoped to one (root, session, peer) tuple.
    -- Carrying cursors from a saved/previous session would skip the new
    -- inbox and create a permanent deadlock after recovery or shared-save
    -- startup.  The new root must be empty; the launcher enforces that.
    state.nextOutSeq = 1
    state.nextInSeq = 1
    state.emitted = 0
    state.received = 0
    state.lastError = nil
    state.lastInboundKind = nil
    state.companion = { available = false, status = "not-running" }
  end
  return changed
end

local function signed(message)
  local core = util.deepCopy(message)
  core.checksum = nil
  message.checksum = hash.value(core)
  return message
end

function M.verify(message)
  if type(message) ~= "table" or type(message.checksum) ~= "string" then return false, "missing checksum" end
  local expected = message.checksum
  local core = util.deepCopy(message)
  core.checksum = nil
  local actual = hash.value(core)
  if expected ~= actual then return false, "checksum mismatch: expected " .. expected .. ", calculated " .. actual end
  return true
end

function M.emit(state, kind, payload, tick)
  local seq = state.nextOutSeq
  local path = state.root .. "/game_outbox/" .. fileName(seq)
  -- Fresh disposable worlds use a fresh script state but often reuse the
  -- same bridge directory. Preserve the numbered queue's immutability rather
  -- than overwriting a prior run that used the same session identifier.
  while fileExists(path) do
    seq = seq + 1
    path = state.root .. "/game_outbox/" .. fileName(seq)
  end
  state.nextOutSeq = seq
  local message = signed({
    protocol = state.protocol,
    session = state.sessionId,
    peer = state.peerId,
    local_seq = seq,
    tick = tonumber(tick) or 0,
    kind = tostring(kind),
    payload = util.deepCopy(payload or {}),
  })
  local ok, err = writeAtomic(path, json.encode(message) .. "\n")
  if not ok then state.lastError = "outbox write failed: " .. tostring(err); return false, state.lastError end
  state.nextOutSeq = seq + 1
  state.emitted = (state.emitted or 0) + 1
  state.lastError = nil
  return true, message
end

function M.poll(state, limit)
  local messages = {}
  limit = limit or 8
  while #messages < limit do
    local seq = state.nextInSeq
    local path = state.root .. "/game_inbox/" .. fileName(seq)
    local raw, err = readFile(path)
    if not raw then
      if err and not tostring(err):match("No such file") and not tostring(err):match("cannot find") then
        state.lastError = "inbox read failed: " .. tostring(err)
      end
      break
    end
    local ok, message = pcall(json.decode, raw)
    if not ok then state.lastError = "invalid inbox JSON at " .. seq .. ": " .. tostring(message); break end
    local valid, verifyErr = M.verify(message)
    if not valid then state.lastError = "invalid inbox message at " .. seq .. ": " .. verifyErr; break end
    if tonumber(message.protocol) ~= tonumber(state.protocol) then state.lastError = "protocol mismatch"; break end
    if tostring(message.session) ~= tostring(state.sessionId) then state.lastError = "session mismatch"; break end
    if tonumber(message.seq) ~= seq then state.lastError = "inbox sequence mismatch"; break end
    messages[#messages + 1] = message
    state.nextInSeq = seq + 1
    state.received = (state.received or 0) + 1
    state.lastInboundKind = message.kind
    state.lastError = nil
  end
  return messages
end

function M.pollCompanionStatus(state)
  local path = state.root .. "/companion_state/companion_status.json"
  local raw, readErr = readFile(path)
  if not raw then
    state.companion = {
      available = false,
      status = "not-running",
      error = readErr and tostring(readErr) or nil,
    }
    return state.companion
  end
  local decoded, value = pcall(json.decode, raw)
  if not decoded or type(value) ~= "table" then
    state.companion = {
      available = false,
      status = "invalid-status",
      error = decoded and "status is not an object" or tostring(value),
    }
    return state.companion
  end
  if tostring(value.session or "") ~= tostring(state.sessionId)
    or tostring(value.peer or "") ~= tostring(state.peerId) then
    state.companion = {
      available = false,
      status = "identity-mismatch",
      error = "companion status belongs to another peer or session",
      observedPeer = value.peer,
      observedSession = value.session,
    }
    return state.companion
  end
  value.available = value.status ~= "stopped"
  state.companion = value
  return state.companion
end

function M.pathForOutSeq(state, seq)
  return state.root .. "/game_outbox/" .. fileName(seq)
end

return M
