local util = require "tpf2_mp/util"
local canonical = require "tpf2_mp/canonical"
local economy = require "tpf2_mp/economy"
local bridge = require "tpf2_mp/bridge"
local finance = require "tpf2_mp/finance"

local M = {}

function M.new(cfg, versions)
  local STATE_VERSION = assert(versions and versions.stateVersion, "stateVersion is required")
  local CHECKPOINT_VERSION = assert(versions and versions.checkpointVersion, "checkpointVersion is required")
  local validationEnabled = cfg.autoValidate or cfg.networkAutoValidate
  local validationKind = cfg.networkAutoValidate and "localhost-network" or "standalone"
  local result = {
    version = STATE_VERSION,
    tick = 0,
    initialized = false,
    networkMode = cfg.startNetwork and "network" or "standalone",
    match = {
      status = "setup",
      startedTick = nil,
      finishedTick = nil,
      winnerCid = nil,
      finishReason = nil,
      rules = {
        startingCash = cfg.startingCash,
        maxEpochs = cfg.maxEpochs,
        valuationTargetCents = cfg.valuationTargetCents,
      },
    },
    companies = {},
    companyOrder = {},
    activeCompanyIndex = 1,
    canonical = canonical.newState(),
    economy = economy.newState(),
    finance = finance.newState(),
    world = {
      playerIds = {},
      controlPlayerId = nil,
      proxyBankBaseline = nil,
      proxyMode = false,
      pauseOnSwitch = cfg.pauseOnSwitch,
      autonomyFrozen = false,
      logicalOwners = {},
      logicalOwnershipAuthoritative = false,
      initialNetworkOwnership = nil,
      pinnedCustody = {},
      proposals = {
        byId = {},
        queued = 0,
        applied = 0,
        failed = 0,
      },
      proposalConsensus = {
        byId = {},
        completed = 0,
        failed = 0,
        lastOutcome = nil,
        sessionFault = nil,
      },
      operations = {
        byId = {},
        queued = 0,
        applied = 0,
        failed = 0,
      },
      operationConsensus = {
        byId = {},
        completed = 0,
        failed = 0,
        lastOutcome = nil,
        sessionFault = nil,
      },
      checkpointConsensus = {
        byBoundary = {},
        completed = 0,
        failed = 0,
        lastOutcome = nil,
        lastAgreed = nil,
      },
      networkClock = {
        requestedSpeed = 0,
        effectiveSpeed = 0,
        generation = 0,
        reason = "initial-paused",
        lastCommandTick = nil,
        lastNativeSuccess = nil,
        lastError = nil,
        healthEmitted = 0,
        lastHealthLocalSeq = nil,
      },
      turn = nil,
      lastTransition = nil,
    },
    bridge = bridge.newState(cfg),
    eventLog = { nextSeq = 1, items = {} },
    checkpoint = {
      version = CHECKPOINT_VERSION,
      exports = 0,
      lastLocalSeq = nil,
      lastDigest = nil,
      lastModelDigest = nil,
      lastEventSeq = nil,
      lastReason = nil,
      lastError = nil,
      lastConvergenceKey = nil,
      lastCoreDigest = nil,
      lastFinancialDigest = nil,
      lastBoundarySeq = nil,
    },
    recovery = {
      schemaVersion = 1,
      freshNetworkBootstrap = nil,
      bridgeRebinds = 0,
      lastBridgeRebind = nil,
    },
    probes = {
      capabilities = {},
      guiCapabilities = {},
      nativeHook = { available = false },
      networkAuthority = {
        ready = not cfg.startNetwork,
        mode = cfg.startNetwork and "network" or "standalone",
        error = cfg.startNetwork and "native authority gates have not been initialised" or nil,
      },
      networkCalendar = {
        frozen = false,
        requested = false,
        error = cfg.startNetwork and "network calendar freeze has not been requested" or nil,
      },
      mobility = nil,
      mobilityHistory = {},
      capture = {
        preCommitCount = 0,
        nativePreCommitCount = 0,
        postCommitCount = 0,
        vehicleIntentCount = 0,
        vehicleResolvedCount = 0,
        claimedCount = 0,
        claimedByKind = {},
        lastNativeEvent = nil,
        lastProposalSnapshot = nil,
        proposalSnapshots = {},
        eventShapes = {},
        replacementObservedCount = 0,
        replacementReboundCount = 0,
        replacementFailureCount = 0,
        replacementRecoveryCount = 0,
        lastReplacement = nil,
        lastReplacementRecovery = nil,
        replacementHistory = {},
        replacementRecoveryHistory = {},
        accessDeniedCount = 0,
        entityAccessDeniedCount = 0,
        proposalCaptureCount = 0,
        proposalReplayCount = 0,
        proposalReplayFailureCount = 0,
        proposalCodecFailureCount = 0,
        proposalCodecFailures = {},
        lastProposalCodecFailure = nil,
        lastAccessDenial = nil,
        nativeCommandCount = 0,
        nativeCommandOrigins = {},
        nativeCommandHistory = {},
        operationalGuiCount = 0,
        operationalGuiHistory = {},
        operationCaptureCount = 0,
        operationReplayCount = 0,
        operationReplayFailureCount = 0,
        lastCanonicalOperation = nil,
      },
      operational = {
        enabled = cfg.operationalCapture,
        mode = cfg.operationalCapture and "local-observation-only" or "disabled",
        intervalTicks = cfg.operationalSampleTicks,
        nextSampleTick = cfg.operationalSampleTicks,
        sampleCount = 0,
        emittedCount = 0,
        samples = {},
        lastSample = nil,
        lastJournalTimeMs = nil,
        autoInitAttempted = false,
        autoInit = nil,
        lastError = nil,
      },
      structural = nil,
      worldManifest = nil,
      ownership = nil,
      lastResearch = nil,
      lastError = nil,
    },
    validation = {
      enabled = validationEnabled,
      kind = validationKind,
      sessionId = cfg.sessionId,
      peerId = cfg.peerId,
      status = validationEnabled and "pending" or "disabled",
      stage = cfg.networkAutoValidate and "wait-for-network"
        or (cfg.autoValidate and "wait-for-world" or "disabled"),
      stageStartedTick = 0,
      startedTick = nil,
      completedTick = nil,
      checks = {},
      values = {},
      error = nil,
    },
    lastAction = nil,
    lastResult = nil,
    lastError = nil,
  }
  result.finance.neutralizer.enabled = cfg.neutralizer
  return result
