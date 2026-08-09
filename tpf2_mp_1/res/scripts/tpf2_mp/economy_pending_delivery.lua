local util = require "tpf2_mp/util"
local difficulty = require "tpf2_mp/economy_difficulty"

local M = {}

function M.service(state, service, lineCid, revenueMultiplierPpm)
  local economy = state.economy or {}
  local market = economy.markets and economy.markets[service.marketCid] or {}
  local cargo = market.kind == "cargo"
  local presentationState = state.world and (cargo
    and state.world.cargoPresentation or state.world.passengerPresentation) or {}
  local presentation = presentationState.lines and presentationState.lines[lineCid] or {}
  local cursor = economy.deliveryCursors and economy.deliveryCursors[lineCid] or {}
  local completed = cargo and presentation.deliveredTotal or presentation.alightedTotal
  local settled = cargo and cursor.deliveredCargo or cursor.deliveredPassengers
  local pendingDelivered = math.max(0,
    util.integer(completed, 0) - util.integer(settled, 0))
  local pendingRawGross = math.max(0, util.integer(
    presentation.earnedRevenueCents, 0) - util.integer(cursor.earnedRevenueCents, 0))
  return {
    kind = cargo and "cargo" or "passenger",
    presentation = presentation,
    pendingDelivered = pendingDelivered,
    pendingRawGrossRevenueCents = pendingRawGross,
    pendingGrossRevenueCents = difficulty.preview(pendingRawGross,
      revenueMultiplierPpm, service.revenueMultiplierResid),
  }
end

return M
