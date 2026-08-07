local util = require "tpf2_mp/util"
local economy = require "tpf2_mp/economy"
local costs = require "tpf2_mp/economy_costs"
local vehicleCostRuntime = require "tpf2_mp/vehicle_cost_runtime"

local M = {}

function M.new(deps)
  local getState = assert(deps.getState, "getState dependency is required")
  local vehicles = vehicleCostRuntime.new({ getState = getState })

  -- Attribute a proposal's capital to durable canonical outputs. This is
  -- generic by design: stations, modded constructions, track types, signals,
  -- and scenery all use the same consensus result. Root constructions/assets
  -- carry compound costs; simple topology uses private edges/objects. Public
  -- town roads carry no company maintenance.
  local function recordProposal(record, financeDelta)
    if type(record) ~= "table" or record.infrastructureRecorded == true then return nil end
    local state = getState()
    local retiredCapitalCents = 0
    for _, input in ipairs(record.localInputs or {}) do
      retiredCapitalCents = retiredCapitalCents
        + math.max(0, util.integer(input.capitalCostCents, 0))
    end
    local roots, topology, fallback = {}, {}, {}
    for _, output in ipairs(record.result and record.result.outputs or {}) do
      local binding = state.canonical.byCanonical[output.cid]
      local metadata = binding and binding.metadata or {}
      if output.kind == "construction" or output.kind == "asset" then
        roots[#roots + 1] = output.cid
      elseif (output.kind == "edge" or output.kind == "edge_object")
        and metadata.private == true then
        topology[#topology + 1] = output.cid
      elseif output.kind == "depot" or output.kind == "station" then
        fallback[#fallback + 1] = output.cid
      end
    end
    local costBearing = #roots > 0 and roots or (#topology > 0 and topology or fallback)
    local spendCents = math.max(0, -util.integer(financeDelta, 0) * 100)
    local addedCapitalCents = #costBearing > 0 and (retiredCapitalCents + spendCents) or 0
    for cid, capitalCostCents in pairs(costs.allocateCapital(costBearing, addedCapitalCents)) do
      local binding = state.canonical.byCanonical[cid]
      if binding then
        binding.metadata = binding.metadata or {}
        binding.metadata.capitalCostCents = capitalCostCents
        binding.metadata.capitalCostSource = "authoritative-proposal"
      end
    end
    local costRecord = economy.applyInfrastructureChange(
      state.economy, record.companyCid, retiredCapitalCents, addedCapitalCents)
    record.infrastructureRecorded = true
    record.infrastructure = {
      retiredCapitalCents = retiredCapitalCents,
      spendCents = spendCents,
      addedCapitalCents = addedCapitalCents,
      costBearingOutputs = util.deepCopy(costBearing),
      companyCapitalCents = costRecord.infrastructureCapitalCents,
    }
    return record.infrastructure
  end

  return {
    recordProposal = recordProposal,
    recordVehicle = vehicles.recordVehicle,
    backfillVehicles = vehicles.backfillVehicles,
    nativeAnnualMaintenanceDollars = vehicles.nativeAnnualMaintenanceDollars,
  }
end

return M
