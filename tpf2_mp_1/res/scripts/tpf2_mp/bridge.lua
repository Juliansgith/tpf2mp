local util = require "tpf2_mp/util"
local json = require "tpf2_mp/json"
local hash = require "tpf2_mp/hash"

local M = {}
local MAX_REPLACEABLE_BACKLOG = 256
local REPLACEABLE_KINDS = {
  clock_health = true,
  vehicle_sync = true,
}

local function nativeFunction(name)
  local value = rawget(_G, name)
  return type(value) == "function" and value or nil
end

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
    coalesced = 0,
    coalescedByKind = {},
    coalesceEphemeral = config.startNetwork == true,
    received = 0,
    lastError = nil,
    lastInboundKind = nil,
    nativeTransport = { active = false, configureAttempts = 0 },
    companion = {
      available = false,
      status = "not-running",
    },
  }
end

local function configureNative(state)
  state.nativeTransport = type(state.nativeTransport) == "table"
    and state.nativeTransport or { active = false, configureAttempts = 0 }
  local transport = state.nativeTransport
  local configure = nativeFunction("tpf2mp_native_bridge_configure")
  local emit = nativeFunction("tpf2mp_native_bridge_emit")
  local take = nativeFunction("tpf2mp_native_bridge_take")
  if not (configure and emit and take) then
    transport.active = false
    transport.reason = "native async bridge is unavailable"
    return false, transport.reason
  end
  local processMarker = tostring(configure) .. ":" .. tostring(emit) .. ":" .. tostring(take)
  if transport.active == true and transport.root == state.root
    and transport.processMarker == processMarker then return true end
  transport.configureAttempts = math.max(0,
    util.integer(transport.configureAttempts, 0)) + 1
  local called, response = pcall(configure, state.root,
    tostring(state.nextOutSeq), tostring(state.nextInSeq))
  response = tostring(response or "")
  local effective = called and tonumber(response:match("^A1|(%d+)$")) or nil
  if not effective then
    transport.active = false
    transport.reason = called and response:gsub("^F1|", "") or tostring(response)
    return false, transport.reason
  end
  state.nextOutSeq = math.max(1, util.integer(effective, state.nextOutSeq))
  transport.active = true
  transport.root = state.root
  transport.processMarker = processMarker
  transport.configuredOutSeq = state.nextOutSeq
  transport.configuredInSeq = state.nextInSeq
  transport.reason = nil
  return true
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
    state.coalesced = 0
    state.coalescedByKind = {}
    state.received = 0
    state.lastError = nil
    state.lastInboundKind = nil
    state.companion = { available = false, status = "not-running" }
    state.nativeTransport = { active = false, configureAttempts = 0 }
  end
  state.coalesced = math.max(0, util.integer(state.coalesced, 0))
  state.coalescedByKind = type(state.coalescedByKind) == "table"
    and state.coalescedByKind or {}
  state.coalesceEphemeral = config.startNetwork == true
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

local function companionConnected(state)
  local companion = state.companion
  if type(companion) ~= "table" or companion.connected ~= true then return false end
  local role, status = tostring(companion.role or ""), tostring(companion.status or "")
  if role == "host" then return status == "running" end
  if role == "client" then return status == "connected" end
  return status == "running" or status == "connected"
end

local function replaceableBacklog(state)
  local cursor = type(state.companion) == "table"
    and math.max(0, util.integer(state.companion.outboxCursor, 0)) or 0
  return math.max(0, math.max(1, util.integer(state.nextOutSeq, 1)) - 1 - cursor)
end

local function coalesceReplaceable(state, kind)
  if state.coalesceEphemeral ~= true or REPLACEABLE_KINDS[kind] ~= true then return false end
  if companionConnected(state) and replaceableBacklog(state) < MAX_REPLACEABLE_BACKLOG then
    return false
  end
  state.coalesced = math.max(0, util.integer(state.coalesced, 0)) + 1
  state.coalescedByKind = type(state.coalescedByKind) == "table"
    and state.coalescedByKind or {}
  state.coalescedByKind[kind] = math.max(
    0, util.integer(state.coalescedByKind[kind], 0)) + 1
  state.lastError = nil
  return true
end

function M.emit(state, kind, payload, tick)
  kind = tostring(kind)
  if coalesceReplaceable(state, kind) then
    return false, "replaceable " .. kind .. " coalesced while companion is unavailable"
  end
  local nativeActive = configureNative(state)
  local seq = state.nextOutSeq
  local path = state.root .. "/game_outbox/" .. fileName(seq)
  -- Fresh disposable worlds use a fresh script state but often reuse the
  -- same bridge directory. Preserve the numbered queue's immutability rather
  -- than overwriting a prior run that used the same session identifier.
  if not nativeActive then
    while fileExists(path) do
      seq = seq + 1
      path = state.root .. "/game_outbox/" .. fileName(seq)
    end
  end
  state.nextOutSeq = seq
  local message = signed({
    protocol = state.protocol,
    session = state.sessionId,
    peer = state.peerId,
    local_seq = seq,
    tick = tonumber(tick) or 0,
    kind = kind,
    payload = util.deepCopy(payload or {}),
  })
  local encoded = json.encode(message) .. "\n"
  local ok, err
  if nativeActive then
    local called, response = pcall(
      nativeFunction("tpf2mp_native_bridge_emit"), tostring(seq), encoded)
    response = tostring(response or "")
    ok = called and response == "A1"
    if not ok then
      err = called and response:gsub("^F1|", "") or response
    end
  else
    ok, err = writeAtomic(path, encoded)
  end
  if not ok then state.lastError = "outbox write failed: " .. tostring(err); return false, state.lastError end
  state.nextOutSeq = seq + 1
  state.emitted = (state.emitted or 0) + 1
  state.lastError = nil
  return true, message
end

function M.poll(state, limit)
  local messages = {}
  limit = limit or 8
  local nativeActive = configureNative(state)
  while #messages < limit do
    local seq = state.nextInSeq
    local raw, err
    if nativeActive then
      local called, response = pcall(nativeFunction("tpf2mp_native_bridge_take"))
      if not called then err = tostring(response)
      elseif response ~= nil then
        local observed, payload = tostring(response):match("^I1|(%d+)|(.*)$")
        if tonumber(observed) ~= seq then
          state.lastError = "native inbox sequence mismatch: expected "
            .. tostring(seq) .. ", observed " .. tostring(observed)
          break
        end
        raw = payload
      end
    else
      local path = state.root .. "/game_inbox/" .. fileName(seq)
      raw, err = readFile(path)
    end
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

function M.nativeStatus(state)
  local active = configureNative(state)
  if not active then return util.deepCopy(state.nativeTransport or {}) end
  local status = nativeFunction("tpf2mp_native_bridge_status")
  if not status then return util.deepCopy(state.nativeTransport or {}) end
  local called, raw = pcall(status)
  if not called then return { active = true, error = tostring(raw) } end
  local decoded, value = pcall(json.decode, tostring(raw or ""))
  if not decoded or type(value) ~= "table" then
    return { active = true, error = "native async bridge returned invalid status" }
  end
  value.active = true
  return value
end

function M.isNative(state)
  return configureNative(state) == true
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
  local role, status = tostring(value.role or ""), tostring(value.status or "")
  value.available = value.connected == true
    and ((role == "host" and status == "running")
      or (role == "client" and status == "connected"))
  state.companion = value
  return state.companion
end

function M.pathForOutSeq(state, seq)
  return state.root .. "/game_outbox/" .. fileName(seq)
end

return M
