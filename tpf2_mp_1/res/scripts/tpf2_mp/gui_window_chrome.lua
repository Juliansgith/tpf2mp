-- Window chrome for the multiplayer panel: optional style classes (the test
-- fakes have none), collapsible section headers, header badges that mirror the
-- plain-text summary line one fact per tinted badge, and the whole section /
-- row list the window is built from. The module registers itself as
-- guiView.chrome so the game script, which sits at Lua 5.1's 200-local cap,
-- needs no new local to reach it; for the same reason the section list lives
-- here rather than in ensureWindow.
local util = require "tpf2_mp/util"
local json = require "tpf2_mp/json"
local guiView = require "tpf2_mp/gui_view"
local matchInitialisePolicy = require "tpf2_mp/match_initialise_policy"
local matchControls = require "tpf2_mp/gui_match_controls"
local nextAction = require "tpf2_mp/gui_next_action"
local notices = require "tpf2_mp/gui_notices"
local scoreboard = require "tpf2_mp/gui_scoreboard"

local M = {}

function M.styled(component, ...)
  if component and type(component.setStyleClassList) == "function" then
    pcall(component.setStyleClassList, component, { ... })
  end
  return component
end

-- Button rows wrap after five buttons so the window keeps a readable width.
M.ROW_LIMIT = 5

-- Sections a player needs on first sight stay open; the rest are one click
-- away. "Scoreboard" is resolved per mode: it is meaningless outside a match.
M.DEFAULT_EXPANDED = {
  ["Match"] = true,
  ["Notices"] = true,
  ["Shared clock"] = true,
  ["Chat and pings"] = true,
  ["Diagnostics and recovery"] = true,
}
-- Compact mode keeps only the badges, the next-action line and these.
M.COMPACT_KEEP = { ["Notices"] = true }
M.PREFERENCES_FILE = "/TPF2MP/ui-preferences.json"
M.SAVE_INTERVAL_SECONDS = 2

local function seconds()
  if os and type(os.time) == "function" then
    local ok, value = pcall(os.time)
    if ok and type(value) == "number" then return value end
  end
  return 0
end

local function setVisible(component, visible)
  if component and type(component.setVisible) == "function" then
    pcall(component.setVisible, component, visible == true, false)
  end
end

local function setText(component, text)
  if component and type(component.setText) == "function" then
    pcall(component.setText, component, text)
  end
end

-- Preferences: expanded/collapsed state and compact mode, per player, in
-- %LOCALAPPDATA%/TPF2MP (the directory the launcher already owns). Every step
-- is guarded: an unreadable or unwritable file must only cost the defaults.
local function preferencesPath()
  if not (os and type(os.getenv) == "function") then return nil end
  local ok, root = pcall(os.getenv, "LOCALAPPDATA")
  if not ok or type(root) ~= "string" or root == "" then return nil end
  return (root:gsub("\\", "/"):gsub("/+$", "")) .. M.PREFERENCES_FILE
end

local function peerKey(gui)
  local peer
  local ok, value = pcall(function() return game.config.tpf2mp.peerId end)
  if ok then peer = value end
  if peer == nil and type(gui) == "table" and type(gui.snapshot) == "table" then
    peer = gui.snapshot.peerId
  end
  if peer == nil or tostring(peer) == "" then return "default" end
  return tostring(peer)
end

function M.loadPreferences(gui)
  if M.preferences then return M.preferences end
  M.preferences = { schemaVersion = 1, peers = {} }
  local path = preferencesPath()
  if not path or not (io and type(io.open) == "function") then return M.preferences end
  local ok, document = pcall(function()
    local file = io.open(path, "rb")
    if not file then return nil end
    local raw = file:read("*a")
    file:close()
    return json.decode(raw)
  end)
  if ok and type(document) == "table" and type(document.peers) == "table" then
    M.preferences = document
  end
  return M.preferences
end

local function storedEntry(gui)
  local document = M.loadPreferences(gui)
  local entry = document.peers and document.peers[peerKey(gui)]
  if type(entry) ~= "table" then return {} end
  return entry
end

