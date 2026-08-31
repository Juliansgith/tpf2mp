local operationCodec = require "tpf2_mp/operation_codec"

local M = {}

local function stockBusTransaction(depotCid, companyCid)
  -- The Build 35924 base archive contains the v2 resource names.  The old
  -- codec unit fixture deliberately used a fake `benz.mdl` repository entry;
  -- that name is not a stock resource and therefore cannot drive a native
  -- validation run.  Try the region-neutral European buses oldest-first so
  -- this slice remains valid for pinned saves from any playable year.
  local config, configError
  for _, model in ipairs({
    "vehicle/bus/landauer_v2.mdl",
    "vehicle/bus/benz_o6600_v2.mdl",
    "vehicle/bus/saurer_tuescher_v2.mdl",
    "vehicle/bus/man_sl_192_v2.mdl",
    "vehicle/bus/volvo_5000_v2.mdl",
    "vehicle/bus/ecitaro_v2.mdl",
  }) do
    config, configError = operationCodec.defaultVehicleConfig({ model }, api)
    if config then break end
  end
  if not config then return nil, configError end
  return operationCodec.make("vehicle.buy", companyCid, {
    depotCid = depotCid, config = config,
  })
end

local function vehicleOutput(result)
  local found
  for _, output in ipairs(type(result) == "table" and result.outputs or {}) do
    if output.kind == "vehicle" and output.slot == "vehicle:1" then found = output.cid end
  end
  return found
end

function M.new(deps)
  local getState = assert(deps.getState, "vehicle-purchase validation state is required")
  local transition = assert(deps.transition, "vehicle-purchase validation transition is required")
  local check = assert(deps.check, "vehicle-purchase validation check is required")
  local submit = assert(deps.submit, "vehicle-purchase validation submit is required")
  local checkpoint = assert(deps.checkpoint, "vehicle-purchase validation checkpoint is required")
  local finish = assert(deps.finish, "vehicle-purchase validation finish is required")
  local makeTransaction = deps.makeTransaction or stockBusTransaction

  local function begin(depotCid, companyCid)
    local state, consensus = getState(), getState().world.operationConsensus
    state.validation.values.depotPurchaseCompletedBefore = consensus.completed or 0
    state.validation.values.depotPurchaseRejectedBefore = consensus.rejected or 0
    state.validation.values.depotPurchaseFailedBefore = consensus.failed or 0
    if state.bridge.peerId == "player1" then
      local transaction, transactionError = makeTransaction(depotCid, companyCid)
      check("connected-road-depot-bus-transaction-valid", transaction ~= nil, {
        error = transactionError, depotCid = depotCid,
        digest = transaction and transaction.digest or nil,
      })
      -- Canonical operations have one ordered phase. `operation.prepare` is
      -- intentionally not a wire action (proposals alone use prepare/build).
      local result = submit({ type = "operation.execute", transaction = transaction },
        "connected-road-depot-bus-purchase-queued")
      state.validation.values.depotPurchaseLocalSeq = result and result.local_seq
    end
    transition("wait-for-connected-road-depot-bus-consensus")
  end

  local function maintain(stage)
    local state = getState()
    if stage == "wait-for-connected-road-depot-bus-consensus" then
      local consensus = state.world.operationConsensus
      if (consensus.completed or 0) <= (state.validation.values.depotPurchaseCompletedBefore or 0)
          and (consensus.rejected or 0) <= (state.validation.values.depotPurchaseRejectedBefore or 0)
          and (consensus.failed or 0) <= (state.validation.values.depotPurchaseFailedBefore or 0) then
        return true
      end
      local outcome = consensus.lastOutcome
      local record = outcome and state.world.operations.byId[outcome.operationId] or nil
      local result = record and record.result or nil
      local vehicleCid = vehicleOutput(result)
      check("connected-road-depot-bus-physical-consensus",
        outcome and outcome.success == true, outcome)
      check("connected-road-depot-bus-created", vehicleCid ~= nil, result)
      state.validation.values.depotPurchaseOperationId =
        outcome and outcome.operationId or nil
      state.validation.values.depotPurchaseVehicleCid = vehicleCid
      transition("wait-for-connected-road-depot-bus-checkpoint")
      return true
    end
    if stage == "wait-for-connected-road-depot-bus-checkpoint" then
      local wanted = state.validation.values.depotPurchaseOperationId
      local agreed = checkpoint(function(record)
        return wanted ~= nil and tostring(record.proposalId or "") == tostring(wanted)
      end)
      if not agreed then return true end
      check("connected-road-depot-bus-checkpoint-consensus", agreed.success == true, agreed)
      finish(agreed.boundarySeq)
      return true
    end
    return false
  end

  return { begin = begin, maintain = maintain }
end

return M
