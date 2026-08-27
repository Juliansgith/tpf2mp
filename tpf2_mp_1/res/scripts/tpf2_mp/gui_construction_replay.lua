local proposalCodec = require "tpf2_mp/proposal_codec"
local constructionReplayPolicy = require "tpf2_mp/construction_replay_policy"

local M = {
  owns = constructionReplayPolicy.guiOwns,
  isExact = constructionReplayPolicy.isGuiExact,
}

function M.materialiseOptions(record, localRefs, nativePlayerId)
  return {
    resolveLocal = function(cid) return localRefs[cid] end,
    nativePlayerId = nativePlayerId,
    omitConstructionCollateral = record.replayPath == "staged-gui-build-proposal",
  }
end

function M.rejectOrFallback(record, proposalId, errorValue, queueResult, reject)
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