function M.flushPreferences(force)
  if not M.preferencesDirty then return false end
  local now = seconds()
  if not force and M.preferencesWrittenAt
    and (now - M.preferencesWrittenAt) < M.SAVE_INTERVAL_SECONDS then
    return false
  end
  M.preferencesDirty = false
  M.preferencesWrittenAt = now
  local path = preferencesPath()
  if not path or not (io and type(io.open) == "function") then return false end
  local document = M.preferences
  return (pcall(function()
    local file = assert(io.open(path, "wb"))
    file:write(json.encode(document))
    file:close()
  end))
end

function M.savePreferences(gui)
  local document = M.loadPreferences(gui)
  document.schemaVersion = 1
  document.peers = document.peers or {}
  local entry = { compact = M.compact == true, sections = {} }
  for _, record in ipairs(M.order or {}) do
    entry.sections[record.caption] = record.expanded == true
  end
  document.peers[peerKey(gui)] = entry
  M.preferencesDirty = true
  return M.flushPreferences(false)
end

local function defaultExpanded(gui, caption)
  if caption == "Scoreboard" then
    return type(gui) == "table" and type(gui.snapshot) == "table"
      and gui.snapshot.networkMode == "network"
  end
  return M.DEFAULT_EXPANDED[caption] == true
end

local function headerText(record)
  local marker = ">"
  if record.expanded == true then marker = "v" end
  return marker .. " " .. record.caption
end

