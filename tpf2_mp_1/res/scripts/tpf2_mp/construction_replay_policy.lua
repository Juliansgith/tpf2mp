local M = {}

function M.isExact(record, codec)
  local transaction = record and record.transaction
  local construction = type(transaction) == "table"
    and type(transaction.constructions) == "table" and transaction.constructions[1] or nil
  local edgeObjects = type(transaction) == "table"
    and type(transaction.edgeObjects) == "table" and transaction.edgeObjects or {}
  -- Fresh builds, including collateral removals and replacement topology, must
  -- remain in one GUI BuildProposal. Typed depots still crash stock selection;
  -- depots, upgrades, and removals retain the proven helper path.
  return type(transaction) == "table"
    and transaction.schemaVersion == codec.CONSTRUCTION_SCHEMA_VERSION
    and type(construction) == "table" and construction.mode == "build"
    and construction.kind ~= "depot"
    and #(edgeObjects.add or {}) == 0 and #(edgeObjects.retain or {}) == 0
    and not codec.isTopologyConstructionRemoval(transaction)
end

function M.requiresAtomic(record, codec)
  if not M.isExact(record, codec) then return false end
  local transaction = record.transaction
  local construction = transaction.constructions[1]
  local remove = type(transaction.remove) == "table" and transaction.remove or {}
  local edgeObjects = type(transaction.edgeObjects) == "table" and transaction.edgeObjects or {}
  return #(construction.collateral or {}) > 0
    or #(remove.edges or {}) > 0 or #(remove.nodes or {}) > 0
    or #(edgeObjects.remove or {}) > 0
end

function M.collateralInputs(record)
  local transaction = type(record) == "table" and record.transaction or nil
  local construction = type(transaction) == "table"
    and type(transaction.constructions) == "table" and transaction.constructions[1] or nil
  local collateral = type(construction) == "table"
    and type(construction.collateral) == "table" and construction.collateral or {}
  local wanted, result = {}, {}
  for _, item in ipairs(collateral) do
    wanted[tostring(item.kind) .. "\0" .. tostring(item.cid)] = true
  end
  for _, input in ipairs(type(record) == "table" and record.localInputs or {}) do
    local key = tostring(input.kind) .. "\0" .. tostring(input.cid)
    if wanted[key] then result[#result + 1] = input end
  end
  if #result ~= #collateral then
    return nil, "construction collateral input set is incomplete"
  end
  return result
end

return M
