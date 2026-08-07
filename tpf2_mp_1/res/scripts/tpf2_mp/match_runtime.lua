local util = require "tpf2_mp/util"
local economy = require "tpf2_mp/economy"

local M = {}

function M.new(deps)
  assert(type(deps) == "table", "match runtime dependencies are required")
  local getState = assert(deps.getState, "getState dependency is required")

  local function rankedWinner()
    local state = getState()
    local scores = economy.scoreboard(state.economy, state.companies)
    local ranked = {}
    for _, cid in ipairs(util.sortedKeys(scores)) do ranked[#ranked + 1] = scores[cid] end
    table.sort(ranked, function(a, b)
      if a.modelValueCents ~= b.modelValueCents then return a.modelValueCents > b.modelValueCents end
      if a.settledRevenueCents ~= b.settledRevenueCents then
        return a.settledRevenueCents > b.settledRevenueCents
      end
      if a.settledDemand ~= b.settledDemand then return a.settledDemand > b.settledDemand end
      if a.marketWins ~= b.marketWins then return a.marketWins > b.marketWins end
      return a.companyCid < b.companyCid
    end)
    return ranked[1] and ranked[1].companyCid or nil, ranked
  end

  local function finish(reason, winnerCid)
    local state = getState()
    if not state.initialized then return false, "initialise the match first" end
    if state.match.status == "finished" then return false, "match is already finished" end
    if winnerCid ~= nil and not state.companies[winnerCid] then
      return false, "unknown winner company"
    end
    local rankedWinnerCid, ranked = rankedWinner()
    state.match.status = "finished"
    state.match.finishedTick = state.tick
    state.match.finishReason = tostring(reason or "manual")
    state.match.winnerCid = winnerCid or rankedWinnerCid
    return true, { match = util.deepCopy(state.match), ranking = ranked }
  end

  local function evaluateEnd()
    local state = getState()
    if state.match.status ~= "running" then return nil end
    local rules = state.match.rules or {}
    local winnerCid, ranked = rankedWinner()
    local leader = ranked[1]
    local reason
    -- Bankruptcy outranks scoring: a company that cannot fund itself has lost
    -- regardless of who was ahead on model value.
    local bankruptCid = state.finance and state.finance.networkAccounts
      and state.finance.networkAccounts.bankruptCid or nil
    if bankruptCid then
      reason = "bankruptcy"
      for _, candidate in ipairs(state.companyOrder or {}) do
        if candidate ~= bankruptCid then winnerCid = candidate; break end
      end
    elseif util.integer(rules.valuationTargetCents, 0) > 0
      and leader and leader.modelValueCents >= util.integer(rules.valuationTargetCents, 0) then
      reason = "valuation-target"
    elseif util.integer(rules.maxEpochs, 0) > 0
      and state.economy.epoch >= util.integer(rules.maxEpochs, 0) then
      reason = "epoch-limit"
    end
    if not reason then return nil end
    local ok, result = finish(reason, winnerCid)
    return ok and result or nil
  end

  local function requireRunning()
    local state = getState()
    if not state.initialized then return false, "initialise the match first" end
    if state.match.status ~= "running" then return false, "match is not running" end
    return true
  end

  return {
    rankedWinner = rankedWinner,
    finish = finish,
    evaluateEnd = evaluateEnd,
    requireRunning = requireRunning,
  }
end

return M
