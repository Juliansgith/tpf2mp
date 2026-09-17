-- Window chrome for the multiplayer panel: optional style classes (the test
-- fakes have none), section captions, and header badges that mirror the
-- plain-text summary line one fact per tinted badge. The module registers
-- itself as guiView.chrome so the game script, which sits at Lua 5.1's
-- 200-local cap, needs no new local to reach it.
local guiView = require "tpf2_mp/gui_view"
local matchInitialisePolicy = require "tpf2_mp/match_initialise_policy"

local M = {}

function M.styled(component, ...)
  if component and type(component.setStyleClassList) == "function" then
    pcall(component.setStyleClassList, component, { ... })
  end
  return component
end

-- Button rows wrap after five buttons so the window keeps a readable width.
M.ROW_LIMIT = 5

function M.addRows(rootLayout, definitions, makeButton)
  for first = 1, #definitions, M.ROW_LIMIT do
    local layout = api.gui.layout.BoxLayout.new("HORIZONTAL")
    local component = M.styled(api.gui.comp.Component.new(""), "tpf2mp-row")
    component:setLayout(layout)
    for index = first, math.min(first + M.ROW_LIMIT - 1, #definitions) do
      layout:addItem(makeButton(definitions[index][1], definitions[index][2]))
    end
    rootLayout:addItem(component)
  end
end

function M.addSection(rootLayout, caption)
  rootLayout:addItem(M.styled(api.gui.comp.TextView.new(caption), "tpf2mp-section"))
end

function M.addHeader(gui, rootLayout)
  local layout = api.gui.layout.BoxLayout.new("HORIZONTAL")
  local header = M.styled(api.gui.comp.Component.new(""), "tpf2mp-header")
  header:setLayout(layout)
  gui.badges = {}
  for _, key in ipairs({ "mode", "peer", "link", "match", "company", "proxy" }) do
    local badge = M.styled(api.gui.comp.TextView.new(""), "tpf2mp-badge", "tpf2mp-badge-muted")
    gui.badges[key] = badge
    layout:addItem(badge)
  end
  rootLayout:addItem(header)
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
end

guiView.chrome = M
return M
