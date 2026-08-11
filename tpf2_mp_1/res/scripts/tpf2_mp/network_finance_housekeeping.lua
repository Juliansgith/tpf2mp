local util = require "tpf2_mp/util"
local finance = require "tpf2_mp/finance"

local M = {
  IDLE_STRIDE = 15,
  PENDING_STRIDE = 1,
  BLOCKED_STRIDE = 3,
}

local function hasPhysicalBarrier(state)
  for _, record in pairs(state.world.proposals.byId or {}) do
    if record.status == "queued" or record.status == "awaiting-finance"
      or record.status == "building-construction" then return true end
  end
  for _, record in pairs(state.world.operations.byId or {}) do
    if record.status == "queued" or record.status == "awaiting-result" then return true end
  end
  for _, record in pairs(state.world.proposalConsensus.byId or {}) do
    if record.status == "pending" then return true end
  end
  for _, record in pairs(state.world.operationConsensus.byId or {}) do
    if record.status == "pending" then return true end
  end
  for _, record in pairs(state.world.checkpointConsensus.byBoundary or {}) do
    if record.status == "pending" then return true end
  end
  return false
end

function M.new(deps)
  assert(type(deps) == "table" and type(deps.getState) == "function",
    "network finance housekeeping state provider is required")
  local getState = deps.getState
  return function()
    local state = getState()
    if state.networkMode ~= "network" or state.initialized ~= true then return true end
    local ledger = finance.ensureNetworkAccounts(state.finance)
    if ledger.initialized ~= true then
      return false, "canonical network accounts are not initialised"
    end
    local reconciliation = ledger.reconciliation or {}
    if reconciliation.nextHousekeepingTick == nil then
      reconciliation.nextHousekeepingTick = state.tick + 1
      return true
    end
    local nextTick = util.integer(reconciliation.nextHousekeepingTick, state.tick + 1)
    if state.tick < nextTick then return true end

    -- Never erase a native construction debit while it is still being sampled,
    -- and never alter wallet presentation inside a physical/checkpoint barrier.
    if hasPhysicalBarrier(state) then
      reconciliation.nextHousekeepingTick = state.tick + M.BLOCKED_STRIDE
      return true
    end

    local ok, result = finance.reconcileNetworkAccounts(state.finance, state.companies, {
      reason = "periodic-native-wallet-cache",
      tick = state.tick,
    })
    local waiting = next(reconciliation.pending or {}) ~= nil
    reconciliation.nextHousekeepingTick = state.tick
      + (waiting and M.PENDING_STRIDE or M.IDLE_STRIDE)
    if not ok then return false, type(result) == "table" and result.error or result end
    return true, result
  end
end

return M
