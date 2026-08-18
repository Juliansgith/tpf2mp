local util = require "tpf2_mp/util"
local canonical = require "tpf2_mp/canonical"
local economy = require "tpf2_mp/economy"
local economyDifficulty = require "tpf2_mp/economy_difficulty"
local bridge = require "tpf2_mp/bridge"
local finance = require "tpf2_mp/finance"
local passengerPresentation = require "tpf2_mp/passenger_presentation"
local cargoPresentation = require "tpf2_mp/cargo_presentation"
local passengerCosmetics = require "tpf2_mp/passenger_cosmetics"
local industryContentRuntime = require "tpf2_mp/industry_content_runtime"
local freightIndustryModel = require "tpf2_mp/freight_industry_model"
local stateSuccessNormalization = require "tpf2_mp/state_success_normalization"
local restoreSessionIdentity = require "tpf2_mp/restore_session_identity"
local stateRetention = require "tpf2_mp/state_retention"
local recoveryPhaseProof = require "tpf2_mp/recovery_phase_proof"
local resourceCompatibility = require "tpf2_mp/resource_compatibility"

local M = {}

local function startingOwnershipHints(saved)
  if type(saved) ~= "table" or type(saved.companyOrder) ~= "table"
    or type(saved.companies) ~= "table" then return nil end

  local result = {
    schemaVersion = 1,
    companyPlayerIds = {},
    logicalOwners = {},
  }
  local validCompanies = {}
  local seenPlayers = {}
  for _, companyCid in ipairs(saved.companyOrder) do
    local company = saved.companies[companyCid]
    local playerId = type(company) == "table" and tonumber(company.playerId) or nil
    if type(companyCid) ~= "string" or not companyCid:match("^company:%d+$")
      or not playerId or playerId < 0 or playerId ~= math.floor(playerId)
      or seenPlayers[playerId] then
      return nil
    end
    seenPlayers[playerId] = true
    validCompanies[companyCid] = true
    result.companyPlayerIds[#result.companyPlayerIds + 1] = playerId
  end
  if #result.companyPlayerIds == 0 then return nil end

  local function remember(localId, companyCid)
    local numericId = tonumber(localId)
    if numericId and numericId >= 0 and numericId == math.floor(numericId)
      and validCompanies[companyCid] then
      result.logicalOwners[tostring(numericId)] = companyCid
    end
  end
  for localId, companyCid in pairs(saved.world and saved.world.logicalOwners or {}) do
    remember(localId, companyCid)
  end
  -- Older hot-seat saves did not always mirror every logical owner into the
  -- world table, but canonical bindings created by the same match retain the
  -- owner metadata. Preserve those hints too; the fresh network bootstrap
  -- validates every referenced entity against the newly loaded physical map.
  for _, binding in pairs(saved.canonical and saved.canonical.byCanonical or {}) do
    if type(binding) == "table" then
      remember(binding.localId, binding.metadata and binding.metadata.owner)
    end
  end
  return result
end

-- A fresh network session deliberately discards the prior match model while
-- retaining the loaded native map.  Autonomy is part of that native map: once
-- every town/industry freeze command has completed successfully, replaying the
-- same command burst during promotion is unnecessary and can race Build
-- 35924's just-loaded simulation thread.  Carry only a fully verified freeze;
-- partial/failed attempts remain false and are retried by match initialisation.
local function startingAutonomyFreeze(saved)
  local world = type(saved) == "table" and saved.world or nil
  local result = type(world) == "table" and world.lastFreezeResult or nil
  if not (type(world) == "table" and world.autonomyFrozen == true
      and type(result) == "table" and result.freeze == true
      and type(result.errors) == "table" and next(result.errors) == nil) then
    return nil
  end
  local towns = tonumber(result.towns)
  local industries = tonumber(result.industries)
  if not towns or towns < 0 or towns ~= math.floor(towns)
    or not industries or industries < 0 or industries ~= math.floor(industries)
    or towns + industries == 0 then
    return nil
  end
  return util.deepCopy(result)
end

local function restoreResumeValidation(saved, cfg)
  local request = cfg.restoreResume
  local savedWorld = type(saved.world) == "table" and saved.world or {}
  if type(request) ~= "table" or request.requested ~= true or request.valid ~= true then
    return false, type(request) == "table" and request.error
      or "launcher restore attestation is unavailable"
  end
  local priorBridge = type(saved.bridge) == "table" and saved.bridge or {}
  if saved.networkMode ~= "network" or saved.initialized ~= true then
    return false, "restore source is not an initialized network match"
  end
  if tostring(priorBridge.sessionId or "") ~= tostring(request.fromSession)
    or tostring(priorBridge.peerId or "") ~= tostring(cfg.peerId) then
    return false, "restore source session or peer does not match the attested save"
      .. " (savedSession=" .. tostring(priorBridge.sessionId or "")
      .. ", requestedSession=" .. tostring(request.fromSession or "")
      .. ", savedPeer=" .. tostring(priorBridge.peerId or "")
      .. ", localPeer=" .. tostring(cfg.peerId or "") .. ")"
  end
  local expectedResume = restoreSessionIdentity.derive(
    request.fromSession, request.boundarySeq)
  if not expectedResume or tostring(cfg.sessionId) ~= expectedResume then
    return false, "restore resume session does not match its attested boundary"
  end
  local consensus = savedWorld.checkpointConsensus
  local anchor = consensus and consensus.byBoundary
    and consensus.byBoundary[tostring(request.boundarySeq)] or nil
  local preparation = saved.recovery and saved.recovery.anchorPreparation or nil
  local phaseProof, phaseError = recoveryPhaseProof.normalise(
    preparation and preparation.vehiclePhaseProof)
  if type(anchor) ~= "table" or anchor.status ~= "complete" or anchor.success ~= true
    or tostring(anchor.coreDigest or "") ~= tostring(request.coreDigest)
    or tostring(anchor.convergenceKey or "") ~= tostring(request.convergenceKey) then
    return false, "saved checkpoint does not match the restore plan"
  end
  if type(preparation) ~= "table" or preparation.status ~= "ready"
    or util.integer(preparation.boundarySeq, 0) ~= request.boundarySeq then
    return false, "saved world was not at a prepared restore boundary"
  end
  if not phaseProof
    or phaseProof.vehiclePhaseDigest ~= tostring(request.vehiclePhaseDigest or "") then
    return false, phaseError or "saved native vehicle phase proof does not match the restore plan"
  end
  for _, records in ipairs({
    savedWorld.proposalConsensus and savedWorld.proposalConsensus.byId or {},
    savedWorld.operationConsensus and savedWorld.operationConsensus.byId or {},
    consensus and consensus.byBoundary or {},
  }) do
    for _, record in pairs(records) do
      if type(record) == "table" and record.status == "pending" then
        return false, "saved world contains an unfinished consensus barrier"
      end
    end
  end
  if savedWorld.proposalConsensus and savedWorld.proposalConsensus.sessionFault
    or savedWorld.operationConsensus and savedWorld.operationConsensus.sessionFault
    or util.tableCount(savedWorld.originResidueCustody or {}) > 0 then
    return false, "saved world contains a fault or unowned native residue"
  end
  return true, util.deepCopy(anchor)
end

function M.new(cfg, versions)
  local STATE_VERSION = assert(versions and versions.stateVersion, "stateVersion is required")
  local CHECKPOINT_VERSION = assert(versions and versions.checkpointVersion, "checkpointVersion is required")
  local validationEnabled = cfg.autoValidate or cfg.networkAutoValidate
  local validationKind = cfg.networkAutoValidate and "localhost-network" or "standalone"
  local configuredPlayerIds = util.deepCopy(cfg.startingCompanyPlayerIds or {})
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
        economyDifficulty = economyDifficulty.normaliseKey(cfg.economyDifficulty),
        revenueMultiplierPpm = economyDifficulty.multiplier(cfg.economyDifficulty),
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
      townDevelopment = {
        schemaVersion = 1,
        enabled = cfg.townDevelopment == true,
        points = {},
        cursor = {},
      },
      industryContent = industryContentRuntime.newState(),
      freightIndustry = freightIndustryModel.newState(),
      logicalOwners = {},
      logicalOwnershipAuthoritative = false,
      initialNetworkOwnership = nil,
      startingOwnershipHints = #configuredPlayerIds > 0 and {
        schemaVersion = 1,
        companyPlayerIds = configuredPlayerIds,
        logicalOwners = {},
        source = "launcher-save-metadata",
      } or nil,
      pinnedCustody = {},
      -- Persisted custody markers for origin-applied (already natively
      -- mutated) operations. Machine-local and outside every digest; their
      -- presence after a reload means custody was lost and the session must
      -- fault closed.
      originResidueCustody = {},
      originResidueNextToken = 1,
      proposals = {
        byId = {},
        queued = 0,
        applied = 0,
        failed = 0,
      },
      proposalConsensus = {
        byId = {},
        completed = 0,
        rejected = 0,
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
        rendezvousReached = 0,
        rendezvousFaults = 0,
        startupPause = { requested = false, confirmed = false },
      },
      vehicleSync = {
        schemaVersion = 2,
        enabled = true,
        vehicles = {},
        scheduleReservations = {},
      },
      passengerPresentation = passengerPresentation.newState(),
      cargoPresentation = cargoPresentation.newState(),
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
      vehicleSync = {
        managed = 0,
        held = 0,
        released = 0,
        faults = 0,
        reports = 0,
        reportedReleases = {},
        lastEvent = nil,
        lastError = nil,
      },
      passengerCosmetics = passengerCosmetics.newProbe(),
      industryContent = industryContentRuntime.newProbe(),
      freightIndustry = freightIndustryModel.newProbe(),
      performance = { schemaVersion = 1, tasks = {}, scheduler = {} },
      resourceCompatibility = resourceCompatibility.newProbe(),
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
  economy.setDifficulty(result.economy, cfg.economyDifficulty)
  return result
