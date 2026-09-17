-- The contest, in the panel: both companies side by side with the numbers the
-- match is actually decided on, plus the end-of-match summary. Data comes from
-- the public snapshot only (economy.scoreboard fields, public_snapshot
-- companies); the ranking mirrors match_runtime.rankedWinner exactly so the
-- leader shown here is the company that would win right now. Registers itself
-- as guiView.scoreboard; the game script needs no new local.
local guiView = require "tpf2_mp/gui_view"
local nextAction = require "tpf2_mp/gui_next_action"
local notices = require "tpf2_mp/gui_notices"

local M = {}

-- Thousands separators: a nine-figure valuation is unreadable without them.
function M.group(digits)
  local text = tostring(digits)
  while true do
    local replaced, count = text:gsub("^(%-?%d+)(%d%d%d)", "%1,%2")
    text = replaced
    if count == 0 then break end
  end
  return text
end

-- gui_view.lua prints cents as value/100 with two decimals; keep that unit and
-- add grouping so both surfaces agree.
function M.money(cents)
  local value = (tonumber(cents) or 0) / 100
  local sign = ""
  if value < 0 then sign = "-" end
  local whole = string.format("%.2f", math.abs(value))
  local integral, fraction = whole:match("^(%d+)%.(%d+)$")
  if not integral then return sign .. "$" .. whole end
  return sign .. "$" .. M.group(integral) .. "." .. fraction
end

function M.count(value)
  return M.group(string.format("%d", math.floor(tonumber(value) or 0)))
end

-- Same ordering as match_runtime.rankedWinner, so "leader" here means "would
-- win if the match ended now".
function M.ranking(snapshot)
  if type(snapshot) ~= "table" then snapshot = {} end
  local scoreboard = snapshot.scoreboard or {}
  local companies = snapshot.companies or {}
  local order = snapshot.companyOrder
  local ranked = {}
  local seen = {}
  local function add(companyCid)
    if seen[companyCid] then return end
    seen[companyCid] = true
    local score = scoreboard[companyCid] or {}
    local company = companies[companyCid] or {}
    ranked[#ranked + 1] = {
      companyCid = companyCid,
      name = tostring(score.name or company.name or companyCid),
      modelValueCents = tonumber(score.modelValueCents) or 0,
      settledNetRevenueCents = tonumber(score.settledNetRevenueCents) or 0,
      settledRevenueCents = tonumber(score.settledRevenueCents) or 0,
      settledDemand = tonumber(score.settledDemand) or 0,
      marketsReached = tonumber(score.marketsReached) or 0,
      activeLines = tonumber(score.activeLines) or 0,
      marketWins = tonumber(score.marketWins) or 0,
      balance = tonumber(company.effectiveBalance or company.balance) or 0,
    }
  end
  if type(order) == "table" then
    for _, companyCid in ipairs(order) do add(companyCid) end
  end
  local rest = {}
  for companyCid in pairs(scoreboard) do
    if not seen[companyCid] then rest[#rest + 1] = companyCid end
  end
  table.sort(rest)
  for _, companyCid in ipairs(rest) do add(companyCid) end
  table.sort(ranked, function(a, b)
    if a.modelValueCents ~= b.modelValueCents then return a.modelValueCents > b.modelValueCents end
    if a.settledNetRevenueCents ~= b.settledNetRevenueCents then
      return a.settledNetRevenueCents > b.settledNetRevenueCents
    end
    if a.settledRevenueCents ~= b.settledRevenueCents then
      return a.settledRevenueCents > b.settledRevenueCents
    end
    if a.settledDemand ~= b.settledDemand then return a.settledDemand > b.settledDemand end
    if a.marketWins ~= b.marketWins then return a.marketWins > b.marketWins end
    return a.companyCid < b.companyCid
  end)
  return ranked
end

function M.leader(snapshot)
  return M.ranking(snapshot)[1]
end

-- "Match over: <winner> won by <reason in words>" plus the final ranking.
function M.summary(snapshot)
  if type(snapshot) ~= "table" then snapshot = {} end
  local match = snapshot.match or {}
  if tostring(match.status or "") ~= "finished" then return nil end
  local lines = { nextAction.matchOver(snapshot) }
  local ranked = M.ranking(snapshot)
  for index, entry in ipairs(ranked) do
    lines[#lines + 1] = string.format("  %d. %s -- value %s, settled net %s",
      index, entry.name, M.money(entry.modelValueCents), M.money(entry.settledNetRevenueCents))
  end
  return table.concat(lines, "\n")
end

function M.lines(snapshot)
  if type(snapshot) ~= "table" then snapshot = {} end
  local ranked = M.ranking(snapshot)
  local lines = {}
  local summary = M.summary(snapshot)
  if summary then
    lines[#lines + 1] = summary
    lines[#lines + 1] = ""
  end
  if #ranked == 0 then
    lines[#lines + 1] = "No company standings yet."
    return lines
  end
  for index, entry in ipairs(ranked) do
    local marker = "  "
    if index == 1 then marker = "* " end
    lines[#lines + 1] = marker .. entry.name
    if index == 1 then lines[#lines] = lines[#lines] .. "  (leader)" end
    lines[#lines + 1] = string.format(
      "    value %s | settled net %s | demand %s | lines %s | markets %s | wins %s",
      M.money(entry.modelValueCents), M.money(entry.settledNetRevenueCents),
      M.count(entry.settledDemand), M.count(entry.activeLines),
      M.count(entry.marketsReached), M.count(entry.marketWins))
  end
  return lines
end

function M.text(snapshot)
  return table.concat(M.lines(snapshot), "\n")
end

function M.addSection(gui, rootLayout, chrome)
  chrome.addSection(rootLayout, "Scoreboard")
  gui.scoreboardView = chrome.styled(api.gui.comp.TextView.new(""), "tpf2mp-scoreboard")
  chrome.addItem(rootLayout, gui.scoreboardView)
end

function M.render(gui, snapshot)
  if type(snapshot) ~= "table" then snapshot = {} end
  local match = snapshot.match or {}
  local finished = tostring(match.status or "") == "finished"
  -- Announce the end of the match exactly once, however many renders follow.
  if finished and gui.scoreboardFinishAnnounced ~= true then
    gui.scoreboardFinishAnnounced = true
    notices.push(gui, { kind = "info", text = nextAction.matchOver(snapshot), ttl = 20 })
  end
  if not finished then gui.scoreboardFinishAnnounced = false end
  local view = gui.scoreboardView
  if not view then return end
  if type(view.setText) ~= "function" then return end
  pcall(view.setText, view, M.text(snapshot))
end

guiView.scoreboard = M
return M
