-- Social channel inside the game GUI state: chat, pings and build previews.
-- See docs/SOCIAL_CHANNEL.md. Registers itself as guiView.social so the game
-- script needs no new local (Lua 5.1 caps a chunk at 200 locals).
--
-- Advisory only. Nothing here enters an intent, a commit, an event record, a
-- checkpoint digest or the audit replay, and nothing here calls api.cmd. The
-- two JSON files under the per-peer bridge root are the whole transport: the
-- companion forwards social_out.json and fills social_in.json.
local guiView = require "tpf2_mp/gui_view"
local json = require "tpf2_mp/json"
local runtimeConfig = require "tpf2_mp/runtime_config"
local preview = require "tpf2_mp/gui_social_preview"
local codec = require "tpf2_mp/gui_social_codec"

local M = {}

local POLL_SECONDS = 0.2
local KEEPALIVE_SECONDS = 1
local CANCEL_PROBE_SECONDS = 0.3
local PREVIEW_STALE_SECONDS = 4
local MARKER_SECONDS = 10
local CHAT_LINES = 8
local MAX_QUEUED = 16
local BUILDER_TOOLS = {
  streetBuilder = true, trackBuilder = true, constructionBuilder = true,
}
local PING_LABELS = codec.PING_LABELS
local PING_BUTTONS = {
  { "Wait", "wait" }, { "Ready", "ready" },
  { "Look here", "look" }, { "Pause please", "pause" },
}
local PEER_TINT = {
  player1 = { 0.29, 0.75, 0.66 }, player2 = { 0.92, 0.71, 0.28 },
}
local INVALID_TINT = { 0.88, 0.34, 0.30 }
local EMPTY_HINT = "No messages yet. Chat, pings and previews are advisory only."

local reader
local state

-- The companion keeps the highest id it has forwarded per origin peer in
-- memory and drops anything lower as stale, so a reloaded GUI state must
-- never restart its counter at zero. Seeding from the wall clock keeps every
-- later state's ids above every earlier state's, with room for a hundred
-- items per second.
local function seedId()
  local ok, value = pcall(os.time)
  if ok and type(value) == "number" then return math.floor(value) * 100 end
  return 0
end

local function reset(root, peerId, sessionId)
  state = {
    root = root, peerId = peerId, sessionId = sessionId,
    enabled = false, dropped = 0,
    outSeq = 0, nextId = seedId(), outItems = {}, queue = {},
    previewSignature = nil, previewSent = false,
    localPreview = nil, eventAt = nil,
    pollAt = nil, controlsAt = nil, writeAt = nil, chatAt = nil,
    inRaw = nil, seen = {},
    chat = {}, remote = {}, markers = {}, drawn = {},
    chatView = (state or {}).chatView, input = (state or {}).input,
  }
end

reset(nil, nil, nil)

-- Throttle source. os.clock() measures processor time, which is what a GUI
-- frame budget wants and is what the rest of the mod throttles on. It is a
-- module field so tests can drive the five-hertz poll deterministically
-- instead of burning processor time between two synthetic frames.
M.clock = os.clock

local function clock()
  local ok, value = pcall(M.clock)
  if ok and type(value) == "number" then return value end
  return 0
end

local function wall()
  local ok, value = pcall(os.time)
  if ok and type(value) == "number" then return math.floor(value) end
  return 0
end

local function peerLabel(peerId)
  if peerId == "player1" then return "Player 1" end
  if peerId == "player2" then return "Player 2" end
  if type(peerId) == "string" and peerId ~= "" then return peerId end
  return "Player"
end

local function socialPath(name)
  return state.root .. "/companion_state/" .. name
end

local function age(seconds)
  if seconds < 2 then return "just now" end
  if seconds < 60 then return string.format("%ds ago", seconds) end
  if seconds < 3600 then return string.format("%dm ago", math.floor(seconds / 60)) end
  return "earlier"
end

