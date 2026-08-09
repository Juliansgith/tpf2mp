local hash = require "tpf2_mp/hash"
local model = require "tpf2_mp/freight_industry_model"
local revalidation = require "tpf2_mp/freight_industry_revalidation"

local M = {}

local function ensureProbe(state)
  state.probes.freightIndustry = type(state.probes.freightIndustry) == "table"
    and state.probes.freightIndustry or model.newProbe()
  return state.probes.freightIndustry
end

local function classify(industries)
  local sources, processors = 0, 0
  for _, industry in ipairs(industries or {}) do
    local source = false
    for _, alternative in ipairs(industry.inputs or {}) do
      if #alternative == 0 then source = true; break end
    end
    if source then sources = sources + 1 else processors = processors + 1 end
  end
  return sources, processors
end

function M.applyBootstrap(state, action, deps)
  local valid, rebuiltOrError = model.validateBootstrapAction(action)
  if not valid then return false, rebuiltOrError end
  local rebuilt = rebuiltOrError
  local localFacts, factsError = deps.readFacts(state.canonical)
  if not localFacts then return false, "could not resolve local freight industries: " .. tostring(factsError) end
  local localAction, actionError = model.bootstrapAction(
    state.world.industryContent.digest, state.economy.epoch, localFacts)
  if not localAction then return false, actionError end
  if localAction.digest ~= rebuilt.digest
      or hash.value(localAction.industries) ~= hash.value(rebuilt.industries) then
    return false, "freight bootstrap differs from the local epoch or bound industry recipes"
  end
  local applied, result = model.applyBootstrap(
    state.world.freightIndustry, rebuilt, state.world.industryContent)
  local probe = ensureProbe(state)
  if not applied then
    probe.status, probe.lastError = "bootstrap-rejected", tostring(result)
    return false, result
  end
  local sources, processors = classify(rebuilt.industries)
  probe.status = "ready"
  probe.industryCount = #rebuilt.industries
  probe.sourceCount, probe.processorCount = sources, processors
  probe.validatedBootstrapDigest = rebuilt.digest
  probe.validatedIndustryCount = #rebuilt.industries
  probe.lastError = nil
  return true, result
end

function M.installHandler(handlers, deps)
  handlers["freight.industry_bootstrap"] = function(action)
    local state = deps.getState()
    local running, runningError = deps.requireRunningMatch()
    if not running then return false, runningError end
    return M.applyBootstrap(state, action, { readFacts = deps.readFacts })
  end
end

function M.normaliseIntent(state, peerId, readFacts)
  if peerId ~= "player1" then
    return nil, "only the host peer can bootstrap freight industries"
  end
  if state.world.freightIndustry.ready == true then
    return nil, "freight industries are already bootstrapped"
  end
  if state.world.industryContent.ready ~= true then
    return nil, "industry content must be agreed before freight bootstrap"
  end
  local facts, factsError = readFacts(state.canonical)
  if not facts then return nil, factsError end
  return model.bootstrapAction(
    state.world.industryContent.digest, state.economy.epoch, facts)
end

function M.maintain(state, deps)
  local probe = ensureProbe(state)
  local freight = state.world.freightIndustry
  local content = state.world.industryContent
  if type(freight) ~= "table" then
    freight = model.newState()
    state.world.freightIndustry = freight
  end
  if type(freight.migrationError) == "string" then
    revalidation.installFault(state, probe, "freight-industry-save-invalid",
      freight.migrationError)
    return false, freight.migrationError
  end
  if freight.ready == true then
    return revalidation.maintain(state, deps, probe, freight, content)
  end
  if state.networkMode ~= "network" then
    probe.status = "network-only"
    return false
  end
  if type(content) ~= "table" or content.ready ~= true then
    probe.status = "waiting-for-content"
    return false
  end
  if state.initialized ~= true or state.match.status ~= "running" then
    probe.status = "waiting-for-match"
    return false
  end
  if state.bridge.peerId ~= "player1" then
    probe.status = "waiting-for-host-bootstrap"
    return false
  end
  local work = deps.localWorkState()
  if type(work) == "table" and work.pending == true then
    probe.status = "waiting-for-order-lane"
    return false
  end
  local facts, factsError = deps.readFacts(state.canonical)
  if not facts then
    probe.status = "binding-failed"
    probe.lastError = tostring(factsError)
    return false, probe.lastError
  end
  local action, actionError = model.bootstrapAction(
    content.digest, state.economy.epoch, facts)
  if not action then
    probe.status = "binding-failed"
    probe.lastError = tostring(actionError)
    return false, probe.lastError
  end
  local sources, processors = classify(action.industries)
  probe.industryCount = #action.industries
  probe.sourceCount, probe.processorCount = sources, processors
  probe.attempts = (tonumber(probe.attempts) or 0) + 1
  probe.lastAttemptTick = state.tick
  local submitted, submitResult = deps.submitIntent(action)
  if submitted then
    probe.status, probe.lastError = "bootstrap-submitted", nil
    return true, submitResult
  end
  probe.status = "bootstrap-rejected"
  probe.lastError = tostring(type(submitResult) == "table" and submitResult.error or submitResult)
  return false, probe.lastError
end

function M.advanceCandidate(state, epoch, periodSeconds)
  local candidate = model.migrate(state.world.freightIndustry)
  local advanced, result = model.advance(candidate, epoch, periodSeconds)
  if not advanced then return nil, result end
  return candidate, result
end

function M.prepareSettlement(state, results)
  if state.world.freightIndustry.ready ~= true then return function() end end
  local content = state.world.industryContent
  local probe = ensureProbe(state)
  if type(content) ~= "table" or content.ready ~= true
      or content.digest ~= state.world.freightIndustry.contentDigest then
    return nil, "freight settlement requires revalidated industry content"
  end
  if probe.validatedBootstrapDigest ~= state.world.freightIndustry.bootstrapDigest then
    return nil, "freight settlement requires revalidated live industry bindings"
  end
  local candidate, summary = M.advanceCandidate(
    state, results.epoch, state.economy.scheduler.epochSeconds)
  if not candidate then return nil, summary end
  return function() state.world.freightIndustry = candidate end, summary
end

function M.pump(state, deps)
  local ok, result = xpcall(M.maintain, debug.traceback, state, deps)
  if not ok then ensureProbe(state).lastError = tostring(result) end
  return ok
end

function M.afterCommit(state, action, success, authoritySeq, exportCheckpoint, log)
  if not success or action.type ~= "freight.industry_bootstrap" or not authoritySeq then
    return false
  end
  local checkpointed, checkpointError = exportCheckpoint(
    authoritySeq, "freight-industry-bootstrap")
  if not checkpointed then
    log("checkpoint-barrier-error", {
      tick = state.tick, boundarySeq = authoritySeq,
      error = tostring(checkpointError),
    })
  end
  return true
end

return M