local function register(component)
  local section = M.current
  if not section then return end
  if section.seen[component] then return end
  section.seen[component] = true
  section.rows[#section.rows + 1] = component
end

-- Every widget that belongs to a section must arrive through here, so that
-- collapsing a section can hide exactly the widgets it owns.
function M.addItem(rootLayout, component)
  rootLayout:addItem(component)
  register(component)
  return component
end

function M.addRows(rootLayout, definitions, makeButton)
  for first = 1, #definitions, M.ROW_LIMIT do
    local layout = api.gui.layout.BoxLayout.new("HORIZONTAL")
    local component = M.styled(api.gui.comp.Component.new(""), "tpf2mp-row")
    component:setLayout(layout)
    for index = first, math.min(first + M.ROW_LIMIT - 1, #definitions) do
      layout:addItem(makeButton(definitions[index][1], definitions[index][2]))
    end
    M.addItem(rootLayout, component)
  end
end

-- Visibility is reapplied only after a toggle: setVisible relayouts the whole
-- window in the live API, and a render happens for every arriving snapshot.
function M.applyVisibility()
  M.visibilityDirty = false
  for _, record in ipairs(M.order or {}) do
    local keep = true
    if M.compact == true and M.COMPACT_KEEP[record.caption] ~= true then keep = false end
    local rowsVisible = keep and record.expanded == true
    setText(record.label, headerText(record))
    setVisible(record.header, keep)
    for _, row in ipairs(record.rows) do setVisible(row, rowsVisible) end
  end
  local gui = M.gui
  if gui and gui.status then setVisible(gui.status, M.compact ~= true) end
end

function M.toggleSection(caption)
  local record = M.sections and M.sections[caption]
  if not record then return false end
  record.expanded = record.expanded ~= true
  M.applyVisibility()
  M.savePreferences(M.gui)
  return record.expanded
end

local function compactText()
  if M.compact == true then return "Expand" end
  return "Compact"
end

function M.setCompact(gui, value)
  M.compact = value == true
  setText(gui and gui.compactLabel, compactText())
  M.applyVisibility()
  M.savePreferences(gui)
  return M.compact
end

-- A clickable caption: the header is the control, so there is no separate
-- expander widget to hunt for. The style sheet keeps the caption uppercase.
function M.addSection(rootLayout, caption)
  local gui = M.gui
  M.sections = M.sections or {}
  M.order = M.order or {}
  local record = { caption = caption, rows = {}, seen = {} }
  record.expanded = defaultExpanded(gui, caption)
  local stored = storedEntry(gui).sections
  if type(stored) == "table" and stored[caption] ~= nil then
    record.expanded = stored[caption] == true
  end
  local label = api.gui.comp.TextView.new(headerText(record))
  local header = M.styled(api.gui.comp.Button.new(label, true),
    "tpf2mp-section", "tpf2mp-section-header")
  if type(header.onClick) == "function" then
    pcall(header.onClick, header, function() M.toggleSection(caption) end)
  end
  record.label, record.header = label, header
  -- The header is the section's control, not one of its rows: add it while no
  -- section is current so that collapsing cannot hide its own caption.
  M.current = nil
  rootLayout:addItem(header)
  M.sections[caption] = record
  M.order[#M.order + 1] = record
  M.current = record
  M.visibilityDirty = true
  return record
end

-- A minimal forwarding layout: modules that add widgets straight to the panel
-- (gui_match_controls, gui_social_runtime) stay collapsible without knowing
-- anything about sections.
function M.tracked(rootLayout)
  return { addItem = function(_, item) return M.addItem(rootLayout, item) end }
end

function M.addHeader(gui, rootLayout)
  M.gui, M.sections, M.order, M.current = gui, {}, {}, nil
  M.compact = storedEntry(gui).compact == true
  local layout = api.gui.layout.BoxLayout.new("HORIZONTAL")
  local header = M.styled(api.gui.comp.Component.new(""), "tpf2mp-header")
  header:setLayout(layout)
  gui.badges = {}
  for _, key in ipairs({ "mode", "peer", "link", "match", "company", "proxy" }) do
    local badge = M.styled(api.gui.comp.TextView.new(""), "tpf2mp-badge", "tpf2mp-badge-muted")
    gui.badges[key] = badge
    layout:addItem(badge)
  end
  gui.compactLabel = api.gui.comp.TextView.new(compactText())
  gui.compactButton = M.styled(api.gui.comp.Button.new(gui.compactLabel, true), "tpf2mp-compact")
  if type(gui.compactButton.onClick) == "function" then
    pcall(gui.compactButton.onClick, gui.compactButton,
      function() M.setCompact(M.gui, M.compact ~= true) end)
  end
  layout:addItem(gui.compactButton)
  rootLayout:addItem(header)
  -- The instruction line sits directly under the badges, above the evidence.
  gui.nextActionView = M.styled(api.gui.comp.TextView.new(""), "tpf2mp-next")
  rootLayout:addItem(gui.nextActionView)
end

local function setBadge(gui, key, text, tone)
  local badge = gui.badges and gui.badges[key]
  if not badge then return end
  badge:setText(text)
  if type(badge.setStyleClassList) == "function" then
    pcall(badge.setStyleClassList, badge, { "tpf2mp-badge", "tpf2mp-badge-" .. tone })
  end
  if type(badge.setVisible) == "function" then pcall(badge.setVisible, badge, text ~= "", false) end
end

-- Mirrors the facts gui_view.render prints in the summary line.
function M.renderBadges(gui, snapshot)
  if not gui.badges then return end
  snapshot = snapshot or gui.snapshot or {}
  local companion = snapshot.bridge and snapshot.bridge.companion or {}
  local network = snapshot.networkMode == "network"
  local linkStatus = not network and "local"
    or (companion.connected == true and "connected" or tostring(companion.status or "offline"))
  local matchStatus = tostring(matchInitialisePolicy.status(snapshot) or "setup")
  setBadge(gui, "mode", network and "Network" or "Local", network and "info" or "muted")
  local peer = tostring(snapshot.peerId or "?")
  setBadge(gui, "peer", peer == "player1" and "Player 1 (host)" or peer == "player2" and "Player 2" or peer,
    peer == "?" and "muted" or "info")
  setBadge(gui, "link", "Link " .. linkStatus,
    linkStatus == "connected" and "ok" or (linkStatus == "local" and "muted" or "warn"))
  setBadge(gui, "match", "Match " .. matchStatus,
    (matchStatus == "setup" or matchStatus:find("wait", 1, true)) and "warn" or "ok")
  local company = snapshot.activeCompanyName
  setBadge(gui, "company", company and tostring(company) or "Company pending", company and "ok" or "muted")
  setBadge(gui, "proxy", snapshot.proxyMode == true and "Proxy" or "", "warn")
  -- The badges already carry the first six facts; break the plain-text summary
  -- before the rest so it fits the window width instead of clipping.
  if gui.status and type(gui.status.getText) == "function" then
    local ok, text = pcall(gui.status.getText, gui.status)
    if ok and type(text) == "string" and text:find(" | Selected:", 1, true) then
      gui.status:setText((text:gsub(" | Selected:", "\nSelected:", 1)))
    end
  end
  pcall(nextAction.render, gui, snapshot)
  pcall(notices.render, gui, snapshot)
  pcall(scoreboard.render, gui, snapshot)
  if M.visibilityDirty then M.applyVisibility() end
  M.flushPreferences(false)
end

-- The whole panel below the summary line. ctx carries the three closures the
-- game script owns: button(label, factory), config() and publicSnapshot().
function M.buildSections(gui, rootLayout, ctx)
  local function addRow(layout, definitions) M.addRows(layout, definitions, ctx.button) end
  -- gui_match_controls adds one TextView straight to the layout it is given;
  -- route it through the section tracker so collapsing "Match" hides it too.
  M.addSection(rootLayout, "Match")
  matchControls.add(M.tracked(rootLayout), addRow, ctx.config())
  scoreboard.addSection(gui, rootLayout, M)
  notices.addSection(gui, rootLayout, M)
  M.addSection(rootLayout, "Transport manager")
  addRow(rootLayout, guiView.managerButtons(gui))
  if ctx.config().developerEconomyControls then
    M.addSection(rootLayout, "Developer economy")
    addRow(rootLayout, {
      { "Seed Demo Market (Dev)", function() return { type = "economy.seed_demo" } end },
      { "Settle Epoch (Dev Host)", function()
      local snapshot = gui.snapshot or {}
      assert(snapshot.networkMode ~= "network" or snapshot.peerId == "player1",
        "only Player 1 (the host) can settle the authoritative economy")
      return { type = "economy.settle" }
      end },
    })
  end
  M.addSection(rootLayout, "Lines and route draft")
  addRow(rootLayout, {
    { "Add Selected Stop", function()
      gui.routeDraft[#gui.routeDraft + 1] = assert(gui.selectedEntityId,
        "select a station-group icon first")
      return { type = "snapshot.request", localOnly = true }
    end },
    { "Undo Draft Stop", function()
      if #gui.routeDraft > 0 then table.remove(gui.routeDraft) end
      return { type = "snapshot.request", localOnly = true }
    end },
    { "Clear Route Draft", function()
      gui.routeDraft = {}
      return { type = "snapshot.request", localOnly = true }
    end },
    { "Create Draft Line", function()
      assert(#gui.routeDraft >= 2, "add at least two station groups to the route draft")
      return { type = "operation.capture", capture = {
        kind = "line.create", stationGroupLocalIds = util.deepCopy(gui.routeDraft),
      } }
    end },
    { "Update Selected Line", function()
      assert(#gui.routeDraft >= 2, "add at least two station groups to the route draft")
      return { type = "operation.capture", capture = {
        kind = "line.update", targetLocalId = assert(gui.selectedLineId, "select a line first"),
        stationGroupLocalIds = util.deepCopy(gui.routeDraft),
      } }
    end },
  })
  M.addSection(rootLayout, "Vehicles")
  addRow(rootLayout, {
    { "Assign Vehicle to Line", function() return { type = "operation.capture", capture = {
      kind = "vehicle.assign",
      targetLocalId = assert(gui.selectedVehicleId, "select a vehicle first"),
      lineLocalId = assert(gui.selectedLineId, "select a line first"),
      stopIndex = 0,
    } } end },
    { "Stop Vehicle", function() return { type = "operation.capture", capture = {
      kind = "vehicle.stop", targetLocalId = assert(gui.selectedVehicleId, "select a vehicle first"),
      stopped = true,
    } } end },
    { "Start Vehicle", function() return { type = "operation.capture", capture = {
      kind = "vehicle.stop", targetLocalId = assert(gui.selectedVehicleId, "select a vehicle first"),
      stopped = false,
    } } end },
    { "Send Vehicle to Depot", function() return { type = "operation.capture", capture = {
      kind = "vehicle.send_to_depot",
      targetLocalId = assert(gui.selectedVehicleId, "select a vehicle first"),
      sellOnArrival = false,
    } } end },
    { "Sell Vehicle", function() return { type = "operation.capture", capture = {
      kind = "vehicle.sell", targetLocalId = assert(gui.selectedVehicleId, "select a vehicle first"),
    } } end },
    { "Delete Selected Line", function() return { type = "operation.capture", capture = {
      kind = "line.delete", targetLocalId = assert(gui.selectedLineId, "select a line first"),
    } } end },
  })
  M.addSection(rootLayout, "Assets and fares")
  addRow(rootLayout, {
    -- Registration is automatic after any line or assignment change; this
    -- stays as a manual re-derive for lines that predate the match or whose
    -- facts a player wants refreshed on demand.
    { "Re-check Selected Line", function() return { type = "line.register", localLineId = assert(gui.selectedLineId, "select a line first") } end },
    { "Claim Selected Asset", function() return { type = "world.claim", ids = { assert(gui.selectedEntityId, "select an entity first") } } end },
    { "Fare -1.00", function() return { type = "fare.adjust", localLineId = assert(gui.selectedLineId, "select a line first"), deltaCents = -100 } end },
    { "Fare +1.00", function() return { type = "fare.adjust", localLineId = assert(gui.selectedLineId, "select a line first"), deltaCents = 100 } end },
  })
  M.addSection(rootLayout, "World and finance")
  addRow(rootLayout, {
    { "Freeze / Unfreeze", function()
      local snapshot = gui.snapshot or ctx.publicSnapshot()
      return { type = "world.freeze", freeze = not snapshot.autonomyFrozen }
    end },
    { "Network Mode (pre-match)", function()
      local snapshot = gui.snapshot or ctx.publicSnapshot()
      return { type = "network.set_mode", mode = snapshot.networkMode == "network" and "standalone" or "network" }
    end },
    { "Toggle Income Neutralizer", function() return { type = "finance.toggle_neutralizer" } end },
    { "Repair Starting Cash", function() return { type = "finance.repair_starting_cash", localOnly = true } end },
  })
  M.addSection(rootLayout, "Shared clock")
  addRow(rootLayout, {
    { "Pause", function() return { type = "clock.request", requestedSpeed = 0 } end },
    { "Speed 1", function() return { type = "clock.request", requestedSpeed = 1 } end },
    { "Speed 2", function() return { type = "clock.request", requestedSpeed = 2 } end },
    { "Speed 3", function() return { type = "clock.request", requestedSpeed = 4 } end },
  })
  if ctx.config().developerEconomyControls then
    M.addSection(rootLayout, "Native gate (testing)")
    addRow(rootLayout, {
      { "Toggle Build Gate (Test)", function()
        local snapshot = gui.snapshot or ctx.publicSnapshot()
        local gate = snapshot.probes and snapshot.probes.nativeHook
          and snapshot.probes.nativeHook.gates and snapshot.probes.nativeHook.gates.buildProposal or {}
        return { type = "native.build_gate", enabled = gate.enabled ~= true, localOnly = true }
      end },
      { "Authorize Next Build", function()
        return { type = "native.build_authorize", localOnly = true }
      end },
    })
  end
  M.addSection(rootLayout, "Diagnostics and recovery")
  addRow(rootLayout, {
    { "Run Sync Probe", function() return { type = "probe.run" } end },
    { "Sample Pax / Cargo", function() return { type = "probe.mobility" } end },
    { "Refresh Passenger Display", function()
      return { type = "probe.passenger_cosmetics", localOnly = true }
    end },
    { "Export Research", function() return { type = "probe.export_research" } end },
    { "Export Snapshot", function() return { type = "snapshot.export" } end },
    { "Recover / Resync Session", function() return { type = "recovery.requalify" } end },
    { "Prepare & Save Restore Point", function() return { type = "recovery.prepare" } end },
    { "Refresh", function() return { type = "snapshot.request", localOnly = true } end },
  })
end

guiView.chrome = M
return M
