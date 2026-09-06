local proposalCodec = require "tpf2_mp/proposal_codec"
local constructionReplayPolicy, constructionCollateralPolicy = require "tpf2_mp/construction_replay_policy", require "tpf2_mp/construction_collateral_policy"
local depotConnectionRepair = require "tpf2_mp/construction_depot_connection_repair"
local referenceGuard, world = require "tpf2_mp/gui_replay_reference_guard", require "tpf2_mp/world"

local M = { owns = constructionReplayPolicy.guiOwns,
  isExact = constructionReplayPolicy.isGuiExact,
  omitsCollateral = constructionCollateralPolicy.omit }

function M.isHelperConnection(record)
  return type(record) == "table" and record.replayPath == "helper-depot-connection"
end

function M.materialise(record, localRefs, nativePlayerId, apiValue)
  local omitConstructionCollateral = M.omitsCollateral(record)
  local referencesValid, referenceError = referenceGuard.validate(
    record.transaction, localRefs, apiValue, {
      fingerprint = world.fingerprint,
      omitConstructionCollateral = omitConstructionCollateral })
  if not referencesValid then return nil, referenceError end
  if M.isHelperConnection(record) then
    return depotConnectionRepair.materialise(record, proposalCodec, apiValue)
  end
  local proposal, materialisation = proposalCodec.materialise(record.transaction,
    M.materialiseOptions(record, localRefs, nativePlayerId))
  if not proposal then return nil, materialisation end
  return proposal, {
    transaction = record.transaction,
    materialisation = materialisation,
  }
end

function M.materialiseOptions(record, localRefs, nativePlayerId)
  return {
    resolveLocal = function(cid) return localRefs[cid] end,
    nativePlayerId = nativePlayerId,
    omitConstructionCollateral = M.omitsCollateral(record),
  }
end

function M.rejectOrFallback(record, proposalId, errorValue, queueResult, reject)
  if M.isHelperConnection(record) then
    reject(proposalId, errorValue, false)
    return
  end
  local staged = record.replayPath == "staged-gui-build-proposal"
  if not staged and proposalCodec.isConstructionSchema(record.transaction.schemaVersion)
      and not proposalCodec.isTopologyConstructionRemoval(record.transaction) then
    queueResult({ proposalId = proposalId, success = false,
      fallbackHelper = true, worldUnchanged = true, error = tostring(errorValue) })
  else
    reject(proposalId, errorValue, not staged)
  end
end

return M
