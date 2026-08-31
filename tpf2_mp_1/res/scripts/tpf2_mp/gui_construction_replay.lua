local proposalCodec = require "tpf2_mp/proposal_codec"
local constructionReplayPolicy = require "tpf2_mp/construction_replay_policy"
local depotConnectionRepair = require "tpf2_mp/construction_depot_connection_repair"

local M = {
  owns = constructionReplayPolicy.guiOwns,
  isExact = constructionReplayPolicy.isGuiExact,
}

function M.isHelperConnection(record)
  return type(record) == "table" and record.replayPath == "helper-depot-connection"
end

function M.materialise(record, localRefs, nativePlayerId, apiValue)
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
    omitConstructionCollateral = record.replayPath == "staged-gui-build-proposal",
  }
end

function M.rejectOrFallback(record, proposalId, errorValue, queueResult, reject)
  if M.isHelperConnection(record) then
    reject(proposalId, errorValue, false)
    return
  end
  local staged = record.replayPath == "staged-gui-build-proposal"
  if not staged and record.transaction.schemaVersion == proposalCodec.CONSTRUCTION_SCHEMA_VERSION
      and not proposalCodec.isTopologyConstructionRemoval(record.transaction) then
    queueResult({ proposalId = proposalId, success = false,
      fallbackHelper = true, worldUnchanged = true, error = tostring(errorValue) })
  else
    reject(proposalId, errorValue, not staged)
  end
end

return M
