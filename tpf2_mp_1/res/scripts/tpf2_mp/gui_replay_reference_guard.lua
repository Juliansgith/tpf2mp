local util = require "tpf2_mp/util"

local M = {}

function M.validate(transaction, localRefs, gameApi)
  local references, seen = {}, {}
  for _, edge in ipairs(type(transaction) == "table" and transaction.edges or {}) do
    for _, reference in ipairs({ edge.node0, edge.node1 }) do
      local cid = type(reference) == "table" and reference.cid or nil
      if cid and not seen[cid] then
        seen[cid] = true
        references[#references + 1] = cid
      end
    end
  end
  -- Fresh stations and other self-contained constructions use only negative
  -- transaction-local node slots.  They have no live canonical endpoint to
  -- inspect, and GUI states are not required to expose the engine component
  -- reader merely to materialise those slots.
  if #references == 0 then return true end

  local engine = gameApi and gameApi.engine
  local types = gameApi and gameApi.type and gameApi.type.ComponentType or {}
  if not (engine and util.isCallable(engine.getComponent) and types.BASE_NODE) then
    return nil, "canonical node preflight API is unavailable"
  end
  for _, cid in ipairs(references) do
    local localId = localRefs and tonumber(localRefs[cid]) or nil
    if not localId or localId < 0 then
      return nil, "canonical node is not mapped immediately before replay: " .. tostring(cid)
    end
    if util.isCallable(engine.entityExists) then
      local existsOk, exists = pcall(engine.entityExists, localId)
      if not existsOk or exists ~= true then
        return nil, "canonical node disappeared immediately before replay: " .. tostring(cid)
      end
    end
    local componentOk, component = pcall(engine.getComponent, localId, types.BASE_NODE)
    if not componentOk or component == nil then
      return nil, "canonical node lost BASE_NODE immediately before replay: " .. tostring(cid)
    end
  end
  return true
end

return M
