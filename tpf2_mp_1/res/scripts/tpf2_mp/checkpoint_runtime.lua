local util = require "tpf2_mp/util"
local hash = require "tpf2_mp/hash"
local canonical = require "tpf2_mp/canonical"
local bridge = require "tpf2_mp/bridge"
local finance = require "tpf2_mp/finance"
local vehicleSyncRuntime = require "tpf2_mp/vehicle_sync_runtime"
local industryContentRuntime = require "tpf2_mp/industry_content_runtime"
local freightIndustryModel = require "tpf2_mp/freight_industry_model"

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
        kind = value.kind,
        demand = value.demand,
        demandResid = value.demandResid,
        outsideWeight = value.outsideWeight,
        votCentsPerHour = value.votCentsPerHour,
        gcOutsideCents = value.gcOutsideCents,
        thetaCents = value.thetaCents,
        waitWeightPm = value.waitWeightPm,
        transferSeconds = value.transferSeconds,
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
        transfers = value.transfers,
        enabled = value.enabled,
        -- Version-2+ share/crowding stocks and the version-3 fare-shock latch
        -- decide future allocations, so
        -- they are authored convergence state, not local bookkeeping.
        sharePpm = value.sharePpm,
        shareResid = value.shareResid,
        lagLoadPpm = value.lagLoadPpm,
        lastFareCents = value.lastFareCents,
        annualVehicleUpkeepCents = value.annualVehicleUpkeepCents,
        upkeepResid = value.upkeepResid,
        capacityResid = value.capacityResid,
        revenueMultiplierResid = value.revenueMultiplierResid,
        metadata = util.deepCopy(value.metadata or {}),
      }
    end
    return {
      version = currentState().economy.version,
      epoch = currentState().economy.epoch,
      params = util.deepCopy(currentState().economy.params),
      markets = markets,
      towns = util.deepCopy(currentState().economy.towns or {}),
      services = services,
      companyCosts = util.deepCopy(currentState().economy.companyCosts or {}),
      vehicleCosts = util.deepCopy(currentState().economy.vehicleCosts or {}),
      deliveryCursors = util.deepCopy(currentState().economy.deliveryCursors or {}),
      payoutResidCents = util.deepCopy(currentState().economy.payoutResidCents or {}),
      scheduler = util.deepCopy(currentState().economy.scheduler or {}),
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
      townDevelopment = util.deepCopy(currentState().world.townDevelopment or {
        schemaVersion = 1, enabled = false, points = {}, cursor = {},
      }),
      industryContent = industryContentRuntime.digestView(
        currentState().world.industryContent),
      freightIndustry = freightIndustryModel.digestView(
        currentState().world.freightIndustry),
    }
  end
  
  local function authoredDigest()
    return hash.value(authoredStateSnapshot())
  end
  
  local function coreStateSnapshot()
    local result = authoredStateSnapshot()
    result.canonical = canonical.digestView(currentState().canonical)
    result.vehicleSynchronization = vehicleSyncRuntime.digestView(currentState().world)
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
      or actionType == "match.finish" or actionType == "probe.mobility"
      or actionType == "probe.structural"
      or actionType == "recovery.resume" or actionType == "town.develop"
      or actionType == "content.industry_attest"
      or actionType == "freight.industry_bootstrap"
      or actionType == "freight.milestone" then
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
    local vehicleSynchronization = vehicleSyncRuntime.digestView(currentState().world)
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
    -- Keep a compact decomposition beside the aggregate probe.  It is not
    -- convergence material; it lets a failed cross-peer comparison identify
    -- whether topology, vehicles, towns, or a native aggregate was unstable
    -- without exporting the potentially very large structural inventory.
    local structuralParts
    if currentState().probes.structural then
      local structural = currentState().probes.structural
      structuralParts = {
        towns = hash.value(structural.towns or {}),
        lines = hash.value(structural.lines or {}),
        vehicles = hash.value(structural.vehicles or {}),
        depots = hash.value(structural.depots or {}),
        objects = hash.value(structural.objects or {}),
        counts = hash.value({
          industryCount = structural.industryCount,
          vehicleCount = structural.vehicleCount,
          depotCount = structural.depotCount,
          constructionCount = structural.constructionCount,
        }),
      }
    end
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
      vehicleSynchronization = vehicleSynchronization,
      vehicleSynchronizationDigest = hash.value(vehicleSynchronization),
      coreDigest = coreDigest(),
      financial = financial,
      financialDigest = hash.value(financial),
      structuralDigest = structuralDigest,
      structuralParts = structuralParts,
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
      vehicleSynchronizationDigest = payload.vehicleSynchronizationDigest,
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
    if currentState().networkMode == "network"
        and finance.networkDigestView(currentState().finance).initialized ~= true then
      currentState().checkpoint.lastError = "canonical network accounts are not initialised"
      return false, currentState().checkpoint.lastError
    end
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

  local function initialActionCheckpoint(action, authoritySeq)
    local restored = action.type == "recovery.resume"
    local reason = restored and "restore-resume:" .. tostring(action.planChecksum)
      or "match-initialised"
    if currentState().networkMode == "network" and authoritySeq then
      return exportCheckpointBarrier(authoritySeq, reason)
    end
    return emitCheckpoint(reason)
  end
  

  return {
    authoredDigest = authoredDigest,
    coreDigest = coreDigest,
    trimEvents = trimEvents,
    emitCheckpoint = emitCheckpoint,
    exportCheckpointBarrier = exportCheckpointBarrier,
    emitEventRecord = emitEventRecord,
    initialActionCheckpoint = initialActionCheckpoint,
  }
end

return M
