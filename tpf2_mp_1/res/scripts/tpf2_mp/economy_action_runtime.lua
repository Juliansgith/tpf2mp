local util = require "tpf2_mp/util"
local hash = require "tpf2_mp/hash"
local serviceQuarantine = require "tpf2_mp/economy_service_quarantine"
local deliverySnapshot = require "tpf2_mp/delivery_snapshot"

local M = {}

-- Assemble portable economy actions without leaking machine-local ids. This
-- is the single reviewable boundary for authored registration and settlement.
function M.lineRegistration(state, world, economy, lineCid, lineId, companyCid)
  local preview = util.deepCopy(state.economy)
  local ok, result = world.makeLineService(
    state.canonical, economy, preview, lineId, companyCid, state.world)
  if not ok then
    return serviceQuarantine.disabledAction(state, lineCid, companyCid, result), result
  end
  local action = {
    type = "line.register", lineCid = lineCid, companyCid = companyCid,
    market = util.deepCopy(preview.markets[result.marketCid]),
    service = util.deepCopy(preview.services[result.lineCid]), vehicleCosts = {},
  }
  for _, vehicleCid in ipairs(action.service.metadata.vehicleCids or {}) do
    if preview.vehicleCosts[vehicleCid] then
      action.vehicleCosts[vehicleCid] = util.deepCopy(preview.vehicleCosts[vehicleCid])
    end
  end
  return action
end

function M.settlement(
    state, economy, passengerPresentation, cargoPresentation, boundary, scheduled)
  local delivery, deliveryError = deliverySnapshot.combine(
    passengerPresentation.economySnapshot(state.world.passengerPresentation),
    cargoPresentation.economySnapshot(state.world.cargoPresentation))
  if not delivery then error(deliveryError) end
  local preview = util.deepCopy(state.economy)
  return {
    type = "economy.settle", scheduled = scheduled == true,
    boundaryGameTimeSeconds = boundary, deliverySnapshot = delivery,
    results = economy.evaluateAll(preview, boundary, delivery),
  }
end

function M.verifiedDelivery(state, passengerPresentation, cargoPresentation, snapshot)
  local localValue, localError = deliverySnapshot.combine(
    passengerPresentation.economySnapshot(state.world.passengerPresentation),
    cargoPresentation.economySnapshot(state.world.cargoPresentation))
  if not localValue then return nil, localError end
  if snapshot == nil and state.networkMode ~= "network" then return localValue end
  if hash.value(snapshot) ~= hash.value(localValue) then
    return nil, "economy delivery snapshot diverges from synchronized completed trips"
  end
  return snapshot
end

return M
