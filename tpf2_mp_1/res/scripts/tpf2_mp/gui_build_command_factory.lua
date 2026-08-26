local proposalCodec = require "tpf2_mp/proposal_codec"
local proposalRemovalVerifier = require "tpf2_mp/gui_proposal_removal_verifier"

local M = {}

function M.make(factory, proposal, transaction, materialisation, safeField)
  if factory == nil then return nil, "GUI BuildProposal API is unavailable" end
  -- Vanilla permits a GUI-approved road/track edit to cross its soft Collision
  -- warning when that same proposal explicitly demolishes the obstruction.
  -- Critical errors still reject; the exact removal vector is checked before
  -- and after the native proposal processor converts SimpleProposal.
  local ignoreSoftErrors = proposalCodec.isTopologyConstructionRemoval(transaction)
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
