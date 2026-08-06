local util = require "tpf2_mp/util"
local hash = require "tpf2_mp/hash"
local bridge = require "tpf2_mp/bridge"
local finance = require "tpf2_mp/finance"
local world = require "tpf2_mp/world"
local proposalCodec = require "tpf2_mp/proposal_codec"
local validationClockModule = require "tpf2_mp/validation_clock"

local M = {}

function M.new(deps)
  assert(type(deps) == "table", "validation runtime dependencies are required")
  local getState = assert(deps.getState, "getState dependency is required")
  local config = assert(deps.config, "config dependency is required")
  local diagnosticLog = assert(deps.diagnosticLog, "diagnosticLog dependency is required")
  local coreDigest = assert(deps.coreDigest, "coreDigest dependency is required")
  local authoredDigest = assert(deps.authoredDigest, "authoredDigest dependency is required")
  local exportResearch = assert(deps.exportResearch, "exportResearch dependency is required")
  local balanceOf = assert(deps.balanceOf, "balanceOf dependency is required")
  local proposalResourceName = assert(deps.proposalResourceName, "proposalResourceName dependency is required")
  local applyCommitted = assert(deps.applyCommitted, "applyCommitted dependency is required")
  local submitIntent = assert(deps.submitIntent, "submitIntent dependency is required")
  local awaitingOrder = assert(deps.awaitingOrder, "awaitingOrder dependency is required")
  local networkPendingBarrierReason =
    assert(deps.pendingBarrierReason, "pendingBarrierReason dependency is required")
  local activeCompany = assert(deps.activeCompany, "activeCompany dependency is required")
  local refreshOwnershipProbe =
    assert(deps.refreshOwnershipProbe, "refreshOwnershipProbe dependency is required")

  local state = setmetatable({}, {
    __index = function(_, key) return getState()[key] end,
    __newindex = function(_, key, value) getState()[key] = value end,
  })
  local validationClock = validationClockModule.new(getState)

  -- Environment-gated, disposable-world validation. Each money mutation gets a
  -- settling window because native commands may not become observable until a
  -- later engine update. This deliberately exercises the real public handlers
  -- used by the GUI instead of maintaining a separate test-only implementation.
  -- Keep the proxy-wallet assertions inside a single native accounting period.
  -- The original turn desk carries the base game's 30M loan, whose monthly
  -- interest is deliberately outside the canonical company ledger. A separate
  -- long-horizon probe below records that boundary; individual command/turn
  -- postconditions must not straddle an accounting rollover nondeterministically.
  local VALIDATION_SETTLE_TICKS = 15
  local VALIDATION_WORLD_WARMUP_TICKS = 240
  local VALIDATION_DEBIT = -12345
  
  local function validationTransition(stage)
    state.validation.stage = stage
    state.validation.stageStartedTick = state.tick
    diagnosticLog("auto-validation-stage", { stage = stage, tick = state.tick })
  end
  
  local function validationCheck(name, passed, details)
    local record = {
      name = tostring(name),
      passed = passed and true or false,
      tick = state.tick,
      details = util.deepCopy(details or {}),
    }
    state.validation.checks[#state.validation.checks + 1] = record
    if not passed then error("validation check failed: " .. tostring(name)) end
    return record
  end
  
  local function moneyEquals(actual, expected)
    return tonumber(actual) ~= nil and tonumber(expected) ~= nil
      and math.abs(tonumber(actual) - tonumber(expected)) < 0.5
  end
  
  local function validationEmitResult()
    return bridge.emit(state.bridge, "validation", {
      kind = state.validation.kind,
      sessionId = state.bridge.sessionId,
      peerId = state.bridge.peerId,
      networkMode = state.networkMode,
      status = state.validation.status,
      stage = state.validation.stage,
      startedTick = state.validation.startedTick,
      completedTick = state.validation.completedTick,
      checks = util.deepCopy(state.validation.checks),
      values = util.deepCopy(state.validation.values),
      error = state.validation.error,
      digest = coreDigest(),
      modelDigest = authoredDigest(),
      structuralDigest = state.probes.structural and state.probes.structural.digest or nil,
      mobilityDigest = state.probes.mobility and state.probes.mobility.digest or nil,
      companion = util.deepCopy(state.bridge.companion),
    }, state.tick)
  end
  
  local function validationFail(message)
    local validation = state.validation
    if validation.status == "failed" then return end
    validation.status = "failed"
    validation.stage = "failed"
    validation.error = tostring(message)
    validation.completedTick = state.tick
    state.probes.lastError = validation.error
    -- Export as much evidence as possible. Failures here are retained in the
    -- bridge state but cannot hide the original validation error.
    pcall(function() exportResearch() end)
    pcall(validationEmitResult)
    diagnosticLog("auto-validation-complete", {
      success = false,
      tick = state.tick,
      checks = #validation.checks,
      error = validation.error,
    })
  end
  
  local function validationComplete()
    local validation = state.validation
    validation.status = "passed"
    validation.stage = "complete"
    validation.completedTick = state.tick
    local researchOk, researchResult = exportResearch()
    validationCheck("research-export", researchOk, researchResult)
    local emitted, emitResult = validationEmitResult()
    validationCheck("validation-export", emitted, emitResult)
    diagnosticLog("auto-validation-complete", {
      success = true,
      tick = state.tick,
      checks = #validation.checks,
      digest = coreDigest(),
    })
  end
  
  local function validationCompanyBalance(companyCid)
    local company = state.companies[companyCid]
    return company and balanceOf(company.playerId) or nil
  end
  
  local function validationNetworkFinanceEvidence()
    local view = finance.networkDigestView(state.finance)
    local native = {}
    local matches = view.initialized == true
    for _, companyCid in ipairs(util.sortedKeys(view.accounts or {})) do
      local company = state.companies[companyCid]
      local observed = company and balanceOf(company.playerId) or nil
      local expected = view.accounts[companyCid].balance
      local match = observed ~= nil and math.abs(observed - expected) < 0.5
      native[companyCid] = { expected = expected, observed = observed, matches = match }
      if not match then matches = false end
    end
    return {
      digest = hash.value(view),
      view = view,
      native = native,
      nativeMatches = matches,
      reconciliation = util.deepCopy(state.finance.networkAccounts.reconciliation or {}),
    }
  end
  
  local function requestValidationSpeed()
    local setGameSpeed = util.commandFactory("setGameSpeed")
    if setGameSpeed and api and api.cmd and type(api.cmd.sendCommand) == "function" then
      local made, command = pcall(setGameSpeed, 4.0)
      local ok = made and util.sendCommand(command, nil, "mod.validation.set-game-speed")
      if ok then return true end
    end
    if game.interface.setGameSpeed then return pcall(game.interface.setGameSpeed, 3) end
    return false
  end
  
  local function validationHeight(x, y)
    if api and api.engine and api.engine.terrain and type(api.engine.terrain.getHeightAt) == "function"
      and api.type and api.type.Vec2f then
      local ok, value = pcall(api.engine.terrain.getHeightAt, api.type.Vec2f.new(x, y))
      if ok and tonumber(value) then return tonumber(value) end
    end
    if game and game.interface and type(game.interface.getHeight) == "function" then
      for _, position in ipairs({ { x = x, y = y }, { x, y } }) do
        local ok, value = pcall(game.interface.getHeight, position)
        if ok and tonumber(value) then return tonumber(value) end
      end
    end
    return nil
  end
  
  local function validationTrackTransaction(x, y, companyCid)
    local length = 80
    local firstZ, secondZ = validationHeight(x, y), validationHeight(x + length, y)
    if firstZ == nil or secondZ == nil then return nil, "terrain height is unavailable" end
    local trackType = api and api.res and api.res.trackTypeRep and api.res.trackTypeRep.find
      and api.res.trackTypeRep.find("standard.lua") or nil
    if tonumber(trackType) == nil or tonumber(trackType) < 0 then return nil, "standard track resource is unavailable" end
    local snapshot = {
      __observedCost = 25000,
      streetProposal = {
        edgesToAdd = {{
          entity = -1,
          type = 1,
          comp = {
            node0 = -2,
            node1 = -3,
            tangent0 = { x = length, y = 0, z = secondZ - firstZ },
            tangent1 = { x = length, y = 0, z = secondZ - firstZ },
            type = 0,
            typeIndex = -1,
          },
          trackEdge = { trackType = trackType, catenary = true },
          playerOwned = { player = game.interface.getPlayer() },
        }},
        nodesToAdd = {
          { entity = -2, comp = { position = { x = x, y = y, z = firstZ } } },
          { entity = -3, comp = { position = { x = x + length, y = y, z = secondZ } } },
        },
        edgesToRemove = {}, nodesToRemove = {}, edgeObjectsToAdd = {}, edgeObjectsToRemove = {},
      },
      constructionsToAdd = {}, constructionsToRemove = {},
    }
    return proposalCodec.normalise(snapshot, companyCid, { resourceName = proposalResourceName })
  end
  
  local function runValidationCanonicalProposal(companyCid, startIndex)
    local candidates = {
      { -1400, -1400 }, { 1400, -1400 }, { -1400, 1400 }, { 1400, 1400 },
      { -1000, -1200 }, { 1000, -1200 }, { -1000, 1200 }, { 1000, 1200 },
      { -600, -1400 }, { 600, -1400 }, { -600, 1400 }, { 600, 1400 },
      { -1600, 0 }, { 1600, 0 }, { 0, -1600 }, { 0, 1600 },
    }
    local errors = {}
    for index = math.max(1, util.integer(startIndex, 1)), #candidates do
      local candidate = candidates[index]
      local transaction, transactionError = validationTrackTransaction(candidate[1], candidate[2], companyCid)
      if transaction then
        local ok, result = applyCommitted({ type = "proposal.build", transaction = transaction }, "auto-validator", nil)
        if ok then return true, { candidate = index, transaction = transaction, result = result } end
        errors[#errors + 1] = tostring(type(result) == "table" and result.error or result)
      else
        errors[#errors + 1] = tostring(transactionError)
      end
    end
    return false, { error = "no canonical track proposal candidate succeeded", attempts = #candidates, errors = errors }
  end
  
  local function networkValidationCompanionReady()
    local companion = bridge.pollCompanionStatus(state.bridge) or {}
    if companion.available ~= true then return false, companion end
    if state.bridge.peerId == "player1" then
      return companion.role == "host" and companion.status == "running"
        and companion.connected == true, companion
    end
    return companion.role == "client" and companion.status == "connected"
      and companion.connected == true, companion
  end
  
  local function networkValidationFault()
    local fault = state.world.proposalConsensus and state.world.proposalConsensus.sessionFault
    if not fault and state.world.operationConsensus then
      fault = state.world.operationConsensus.sessionFault
    end
    if not fault and state.world.checkpointConsensus
      and state.world.checkpointConsensus.lastOutcome
      and state.world.checkpointConsensus.lastOutcome.success == false then
      fault = state.world.checkpointConsensus.lastOutcome
    end
    if fault then
      return tostring(fault.errorCode or fault.error or "network session faulted")
    end
    return nil
  end
  
  local function networkValidationCheckpoint(predicate)
    local byBoundary = state.world.checkpointConsensus
      and state.world.checkpointConsensus.byBoundary or {}
    for _, boundaryKey in ipairs(util.sortedKeys(byBoundary)) do
      local record = byBoundary[boundaryKey]
      if type(record) == "table" and record.status == "complete"
        and record.success == true and predicate(record) then
        return record
      end
    end
    return nil
  end
  
  local function networkValidationSubmit(action, label)
    local ok, result = submitIntent(action)
    local diagnostic = {
      type = "auto-validation-submit",
      label = label,
      actionType = type(action) == "table" and action.type or nil,
      ok = ok == true,
      mode = state.networkMode,
      peer = state.bridge.peerId,
      localSeq = type(result) == "table" and (result.local_seq or result.localSeq) or nil,
      queued = type(result) == "table" and result.queued == true or false,
      deferred = type(result) == "table" and result.deferred == true or false,
      resultStatus = type(result) == "table" and result.status or nil,
      error = not ok and tostring(type(result) == "table" and result.error or result) or nil,
      tick = state.tick,
    }
    diagnosticLog("auto-validation-submit", diagnostic)
    -- stdout is shared by both local game processes and their writes can
    -- interleave. Retain the same tiny record in the peer's numbered bridge so
    -- unattended failures remain attributable without opening the game console.
    pcall(function() bridge.emit(state.bridge, "telemetry", diagnostic, state.tick) end)
    validationCheck(label, ok, result)
    return result
  end
  
  local function networkValidationMobilityReady(keyName)
    local result = state.lastAction and state.lastAction.type == "probe.mobility"
      and state.lastResult or nil
    if type(result) ~= "table" or type(result.sampleKey) ~= "string" then
      local history = state.probes.mobilityHistory or {}
      local wanted = state.validation.values[keyName]
      for _, sample in ipairs(history) do
        local eligible = wanted and sample.sampleKey == wanted
          or (not wanted and keyName == "initialMobilitySample")
          or (not wanted and keyName ~= "initialMobilitySample"
            and sample.sampleKey ~= state.validation.values.initialMobilitySample)
        if eligible then
          result = sample
          break
        end
      end
    end
    if type(result) ~= "table" or type(result.sampleKey) ~= "string" then return false end
    state.validation.values[keyName] = result.sampleKey
    state.validation.values[keyName .. "Digest"] = result.mobilityDigest
    if state.bridge.peerId ~= "player1" then return true end
    local companion = bridge.pollCompanionStatus(state.bridge) or {}
    local outcome = type(companion.mobilityOutcomes) == "table"
      and companion.mobilityOutcomes[result.sampleKey] or nil
    if not outcome then return false end
    validationCheck(keyName .. "-cross-peer-consensus", outcome == "converged", {
      sampleKey = result.sampleKey,
      outcome = outcome,
      digest = result.mobilityDigest,
    })
    return true
  end

  local function runAutomatedNetworkValidation()
    local validation = state.validation
    if not (config().networkAutoValidate and validation and validation.enabled) then return end
    if validation.status == "passed" or validation.status == "failed" then return end
    if state.tick % 60 == 0 and validation.values.lastHeartbeatTick ~= state.tick then
      validation.values.lastHeartbeatTick = state.tick
      pcall(function()
        bridge.emit(state.bridge, "telemetry", {
          type = "validation-heartbeat",
          peer = state.bridge.peerId,
          mode = state.networkMode,
          stage = validation.stage,
          status = validation.status,
          tick = state.tick,
        }, state.tick)
      end)
    end
    local fault = networkValidationFault()
    if fault then error(fault) end
    local stage = validation.stage
    local startup = state.world.networkClock and state.world.networkClock.startupPause
    local authority = state.probes.networkAuthority
    local calendar = state.probes.networkCalendar
    local pausedBootstrap = startup and startup.confirmed == true
      and authority and authority.ready == true and calendar and calendar.frozen == true
      and (stage == "wait-for-network" or stage == "wait-for-match"
        or stage == "wait-for-initial-checkpoint")
    if stage == "wait-for-network" and state.tick < VALIDATION_WORLD_WARMUP_TICKS
      and not pausedBootstrap then return end
    if state.tick - (validation.stageStartedTick or 0) < VALIDATION_SETTLE_TICKS
      and not pausedBootstrap then return end

    if stage == "wait-for-network" then
      local companionReady, companion = networkValidationCompanionReady()
      if not companionReady then return end
      validation.status = "running"
      validation.startedTick = state.tick
      validationCheck("network-mode-active", state.networkMode == "network", {
        mode = state.networkMode,
        peer = state.bridge.peerId,
      })
      validationCheck("native-network-authority-ready",
        state.probes.networkAuthority and state.probes.networkAuthority.ready == true,
        state.probes.networkAuthority)
      validationCheck("native-calendar-frozen-for-finance-stability",
        state.probes.networkCalendar and state.probes.networkCalendar.frozen == true,
        state.probes.networkCalendar)
      validationCheck("native-game-paused-before-network-bootstrap",
        state.world.networkClock.startupPause
          and state.world.networkClock.startupPause.confirmed == true,
        state.world.networkClock.startupPause)
      validationCheck("companion-link-ready", true, companion)
      if state.bridge.peerId == "player1" then
        local result = networkValidationSubmit({ type = "match.initialise" }, "host-match-initialise-queued")
        validation.values.initialiseLocalSeq = result and result.local_seq
        validation.values.lastInitialiseAttemptTick = state.tick
      end
      validationTransition("wait-for-match")
  
    elseif stage == "wait-for-match" then
      if not state.initialized then
        -- Loading a populated native save can replace the world between the
        -- validator's initial stage transition and the matching intent file.
        -- If there is demonstrably no local intent or consensus barrier in
        -- flight, retry the idempotent bootstrap instead of waiting forever.
        local lastAttempt = tonumber(validation.values.lastInitialiseAttemptTick)
          or tonumber(validation.stageStartedTick) or 0
        if state.bridge.peerId == "player1"
          and state.tick - lastAttempt >= 60
          and not awaitingOrder()
          and not networkPendingBarrierReason() then
          local result = networkValidationSubmit({ type = "match.initialise" },
            "host-match-initialise-retry-queued")
          validation.values.initialiseLocalSeq = result and result.local_seq
          validation.values.lastInitialiseAttemptTick = state.tick
          diagnosticLog("auto-validation-retry", {
            stage = stage,
            localSeq = result and result.local_seq or nil,
            tick = state.tick,
          })
        end
        return
      end
      validationCheck("ordered-match-initialised", state.match.status == "running", state.match)
      validationCheck("two-canonical-companies", #state.companyOrder == 2, state.companyOrder)
      validationCheck("peer-company-pinned", activeCompany() == (state.bridge.peerId == "player1"
        and "company:1" or "company:2"), { active = activeCompany(), peer = state.bridge.peerId })
      validationCheck("autonomous-development-frozen", state.world.autonomyFrozen == true, {})
      validationCheck("initial-structural-snapshot", state.probes.structural
        and type(state.probes.structural.digest) == "string", state.probes.structural)
      validation.values.initialStructuralDigest = state.probes.structural.digest
      validationTransition("wait-for-initial-checkpoint")
  
    elseif stage == "wait-for-initial-checkpoint" then
      -- A faster peer can receive the post-proposal checkpoint before its local
      -- validator has walked through these observational stages. Select the
      -- checkpoint by its semantic purpose, never by whichever outcome happened
      -- to arrive last.
      local agreed = networkValidationCheckpoint(function(record)
        return record.proposalId == nil and record.reason == "match-initialised"
      end)
      if not agreed then return end
      if not validationClock.peersReady() then return end
      validationCheck("initial-checkpoint-consensus", agreed.success == true, agreed)
      validationCheck("initial-checkpoint-covers-structure",
        agreed.structuralDigest == validation.values.initialStructuralDigest, agreed)
      validation.values.initialCheckpointBoundary = agreed.boundarySeq
      if state.bridge.peerId == "player1" then
        local result = networkValidationSubmit({ type = "clock.request", requestedSpeed = 2 },
          "shared-clock-resume-request-queued")
        validation.values.clockResumeLocalSeq = result and result.local_seq
        validation.values.lastClockResumeAttemptTick = state.tick
      end
      validationTransition("wait-for-shared-clock-running")

    elseif stage == "wait-for-shared-clock-running" then
      if not validationClock.settled(2) then
        local lastAttempt = tonumber(validation.values.lastClockResumeAttemptTick)
          or tonumber(validation.stageStartedTick) or 0
        if state.bridge.peerId == "player1" and state.tick - lastAttempt >= 60
          and validationClock.peersReady() and not awaitingOrder()
          and not networkPendingBarrierReason() then
          local result = networkValidationSubmit({ type = "clock.request", requestedSpeed = 2 },
            "shared-clock-resume-retry-queued")
          validation.values.clockResumeLocalSeq = result and result.local_seq
          validation.values.lastClockResumeAttemptTick = state.tick
        end
        -- The host deliberately waits for all-peer speed-2 heartbeats before
        -- pausing, but a slower game-script callback can miss the short local
        -- interval between the final resume commit and that pause order. The
        -- ordered successful clock.set proves this replica applied the same
        -- running generation; let its validator catch up to the current stage.
        local committed = validationClock.event(2)
        if state.bridge.peerId ~= "player1" and committed then
          validation.values.clockRunningObservedTick = state.tick
          validationCheck("shared-clock-running-locally", true, {
            orderedEvent = util.deepCopy(committed), caughtUpFromOrderedHistory = true,
          })
          validationTransition("wait-for-shared-clock-paused")
        end
        return
      end
      if not validation.values.clockRunningObservedTick then
        validation.values.clockRunningObservedTick = state.tick
        validationCheck("shared-clock-running-locally", true, {
          clock = util.deepCopy(state.world.networkClock), observed = world.clockSnapshot(),
        })
        return
      end
      -- Leave the completed running state visible for several update frames so
      -- the other local game cannot miss it before the host orders the pause.
      if state.tick - validation.values.clockRunningObservedTick
        < math.max(30, util.integer(config().networkClockRunTicks, 30)) then return end
      if state.bridge.peerId == "player1" then
        local companion = bridge.pollCompanionStatus(state.bridge) or {}
        -- Heartbeat projection can fluctuate after release while both engines
        -- run. The barrier's reached reports are the acceptance fact: they
        -- compare both peers at one target before the release commit.
        validationCheck("shared-clock-running-cross-peer",
          validationClock.rendezvousConverged(companion), companion.clock)
        local result = networkValidationSubmit({ type = "clock.request", requestedSpeed = 0 },
          "shared-clock-pause-request-queued")
        validation.values.clockPauseLocalSeq = result and result.local_seq
      end
      validationTransition("wait-for-shared-clock-paused")

    elseif stage == "wait-for-shared-clock-paused" then
      if not validationClock.settled(0) then return end
      validationCheck("shared-clock-paused-locally", true, {
        clock = util.deepCopy(state.world.networkClock), observed = world.clockSnapshot(),
      })
      if state.bridge.peerId == "player1" then
        local companion = bridge.pollCompanionStatus(state.bridge) or {}
        validationCheck("shared-clock-paused-cross-peer",
          validationClock.rendezvousConverged(companion), companion.clock)
        local result = networkValidationSubmit({ type = "probe.mobility" },
          "initial-mobility-sample-queued")
        validation.values.initialMobilityLocalSeq = result and result.local_seq
      end
      validationTransition("wait-for-initial-mobility")
  
    elseif stage == "wait-for-initial-mobility" then
      if not networkValidationMobilityReady("initialMobilitySample") then return end
      validationCheck("initial-mobility-sampled", state.probes.mobility
        and type(state.probes.mobility.digest) == "string", state.probes.mobility)
      if state.bridge.peerId == "player1" then
        -- Candidate two is the first terrain-safe location in the deterministic
        -- app.startGame test world on Build 35924; candidate one is deliberately
        -- retained by the standalone validator as a rejection-path exercise.
        local transaction, transactionError = validationTrackTransaction(1400, -1400, "company:1")
        validationCheck("network-track-transaction-normalised", transaction ~= nil, {
          error = transactionError,
          digest = transaction and transaction.digest or nil,
        })
        validation.values.proposalDigest = transaction.digest
        local result = networkValidationSubmit({ type = "proposal.prepare", transaction = transaction },
          "host-origin-track-proposal-queued")
        validation.values.proposalLocalSeq = result and result.local_seq
      end
      validationTransition("wait-for-proposal-consensus")
  
    elseif stage == "wait-for-proposal-consensus" then
      local consensus = state.world.proposalConsensus
      if (consensus.completed or 0) < 1 then return end
      local outcome = consensus.lastOutcome
      validationCheck("host-origin-physical-proposal-consensus", outcome and outcome.success == true, outcome)
      validationCheck("host-origin-track-bound-locally", util.tableCount(state.canonical.byCanonical) >= 3, {
        canonicalCount = util.tableCount(state.canonical.byCanonical),
      })
      validation.values.proposalOutcomeBoundary = outcome.commitSeq
      validation.values.hostProposalId = outcome.proposalId
      validationTransition("wait-for-proposal-checkpoint")
  
    elseif stage == "wait-for-proposal-checkpoint" then
      local wantedProposalId = validation.values.hostProposalId
      local agreed = networkValidationCheckpoint(function(record)
        return wantedProposalId ~= nil
          and tostring(record.proposalId or "") == tostring(wantedProposalId)
      end)
      if not agreed then return end
      validationCheck("host-origin-post-proposal-checkpoint-consensus", agreed.success == true, agreed)
      validation.values.hostProposalCheckpointBoundary = agreed.boundarySeq
      if state.bridge.peerId == "player2" then
        -- Exercise the reverse network direction as a real authority case, not
        -- merely as an echoed host commit. This location is distinct from the
        -- host proposal and deterministic in the pinned app.startGame world.
        local transaction, transactionError = validationTrackTransaction(-1400, 1400, "company:2")
        validationCheck("client-track-transaction-normalised", transaction ~= nil, {
          error = transactionError,
          digest = transaction and transaction.digest or nil,
        })
        validation.values.clientProposalDigest = transaction.digest
        local result = networkValidationSubmit({ type = "proposal.prepare", transaction = transaction },
          "client-origin-track-proposal-queued")
        validation.values.clientProposalLocalSeq = result and result.local_seq
      end
      validationTransition("wait-for-client-proposal-consensus")
  
    elseif stage == "wait-for-client-proposal-consensus" then
      local consensus = state.world.proposalConsensus
      if (consensus.completed or 0) < 2 then return end
      local outcome = consensus.lastOutcome
      validationCheck("client-origin-physical-proposal-consensus", outcome and outcome.success == true, outcome)
      local record = outcome and state.world.proposals.byId[outcome.proposalId] or nil
      validationCheck("client-origin-company-authority",
        record and record.transaction and record.transaction.companyCid == "company:2", {
          proposalId = outcome and outcome.proposalId or nil,
          companyCid = record and record.transaction and record.transaction.companyCid or nil,
        })
      validationCheck("both-origin-tracks-bound-locally", util.tableCount(state.canonical.byCanonical) >= 6, {
        canonicalCount = util.tableCount(state.canonical.byCanonical),
      })
      validation.values.clientProposalOutcomeBoundary = outcome.commitSeq
      validation.values.clientProposalId = outcome.proposalId
      validationTransition("wait-for-client-proposal-checkpoint")
  
    elseif stage == "wait-for-client-proposal-checkpoint" then
      local wantedProposalId = validation.values.clientProposalId
      local agreed = networkValidationCheckpoint(function(record)
        return wantedProposalId ~= nil
          and tostring(record.proposalId or "") == tostring(wantedProposalId)
      end)
      if not agreed then return end
      validationCheck("client-origin-post-proposal-checkpoint-consensus", agreed.success == true, agreed)
      state.probes.structural = world.structuralSnapshot(state.canonical, state.world, state.companies)
      validation.values.soakStartTick = state.tick
      validation.values.soakStartStructuralDigest = state.probes.structural.digest
      validation.values.soakStartFinanceDigest = validationNetworkFinanceEvidence().digest
      validation.values.postProposalCheckpointBoundary = agreed.boundarySeq
      validationTransition("soak-structural-drift")
  
    elseif stage == "soak-structural-drift" then
      if state.tick - validation.values.soakStartTick < config().networkSoakTicks then return end
      state.probes.structural = world.structuralSnapshot(state.canonical, state.world, state.companies)
      validation.values.soakEndTick = state.tick
      validation.values.soakEndStructuralDigest = state.probes.structural.digest
      local financeEvidence = validationNetworkFinanceEvidence()
      validationCheck("local-structure-stable-during-soak",
        validation.values.soakEndStructuralDigest == validation.values.soakStartStructuralDigest, {
          start = validation.values.soakStartStructuralDigest,
          finish = validation.values.soakEndStructuralDigest,
          ticks = state.tick - validation.values.soakStartTick,
        })
      validationCheck("canonical-finance-stable-during-soak",
        financeEvidence.digest == validation.values.soakStartFinanceDigest, {
          start = validation.values.soakStartFinanceDigest,
          finish = financeEvidence.digest,
        })
      validationCheck("native-wallet-cache-reconciled", financeEvidence.nativeMatches, financeEvidence)
      validationCheck("native-wallet-reconciliation-error-free",
        (financeEvidence.reconciliation.failures or 0) == 0, financeEvidence.reconciliation)
      if state.bridge.peerId == "player1" then
        local result = networkValidationSubmit({ type = "probe.mobility" }, "final-mobility-sample-queued")
        validation.values.finalMobilityLocalSeq = result and result.local_seq
      end
      validationTransition("wait-for-final-mobility")
  
    elseif stage == "wait-for-final-mobility" then
      if not networkValidationMobilityReady("finalMobilitySample") then return end
      validationCheck("final-mobility-sampled", state.probes.mobility
        and type(state.probes.mobility.digest) == "string", state.probes.mobility)
      validationComplete()
    else
      error("unknown network validation stage: " .. tostring(stage))
    end
  end
  
  local function runAutomatedValidation()
    local validation = state.validation
    if not (config().autoValidate and validation and validation.enabled) then return end
    if validation.status == "passed" or validation.status == "failed" then return end
    -- A validation run must never suspend the callback that advances its own
    -- stages, including after loading state created by an older validator build.
    state.world.pauseOnSwitch = false
    -- app.startGame can call this script while the freshly generated world is
    -- still completing native initialization. Build 35924 has intermittently
    -- entered its generic Internal error/hang path when player and journal work
    -- begins after only a handful of updates. Keep the test-only validator inert
    -- until the engine has advanced a conservative warm-up window.
    if validation.stage == "wait-for-world" and state.tick < VALIDATION_WORLD_WARMUP_TICKS then
      if not validation.values.worldWarmupLogged then
        validation.values.worldWarmupLogged = true
        diagnosticLog("auto-validation-warmup", {
          untilTick = VALIDATION_WORLD_WARMUP_TICKS,
          tick = state.tick,
        })
      end
      return
    end
    if state.tick - (validation.stageStartedTick or 0) < VALIDATION_SETTLE_TICKS then return end
  
    local stage = validation.stage
    if stage == "wait-for-world" then
      validation.status = "running"
      validation.startedTick = state.tick
      requestValidationSpeed()
      local ok, result = applyCommitted({ type = "match.initialise" }, "auto-validator", nil)
      validationCheck("match-initialise", ok, result)
      validationCheck("match-lifecycle-running", state.match.status == "running", util.deepCopy(state.match))
      validationCheck("baseline-checkpoint-exported", (state.checkpoint.exports or 0) > 0, util.deepCopy(state.checkpoint))
      validationCheck("validation-speed-request", requestValidationSpeed(), {})
      diagnosticLog("auto-validation-init", {
        turnPaused = state.world.turn and state.world.turn.paused == true,
        pauseOnSwitch = state.world.pauseOnSwitch == true,
        tick = state.tick,
      })
      validationCheck("native-turn-proxy-enabled", state.world.proxyMode == true, {
        proxyMode = state.world.proxyMode,
        controlPlayerId = state.world.controlPlayerId,
      })
      local firstCid, secondCid = state.companyOrder[1], state.companyOrder[2]
      validationCheck("two-independent-companies", firstCid ~= nil and secondCid ~= nil and firstCid ~= secondCid, {
        firstCid = firstCid,
        secondCid = secondCid,
      })
      validation.values.firstCid = firstCid
      validation.values.secondCid = secondCid
      validation.values.firstInitial = validationCompanyBalance(firstCid)
      validation.values.secondInitial = validationCompanyBalance(secondCid)
      validation.values.controlBaseline = state.world.proxyBankBaseline
      validationTransition("verify-initial-mirror")
  
    elseif stage == "verify-initial-mirror" then
      local firstCid = validation.values.firstCid
      local activeCid = activeCompany()
      local companyBalance = validationCompanyBalance(firstCid)
      local controlBalance = balanceOf(state.world.controlPlayerId)
      validationCheck("first-company-active", activeCid == firstCid, { activeCid = activeCid, expected = firstCid })
      validationCheck("initial-wallet-mirrored", moneyEquals(controlBalance, companyBalance), {
        controlBalance = controlBalance,
        companyBalance = companyBalance,
      })
      validation.values.debitStart = controlBalance
      validation.values.debit = VALIDATION_DEBIT
      local booked, bookingError = finance.book(state.world.controlPlayerId, VALIDATION_DEBIT)
      validationCheck("native-journal-debit-issued", booked, { error = bookingError, amount = VALIDATION_DEBIT })
      validationTransition("verify-native-debit")
  
    elseif stage == "verify-native-debit" then
      local controlBalance = balanceOf(state.world.controlPlayerId)
      local expected = validation.values.debitStart + VALIDATION_DEBIT
      validationCheck("native-journal-debit-observed", moneyEquals(controlBalance, expected), {
        controlBalance = controlBalance,
        expected = expected,
      })
      local ok, result = applyCommitted({ type = "company.cycle" }, "auto-validator", nil)
      validationCheck("cycle-to-second-company", ok, result)
      validationTransition("verify-forward-cycle")
  
    elseif stage == "verify-forward-cycle" then
      local firstCid, secondCid = validation.values.firstCid, validation.values.secondCid
      local activeCid = activeCompany()
      local firstBalance = validationCompanyBalance(firstCid)
      local secondBalance = validationCompanyBalance(secondCid)
      local controlBalance = balanceOf(state.world.controlPlayerId)
      validationCheck("second-company-active", activeCid == secondCid, { activeCid = activeCid, expected = secondCid })
      validationCheck("first-company-kept-turn-debit", moneyEquals(firstBalance, validation.values.firstInitial + VALIDATION_DEBIT), {
        actual = firstBalance,
        expected = validation.values.firstInitial + VALIDATION_DEBIT,
      })
      validationCheck("second-company-finances-isolated", moneyEquals(secondBalance, validation.values.secondInitial), {
        actual = secondBalance,
        expected = validation.values.secondInitial,
      })
      validationCheck("second-wallet-mirrored", moneyEquals(controlBalance, secondBalance), {
        controlBalance = controlBalance,
        companyBalance = secondBalance,
      })
      local ok, result = applyCommitted({ type = "company.cycle" }, "auto-validator", nil)
      validationCheck("cycle-back-to-first-company", ok, result)
      validationTransition("verify-return-cycle")
  
    elseif stage == "verify-return-cycle" then
      local firstCid, secondCid = validation.values.firstCid, validation.values.secondCid
      local activeCid = activeCompany()
      local firstBalance = validationCompanyBalance(firstCid)
      local secondBalance = validationCompanyBalance(secondCid)
      local controlBalance = balanceOf(state.world.controlPlayerId)
      validationCheck("first-company-reactivated", activeCid == firstCid, { activeCid = activeCid, expected = firstCid })
      validationCheck("first-wallet-remirrored", moneyEquals(controlBalance, firstBalance), {
        controlBalance = controlBalance,
        companyBalance = firstBalance,
      })
      validationCheck("second-wallet-still-isolated", moneyEquals(secondBalance, validation.values.secondInitial), {
        actual = secondBalance,
        expected = validation.values.secondInitial,
      })
      local freezeOk, freezeResult = applyCommitted({ type = "world.freeze", freeze = true }, "auto-validator", nil)
      validationCheck("autonomy-freeze-command", freezeOk and state.world.autonomyFrozen == true, freezeResult)
      local probeOk, probeResult = applyCommitted({ type = "probe.run" }, "auto-validator", nil)
      validationCheck("structural-world-probe", probeOk and state.probes.structural ~= nil, probeResult)
      local seedOk, seedResult = applyCommitted({ type = "economy.seed_demo" }, "auto-validator", nil)
      validationCheck("competitive-market-seeded", seedOk, seedResult)
      validation.values.prePayoutFirst = validationCompanyBalance(firstCid)
      validation.values.prePayoutSecond = validationCompanyBalance(secondCid)
      local settleOk, settleResult = applyCommitted({ type = "economy.settle" }, "auto-validator", nil)
      validationCheck("authoritative-economy-settlement", settleOk and state.economy.epoch == 1, settleResult)
      validation.values.firstPayout = state.finance.lastPayouts[firstCid] and state.finance.lastPayouts[firstCid].amount or 0
      validation.values.secondPayout = state.finance.lastPayouts[secondCid] and state.finance.lastPayouts[secondCid].amount or 0
      validationTransition("verify-settlement")
  
    elseif stage == "verify-settlement" then
      local firstCid, secondCid = validation.values.firstCid, validation.values.secondCid
      local firstBalance = validationCompanyBalance(firstCid)
      local secondBalance = validationCompanyBalance(secondCid)
      validationCheck("first-company-received-model-payout", moneyEquals(firstBalance,
        validation.values.prePayoutFirst + validation.values.firstPayout), {
        actual = firstBalance,
        expected = validation.values.prePayoutFirst + validation.values.firstPayout,
        payout = validation.values.firstPayout,
      })
      validationCheck("second-company-received-model-payout", moneyEquals(secondBalance,
        validation.values.prePayoutSecond + validation.values.secondPayout), {
        actual = secondBalance,
        expected = validation.values.prePayoutSecond + validation.values.secondPayout,
        payout = validation.values.secondPayout,
      })
      local reconcileOk, reconcileResult = applyCommitted({ type = "company.reconcile" }, "auto-validator", nil)
      validationCheck("active-company-reconcile", reconcileOk, reconcileResult)
      validationTransition("verify-reconcile")
  
    elseif stage == "verify-reconcile" then
      local firstCid = validation.values.firstCid
      local controlBalance = balanceOf(state.world.controlPlayerId)
      local companyBalance = validationCompanyBalance(firstCid)
      validationCheck("payout-visible-on-turn-desk", moneyEquals(controlBalance, companyBalance), {
        controlBalance = controlBalance,
        companyBalance = companyBalance,
      })
      local ownership = refreshOwnershipProbe()
      validationCheck("ownership-probe-complete", ownership ~= nil and ownership.total ~= nil, ownership)
      validation.values.proposalControlBefore = controlBalance
      validation.values.proposalCompanyBefore = companyBalance
      validation.values.proposalCanonicalBefore = util.tableCount(state.canonical.byCanonical)
      local proposalOk, proposalResult = runValidationCanonicalProposal(firstCid)
      validationCheck("canonical-track-proposal-replay", proposalOk, proposalResult)
      validation.values.proposal = proposalResult
      validationTransition("verify-canonical-proposal")
  
    elseif stage == "verify-canonical-proposal" then
      local firstCid = validation.values.firstCid
      local proposal = validation.values.proposal or {}
      local queuedResult = proposal.result or {}
      local proposalRecord = state.world.proposals.byId[tostring(queuedResult.proposalId or "")]
      if not proposalRecord or proposalRecord.status == "queued" then return end
      if proposalRecord.status == "failed" then
        local retryable = tostring(proposalRecord.error or ""):find("rejected", 1, true) ~= nil
        if retryable and tonumber(proposal.candidate) and proposal.candidate < 16 then
          local retryOk, retryResult = runValidationCanonicalProposal(firstCid, proposal.candidate + 1)
          validationCheck("canonical-track-proposal-retry-queued", retryOk, retryResult)
          validation.values.proposal = retryResult
          validation.stageStartedTick = state.tick
          return
        end
        validationCheck("canonical-track-proposal-native-result", false, proposalRecord)
      end
      local proposalResult = proposalRecord.result or {}
      proposal.finalResult = util.deepCopy(proposalResult)
      local financeResult = proposalResult.finance or {}
      local controlBalance = balanceOf(state.world.controlPlayerId)
      local companyBalance = validationCompanyBalance(firstCid)
      validationCheck("canonical-proposal-output-bindings", #(proposalResult.outputs or {}) == 3, proposalResult)
      validationCheck("canonical-proposal-registry-growth",
        util.tableCount(state.canonical.byCanonical) == validation.values.proposalCanonicalBefore + 3, {
          before = validation.values.proposalCanonicalBefore,
          after = util.tableCount(state.canonical.byCanonical),
        })
      validationCheck("canonical-proposal-control-wallet-restored",
        moneyEquals(controlBalance, validation.values.proposalControlBefore), {
          actual = controlBalance, expected = validation.values.proposalControlBefore,
        })
      validationCheck("canonical-proposal-cost-routed",
        moneyEquals(companyBalance, validation.values.proposalCompanyBefore + (financeResult.delta or 0)), {
          actual = companyBalance,
          expected = validation.values.proposalCompanyBefore + (financeResult.delta or 0),
          delta = financeResult.delta,
        })
      validationCheck("canonical-proposal-native-replay-count",
        (state.probes.capture.proposalReplayCount or 0) >= 1, state.probes.capture)
      local reconcileOk, reconcileResult = applyCommitted({ type = "company.reconcile" }, "auto-validator", nil)
      validationCheck("post-proposal-company-reconcile", reconcileOk, reconcileResult)
      validationTransition("verify-proposal-reconcile")
  
    elseif stage == "verify-proposal-reconcile" then
      local firstCid = validation.values.firstCid
      local controlBalance = balanceOf(state.world.controlPlayerId)
      local companyBalance = validationCompanyBalance(firstCid)
      validationCheck("post-proposal-wallet-remirrored", moneyEquals(controlBalance, companyBalance), {
        controlBalance = controlBalance,
        companyBalance = companyBalance,
      })
      validationComplete()
    else
      error("unknown validation stage: " .. tostring(stage))
    end
  end

  return {
    runStandalone = runAutomatedValidation,
    runNetwork = runAutomatedNetworkValidation,
    fail = validationFail,
  }
end

return M
