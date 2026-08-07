local util = require "tpf2_mp/util"
local passengerPresentation = require "tpf2_mp/passenger_presentation"

local M = {}

function M.applyRelease(worldState, economyState, vehicleSync, action, metadata)
  local presentation = util.deepCopy(worldState.passengerPresentation)
  local aligned, alignmentResult = passengerPresentation.alignWithVehicleSync(
    presentation, economyState, vehicleSync)
  if not aligned then
    return false, "passenger presentation alignment failed: " .. tostring(alignmentResult)
  end
  presentation = alignmentResult
  local applied, result = passengerPresentation.applyRelease(
    presentation, economyState, action, metadata)
  if not applied then
    return false, "passenger presentation rejected vehicle release: " .. tostring(result)
  end
  worldState.passengerPresentation = presentation
  return true, result
end

function M.applyOperation(worldState, economyState, transaction, companyCid)
  local presentation = util.deepCopy(worldState.passengerPresentation)
  local ok, result = passengerPresentation.onOperation(
    presentation, economyState, transaction, companyCid)
  if not ok then return false, result end
  worldState.passengerPresentation = result
  return true, result
end

return M
