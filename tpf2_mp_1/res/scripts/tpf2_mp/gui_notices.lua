-- Rejection notices and a floating toast. A multiplayer refusal that only
-- appears as one line inside a wall of diagnostics is a refusal the player
-- never reads, so every rejection is also translated into a plain sentence,
-- kept in a short dated feed, and shown once near the top of the screen.
-- Registers itself as guiView.notices; other panel modules call
-- guiView.notices.push(gui, { kind = ..., text = ..., ttl = ... }).
local guiView = require "tpf2_mp/gui_view"

local M = {}

M.LIMIT = 6
M.DEFAULT_TTL = 8

-- Machine reason codes that players should never have to decode.
M.REASONS = {
  ["native-proposal-rejected"] = "The game refused this build on the other computer.",
  ["native-operation-rejected"] = "The game refused this order on the other computer.",
  ["the network companion is disconnected"] =
    "You are disconnected; builds are not queued.",
  ["companion-disconnected"] = "You are disconnected; builds are not queued.",
  ["proposal-timeout"] =
    "The other computer did not answer in time; the build was cancelled.",
  ["operation-timeout"] =
    "The other computer did not answer in time; the order was cancelled.",
  ["session-fault"] = "The session is faulted. Use Recover / Resync Session.",
  ["origin-applied-custody-lost-on-reload"] =
    "A build was applied here but lost its shared order; resync the session.",
}

-- The test fakes have no style classes, and the live API may not expose
-- setStyleClassList on every component, so styling is always optional. This
-- mirrors guiView.chrome.styled deliberately: chrome composes this module, so
-- this module must not compose chrome.
local function styled(component, ...)
  if component and type(component.setStyleClassList) == "function" then
    pcall(component.setStyleClassList, component, { ... })
  end
  return component
end

local function method(object, name)
  if object == nil then return nil end
  local ok, value = pcall(function() return object[name] end)
  if ok and type(value) == "function" then return value end
  return nil
end

local function call(object, name, ...)
  local fn = method(object, name)
  if not fn then return false end
  return (pcall(fn, object, ...))
end

local function seconds()
  if os and type(os.time) == "function" then
    local ok, value = pcall(os.time)
    if ok and type(value) == "number" then return value end
  end
  return 0
end

function M.state(gui)
  gui.notices = gui.notices or { items = {}, observed = false }
  gui.notices.items = gui.notices.items or {}
  return gui.notices
end

function M.explain(code)
  if code == nil then return "Rejected: unknown" end
  local text = tostring(code)
  local mapped = M.REASONS[text]
  if mapped then return mapped end
  -- Ownership vetoes are already written for players; keep them verbatim.
  if text:sub(1, 7) == "TPF2MP:" then return text end
  mapped = M.REASONS[text:lower()]
  if mapped then return mapped end
  return "Rejected: " .. text
end

function M.push(gui, notice)
  if type(gui) ~= "table" or type(notice) ~= "table" then return nil end
  local text = notice.text
  if text == nil or tostring(text) == "" then return nil end
  local state = M.state(gui)
  local item = {
    kind = tostring(notice.kind or "info"),
    text = tostring(text),
    ttl = tonumber(notice.ttl) or M.DEFAULT_TTL,
    at = seconds(),
  }
  local newest = state.items[1]
  -- The same refusal repeated every render is one event, not six.
  if newest and newest.text == item.text and newest.kind == item.kind then
    newest.at = item.at
    newest.ttl = item.ttl
    state.dirty = true
    return newest
  end
  table.insert(state.items, 1, item)
  while #state.items > M.LIMIT do table.remove(state.items) end
  state.dirty = true
  return item
end

function M.age(item, now)
  local elapsed = math.max(0, (now or seconds()) - (tonumber(item.at) or 0))
  if elapsed < 60 then return string.format("%d s ago", elapsed) end
  return string.format("%d min ago", math.floor(elapsed / 60))
end

