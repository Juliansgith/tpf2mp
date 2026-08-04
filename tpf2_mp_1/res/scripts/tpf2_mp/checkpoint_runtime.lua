local util = require "tpf2_mp/util"
local hash = require "tpf2_mp/hash"
local canonical = require "tpf2_mp/canonical"
local bridge = require "tpf2_mp/bridge"
local finance = require "tpf2_mp/finance"

local M = {}

function M.new(env)
  assert(type(env) == "table" and type(env.getState) == "function",
    "checkpoint runtime state provider is required")
  assert(type(env.maxEvents) == "function", "event retention provider is required")
  local STATE_VERSION = assert(env.stateVersion, "stateVersion is required")
  local CHECKPOINT_VERSION = assert(env.checkpointVersion, "checkpointVersion is required")
  local EVENT_RECORD_VERSION = assert(env.eventRecordVersion, "eventRecordVersion is required")
  local function currentState() return env.getState() end

  local function economyDigestView()
    local markets, services = {}, {}
    for _, cid in ipairs(util.sortedKeys(currentState().economy.markets)) do
      local value = currentState().economy.markets[cid]
      markets[cid] = {
        cid = value.cid,
        name = value.name,
        demand = value.demand,
        outsideWeight = value.outsideWeight,
        metadata = util.deepCopy(value.metadata or {}),
      }
    end
    for _, cid in ipairs(util.sortedKeys(currentState().economy.services)) do
      local value = currentState().economy.services[cid]
      services[cid] = {
        lineCid = value.lineCid,
        marketCid = value.marketCid,
        companyCid = value.companyCid,
        name = value.name,
        headwaySeconds = value.headwaySeconds,
        journeySeconds = value.journeySeconds,
        fareCents = value.fareCents,
        capacity = value.capacity,
        quality = value.quality,
        enabled = value.enabled,
      }
    end
    return {
      version = currentState().economy.version,
      epoch = currentState().economy.epoch,
      markets = markets,
      services = services,
      lastResults = util.deepCopy(currentState().economy.lastResults),
      ledger = util.deepCopy(currentState().economy.ledger),
    }
  end
  
  local function authoredStateSnapshot()
    local companies = {}
    for _, cid in ipairs(util.sortedKeys(currentState().companies)) do
      companies[cid] = { cid = cid, name = currentState().companies[cid].name }
    end
    -- Local engine ticks are diagnostic clocks, not authored match currentState(). Two
    -- machines can consume the same ordered command on different update ticks.
    -- Keep lifecycle ticks in saves/research, but exclude them from convergence.
    local match = currentState().match or {}
    local authoredMatch = {
      status = match.status,
      winnerCid = match.winnerCid,
      finishReason = match.finishReason,
      rules = util.deepCopy(match.rules or {}),
    }
    return {
      initialized = currentState().initialized,
      match = authoredMatch,
      companies = companies,
      companyOrder = util.deepCopy(currentState().companyOrder),
      economy = economyDigestView(),
      networkFinance = finance.networkDigestView(currentState().finance),
      autonomyFrozen = currentState().world.autonomyFrozen,
    }
  end
  
  local function authoredDigest()
    return hash.value(authoredStateSnapshot())
  end
  
  local function coreStateSnapshot()
    local result = authoredStateSnapshot()
    result.canonical = canonical.digestView(currentState().canonical)
    return result
  end
  
  local function coreDigest()
    return hash.value(coreStateSnapshot())
  end
  
  local function trimEvents()
    local maximum = env.maxEvents()
    while #currentState().eventLog.items > maximum do table.remove(currentState().eventLog.items, 1) end
  end
  
  local function actionIsPortable(action)
    if type(action) ~= "table" then return false end
    local actionType = action.type
    if actionType == "world.freeze" or actionType == "fare.adjust"
      or actionType == "economy.seed_demo" or actionType == "economy.settle"
      or actionType == "match.finish" or actionType == "probe.mobility" then
      return action.localLineId == nil
    end
    if actionType == "line.register" then
      return type(action.lineCid) == "string"
        and type(action.companyCid) == "string"
        and type(action.market) == "table"
        and type(action.service) == "table"
        and action.localLineId == nil
    end
    return false
  end
  
  local function checkpointFinancialSnapshot()
    if currentState().networkMode == "network" then
      local view = finance.networkDigestView(currentState().finance)
      if view.initialized ~= true then
        return nil, "canonical network accounts are not initialised"
      end
      return { companies = util.deepCopy(view.accounts) }
    end
    local companies = {}
    for _, companyCid in ipairs(util.sortedKeys(currentState().companies or {})) do
      local company = currentState().companies[companyCid]
      local ok, entity = pcall(game.interface.getEntity, company.playerId)
      local balance = ok and entity and tonumber(entity.balance) or nil
      local loan = ok and entity and tonumber(entity.loan) or 0
      if balance == nil then
        return nil, "native account is unavailable for " .. tostring(companyCid)
      end
      companies[companyCid] = {
        balance = util.integer(balance, 0),
        loan = util.integer(loan, 0),
      }
    end
    return { companies = companies }
  end
  
  local function emitCheckpoint(reason, boundarySeq)
    local model = authoredStateSnapshot()
    local canonicalView = canonical.digestView(currentState().canonical)
    local financial, financialError = checkpointFinancialSnapshot()
    if not financial then
      currentState().checkpoint.lastError = tostring(financialError)
      return false, currentState().checkpoint.lastError
    end
    local items = currentState().eventLog.items or {}
    local nextEventSeq = currentState().eventLog.nextSeq or 1
    local firstRetainedSeq = #items > 0 and items[1].seq or nextEventSeq
    local lastEventSeq = nextEventSeq - 1
    local structuralDigest = currentState().probes.structural and currentState().probes.structural.digest or nil
    local worldManifestDigest = currentState().probes.worldManifest and currentState().probes.worldManifest.digest or nil
    local lastCommitSeq = tonumber(boundarySeq)
    if lastCommitSeq then
      lastCommitSeq = math.max(0, util.integer(lastCommitSeq, 0))
    else
      lastCommitSeq = math.max(0, (currentState().bridge.nextInSeq or 1) - 1)
    end
    local eventCursor = {
      firstRetainedSeq = firstRetainedSeq,
      lastEventSeq = lastEventSeq,
      nextEventSeq = nextEventSeq,
      retainedCount = #items,
      lastCommitSeq = lastCommitSeq,
    }
    local payload = {
      checkpointVersion = CHECKPOINT_VERSION,
      stateVersion = STATE_VERSION,
      protocol = currentState().bridge.protocol,
      sessionId = currentState().bridge.sessionId,
      peerId = currentState().bridge.peerId,
      networkMode = currentState().networkMode,
      tick = currentState().tick,
      reason = tostring(reason or "manual"),
      model = model,
      modelDigest = hash.value(model),
      canonical = canonicalView,
      canonicalDigest = hash.value(canonicalView),
      coreDigest = coreDigest(),
      financial = financial,
      financialDigest = hash.value(financial),
      structuralDigest = structuralDigest,
      worldManifestDigest = worldManifestDigest,
      eventCursor = eventCursor,
    }
    local convergenceView = {
      checkpointVersion = payload.checkpointVersion,
      stateVersion = payload.stateVersion,
      protocol = payload.protocol,
      sessionId = payload.sessionId,
      lastCommitSeq = eventCursor.lastCommitSeq,
      modelDigest = payload.modelDigest,
      canonicalDigest = payload.canonicalDigest,
      coreDigest = payload.coreDigest,
      financialDigest = payload.financialDigest,
    }
    if structuralDigest then convergenceView.structuralDigest = structuralDigest end
    if worldManifestDigest then convergenceView.worldManifestDigest = worldManifestDigest end
    payload.convergenceKey = hash.value(convergenceView)
    payload.checkpointDigest = hash.value(payload)
    local ok, outbound = bridge.emit(currentState().bridge, "checkpoint", payload, currentState().tick)
    currentState().checkpoint.exports = (currentState().checkpoint.exports or 0) + (ok and 1 or 0)
    currentState().checkpoint.lastLocalSeq = ok and outbound.local_seq or currentState().checkpoint.lastLocalSeq
    currentState().checkpoint.lastDigest = ok and payload.checkpointDigest or currentState().checkpoint.lastDigest
    currentState().checkpoint.lastModelDigest = ok and payload.modelDigest or currentState().checkpoint.lastModelDigest
    currentState().checkpoint.lastEventSeq = ok and lastEventSeq or currentState().checkpoint.lastEventSeq
    currentState().checkpoint.lastReason = tostring(reason or "manual")
    currentState().checkpoint.lastError = ok and nil or tostring(outbound)
    currentState().checkpoint.lastConvergenceKey = ok and payload.convergenceKey
      or currentState().checkpoint.lastConvergenceKey
    currentState().checkpoint.lastCoreDigest = ok and payload.coreDigest or currentState().checkpoint.lastCoreDigest
    currentState().checkpoint.lastFinancialDigest = ok and payload.financialDigest
      or currentState().checkpoint.lastFinancialDigest
    currentState().checkpoint.lastBoundarySeq = ok and lastCommitSeq or currentState().checkpoint.lastBoundarySeq
    return ok, ok and {
      localSeq = outbound.local_seq,
      checkpointDigest = payload.checkpointDigest,
      convergenceKey = payload.convergenceKey,
      modelDigest = payload.modelDigest,
      coreDigest = payload.coreDigest,
      financialDigest = payload.financialDigest,
      lastEventSeq = lastEventSeq,
    } or currentState().checkpoint.lastError
  end
  
  local function exportCheckpointBarrier(boundarySeq, reason, proposalId)
    boundarySeq = math.max(1, util.integer(boundarySeq, 0))
    local key = tostring(boundarySeq)
    local barriers = currentState().world.checkpointConsensus
    local record = barriers.byBoundary[key]
    if not record then
      record = {
        boundarySeq = boundarySeq,
        reason = tostring(reason),
        proposalId = proposalId and tostring(proposalId) or nil,
        status = "pending",
        exported = false,
        tick = currentState().tick,
      }
      barriers.byBoundary[key] = record
    end
    if record.status ~= "pending" or record.exported == true then return true, util.deepCopy(record) end
    local ok, result = emitCheckpoint(record.reason, boundarySeq)
    record.lastError = ok and nil or tostring(result)
    if ok then
      record.exported = true
      record.localSeq = result.localSeq
      record.checkpointDigest = result.checkpointDigest
      record.convergenceKey = result.convergenceKey
      record.coreDigest = result.coreDigest
      record.financialDigest = result.financialDigest
      record.lastEventSeq = result.lastEventSeq
    end
    return ok, ok and util.deepCopy(record) or record.lastError
  end
  
  local function emitEventRecord(event)
    local payload = {
      recordVersion = EVENT_RECORD_VERSION,
      stateVersion = STATE_VERSION,
      localEventSeq = event.seq,
      commitSeq = event.commitSeq,
      eventId = event.eventId,
      tick = event.tick,
      actor = event.actor,
      action = util.deepCopy(event.action),
      preDigest = event.preDigest,
      postDigest = event.postDigest,
      preModelDigest = event.preModelDigest,
      postModelDigest = event.postModelDigest,
      success = event.success,
      portable = actionIsPortable(event.action),
    }
    payload.recordDigest = hash.value(payload)
    local ok, result = bridge.emit(currentState().bridge, "event", payload, currentState().tick)
    if not ok then currentState().checkpoint.lastError = tostring(result) end
    return ok, result
  end
  

  return {
    authoredDigest = authoredDigest,
    coreDigest = coreDigest,
    trimEvents = trimEvents,
    emitCheckpoint = emitCheckpoint,
    exportCheckpointBarrier = exportCheckpointBarrier,
    emitEventRecord = emitEventRecord,
  }
end

return M
