local util = require "tpf2_mp/util"
local economy = require "tpf2_mp/economy"
local finance = require "tpf2_mp/finance"
local world = require "tpf2_mp/world"

local M = {}

function M.new(env)
  assert(type(env) == "table" and type(env.getState) == "function",
    "public snapshot state provider is required")
  assert(type(env.activeCompany) == "function", "active-company provider is required")
  assert(type(env.refreshOwnershipProbe) == "function", "ownership refresher is required")
  assert(type(env.balanceOf) == "function" and type(env.accountOf) == "function",
    "native account providers are required")
  assert(type(env.coreDigest) == "function" and type(env.authoredDigest) == "function",
    "snapshot digest providers are required")
  assert(type(env.deferredNetworkIntents) == "function" and type(env.networkIntentAwaitingOrder) == "function",
    "deferred-intent providers are required")
  local maxDeferredNetworkIntents = env.maxDeferredNetworkIntents or 32
  local function currentState() return env.getState() end

  local function publicSnapshot()
    local deferredNetworkIntents = env.deferredNetworkIntents()
    local networkIntentAwaitingOrder = env.networkIntentAwaitingOrder()
    local cid, company = env.activeCompany()
    local ownership = currentState().probes.ownership or env.refreshOwnershipProbe()
    local proxyBalanceDelta = 0
    if currentState().world.proxyMode and currentState().world.turn and currentState().world.turn.active then
      local currentProxyBalance = env.balanceOf(currentState().world.controlPlayerId) or nil
      if currentProxyBalance and currentState().world.turn.balanceStart then
        proxyBalanceDelta = currentProxyBalance - currentState().world.turn.balanceStart
      end
    end
    local publicCompanies = {}
    for _, companyCid in ipairs(util.sortedKeys(currentState().companies)) do
      local nativeBalance = env.balanceOf(currentState().companies[companyCid].playerId) or nil
      local nativeAccount = env.accountOf(currentState().companies[companyCid].playerId) or {}
      local canonicalAccount = currentState().networkMode == "network"
        and finance.networkAccount(currentState().finance, companyCid) or nil
      local publicBalance = canonicalAccount and canonicalAccount.balance or nativeBalance
      publicCompanies[companyCid] = {
        cid = companyCid,
        name = currentState().companies[companyCid].name,
        balance = publicBalance,
        loan = canonicalAccount and canonicalAccount.loan or nativeAccount.loan,
        nativeBalance = nativeBalance,
        nativeLoan = nativeAccount.loan,
        effectiveBalance = canonicalAccount and canonicalAccount.balance
          or (nativeBalance and (nativeBalance + (companyCid == cid and proxyBalanceDelta or 0)) or nil),
        assets = util.deepCopy(ownership.companies and ownership.companies[companyCid] or { total = 0, byKind = {} }),
      }
    end
    local recent = {}
    local first = math.max(1, #currentState().eventLog.items - 7)
    for index = first, #currentState().eventLog.items do recent[#recent + 1] = util.deepCopy(currentState().eventLog.items[index]) end
    local structural = currentState().probes.structural
    local mobility = currentState().probes.mobility
    local publicProbes = {
      capabilities = util.deepCopy(currentState().probes.capabilities),
      guiCapabilities = util.deepCopy(currentState().probes.guiCapabilities),
      nativeHook = util.deepCopy(currentState().probes.nativeHook),
      networkAuthority = util.deepCopy(currentState().probes.networkAuthority),
      networkCalendar = util.deepCopy(currentState().probes.networkCalendar),
      capture = util.deepCopy(currentState().probes.capture),
      operational = util.deepCopy(currentState().probes.operational),
      lastError = currentState().probes.lastError,
      structuralDigest = structural and structural.digest or nil,
      worldManifestDigest = currentState().probes.worldManifest and currentState().probes.worldManifest.digest or nil,
      worldManifest = currentState().probes.worldManifest and {
        total = currentState().probes.worldManifest.total,
        uniqueBound = currentState().probes.worldManifest.uniqueBound,
        deferredUnique = currentState().probes.worldManifest.deferredUnique,
        ambiguousCount = currentState().probes.worldManifest.ambiguousCount,
        digest = currentState().probes.worldManifest.digest,
      } or nil,
      mobilityDigest = mobility and mobility.digest or nil,
      mobility = mobility and {
        scope = mobility.scope,
        totalPersons = mobility.totalPersons,
        terminalEdges = mobility.terminalEdges,
        terminalFreePlaces = mobility.terminalFreePlaces,
        totals = util.deepCopy(mobility.totals),
        lineCount = #(mobility.lines or {}),
        errors = util.deepCopy(mobility.errors or {}),
      } or nil,
      townCount = structural and #(structural.towns or {}) or 0,
      lineCount = structural and #(structural.lines or {}) or 0,
      industryCount = structural and structural.industryCount or 0,
    }
    return {
      version = currentState().version,
      tick = currentState().tick,
      initialized = currentState().initialized,
      match = util.deepCopy(currentState().match),
      networkMode = currentState().networkMode,
      peerId = currentState().bridge.peerId,
      sessionId = currentState().bridge.sessionId,
      activeCompanyCid = cid,
      activeCompanyName = company and company.name or nil,
      companies = publicCompanies,
      companyOrder = util.deepCopy(currentState().companyOrder),
      marketCount = util.tableCount(currentState().economy.markets),
      serviceCount = util.tableCount(currentState().economy.services),
      epoch = currentState().economy.epoch,
      lastResults = util.deepCopy(currentState().economy.lastResults),
      ledger = util.deepCopy(currentState().economy.ledger),
      scoreboard = economy.scoreboard(currentState().economy, currentState().companies),
      -- Per-peer display only; never digest material.
      stationBoards = world.stationBoards(currentState().economy, currentState().canonical),
      autonomyFrozen = currentState().world.autonomyFrozen,
      neutralizer = util.deepCopy(currentState().finance.neutralizer),
      transfers = util.deepCopy(currentState().finance.transfers),
      startingCash = util.deepCopy(currentState().finance.startingCash),
      networkAccounts = util.deepCopy(currentState().finance.networkAccounts),
      networkClock = util.deepCopy(currentState().world.networkClock),
      proxyMode = currentState().world.proxyMode == true,
      controlAccount = currentState().world.controlPlayerId and env.accountOf(currentState().world.controlPlayerId) or nil,
      turn = util.deepCopy(currentState().world.turn),
      lastTransition = util.deepCopy(currentState().world.lastTransition),
      ownership = util.deepCopy(ownership),
      proposals = {
        queued = currentState().world.proposals.queued or 0,
        applied = currentState().world.proposals.applied or 0,
        failed = currentState().world.proposals.failed or 0,
        retained = util.tableCount(currentState().world.proposals.byId),
      },
      operations = {
        queued = currentState().world.operations.queued or 0,
        applied = currentState().world.operations.applied or 0,
        failed = currentState().world.operations.failed or 0,
        retained = util.tableCount(currentState().world.operations.byId),
      },
      proposalConsensus = {
        completed = currentState().world.proposalConsensus.completed or 0,
        failed = currentState().world.proposalConsensus.failed or 0,
        pending = (function()
          local count = 0
          for _, item in pairs(currentState().world.proposalConsensus.byId or {}) do
            if item.status == "pending" then count = count + 1 end
          end
          return count
        end)(),
        lastOutcome = util.deepCopy(currentState().world.proposalConsensus.lastOutcome),
        sessionFault = util.deepCopy(currentState().world.proposalConsensus.sessionFault),
      },
      operationConsensus = {
        completed = currentState().world.operationConsensus.completed or 0,
        failed = currentState().world.operationConsensus.failed or 0,
        pending = (function()
          local count = 0
          for _, item in pairs(currentState().world.operationConsensus.byId or {}) do
            if item.status == "pending" then count = count + 1 end
          end
          return count
        end)(),
        lastOutcome = util.deepCopy(currentState().world.operationConsensus.lastOutcome),
        sessionFault = util.deepCopy(currentState().world.operationConsensus.sessionFault),
      },
      checkpointConsensus = {
        completed = currentState().world.checkpointConsensus.completed or 0,
        failed = currentState().world.checkpointConsensus.failed or 0,
        pending = (function()
          local count = 0
          for _, item in pairs(currentState().world.checkpointConsensus.byBoundary or {}) do
            if item.status == "pending" then count = count + 1 end
          end
          return count
        end)(),
        lastOutcome = util.deepCopy(currentState().world.checkpointConsensus.lastOutcome),
        lastAgreed = util.deepCopy(currentState().world.checkpointConsensus.lastAgreed),
      },
      deferredNetworkIntent = deferredNetworkIntents[1] and {
        type = deferredNetworkIntents[1].action and deferredNetworkIntents[1].action.type or nil,
        companyCid = deferredNetworkIntents[1].companyCid,
        queuedTick = deferredNetworkIntents[1].queuedTick,
        reason = deferredNetworkIntents[1].reason,
        queueDepth = #deferredNetworkIntents,
        capacity = maxDeferredNetworkIntents,
      } or nil,
      deferredNetworkQueue = {
        count = #deferredNetworkIntents,
        capacity = maxDeferredNetworkIntents,
        awaitingOrder = networkIntentAwaitingOrder and {
          localSeq = networkIntentAwaitingOrder.localSeq,
          type = networkIntentAwaitingOrder.type,
          emittedTick = networkIntentAwaitingOrder.emittedTick,
        } or nil,
      },
      bridge = {
        nextOutSeq = currentState().bridge.nextOutSeq,
        nextInSeq = currentState().bridge.nextInSeq,
        emitted = currentState().bridge.emitted,
        received = currentState().bridge.received,
        lastError = currentState().bridge.lastError,
        lastInboundKind = currentState().bridge.lastInboundKind,
        companion = util.deepCopy(currentState().bridge.companion),
      },
      checkpoint = util.deepCopy(currentState().checkpoint),
      recovery = util.deepCopy(currentState().recovery),
      canonicalCount = util.tableCount(currentState().canonical.byCanonical),
      digest = env.coreDigest(),
      modelDigest = env.authoredDigest(),
      probes = publicProbes,
      validation = util.deepCopy(currentState().validation),
      recentEvents = recent,
      lastAction = util.deepCopy(currentState().lastAction),
      lastResult = util.deepCopy(currentState().lastResult),
      lastError = currentState().lastError,
    }
  end
  

  return publicSnapshot
end

return M
