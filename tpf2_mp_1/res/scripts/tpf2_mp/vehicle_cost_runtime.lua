local util = require "tpf2_mp/util"
local economy = require "tpf2_mp/economy"
local costs = require "tpf2_mp/economy_costs"
local world = require "tpf2_mp/world"

local M = {}

function M.new(deps)
  local getState = assert(deps.getState, "getState dependency is required")

  local function nativeAnnualMaintenanceDollars(localId)
    local types = api and api.type and api.type.ComponentType or {}
    if tonumber(localId) == nil or not (types.MAINTENANCE_COST
      and api and api.engine and api.engine.getComponent) then return nil end
    local ok, component = pcall(
      api.engine.getComponent, tonumber(localId), types.MAINTENANCE_COST)
    local annual = ok and component and tonumber(component.maintenanceCost) or nil
    if not annual or annual < 0 then return nil end
    return math.max(0, util.integer(annual, 0))
  end

  local function completionAnnualMaintenanceDollars(record)
    for _, container in ipairs({ record and record.completion, record and record.result }) do
      local postcondition = type(container) == "table" and container.postcondition or nil
      local annual = type(postcondition) == "table"
        and tonumber(postcondition.annualMaintenanceDollars) or nil
      if annual and annual >= 0 then return math.max(0, util.integer(annual, 0)) end
    end
    return nil
  end

  local function recordVehicle(record, financeDelta)
    if type(record) ~= "table" or type(record.transaction) ~= "table"
      or record.vehicleCostRecorded == true then return nil end
    local kind = record.transaction.kind
    if kind ~= "vehicle.buy" and kind ~= "vehicle.replace"
      and kind ~= "vehicle.maintenance" and kind ~= "vehicle.sell"
      and kind ~= "vehicle.sell_batch" then return nil end
    local state = getState()
    if kind == "vehicle.sell_batch" then
      local removed = {}
      for _, targetCid in ipairs(record.transaction.data.targetCids or {}) do
        removed[#removed + 1] = {
          vehicleCid = targetCid,
          removed = economy.removeVehicleCost(state.economy, targetCid),
        }
      end
      record.vehicleCostRecorded = true
      return { vehicles = removed }
    end
    local output = kind == "vehicle.buy" and record.result and record.result.outputs
      and record.result.outputs[1] or nil
    local vehicleCid = output and output.cid
      or (record.transaction.data and record.transaction.data.targetCid)
    if type(vehicleCid) ~= "string" or vehicleCid == "" then return nil end
    if kind == "vehicle.sell" then
      local removed = economy.removeVehicleCost(state.economy, vehicleCid)
      record.vehicleCostRecorded = true
      return { vehicleCid = vehicleCid, removed = removed }
    end
    local binding = state.canonical.byCanonical[vehicleCid]
    if not binding then return nil end
    local purchasePriceDollars = kind == "vehicle.buy"
      and math.max(0, -util.integer(financeDelta, 0))
      or tonumber(binding.metadata and binding.metadata.purchasePriceDollars)
    local annualDollars = completionAnnualMaintenanceDollars(record)
      or nativeAnnualMaintenanceDollars(binding.localId)
    local existing = state.economy.vehicleCosts
      and state.economy.vehicleCosts[vehicleCid] or nil
    local annualVehicleUpkeepCents, source
    if annualDollars ~= nil then
      annualVehicleUpkeepCents = math.min(costs.ACCUMULATOR_LIMIT, annualDollars * 100)
      source = "consensus-native-maintenance"
    elseif existing then
      annualVehicleUpkeepCents = math.max(0,
        util.integer(existing.annualVehicleUpkeepCents, 0))
      source = "retained-authored-cost"
    else
      annualVehicleUpkeepCents = costs.vehicleAnnualUpkeepCents(purchasePriceDollars or 0)
      source = "purchase-price-fallback"
    end
    binding.metadata = binding.metadata or {}
    if kind == "vehicle.buy" then
      binding.metadata.purchasePriceDollars = purchasePriceDollars
    end
    binding.metadata.annualVehicleUpkeepCents = annualVehicleUpkeepCents
    binding.metadata.nativeAnnualMaintenanceDollars = annualDollars
    binding.metadata.vehicleCostSource = source
    economy.upsertVehicleCost(
      state.economy, vehicleCid, record.companyCid, annualVehicleUpkeepCents)
    record.vehicleCostRecorded = true
    return {
      vehicleCid = vehicleCid,
      purchasePriceDollars = purchasePriceDollars,
      annualVehicleUpkeepCents = annualVehicleUpkeepCents,
      nativeAnnualMaintenanceDollars = annualDollars,
      source = source,
    }
  end

  -- Starting saves can already contain vehicles. Unique manifest-bound
  -- vehicles receive the same native cost basis. Indistinguishable duplicates
  -- remain unbound until a future portable manifest adapter identifies them.
  local function backfillVehicles()
    local state = getState()
    local report = { examined = 0, priced = 0, alreadyPriced = 0,
      ownerUnavailable = 0, costUnavailable = 0 }
    for _, vehicleCid in ipairs(util.sortedKeys(state.canonical.byCanonical or {})) do
      local binding = state.canonical.byCanonical[vehicleCid]
      if binding.kind == "vehicle" then
        report.examined = report.examined + 1
        if state.economy.vehicleCosts and state.economy.vehicleCosts[vehicleCid] then
          report.alreadyPriced = report.alreadyPriced + 1
        else
          local owner = binding.metadata and binding.metadata.owner
            or world.logicalOwnerOf(state.world, state.companies, binding.localId)
          local annualDollars = nativeAnnualMaintenanceDollars(binding.localId)
          if not owner then
            report.ownerUnavailable = report.ownerUnavailable + 1
          elseif annualDollars == nil then
            report.costUnavailable = report.costUnavailable + 1
          else
            binding.metadata = binding.metadata or {}
            binding.metadata.owner = owner
            binding.metadata.annualVehicleUpkeepCents = math.min(
              costs.ACCUMULATOR_LIMIT, annualDollars * 100)
            binding.metadata.nativeAnnualMaintenanceDollars = annualDollars
            binding.metadata.vehicleCostSource = "manifest-native-maintenance"
            economy.upsertVehicleCost(state.economy, vehicleCid, owner,
              binding.metadata.annualVehicleUpkeepCents)
            report.priced = report.priced + 1
          end
        end
      end
    end
    return report
  end

  return {
    recordVehicle = recordVehicle,
    backfillVehicles = backfillVehicles,
    nativeAnnualMaintenanceDollars = nativeAnnualMaintenanceDollars,
  }
end

return M