function M.feedText(gui, now)
  local state = M.state(gui)
  if #state.items == 0 then return "No rejections or messages yet." end
  now = now or seconds()
  local lines = {}
  for _, item in ipairs(state.items) do
    lines[#lines + 1] = string.format("[%s] %s (%s)", item.kind, item.text, M.age(item, now))
  end
  return table.concat(lines, "\n")
end

-- guiHandleEvent hands back whatever the builder veto returned. Two shapes
-- carry refusals: { errorMessages = { ... } } and a bare array of strings.
function M.observeVeto(gui, result)
  if type(gui) ~= "table" or type(result) ~= "table" then return end
  local messages = result.errorMessages
  if type(messages) ~= "table" then
    if type(result[1]) == "string" and result[1]:sub(1, 7) == "TPF2MP:" then
      messages = result
    end
  end
  if type(messages) ~= "table" then return end
  for _, message in ipairs(messages) do
    if type(message) == "string" and message ~= "" then
      M.push(gui, { kind = "rejection", text = M.explain(message) })
    end
  end
end

local function outcomeReason(outcome)
  if type(outcome) ~= "table" then return nil end
  return outcome.reason or outcome.error or outcome.errorCode
end

local function observeError(gui, state, key, value)
  if value == nil then
    state[key] = nil
    return
  end
  local text = tostring(value)
  if state[key] == text then return end
  state[key] = text
  M.push(gui, { kind = "rejection", text = M.explain(text) })
end

local function observeCounter(gui, state, key, count, outcome, fallback)
  local current = tonumber(count) or 0
  local previous = state[key]
  state[key] = current
  if previous == nil then return end
  if current <= previous then return end
  M.push(gui, { kind = "rejection", text = M.explain(outcomeReason(outcome) or fallback) })
end

-- Called once per render: the snapshot is the only place a rejection that
-- happened on the other computer becomes visible here.
function M.observe(gui, snapshot)
  if type(gui) ~= "table" then return end
  if type(snapshot) ~= "table" then snapshot = {} end
  local state = M.state(gui)
  observeError(gui, state, "lastGuiError", gui.lastError)
  observeError(gui, state, "lastSnapshotError", snapshot.lastError)
  local proposals = snapshot.proposalConsensus or {}
  observeCounter(gui, state, "proposalRejected", proposals.rejected,
    proposals.lastOutcome, "native-proposal-rejected")
  local operations = snapshot.operationConsensus or {}
  observeCounter(gui, state, "operationRejected", operations.rejected,
    operations.lastOutcome, "native-operation-rejected")
  state.observed = true
end

function M.addSection(gui, rootLayout, chrome)
  chrome.addSection(rootLayout, "Notices")
  gui.noticesView = chrome.styled(api.gui.comp.TextView.new(""), "tpf2mp-notices")
  chrome.addItem(rootLayout, gui.noticesView)
end

local function ensureToast(gui)
  if gui.noticeToast then return gui.noticeToast end
  if gui.noticeToastFailed then return nil end
  if not (api and api.gui and api.gui.comp and api.gui.comp.Window
    and api.gui.layout and api.gui.layout.BoxLayout) then
    gui.noticeToastFailed = true
    return nil
  end
  local ok, toast = pcall(function()
    local layout = api.gui.layout.BoxLayout.new("VERTICAL")
    local root = styled(api.gui.comp.Component.new("tpf2mp.toast"), "tpf2mp-toast")
    root:setLayout(layout)
    local view = styled(api.gui.comp.TextView.new(""), "tpf2mp-toast-text")
    layout:addItem(view)
    -- A title-less window would be ideal; the documented API has no way to
    -- drop the bar, so the product name is the least noisy title available.
    return { window = api.gui.comp.Window.new("TPF2MP", root), view = view, root = root }
  end)
  if not ok or type(toast) ~= "table" or not toast.window then
    gui.noticeToastFailed = true
    return nil
  end
  call(toast.window, "setId", "tpf2mp.toast.window")
  call(toast.window, "addHideOnCloseHandler")
  call(toast.window, "setMovable", true)
  call(toast.window, "setResizable", false)
  call(toast.window, "setPinned", true)
  -- Near the top centre; a fixed offset is used when the UI rectangle is not
  -- readable, which is the case in the test fakes.
  call(toast.window, "setPosition", 640, 70)
  call(toast.window, "setVisible", false, false)
  gui.noticeToast = toast
  return toast
end

function M.render(gui, snapshot)
  if type(gui) ~= "table" then return end
  M.observe(gui, snapshot)
  local state = M.state(gui)
  local now = seconds()
  if gui.noticesView and type(gui.noticesView.setText) == "function" then
    pcall(gui.noticesView.setText, gui.noticesView, M.feedText(gui, now))
  end
  local newest = state.items[1]
  local visible = false
  if newest then
    visible = (now - (tonumber(newest.at) or 0)) < (tonumber(newest.ttl) or M.DEFAULT_TTL)
  end
  -- Do not put a second window on the player's screen until there is actually
  -- something to say in it.
  if not visible and not gui.noticeToast then
    state.toastVisible = false
    return
  end
  local toast = ensureToast(gui)
  if not toast then return end
  if visible then
    if type(toast.view.setText) == "function" then
      pcall(toast.view.setText, toast.view, newest.text)
    end
    state.toastText = newest.text
  else
    state.toastText = nil
  end
  state.toastVisible = visible
  call(toast.window, "setVisible", visible, false)
end

guiView.notices = M
return M
