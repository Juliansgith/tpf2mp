local M = {}

function M.validate(transaction, localRefs, gameApi)
  local engine = gameApi and gameApi.engine
  local types = gameApi and gameApi.type and gameApi.type.ComponentType or {}
  if not (engine and type(engine.getComponent) == "function" and types.BASE_NODE) then
    return nil, "canonical node preflight API is unavailable"
  end
  local checked = {}
  for _, edge in ipairs(type(transaction) == "table" and transaction.edges or {}) do
    for _, reference in ipairs({ edge.node0, edge.node1 }) do
      local cid = type(reference) == "table" and reference.cid or nil
      if cid and not checked[cid] then
        local localId = localRefs and tonumber(localRefs[cid]) or nil
        if not localId or localId < 0 then
          return nil, "canonical node is not mapped immediately before replay: " .. tostring(cid)
        end
        if type(engine.entityExists) == "function" then
          local existsOk, exists = pcall(engine.entityExists, localId)
          if not existsOk or exists ~= true then
            return nil, "canonical node disappeared immediately before replay: " .. tostring(cid)
          end
        end
        local componentOk, component = pcall(engine.getComponent, localId, types.BASE_NODE)
        if not componentOk or component == nil then
          return nil, "canonical node lost BASE_NODE immediately before replay: " .. tostring(cid)
        end
        checked[cid] = true
      end
    end
  end
  return true
end

return M
