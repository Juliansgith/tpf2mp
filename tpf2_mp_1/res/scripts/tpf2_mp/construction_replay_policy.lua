local M = {}
local connectionReplay = require "tpf2_mp/construction_connection_replay"
local depotConnectionRepair = require "tpf2_mp/construction_depot_connection_repair"

local function exactBuildShape(record, codec)
  local transaction = record and record.transaction
  local construction = type(transaction) == "table"
    and type(transaction.constructions) == "table" and transaction.constructions[1] or nil
  return type(transaction) == "table"
    and transaction.schemaVersion == codec.CONSTRUCTION_SCHEMA_VERSION
    and type(construction) == "table" and construction.mode == "build"
    -- Every fresh depot root stays on the Build 35924 context-helper-safe
    -- engine helper. Connected street depots receive a later topology-only
    -- GUI repair; no depot ConstructionEntity is ever typed across Lua.
    and construction.kind ~= "depot"
    and not codec.isTopologyConstructionRemoval(transaction)
end

function M.isExact(record, codec)
  local construction = exactBuildShape(record, codec)
    and record.transaction.constructions[1] or nil
  -- A typed ConstructionEntity is safe to convert directly only when it owns
  -- no existing construction roots. Build 35924 crashes before
  -- BuildProposalVisitor when module-bearing construction data and live
  -- collateral roots cross its Lua-table converter together.
  return type(construction) == "table" and #(construction.collateral or {}) == 0
end

function M.isStagedExact(record, codec)
  local construction = exactBuildShape(record, codec)
    and record.transaction.constructions[1] or nil
  -- Collateral builds use two native stages: the game-script helper retires
  -- only the declared roots, then GUI state issues the exact typed proposal
  -- without those already-absent roots. This preserves road/track attachment
  -- topology without re-entering the crashing converter shape.
  return type(construction) == "table" and #(construction.collateral or {}) > 0
end

function M.isGuiExact(record)
  local replayPath = type(record) == "table" and record.replayPath or nil
  return replayPath == "gui-build-proposal"
    or replayPath == "staged-gui-build-proposal"
end

function M.guiOwns(record) return M.isGuiExact(record) or type(record) == "table" and record.replayPath == "helper-depot-connection" end

function M.requiresAtomic(record, codec)
  local transaction = type(record) == "table" and record.transaction or nil
  local construction = type(transaction) == "table"
    and type(transaction.constructions) == "table" and transaction.constructions[1] or nil
  if connectionReplay.isConnectedStreetDepot(transaction, construction) then return true end
  if not M.isExact(record, codec) and not M.isStagedExact(record, codec) then return false end
  local remove = type(transaction.remove) == "table" and transaction.remove or {}
  local edgeObjects = type(transaction.edgeObjects) == "table" and transaction.edgeObjects or {}
  -- Transform-only fallback would detach any captured existing-road endpoint,
  -- independent of the construction's stock/mod resource name.
  return connectionReplay.hasExistingStreetEndpoint(transaction, construction)
    or #(construction.collateral or {}) > 0
    or #(remove.edges or {}) > 0 or #(remove.nodes or {}) > 0
    or #(edgeObjects.add or {}) > 0 or #(edgeObjects.retain or {}) > 0
    or #(edgeObjects.remove or {}) > 0
end

M.connection = connectionReplay
M.helperSafe = depotConnectionRepair.helperSafe

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
