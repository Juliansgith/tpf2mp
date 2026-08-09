local util = require "tpf2_mp/util"

local M = {}

local function presentations(
    state, economyState, passengerPresentation, cargoPresentation, lineCid)
  local passengerCandidate = util.deepCopy(state.world.passengerPresentation)
  local cargoCandidate = util.deepCopy(state.world.cargoPresentation)
  local passengerOk, passengerError = passengerPresentation.reconcileService(
    passengerCandidate, economyState, lineCid)
  if not passengerOk then return nil, passengerError end
  local cargoOk, cargoError = cargoPresentation.reconcileService(
    cargoCandidate, economyState, lineCid)
  if not cargoOk then return nil, cargoError end
  return passengerCandidate, cargoCandidate
end

local function applyVehicleCosts(economyState, economy, values)
  for vehicleCid, cost in pairs(values or {}) do
    economy.upsertVehicleCost(economyState, vehicleCid,
      cost.companyCid, cost.annualVehicleUpkeepCents)
  end
end

-- Registration touches the economy, both delivery ledgers, vehicle costs,
-- and (for the standalone derived path) canonical bindings. Stage all of it
-- so a rejected active freight-contract edit cannot partially change state.
function M.prepare(state, world, economy, passengerPresentation,
    cargoPresentation, action, lineId, companyCid)
  local economyCandidate = util.deepCopy(state.economy)
  local canonicalCandidate = nil
  local result
  if action.market and action.service then
    economy.upsertMarket(economyCandidate, action.market)
    economy.upsertService(economyCandidate, action.service)
    applyVehicleCosts(economyCandidate, economy, action.vehicleCosts)
    result = {
      lineCid = action.lineCid, marketCid = action.market.cid,
      owner = companyCid, authoritativeFacts = true,
    }
  else
    canonicalCandidate = util.deepCopy(state.canonical)
    local ok
    ok, result = world.makeLineService(canonicalCandidate, economy,
      economyCandidate, lineId, companyCid, state.world)
    if not ok then return nil, result end
  end
  local passengerCandidate, cargoCandidate = presentations(
    state, economyCandidate, passengerPresentation, cargoPresentation,
    result.lineCid or action.lineCid)
  if not passengerCandidate then return nil, cargoCandidate end
  return {
    economy = economyCandidate, canonical = canonicalCandidate,
    passengerPresentation = passengerCandidate,
    cargoPresentation = cargoCandidate, result = result,
  }
end

return M
