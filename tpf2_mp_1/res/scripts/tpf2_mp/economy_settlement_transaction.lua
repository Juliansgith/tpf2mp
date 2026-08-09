local util = require "tpf2_mp/util"

local M = {}

-- Stage every authored ledger touched by an economy boundary. Nothing in the
-- live state is adopted until deterministic economy evaluation, aggregate
-- freight stock transfer, settlement recording, and both presentation epoch
-- transitions have all succeeded.
function M.prepare(state, economy, passengerPresentation,
    cargoPresentation, freightRuntime, action, delivery)
  local economyCandidate = util.deepCopy(state.economy)
  local results
  if action.results then
    local accepted, resultOrError = economy.acceptAuthoritativeResults(
      economyCandidate, action.results, delivery)
    if not accepted then return nil, resultOrError end
    results = resultOrError
  else
    local evaluated, resultOrError = pcall(economy.evaluateAll,
      economyCandidate, action.boundaryGameTimeSeconds, delivery)
    if not evaluated then return nil, tostring(resultOrError) end
    results = resultOrError
  end
  local recorded, recordError = economy.recordSettlement(economyCandidate, results)
  if not recorded then return nil, recordError end
  local freightCandidate, freightSummary = freightRuntime.settlementCandidate(
    state, results, delivery, economyCandidate.scheduler.epochSeconds)
  if not freightCandidate then return nil, freightSummary end

  local passengerCandidate = util.deepCopy(state.world.passengerPresentation)
  local passengerOk, passengerResult = passengerPresentation.beginEpoch(
    passengerCandidate, economyCandidate)
  if not passengerOk then return nil, passengerResult end
  local cargoCandidate = util.deepCopy(state.world.cargoPresentation)
  local cargoOk, cargoResult = cargoPresentation.beginEpoch(
    cargoCandidate, economyCandidate)
  if not cargoOk then return nil, cargoResult end
  return {
    economy = economyCandidate,
    freightIndustry = freightCandidate,
    passengerPresentation = passengerResult,
    cargoPresentation = cargoResult,
    results = results,
    freightSummary = freightSummary,
  }
end

return M