end


function M.migrate(saved, context)
  local newState = assert(context and context.newState, "newState callback is required")
  local config = assert(context and context.config, "config callback is required")
  local STATE_VERSION = assert(context.stateVersion, "stateVersion is required")
  local CHECKPOINT_VERSION = assert(context.checkpointVersion, "checkpointVersion is required")
  if type(saved) ~= "table" then return newState() end
  local cfg = config()
  -- A local/hot-seat state cannot be promoted in place, and a saved network
  -- match cannot donate its barriers/accounts to a differently identified
  -- network session. Retain the physical map in both cases but start a clean
  -- canonical match state. Resuming the same session ID still preserves its
  -- canonical state and merely rebinds the machine-local bridge/peer below.
  local priorSessionId = saved.bridge and saved.bridge.sessionId or nil
  local networkSessionChanged = tostring(priorSessionId or "") ~= tostring(cfg.sessionId)
  if cfg.startNetwork and saved.initialized == true
    and (saved.networkMode ~= "network" or networkSessionChanged) then
    local previous = {
      version = saved.version,
      networkMode = saved.networkMode,
      initialized = saved.initialized,
      priorSessionId = priorSessionId,
      priorPeerId = saved.bridge and saved.bridge.peerId or nil,
    }
    local fresh = newState()
    fresh.recovery.freshNetworkBootstrap = {
      reason = saved.networkMode ~= "network"
        and "launcher-network-over-local-save"
        or "launcher-new-network-session-over-prior-network-save",
      previous = previous,
      sessionId = fresh.bridge.sessionId,
      peerId = fresh.bridge.peerId,
    }
    return fresh
  end
  local defaults = newState()
  for key, value in pairs(defaults) do
    if saved[key] == nil then saved[key] = value end
  end
  saved.canonical = saved.canonical or canonical.newState()
  saved.canonical.byCanonical = saved.canonical.byCanonical or {}
  saved.canonical.byLocal = saved.canonical.byLocal or {}
  saved.economy = economy.migrate(saved.economy or economy.newState())
  saved.economy.markets = saved.economy.markets or {}
  saved.economy.services = saved.economy.services or {}
  saved.economy.lastResults = saved.economy.lastResults or { markets = {}, companies = {} }
  saved.economy.ledger = saved.economy.ledger or economy.newState().ledger
  saved.finance = saved.finance or finance.newState()
  saved.match = saved.match or util.deepCopy(defaults.match)
  saved.match.rules = saved.match.rules or util.deepCopy(defaults.match.rules)
  if saved.match.rules.startingCash == nil then saved.match.rules.startingCash = defaults.match.rules.startingCash end
  if saved.match.rules.maxEpochs == nil then saved.match.rules.maxEpochs = defaults.match.rules.maxEpochs end
  if saved.match.rules.valuationTargetCents == nil then
    saved.match.rules.valuationTargetCents = defaults.match.rules.valuationTargetCents
  end
  if saved.match.status == nil then saved.match.status = saved.initialized and "running" or "setup" end
  saved.finance.neutralizer = saved.finance.neutralizer or finance.newState().neutralizer
  saved.finance.transfers = saved.finance.transfers or finance.newState().transfers
  saved.finance.startingCash = saved.finance.startingCash or finance.newState().startingCash
  for key, value in pairs(finance.newState().startingCash) do
    if saved.finance.startingCash[key] == nil then saved.finance.startingCash[key] = util.deepCopy(value) end
  end
  local networkAccounts = finance.ensureNetworkAccounts(saved.finance)
  if saved.networkMode == "network" and saved.initialized == true
    and networkAccounts.initialized ~= true then
    -- There is no trustworthy way to infer historical construction debits
    -- from an older save's peer-local wallet. Keep the migration explicit and
    -- require a fresh network match instead of silently inventing balances.
    networkAccounts.requiresFreshMatch = true
    networkAccounts.migrationError = "network finance predates the canonical account ledger; start a fresh match"
  end
  saved.world = saved.world or util.deepCopy(defaults.world)
  saved.world.playerIds = saved.world.playerIds or {}
  saved.world.logicalOwners = saved.world.logicalOwners or {}
  if saved.world.logicalOwnershipAuthoritative == nil then
    saved.world.logicalOwnershipAuthoritative = saved.networkMode == "network"
  end
  saved.world.pinnedCustody = saved.world.pinnedCustody or {}
  saved.world.proposals = saved.world.proposals or util.deepCopy(defaults.world.proposals)
  saved.world.proposals.byId = saved.world.proposals.byId or {}
  saved.world.proposals.queued = math.max(0, util.integer(saved.world.proposals.queued, 0))
  saved.world.proposals.applied = math.max(0, util.integer(saved.world.proposals.applied, 0))
  saved.world.proposals.failed = math.max(0, util.integer(saved.world.proposals.failed, 0))
  saved.world.proposalConsensus = saved.world.proposalConsensus
    or util.deepCopy(defaults.world.proposalConsensus)
  saved.world.proposalConsensus.byId = saved.world.proposalConsensus.byId or {}
  saved.world.proposalConsensus.completed = math.max(0,
    util.integer(saved.world.proposalConsensus.completed, 0))
  saved.world.proposalConsensus.failed = math.max(0,
    util.integer(saved.world.proposalConsensus.failed, 0))
  saved.world.operations = saved.world.operations or util.deepCopy(defaults.world.operations)
  saved.world.operations.byId = saved.world.operations.byId or {}
  saved.world.operations.queued = math.max(0, util.integer(saved.world.operations.queued, 0))
  saved.world.operations.applied = math.max(0, util.integer(saved.world.operations.applied, 0))
  saved.world.operations.failed = math.max(0, util.integer(saved.world.operations.failed, 0))
  saved.world.operationConsensus = saved.world.operationConsensus
    or util.deepCopy(defaults.world.operationConsensus)
  saved.world.operationConsensus.byId = saved.world.operationConsensus.byId or {}
  saved.world.operationConsensus.completed = math.max(0,
    util.integer(saved.world.operationConsensus.completed, 0))
  saved.world.operationConsensus.failed = math.max(0,
    util.integer(saved.world.operationConsensus.failed, 0))
  saved.world.checkpointConsensus = saved.world.checkpointConsensus
    or util.deepCopy(defaults.world.checkpointConsensus)
  saved.world.checkpointConsensus.byBoundary = saved.world.checkpointConsensus.byBoundary or {}
  saved.world.checkpointConsensus.completed = math.max(0,
    util.integer(saved.world.checkpointConsensus.completed, 0))
  saved.world.checkpointConsensus.failed = math.max(0,
    util.integer(saved.world.checkpointConsensus.failed, 0))
  saved.world.networkClock = saved.world.networkClock or util.deepCopy(defaults.world.networkClock)
  for key, value in pairs(defaults.world.networkClock) do
    if saved.world.networkClock[key] == nil then
      saved.world.networkClock[key] = util.deepCopy(value)
    end
  end
  if saved.world.pauseOnSwitch == nil then saved.world.pauseOnSwitch = config().pauseOnSwitch end
  if saved.world.proxyMode == nil then saved.world.proxyMode = false end
  saved.eventLog = saved.eventLog or { nextSeq = 1, items = {} }
  saved.eventLog.items = saved.eventLog.items or {}
  saved.eventLog.nextSeq = saved.eventLog.nextSeq or (#saved.eventLog.items + 1)
  saved.checkpoint = saved.checkpoint or util.deepCopy(defaults.checkpoint)
  for key, value in pairs(defaults.checkpoint) do
    if saved.checkpoint[key] == nil then saved.checkpoint[key] = value end
  end
  saved.checkpoint.version = CHECKPOINT_VERSION
  saved.probes = saved.probes or defaults.probes
  saved.probes.capabilities = saved.probes.capabilities or {}
  saved.probes.guiCapabilities = saved.probes.guiCapabilities or {}
  saved.probes.nativeHook = saved.probes.nativeHook or { available = false }
  saved.probes.worldManifest = saved.probes.worldManifest or nil
  saved.probes.mobilityHistory = saved.probes.mobilityHistory or {}
  saved.probes.networkAuthority = saved.probes.networkAuthority
    or util.deepCopy(defaults.probes.networkAuthority)
  saved.probes.networkCalendar = saved.probes.networkCalendar
    or util.deepCopy(defaults.probes.networkCalendar)
  saved.probes.capture = saved.probes.capture or defaults.probes.capture
  if saved.probes.capture.nativePreCommitCount == nil then saved.probes.capture.nativePreCommitCount = 0 end
  saved.probes.capture.claimedByKind = saved.probes.capture.claimedByKind or {}
  saved.probes.capture.eventShapes = saved.probes.capture.eventShapes or {}
  saved.probes.capture.proposalSnapshots = saved.probes.capture.proposalSnapshots or {}
  if saved.probes.capture.replacementObservedCount == nil then saved.probes.capture.replacementObservedCount = 0 end
  if saved.probes.capture.replacementReboundCount == nil then saved.probes.capture.replacementReboundCount = 0 end
  if saved.probes.capture.replacementFailureCount == nil then saved.probes.capture.replacementFailureCount = 0 end
  if saved.probes.capture.replacementRecoveryCount == nil then saved.probes.capture.replacementRecoveryCount = 0 end
  saved.probes.capture.replacementHistory = saved.probes.capture.replacementHistory or {}
  saved.probes.capture.replacementRecoveryHistory = saved.probes.capture.replacementRecoveryHistory or {}
  if saved.probes.capture.accessDeniedCount == nil then saved.probes.capture.accessDeniedCount = 0 end
  if saved.probes.capture.entityAccessDeniedCount == nil then saved.probes.capture.entityAccessDeniedCount = 0 end
  if saved.probes.capture.proposalCaptureCount == nil then saved.probes.capture.proposalCaptureCount = 0 end
  if saved.probes.capture.proposalReplayCount == nil then saved.probes.capture.proposalReplayCount = 0 end
  if saved.probes.capture.proposalReplayFailureCount == nil then saved.probes.capture.proposalReplayFailureCount = 0 end
  if saved.probes.capture.proposalCodecFailureCount == nil then saved.probes.capture.proposalCodecFailureCount = 0 end
  saved.probes.capture.proposalCodecFailures = saved.probes.capture.proposalCodecFailures or {}
  if saved.probes.capture.nativeCommandCount == nil then saved.probes.capture.nativeCommandCount = 0 end
  saved.probes.capture.nativeCommandOrigins = saved.probes.capture.nativeCommandOrigins or {}
  saved.probes.capture.nativeCommandHistory = saved.probes.capture.nativeCommandHistory or {}
  if saved.probes.capture.operationalGuiCount == nil then saved.probes.capture.operationalGuiCount = 0 end
  saved.probes.capture.operationalGuiHistory = saved.probes.capture.operationalGuiHistory or {}
  if saved.probes.capture.operationCaptureCount == nil then saved.probes.capture.operationCaptureCount = 0 end
  if saved.probes.capture.operationReplayCount == nil then saved.probes.capture.operationReplayCount = 0 end
  if saved.probes.capture.operationReplayFailureCount == nil then
    saved.probes.capture.operationReplayFailureCount = 0
  end
  saved.probes.operational = saved.probes.operational or util.deepCopy(defaults.probes.operational)
  for key, value in pairs(defaults.probes.operational) do
    if saved.probes.operational[key] == nil then saved.probes.operational[key] = util.deepCopy(value) end
  end
  saved.probes.operational.samples = saved.probes.operational.samples or {}
  saved.validation = saved.validation or util.deepCopy(defaults.validation)
  -- Validator progress is disposable process/session state, not portable world
  -- state. A populated save may contain a completed or half-finished older
  -- localhost run; carrying that stage into a new bridge session can strand a
  -- peer waiting for an intent that belonged to the old outbox.
  if cfg.networkAutoValidate and (saved.validation.kind ~= defaults.validation.kind
    or tostring(saved.validation.sessionId or "") ~= tostring(cfg.sessionId)
    or tostring(saved.validation.peerId or "") ~= tostring(cfg.peerId)) then
    saved.validation = util.deepCopy(defaults.validation)
  end
  saved.validation.kind = saved.validation.kind or defaults.validation.kind
  saved.validation.sessionId = saved.validation.sessionId or cfg.sessionId
  saved.validation.peerId = saved.validation.peerId or cfg.peerId
  saved.validation.checks = saved.validation.checks or {}
  saved.validation.values = saved.validation.values or {}
  if (config().autoValidate or config().networkAutoValidate)
    and saved.validation.status == "disabled" then
    saved.validation = util.deepCopy(defaults.validation)
  end
  saved.companies = saved.companies or {}
  saved.companyOrder = saved.companyOrder or {}
  saved.activeCompanyIndex = saved.activeCompanyIndex or 1
  saved.networkMode = saved.networkMode or "standalone"
  -- Version 10 separates the machine-local player that issued/paid for a
  -- replay command from the local native player that must own its output.
  -- They coincide for a local network action, but are deliberately different
  -- when this peer replays the rival company's committed proposal.
  for _, record in pairs(saved.world.proposals.byId) do
    if type(record) == "table" then
      record.issuerPlayerId = tonumber(record.issuerPlayerId or record.controlPlayerId)
      record.commitSeq = tonumber(record.commitSeq
        or tostring(record.proposalId or ""):match(":(%d+)$"))
      record.originPeer = tostring(record.originPeer
        or tostring(record.proposalId or ""):match(":([^:]+):%d+$") or "")
      local company = saved.companies[record.companyCid]
      if record.nativeOwnerPlayerId == nil then
        record.nativeOwnerPlayerId = saved.world.proxyMode
          and record.issuerPlayerId
          or (company and company.playerId or record.issuerPlayerId)
      end
      record.nativeOwnerPlayerId = tonumber(record.nativeOwnerPlayerId)
      -- Retain the old field in saves and research exports for compatibility;
      -- new logic never treats it as the output owner.
      record.controlPlayerId = tonumber(record.controlPlayerId or record.issuerPlayerId)
      if saved.networkMode == "network" and not saved.world.proposalConsensus.byId[record.proposalId] then
        saved.world.proposalConsensus.byId[record.proposalId] = {
          proposalId = record.proposalId,
          commitSeq = tonumber(record.commitSeq),
          proposalDigest = record.transaction and record.transaction.digest or nil,
          status = "pending",
        }
      end
    end
  end
  -- Version 11 adds a persisted, canonical-only barrier after match start and
  -- every successful physical proposal. Old saves have no active barrier;
  -- their next network session must establish a fresh checkpoint normally.
  saved.recovery = saved.recovery or util.deepCopy(defaults.recovery)
  saved.recovery.schemaVersion = 1
  saved.recovery.bridgeRebinds = math.max(0, util.integer(saved.recovery.bridgeRebinds, 0))
  saved.bridge = saved.bridge or bridge.newState(cfg)
  local priorBridge = {
    root = saved.bridge.root,
    peerId = saved.bridge.peerId,
    sessionId = saved.bridge.sessionId,
    nextOutSeq = saved.bridge.nextOutSeq,
    nextInSeq = saved.bridge.nextInSeq,
  }
  local rebound = bridge.reconfigure(saved.bridge, cfg, true)
  if rebound then
    saved.recovery.bridgeRebinds = saved.recovery.bridgeRebinds + 1
    saved.recovery.lastBridgeRebind = {
      tick = saved.tick,
      from = priorBridge,
      to = {
        root = saved.bridge.root,
        peerId = saved.bridge.peerId,
        sessionId = saved.bridge.sessionId,
        nextOutSeq = saved.bridge.nextOutSeq,
        nextInSeq = saved.bridge.nextInSeq,
      },
    }
  end
  saved.bridge.companion = saved.bridge.companion or {
    available = false,
    status = "not-running",
  }
  saved.version = STATE_VERSION
  return saved
end


return M
