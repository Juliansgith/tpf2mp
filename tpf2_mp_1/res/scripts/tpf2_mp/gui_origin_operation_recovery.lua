local world = require "tpf2_mp/world"
local operationCodec = require "tpf2_mp/operation_codec"

local M = {}

local function outputState(localId, outputKind)
  localId = tonumber(localId)
  if not localId then return false, nil end
  local types = api.type and api.type.ComponentType or {}
  local componentType = outputKind == "line" and types.LINE
    or outputKind == "vehicle" and types.TRANSPORT_VEHICLE or nil
  -- Build 35924 can expose a typed component one GUI frame before
  -- entityExists reports the slot. A typed positive is the stronger proof and
  -- prevents a transient false negative from duplicating the native output.
  if componentType and api.engine and api.engine.getComponent then
    local componentOk, component = pcall(api.engine.getComponent, localId, componentType)
    if componentOk and component ~= nil then return true, outputKind end
  end
  local existsOk, exists = pcall(world.entityExists, localId)
  if not existsOk then
    return nil, "optimistic origin output existence probe failed: " .. tostring(exists)
  end
  if not exists then return false, nil end
  local kindOk, actualKind = pcall(world.kindOf, localId)
  if not kindOk then
    return nil, "optimistic origin output kind probe failed: " .. tostring(actualKind)
  end
  return true, actualKind
end

-- Decide whether an already-applied vanilla operation can be acknowledged or
-- must be replayed. Only a genuinely vanished line.create is replayable:
-- every other missing or mistyped output remains a fail-closed result.
function M.decide(record)
  if type(record) ~= "table" or type(record.originApplied) ~= "table" then
    return { mode = "ordinary" }
  end
  if type(record.transaction) ~= "table" then
    return nil, "optimistic origin operation has no canonical transaction"
  end
  local spec = operationCodec.spec(record.transaction.kind)
  if type(spec) ~= "table" then
    return nil, "optimistic origin operation kind is unsupported"
  end
  if not spec.outputKind then return { mode = "ack" } end
  local localId = tonumber(record.originApplied.localId)
  local exists, kindOrError = outputState(localId, spec.outputKind)
  if exists == nil then return nil, kindOrError end
  if exists then
    if kindOrError ~= spec.outputKind then
      return nil, "optimistic origin output changed kind to " .. tostring(kindOrError)
    end
    return { mode = "ack", outputLocalId = localId }
  end
  if record.transaction.kind == "line.create" then return { mode = "replay" } end
  return nil, "optimistic origin output disappeared before finalisation"
end

return M
