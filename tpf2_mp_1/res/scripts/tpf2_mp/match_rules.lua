local util = require "tpf2_mp/util"
local economy = require "tpf2_mp/economy"
local calendarModel = require "tpf2_mp/calendar_model"

local M = {}

-- Match rules are portable authored state. Native observations are admitted
-- only as defaults on the host; the normalized values then travel in the
-- ordered match.initialise action and every peer uses those exact values.
function M.normalise(rules, cfg, observedClock, networkCalendar)
  rules = type(rules) == "table" and rules or {}
  cfg = type(cfg) == "table" and cfg or {}
  observedClock = type(observedClock) == "table" and observedClock or {}
  local observedStart = util.integer(observedClock.time, 0)
  local economyStartGameTimeSeconds = math.max(0, util.integer(
    rules.economyStartGameTimeSeconds, observedStart))
  local bankruptcyEnabled = rules.bankruptcyEnabled
  if bankruptcyEnabled == nil then bankruptcyEnabled = cfg.bankruptcyEnabled end
  local difficultyRule = economy.difficultyRule(
    rules.economyDifficulty or cfg.economyDifficulty)
  local calendarStartDate = calendarModel.normaliseDate(rules.calendarStartDate)
    or calendarModel.normaliseDate(observedClock.date)
    or { year = 1850, month = 1, day = 1 }
  local capturedPace = type(networkCalendar) == "table"
    and networkCalendar.preFreezeMillisPerDay or nil
  local calendarMillisPerDay = util.clamp(util.integer(
    rules.calendarMillisPerDay,
    capturedPace or calendarModel.DEFAULT_MILLIS_PER_DAY), 0, 86400000)
  return {
    startingCash = math.max(0, util.integer(rules.startingCash, cfg.startingCash)),
    maxEpochs = math.max(0, util.integer(rules.maxEpochs, cfg.maxEpochs)),
    valuationTargetCents = math.max(0, util.integer(
      rules.valuationTargetCents, cfg.valuationTargetCents)),
    bankruptcyEnabled = bankruptcyEnabled ~= false,
    insolventSettlements = math.max(0, util.integer(
      rules.insolventSettlements, cfg.insolventSettlements)),
    creditBaseLimitCents = math.max(0, util.integer(
      rules.creditBaseLimitCents, cfg.creditBaseLimitCents)),
    creditRevenueMultiple = math.max(0, util.integer(
      rules.creditRevenueMultiple, cfg.creditRevenueMultiple)),
    creditInterestPermille = math.max(0, util.integer(
      rules.creditInterestPermille, cfg.creditInterestPermille)),
    economyDifficulty = difficultyRule.key,
    revenueMultiplierPpm = difficultyRule.revenueMultiplierPpm,
    economyEpochSeconds = economy.EPOCH_SECONDS,
    economyStartGameTimeSeconds = economyStartGameTimeSeconds,
    calendarStartDate = util.deepCopy(calendarStartDate),
    calendarMillisPerDay = calendarMillisPerDay,
  }
end

return M