end


function M.migrate(saved, context)
  local newState = assert(context and context.newState, "newState callback is required")
  local config = assert(context and context.config, "config callback is required")
  local STATE_VERSION = assert(context.stateVersion, "stateVersion is required")
  local CHECKPOINT_VERSION = assert(context.checkpointVersion, "checkpointVersion is required")
  if type(saved) ~= "table" then return newState() end
  -- Economy v5 and older counted one settlement per authored hour. Economy v6
  -- settles every five minutes, so a persisted non-zero match limit must be
  -- converted before economy.migrate replaces the version marker. Unlimited
  -- matches remain zero. This preserves the advertised duration of old saves.
  local priorEconomyVersion = util.integer(
    type(saved.economy) == "table" and saved.economy.version or 0, 0)
  local legacyMaxEpochs = saved.match and saved.match.rules
    and util.integer(saved.match.rules.maxEpochs, 0) or nil
  local legacyValuationTarget = saved.match and saved.match.rules
    and util.integer(saved.match.rules.valuationTargetCents, 0) or nil
  local cfg = config()
  -- A local/hot-seat state cannot be promoted in place, and a saved network
  -- match cannot donate its barriers/accounts to a differently identified
  -- network session. Retain the physical map in both cases but start a clean
  -- canonical match state. Resuming the same session ID still preserves its
  -- canonical state and merely rebinds the machine-local bridge/peer below.
  local priorSessionId = saved.bridge and saved.bridge.sessionId or nil
  local networkSessionChanged = tostring(priorSessionId or "") ~= tostring(cfg.sessionId)
  if cfg.startNetwork and networkSessionChanged
    and type(cfg.restoreResume) == "table" and cfg.restoreResume.requested == true then
    local valid, anchorOrError = restoreResumeValidation(saved, cfg)
    if not valid then
      local fresh = newState()
      fresh.recovery.restoreResume = {
        status = "failed",
        fromSession = cfg.restoreResume.fromSession,
        sessionId = cfg.sessionId,
        boundarySeq = cfg.restoreResume.boundarySeq,
        planChecksum = cfg.restoreResume.planChecksum,
        error = tostring(anchorOrError),
      }
      fresh.lastError = "restore refused: " .. tostring(anchorOrError)
      return fresh
    end
    saved.recovery = saved.recovery or { schemaVersion = 1 }
    saved.recovery.restoreResume = {
      status = "validated",
      fromSession = cfg.restoreResume.fromSession,
      sessionId = cfg.sessionId,
      boundarySeq = cfg.restoreResume.boundarySeq,
      coreDigest = cfg.restoreResume.coreDigest,
      convergenceKey = cfg.restoreResume.convergenceKey,
      planChecksum = cfg.restoreResume.planChecksum,
      vehiclePhaseDigest = cfg.restoreResume.vehiclePhaseDigest,
      sourceAnchor = anchorOrError,
    }
    saved.recovery.anchorPreparation = nil
    -- These controls are numbered within one sequencer session. Retaining the
    -- old boundary table could make resume commit 1 look already complete;
    -- retaining its clock generation would reject the new host's generation 1.
    saved.world.checkpointConsensus = nil
    saved.world.networkClock = nil
  elseif cfg.startNetwork
    and (saved.networkMode ~= "network" or networkSessionChanged) then
    local ownershipHints = startingOwnershipHints(saved)
    local autonomyFreeze = startingAutonomyFreeze(saved)
    local previous = {
      version = saved.version,
      networkMode = saved.networkMode,
      initialized = saved.initialized,
      priorSessionId = priorSessionId,
      priorPeerId = saved.bridge and saved.bridge.peerId or nil,
    }
    local fresh = newState()
    if not ownershipHints then
      ownershipHints = util.deepCopy(fresh.world.startingOwnershipHints)
    end
    fresh.world.startingOwnershipHints = ownershipHints
    if autonomyFreeze then
      fresh.world.autonomyFrozen = true
      fresh.world.lastFreezeResult = autonomyFreeze
    end
    fresh.recovery.freshNetworkBootstrap = {
      reason = saved.networkMode ~= "network"
        and "launcher-network-over-local-save"
        or "launcher-new-network-session-over-prior-network-save",
      previous = previous,
      sessionId = fresh.bridge.sessionId,
      peerId = fresh.bridge.peerId,
      ownershipHintCompanies = ownershipHints and #ownershipHints.companyPlayerIds or 0,
      ownershipHintEntities = ownershipHints
        and util.tableCount(ownershipHints.logicalOwners) or 0,
      autonomyFreezePreserved = autonomyFreeze ~= nil,
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
  if priorEconomyVersion > 0 and priorEconomyVersion < 6
    and legacyMaxEpochs and legacyMaxEpochs > 0 then
    saved.match.rules.maxEpochs = legacyMaxEpochs * 12
  end
  if priorEconomyVersion > 0 and priorEconomyVersion < 6
    and legacyValuationTarget and legacyValuationTarget > 0 then
    saved.match.rules.valuationTargetCents = legacyValuationTarget > 1000000000000
      and 1000000000000000 or legacyValuationTarget * 1000
  end
  if saved.match.rules.valuationTargetCents == nil then
    saved.match.rules.valuationTargetCents = defaults.match.rules.valuationTargetCents
  end
  local savedDifficulty = economyDifficulty.normaliseKey(
    saved.match.rules.economyDifficulty)
  saved.match.rules.economyDifficulty = savedDifficulty
  saved.match.rules.revenueMultiplierPpm = economyDifficulty.multiplier(savedDifficulty)
  economy.setDifficulty(saved.economy, savedDifficulty)
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
  local legacyTownPoints = type(saved.world.townDevelopmentPoints) == "table"
    and saved.world.townDevelopmentPoints or nil
  saved.world.townDevelopment = saved.world.townDevelopment
    or util.deepCopy(defaults.world.townDevelopment)
  saved.world.townDevelopment.schemaVersion = 1
  if type(saved.world.townDevelopment.enabled) ~= "boolean" then
    saved.world.townDevelopment.enabled = defaults.world.townDevelopment.enabled
  end
  saved.world.townDevelopment.points = saved.world.townDevelopment.points
    or legacyTownPoints or {}
  saved.world.townDevelopment.cursor = saved.world.townDevelopment.cursor or {}
  saved.world.townDevelopmentPoints = nil
  saved.world.industryContent = industryContentRuntime.migrate(
    saved.world.industryContent)
  saved.world.freightIndustry = freightIndustryModel.migrate(
    saved.world.freightIndustry)
  saved.world.originResidueCustody = saved.world.originResidueCustody or {}
  saved.world.originResidueNextToken = math.max(1,
    util.integer(saved.world.originResidueNextToken, 1))
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
  saved.world.proposalConsensus.rejected = math.max(0,
    util.integer(saved.world.proposalConsensus.rejected, 0))
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
  saved.world.vehicleSync = saved.world.vehicleSync or util.deepCopy(defaults.world.vehicleSync)
  saved.world.vehicleSync.schemaVersion = 2
  if saved.world.vehicleSync.enabled == nil then saved.world.vehicleSync.enabled = true end
  saved.world.vehicleSync.vehicles = saved.world.vehicleSync.vehicles or {}
  saved.world.vehicleSync.scheduleReservations = saved.world.vehicleSync.scheduleReservations or {}
  for _, item in pairs(saved.world.vehicleSync.vehicles) do
    if type(item) == "table" then
      if type(item.schedule) ~= "table" then
        item.schedule = { schemaVersion = 1, enabled = false }
      end
      -- Manifest-bound vehicles predate operation-authored owner metadata. The
      -- registered economy service is already canonical and is also the source
      -- used by the passenger ledger, so backfill only an absent sync owner.
      if item.companyCid == nil and type(item.lineCid) == "string" then
        local service = saved.economy and saved.economy.services
          and saved.economy.services[item.lineCid] or nil
        if service and type(service.companyCid) == "string" then
          item.companyCid = service.companyCid
        end
      end
    end
  end
  local hadPassengerPresentation = type(saved.world.passengerPresentation) == "table"
  saved.world.passengerPresentation = passengerPresentation.migrate(
    saved.world.passengerPresentation or defaults.world.passengerPresentation)
  if not hadPassengerPresentation then
    local aligned, alignmentResult = passengerPresentation.alignWithVehicleSync(
      saved.world.passengerPresentation, saved.economy, saved.world.vehicleSync)
    if aligned then
      saved.world.passengerPresentation = alignmentResult
    else
      saved.lastError = "passenger presentation migration failed: "
        .. tostring(alignmentResult)
    end
  end
  saved.world.cargoPresentation = cargoPresentation.migrate(
    saved.world.cargoPresentation or defaults.world.cargoPresentation)
  local cargoAligned, cargoAlignmentResult = cargoPresentation.alignWithVehicleSync(
    saved.world.cargoPresentation, saved.economy, saved.world.vehicleSync)
  if cargoAligned then
    saved.world.cargoPresentation = cargoAlignmentResult
    local cargoValid, cargoValidationError = cargoPresentation.validateState(
      saved.world.cargoPresentation, saved.economy,
      saved.world.freightIndustry, saved.world.vehicleSync)
    if not cargoValid then
      saved.lastError = "cargo presentation migration failed: "
        .. tostring(cargoValidationError)
    end
  else
    saved.lastError = "cargo presentation migration failed: "
      .. tostring(cargoAlignmentResult)
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
  saved.probes.vehicleSync = saved.probes.vehicleSync or util.deepCopy(defaults.probes.vehicleSync)
  for key, value in pairs(defaults.probes.vehicleSync) do
    if saved.probes.vehicleSync[key] == nil then
      saved.probes.vehicleSync[key] = util.deepCopy(value)
    end
  end
  saved.probes.vehicleSync.reportedReleases = saved.probes.vehicleSync.reportedReleases or {}
  saved.probes.passengerCosmetics = saved.probes.passengerCosmetics
    or util.deepCopy(defaults.probes.passengerCosmetics)
  for key, value in pairs(defaults.probes.passengerCosmetics) do
    if saved.probes.passengerCosmetics[key] == nil then
      saved.probes.passengerCosmetics[key] = util.deepCopy(value)
    end
  end
  saved.probes.industryContent = saved.probes.industryContent
    or util.deepCopy(defaults.probes.industryContent)
  for key, value in pairs(defaults.probes.industryContent) do
    if saved.probes.industryContent[key] == nil then
      saved.probes.industryContent[key] = util.deepCopy(value)
    end
  end
  saved.probes.freightIndustry = saved.probes.freightIndustry
    or util.deepCopy(defaults.probes.freightIndustry)
  for key, value in pairs(defaults.probes.freightIndustry) do
    if saved.probes.freightIndustry[key] == nil then
      saved.probes.freightIndustry[key] = util.deepCopy(value)
    end
  end
  saved.probes.performance = saved.probes.performance
    or util.deepCopy(defaults.probes.performance)
  saved.probes.performance.schemaVersion = 1
  saved.probes.performance.tasks = saved.probes.performance.tasks or {}
  saved.probes.performance.scheduler = saved.probes.performance.scheduler or {}
  saved.probes.resourceCompatibility = resourceCompatibility.migrate(
    saved.probes.resourceCompatibility or defaults.probes.resourceCompatibility)
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
  if saved.recovery and saved.recovery.restoreResume
    and saved.recovery.restoreResume.status == "validated" then
    saved.validation.sessionId = cfg.sessionId
    saved.validation.peerId = cfg.peerId
  else
    saved.validation.sessionId = saved.validation.sessionId or cfg.sessionId
    saved.validation.peerId = saved.validation.peerId or cfg.peerId
  end
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
  -- This is a peer-local in-process command diagnostic. A loaded save must
  -- wait for a fresh companion READY request instead of reusing it.
  saved.recovery.nativeSave = nil
  -- Launcher automation is also process/session-local. Persisting this latch
  -- made a restore created by an automatic capture ignore the next session's
  -- equally valid preparation request.
  saved.probes.launcherRecoveryPrepare = nil
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
    -- Content authority belongs to the network session, not merely to the
    -- native save. A restored or newly launched bridge must collect fresh
    -- per-peer attestations before freight rules can trust the loader facts.
    saved.world.industryContent = industryContentRuntime.newState()
    saved.probes.industryContent = industryContentRuntime.newProbe()
    saved.probes.freightIndustry = freightIndustryModel.newProbe()
  end
  saved.bridge.companion = saved.bridge.companion or {
    available = false,
    status = "not-running",
  }
  stateSuccessNormalization.apply(saved)
  stateRetention.compact(saved, cfg.maxEvents)
  saved.version = STATE_VERSION
  return saved
end


return M
