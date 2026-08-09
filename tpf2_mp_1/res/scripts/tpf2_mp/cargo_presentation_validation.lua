local util = require "tpf2_mp/util"
local hash = require "tpf2_mp/hash"

local M = {}

local function exactCount(value, maximum)
  return type(value) == "number" and value == math.floor(value)
    and value >= 0 and value <= maximum
end

function M.validate(state, economyState, freightState, vehicleSync, deps)
  local maxCount, maxCents = deps.maxCount, deps.maxCents
  local count, add, cargoService = deps.count, deps.add, deps.cargoService
  if type(state) ~= "table" or state.schemaVersion ~= deps.schemaVersion
    or not exactCount(state.epoch, maxCount)
    or state.epoch ~= util.integer(economyState and economyState.epoch, -1)
    or type(state.lines) ~= "table" or type(state.vehicles) ~= "table" then
    return false, "cargo presentation save header is invalid"
  end
  local aboardByLine = {}
  for vehicleCid, vehicle in pairs(state.vehicles) do
    local line = type(vehicle) == "table" and state.lines[vehicle.lineCid] or nil
    local sync = vehicleSync and vehicleSync.vehicles
      and vehicleSync.vehicles[vehicleCid] or nil
    if type(vehicleCid) ~= "string" or type(vehicle) ~= "table"
      or vehicle.vehicleCid ~= vehicleCid or type(line) ~= "table"
      or vehicle.companyCid ~= line.companyCid
      or not exactCount(vehicle.capacity, maxCount)
      or not exactCount(vehicle.aboard, maxCount)
      or vehicle.aboard > vehicle.capacity
      or not exactCount(vehicle.lastRound, maxCount)
      or not exactCount(vehicle.boardedTotal, maxCount)
      or not exactCount(vehicle.deliveredTotal, maxCount)
      or not exactCount(vehicle.discardedTotal, maxCount)
      or not exactCount(vehicle.earnedRevenueCents, maxCents)
      or vehicle.boardedTotal ~= vehicle.deliveredTotal
        + vehicle.discardedTotal + vehicle.aboard then
      return false, "cargo presentation vehicle conservation is invalid: "
        .. tostring(vehicleCid)
    end
    if type(sync) ~= "table" or sync.lineCid ~= vehicle.lineCid
      or sync.companyCid ~= vehicle.companyCid
      or util.integer(sync.lastAuthorizedRound, -1) ~= vehicle.lastRound then
      return false, "cargo presentation vehicle disagrees with synchronization: "
        .. tostring(vehicleCid)
    end
    if vehicle.lastRound > 0 then
      local stopIndex = util.integer(vehicle.lastStopIndex, -1)
      if stopIndex < 0 or type(line.stops) ~= "table" or stopIndex >= #line.stops
        or util.integer(sync.stopIndex, -1) ~= stopIndex
        or vehicle.lastStationGroupCid ~= line.stops[stopIndex + 1] then
        return false, "cargo presentation vehicle stop is invalid: "
          .. tostring(vehicleCid)
      end
    end
    aboardByLine[vehicle.lineCid] = add(
      aboardByLine[vehicle.lineCid], vehicle.aboard)
  end

  for lineCid, line in pairs(state.lines) do
    if type(lineCid) ~= "string" or type(line) ~= "table"
      or line.lineCid ~= lineCid or type(line.retired) ~= "boolean"
      or not exactCount(line.epoch, maxCount) or line.epoch > state.epoch
      or not exactCount(line.allocated, maxCount)
      or not exactCount(line.boardedThisEpoch, maxCount)
      or not exactCount(line.capacityPerVehicle, maxCount)
      or not exactCount(line.boardedTotal, maxCount)
      or not exactCount(line.deliveredTotal, maxCount)
      or not exactCount(line.discardedTotal, maxCount)
      or not exactCount(line.earnedRevenueCents, maxCents)
      or line.boardedThisEpoch > line.allocated
      or line.boardedThisEpoch > line.boardedTotal
      or line.boardedTotal ~= line.deliveredTotal + line.discardedTotal
        + count(aboardByLine[lineCid]) then
      return false, "cargo presentation line conservation is invalid: "
        .. tostring(lineCid)
    end
    local service, _, stops, metadata = cargoService(economyState, lineCid)
    if line.retired ~= true then
      if not service or line.companyCid ~= service.companyCid
        or line.marketCid ~= service.marketCid
        or line.contractDigest ~= metadata.freightContractDigest
        or line.sourceIndustryCid ~= metadata.sourceIndustryCid
        or line.destinationIndustryCid ~= metadata.destinationIndustryCid
        or line.destinationStockIndex ~= util.integer(metadata.destinationStockIndex, -1)
        or line.cargoType ~= metadata.cargoType
        or line.sourceStationGroupCid ~= metadata.sourceStationGroupCid
        or line.destinationStationGroupCid ~= metadata.destinationStationGroupCid
        or line.sourceStopIndex ~= util.integer(metadata.sourceStopIndex, -1)
        or line.destinationStopIndex ~= util.integer(metadata.destinationStopIndex, -1)
        or line.capacityPerVehicle ~= count(metadata.cargoCapacityPerVehicle)
        or hash.value(line.stops) ~= hash.value(stops)
        or line.routeDigest ~= hash.value(stops) then
        return false, "cargo presentation line disagrees with its service: "
          .. tostring(lineCid)
      end
    end
    local cursor = freightState and freightState.transportCursors
      and freightState.transportCursors[lineCid] or nil
    if cursor and (cursor.contractDigest ~= line.contractDigest
      or cursor.sourceIndustryCid ~= line.sourceIndustryCid
      or cursor.destinationIndustryCid ~= line.destinationIndustryCid
      or cursor.destinationStockIndex ~= line.destinationStockIndex
      or cursor.cargoType ~= line.cargoType
      or util.integer(cursor.boardedUnits, 0) > line.boardedTotal
      or util.integer(cursor.deliveredUnits, 0) > line.deliveredTotal) then
      return false, "cargo presentation line disagrees with freight transport: "
        .. tostring(lineCid)
    end
    local payment = economyState and economyState.deliveryCursors
      and economyState.deliveryCursors[lineCid] or nil
    if payment and (not exactCount(payment.deliveredCargo, maxCount)
      or not exactCount(payment.earnedRevenueCents, maxCents)
      or payment.deliveredCargo > line.deliveredTotal
      or payment.earnedRevenueCents > line.earnedRevenueCents) then
      return false, "cargo presentation line disagrees with economy settlement: "
        .. tostring(lineCid)
    end
  end
  return true, state
end

return M
