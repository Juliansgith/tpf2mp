local util = require "tpf2_mp/util"
local passengerPresentation = require "tpf2_mp/passenger_presentation"
local cargoPresentation = require "tpf2_mp/cargo_presentation"
local freightIndustryModel = require "tpf2_mp/freight_industry_model"
local multihopNetwork = require "tpf2_mp/multihop_network"

local M = {}

function M.applyRelease(worldState, economyState, vehicleSync, action, metadata)
  local presentation = util.deepCopy(worldState.passengerPresentation)
  local cargo = util.deepCopy(worldState.cargoPresentation)
  local aligned, alignmentResult = passengerPresentation.alignWithVehicleSync(
    presentation, economyState, vehicleSync)
  if not aligned then
    return false, "passenger presentation alignment failed: " .. tostring(alignmentResult)
  end
  presentation = alignmentResult
  local cargoAligned, cargoAlignment = cargoPresentation.alignWithVehicleSync(
    cargo, economyState, vehicleSync)
  if not cargoAligned then
    return false, "cargo presentation alignment failed: " .. tostring(cargoAlignment)
  end
  cargo = cargoAlignment
  local applied, result = passengerPresentation.applyRelease(
    presentation, economyState, action, metadata)
  if not applied then
    return false, "passenger presentation rejected vehicle release: " .. tostring(result)
  end
  local cargoApplied, cargoResult = cargoPresentation.applyRelease(
    cargo, economyState, worldState.freightIndustry, action, metadata)
  if not cargoApplied then
    return false, "cargo presentation rejected vehicle release: " .. tostring(cargoResult)
  end
  local pinned, pinResult = multihopNetwork.pinCargoLine(
    economyState, action.lineCid)
  if not pinned then
    return false, "cargo path pin rejected vehicle release: " .. tostring(pinResult)
  end
  worldState.passengerPresentation = presentation
  worldState.cargoPresentation = cargo
  return true, { passenger = result, cargo = cargoResult, freightPath = pinResult }
end

function M.applyOperation(worldState, economyState, transaction, companyCid)
  local presentation = util.deepCopy(worldState.passengerPresentation)
  local cargo = util.deepCopy(worldState.cargoPresentation)
  local freight, freightResult = worldState.freightIndustry, nil
  if type(transaction) == "table" and type(transaction.data) == "table"
    and transaction.kind == "line.delete" then
    freight = util.deepCopy(worldState.freightIndustry)
    local freightOk
    freightOk, freightResult = freightIndustryModel.retireTransportLine(
      freight, transaction.data.targetCid)
    if not freightOk then return false, freightResult end
  end
  local ok, result = passengerPresentation.onOperation(
    presentation, economyState, transaction, companyCid)
  if not ok then return false, result end
  local cargoOk, cargoResult = cargoPresentation.onOperation(
    cargo, economyState, transaction, companyCid)
  if not cargoOk then return false, cargoResult end
  worldState.passengerPresentation = result
  worldState.cargoPresentation = cargoResult
  if freightResult ~= nil then worldState.freightIndustry = freight end
  return true, { passenger = result, cargo = cargoResult, freight = freightResult }
end

return M