local function renderChat()
  local view = state.chatView
  if type(view) ~= "table" and type(view) ~= "userdata" then return end
  state.chatAt = clock()
  local now, lines = wall(), {}
  if #state.chat == 0 then lines[1] = EMPTY_HINT end
  for index = math.max(1, #state.chat - CHAT_LINES + 1), #state.chat do
    local entry = state.chat[index]
    lines[#lines + 1] = entry.text .. "  (" .. age(math.max(0, now - entry.at)) .. ")"
  end
  if state.dropped > 0 then
    lines[#lines + 1] = string.format("(%d social message(s) dropped by the companion)",
      state.dropped)
  end
  pcall(function() view:setText(table.concat(lines, "\n")) end)
end

local function addLine(text)
  state.chat[#state.chat + 1] = { text = text, at = wall() }
  while #state.chat > CHAT_LINES do table.remove(state.chat, 1) end
  renderChat()
end

local function pushNotice(gui, kind, text)
  local notices = guiView.notices
  if type(notices) ~= "table" or type(notices.push) ~= "function" then return end
  pcall(notices.push, gui, { kind = kind, text = text, ttl = 8 })
end

local function enqueue(channel, body)
  if state.enabled ~= true or #state.queue >= MAX_QUEUED then return false end
  state.queue[#state.queue + 1] = { channel = channel, body = body }
  return true
end

-- "Look here" prefers the ground the mouse is over and falls back to what the
-- camera is looking at; with neither, the ping still goes out without a place.
local function groundPosition()
  local helpers = api and api.gui and api.gui.util
  if type(helpers) ~= "table" then return nil end
  local ok, x, y = pcall(function()
    local position = helpers.getGameUI():getMainRendererComponent():getTerrainPos()
    local px, py = position.x, position.y
    if px == nil then px, py = position[1], position[2] end
    return px, py
  end)
  if ok then
    x, y = preview.finite(x), preview.finite(y)
    if x and y then return x, y end
  end
  local okCamera, cx, cy = pcall(function()
    local controller = helpers.getById("mainView"):getCameraController()
    local position = controller:getCameraData()
    local px, py = position.x, position.y
    if px == nil then px, py = position[1], position[2] end
    return px, py
  end)
  if okCamera then
    cx, cy = preview.finite(cx), preview.finite(cy)
    if cx and cy then return cx, cy end
  end
  return nil
end

local function sendChat(gui, provided)
  local text = codec.sanitize(provided)
  if not text then
    local view = state.input
    if type(view) == "table" or type(view) == "userdata" then
      local ok, value = pcall(function() return view:getText() end)
      if ok then text = codec.sanitize(value) end
    end
  end
  if not text then return end
  if not enqueue("chat", { text = text }) then return end
  local view = state.input
  if type(view) == "table" or type(view) == "userdata" then
    if not pcall(function() view:setText("", false) end) then
      pcall(function() view:setText("") end)
    end
  end
  addLine(peerLabel(state.peerId) .. ": " .. text)
end

local function sendPing(gui, kind)
  local body = { kind = kind }
  if kind == "look" then
    local x, y = groundPosition()
    if x and y then body.x, body.y = x, y end
  end
  if not enqueue("ping", body) then return end
  addLine(peerLabel(state.peerId) .. ": " .. PING_LABELS[kind])
end

local function pushOut(channel, body)
  state.nextId = state.nextId + 1
  if channel == "preview" then
    for index = #state.outItems, 1, -1 do
      if state.outItems[index].channel == "preview" then table.remove(state.outItems, index) end
    end
  end
  state.outItems[#state.outItems + 1] = {
    id = state.nextId, peer = state.peerId, channel = channel, at = wall(), body = body,
  }
  while #state.outItems > codec.MAX_OUT_ITEMS do table.remove(state.outItems, 1) end
end

-- The ring keeps only the newest preview; an unchanged preview is not
-- republished, and the very first "off" is suppressed so an idle peer never
-- writes a preview item at all.
local function refreshPreview()
  local body, signature = state.localPreview, "off"
  if body then
    local ok, encoded = pcall(json.encode, body)
    if not ok then return false end
    signature = encoded
  end
  if signature == state.previewSignature then return false end
  state.previewSignature = signature
  if not body then
    if state.previewSent ~= true then return false end
    state.previewSent = false
    pushOut("preview", { kind = "off" })
    return true
  end
  state.previewSent = true
  pushOut("preview", body)
  return true
end

local function publish()
  local changed = refreshPreview()
  while #state.queue > 0 do
    local entry = table.remove(state.queue, 1)
    pushOut(entry.channel, entry.body)
    changed = true
  end
  if #state.outItems == 0 then return end
  local now = clock()
  if not changed and state.writeAt and now - state.writeAt < KEEPALIVE_SECONDS then return end
  state.outSeq = state.outSeq + 1
  local ok, body = pcall(json.encode, {
    schemaVersion = codec.SCHEMA_VERSION, session = state.sessionId,
    peer = state.peerId, seq = state.outSeq, items = state.outItems,
  })
  if not ok then return end
  if codec.write(socialPath("social_out.json"), body .. "\n") then state.writeAt = now end
end

local function accept(gui, peer, channel, body)
  local label = peerLabel(peer)
  if channel == "chat" then
    local text = label .. ": " .. body.text
    addLine(text)
    pushNotice(gui, "chat", text)
    return
  end
  if channel == "ping" then
    local text = label .. ": " .. PING_LABELS[body.kind]
    addLine(text)
    pushNotice(gui, "ping", text)
    if body.kind == "look" and body.x and body.y then
      state.markers[peer] = { x = body.x, y = body.y, at = clock() }
    end
    return
  end
  if body.kind == "off" then
    state.remote[peer] = nil
    return
  end
  local ok, signature = pcall(json.encode, body)
  if not ok then return end
  state.remote[peer] = { body = body, at = clock(), signature = signature }
end

-- The whole file is re-read at five hertz; an unchanged byte string is not
-- re-parsed, and the highest processed id is kept per origin peer.
local function consume(gui)
  local raw = codec.read(socialPath("social_in.json"))
  if raw == state.inRaw then return end
  state.inRaw = raw
  if type(raw) ~= "string" then return end
  local ok, document = pcall(json.decode, raw)
  if not ok then return end
  codec.eachIncoming(document, state.peerId, state.seen, function(peer, channel, body)
    accept(gui, peer, channel, body)
  end)
end

local function setZone(key, zone)
  local ok = pcall(function() game.interface.setZone(key, zone) end)
  return ok
end

local function zonesAvailable()
  return type(game) == "table" and type(game.interface) == "table"
    and type(game.interface.setZone) == "function"
end

local function clearZones()
  if not zonesAvailable() then
    state.drawn = {}
    return
  end
  for key in pairs(state.drawn) do setZone(key, nil) end
  state.drawn = {}
end

local function tint(peer, invalid)
  local colour = PEER_TINT[peer] or { 0.80, 0.80, 0.80 }
  if invalid == true then colour = INVALID_TINT end
  return { colour[1], colour[2], colour[3], 0.8 }
end

local function collectZones(now)
  local wanted = {}
  for peer, entry in pairs(state.remote) do
    if now - entry.at > PREVIEW_STALE_SECONDS then
      state.remote[peer] = nil
    else
      local body = entry.body
      local colour = tint(peer, body.invalid)
      if body.kind == "construction" then
        wanted["tpf2mp_preview_" .. peer .. "_1"] = {
          polygon = preview.quad(body), colour = colour, signature = entry.signature,
        }
      else
        local width = 3
        if body.kind == "rail" then width = 1.5 end
        for index, curve in ipairs(body.curves) do
          wanted["tpf2mp_preview_" .. peer .. "_" .. index] = {
            polygon = preview.polygon(curve, width), colour = colour,
            signature = entry.signature .. "#" .. index,
          }
        end
      end
    end
  end
  for peer, marker in pairs(state.markers) do
    if now - marker.at > MARKER_SECONDS then
      state.markers[peer] = nil
    else
      -- One pulse per second so the ring reads as a live call for attention.
      local radius = 10 + 8 * ((now - marker.at) % 1)
      wanted["tpf2mp_marker_" .. peer] = {
        polygon = preview.ring(marker.x, marker.y, radius, 2.5),
        colour = tint(peer, false),
        signature = string.format("%s:%.1f", peer, radius),
      }
    end
  end
  return wanted
end

local function renderZones()
  if not zonesAvailable() then return end
  local wanted = collectZones(clock())
  for key in pairs(state.drawn) do
    if not wanted[key] then
      setZone(key, nil)
      state.drawn[key] = nil
    end
  end
  for key, zone in pairs(wanted) do
    if zone.polygon and state.drawn[key] ~= zone.signature then
      if setZone(key, { polygon = zone.polygon, draw = true, drawColor = zone.colour }) then
        state.drawn[key] = zone.signature
      end
    end
  end
end

-- The channel only exists inside a network match with a bridge root. Outside
-- one the module keeps no state and paints nothing.
local function activeConfig(gui)
  if not reader then reader = runtimeConfig.newReader() end
  local ok, config = pcall(reader.read)
  if not ok or type(config) ~= "table" then return nil end
  local root = config.root
  if type(root) ~= "string" or root == "" or root == "." then return nil end
  local snapshot = gui and gui.snapshot
  local mode
  if type(snapshot) == "table" then mode = snapshot.networkMode end
  if mode ~= nil then
    if mode ~= "network" then return nil end
  elseif config.startNetwork ~= true then
    return nil
  end
  return config
end

-- Called from guiHandleEvent after the existing handlers; must never return
-- a value (a returned table would alter the builder's own validation). No file
-- IO here: the capture only lands in memory and tick publishes it.
function M.observeBuilderEvent(gui, id, name, param)
  if state.enabled ~= true then return end
  if name == "builder.proposalCreate" then
    if not BUILDER_TOOLS[id] then return end
    local ok, body = pcall(preview.extract, id, param)
    if ok and type(body) == "table" then
      local invalid = false
      local okFlag, flag = pcall(preview.invalidFlag, param)
      if okFlag and flag == true then invalid = true end
      body.invalid = invalid
      state.localPreview = body
    else
      state.localPreview = nil
    end
    state.eventAt = clock()
  elseif name == "builder.apply" then
    state.localPreview = nil
  elseif name == "tabWidget.currentChanged" and id == "menu.construction" then
    state.localPreview = nil
  end
end

-- Cancelling a builder produces no event, so the renderer's own controls are
-- polled - but only while a local preview exists, and at most every 0.3 s.
local function detectCancel(now)
  if not state.localPreview then return end
  if state.eventAt and now - state.eventAt < CANCEL_PROBE_SECONDS then return end
  if state.controlsAt and now - state.controlsAt < CANCEL_PROBE_SECONDS then return end
  state.controlsAt = now
  local visible = preview.controlsVisible()
  if visible == false then
    state.localPreview = nil
  elseif visible == nil and state.eventAt
    and now - state.eventAt > PREVIEW_STALE_SECONDS then
    state.localPreview = nil
  end
end

-- Called every GUI frame; throttles itself to five hertz internally.
function M.tick(gui)
  local now = clock()
  if state.pollAt and now - state.pollAt < POLL_SECONDS then return end
  state.pollAt = now
  local config = activeConfig(gui)
  if not config then
    if state.enabled == true then
      clearZones()
      reset(nil, nil, nil)
      renderChat()
    end
    return
  end
  if state.root ~= config.root or state.peerId ~= config.peerId
    or state.sessionId ~= config.sessionId then
    clearZones()
    reset(config.root, config.peerId, config.sessionId)
    state.pollAt = now
  end
  state.enabled = true
  -- The companion counts frames it had to drop; surfacing it beats a silent
  -- channel, and it is the only companion fact this section reads.
  local snapshot, social = gui and gui.snapshot, nil
  if type(snapshot) == "table" and type(snapshot.bridge) == "table"
    and type(snapshot.bridge.companion) == "table" then
    social = snapshot.bridge.companion.social
  end
  state.dropped = 0
  if type(social) == "table" then
    state.dropped = math.max(0, math.floor(tonumber(social.dropped) or 0))
  end
  detectCancel(now)
  publish()
  consume(gui)
  renderZones()
  if not state.chatAt or now - state.chatAt >= KEEPALIVE_SECONDS then renderChat() end
end

local function makeButton(label, action)
  local button = api.gui.comp.Button.new(api.gui.comp.TextView.new(label), true)
  button:onClick(function() pcall(action) end)
  return button
end

-- TextInputField is a stock component (its usertype exposes onEnter/onChange/
-- getText/setText/setMaxLength), but it is not used by any shipped Lua script,
-- so construction and every call is guarded and the Send button alone is
-- enough to use the channel.
local function makeInput(gui)
  local factory = api.gui.comp.TextInputField
  if type(factory) ~= "table" or type(factory.new) ~= "function" then return nil end
  local ok, field = pcall(factory.new, "Message the other player")
  if not ok or field == nil then
    ok, field = pcall(factory.new)
    if not ok or field == nil then return nil end
  end
  pcall(function() field:setMaxLength(codec.MAX_TEXT) end)
  pcall(function() field:onEnter(function(text) sendChat(gui, text) end) end)
  return field
end

local function addRow(rootLayout, chrome, items)
  local layout = api.gui.layout.BoxLayout.new("HORIZONTAL")
  local component = chrome.styled(api.gui.comp.Component.new(""), "tpf2mp-row")
  component:setLayout(layout)
  for _, item in ipairs(items) do
    if item then layout:addItem(item) end
  end
  rootLayout:addItem(component)
end

-- Adds the chat and ping controls to the panel.
function M.addSection(gui, rootLayout, chrome)
  if type(chrome) ~= "table" or type(chrome.addSection) ~= "function"
    or type(chrome.styled) ~= "function" then return end
  chrome.addSection(rootLayout, "Chat and pings")
  state.chatView = chrome.styled(api.gui.comp.TextView.new(EMPTY_HINT), "tpf2mp-chat")
  gui.socialChat = state.chatView
  rootLayout:addItem(state.chatView)
  state.input = chrome.styled(makeInput(gui), "tpf2mp-chat-input")
  gui.socialInput = state.input
  -- Built by hand rather than as a literal: a missing input field would make
  -- a literal's first element nil and ipairs would then skip the Send button.
  local inputRow = {}
  if state.input then inputRow[#inputRow + 1] = state.input end
  inputRow[#inputRow + 1] = makeButton("Send", function() sendChat(gui) end)
  addRow(rootLayout, chrome, inputRow)
  local pings = {}
  for _, entry in ipairs(PING_BUTTONS) do
    pings[#pings + 1] = makeButton(entry[1], function() sendPing(gui, entry[2]) end)
  end
  addRow(rootLayout, chrome, pings)
  renderChat()
end

guiView.social = M
return M
