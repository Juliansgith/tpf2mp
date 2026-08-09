local util = require "tpf2_mp/util"

local M = {}

M.SCHEMA_VERSION = 1
M.DEFAULT_REQUIRED_PEERS = { "player1", "player2" }

local MAX_COUNT = 1000000

local function copyRequiredPeers(value)
  local result, seen = {}, {}
  for _, peer in ipairs(type(value) == "table" and value or M.DEFAULT_REQUIRED_PEERS) do
    peer = tostring(peer or "")
    if peer:match("^player[1-9][0-9]*$") and #peer <= 64 and not seen[peer] then
      seen[peer] = true
      result[#result + 1] = peer
    end
  end
  table.sort(result)
  if #result == 0 then return util.deepCopy(M.DEFAULT_REQUIRED_PEERS) end
  return result
end

function M.newState(requiredPeers)
  return {
    schemaVersion = M.SCHEMA_VERSION,
    requiredPeers = copyRequiredPeers(requiredPeers),
    attestations = {},
    ready = false,
    digest = nil,
    resourceCount = 0,
    variantCount = 0,
    ambiguousCount = 0,
    fault = nil,
  }
end

function M.newProbe()
  return {
    status = "waiting-for-sidecar",
    source = nil,
    localDigest = nil,
    resourceCount = 0,
    variantCount = 0,
    ambiguousCount = 0,
    attempts = 0,
    lastAttemptTick = nil,
    lastError = nil,
  }
end

local function exactInteger(value, minimum, maximum)
  return type(value) == "number" and value == math.floor(value)
    and value >= minimum and value <= maximum
end

function M.validateAction(action)
  if type(action) ~= "table" then return false, "industry content attestation is not a table" end
  local allowed = {
    type = true, peer = true, digest = true, resourceCount = true,
    variantCount = true, ambiguousCount = true,
  }
  for key in pairs(action) do
    if not allowed[key] then
      return false, "industry content attestation has an unknown field: " .. tostring(key)
    end
  end
  for key in pairs(allowed) do
    if action[key] == nil then
      return false, "industry content attestation is missing " .. key
    end
  end
  if action.type ~= "content.industry_attest" then
    return false, "industry content attestation has the wrong action type"
  end
  if type(action.peer) ~= "string" or #action.peer > 64
      or not action.peer:match("^player[1-9][0-9]*$") then
    return false, "industry content attestation has an invalid peer"
  end
  if type(action.digest) ~= "string" or #action.digest ~= 8
      or not action.digest:match("^[0-9a-f]+$") then
    return false, "industry content attestation has an invalid digest"
  end
  for _, field in ipairs({ "resourceCount", "variantCount", "ambiguousCount" }) do
    if not exactInteger(action[field], 0, MAX_COUNT) then
      return false, "industry content attestation has an invalid " .. field
    end
  end
  if action.resourceCount < 1 or action.variantCount < action.resourceCount then
    return false, "industry content attestation has impossible resource counts"
  end
  if action.ambiguousCount > action.variantCount then
    return false, "industry content attestation has impossible ambiguity counts"
  end
  return true
end

function M.normaliseAction(action, localPeer)
  local valid, validationError = M.validateAction(action)
  if not valid then return nil, validationError end
  if action.peer ~= localPeer then
    return nil, "industry content attestation peer does not match this process"
  end
  local result = {
    peer = action.peer, digest = action.digest,
    resourceCount = action.resourceCount, variantCount = action.variantCount,
    ambiguousCount = action.ambiguousCount,
  }
  result.type = "content.industry_attest"
  return result
end

local function actionView(action)
  return {
    peer = action.peer,
    digest = action.digest,
    resourceCount = action.resourceCount,
    variantCount = action.variantCount,
    ambiguousCount = action.ambiguousCount,
  }
end

local function sameAttestation(left, right)
  if type(left) ~= "table" or type(right) ~= "table" then return false end
  for _, field in ipairs({
    "peer", "digest", "resourceCount", "variantCount", "ambiguousCount",
  }) do
    if left[field] ~= right[field] then return false end
  end
  return true
end

local function installFault(state, code, detail)
  local content = state.world.industryContent
  if not content.fault then
    content.fault = { errorCode = code, detail = tostring(detail or ""), tick = state.tick }
  end
  local fault = {
    operationId = "industry-content",
    status = "faulted",
    success = false,
    errorCode = content.fault.errorCode,
    tick = state.tick,
  }
  state.world.operationConsensus.sessionFault = util.deepCopy(fault)
  state.world.operationConsensus.lastOutcome = util.deepCopy(fault)
  state.lastError = "network industry content fault: " .. tostring(content.fault.errorCode)
  return content.fault
end

function M.apply(state, action)
  local valid, validationError = M.validateAction(action)
  if not valid then return false, validationError end
  local content = state.world.industryContent
  if type(content) ~= "table" then
    content = M.newState()
    state.world.industryContent = content
  end
  local required = {}
  for _, peer in ipairs(content.requiredPeers or {}) do required[peer] = true end
  if not required[action.peer] then
    return false, "industry content attestation came from an unexpected peer"
  end
  local incoming = actionView(action)
  local previous = content.attestations[action.peer]
  if previous and not sameAttestation(previous, incoming) then
    local fault = installFault(state, "industry-content-peer-conflict", action.peer)
    return true, { ready = false, fault = util.deepCopy(fault) }
  end
  content.attestations[action.peer] = incoming
  if action.ambiguousCount > 0 then
    local fault = installFault(state, "industry-content-ambiguous", action.peer)
    return true, { ready = false, fault = util.deepCopy(fault) }
  end

  local baseline
  for _, peer in ipairs(content.requiredPeers) do
    local value = content.attestations[peer]
    if not value then
      content.ready = false
      return true, {
        ready = false,
        received = #util.sortedKeys(content.attestations),
        required = #content.requiredPeers,
      }
    end
    if not baseline then
      baseline = value
    elseif baseline.digest ~= value.digest
        or baseline.resourceCount ~= value.resourceCount
        or baseline.variantCount ~= value.variantCount
        or baseline.ambiguousCount ~= value.ambiguousCount then
      local fault = installFault(state, "industry-content-mismatch", peer)
      return true, { ready = false, fault = util.deepCopy(fault) }
    end
  end
  content.ready = true
  content.digest = baseline.digest
  content.resourceCount = baseline.resourceCount
  content.variantCount = baseline.variantCount
  content.ambiguousCount = baseline.ambiguousCount
  content.fault = nil
  return true, {
    ready = true,
    digest = content.digest,
    resourceCount = content.resourceCount,
    variantCount = content.variantCount,
  }
end

function M.digestView(content)
  content = type(content) == "table" and content or M.newState()
  local attestations = {}
  for _, peer in ipairs(util.sortedKeys(content.attestations or {})) do
    attestations[peer] = actionView(content.attestations[peer])
  end
  return {
    schemaVersion = M.SCHEMA_VERSION,
    requiredPeers = copyRequiredPeers(content.requiredPeers),
    attestations = attestations,
    ready = content.ready == true,
    digest = content.digest,
    resourceCount = math.max(0, math.floor(tonumber(content.resourceCount) or 0)),
    variantCount = math.max(0, math.floor(tonumber(content.variantCount) or 0)),
    ambiguousCount = math.max(0, math.floor(tonumber(content.ambiguousCount) or 0)),
    fault = type(content.fault) == "table" and {
      errorCode = tostring(content.fault.errorCode or ""),
      detail = tostring(content.fault.detail or ""),
    } or nil,
  }
end

function M.migrate(value, requiredPeers)
  local result = M.newState(requiredPeers)
  if type(value) ~= "table" then return result end
  result.requiredPeers = copyRequiredPeers(value.requiredPeers or requiredPeers)
  for _, peer in ipairs(result.requiredPeers) do
    local attestation = type(value.attestations) == "table" and value.attestations[peer] or nil
    if type(attestation) == "table" then
      local candidate = actionView(attestation)
      candidate.type = "content.industry_attest"
      if M.validateAction(candidate) then result.attestations[peer] = actionView(candidate) end
    end
  end
  -- Re-evaluate readiness from the retained attestations; never trust a saved
  -- boolean which may predate validation or have been partially written.
  for _, peer in ipairs(result.requiredPeers) do
    local attestation = result.attestations[peer]
    if attestation then
      M.apply({ tick = 0, world = {
        industryContent = result,
        operationConsensus = { sessionFault = nil, lastOutcome = nil },
      } }, {
        type = "content.industry_attest",
        peer = peer,
        digest = attestation.digest,
        resourceCount = attestation.resourceCount,
        variantCount = attestation.variantCount,
        ambiguousCount = attestation.ambiguousCount,
      })
    end
  end
  return result
end

function M.installHandler(handlers, getState)
  handlers["content.industry_attest"] = function(action)
    return M.apply(getState(), action)
  end
end

function M.afterCommit(state, action, success, authoritySeq, exportCheckpoint, log)
  if not success or action.type ~= "content.industry_attest" or not authoritySeq
      or state.world.industryContent.ready ~= true then return false end
  -- Fresh network worlds attest their freight rules before match.initialise
  -- creates canonical accounts. The match-initialised checkpoint immediately
  -- follows and includes this digested content state, so attempting an earlier
  -- financial checkpoint would be both redundant and invalid. A late sidecar
  -- in an already-running match still receives its dedicated boundary below.
  if state.initialized ~= true then
    log("industry-content-checkpoint-deferred", {
      tick = state.tick,
      boundarySeq = authoritySeq,
      reason = "match-not-initialised",
    })
    return true
  end
  local checkpointed, checkpointError = exportCheckpoint(
    authoritySeq, "industry-content-ready")
  if not checkpointed then
    log("checkpoint-barrier-error", {
      tick = state.tick,
      boundarySeq = authoritySeq,
      error = tostring(checkpointError),
    })
  end
  return true
end

function M.maintain(state, deps)
  local probe = state.probes.industryContent
  if type(probe) ~= "table" then
    probe = M.newProbe()
    state.probes.industryContent = probe
  end
  local content = state.world.industryContent or M.newState()
  state.world.industryContent = content
  if content.fault then
    probe.status = "faulted"
    probe.lastError = tostring(content.fault.errorCode or "industry-content-fault")
    return false
  end
  local localPeer = tostring(state.bridge.peerId or "")
  local existing = content.attestations and content.attestations[localPeer]
  if existing then
    probe.status = content.ready and "ready" or "attested-waiting-for-peer"
    probe.localDigest = existing.digest
    probe.resourceCount = existing.resourceCount
    probe.variantCount = existing.variantCount
    probe.ambiguousCount = existing.ambiguousCount
    probe.lastError = nil
    return false
  end
  local facts = deps.readFacts()
  if type(facts) ~= "table" or facts.available ~= true then
    probe.status = "waiting-for-sidecar"
    probe.source = type(facts) == "table" and facts.source or nil
    probe.lastError = type(facts) == "table" and facts.error or "industry registry unavailable"
    return false
  end
  probe.source = facts.source
  probe.localDigest = facts.digest
  probe.resourceCount = tonumber(facts.resourceCount) or 0
  probe.variantCount = tonumber(facts.variantCount) or 0
  probe.ambiguousCount = tonumber(facts.ambiguousCount) or 0
  local work = deps.localWorkState()
  if type(work) == "table" and work.pending == true then
    probe.status = "waiting-for-order-lane"
    return false
  end
  local action = {
    type = "content.industry_attest",
    peer = localPeer,
    digest = probe.localDigest,
    resourceCount = probe.resourceCount,
    variantCount = probe.variantCount,
    ambiguousCount = probe.ambiguousCount,
  }
  local valid, validationError = M.validateAction(action)
  if not valid then
    probe.status = "invalid-local-content"
    probe.lastError = validationError
    return false
  end
  probe.attempts = (tonumber(probe.attempts) or 0) + 1
  probe.lastAttemptTick = state.tick
  local accepted, result = deps.submitIntent(action)
  if accepted then
    probe.status = "attestation-submitted"
    probe.lastError = nil
    return true, result
  end
  probe.status = "attestation-rejected"
  probe.lastError = tostring(type(result) == "table" and result.error or result)
  return false, probe.lastError
end

return M
