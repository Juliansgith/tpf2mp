local M = {}

function M.after(action, state, controller, registerLine)
  if type(action) ~= "table" or action.success ~= true
    or tostring(action.reason or ""):find("operation-consensus:", 1, true) ~= 1 then
    return false
  end
  local record = state.world.operations.byId[tostring(action.proposalId or "")]
  if not record then return false end
  local transaction = record.transaction
  if transaction.kind == "line.delete" and controller then
    controller.cancelLineRegistration(transaction.data.targetCid)
  end
  local outputCid = record.result and record.result.outputs
    and record.result.outputs[1] and record.result.outputs[1].cid or nil
  registerLine(transaction, outputCid)
  local priorLines = record.previousLineCids
    or (record.previousLineCid and { record.previousLineCid } or {})
  for _, previousLineCid in ipairs(priorLines) do
    if type(previousLineCid) == "string" and previousLineCid ~= ""
      and not (transaction.data and transaction.data.lineCid == previousLineCid) then
      registerLine({ kind = "vehicle.assign", companyCid = record.companyCid,
        data = { lineCid = previousLineCid } }, nil)
    end
  end
  return true
end

return M
