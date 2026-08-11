local util = require "tpf2_mp/util"

local M = {}

local COUNTERS = {
  "preCommitCount", "nativePreCommitCount", "postCommitCount",
  "vehicleIntentCount", "vehicleResolvedCount", "claimedCount",
  "replacementObservedCount", "replacementReboundCount",
  "replacementFailureCount", "replacementRecoveryCount",
  "accessDeniedCount", "entityAccessDeniedCount",
  "proposalCaptureCount", "proposalReplayCount", "proposalReplayFailureCount",
  "proposalCodecFailureCount", "nativeCommandCount", "operationalGuiCount",
  "operationCaptureCount", "operationReplayCount", "operationReplayFailureCount",
}

function M.build(capture)
  capture = type(capture) == "table" and capture or {}
  local result = {}
  for _, field in ipairs(COUNTERS) do result[field] = tonumber(capture[field]) or 0 end
  result.claimedByKind = util.deepCopy(capture.claimedByKind or {})
  result.nativeCommandOrigins = util.deepCopy(capture.nativeCommandOrigins or {})
  result.lastProposalCodecFailure = util.deepCopy(capture.lastProposalCodecFailure)
  result.lastAccessDenial = util.deepCopy(capture.lastAccessDenial)
  -- Full proposal/event envelopes stay in research exports. Copying them into
  -- every GUI snapshot previously re-serialized megabytes after large builds.
  result.retainedResearch = {
    eventShapes = #(capture.eventShapes or {}),
    proposalSnapshots = #(capture.proposalSnapshots or {}),
    nativeCommands = #(capture.nativeCommandHistory or {}),
    operationalGui = #(capture.operationalGuiHistory or {}),
  }
  return result
end

return M
