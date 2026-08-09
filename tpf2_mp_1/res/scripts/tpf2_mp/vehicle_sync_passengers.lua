local util = require "tpf2_mp/util"
local passengerPresentation = require "tpf2_mp/passenger_presentation"
local cargoPresentation = require "tpf2_mp/cargo_presentation"

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
  worldState.passengerPresentation = presentation
  worldState.cargoPresentation = cargo
  return true, { passenger = result, cargo = cargoResult }
end

function M.applyOperation(worldState, economyState, transaction, companyCid)
  local presentation = util.deepCopy(worldState.passengerPresentation)
  local cargo = util.deepCopy(worldState.cargoPresentation)
  local ok, result = passengerPresentation.onOperation(
    presentation, economyState, transaction, companyCid)
  if not ok then return false, result end
  local cargoOk, cargoResult = cargoPresentation.onOperation(
    cargo, economyState, transaction, companyCid)
  if not cargoOk then return false, cargoResult end
  worldState.passengerPresentation = result
  worldState.cargoPresentation = cargoResult
  return true, { passenger = result, cargo = cargoResult }
end

return M
