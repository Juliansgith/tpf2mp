local proposalCodec = require "tpf2_mp/proposal_codec"
local proposalRemovalVerifier = require "tpf2_mp/gui_proposal_removal_verifier"

local M = {}

local function hasConstructionCollateral(transaction)
  if type(transaction) ~= "table"
    or transaction.schemaVersion ~= proposalCodec.CONSTRUCTION_SCHEMA_VERSION then return false end
  local construction = type(transaction.constructions) == "table"
    and transaction.constructions[1] or nil
  return type(construction) == "table" and construction.mode == "build"
    and type(construction.collateral) == "table" and #construction.collateral > 0
end

function M.make(factory, proposal, transaction, materialisation, safeField)
  if factory == nil then return nil, "GUI BuildProposal API is unavailable" end
  -- Vanilla permits a GUI-approved road/track edit or construction placement
  -- to cross its soft Collision warning when that same proposal explicitly
  -- demolishes the obstruction. Critical errors still reject; the exact
  -- removal vector is checked before and after the native proposal processor
  -- converts SimpleProposal.
  local ignoreSoftErrors = proposalCodec.isTopologyConstructionRemoval(transaction)
    or hasConstructionCollateral(transaction)
  local commandOk, commandOrError = pcall(factory, proposal, nil, ignoreSoftErrors)
  if not commandOk then return nil, commandOrError end
  if ignoreSoftErrors then
    local removalsOk, removalsError = proposalRemovalVerifier.verify(
      commandOrError, materialisation, safeField)
    if not removalsOk then return nil, removalsError end
  end
  return commandOrError, nil, { ignoreSoftErrors = ignoreSoftErrors }
end

return M
