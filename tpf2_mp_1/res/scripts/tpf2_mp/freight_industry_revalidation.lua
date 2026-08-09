local util = require "tpf2_mp/util"
local model = require "tpf2_mp/freight_industry_model"

local M = {}

function M.installFault(state, probe, code, detail)
  local fault = {
    operationId = "freight-industry",
    status = "faulted",
    success = false,
    errorCode = tostring(code),
    detail = tostring(detail or ""),
    tick = state.tick,
  }
  local consensus = type(state.world.operationConsensus) == "table"
    and state.world.operationConsensus or {}
  state.world.operationConsensus = consensus
  consensus.sessionFault = util.deepCopy(fault)
  consensus.lastOutcome = util.deepCopy(fault)
  consensus.failed = (tonumber(consensus.failed) or 0) + 1
  state.lastError = "network freight industry fault: " .. fault.errorCode
  probe.status, probe.lastError = "faulted", fault.errorCode .. ": " .. fault.detail
  return fault
end

function M.maintain(state, deps, probe, freight, content)
  if type(content) ~= "table" or content.ready ~= true then
    probe.status = "waiting-for-content-revalidation"
    return false
  end
  if freight.contentDigest ~= content.digest then
    local detail = "saved freight state does not match the agreed industry content"
    M.installFault(state, probe, "freight-industry-content-mismatch", detail)
    return false, detail
  end
  if state.initialized ~= true or state.match.status ~= "running" then
    probe.status = "waiting-for-match-revalidation"
    return false
  end
  if probe.validatedBootstrapDigest ~= freight.bootstrapDigest then
    local facts, factsError = deps.readFacts(state.canonical)
    if not facts then
      M.installFault(state, probe, "freight-industry-binding-unavailable", factsError)
      return false, factsError
    end
    local action, actionError = model.bootstrapAction(
      content.digest, freight.bootstrapEpoch, facts)
    if not action then
      M.installFault(state, probe, "freight-industry-binding-invalid", actionError)
      return false, actionError
    end
    if action.digest ~= freight.bootstrapDigest then
      local detail = "saved freight bootstrap differs from the live canonical industries"
      M.installFault(state, probe, "freight-industry-binding-mismatch", detail)
      return false, detail
    end
    probe.validatedBootstrapDigest = action.digest
    probe.validatedIndustryCount = #action.industries
  end
  probe.status = "ready"
  probe.industryCount = #util.sortedKeys(freight.industries or {})
  probe.lastError = nil
  return false
end

return M
