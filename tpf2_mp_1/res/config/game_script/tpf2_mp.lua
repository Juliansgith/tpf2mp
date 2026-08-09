local util = require "tpf2_mp/util"
local json = require "tpf2_mp/json"
local hash = require "tpf2_mp/hash"
local canonical = require "tpf2_mp/canonical"
local economy = require "tpf2_mp/economy"
local economyDemo = require "tpf2_mp/economy_demo"
local economyAssetCostRuntimeModule = require "tpf2_mp/economy_asset_cost_runtime"
local bridge = require "tpf2_mp/bridge"
local finance = require "tpf2_mp/finance"
local world = require "tpf2_mp/world"
local presentation = require "tpf2_mp/presentation"
local passengerPresentation = require "tpf2_mp/passenger_presentation"
local cargoPresentation = require "tpf2_mp/cargo_presentation"
local passengerCosmetics = require "tpf2_mp/passenger_cosmetics"
local proposalCodec = require "tpf2_mp/proposal_codec"
local operationCodec = require "tpf2_mp/operation_codec"
local edgeOwnership = require "tpf2_mp/edge_ownership"
local runtimeConfig = require "tpf2_mp/runtime_config"
local stateSchema = require "tpf2_mp/state_schema"
local nativeHook = require "tpf2_mp/native_hook"
local guiState = require "tpf2_mp/gui_state"
local guiView = require "tpf2_mp/gui_view"
local guiLoadRuntimeModule = require "tpf2_mp/gui_load_runtime"
local guiStockPresentation = require "tpf2_mp/gui_stock_presentation"
local guiEntryPointsModule = require "tpf2_mp/gui_entry_points"
local guiCaptureModule = require "tpf2_mp/gui_capture"
local proposalRuntimeModule = require "tpf2_mp/proposal_runtime"
local operationRuntimeModule = require "tpf2_mp/operation_runtime"
local networkIntentRuntimeModule = require "tpf2_mp/network_intent_runtime"
local networkClockRuntimeModule = require "tpf2_mp/network_clock_runtime"
local economyClockRuntimeModule = require "tpf2_mp/economy_clock_runtime"
local economyActionRuntime = require "tpf2_mp/economy_action_runtime"
local economyLineRegistration = require "tpf2_mp/economy_line_registration"
local economySettlementTransaction = require "tpf2_mp/economy_settlement_transaction"
local networkSpeedIndicatorModule = require "tpf2_mp/network_speed_indicator"
local vehicleSyncRuntimeModule = require "tpf2_mp/vehicle_sync_runtime"
local validationRuntimeModule = require "tpf2_mp/validation_runtime"
local guiEventRuntimeModule = require "tpf2_mp/gui_event_runtime"
local checkpointRuntimeModule = require "tpf2_mp/checkpoint_runtime"
local recoveryPrepareRuntimeModule = require "tpf2_mp/recovery_prepare_runtime"
local restoreResumeRuntimeModule = require "tpf2_mp/restore_resume_runtime"
local publicSnapshotModule = require "tpf2_mp/public_snapshot"
local matchRuntimeModule = require "tpf2_mp/match_runtime"
local authoredFollowupRuntime = require "tpf2_mp/authored_followup_runtime"
local operationalCaptureRuntimeModule = require "tpf2_mp/operational_capture_runtime"
local industryContentRuntime = require "tpf2_mp/industry_content_runtime"
local freightIndustryModel = require "tpf2_mp/freight_industry_model"
local freightIndustryRuntime = require "tpf2_mp/freight_industry_runtime"
local aboardMilestoneIntegration = require "tpf2_mp/aboard_milestone_integration"
local serviceRegistrationIntegrationModule = require "tpf2_mp/service_registration_integration"
local SCRIPT_FILE = "tpf2_mp.lua"
local EVENT_ID = "tpf2mp"
local STATE_VERSION = 29
local CHECKPOINT_VERSION = 5
local EVENT_RECORD_VERSION = 1
local function config() return runtimeConfig.read() end
local setDifference = util.setDifference

local function newState()
  return stateSchema.new(config(), {
    stateVersion = STATE_VERSION,
    checkpointVersion = CHECKPOINT_VERSION,
  })
end
local state = newState()
local economyAssetCosts = economyAssetCostRuntimeModule.new({ getState = function() return state end })
local recordProposalInfrastructure = economyAssetCosts.recordProposal
local recordVehiclePurchaseCost = economyAssetCosts.recordVehicle
local backfillVehicleCosts = economyAssetCosts.backfillVehicles
local matchRuntime = matchRuntimeModule.new({ getState = function() return state end })
local rankedWinner = matchRuntime.rankedWinner
local finishMatch = matchRuntime.finish
local evaluateMatchEnd = matchRuntime.evaluateEnd
local requireRunningMatch = matchRuntime.requireRunning
-- Machine-local GUI result IDs live only long enough for the engine to apply a
-- sanitized proposal.finalise event. They are never serialized into the
-- portable action, checkpoint, or network protocol.
local pendingProposalResults = {}
local pendingOperationResults = {}
-- Construction replay finishes asynchronously from update().  Its final graph
-- binding and finance normalization still have to cross applyCommitted so the
-- event/checkpoint chain records the state transition.  Forward-declare the
-- dispatcher because the construction worker is defined before its body.
local applyCommitted
-- A vanilla build is already suppressed by the native gate before the engine
-- learns whether another proposal/checkpoint barrier is still settling. Keep
-- a small machine-local FIFO so independent clicks are submitted in order as
-- authority becomes idle instead of disappearing after the dust animation.
-- Raw captures are never portable match state and deliberately never enter
-- saves or core digests; each is canonicalized only when it reaches the head.
local MAX_DEFERRED_NETWORK_INTENTS = networkIntentRuntimeModule.MAX_DEFERRED_INTENTS
local networkIntentController
local networkClock
local economyClock
local vehicleSync
local freezeNetworkGame
local freezeNetworkCalendar
-- Automatic line registration is defined beside its handler but referenced by
-- the operation runtime constructed earlier, and it submits intents through a
-- controller built later still.
local autoRegisterLineFor
local submitIntent

local diagnosticLog = require("tpf2_mp/diagnostic_log").new(STATE_VERSION)

local nativeHookStatus = nativeHook.status
local validatedNetworkAuthority = nativeHook.validatedNetworkAuthority
local markNativeContext = nativeHook.markContext
local function configureNativeAuthority(mode)
  local network = mode == "network"
  local buildName = network and "tpf2mp_native_enable_build_gate"
    or "tpf2mp_native_disable_build_gate"
  local commandName = network and "tpf2mp_native_enable_command_gate"
    or "tpf2mp_native_disable_command_gate"
  local buildGate = rawget(_G, buildName)
  local commandGate = rawget(_G, commandName)
  if network and (type(buildGate) ~= "function" or type(commandGate) ~= "function") then
    local missing = {}
    if type(buildGate) ~= "function" then missing[#missing + 1] = buildName end
    if type(commandGate) ~= "function" then missing[#missing + 1] = commandName end
    local message = "network mode requires exact-build native authority gates: "
      .. table.concat(missing, ", ")
    state.probes.networkAuthority = { ready = false, mode = mode, error = message }
    return false, message
  end
  for _, operation in ipairs({
    { name = buildName, fn = buildGate },
    { name = commandName, fn = commandGate },
  }) do
    if type(operation.fn) == "function" then
      local ok, err = pcall(operation.fn)
      if not ok then
        local message = "could not configure " .. operation.name .. ": " .. tostring(err)
        state.probes.networkAuthority = { ready = false, mode = mode, error = message }
        return false, message
      end
    end
  end
  state.probes.nativeHook = nativeHookStatus()
  local nativeStatus = state.probes.nativeHook
  local validated, authorityView = validatedNetworkAuthority(nativeStatus)
  local statusReady = not network or validated
  local message = statusReady and nil
    or "native hook did not report a validated, mismatch-free network authority boundary"
  state.probes.networkAuthority = {
    ready = statusReady,
    mode = mode,
    buildGateEnabled = authorityView.buildGateEnabled,
    commandGateEnabled = authorityView.commandGateEnabled,
    commandVisitors = authorityView.commandVisitors,
    error = message,
  }
  return statusReady, message
end


local function migrate(saved)
  return stateSchema.migrate(saved, {
    newState = newState,
    config = config,
    stateVersion = STATE_VERSION,
    checkpointVersion = CHECKPOINT_VERSION,
  })
end
local function isEngineThread()
  -- The same file is loaded into isolated engine and UI Lua states. The game
  -- exposes game.gui only in the UI state; shipped scripts use this boundary
  -- too, so do not infer the thread from a particular interface function.
  return game and game.gui == nil
end

local function activeCompany()
  local index = state.activeCompanyIndex or 1
  if state.networkMode == "network" then
    local peerIndex = tonumber(tostring(state.bridge.peerId or ""):match("(%d+)$"))
    if peerIndex and state.companyOrder[peerIndex] then index = peerIndex end
  end
  local cid = state.companyOrder[index]
  return cid, cid and state.companies[cid] or nil
end

local checkpointRuntime = checkpointRuntimeModule.new({
  getState = function() return state end,
  maxEvents = function() return config().maxEvents end,
  stateVersion = STATE_VERSION,
  checkpointVersion = CHECKPOINT_VERSION,
  eventRecordVersion = EVENT_RECORD_VERSION,
})
local authoredDigest = checkpointRuntime.authoredDigest
local coreDigest = checkpointRuntime.coreDigest
local trimEvents = checkpointRuntime.trimEvents
local emitCheckpoint = checkpointRuntime.emitCheckpoint
local exportCheckpointBarrier = checkpointRuntime.exportCheckpointBarrier
local emitEventRecord = checkpointRuntime.emitEventRecord
local recoveryPrepareRuntime = recoveryPrepareRuntimeModule.new({
  getState = function() return state end,
  emitCheckpoint = emitCheckpoint,
  exportCheckpointBarrier = exportCheckpointBarrier,
})
local restoreResumeRuntime = restoreResumeRuntimeModule.new({ getState = function() return state end, coreDigest = coreDigest })
local balanceOf
local accountOf

local function refreshOwnershipProbe()
  state.probes.ownership = world.ownershipSummary(state.world, state.companies)
  return state.probes.ownership
end

local publicSnapshot = publicSnapshotModule.new({
  getState = function() return state end,
  activeCompany = activeCompany,
  refreshOwnershipProbe = refreshOwnershipProbe,
  balanceOf = function(playerId) return balanceOf and balanceOf(playerId) or nil end,
  accountOf = function(playerId) return accountOf and accountOf(playerId) or nil end,
  coreDigest = coreDigest,
  authoredDigest = authoredDigest,
  deferredNetworkIntents = function()
    return networkIntentController and networkIntentController.deferredIntents() or {}
  end,
  networkIntentAwaitingOrder = function()
    return networkIntentController and networkIntentController.awaitingOrder() or nil
  end,
  maxDeferredNetworkIntents = MAX_DEFERRED_NETWORK_INTENTS,
})
local function publishSnapshot()
  -- The game regularly calls the GUI state's load callback with the engine
  -- script's shared save state. Avoid serialising the same snapshot as a
  -- second command event; the load callback updates gui.snapshot.
  return true
end

local function refreshPassengerCosmetics()
  local presentationView = passengerPresentation.publicView(
    state.world.passengerPresentation, state.economy, state.canonical)
  local ok, result = passengerCosmetics.applyDesiredCounts(
    state.probes.passengerCosmetics, presentationView)
  if ok then state.probes.passengerCosmetics = result end
  return ok, result
end

accountOf = function(playerId)
  local ok, entity = pcall(game.interface.getEntity, playerId)
  if not ok or not entity then return {} end
  return { balance = tonumber(entity.balance), loan = tonumber(entity.loan) }
end

balanceOf = function(playerId)
  return accountOf(playerId).balance
end

local function ensureCompanyStartingCash(target, reason)
  target = math.max(0, util.integer(target, config().startingCash))
  local funding = state.finance.startingCash or finance.newState().startingCash
  state.finance.startingCash = funding
  funding.target = target
  funding.totalGranted = math.max(0, util.integer(funding.totalGranted, 0))
  funding.grants = funding.grants or {}
  funding.lastReason = tostring(reason or "match-setup")
  funding.lastError = nil

  local errors = {}
  local thisRun = {
    target = target,
    reason = funding.lastReason,
    tick = state.tick,
    companies = {},
  }
  for _, companyCid in ipairs(state.companyOrder) do
    local company = state.companies[companyCid]
    local before = company and balanceOf(company.playerId) or nil
    local amount = before and (target - before) or 0
    local booked, bookingError = before ~= nil, nil
    if before == nil then
      bookingError = "company balance is unavailable"
    elseif amount ~= 0 then
      booked, bookingError = finance.book(company.playerId, amount)
    end
    local after = company and balanceOf(company.playerId) or nil
    local verified = booked == true and after ~= nil and math.abs(after - target) < 0.5
    local grant = {
      companyCid = companyCid,
      playerId = company and company.playerId or nil,
      before = before,
      amount = amount,
      after = after,
      ok = verified,
      reason = funding.lastReason,
      tick = state.tick,
      error = verified and nil or tostring(bookingError or "starting-cash postcondition failed"),
    }
    funding.grants[companyCid] = grant
    thisRun.companies[companyCid] = util.deepCopy(grant)
    if verified then
      if amount > 0 then funding.totalGranted = funding.totalGranted + amount end
      company.initialBalance = after
    else
      errors[#errors + 1] = companyCid .. ": " .. grant.error
    end
  end
  if #state.companyOrder == 0 then errors[#errors + 1] = "no competitive companies are bound" end
  if #errors > 0 then funding.lastError = table.concat(errors, "; ") end
  thisRun.totalGranted = funding.totalGranted
  thisRun.error = funding.lastError
  return #errors == 0, thisRun
end

local function proxyTargetPlayer(companyCid)
  local company = companyCid and state.companies[companyCid] or nil
  if not company then return nil end
  local turn = state.world.turn
  if state.world.proxyMode and turn and turn.active and turn.companyCid == companyCid then
    return state.world.controlPlayerId
  end
  return company.playerId
end

local function beginProxyTurn(companyCid)
  if not state.world.proxyMode then return true, { proxyMode = false } end
  local company = state.companies[companyCid]
  local controlPlayerId = state.world.controlPlayerId
  if not company or not controlPlayerId then return false, "proxy turn is missing company/control binding" end
  if state.world.turn and state.world.turn.active then return false, "finish the current proxy turn first" end

  local controlBalanceBefore = balanceOf(controlPlayerId)
  local companyBalanceStart = balanceOf(company.playerId)
  if controlBalanceBefore == nil or companyBalanceStart == nil then
    return false, "could not read proxy/company balance"
  end
  if state.world.proxyBankBaseline == nil then state.world.proxyBankBaseline = controlBalanceBefore end
  local mirrorDelta = companyBalanceStart - controlBalanceBefore
  local mirrored, mirrorError = finance.book(controlPlayerId, mirrorDelta)
  if not mirrored then return false, "could not mirror company balance: " .. tostring(mirrorError) end

  local transfer = world.transferOwnedByPlayer(
    state.world,
    state.canonical,
    company.playerId,
    controlPlayerId,
    companyCid,
    string.format("proxy-begin:%d", state.tick)
  )
  if #transfer.failed > 0 then
    transfer.recovery = transfer.rollback
      or { claimed = {}, failed = {}, skipped = {}, pinned = {}, unchanged = {} }
    local mirrorRollbackOk, mirrorRollbackError = finance.book(controlPlayerId, -mirrorDelta)
    local controlBalanceAfterRollback = balanceOf(controlPlayerId)
    transfer.mirrorRollback = {
      ok = mirrorRollbackOk == true and controlBalanceAfterRollback == controlBalanceBefore,
      error = mirrorRollbackError,
      expected = controlBalanceBefore,
      observed = controlBalanceAfterRollback,
    }
    transfer.error = transfer.mirrorRollback.ok
      and "incoming asset lease failed; the desk mirror and successful ownership changes were rolled back"
      or "incoming asset lease failed and mirror rollback did not meet its postcondition"
    return false, transfer
  end
  if game.interface.setBuildInPauseModeAllowed then pcall(game.interface.setBuildInPauseModeAllowed, true) end
  if game.interface.setMaximumLoan then pcall(game.interface.setMaximumLoan, controlPlayerId, 0) end
  local paused = false
  if state.world.pauseOnSwitch and game.interface.setGameSpeed then
    paused = pcall(game.interface.setGameSpeed, 0)
  end
  state.world.turn = {
    active = true,
    companyCid = companyCid,
    startedTick = state.tick,
    balanceStart = companyBalanceStart,
    controlBalanceBefore = controlBalanceBefore,
    mirrorDelta = mirrorDelta,
    controlBaseline = state.world.proxyBankBaseline,
    companyLoanStart = accountOf(company.playerId).loan,
    controlLoanStart = accountOf(controlPlayerId).loan,
    leasedAssets = #transfer.claimed,
    paused = paused,
  }
  if game.interface.setName then pcall(game.interface.setName, controlPlayerId, "Playing: " .. company.name) end
  refreshOwnershipProbe()
  return true, { companyCid = companyCid, leased = transfer, turn = util.deepCopy(state.world.turn) }
end

local function enforceProxyLoanLimit()
  if not (state.world.proxyMode and state.world.turn and state.world.turn.active) then return end
  local controlPlayerId = state.world.controlPlayerId
  if controlPlayerId and game.interface.setMaximumLoan then
    -- The base game refreshes its normal maximum loan from its own update loop.
    -- Reassert the turn-desk limit so native borrowing cannot silently bypass
    -- the company wallet mirrored into the proxy.
    pcall(game.interface.setMaximumLoan, controlPlayerId, 0)
  end
end

local function finishProxyTurn(reason)
  if not state.world.proxyMode then return true, { proxyMode = false } end
  local turn = state.world.turn
  if not turn or not turn.active then return true, { proxyMode = true, active = false } end
  local company = state.companies[turn.companyCid]
  if not company then return false, "active proxy company is missing" end
  local controlPlayerId = state.world.controlPlayerId
  local balanceEnd = balanceOf(controlPlayerId)
  local balanceDelta = balanceEnd and turn.balanceStart and (balanceEnd - turn.balanceStart) or nil
  local edgeReplacementRecovery = nil
  if state.world.edgeReplacementFailure then
    local failure = util.deepCopy(state.world.edgeReplacementFailure)
    local recovered, recovery = world.recoverProxyEdgeCustody(
      state.world,
      state.canonical,
      failure,
      controlPlayerId,
      company.playerId,
      turn.companyCid,
      string.format("proxy-edge-recover:%d", state.tick),
      state.companies
    )
    if recovered then
      edgeReplacementRecovery = util.deepCopy(recovery)
      state.world.edgeReplacementFailure = nil
      state.world.lastEdgeReplacementRecovery = util.deepCopy(recovery)
      local capture = state.probes.capture
      capture.replacementRecoveryCount = (capture.replacementRecoveryCount or 0) + 1
      capture.lastReplacementRecovery = util.deepCopy(recovery)
      capture.replacementRecoveryHistory = capture.replacementRecoveryHistory or {}
      capture.replacementRecoveryHistory[#capture.replacementRecoveryHistory + 1] = util.deepCopy(recovery)
      while #capture.replacementRecoveryHistory > 8 do
        table.remove(capture.replacementRecoveryHistory, 1)
      end
    else
    local result = {
      companyCid = turn.companyCid,
      returned = { claimed = {}, failed = {}, skipped = {}, pinned = {}, unchanged = {} },
      balanceStart = turn.balanceStart,
      balanceEnd = balanceEnd,
      balanceDelta = balanceDelta,
      finance = { skipped = true, reason = "unresolved edge replacement" },
      reason = reason or "cycle",
      error = "edge replacement mapping failed before financial settlement; no money was moved",
      edgeReplacementFailure = failure,
      edgeReplacementRecovery = recovery,
    }
    turn.lastFailure = {
      tick = state.tick,
      stage = "edge-replacement",
      reason = reason or "cycle",
      failure = failure,
    }
    state.world.turn = turn
    state.world.lastTransition = util.deepCopy(result)
    refreshOwnershipProbe()
    return false, result
    end
  end
  local pinnedValidation = world.validatePinnedEdgeCustody(
    state.world, controlPlayerId, state.companies)
  if #(pinnedValidation.failed or {}) > 0 then
    local result = {
      companyCid = turn.companyCid,
      returned = { claimed = {}, failed = {}, skipped = {}, pinned = {}, unchanged = {} },
      balanceStart = turn.balanceStart,
      balanceEnd = balanceEnd,
      balanceDelta = balanceDelta,
      finance = { skipped = true, reason = "pinned edge custody postcondition failed" },
      reason = reason or "cycle",
      error = "pinned edge custody failed before financial settlement; no money was moved",
      pinnedValidation = util.deepCopy(pinnedValidation),
    }
    turn.lastFailure = {
      tick = state.tick,
      stage = "pinned-edge-postcondition",
      reason = reason or "cycle",
      failed = util.deepCopy(pinnedValidation.failed),
    }
    state.world.turn = turn
    state.world.lastTransition = util.deepCopy(result)
    refreshOwnershipProbe()
    return false, result
  end
  local returned = world.transferOwnedByPlayer(
    state.world,
    state.canonical,
    controlPlayerId,
    company.playerId,
    turn.companyCid,
    string.format("proxy-end:%d", state.tick)
  )
  local result = {
    companyCid = turn.companyCid,
    returned = returned,
    balanceStart = turn.balanceStart,
    balanceEnd = balanceEnd,
    balanceDelta = balanceDelta,
    finance = { skipped = true, reason = "waiting for ownership return postconditions" },
    reason = reason or "cycle",
    edgeReplacementRecovery = edgeReplacementRecovery,
  }

  -- Asset custody and money form one logical transaction. Never restore the
  -- desk baseline or credit the company until every outgoing ownership change
  -- has passed its postcondition. The old ordering settled money even when one
  -- road edge refused transfer, leaving a live ~5M turn on the 30M desk and
  -- allowing every retry to credit the 25M difference again.
  if #returned.failed > 0 then
    result.recovery = returned.rollback
      or { claimed = {}, failed = {}, skipped = {}, pinned = {}, unchanged = {} }
    result.error = "asset return failed before financial settlement; no money was moved"
    turn.lastFailure = {
      tick = state.tick,
      stage = "asset-return",
      reason = reason or "cycle",
      failed = util.deepCopy(returned.failed),
      recoveryFailed = util.deepCopy(result.recovery.failed),
    }
    state.world.turn = turn
    state.world.lastTransition = util.deepCopy(result)
    refreshOwnershipProbe()
    return false, result
  end

  if balanceEnd == nil or turn.balanceStart == nil or state.world.proxyBankBaseline == nil then
    result.recovery = world.rollbackTransfer(
      state.world,
      state.canonical,
      returned,
      turn.companyCid,
      string.format("proxy-recover:%d", state.tick)
    )
    result.error = "proxy balance unavailable; returned assets were leased back and no money was moved"
    turn.lastFailure = {
      tick = state.tick,
      stage = "finance-precondition",
      reason = reason or "cycle",
      recoveryFailed = util.deepCopy(result.recovery.failed),
    }
    state.world.turn = turn
    state.world.lastTransition = util.deepCopy(result)
    refreshOwnershipProbe()
    return false, result
  end

  local financeOk, financeResult = finance.settleProxyTurn(
    state.finance,
    controlPlayerId,
    company.playerId,
    turn.balanceStart,
    balanceEnd,
    state.world.proxyBankBaseline,
    {
      source = "proxy-turn",
      companyCid = turn.companyCid,
      reason = reason or "cycle",
      startedTick = turn.startedTick,
      endedTick = state.tick,
    }
  )
  result.finance = financeResult
  if not financeOk then
    result.recovery = world.rollbackTransfer(
      state.world,
      state.canonical,
      returned,
      turn.companyCid,
      string.format("proxy-recover:%d", state.tick)
    )
    result.error = "financial settlement failed and was rolled back; returned assets were leased back"
    turn.lastFailure = {
      tick = state.tick,
      stage = "finance",
      reason = reason or "cycle",
      finance = util.deepCopy(financeResult),
      recoveryFailed = util.deepCopy(result.recovery.failed),
    }
    state.world.turn = turn
    state.world.lastTransition = util.deepCopy(result)
    refreshOwnershipProbe()
    return false, result
  end

  state.world.turn = nil
  state.world.lastTransition = util.deepCopy(result)
  refreshOwnershipProbe()
  return true, result
end

local function repairCompanyStartingCash()
  if not state.initialized then return false, "initialise the match first" end
  if state.networkMode == "network" then
    return false, "starting-cash repair is standalone-only; network funding must arrive in the host's ordered match.initialise commit"
  end
  local companyCid = activeCompany()
  if not companyCid then return false, "active company is unavailable" end

  local finishedOk, finished = finishProxyTurn("starting-cash-repair")
  if not finishedOk then
    return false, { error = "could not close the active proxy turn before funding repair", finished = finished }
  end

  local rules = state.match and state.match.rules or {}
  local target = rules.startingCash
    or (state.finance.startingCash and state.finance.startingCash.target)
    or config().startingCash
  local funded, funding = ensureCompanyStartingCash(target, "manual-repair")
  if funded then
    state.finance.startingCash.repairs = math.max(0, util.integer(state.finance.startingCash.repairs, 0)) + 1
  end

  local beganOk, began = true, { proxyMode = false }
  if state.world.proxyMode then beganOk, began = beginProxyTurn(companyCid) end
  if not funded or not beganOk then
    return false, {
      error = not funded and "starting-cash top-up failed" or "cash was repaired, but the active proxy turn could not be reopened",
      funding = funding,
      finished = finished,
      began = began,
    }
  end
  return true, {
    activeCompanyCid = companyCid,
    funding = funding,
    repairs = state.finance.startingCash.repairs,
    finished = finished,
    began = began,
  }
end

-- Loss and victory conditions are match rules, not architecture. A group
-- that wants to build side by side and compare company value at the end
-- should be able to switch elimination off entirely; a group that wants a
-- knife fight should be able to make credit tight. Both are the same code
-- with different numbers, and the numbers are authored match state so both
-- peers judge by identical rules.
local function normaliseMatchRules(rules)
  rules = type(rules) == "table" and rules or {}
  local cfg = config()
  local observedClock = world.clockSnapshot()
  local observedStart = util.integer(observedClock and observedClock.time, 0)
  local economyStartGameTimeSeconds = math.max(0, util.integer(
    rules.economyStartGameTimeSeconds, observedStart))
  local bankruptcyEnabled = rules.bankruptcyEnabled
  if bankruptcyEnabled == nil then bankruptcyEnabled = cfg.bankruptcyEnabled end
  local difficultyRule = economy.difficultyRule(rules.economyDifficulty or cfg.economyDifficulty)
  return {
    startingCash = math.max(0, util.integer(rules.startingCash, cfg.startingCash)),
    maxEpochs = math.max(0, util.integer(rules.maxEpochs, cfg.maxEpochs)),
    valuationTargetCents = math.max(0, util.integer(rules.valuationTargetCents, cfg.valuationTargetCents)),
    bankruptcyEnabled = bankruptcyEnabled ~= false,
    -- Zero keeps credit available but never eliminates anyone: debt still
    -- costs interest and still constrains what you can buy.
    insolventSettlements = math.max(0, util.integer(rules.insolventSettlements,
      cfg.insolventSettlements)),
    creditBaseLimitCents = math.max(0, util.integer(rules.creditBaseLimitCents,
      cfg.creditBaseLimitCents)),
    creditRevenueMultiple = math.max(0, util.integer(rules.creditRevenueMultiple,
      cfg.creditRevenueMultiple)),
    creditInterestPermille = math.max(0, util.integer(rules.creditInterestPermille,
      cfg.creditInterestPermille)),
    economyDifficulty = difficultyRule.key, revenueMultiplierPpm = difficultyRule.revenueMultiplierPpm,
    economyEpochSeconds = economy.EPOCH_SECONDS,
    economyStartGameTimeSeconds = economyStartGameTimeSeconds,
  }
end

local function initialiseMatch(rules)
  if state.initialized then return false, "match is already initialised" end
  local difficultyOk, difficultyError = economy.validateDifficultyRule(rules)
  if not difficultyOk then return false, difficultyError end
  local matchRules = normaliseMatchRules(rules)
  local proxyMode = state.networkMode == "standalone" and config().localProxy
  if proxyMode and state.finance.neutralizer.enabled then
    state.finance.neutralizer.enabled = false
    state.finance.neutralizer.lastTimeMs = nil
    state.finance.neutralizer.lastError = "disabled because the native-income neutralizer is incompatible with turn-desk balance mirroring"
  end
  local peerCompanyIndex = state.networkMode == "network"
    and tonumber(tostring(state.bridge.peerId or ""):match("(%d+)$")) or 1
  peerCompanyIndex = util.clamp(util.integer(peerCompanyIndex, 1), 1, 2)
  local ok, playersOrError = world.initialiseCompanies(state.world, state.canonical, 2, {
    proxyMode = proxyMode,
    localCompanyIndex = peerCompanyIndex,
    canonicalNetworkOwnership = state.networkMode == "network",
  })
  if not ok then return false, playersOrError end
  local playerIds = playersOrError.companyPlayerIds or playersOrError
  local nativeOwnershipProjection = playersOrError.nativeOwnershipProjection
  state.companies = {}
  state.companyOrder = {}
  for index, playerId in ipairs(playerIds) do
    local cid = "company:" .. tostring(index)
    state.companyOrder[#state.companyOrder + 1] = cid
    state.companies[cid] = {
      cid = cid,
      playerId = playerId,
      name = "Company " .. tostring(index),
      initialBalance = balanceOf(playerId),
    }
  end
  state.activeCompanyIndex = util.clamp(state.activeCompanyIndex or 1, 1, #state.companyOrder)
  local funded, funding = ensureCompanyStartingCash(matchRules.startingCash, "match-initialise")
  if not funded then return false, { error = "could not provision company starting cash", funding = funding } end
  if state.networkMode == "network" then
    finance.initialiseNetworkAccounts(state.finance, state.companyOrder, matchRules.startingCash, {
      reason = "match-initialise",
      tick = state.tick,
      sessionId = state.bridge.sessionId,
    })
  end
  for _, companyCid in ipairs(state.companyOrder) do
    economy.applyInfrastructureChange(state.economy, companyCid, 0, 0)
  end
  state.initialized = true
  state.probes.capabilities = world.capabilityProbe()
  local proxySetup
  if state.world.proxyMode then
    state.world.proxyBankBaseline = balanceOf(state.world.controlPlayerId)
    local firstCid = state.companyOrder[1]
    local firstCompany = state.companies[firstCid]
    local imported = world.transferOwnedByPlayer(
      state.world,
      state.canonical,
      state.world.controlPlayerId,
      firstCompany.playerId,
      firstCid,
      string.format("proxy-import:%d", state.tick)
    )
    local began, beginResult = beginProxyTurn(firstCid)
    if not began then state.initialized = false; return false, beginResult end
    proxySetup = { imported = imported, began = beginResult, funding = funding }
  else
    refreshOwnershipProbe()
  end
  local worldManifest = world.canonicalManifest(
    state.canonical, state.networkMode == "network" and state.world or nil)
  local vehicleCostBackfill = backfillVehicleCosts()
  -- The ordered checkpoint needs the portable digest and summary, not the
  -- complete row inventory.  Keeping hundreds of generated construction and
  -- asset rows in persistent game-script state causes Build 35924 to copy a
  -- needlessly large Lua graph at every native proposal boundary.  Selected
  -- operational roots are still admitted lazily into state.canonical.
  state.probes.worldManifest = {
    schemaVersion = worldManifest.schemaVersion,
    total = worldManifest.total,
    uniqueBound = worldManifest.uniqueBound,
    deferredUnique = worldManifest.deferredUnique,
    ambiguousCount = worldManifest.ambiguousCount,
    digest = worldManifest.digest,
  }
  state.probes.structural = world.structuralSnapshot(state.canonical, state.world, state.companies)
  if config().autoFreeze and not state.world.autonomyFrozen then world.freezeAutonomy(state.world, true) end
  -- Build 35924's live probe proved setTownInfo is not a safe runtime capacity
  -- scaler. Record that result without issuing native mutations here; the
  -- loadConstruction modifier remains the policy surface for buildings while
  -- their resources/world are loaded.
  presentation.applyConfiguredPolicy(state, config(),
    { listTowns = world.listTowns, townCapacity = world.townCapacity }, diagnosticLog)
  state.match = {
    status = "running",
    startedTick = state.tick,
    finishedTick = nil,
    winnerCid = nil,
    finishReason = nil,
    rules = matchRules,
  }
  economy.configureMatch(state.economy, matchRules)
  local publicCompanies = {}
  for _, cid in ipairs(state.companyOrder) do
    publicCompanies[cid] = { cid = cid, name = state.companies[cid].name }
  end
  return true, {
    companies = publicCompanies,
    structuralDigest = state.probes.structural.digest,
    worldManifestDigest = state.probes.worldManifest.digest,
    proxyMode = state.world.proxyMode,
    proxySetup = proxySetup,
    nativeOwnershipProjection = util.deepCopy(nativeOwnershipProjection),
    funding = funding,
    vehicleCostBackfill = util.deepCopy(vehicleCostBackfill),
    match = util.deepCopy(state.match),
    note = state.world.proxyMode
      and "The native UI is a turn proxy; active assets and net turn finances return to the selected company on cycle/reconcile."
      or "Competitive company selection is mod-owned; native UI attribution uses post-build capture.",
  }
end

local function requireCompany()
  local cid, company = activeCompany()
  if not company then return nil, nil, "initialise the match first" end
  return cid, company
end

local function lineIdFromAction(action)
  if action.lineCid then
    local localId = canonical.resolveLocal(state.canonical, action.lineCid)
    if localId then return localId, action.lineCid end
    return nil, action.lineCid, "canonical line is not mapped on this machine: " .. tostring(action.lineCid)
  end
  if action.localLineId then
    local lineCid, err = world.bindExisting(state.canonical, tonumber(action.localLineId), "line")
    if not lineCid then return nil, nil, err end
    return tonumber(action.localLineId), lineCid
  end
  return nil, nil, "line selection required"
end

local function seedDemo()
  return economyDemo.seed(state, economy)
end

local function proposalResourceName(kind, index)
  local repository = api and api.res and (kind == "street" and api.res.streetTypeRep
    or (kind == "track" and api.res.trackTypeRep
    or (kind == "model" and api.res.modelRep or nil))) or nil
  if not (repository and repository.find) then return nil end
  -- Bound C++ repository methods can be callable userdata/tables rather than
  -- reporting Lua type "function". Presence plus guarded invocation is the
  -- actual API contract used by the base game.
  if repository.getName ~= nil then
    local named, directName = pcall(repository.getName, index)
    if named and type(directName) == "string" and directName ~= "" then
      local found, localIndex = pcall(repository.find, directName)
      if found and tonumber(localIndex) == tonumber(index) then return directName end
    end
  end
  if repository.getAll == nil then return nil end
  local ok, names = pcall(repository.getAll)
  if not ok or names == nil then return nil end
  local candidates = {}
  -- Build 35924 exposes several repository collections as iterable userdata,
  -- not ordinary Lua tables. The former type check silently stripped every
  -- road/track filename from network transactions. The base game itself uses
  -- pairs(repository.getAll()), so use the same guarded iteration contract.
  local iterated = pcall(function()
    for _, name in pairs(names) do
      if type(name) == "string" then candidates[#candidates + 1] = name end
    end
  end)
  if not iterated then return nil end
  table.sort(candidates)
  for _, name in ipairs(candidates) do
    local found, localIndex = pcall(repository.find, name)
    if found and tonumber(localIndex) == tonumber(index) then return name end
  end
  return nil
end

local function proposalEntityPosition(kind, localId)
  if kind ~= "node" or tonumber(localId) == nil or not (api and api.engine
    and api.engine.getComponent and api.type and api.type.ComponentType
    and api.type.ComponentType.BASE_NODE) then return nil end
  local ok, component = pcall(
    api.engine.getComponent, tonumber(localId), api.type.ComponentType.BASE_NODE)
  if not ok or component == nil then return nil end
  local positionOk, x, y, z = pcall(function()
    local position = component.position or component.pos
    return position and (position.x or position[1]),
      position and (position.y or position[2]),
      position and (position.z or position[3])
  end)
  if not positionOk or tonumber(x) == nil or tonumber(y) == nil or tonumber(z) == nil then
    return nil
  end
  return { x = tonumber(x), y = tonumber(y), z = tonumber(z) }
end

local function proposalResolveCanonical(kind, localId)
  local cid = canonical.resolveCanonical(state.canonical, kind, localId)
  if cid then return cid end
  -- Proposal capture is pre-consensus. It may derive a stable identity, but it
  -- must not bind that identity or enrich metadata on the origin alone. The
  -- ordered proposal commit resolves and binds every missing pre-existing
  -- reference identically on all peers.
  return world.identifyExisting(state.canonical, localId, kind)
end

local function componentOf(entity, componentType)
  if not (api and api.engine and api.engine.getComponent and componentType) then return nil end
  local ok, value = pcall(api.engine.getComponent, entity, componentType)
  return ok and value or nil
end

local function componentEntitySet(componentType)
  local result = {}
  if not (api and api.engine and api.engine.forEachEntityWithComponent and componentType) then
    return nil, "component enumeration is unavailable"
  end
  local ok, err = pcall(function()
    api.engine.forEachEntityWithComponent(function(entity)
      entity = tonumber(entity)
      if entity and entity >= 0 then result[entity] = true end
    end, componentType)
  end)
  return ok and result or nil, ok and nil or tostring(err)
end

local function nodePosition(entity)
  local types = api and api.type and api.type.ComponentType or {}
  local node = componentOf(entity, types.BASE_NODE)
  local position = node and (node.position or node.pos) or nil
  if not position then return nil end
  local x, y, z = tonumber(position.x or position[1]), tonumber(position.y or position[2]), tonumber(position.z or position[3])
  if not x or not y or not z then return nil end
  return { x = x, y = y, z = z }
end

local function inspectCreatedNodes(ids)
  local result = {}
  for _, localId in ipairs(ids or {}) do
    local position = nodePosition(localId)
    if position then result[#result + 1] = { localId = localId, position = position } end
  end
  return result
end

local function inspectCreatedEdges(ids)
  local result = {}
  local types = api and api.type and api.type.ComponentType or {}
  for _, localId in ipairs(ids or {}) do
    local base = componentOf(localId, types.BASE_EDGE)
    if base then
      local track = componentOf(localId, types.BASE_EDGE_TRACK)
      local street = componentOf(localId, types.BASE_EDGE_STREET)
      result[#result + 1] = {
        localId = localId,
        carrier = track and "track" or street and "street" or "unknown",
        node0Position = nodePosition(tonumber(base.node0)),
        node1Position = nodePosition(tonumber(base.node1)),
        resourceIndex = tonumber(track and track.trackType or street and street.streetType),
        catenary = track and track.catenary or nil,
        objects = (function()
          local objects = {}
          local source = base.objects
          if type(source) == "table" or type(source) == "userdata" then
            local lengthOk, length = pcall(function() return #source end)
            if lengthOk then
              for index = 1, math.min(tonumber(length) or 0, proposalCodec.MAX_EDGE_OBJECTS) do
                local readOk, pair = pcall(function() return source[index] end)
                if readOk and pair ~= nil then
                  local function pairField(key)
                    local ok, value = pcall(function() return pair[key] end)
                    return ok and value or nil
                  end
                  local objectId = tonumber(pairField(1) or pairField("entity")
                    or pairField("entityId"))
                  local category = tonumber(pairField(2) or pairField("category")
                    or pairField("type"))
                  if objectId and objectId >= 0 and category then
                    objects[#objects + 1] = { localId = objectId, category = category }
                  end
                end
              end
            end
          end
          return objects
        end)(),
      }
    end
  end
  return result
end

local proposalRuntime = proposalRuntimeModule.new({
  getState = function() return state end,
  requireRunningMatch = requireRunningMatch,
  balanceOf = function(playerId) return balanceOf(playerId) end,
  coreDigest = coreDigest,
  refreshOwnershipProbe = refreshOwnershipProbe,
  componentEntitySet = componentEntitySet,
  inspectCreatedNodes = inspectCreatedNodes,
  inspectCreatedEdges = inspectCreatedEdges,
  nodePosition = nodePosition,
  applyCommitted = function(...) return applyCommitted(...) end,
})
local proposalPreparation = proposalRuntime.preparation
local queueCanonicalProposal = proposalRuntime.queue
local finaliseCanonicalProposal = proposalRuntime.finalise
local beginCanonicalConstruction = proposalRuntime.beginConstruction
local finaliseCanonicalConstruction = proposalRuntime.finaliseConstruction
local processCanonicalConstructionProposals = proposalRuntime.processConstructions
local processPendingProposalFinances = proposalRuntime.processFinances
local networkFinanceHousekeeping = proposalRuntime.financeHousekeeping
local emitProposalCompletion = proposalRuntime.emitCompletion

local operationRuntime = operationRuntimeModule.new({
  getState = function() return state end,
  requireRunningMatch = requireRunningMatch,
  balanceOf = function(playerId) return balanceOf(playerId) end,
  coreDigest = coreDigest,
  refreshOwnershipProbe = refreshOwnershipProbe,
  proposalPreparation = proposalPreparation,
  autoRegisterLine = function(...) return autoRegisterLineFor(...) end,
})
local queueCanonicalOperation = operationRuntime.queue
local finaliseCanonicalOperation = operationRuntime.finalise
local emitOperationCompletion = operationRuntime.emitCompletion
local handlers = {}

handlers["match.initialise"] = function(action) return initialiseMatch(action and action.rules) end

handlers["match.finish"] = function(action)
  return finishMatch(action.reason or "manual", action.winnerCid)
end

handlers["company.cycle"] = function()
  if state.networkMode == "network" then return false, "network peers are pinned to their own company" end
  if #state.companyOrder == 0 then return false, "initialise the match first" end
  local previousIndex = state.activeCompanyIndex or 1
  local previousCid = state.companyOrder[previousIndex]
  local finishedOk, finished = finishProxyTurn("cycle")
  if not finishedOk then
    return false, { error = finished.error or "could not settle outgoing proxy turn", transition = finished }
  end
  state.activeCompanyIndex = ((state.activeCompanyIndex or 1) % #state.companyOrder) + 1
  local cid, company = activeCompany()
  local beganOk, began = beginProxyTurn(cid)
  if not beganOk then
    state.activeCompanyIndex = previousIndex
    beginProxyTurn(previousCid)
    return false, { error = type(began) == "table" and began.error or "could not lease incoming company assets", transition = began }
  end
  return true, { activeCompanyCid = cid, name = company.name, finished = finished, began = began }
end

handlers["company.reconcile"] = function()
  if not state.world.proxyMode then return false, "native turn proxy is not enabled" end
  local cid = activeCompany()
  local finishedOk, finished = finishProxyTurn("reconcile")
  if not finishedOk then return false, finished end
  local beganOk, began = beginProxyTurn(cid)
  return beganOk, {
    activeCompanyCid = cid,
    finished = finished,
    began = began,
    error = not beganOk and (type(began) == "table" and began.error or "could not reopen the active company turn") or nil,
  }
end

handlers["finance.repair_starting_cash"] = function()
  return repairCompanyStartingCash()
end

handlers["world.freeze"] = function(action)
  return true, world.freezeAutonomy(state.world, action.freeze ~= false)
end

handlers["world.claim"] = function(action, eventId)
  local companyCid, company, err = requireCompany()
  if not company then return false, err end
  local targetPlayerId = proxyTargetPlayer(companyCid)
  local result = world.claimEntities(state.canonical, action.ids or {}, targetPlayerId, eventId, {
    logicalOwnerCid = companyCid,
    worldState = state.world,
  })
  refreshOwnershipProbe()
  return #result.failed == 0, result
end

handlers["proposal.build"] = function(action, eventId, commitSeq)
  return queueCanonicalProposal(action and action.transaction, eventId, commitSeq)
end

handlers["proposal.prepare"] = function(action, eventId, commitSeq)
  return proposalPreparation.prepare(action and action.transaction, eventId, commitSeq)
end

handlers["network.proposal_prepare_outcome"] = function(action)
  local proposalDigest = type(action) == "table" and tostring(action.proposalDigest or "") or ""
  if proposalDigest ~= "" then proposalPreparation.pending[proposalDigest] = nil end
  if action and action.success == true then
    return true, { prepared = true, proposalDigest = proposalDigest }
  end
  return false, "multiplayer build rejected before commit: "
    .. tostring(action and action.errorCode or "proposal-prepare-failed")
end

handlers["proposal.finalise"] = function(action)
  local proposalId = type(action) == "table" and tostring(action.proposalId or "") or ""
  local payload = pendingProposalResults[proposalId]
  if not payload then return false, "proposal finalise payload is unavailable locally" end
  pendingProposalResults[proposalId] = nil
  return finaliseCanonicalProposal(payload)
end

handlers["proposal.construction_step"] = function(action)
  local proposalId = type(action) == "table" and tostring(action.proposalId or "") or ""
  local record = state.world.proposals.byId[proposalId]
  if not record or not record.transaction
    or record.transaction.schemaVersion ~= proposalCodec.CONSTRUCTION_SCHEMA_VERSION then
    return false, "construction proposal is unavailable locally"
  end
  if proposalCodec.isTopologyConstructionRemoval(record.transaction) then
    return false, "compound topology demolition must use GUI BuildProposal replay"
  end
  if action.localOnly ~= true then return false, "construction step must remain machine-local" end
  if record.status == "queued" then return beginCanonicalConstruction(record) end
  if record.status == "building-construction" and record.constructionPending then
    return finaliseCanonicalConstruction(record)
  end
  return false, "construction proposal is not awaiting an engine step"
end

handlers["operation.execute"] = function(action, eventId, commitSeq)
  return queueCanonicalOperation(action and action.transaction, eventId, commitSeq,
    action and action.originCaptureToken)
end

handlers["operation.finalise"] = function(action)
  local operationId = type(action) == "table" and tostring(action.operationId or "") or ""
  local payload = pendingOperationResults[operationId]
  if not payload then return false, "operation finalise payload is unavailable locally" end
  pendingOperationResults[operationId] = nil
  return finaliseCanonicalOperation(payload)
end

handlers["network.operation_outcome"] = function(action)
  if state.networkMode ~= "network" then return false, "operation consensus exists only in network mode" end
  local operationId = type(action) == "table" and tostring(action.operationId or "") or ""
  local consensus = state.world.operationConsensus
  local record = state.world.operations.byId[operationId]
  if not record then
    if action.success == true then return false, "successful consensus references an unknown operation" end
    local fault = {
      operationId = operationId,
      commitSeq = tonumber(action.commitSeq),
      operationDigest = tostring(action.operationDigest or ""),
      success = false,
      status = "faulted",
      errorCode = tostring(action.errorCode or "operation-consensus-failed"),
      tick = state.tick,
    }
    consensus.byId[operationId] = fault
    consensus.lastOutcome = util.deepCopy(fault)
    consensus.failed = (consensus.failed or 0) + 1
    consensus.sessionFault = util.deepCopy(fault)
    return false, fault
  end
  if tonumber(action.commitSeq) ~= tonumber(record.commitSeq) then
    return false, "operation consensus commit sequence mismatch"
  end
  local existing = consensus.byId[operationId]
  if existing and existing.status ~= "pending" then
    local same = existing.success == (action.success == true)
      and tostring(existing.resultDigest or "") == tostring(action.resultDigest or "")
      and tostring(existing.coreDigest or "") == tostring(action.coreDigest or "")
    if not same then return false, "conflicting operation consensus outcome" end
    return existing.success, util.deepCopy(existing)
  end
  local localCompletion = record.completion
  local success = action.success == true
  if success and (not localCompletion or localCompletion.success ~= true
    or tostring(localCompletion.resultDigest or "") ~= tostring(action.resultDigest or "")
    or tostring(localCompletion.coreDigest or "") ~= tostring(action.coreDigest or "")) then
    success = false
    action = util.deepCopy(action)
    action.errorCode = "local-operation-completion-does-not-match-consensus"
  end
  local authoritativeFinanceDelta = tonumber(action.financeDelta)
  local canonicalFinanceEntry, nativeReconciliation
  if success and authoritativeFinanceDelta == nil then
    success = false
    action = util.deepCopy(action)
    action.errorCode = "operation-finance-consensus-is-unavailable"
  elseif success then
    local applied, entryOrError = finance.applyNetworkDelta(
      state.finance, record.companyCid, authoritativeFinanceDelta, {
        kind = "operation",
        operationId = operationId,
        operationKind = record.transaction.kind,
        commitSeq = tonumber(action.commitSeq),
      })
    if not applied then
      success = false
      action = util.deepCopy(action)
      action.errorCode = "operation-canonical-finance-failed:" .. tostring(entryOrError)
    else
      canonicalFinanceEntry = entryOrError
      local reconciled, reconciliationOrError = finance.reconcileNetworkAccounts(
        state.finance, state.companies, {
          reason = "operation-consensus",
          operationId = operationId,
          commitSeq = tonumber(action.commitSeq),
          tick = state.tick,
        })
      nativeReconciliation = type(reconciliationOrError) == "table"
        and reconciliationOrError or { error = tostring(reconciliationOrError) }
      if not reconciled then
        success = false
        action = util.deepCopy(action)
        action.errorCode = "operation-native-wallet-reconciliation-failed:"
          .. tostring(nativeReconciliation.error or reconciliationOrError)
      end
    end
  end
  if success then recordVehiclePurchaseCost(record, authoritativeFinanceDelta) end
  local outcome = {
    operationId = operationId,
    commitSeq = tonumber(action.commitSeq),
    operationDigest = tostring(action.operationDigest or ""),
    success = success,
    status = success and "complete" or "faulted",
    resultDigest = tostring(action.resultDigest or ""),
    coreDigest = tostring(action.coreDigest or ""),
    financeDelta = authoritativeFinanceDelta,
    canonicalFinanceEntry = util.deepCopy(canonicalFinanceEntry),
    nativeReconciliation = util.deepCopy(nativeReconciliation),
    peers = util.deepCopy(type(action.peers) == "table" and action.peers or {}),
    errorCode = success and nil or tostring(action.errorCode or "operation-consensus-failed"),
    tick = state.tick,
  }
  consensus.byId[operationId] = outcome
  consensus.lastOutcome = util.deepCopy(outcome)
  if success then consensus.completed = (consensus.completed or 0) + 1
  else
    consensus.failed = (consensus.failed or 0) + 1
    consensus.sessionFault = util.deepCopy(outcome)
  end
  if success and vehicleSync then vehicleSync.onOperationConsensus(record) end
  return success, util.deepCopy(outcome)
end

handlers["network.proposal_outcome"] = function(action)
  if state.networkMode ~= "network" then return false, "proposal consensus exists only in network mode" end
  local proposalId = type(action) == "table" and tostring(action.proposalId or "") or ""
  local requestedRecoverable = type(action) == "table" and action.recoverable == true
  local recoverable = requestedRecoverable and action.success ~= true
  local consensus = state.world.proposalConsensus
  local record = state.world.proposals.byId[proposalId]
  if not record then
    if action.success == true then return false, "successful consensus references an unknown proposal" end
    local existingFault = consensus.byId[proposalId]
    if existingFault and existingFault.status == "faulted" then return false, util.deepCopy(existingFault) end
    local fault = {
      proposalId = proposalId,
      commitSeq = tonumber(action.commitSeq),
      success = false,
      recoverable = false,
      status = "faulted",
      proposalDigest = tostring(action.proposalDigest or ""),
      resultDigest = tostring(action.resultDigest or ""),
      coreDigest = tostring(action.coreDigest or ""),
      peers = util.deepCopy(type(action.peers) == "table" and action.peers or {}),
      errorCode = recoverable and "recoverable-rejection-references-unknown-proposal"
        or tostring(action.errorCode or "proposal-consensus-failed"),
      tick = state.tick,
    }
    consensus.byId[proposalId] = fault
    consensus.lastOutcome = util.deepCopy(fault)
    consensus.failed = (consensus.failed or 0) + 1
    consensus.sessionFault = util.deepCopy(fault)
    return false, util.deepCopy(fault)
  end
  if tonumber(action.commitSeq) ~= tonumber(record.commitSeq) then
    return false, "proposal consensus commit sequence mismatch"
  end
  local existing = consensus.byId[proposalId]
  if existing and existing.status ~= "pending" then
    local same = existing.success == (action.success == true)
      and existing.recoverable == recoverable
      and tostring(existing.resultDigest or "") == tostring(action.resultDigest or "")
      and tostring(existing.coreDigest or "") == tostring(action.coreDigest or "")
    if not same then return false, "conflicting proposal consensus outcome" end
    return existing.success == true or existing.recoverable == true, util.deepCopy(existing)
  end
  local localCompletion = record.completion
  local success = action.success == true
  if requestedRecoverable and success then
    success = false
    action = util.deepCopy(action)
    action.errorCode = "successful-consensus-cannot-be-recoverable"
  end
  if success and (not localCompletion
    or localCompletion.success ~= true
    or tostring(localCompletion.proposalDigest or "") ~= tostring(action.proposalDigest or "")
    or tostring(localCompletion.resultDigest or "") ~= tostring(action.resultDigest or "")
    or tostring(localCompletion.coreDigest or "") ~= tostring(action.coreDigest or "")) then
    success = false
    action = util.deepCopy(action)
    action.errorCode = "local-completion-does-not-match-consensus"
  end
  if recoverable then
    local outputs = localCompletion and localCompletion.outputs
    local transactionDigest = record.transaction and tostring(record.transaction.digest or "") or ""
    if not localCompletion
      or localCompletion.success ~= false
      or type(outputs) ~= "table"
      or next(outputs) ~= nil
      or localCompletion.financeDelta ~= nil
      or transactionDigest == ""
      or transactionDigest ~= tostring(action.proposalDigest or "")
      or tostring(localCompletion.proposalDigest or "") ~= tostring(action.proposalDigest or "")
      or tostring(localCompletion.resultDigest or "") ~= tostring(action.resultDigest or "")
      or tostring(localCompletion.coreDigest or "") ~= tostring(action.coreDigest or "") then
      recoverable = false
      action = util.deepCopy(action)
      action.errorCode = "recoverable-rejection-does-not-match-local-completion"
    end
  end
  local authoritativeFinanceDelta = tonumber(action.financeDelta)
  local localFinanceDelta = localCompletion and tonumber(localCompletion.financeDelta) or nil
  local financeAdjustment = 0
  local canonicalFinanceEntry
  local nativeReconciliation
  if success and (authoritativeFinanceDelta == nil or localFinanceDelta == nil) then
    success = false
    action = util.deepCopy(action)
    action.errorCode = "proposal-finance-consensus-is-unavailable"
  elseif success then
    local applied, entryOrError = finance.applyNetworkDelta(
      state.finance, record.companyCid, authoritativeFinanceDelta, {
        kind = "proposal",
        proposalId = proposalId,
        commitSeq = tonumber(action.commitSeq),
      })
    if not applied then
      success = false
      action = util.deepCopy(action)
      action.errorCode = "proposal-canonical-finance-failed:" .. tostring(entryOrError)
    else
      canonicalFinanceEntry = entryOrError
      local reconciled, reconciliationOrError = finance.reconcileNetworkAccounts(
        state.finance, state.companies, {
          reason = "proposal-consensus",
          proposalId = proposalId,
          commitSeq = tonumber(action.commitSeq),
          tick = state.tick,
        })
      nativeReconciliation = type(reconciliationOrError) == "table"
        and reconciliationOrError or { error = tostring(reconciliationOrError) }
      local targetItem = nativeReconciliation.accounts
        and nativeReconciliation.accounts[record.companyCid] or nil
      financeAdjustment = targetItem and util.integer(targetItem.adjustment, 0)
        or (authoritativeFinanceDelta - localFinanceDelta)
      if not reconciled then
        success = false
        action = util.deepCopy(action)
        action.errorCode = "proposal-native-wallet-reconciliation-failed:"
          .. tostring(nativeReconciliation.error or reconciliationOrError)
      end
    end
  end
  if success then recordProposalInfrastructure(record, authoritativeFinanceDelta) end
  local outcome = {
    proposalId = proposalId,
    commitSeq = tonumber(action.commitSeq),
    success = success,
    recoverable = recoverable,
    status = success and "complete" or recoverable and "rejected" or "faulted",
    proposalDigest = tostring(action.proposalDigest or ""),
    resultDigest = tostring(action.resultDigest or ""),
    coreDigest = tostring(action.coreDigest or ""),
    financeDelta = authoritativeFinanceDelta,
    localFinanceDelta = localFinanceDelta,
    financeAdjustment = financeAdjustment,
    canonicalFinanceEntry = util.deepCopy(canonicalFinanceEntry),
    nativeReconciliation = util.deepCopy(nativeReconciliation),
    peers = util.deepCopy(type(action.peers) == "table" and action.peers or {}),
    errorCode = success and nil or tostring(action.errorCode or "proposal-consensus-failed"),
    tick = state.tick,
  }
  consensus.byId[proposalId] = outcome
  consensus.lastOutcome = util.deepCopy(outcome)
  if success then
    consensus.completed = (consensus.completed or 0) + 1
  elseif recoverable then
    consensus.rejected = (consensus.rejected or 0) + 1
  else
    consensus.failed = (consensus.failed or 0) + 1
    consensus.sessionFault = util.deepCopy(outcome)
  end
  return success or recoverable, util.deepCopy(outcome)
end

handlers["network.checkpoint_outcome"] = function(action)
  if state.networkMode ~= "network" then return false, "checkpoint consensus exists only in network mode" end
  local boundarySeq = math.max(0, util.integer(type(action) == "table" and action.boundarySeq, 0))
  if boundarySeq < 1 then return false, "checkpoint consensus has no valid boundary sequence" end
  local consensus = state.world.checkpointConsensus
  local key = tostring(boundarySeq)
  local record = consensus.byBoundary[key]
  if record and record.status ~= "pending" then
    local same = record.success == (action.success == true)
      and tostring(record.convergenceKey or "") == tostring(action.convergenceKey or "")
    if not same then return false, "conflicting checkpoint consensus outcome" end
    return record.success, util.deepCopy(record)
  end
  local success = action.success == true
  local errorCode = tostring(action.errorCode or "checkpoint-consensus-failed")
  if success and (not record or record.exported ~= true) then
    success = false
    errorCode = "local-checkpoint-is-unavailable"
  elseif success and (tostring(record.convergenceKey or "") ~= tostring(action.convergenceKey or "")
    or tostring(record.coreDigest or "") ~= tostring(action.coreDigest or "")
    or tostring(record.financialDigest or "") ~= tostring(action.financialDigest or "")) then
    success = false
    errorCode = "local-checkpoint-does-not-match-consensus"
  end
  record = record or {
    boundarySeq = boundarySeq,
    reason = tostring(action.reason or "unknown"),
    proposalId = action.proposalId and tostring(action.proposalId) or nil,
    exported = false,
    tick = state.tick,
  }
  record.success = success
  record.status = success and "complete" or "faulted"
  record.convergenceKey = tostring(action.convergenceKey or record.convergenceKey or "")
  record.coreDigest = tostring(action.coreDigest or record.coreDigest or "")
  record.modelDigest = tostring(action.modelDigest or "")
  record.canonicalDigest = tostring(action.canonicalDigest or "")
  record.financialDigest = tostring(action.financialDigest or record.financialDigest or "")
  record.structuralDigest = action.structuralDigest and tostring(action.structuralDigest) or nil
  record.worldManifestDigest = action.worldManifestDigest
    and tostring(action.worldManifestDigest) or nil
  record.peers = util.deepCopy(type(action.peers) == "table" and action.peers or {})
  record.errorCode = success and nil or errorCode
  record.outcomeTick = state.tick
  consensus.byBoundary[key] = record
  consensus.lastOutcome = util.deepCopy(record)
  recoveryPrepareRuntime.checkpointOutcome(action, success, record)
  if success then
    consensus.completed = (consensus.completed or 0) + 1
    consensus.lastAgreed = util.deepCopy(record)
  else
    consensus.failed = (consensus.failed or 0) + 1
    local fault = {
      proposalId = record.proposalId,
      commitSeq = boundarySeq,
      success = false,
      status = "faulted",
      errorCode = errorCode,
      tick = state.tick,
    }
    state.world.proposalConsensus.sessionFault = fault
  end
  return success, util.deepCopy(record)
end

-- A loaded save can contain complete routes with no later line/vehicle operation.
-- Register them after match initialisation; operation-driven registration alone
-- would leave a perfectly valid service invisible to the authored economy. Wait until
-- the initial two-peer checkpoint has converged, then let each owning peer
-- enqueue only its own runnable pre-existing lines.  The normal ordered
-- line.register path still derives and carries the facts; this scan never
-- authors market data independently on both peers.
local serviceRegistrationIntegration = serviceRegistrationIntegrationModule.new({
  getState = function() return state end, getController = function() return networkIntentController end,
  world = world, activeCompany = activeCompany, submitIntent = function(...) return submitIntent(...) end,
  log = diagnosticLog,
})
autoRegisterLineFor = serviceRegistrationIntegration.line
local autoRegisterExistingServices = serviceRegistrationIntegration.existing

authoredFollowupRuntime.installHandlers(handlers, {
  getState = function() return state end; requireRunningMatch = requireRunningMatch;
  world = world; diagnosticLog = diagnosticLog,
})
industryContentRuntime.installHandler(handlers, function() return state end)
freightIndustryRuntime.installHandler(handlers, {
  getState = function() return state end, requireRunningMatch = requireRunningMatch,
  readFacts = world.industryBootstrapFacts,
})
aboardMilestoneIntegration.installHandlers(handlers, { getState = function() return state end,
  requireRunningMatch = requireRunningMatch })
handlers["line.register"] = function(action)
  local running, runningError = requireRunningMatch()
  if not running then return false, runningError end
  local activeCid, _, companyErr = requireCompany()
  local companyCid = action.companyCid or activeCid
  local company = state.companies[companyCid]
  if not company then return false, companyErr or ("unknown company: " .. tostring(companyCid)) end
  local lineId, _, lineErr = lineIdFromAction(action)
  if not lineId then return false, lineErr end
  if action.market and action.service
      and (action.service.companyCid ~= companyCid
        or action.service.lineCid ~= action.lineCid) then
    return false, "authoritative line service identity mismatch"
  end
  local candidate, candidateError = economyLineRegistration.prepare(
    state, world, economy, passengerPresentation, cargoPresentation,
    action, lineId, companyCid)
  if not candidate then return false, candidateError end
  state.economy = candidate.economy
  if candidate.canonical then state.canonical = candidate.canonical end
  state.world.passengerPresentation = candidate.passengerPresentation
  state.world.cargoPresentation = candidate.cargoPresentation
  local result = candidate.result
  pcall(game.interface.setPlayer, lineId, proxyTargetPlayer(companyCid) or company.playerId)
  state.world.logicalOwners[tostring(lineId)] = companyCid
  refreshOwnershipProbe()
  result.owner = companyCid
  return true, result
end
handlers["fare.adjust"] = function(action)
  local running, runningError = requireRunningMatch()
  if not running then return false, runningError end
  local _, lineCid, lineErr = lineIdFromAction(action)
  if not lineCid then return false, lineErr end
  local service = state.economy.services[lineCid]
  if not service then return false, "register the line before setting its fare" end
  local ok, result = economy.setFare(state.economy, lineCid, service.fareCents + util.integer(action.deltaCents, 0))
  return ok, { lineCid = lineCid, fareCents = result }
end
handlers["economy.seed_demo"] = function()
  local running, runningError = requireRunningMatch()
  if not running then return false, runningError end
  return seedDemo()
end

handlers["economy.settle"] = function(action, eventId)
  local running, runningError = requireRunningMatch()
  if not running then return false, runningError end
  local deliverySnapshot, deliveryError = economyActionRuntime.verifiedDelivery(
    state, passengerPresentation, cargoPresentation, action.deliverySnapshot)
  if not deliverySnapshot then return false, deliveryError end
  local candidate, candidateError = economySettlementTransaction.prepare(
    state, economy, passengerPresentation, cargoPresentation,
    freightIndustryRuntime, action, deliverySnapshot)
  if not candidate then return false, candidateError end
  state.economy = candidate.economy
  state.world.freightIndustry = candidate.freightIndustry
  state.world.passengerPresentation = candidate.passengerPresentation
  state.world.cargoPresentation = candidate.cargoPresentation
  local results, freightProduction = candidate.results, candidate.freightSummary
  local payoutDollars = {}
  for _, companyCid in ipairs(util.sortedKeys(results.companies or {})) do
    local companyResult = results.companies[companyCid]
    payoutDollars[companyCid] = economy.walletDeltaDollars(
      state.economy, companyCid,
      companyResult.netRevenueCents ~= nil
        and companyResult.netRevenueCents or companyResult.revenueCents)
  end
  -- Deterministic town growth: identical ordered results on every peer
  -- produce identical native capacity commands; the structural probe
  -- verifies convergence. Fail-soft and recorded, never digest material.
  local grew, growth = pcall(world.applyTownGrowth, state.canonical, state.economy, results)
  state.probes.townGrowth = grew and growth or { errors = { tostring(growth) } }
  -- Carried demand also buys buildings. The host turns accumulated growth
  -- points into an ordered development batch so both peers make identical
  -- native calls; whether the results agree is what the structural digest
  -- measures. Only the host emits, and only when something is actually due.
  world.settleDevelopment(state, results, state.economy, config(),
    function(developmentAction)
      if state.networkMode == "network" and networkIntentController then
        return networkIntentController.scheduleFollowup(developmentAction)
      end
      return submitIntent(developmentAction)
    end,
    function(...) return applyCommitted(...) end)
  -- Credit interest and solvency are part of settling, so capital committed
  -- to a losing corridor eventually costs the match rather than merely
  -- costing money. Deterministic over authored state on every peer.
  if state.networkMode == "network" then
    local solvency, bankruptCid = finance.chargeCreditAndAssessSolvency(
      state.finance, state.companyOrder, state.economy.ledger,
      { reason = "economy-settlement", eventId = eventId }, state.match.rules,
      state.economy.scheduler.epochSeconds)
    state.probes.solvency = solvency
    state.probes.bankruptCid = bankruptCid
  end
  local ok, errors = true, {}
  local nativeReconciliation
  if state.networkMode == "network" then
    state.finance.lastPayouts = {}
    for _, companyCid in ipairs(util.sortedKeys(results.companies or {})) do
      local companyResult = results.companies[companyCid]
      local amount = payoutDollars[companyCid] or 0
      local applied, entryOrError = finance.applyNetworkDelta(state.finance, companyCid, amount, {
        kind = "economy-settlement",
        eventId = eventId,
        epoch = results.epoch,
      })
      state.finance.lastPayouts[companyCid] = {
        amount = amount,
        ok = applied == true,
        canonical = true,
        entry = applied and util.deepCopy(entryOrError) or nil,
        error = applied and nil or tostring(entryOrError),
      }
      if applied then
        state.finance.totalPaid = util.integer(state.finance.totalPaid, 0) + amount
      else
        ok = false
        errors[#errors + 1] = tostring(entryOrError)
      end
    end
    if ok then
      local reconciled, reconciliationOrError = finance.reconcileNetworkAccounts(
        state.finance, state.companies, {
          reason = "economy-settlement",
          eventId = eventId,
          epoch = results.epoch,
          tick = state.tick,
        })
      nativeReconciliation = type(reconciliationOrError) == "table"
        and reconciliationOrError or { error = tostring(reconciliationOrError) }
      if not reconciled then
        ok = false
        errors[#errors + 1] = tostring(nativeReconciliation.error or reconciliationOrError)
      end
    end
  else
    ok, errors = finance.payResults(
      state.finance, state.companies, results, payoutDollars)
  end
  local matchResult = evaluateMatchEnd()
  return ok, {
    results = results,
    payouts = util.deepCopy(state.finance.lastPayouts),
    errors = errors,
    nativeReconciliation = util.deepCopy(nativeReconciliation),
    scoreboard = economy.scoreboard(state.economy, state.companies),
    match = util.deepCopy(state.match),
    matchEnded = matchResult,
    freightProduction = util.deepCopy(freightProduction),
  }
end

handlers["probe.run"] = function()
  state.probes.capabilities = world.capabilityProbe()
  state.probes.nativeHook = nativeHookStatus()
  state.probes.structural = world.structuralSnapshot(state.canonical, state.world, state.companies)
  refreshOwnershipProbe()
  bridge.emit(state.bridge, "telemetry", {
    type = "probe",
    capabilities = state.probes.capabilities,
    structural = state.probes.structural,
    digest = coreDigest(),
  }, state.tick)
  return true, {
    capabilities = util.deepCopy(state.probes.capabilities),
    structuralDigest = state.probes.structural.digest,
    townCount = #(state.probes.structural.towns or {}),
    lineCount = #(state.probes.structural.lines or {}),
    industryCount = state.probes.structural.industryCount,
    vehicleCount = state.probes.structural.vehicleCount,
    depotCount = state.probes.structural.depotCount,
    ownership = util.deepCopy(state.probes.ownership),
  }
end

handlers["probe.gui_capabilities"] = function(action)
  local capabilities = {}
  for key, value in pairs(type(action.capabilities) == "table" and action.capabilities or {}) do
    if type(key) == "string" and (type(value) == "boolean" or type(value) == "string" or type(value) == "number") then
      capabilities[key] = value
    end
  end
  state.probes.guiCapabilities = capabilities
  if type(action.nativeHook) == "table" then state.probes.nativeHook = util.deepCopy(action.nativeHook) end
  local bootstrap = type(action.networkAuthorityBootstrap) == "table"
    and action.networkAuthorityBootstrap or nil
  if state.networkMode == "network" and bootstrap and action.localOnly == true then
    local authorityReady, authorityView = validatedNetworkAuthority(state.probes.nativeHook)
    local gameReady = bootstrap.gameReady == true
    local calendarReady = bootstrap.calendarReady == true
    state.probes.networkAuthority = {
      ready = authorityReady and gameReady and calendarReady,
      mode = "network",
      buildGateEnabled = authorityView.buildGateEnabled,
      commandGateEnabled = authorityView.commandGateEnabled,
      commandVisitors = authorityView.commandVisitors,
      source = "validated-gui-native-bootstrap",
      error = authorityReady and gameReady and calendarReady and nil
        or tostring(bootstrap.error or "GUI native authority bootstrap was incomplete"),
    }
    if authorityReady and gameReady and calendarReady then
      state.world.networkClock.startupPause = {
        requested = true, confirmed = true, source = "validated-gui-native-bootstrap",
        tick = state.tick,
      }
      state.world.networkClock.requestedSpeed = 0
      state.world.networkClock.effectiveSpeed = 0
      state.probes.networkCalendar = {
        frozen = true,
        requested = true,
        speed = 0,
        source = "validated-gui-native-bootstrap",
        tick = state.tick,
      }
      state.lastError = nil
    else
      state.lastError = state.probes.networkAuthority.error
    end
  end
  return true, {
    guiCapabilities = util.deepCopy(state.probes.guiCapabilities),
    nativeHookAvailable = state.probes.nativeHook and state.probes.nativeHook.available == true,
  }
end

local validationConstruction = require "tpf2_mp/validation_construction"
-- Disposable live validation creates the same compound native shapes as
-- player-built depots/stations, plus a topology-free data-driven asset. The
-- GUI state's typed constructionsToAdd vector has no exposed
-- ConstructionEntity constructor in Build 35924, while the shipped engine
-- interface provides build/upgrade/bulldoze helpers. Keep this bridge behind
-- the one-shot validator and select every stock resource server-side; probe
-- actions can never supply an arbitrary filename or parameter table.
handlers["probe.build_construction"] = function(action)
  if not config().autoValidate then
    return false, "probe construction is available only in a disposable validation world"
  end
  if not (game and game.interface and type(game.interface.buildConstruction) == "function"
    and type(game.interface.getHeight) == "function") then
    return false, "engine construction API is unavailable"
  end
  local kind = tostring(type(action) == "table" and action.kind or "")
  local currentYear = validationConstruction.year()
  local spec = validationConstruction.spec(kind, currentYear, false)
  if not spec then return false, "unsupported validation construction kind" end
  local x, y = tonumber(action.x), tonumber(action.y)
  local function finite(value)
    return value ~= nil and value == value and value ~= math.huge and value ~= -math.huge
  end
  if not finite(x) or not finite(y) or math.abs(x) > 100000 or math.abs(y) > 100000 then
    return false, "validation construction coordinates are invalid"
  end
  local heightOk, z = pcall(game.interface.getHeight, { x, y })
  z = tonumber(z)
  if not heightOk or not finite(z) then return false, "terrain height is unavailable" end
  local params = util.deepCopy(spec.params)
  local transform = {
    1, 0, 0, 0,
    0, 1, 0, 0,
    0, 0, 1, 0,
    x, y, z, 1,
  }
  local entity = game.interface.buildConstruction(spec.fileName, params, transform)
  entity = tonumber(entity)
  if not entity or entity < 0 then return false, "construction helper returned no entity" end
  local desk = tonumber(state.world.controlPlayerId)
    or (type(game.interface.getPlayer) == "function" and tonumber(game.interface.getPlayer()) or nil)
  if desk and type(game.interface.setPlayer) == "function" then
    local transferOk, transferError = pcall(game.interface.setPlayer, entity, desk)
    if not transferOk then
      return false, "constructed entity could not be assigned to the turn desk: " .. tostring(transferError)
    end
  end
  diagnosticLog("validation-construction-built", {
    kind = kind,
    localEntityId = entity,
    playerId = desk,
    tick = state.tick,
  })
  return true, { kind = kind, localEntityId = entity, playerId = desk }
end

handlers["probe.mutate_construction"] = function(action)
  if not config().autoValidate then
    return false, "probe construction mutation is available only in a disposable validation world"
  end
  local kind = tostring(type(action) == "table" and action.kind or "")
  local mode = tostring(type(action) == "table" and action.mode or "")
  local entity = tonumber(type(action) == "table" and action.localEntityId or nil)
  if not entity or entity < 0 or entity ~= math.floor(entity) then
    return false, "validation construction entity is invalid"
  end
  if not validationConstruction.spec(kind, validationConstruction.year(), false) then
    return false, "unsupported validation construction kind"
  end
  local interface = game and game.interface or {}
  local returnedEntity = entity
  if mode == "upgrade" then
    if kind ~= "station" then
      return false, "validation upgrade supports only an editable station construction"
    end
    if type(interface.upgradeConstruction) ~= "function" then
      return false, "engine construction upgrade API is unavailable"
    end
    local spec = validationConstruction.spec(kind, validationConstruction.year(), true)
    local codecReplay = type(action) == "table" and action.codecReplay == true
    if codecReplay then
      -- Exercise the same path as a captured GUI station edit, including the
      -- two reserved fields that are present on the prepared proposal but
      -- must not be passed back to upgradeConstruction.
      spec.params.seed = 1
      spec.params.upgrade = true
      local raw = {
        __observedCost = 0,
        __constructionAdditions = {{
          entity = -1,
          fileName = spec.fileName,
          transf = { 1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1 },
          params = spec.params,
        }},
        __constructionRemovals = {{ entity = entity }},
      }
      local transaction, transactionError = proposalCodec.normalise(raw, "company:1", {
        resolveCanonical = function(rootKind, localId)
          if localId == entity and rootKind == "construction" then
            return "construction:validation:station"
          end
        end,
        entityKind = function(localId)
          if localId == entity then return "construction" end
        end,
      })
      if not transaction then
        return false, "validation station edit could not be canonicalised: "
          .. tostring(transactionError)
      end
      local replaySpec, replayError = proposalCodec.materialiseConstruction(transaction)
      if not replaySpec then
        return false, "validation station edit could not be materialised: " .. tostring(replayError)
      end
      if replaySpec.params.seed ~= nil or replaySpec.params.upgrade ~= nil then
        return false, "validation station edit retained reserved upgrade helper fields"
      end
      spec = replaySpec
    end
    local upgraded, value = pcall(interface.upgradeConstruction, entity, spec.fileName, spec.params)
    if not upgraded then return false, "construction upgrade failed: " .. tostring(value) end
    local observed = tonumber(value)
    if observed and observed >= 0 then returnedEntity = observed end
  elseif mode == "remove" then
    if type(interface.bulldoze) ~= "function" then
      return false, "engine construction bulldoze API is unavailable"
    end
    local removed, removeError = pcall(interface.bulldoze, entity)
    if not removed then return false, "construction bulldoze failed: " .. tostring(removeError) end
  else
    return false, "unsupported validation construction mutation mode"
  end
  local desk = tonumber(state.world.controlPlayerId)
    or (type(interface.getPlayer) == "function" and tonumber(interface.getPlayer()) or nil)
  if mode ~= "remove" and desk and type(interface.setPlayer) == "function" then
    local transferOk, transferError = pcall(interface.setPlayer, returnedEntity, desk)
    if not transferOk then
      return false, "mutated construction could not be assigned to the turn desk: "
        .. tostring(transferError)
    end
  end
  diagnosticLog("validation-construction-mutated", {
    kind = kind,
    mode = mode,
    sourceLocalEntityId = entity,
    localEntityId = mode ~= "remove" and returnedEntity or nil,
    playerId = desk,
    codecReplay = type(action) == "table" and action.codecReplay == true,
    tick = state.tick,
  })
  return true, {
    kind = kind,
    mode = mode,
    sourceLocalEntityId = entity,
    localEntityId = mode ~= "remove" and returnedEntity or nil,
    playerId = desk,
    codecReplay = type(action) == "table" and action.codecReplay == true,
  }
end

handlers["probe.mobility"] = function(_, eventId)
  state.probes.nativeHook = nativeHookStatus()
  state.probes.mobility = world.mobilitySnapshot(state.canonical, state.world)
  local payload = util.deepCopy(state.probes.mobility)
  payload.type = "mobility"
  payload.sampleKey = tostring(eventId)
  payload.peerId = state.bridge.peerId
  state.probes.mobility.sampleKey = payload.sampleKey
  state.probes.mobilityHistory = state.probes.mobilityHistory or {}
  local previous = state.probes.mobilityHistory[#state.probes.mobilityHistory]
  if not previous or previous.sampleKey ~= payload.sampleKey then
    state.probes.mobilityHistory[#state.probes.mobilityHistory + 1] = {
      sampleKey = payload.sampleKey,
      mobilityDigest = payload.digest,
      vehicleLifecycleDigest = payload.vehicleLifecycleDigest,
      vehiclePhaseDigest = payload.vehiclePhaseDigest,
      totalPersons = payload.totalPersons,
      lineCount = #(payload.lines or {}),
      totals = util.deepCopy(payload.totals),
      tick = state.tick,
    }
    while #state.probes.mobilityHistory > 8 do table.remove(state.probes.mobilityHistory, 1) end
  end
  local emitted, outbound = bridge.emit(state.bridge, "mobility", payload, state.tick)
  return true, {
    sampleKey = payload.sampleKey,
    mobilityDigest = payload.digest,
    vehicleLifecycleDigest = payload.vehicleLifecycleDigest,
    vehiclePhaseDigest = payload.vehiclePhaseDigest,
    totalPersons = payload.totalPersons,
    lineCount = #(payload.lines or {}),
    totals = util.deepCopy(payload.totals),
    emitted = emitted and true or false,
    bridgeError = emitted and nil or tostring(outbound),
  }
end

-- Refreshes the native structural projection at an ordered boundary. Unlike
-- probe.run this is intentionally not machine-local: delayed engine commands
-- (notably developTown) need a later, shared observation point before their
-- physical result can be trusted by recovery or validation.
handlers["probe.structural"] = function()
  state.probes.structural = world.structuralSnapshot(
    state.canonical, state.world, state.companies)
  return true, {
    digest = state.probes.structural.digest,
    townCount = #(state.probes.structural.towns or {}),
    vehicleCount = state.probes.structural.vehicleCount,
    constructionCount = state.probes.structural.constructionCount,
  }
end

handlers["probe.passenger_cosmetics"] = function()
  return refreshPassengerCosmetics()
end

handlers["probe.export_research"] = function()
  local report = world.researchSnapshot(state.world, state.canonical, state.companies)
  report.tick = state.tick
  report.sessionId = state.bridge.sessionId
  report.peerId = state.bridge.peerId
  report.networkMode = state.networkMode
  report.capture = util.deepCopy(state.probes.capture)
  report.guiCapabilities = util.deepCopy(state.probes.guiCapabilities)
  report.nativeHook = nativeHookStatus()
  report.networkAuthority = util.deepCopy(state.probes.networkAuthority)
  report.networkCalendar = util.deepCopy(state.probes.networkCalendar)
  report.mobility = util.deepCopy(state.probes.mobility)
  report.mobilityHistory = util.deepCopy(state.probes.mobilityHistory)
  report.operational = util.deepCopy(state.probes.operational)
  report.financeTransfers = util.deepCopy(state.finance.transfers)
  report.startingCash = util.deepCopy(state.finance.startingCash)
  report.networkAccounts = util.deepCopy(state.finance.networkAccounts)
  report.validation = util.deepCopy(state.validation)
  report.checkpoint = util.deepCopy(state.checkpoint)
  report.match = util.deepCopy(state.match); report.agentPolicy = util.deepCopy(state.probes.agentPolicy)
  report.modelDigest = authoredDigest(); report.townDevelopment = util.deepCopy(state.probes.townDevelopment)
  report.coreDigest = coreDigest(); report.townDevelopmentQueue = util.deepCopy(state.probes.townDevelopmentQueue)
  report.passengerPresentation = passengerPresentation.digestView(
    state.world.passengerPresentation)
  report.passengerPresentationDigest = hash.value(report.passengerPresentation); report.passengerCosmetics = util.deepCopy(state.probes.passengerCosmetics)
  report.economyPresentation = util.deepCopy(publicSnapshot().economyPresentation); report.serviceRegistration = util.deepCopy(state.probes.serviceRegistration)
  report.freightMilestone = util.deepCopy(state.probes.freightMilestone); report.passengerMilestone = util.deepCopy(state.probes.passengerMilestone)
  report.proposals = {
    queued = state.world.proposals.queued or 0,
    applied = state.world.proposals.applied or 0,
    failed = state.world.proposals.failed or 0,
    retained = util.tableCount(state.world.proposals.byId),
  }
  report.operations = {
    schemaVersion = operationCodec.SCHEMA_VERSION,
    queued = state.world.operations.queued or 0,
    applied = state.world.operations.applied or 0,
    failed = state.world.operations.failed or 0,
    retained = util.tableCount(state.world.operations.byId),
    records = util.deepCopy(state.world.operations.byId),
  }
  report.proposalConsensus = util.deepCopy(state.world.proposalConsensus)
  report.operationConsensus = util.deepCopy(state.world.operationConsensus)
  report.checkpointConsensus = util.deepCopy(state.world.checkpointConsensus)
  report.worldManifest = util.deepCopy(state.probes.worldManifest)
  report.recovery = util.deepCopy(state.recovery)
  report.accounts = {
    source = state.networkMode == "network" and "native-cache-plus-canonical-ledger" or "native",
    canonical = finance.networkDigestView(state.finance),
    control = state.world.controlPlayerId and accountOf(state.world.controlPlayerId) or nil,
    companies = {},
  }
  for _, companyCid in ipairs(state.companyOrder) do
    report.accounts.companies[companyCid] = accountOf(state.companies[companyCid].playerId)
  end
  report.knownLimits = {
    "BuildProposal has a payload-aware pre-mutation gate. Of the twenty-three additional exact visitor gates, fifteen line/portable-vehicle/name/color tags have strict canonical operation codecs. Native SetGameSpeed is now host-ordered; calendar/logo/field/terrain/date/cheat/person-debug categories stay fail-closed for player input.",
    "Proposal schema 5 canonically serializes road/track changes plus named signal/waypoint edge objects, including retained objects across edge replacement, with quoted cost and no machine-local IDs. Schema 7 adds stock rail-station placement and bounded generic named .con/.module payloads for depots, ordinary constructions, ASSET_DEFAULT roots, upgrades, modular station edits, and removal. Both paths use repository names, strict ownership, preflight and physical consensus. Opaque/script callbacks and ambiguous dependency migration fail closed; every peer still requires an identical pinned mod pack.",
    "Construction uses all-peer prepare before native mutation, then two-peer physical completion consensus, ordered success/fault controls, a bounded timeout, and fail-closed dependency gating. A readiness rejection is non-fatal because neither world changed. Match start and each successful physical result are followed by a host-verified checkpoint barrier; in-place native geometry rollback is deliberately not claimed.",
    "Shared-clock v2 projects staggered peer heartbeats to one host time, orders future-time pause/speed rendezvous, corrects bounded overshoot, emits paused heartbeats, and adaptively caps the effective speed from engine/backlog health. Populated localhost is live-proven; two-computer long-pause and slowdown/recovery proof remains.",
    "Assigned canonical trains are held at every native terminal until both peers report the same vehicle, line, stop and sequential leg round, then receive one ordered future-time release. Format-4 checkpoints digest that authority state together with exact model passenger queues/loads. Four populated localhost rounds are live-proven. This does not teleport trains; a different stop index faults closed.",
    "Line/vehicle creation IDs are discovered from the native callback result or an exact before/after component-set delta, then bound to event-derived canonical IDs.",
    "The GUI rejects known mutating actions against rival logical entities. Native visitors now stop selected unsupported line, vehicle, naming, speed, terrain, date, and cheat commands in network mode; unlisted/autonomous categories still require dedicated authority analysis.",
    "Populated local hot-seat validation covers stations, depots, lines, two running trains and real passenger/cargo trips. Canonical network sale/replacement/maintenance and long-running income/expense still require live destructive tests.",
    "Native loan principal is not mirrored; borrowing/repayment is disabled on the turn desk and requires a dedicated competitive credit model.",
    "The desk retains the base game's loan, so unpaused month-boundary interest can contaminate a long proxy turn; pause-on-switch is the supported local-test configuration.",
    "Company starting cash is an explicit, idempotent match-setup grant; it is audited separately and is not a money-conserving operational transfer.",
    "Build 35924 asserts when legacy setPlayer is used directly on BASE_EDGE. Tracked edges therefore use logical ownership and normally stay on the desk; a depot/station transfer may cascade attached edges to their rightful company. Either native holder is valid, rival holders fail closed, and rival builder proposals are vetoed before commit.",
    "Autonomous town/industry evolution is not yet a complete host-driven replicated event system; unsupported subsystems must remain frozen for network experiments.",
    "Native person and cargo entity IDs are intentionally local scenery. Direct SIM_* component telemetry is retained, while the synchronized passenger ledger and authored stock-UI projection—not native agents—are authoritative for station queues, train loads, revenue, and score.",
    "Debug_SetSimPersonState carries only an eight-byte person-id/boolean payload and cannot address a train or station. Native cosmetic writes therefore fail closed with zero commands issued; misleading stock load, station-board, finance-history, and transported widgets are hidden or relabelled while exact authored replacements are inserted into their standard windows. Cargo presentation remains telemetry-only and its stock total is suppressed.",
  }
  local ok, outbound = bridge.emit(state.bridge, "research", report, state.tick)
  local researchError
  if not ok then researchError = tostring(outbound) end
  state.probes.lastResearch = {
    ok = ok,
    localSeq = ok and outbound.local_seq or nil,
    error = researchError,
    structuralDigest = report.structural and report.structural.digest or nil,
  }
  return ok, util.deepCopy(state.probes.lastResearch)
end

handlers["finance.toggle_neutralizer"] = function(action)
  local enabled = action.enabled
  if enabled == nil then enabled = not state.finance.neutralizer.enabled end
  if enabled and state.world.proxyMode then
    return false, "the native-income neutralizer is legacy-only because it cannot distinguish proxy mirror entries"
  end
  state.finance.neutralizer.enabled = enabled and true or false
  state.finance.neutralizer.lastTimeMs = nil
  return true, util.deepCopy(state.finance.neutralizer)
end


handlers["clock.set"] = function(action)
  return networkClock.apply(action)
end

handlers["clock.rendezvous"] = function(action)
  return networkClock.arm(action)
end

handlers["vehicle.sync_release"] = function(action)
  local ok, result = vehicleSync.applyRelease(action)
  if ok then aboardMilestoneIntegration.observeRelease(state, action, networkIntentController, diagnosticLog) end
  return ok, result
end

handlers["network.sync_fault"] = function(action)
  if state.networkMode ~= "network" then return false, "synchronization faults are network-only" end
  local fault = {
    success = false,
    status = "faulted",
    scope = tostring(action and action.scope or "synchronization"),
    errorCode = tostring(action and action.errorCode or "synchronization-fault"),
    tick = state.tick,
  }
  state.world.operationConsensus.sessionFault = util.deepCopy(fault)
  state.world.operationConsensus.lastOutcome = util.deepCopy(fault)
  state.world.operationConsensus.failed = (state.world.operationConsensus.failed or 0) + 1
  state.lastError = "network synchronization fault: " .. fault.errorCode
  return true, fault
end

handlers["native.build_gate"] = function(action)
  local enabled = action.enabled == true
  if state.networkMode == "network" and not enabled then
    return false, "the BuildProposal gate is mandatory in network mode"
  end
  local functionName = enabled and "tpf2mp_native_enable_build_gate" or "tpf2mp_native_disable_build_gate"
  local nativeFunction = rawget(_G, functionName)
  if type(nativeFunction) ~= "function" then return false, functionName .. " is unavailable" end
  local ok, err = pcall(nativeFunction)
  if not ok then return false, tostring(err) end
  state.probes.nativeHook = nativeHookStatus()
  return true, {
    enabled = enabled,
    warning = enabled and "local BuildProposal commands are now rejected unless one-shot authorized" or nil,
    nativeHook = util.deepCopy(state.probes.nativeHook),
  }
end

handlers["native.build_authorize"] = function()
  if state.networkMode == "network" then
    return false, "manual BuildProposal authorization is disabled in network mode"
  end
  local nativeFunction = rawget(_G, "tpf2mp_native_authorize_build")
  if type(nativeFunction) ~= "function" then return false, "tpf2mp_native_authorize_build is unavailable" end
  local ok, err = pcall(nativeFunction)
  if not ok then return false, tostring(err) end
  state.probes.nativeHook = nativeHookStatus()
  return true, {
    authorized = true,
    warning = "exactly one subsequent BuildProposal visitor call may pass while the gate is enabled",
    nativeHook = util.deepCopy(state.probes.nativeHook),
  }
end

handlers["native.command_gate"] = function(action)
  local enabled = action.enabled == true
  if state.networkMode == "network" and not enabled then
    return false, "the consequential-command visitor gate is mandatory in network mode"
  end
  local functionName = enabled and "tpf2mp_native_enable_command_gate"
    or "tpf2mp_native_disable_command_gate"
  local nativeFunction = rawget(_G, functionName)
  if type(nativeFunction) ~= "function" then return false, functionName .. " is unavailable" end
  local ok, err = pcall(nativeFunction)
  if not ok then return false, tostring(err) end
  state.probes.nativeHook = nativeHookStatus()
  local commandGate = state.probes.nativeHook.gates
    and state.probes.nativeHook.gates.commandVisitors or {}
  return true, {
    enabled = enabled,
    visitors = tonumber(commandGate.hooked) or 0,
    warning = enabled and "selected unsupported commands now require one-shot authorization" or nil,
  }
end

handlers["native.command_authorize"] = function(action)
  if state.networkMode == "network" then
    return false, "manual consequential-command authorization is disabled in network mode"
  end
  local tag = util.integer(action.tag, -1)
  local gatedTags = {
    [0] = true, [1] = true, [2] = true, [3] = true, [4] = true, [5] = true,
    [6] = true, [7] = true, [8] = true, [9] = true, [10] = true, [11] = true,
    [12] = true, [13] = true, [14] = true, [16] = true, [25] = true,
    [26] = true, [28] = true, [29] = true, [30] = true, [33] = true, [36] = true,
  }
  if not gatedTags[tag] then return false, "command tag is not covered by the authority visitor gate" end
  local nativeFunction = rawget(_G, "tpf2mp_native_authorize_command")
  if type(nativeFunction) ~= "function" then
    return false, "tpf2mp_native_authorize_command is unavailable"
  end
  local ok, err = pcall(nativeFunction, tag)
  if not ok then return false, tostring(err) end
  state.probes.nativeHook = nativeHookStatus()
  return true, {
    tag = tag,
    authorized = true,
    warning = "one matching command visitor may pass while the gate is enabled",
  }
end

handlers["network.set_mode"] = function(action)
  local mode = action.mode == "network" and "network" or "standalone"
  if state.initialized and mode ~= state.networkMode then
    return false, "network mode cannot change after match initialisation"
  end
  local ready, authorityError = configureNativeAuthority(mode)
  if not ready then return false, authorityError end
  state.networkMode = mode
  state.probes.nativeHook = nativeHookStatus()
  local commandGate = state.probes.nativeHook.gates
    and state.probes.nativeHook.gates.commandVisitors or {}
  return true, {
    mode = mode,
    bridgeRoot = state.bridge.root,
    session = state.bridge.sessionId,
    peer = state.bridge.peerId,
    buildGateEnabled = state.probes.nativeHook.gates
      and state.probes.nativeHook.gates.buildProposal
      and state.probes.nativeHook.gates.buildProposal.enabled == true or false,
    commandGateEnabled = commandGate.enabled == true,
    commandVisitors = tonumber(commandGate.hooked) or 0,
  }
end

handlers["snapshot.export"] = function()
  local snapshot = publicSnapshot()
  local ok, result = bridge.emit(state.bridge, "snapshot", snapshot, state.tick)
  return ok, result or state.bridge.lastError
end

handlers["checkpoint.export"] = function(action)
  return recoveryPrepareRuntime.manualCheckpoint(action)
end
handlers["recovery.prepare"], handlers["network.checkpoint_request"], handlers["recovery.resume"] =
  recoveryPrepareRuntime.prepare, recoveryPrepareRuntime.checkpointRequest, restoreResumeRuntime.apply

handlers["native.observed"] = function(action, eventId)
  local capture = state.probes.capture
  local proposalSnapshot = action.proposalSnapshot
  local edgeReplacementObservation = action.edgeReplacementObservation
  local accessDecision = action.accessDecision
  local isNativeCommand = tostring(action.observation or ""):find(
    "native.sendCommand.", 1, true) == 1
  if isNativeCommand then
    local origin = tostring(action.commandOrigin or "unmarked-player-or-engine")
    capture.nativeCommandCount = (capture.nativeCommandCount or 0) + 1
    capture.nativeCommandOrigins = capture.nativeCommandOrigins or {}
    capture.nativeCommandOrigins[origin] = (capture.nativeCommandOrigins[origin] or 0) + 1
    local commandRecord = {
      sequence = capture.nativeCommandCount,
      tick = state.tick,
      companyCid = action.companyCid,
      origin = origin,
      observation = action.observation,
      digest = action.commandDigest or hash.value(action.eventShape or {}),
      envelope = util.deepCopy(action.eventShape),
    }
    capture.nativeCommandHistory = capture.nativeCommandHistory or {}
    capture.nativeCommandHistory[#capture.nativeCommandHistory + 1] = util.deepCopy(commandRecord)
    while #capture.nativeCommandHistory > 64 do table.remove(capture.nativeCommandHistory, 1) end
    if config().operationalCapture then
      bridge.emit(state.bridge, "operational-command", commandRecord, state.tick)
    end
  end
  if action.observation == "gui.operationalAction" then
    local record = {
      sequence = (capture.operationalGuiCount or 0) + 1,
      tick = state.tick,
      companyCid = action.companyCid,
      sourceId = action.sourceId,
      eventName = action.eventName,
      digest = action.commandDigest or hash.value(action.eventShape or {}),
      entityIds = util.deepCopy(action.observedEntityIds or {}),
      envelope = util.deepCopy(action.eventShape),
    }
    capture.operationalGuiCount = record.sequence
    capture.operationalGuiHistory = capture.operationalGuiHistory or {}
    capture.operationalGuiHistory[#capture.operationalGuiHistory + 1] = util.deepCopy(record)
    while #capture.operationalGuiHistory > 64 do table.remove(capture.operationalGuiHistory, 1) end
    if config().operationalCapture then
      bridge.emit(state.bridge, "operational-gui", record, state.tick)
    end
    -- Local IDs and reverse-engineering envelopes stay in the bounded local
    -- capture/bridge records, not the persistent canonical event action.
    action.observedEntityIds = nil
    action.eventShape = nil
    return true, { observed = true, sequence = record.sequence, digest = record.digest }
  end
  action.proposalSnapshot = nil -- keep the bounded RE payload out of the persistent event/audit tail
  action.edgeReplacementObservation = nil -- machine-local IDs stay in the bounded replacement audit only
  action.accessDecision = nil -- access evidence also contains machine-local IDs
  if proposalSnapshot then
    local snapshotRecord = {
      tick = state.tick,
      sourceId = action.sourceId,
      observation = action.observation,
      snapshot = util.deepCopy(proposalSnapshot),
    }
    capture.lastProposalSnapshot = snapshotRecord
    capture.proposalSnapshots = capture.proposalSnapshots or {}
    capture.proposalSnapshots[#capture.proposalSnapshots + 1] = util.deepCopy(snapshotRecord)
    while #capture.proposalSnapshots > 8 do table.remove(capture.proposalSnapshots, 1) end
  end
  capture.lastNativeEvent = util.deepCopy(action)
  if action.observation == "builder.proposalCreate" then capture.preCommitCount = (capture.preCommitCount or 0) + 1 end
  if action.observation == "native.sendCommand.buildProposal" then
    capture.nativePreCommitCount = (capture.nativePreCommitCount or 0) + 1
  end
  if action.observation == "builder.apply" then capture.postCommitCount = (capture.postCommitCount or 0) + 1 end
  if action.observation == "builder.proposalDenied" then
    capture.accessDeniedCount = (capture.accessDeniedCount or 0) + 1
    capture.lastAccessDenial = {
      tick = state.tick,
      sourceId = action.sourceId,
      companyCid = action.companyCid,
      decision = util.deepCopy(accessDecision),
    }
  end
  if action.observation == "entity.accessDenied" then
    capture.entityAccessDeniedCount = (capture.entityAccessDeniedCount or 0) + 1
  end
  if action.observation == "vehicle.accept" then capture.vehicleIntentCount = (capture.vehicleIntentCount or 0) + 1 end
  if action.observation == "vehicle.resolve" then capture.vehicleResolvedCount = (capture.vehicleResolvedCount or 0) + 1 end
  if action.eventShape then
    capture.eventShapes = capture.eventShapes or {}
    capture.eventShapes[#capture.eventShapes + 1] = {
      tick = state.tick,
      observation = action.observation,
      sourceId = action.sourceId,
      shape = util.deepCopy(action.eventShape),
    }
    while #capture.eventShapes > 24 do table.remove(capture.eventShapes, 1) end
  end

  local replacementMigration = nil
  if action.observation == "builder.apply" and state.world.proxyMode
    and type(edgeReplacementObservation) == "table" then
    replacementMigration = world.rebindEdgeReplacements(
      state.world, state.canonical, edgeReplacementObservation, state.world.controlPlayerId
    )
    if (tonumber(edgeReplacementObservation.sourceCount) or 0) > 0 then
      capture.replacementObservedCount = (capture.replacementObservedCount or 0) + 1
      capture.replacementReboundCount = (capture.replacementReboundCount or 0)
        + #(replacementMigration.rebound or {})
      if #(replacementMigration.failed or {}) > 0 then
        capture.replacementFailureCount = (capture.replacementFailureCount or 0) + 1
      end
      local record = {
        tick = state.tick,
        sourceId = action.sourceId,
        companyCid = action.companyCid,
        observation = util.deepCopy(edgeReplacementObservation),
        migration = util.deepCopy(replacementMigration),
      }
      capture.lastReplacement = record
      capture.replacementHistory = capture.replacementHistory or {}
      capture.replacementHistory[#capture.replacementHistory + 1] = util.deepCopy(record)
      while #capture.replacementHistory > 8 do table.remove(capture.replacementHistory, 1) end
    end
    if #(replacementMigration.failed or {}) > 0 then
      state.world.edgeReplacementFailure = {
        tick = state.tick,
        sourceId = action.sourceId,
        companyCid = action.companyCid,
        migration = util.deepCopy(replacementMigration),
      }
      refreshOwnershipProbe()
      return false, {
        error = "tracked edge replacement could not be mapped atomically",
        edgeReplacement = replacementMigration,
        proxyDeferredFinance = true,
      }
    end
  end

  if state.networkMode == "standalone" then
    local activeCid, active = activeCompany()
    local companyCid = action.companyCid and state.companies[action.companyCid] and action.companyCid or activeCid
    local company = state.companies[companyCid] or active
    if company then
      local targetPlayerId = proxyTargetPlayer(companyCid) or company.playerId
      local claimed = world.claimEntities(state.canonical, action.ids or {}, targetPlayerId, eventId, {
        logicalOwnerCid = companyCid,
        worldState = state.world,
      })
      capture.claimedByKind = capture.claimedByKind or {}
      for _, value in ipairs(claimed.claimed) do
        capture.claimedCount = (capture.claimedCount or 0) + 1
        capture.claimedByKind[value.kind] = (capture.claimedByKind[value.kind] or 0) + 1
      end

      local transferOk, transfer = true, nil
      if not state.world.proxyMode then
        local nativeDelta
        local source
        if action.cost ~= nil then
          nativeDelta = -util.integer(action.cost, 0)
          source = "proposal-cost"
        elseif tonumber(action.balanceBefore) and tonumber(action.balanceAfter) then
          nativeDelta = util.integer(tonumber(action.balanceAfter) - tonumber(action.balanceBefore), 0)
          source = "observed-balance-delta"
        end
        if nativeDelta and nativeDelta ~= 0 then
          transferOk, transfer = finance.transferNativeDelta(
            state.finance,
            game.interface.getPlayer(),
            company.playerId,
            nativeDelta,
            {
              source = source,
              observation = action.observation,
              captureId = action.captureId,
              companyCid = companyCid,
              confidence = source == "proposal-cost" and "exact-event-field" or "transaction-window",
            }
          )
        end
      end
      if #claimed.claimed > 0 or action.observation ~= "builder.proposalCreate" then refreshOwnershipProbe() end
      return #claimed.failed == 0 and transferOk, {
        companyCid = companyCid,
        ownership = claimed,
        edgeReplacement = replacementMigration,
        financeTransfer = transfer,
        proxyDeferredFinance = state.world.proxyMode == true,
      }
    end
  end
  bridge.emit(state.bridge, "telemetry", {
    type = "native-observation",
    observation = action.observation,
    ids = action.ids or {},
    captureId = action.captureId,
    eventShape = action.eventShape,
    note = "local GUI observation only; not serialized or safe command replication",
  }, state.tick)
  return true, { observed = action.observation, claimed = false, networkGate = state.networkMode == "network" }
end

local function normaliseOperationCapture(action)
  local companyCid, company, companyError = requireCompany()
  if not company then return nil, companyError end
  if action.companyCid and action.companyCid ~= companyCid then
    return nil, "operation capture company does not match this peer's assigned company"
  end
  local capture = type(action.capture) == "table" and action.capture or action
  local kind = tostring(capture.kind or "")
  local originApplied = capture.originApplied == true
  local data
  local function bindLocal(localId, expectedKind)
    localId = tonumber(localId)
    if not localId then return nil, "operation capture is missing a local " .. expectedKind end
    local actualKind = world.kindOf(localId)
    if expectedKind ~= "entity" and actualKind ~= expectedKind then
      return nil, "selected object is " .. tostring(actualKind) .. ", expected " .. expectedKind
    end
    local cid, bindError = world.bindExisting(state.canonical, localId, actualKind)
    if not cid then return nil, bindError end
    local binding = state.canonical.byCanonical[cid]
    if state.networkMode == "network" and cid:find(":pre:", 1, true)
      and not (binding and binding.metadata and binding.metadata.manifestBound == true) then
      return nil, "selected pre-existing object is ambiguous across peers"
    end
    -- Must stay a superset of commit-time operationAccess: with vanilla
    -- pass-through the native world has already mutated, so anything the
    -- ordered commit would reject must already be rejected here.
    local owner = world.logicalOwnerOf(state.world, state.companies, localId)
      or (binding and binding.metadata and binding.metadata.owner or nil)
    if owner and owner ~= companyCid then
      return nil, "operation cannot mutate rival-owned "
        .. tostring(expectedKind) .. " " .. tostring(cid)
    end
    return cid
  end
  if kind == "line.create" or kind == "line.update" then
    local encodedStops = {}
    if type(capture.stops) == "table" then
      for index, stop in ipairs(capture.stops) do
        if type(stop) ~= "table" then
          return nil, "captured line stop " .. tostring(index) .. " is invalid"
        end
        local localId = stop.stationGroupLocalId or stop.stationGroup
          or stop.stationGroupId or stop.entity
        local groupId, groupError = world.stationGroupFor(localId)
        if not groupId then return nil, groupError end
        local cid, cidError = bindLocal(groupId, "station_group")
        if not cid then return nil, cidError end
        encodedStops[#encodedStops + 1] = {
          stationGroupCid = cid,
          station = util.clamp(util.integer(stop.station, 0), 0, 4095),
          terminal = util.clamp(util.integer(stop.terminal, 0), 0, 4095),
          alternativeTerminals = util.deepCopy(stop.alternativeTerminals or {}),
        }
      end
    else
      for _, localId in ipairs(capture.stationGroupLocalIds or {}) do
        local groupId, groupError = world.stationGroupFor(localId)
        if not groupId then return nil, groupError end
        local cid, cidError = bindLocal(groupId, "station_group")
        if not cid then return nil, cidError end
        encodedStops[#encodedStops + 1] = {
          stationGroupCid = cid, station = 0, terminal = 0, alternativeTerminals = {},
        }
      end
    end
    local line = { stops = encodedStops }
    if kind == "line.create" then
      if originApplied then
        local outputLocalId = tonumber(capture.originLocalId)
        if not outputLocalId or not world.entityExists(outputLocalId)
          or world.kindOf(outputLocalId) ~= "line" then
          return nil, "vanilla New Line completed without one identifiable local line output"
        end
      end
      local companyIndex = tonumber(companyCid:match("(%d+)$")) or 1
      local colors = {
        { r = 950, g = 250, b = 100 }, { r = 80, g = 420, b = 1000 },
        { r = 100, g = 800, b = 360 }, { r = 900, g = 160, b = 700 },
      }
      local fallbackName = "MP " .. tostring(company.name or companyCid)
        .. " Line " .. tostring((state.world.operations.queued or 0) + 1)
      local capturedName = tostring(capture.name or "")
      data = {
        name = capturedName ~= "" and capturedName or fallbackName,
        color = util.deepCopy(type(capture.color) == "table" and capture.color
          or colors[((companyIndex - 1) % #colors) + 1]),
        line = line,
      }
    else
      local targetCid, targetError = bindLocal(capture.targetLocalId, "line")
      if not targetCid then return nil, targetError end
      data = { targetCid = targetCid, line = line }
    end
  elseif kind == "vehicle.buy" then
    local expectedNativePlayer = proxyTargetPlayer(companyCid) or company.playerId
    if capture.nativePlayerId ~= nil
      and tonumber(capture.nativePlayerId) ~= tonumber(expectedNativePlayer) then
      return nil, "native BuyVehicle player does not match this peer's assigned company"
    end
    local depotCid, depotError = bindLocal(capture.depotLocalId, "depot")
    if not depotCid then return nil, depotError end
    local names, namesError = operationCodec.vehicleModelNames(capture.modelNames or capture.vehicleConfig); if not names then return nil, namesError end
    local config, configError = operationCodec.defaultVehicleConfig(names, api)
    if not config then return nil, configError end
    data = { depotCid = depotCid, config = config }
  elseif kind == "vehicle.replace" then
    local targetCid, targetError = bindLocal(capture.targetLocalId, "vehicle")
    if not targetCid then return nil, targetError end
    local names, namesError = operationCodec.vehicleModelNames(capture.modelNames or capture.vehicleConfig); if not names then return nil, namesError end
    local config, configError = operationCodec.defaultVehicleConfig(names, api)
    if not config then return nil, configError end
    data = { targetCid = targetCid, config = config }
  elseif kind == "vehicle.assign" then
    local targetCid, targetError = bindLocal(capture.targetLocalId, "vehicle")
    if not targetCid then return nil, targetError end
    local lineCid, lineError = bindLocal(capture.lineLocalId, "line")
    if not lineCid then return nil, lineError end
    data = { targetCid = targetCid, lineCid = lineCid, stopIndex = util.integer(capture.stopIndex, 0) }
  elseif kind == "line.delete" then
    local targetCid, targetError
    if originApplied then
      local targetLocalId = tonumber(capture.targetLocalId or capture.originLocalId)
      targetCid = targetLocalId
        and canonical.resolveCanonical(state.canonical, "line", targetLocalId) or nil
      if not targetCid then
        targetError = "vanilla Delete Line target has no canonical local binding"
      else
        local binding = state.canonical.byCanonical[targetCid]
        local owner = world.logicalOwnerOf(state.world, state.companies, targetLocalId)
          or (binding and binding.metadata and binding.metadata.owner or nil)
        if state.networkMode == "network" and targetCid:find(":pre:", 1, true)
          and not (binding and binding.metadata and binding.metadata.manifestBound == true) then
          targetCid = nil
          targetError = "selected pre-existing line is ambiguous across peers"
        elseif owner and owner ~= companyCid then
          targetCid = nil
          targetError = "operation cannot mutate a rival-owned line"
        end
      end
    else
      targetCid, targetError = bindLocal(capture.targetLocalId, "line")
    end
    if not targetCid then return nil, targetError end
    data = { targetCid = targetCid }
  elseif kind == "vehicle.stop" then
    local targetCid, targetError = bindLocal(capture.targetLocalId, "vehicle")
    if not targetCid then return nil, targetError end
    data = { targetCid = targetCid, stopped = capture.stopped == true }
  elseif kind == "vehicle.send_to_depot" then
    local targetCid, targetError = bindLocal(capture.targetLocalId, "vehicle")
    if not targetCid then return nil, targetError end
    data = { targetCid = targetCid, sellOnArrival = capture.sellOnArrival == true }
  elseif kind == "vehicle.maintenance" then
    local targetCid, targetError = bindLocal(capture.targetLocalId, "vehicle")
    if not targetCid then return nil, targetError end
    data = { targetCid = targetCid,
      valueBasisPoints = util.clamp(util.integer(capture.valueBasisPoints, 5000), 0, 10000) }
  elseif kind == "entity.name" then
    local targetCid, targetError = bindLocal(capture.targetLocalId, "entity")
    if not targetCid then return nil, targetError end
    data = { targetCid = targetCid, name = tostring(capture.name or "Multiplayer asset") }
  elseif kind == "entity.color" then
    local targetCid, targetError = bindLocal(capture.targetLocalId, "entity")
    if not targetCid then return nil, targetError end
    data = { targetCid = targetCid, color = util.deepCopy(capture.color or { r = 950, g = 250, b = 100 }) }
  elseif kind == "vehicle.manual_departure" then
    local targetCid, targetError = bindLocal(capture.targetLocalId, "vehicle")
    if not targetCid then return nil, targetError end
    data = { targetCid = targetCid, manual = capture.manual == true }
  elseif kind == "vehicle.reverse" or kind == "vehicle.sell" or kind == "vehicle.depart" then
    local targetCid, targetError = bindLocal(capture.targetLocalId, "vehicle")
    if not targetCid then return nil, targetError end
    data = { targetCid = targetCid }
  else return nil, "unsupported multiplayer operation capture: " .. kind end
  local transaction, transactionError = operationCodec.make(kind, companyCid, data)
  if not transaction then return nil, transactionError end
  local originCaptureToken
  if originApplied then
    local localId = tonumber(capture.originLocalId or capture.targetLocalId)
    if not localId then return nil, "optimistic vanilla operation is missing its local entity" end
    -- Evicting an entry would discard custody of a mutation this world has
    -- already applied. Refuse instead: the caller converts an origin-applied
    -- rejection into the fail-closed residue fault.
    if util.tableCount(proposalPreparation.originAppliedOperations) >= 64 then
      return nil, "optimistic origin custody table is full"
    end
    -- The token counter and a custody marker live in saved state so they
    -- survive script.load; the full record stays machine-local. Monotonic
    -- tokens across reloads keep a stale ordered commit from consuming a
    -- fresh capture's registry entry.
    state.world.originResidueNextToken = math.max(1,
      util.integer(state.world.originResidueNextToken, 1))
    local sequence = state.world.originResidueNextToken
    state.world.originResidueNextToken = sequence + 1
    proposalPreparation.nextOriginToken = state.world.originResidueNextToken
    originCaptureToken = tostring(state.bridge.peerId) .. ":operation-origin:" .. tostring(sequence)
    proposalPreparation.originAppliedOperations[originCaptureToken] = {
      sequence = sequence,
      localId = localId,
      kind = kind,
      companyCid = companyCid,
      transactionId = transaction.transactionId,
      capturedTick = state.tick,
    }
    state.world.originResidueCustody = state.world.originResidueCustody or {}
    state.world.originResidueCustody[originCaptureToken] = {
      kind = kind,
      capturedTick = state.tick,
    }
  end
  state.probes.capture.operationCaptureCount =
    (state.probes.capture.operationCaptureCount or 0) + 1
  state.probes.capture.lastCanonicalOperation = {
    tick = state.tick,
    kind = kind,
    companyCid = companyCid,
    transactionId = transaction.transactionId,
    digest = transaction.digest,
  }
  return {
    type = "operation.execute",
    transaction = transaction,
    originCaptureToken = originCaptureToken,
  }
end

local function normaliseForNetwork(action)
  local copy = util.deepCopy(action)
  copy.localOnly = nil
  if copy.type == "proposal.capture" then
    local companyCid = activeCompany()
    if not companyCid or copy.companyCid ~= companyCid then
      return nil, "proposal capture company does not match this peer's assigned company"
    end
    local transaction, proposalError = proposalCodec.normalise(copy.proposalSnapshot, companyCid, {
      resolveCanonical = proposalResolveCanonical,
      resourceName = proposalResourceName,
      entityPosition = proposalEntityPosition,
      entityKind = world.kindOf,
      requireResourceName = true,
    })
    if not transaction then
      local capture = state.probes.capture
      local failure = {
        tick = state.tick,
        companyCid = companyCid,
        error = tostring(proposalError),
        snapshotDigest = hash.value(copy.proposalSnapshot),
        diagnostic = proposalCodec.diagnose(copy.proposalSnapshot),
      }
      capture.proposalCodecFailureCount = (capture.proposalCodecFailureCount or 0) + 1
      capture.lastProposalCodecFailure = util.deepCopy(failure)
      capture.proposalCodecFailures = capture.proposalCodecFailures or {}
      capture.proposalCodecFailures[#capture.proposalCodecFailures + 1] = util.deepCopy(failure)
      while #capture.proposalCodecFailures > 16 do table.remove(capture.proposalCodecFailures, 1) end
      diagnosticLog("proposal-codec-failure", failure)
      bridge.emit(state.bridge, "telemetry", {
        type = "proposal-codec-failure",
        error = failure.error,
        companyCid = failure.companyCid,
        snapshotDigest = failure.snapshotDigest,
        diagnostic = util.deepCopy(failure.diagnostic),
      }, state.tick)
      return nil, proposalError
    end
    state.probes.capture.proposalCaptureCount = (state.probes.capture.proposalCaptureCount or 0) + 1
    state.probes.capture.lastCanonicalProposal = {
      tick = state.tick,
      digest = transaction.digest,
      transactionId = transaction.transactionId,
      companyCid = transaction.companyCid,
      nodeCount = #transaction.nodes,
      edgeCount = #transaction.edges,
      removalCount = #transaction.remove.nodes + #transaction.remove.edges,
    }
    copy = { type = "proposal.prepare", transaction = transaction }
  elseif copy.type == "proposal.prepare" or copy.type == "proposal.build" then
    local valid, proposalError = proposalCodec.validatePortable(copy.transaction)
    if not valid then return nil, proposalError end
  elseif copy.type == "clock.request" then
    local requestedSpeed = util.integer(copy.requestedSpeed, -1)
    if requestedSpeed < 0 or requestedSpeed > 4 then
      return nil, "clock.request requires a speed from 0 through 4"
    end
    copy = { type = "clock.request", requestedSpeed = requestedSpeed }
  elseif copy.type == "recovery.prepare" then
    for key in pairs(copy) do
      if key ~= "type" then return nil, "recovery.prepare has an unknown field: " .. tostring(key) end
    end
    copy = { type = "recovery.prepare" }
  elseif copy.type == "recovery.resume" then
    local restoreError; copy, restoreError = restoreResumeRuntime.normalise(copy)
    if not copy then return nil, restoreError end
  elseif copy.type == "content.industry_attest" then
    local contentError; copy, contentError = industryContentRuntime.normaliseAction(
      copy, state.bridge.peerId)
    if not copy then return nil, contentError end
  elseif copy.type == "freight.industry_bootstrap" then
    local bootstrapError; copy, bootstrapError = freightIndustryRuntime.normaliseIntent(
      state, state.bridge.peerId, world.industryBootstrapFacts)
    if not copy then return nil, bootstrapError end
  elseif copy.type == "freight.milestone" or copy.type == "passenger.milestone" then
    local milestoneError; copy, milestoneError = aboardMilestoneIntegration.normaliseIntent(state, copy)
    if not copy then return nil, milestoneError end
  elseif copy.type == "network.checkpoint_request" then
    local preparationSeq = util.integer(copy.preparationSeq, 0)
    if preparationSeq < 1 or tostring(copy.reason or "") ~= "recovery-prepare:" .. tostring(preparationSeq) then
      return nil, "network checkpoint request is malformed"
    end
    copy = { type = "network.checkpoint_request", preparationSeq = preparationSeq,
      reason = "recovery-prepare:" .. tostring(preparationSeq) }
  elseif copy.type == "operation.execute" then
    local valid, operationError = operationCodec.validate(copy.transaction)
    if not valid then return nil, operationError end
    if copy.originCaptureToken ~= nil
      and (type(copy.originCaptureToken) ~= "string" or #copy.originCaptureToken > 160
        or (not copy.originCaptureToken:match("^[%w_.%-]+:line%-origin:%d+$")
          and not copy.originCaptureToken:match("^[%w_.%-]+:operation%-origin:%d+$"))) then
      return nil, "operation has an invalid optimistic-origin token"
    end
  end
  if (copy.type == "line.register" or copy.type == "fare.adjust") and copy.localLineId and not copy.lineCid then
    local cid, err = world.bindExisting(state.canonical, tonumber(copy.localLineId), "line")
    if not cid then return nil, err end
    copy.lineCid = cid
    copy.localLineId = nil
  end
  if copy.type == "match.initialise" then
    if state.bridge.peerId ~= "player1" then return nil, "only the host peer can initialise the match" end
    copy.rules = normaliseMatchRules(copy.rules)
  elseif copy.type == "match.finish" then
    if state.bridge.peerId ~= "player1" then return nil, "only the host peer can finish the match" end
    local winnerCid = rankedWinner()
    copy.winnerCid = copy.winnerCid or winnerCid
    copy.reason = tostring(copy.reason or "manual-host")
  elseif copy.type == "line.register" then
    local companyCid, company, companyError = requireCompany()
    if not company then return nil, companyError end
    local lineId = canonical.resolveLocal(state.canonical, copy.lineCid)
    if not lineId then return nil, "canonical line has no local host binding" end
    copy, companyError = economyActionRuntime.lineRegistration(state, world, economy, copy.lineCid, lineId, companyCid)
    if not copy then return nil, companyError end
  elseif copy.type == "operation.execute" then
    local companyCid, company, companyError = requireCompany()
    if not company then return nil, companyError end
    if copy.transaction.companyCid ~= companyCid then
      return nil, "canonical operation company does not match this peer's assigned company"
    end
  elseif copy.type == "economy.settle" then
    if state.bridge.peerId ~= "player1" then return nil, "only the host peer can settle the authoritative economy" end
    local scheduled = copy.scheduled == true
    if not scheduled and not config().developerEconomyControls then
      return nil, "manual economy settlement is available only in developer mode"
    end
    local expectedBoundary = economy.nextBoundary(state.economy)
    if not expectedBoundary then return nil, "authored economy clock is not initialised" end
    local boundary = util.integer(copy.boundaryGameTimeSeconds, expectedBoundary)
    if boundary ~= expectedBoundary then
      return nil, "economy settlement is not the next accounting boundary"
    end
    copy = economyActionRuntime.settlement(state, economy, passengerPresentation,
      cargoPresentation, boundary, scheduled)
  elseif copy.type == "town.develop" then
    if state.bridge.peerId ~= "player1" then return nil, "only the host peer can order town development" end
    for key in pairs(copy) do
      if key ~= "type" and key ~= "batch" then
        return nil, "town development order has an unknown field: " .. tostring(key)
      end
    end
    local valid, developmentError = authoredFollowupRuntime.validateTownBatch(state, copy.batch, true)
    if not valid then return nil, developmentError end
    copy = { type = "town.develop", batch = util.deepCopy(copy.batch) }
  elseif copy.type == "probe.mobility" or copy.type == "probe.structural" then
    if state.bridge.peerId ~= "player1" then
      return nil, "only the host peer can request an ordered native-world sample"
    end
    for key in pairs(copy) do
      if key ~= "type" then
        return nil, tostring(copy.type) .. " has an unknown field: " .. tostring(key)
      end
    end
    copy = { type = copy.type }
  end
  return copy
end

applyCommitted = function(action, actor, commitSeq)
  if type(action) ~= "table" or type(action.type) ~= "string" then return false, "invalid action" end
  local logSeq = state.eventLog.nextSeq or 1
  local authoritySeq = tonumber(commitSeq)
  local identitySeq = authoritySeq or logSeq
  local eventId = string.format("%s:%s:%d", state.bridge.sessionId, tostring(actor or state.bridge.peerId), identitySeq)
  local before = coreDigest()
  local beforeModel = authoredDigest()
  local handler = handlers[action.type]
  local success, result
  if not handler then
    success, result = false, "unknown action: " .. tostring(action.type)
  else
    local invoked, first, second = xpcall(function() return handler(action, eventId, authoritySeq) end, debug.traceback)
    if invoked then success, result = first, second else success, result = false, first end
  end
  if success and state.networkMode ~= "network" then
    if action.type == "proposal.finalise" or action.type == "proposal.construction_step" then
      local proposalId = tostring(action.proposalId or (type(result) == "table" and result.proposalId) or "")
      local record = state.world.proposals.byId[proposalId]
      if record and record.status == "applied" then
        recordProposalInfrastructure(record, -util.integer(record.transaction.cost, 0))
      end
    elseif action.type == "operation.finalise" then
      local operationId = tostring(action.operationId
        or (type(result) == "table" and result.operationId) or "")
      local record = state.world.operations.byId[operationId]
      if record and record.status == "applied" then
        recordVehiclePurchaseCost(record,
          type(result) == "table" and result.financeDelta or nil)
      end
    end
  end
  local after = coreDigest()
  local afterModel = authoredDigest()
  local event = {
    seq = logSeq,
    commitSeq = authoritySeq,
    eventId = eventId,
    tick = state.tick,
    actor = tostring(actor or state.bridge.peerId),
    action = util.deepCopy(action),
    preDigest = before,
    postDigest = after,
    preModelDigest = beforeModel,
    postModelDigest = afterModel,
    success = success and true or false,
    result = util.deepCopy(result),
  }
  state.eventLog.items[#state.eventLog.items + 1] = event
  state.eventLog.nextSeq = logSeq + 1
  trimEvents()
  local recorded, recordError = emitEventRecord(event)
  if not recorded then
    diagnosticLog("event-record-error", { type = action.type, tick = state.tick, error = tostring(recordError) })
  end
  if success and (action.type == "match.initialise" or action.type == "recovery.resume") then
    local checkpointed, checkpointError =
      checkpointRuntime.initialActionCheckpoint(action, authoritySeq)
    if not checkpointed then
      diagnosticLog("checkpoint-error", { tick = state.tick, error = tostring(checkpointError) })
    end
  elseif success and action.type == "network.checkpoint_outcome"
    and action.success == true and action.reason == "match-initialised" then
    -- This outcome proves both peers started from the same authored and
    -- structural boundary.  Queueing here also avoids submitting a nested
    -- intent from inside match.initialise itself.
    autoRegisterExistingServices(action.reason)
  elseif success and action.type == "network.proposal_outcome"
    and (action.success == true or action.recoverable == true) and authoritySeq then
    local reason = (action.success == true and "physical-consensus:" or "physical-rejection:")
      .. tostring(action.proposalId or "unknown")
    local checkpointed, checkpointError = exportCheckpointBarrier(authoritySeq, reason, action.proposalId)
    if not checkpointed then
      diagnosticLog("checkpoint-barrier-error", {
        tick = state.tick,
        boundarySeq = authoritySeq,
        error = tostring(checkpointError),
      })
    end
  elseif success and action.type == "network.operation_outcome"
    and action.success == true and authoritySeq then
    -- Both worlds have now agreed on this operation's physical result, so the
    -- owning peer can safely re-derive the line's competitive facts from a
    -- world its rival also sees.
    local record = state.world.operations.byId[tostring(action.operationId or "")]
    if record then
      -- A line may be deleted before its commit-derived registration reaches
      -- the head of the authored follow-up FIFO.  Drop that now-impossible
      -- job so it cannot retry forever and starve registrations behind it.
      if record.transaction.kind == "line.delete" and networkIntentController then
        networkIntentController.cancelLineRegistration(record.transaction.data.targetCid)
      end
      local outputCid = record.result and record.result.outputs
        and record.result.outputs[1] and record.result.outputs[1].cid or nil
      autoRegisterLineFor(record.transaction, outputCid)
      if type(record.previousLineCid) == "string" and record.previousLineCid ~= ""
        and not (record.transaction.data
          and record.transaction.data.lineCid == record.previousLineCid) then
        autoRegisterLineFor({
          kind = "vehicle.assign",
          companyCid = record.companyCid,
          data = { lineCid = record.previousLineCid },
        }, nil)
      end
    end
    local reason = "operation-consensus:" .. tostring(action.operationId or "unknown")
    local checkpointed, checkpointError = exportCheckpointBarrier(
      authoritySeq, reason, action.operationId)
    if not checkpointed then
      diagnosticLog("checkpoint-barrier-error", {
        tick = state.tick,
        boundarySeq = authoritySeq,
        error = tostring(checkpointError),
      })
    end
  elseif success and action.type == "probe.structural" and authoritySeq then
    local checkpointed, checkpointError = exportCheckpointBarrier(
      authoritySeq, "structural-probe")
    if not checkpointed then
      diagnosticLog("checkpoint-barrier-error", {
        tick = state.tick,
        boundarySeq = authoritySeq,
        error = tostring(checkpointError),
      })
    end
  else
    if not aboardMilestoneIntegration.afterCommit(state, action, success, authoritySeq,
        exportCheckpointBarrier, diagnosticLog)
      and not industryContentRuntime.afterCommit(state, action, success, authoritySeq,
        exportCheckpointBarrier, diagnosticLog) then
      if not freightIndustryRuntime.afterCommit(state, action, success, authoritySeq,
          exportCheckpointBarrier, diagnosticLog) then
        authoredFollowupRuntime.afterCommit(state, action, success, authoritySeq,
          exportCheckpointBarrier, diagnosticLog)
      end
    end
  end
  state.lastAction = util.deepCopy(action)
  state.lastResult = util.deepCopy(result)
  local resultError = type(result) == "table" and result.error or result
  local actionError
  if not success then actionError = tostring(resultError) end
  state.lastError = actionError
  if action.type ~= "native.observed" or not success then
    diagnosticLog("action", {
      type = action.type,
      success = success and true or false,
      tick = state.tick,
      actor = tostring(actor or state.bridge.peerId),
      postDigest = after,
      error = actionError,
    })
  end
  return success, result, event
end

networkIntentController = networkIntentRuntimeModule.new({
  getState = function() return state end,
  normaliseForNetwork = normaliseForNetwork,
  normaliseOperationCapture = normaliseOperationCapture,
  applyCommitted = function(...) return applyCommitted(...) end,
  activeCompany = activeCompany,
  publishSnapshot = publishSnapshot,
  diagnosticLog = diagnosticLog,
  coreDigest = coreDigest,
  proposalPreparation = proposalPreparation,
  maxDeferredIntents = MAX_DEFERRED_NETWORK_INTENTS,
  maxDeferredFollowups = networkIntentRuntimeModule.MAX_DEFERRED_FOLLOWUPS,
  physicalPrerequisite = function(action)
    return networkClock and networkClock.operationPrerequisite(action) or nil
  end,
})
submitIntent = networkIntentController.submit
local processDeferredNetworkIntent = networkIntentController.processDeferred
local consumeBridge = networkIntentController.consume
local networkPendingBarrierReason = networkIntentController.pendingBarrierReason

networkClock = networkClockRuntimeModule.new({
  getState = function() return state end,
  config = config,
  diagnosticLog = diagnosticLog,
  submitIntent = submitIntent,
  awaitingOrder = networkIntentController.awaitingOrder,
  pendingBarrierReason = networkPendingBarrierReason,
  localWorkState = networkIntentController.localWorkState,
})
freezeNetworkGame = networkClock.freezeGame
freezeNetworkCalendar = networkClock.freezeCalendar

economyClock = economyClockRuntimeModule.new({
  getState = function() return state end,
  submitIntent = submitIntent,
  localWorkState = networkIntentController.localWorkState,
  diagnosticLog = diagnosticLog,
})

vehicleSync = vehicleSyncRuntimeModule.new({
  getState = function() return state end,
  diagnosticLog = diagnosticLog,
})

-- Game-script update ticks stop while a loaded world is paused, but GUI
-- frames and script events continue.  Keep ordered ingress in one helper so
-- the periodic GUI snapshot request can pump the bridge as well as the normal
-- simulation update.  Without this boundary a launcher-managed paused save
-- deadlocks: the launcher arms match bootstrap after load, then no engine tick
-- remains on which to emit or consume the first ordered action.
local function pumpNetworkBridge(includeHealth)
  if state.networkMode ~= "network" then return true end
  local consumeOk, consumeError = pcall(consumeBridge)
  if not consumeOk then state.bridge.lastError = tostring(consumeError) end
  local clockOk, clockError = xpcall(networkClock.update, debug.traceback)
  if not clockOk then state.world.networkClock.lastError = tostring(clockError) end
  local economyClockOk, economyClockError = xpcall(economyClock.update, debug.traceback)
  if not economyClockOk then state.probes.lastError = tostring(economyClockError) end
  local vehicleOk, vehicleError = xpcall(vehicleSync.update, debug.traceback)
  if not vehicleOk then state.probes.vehicleSync.lastError = tostring(vehicleError) end
  local deferredOk, deferredError = xpcall(processDeferredNetworkIntent, debug.traceback)
  if not deferredOk then
    state.lastError = "deferred multiplayer physical-action processing failed: "
      .. tostring(deferredError)
  end
  local contentOk, contentError = xpcall(industryContentRuntime.maintain,
    debug.traceback, state, { readFacts = world.industryResourceProbe,
      localWorkState = networkIntentController.localWorkState, submitIntent = submitIntent })
  if not contentOk then
    state.probes.industryContent.lastError = tostring(contentError)
  end
  local freightOk = freightIndustryRuntime.pump(state, {
    readFacts = world.industryBootstrapFacts,
    localWorkState = networkIntentController.localWorkState, submitIntent = submitIntent })
  local healthOk = true
  if includeHealth ~= false then
    local healthError
    healthOk, healthError = xpcall(networkClock.emitHealth, debug.traceback)
    if not healthOk then state.world.networkClock.lastError = tostring(healthError) end
  else
    local healthError
    healthOk, healthError = xpcall(networkClock.emitPausedHealth, debug.traceback)
    if not healthOk then state.world.networkClock.lastError = tostring(healthError) end
  end
  return consumeOk and deferredOk and contentOk and freightOk and healthOk
end

local validationRuntime = validationRuntimeModule.new({
  getState = function() return state end,
  config = config,
  diagnosticLog = diagnosticLog,
  coreDigest = coreDigest,
  authoredDigest = authoredDigest,
  exportResearch = function() return handlers["probe.export_research"]() end,
  balanceOf = function(playerId) return balanceOf(playerId) end,
  proposalResourceName = proposalResourceName,
  applyCommitted = function(...) return applyCommitted(...) end,
  submitIntent = submitIntent,
  awaitingOrder = networkIntentController.awaitingOrder,
  pendingBarrierReason = networkPendingBarrierReason,
  activeCompany = activeCompany,
  refreshOwnershipProbe = refreshOwnershipProbe,
})
local runAutomatedValidation = validationRuntime.runStandalone
local runAutomatedNetworkValidation = validationRuntime.runNetwork
local validationFail = validationRuntime.fail

local gui = guiState.new()
local function renderGui()
  local snapshot = gui.snapshot or publicSnapshot()
  local result = guiView.render(gui, snapshot, {
    maxDeferredNetworkIntents = MAX_DEFERRED_NETWORK_INTENTS,
  })
  return result
end
local function queueAction(action)
  gui.queue[#gui.queue + 1] = action
  gui.lastError = nil
  renderGui()
end
local networkSpeedIndicator = networkSpeedIndicatorModule.new({
  getState = function() return state end,
  wakeClock = function()
    for _, action in ipairs(gui.queue) do
      if action.type == "snapshot.request" then return end
    end
    table.insert(gui.queue, 1, { type = "snapshot.request", localOnly = true })
  end,
})
gui.nativeClockCapture.indicator = networkSpeedIndicator.status()

local function enforceProxyGuiLocks()
  if not (gui.snapshot and gui.snapshot.proxyMode) then return end
  if game and game.gui and type(game.gui.setEnabled) == "function" then
    pcall(game.gui.setEnabled, "finances.borrow", false)
    pcall(game.gui.setEnabled, "finances.repay", false)
  end
end

local function button(label, actionFactory)
  local value = api.gui.comp.Button.new(api.gui.comp.TextView.new(label), true)
  value:onClick(function()
    local ok, action = pcall(actionFactory)
    if ok and action then queueAction(action) else gui.lastError = tostring(action); renderGui() end
  end)
  return value
end

local function addRow(rootLayout, definitions)
  local layout = api.gui.layout.BoxLayout.new("HORIZONTAL")
  local component = api.gui.comp.Component.new("")
  component:setLayout(layout)
  for _, definition in ipairs(definitions) do layout:addItem(button(definition[1], definition[2])) end
  rootLayout:addItem(component)
end

local function ensureWindow()
  if gui.window then
    pcall(gui.window.setVisible, gui.window, true, false)
    renderGui()
    return
  end
  local rootLayout = api.gui.layout.BoxLayout.new("VERTICAL")
  local root = api.gui.comp.Component.new("tpf2mp.root")
  if type(root.setId) == "function" then pcall(root.setId, root, "tpf2mp.root") end
  root:setLayout(rootLayout)
  gui.status = api.gui.comp.TextView.new("TPF2MP starting...")
  gui.details = api.gui.comp.TextView.new("")
  rootLayout:addItem(gui.status)
  addRow(rootLayout, {
    { "Initialise Match", function() return { type = "match.initialise" } end },
    { "Finish Match", function() return { type = "match.finish", reason = "manual-ui" } end },
    { "Cycle Company", function() return { type = "company.cycle" } end },
    { "Reconcile Turn", function() return { type = "company.reconcile" } end },
  })
  if config().developerEconomyControls then
    addRow(rootLayout, {
      { "Seed Demo Market (Dev)", function() return { type = "economy.seed_demo" } end },
      { "Settle Epoch (Dev Host)", function()
      local snapshot = gui.snapshot or {}
      assert(snapshot.networkMode ~= "network" or snapshot.peerId == "player1",
        "only Player 1 (the host) can settle the authoritative economy")
      return { type = "economy.settle" }
      end },
    })
  end
  addRow(rootLayout, {
    { "Add Selected Stop", function()
      gui.routeDraft[#gui.routeDraft + 1] = assert(gui.selectedEntityId,
        "select a station-group icon first")
      return { type = "snapshot.request", localOnly = true }
    end },
    { "Undo Draft Stop", function()
      if #gui.routeDraft > 0 then table.remove(gui.routeDraft) end
      return { type = "snapshot.request", localOnly = true }
    end },
    { "Clear Route Draft", function()
      gui.routeDraft = {}
      return { type = "snapshot.request", localOnly = true }
    end },
    { "Create Draft Line", function()
      assert(#gui.routeDraft >= 2, "add at least two station groups to the route draft")
      return { type = "operation.capture", capture = {
        kind = "line.create", stationGroupLocalIds = util.deepCopy(gui.routeDraft),
      } }
    end },
    { "Update Selected Line", function()
      assert(#gui.routeDraft >= 2, "add at least two station groups to the route draft")
      return { type = "operation.capture", capture = {
        kind = "line.update", targetLocalId = assert(gui.selectedLineId, "select a line first"),
        stationGroupLocalIds = util.deepCopy(gui.routeDraft),
      } }
    end },
  })
  addRow(rootLayout, {
    { "Assign Vehicle to Line", function() return { type = "operation.capture", capture = {
      kind = "vehicle.assign",
      targetLocalId = assert(gui.selectedVehicleId, "select a vehicle first"),
      lineLocalId = assert(gui.selectedLineId, "select a line first"),
      stopIndex = 0,
    } } end },
    { "Stop Vehicle", function() return { type = "operation.capture", capture = {
      kind = "vehicle.stop", targetLocalId = assert(gui.selectedVehicleId, "select a vehicle first"),
      stopped = true,
    } } end },
    { "Start Vehicle", function() return { type = "operation.capture", capture = {
      kind = "vehicle.stop", targetLocalId = assert(gui.selectedVehicleId, "select a vehicle first"),
      stopped = false,
    } } end },
    { "Send Vehicle to Depot", function() return { type = "operation.capture", capture = {
      kind = "vehicle.send_to_depot",
      targetLocalId = assert(gui.selectedVehicleId, "select a vehicle first"),
      sellOnArrival = false,
    } } end },
    { "Sell Vehicle", function() return { type = "operation.capture", capture = {
      kind = "vehicle.sell", targetLocalId = assert(gui.selectedVehicleId, "select a vehicle first"),
    } } end },
    { "Delete Selected Line", function() return { type = "operation.capture", capture = {
      kind = "line.delete", targetLocalId = assert(gui.selectedLineId, "select a line first"),
    } } end },
  })
  addRow(rootLayout, {
    -- Registration is automatic after any line or assignment change; this
    -- stays as a manual re-derive for lines that predate the match or whose
    -- facts a player wants refreshed on demand.
    { "Re-check Selected Line", function() return { type = "line.register", localLineId = assert(gui.selectedLineId, "select a line first") } end },
    { "Claim Selected Asset", function() return { type = "world.claim", ids = { assert(gui.selectedEntityId, "select an entity first") } } end },
    { "Fare -1.00", function() return { type = "fare.adjust", localLineId = assert(gui.selectedLineId, "select a line first"), deltaCents = -100 } end },
    { "Fare +1.00", function() return { type = "fare.adjust", localLineId = assert(gui.selectedLineId, "select a line first"), deltaCents = 100 } end },
  })
  addRow(rootLayout, {
    { "Freeze / Unfreeze", function()
      local snapshot = gui.snapshot or publicSnapshot()
      return { type = "world.freeze", freeze = not snapshot.autonomyFrozen }
    end },
    { "Network Mode (pre-match)", function()
      local snapshot = gui.snapshot or publicSnapshot()
      return { type = "network.set_mode", mode = snapshot.networkMode == "network" and "standalone" or "network" }
    end },
    { "Toggle Income Neutralizer", function() return { type = "finance.toggle_neutralizer" } end },
    { "Repair Starting Cash", function() return { type = "finance.repair_starting_cash", localOnly = true } end },
  })
  addRow(rootLayout, {
    { "Pause", function() return { type = "clock.request", requestedSpeed = 0 } end },
    { "Speed 1", function() return { type = "clock.request", requestedSpeed = 1 } end },
    { "Speed 2", function() return { type = "clock.request", requestedSpeed = 2 } end },
    { "Speed 3", function() return { type = "clock.request", requestedSpeed = 4 } end },
  })
  addRow(rootLayout, {
    { "Toggle Build Gate (Test)", function()
      local snapshot = gui.snapshot or publicSnapshot()
      local gate = snapshot.probes and snapshot.probes.nativeHook
        and snapshot.probes.nativeHook.gates and snapshot.probes.nativeHook.gates.buildProposal or {}
      return { type = "native.build_gate", enabled = gate.enabled ~= true, localOnly = true }
    end },
    { "Authorize Next Build", function()
      return { type = "native.build_authorize", localOnly = true }
    end },
  })
  addRow(rootLayout, {
    { "Run Sync Probe", function() return { type = "probe.run" } end },
    { "Sample Pax / Cargo", function() return { type = "probe.mobility" } end },
    { "Refresh Passenger Display", function()
      return { type = "probe.passenger_cosmetics", localOnly = true }
    end },
    { "Export Research", function() return { type = "probe.export_research" } end },
    { "Export Snapshot", function() return { type = "snapshot.export" } end },
    { "Prepare Restore Point", function() return { type = "recovery.prepare" } end },
    { "Refresh", function() return { type = "snapshot.request", localOnly = true } end },
  })
  rootLayout:addItem(gui.details)
  gui.window = api.gui.comp.Window.new("TPF2MP Multiplayer", root)
  if type(gui.window.setId) == "function" then
    pcall(gui.window.setId, gui.window, "tpf2mp.window")
  end
  gui.window:addHideOnCloseHandler()
  gui.window:setMovable(true)
  gui.window:setResizable(true)
  gui.window:setPinned(true)
  gui.window:setVisible(true, false)
  renderGui()
end

local function installMultiplayerEntryPoints()
  return guiEntryPointsModule.install(gui, ensureWindow)
end

local guiEventRuntime = guiEventRuntimeModule.new({
  getState = function() return state end,
  gui = gui,
  config = config,
  queueAction = queueAction,
  renderGui = renderGui,
  ensureWindow = ensureWindow,
  installMultiplayerEntryPoints = installMultiplayerEntryPoints,
  enforceProxyGuiLocks = enforceProxyGuiLocks,
  componentEntitySet = componentEntitySet,
  balanceOf = function(playerId) return balanceOf(playerId) end,
  nativeHookStatus = nativeHookStatus,
  markNativeContext = markNativeContext,
  configureNativeAuthority = configureNativeAuthority,
  freezeNetworkGame = freezeNetworkGame,
  freezeNetworkCalendar = freezeNetworkCalendar,
  diagnosticLog = diagnosticLog,
  projectNetworkSpeedIndicator = networkSpeedIndicator.project,
  eventId = EVENT_ID,
  scriptFile = SCRIPT_FILE,
})


local operationalCaptureRuntime = operationalCaptureRuntimeModule.new({
  getState = function() return state end,
  config = config,
  accountOf = accountOf,
  activeCompany = activeCompany,
  authoredDigest = authoredDigest,
  coreDigest = coreDigest,
  nativeHookStatus = nativeHookStatus,
  applyCommitted = function(...) return applyCommitted(...) end,
})
local maintainOperationalCapture = operationalCaptureRuntime.maintain

-- Human multiplayer sessions need the same ordered company/account bootstrap
-- as the validator, but none of the validator's synthetic infrastructure.
-- Only the host emits it; the companion orders the resulting match.initialise
-- for both peers and the usual checkpoint barrier proves that they agreed.

local function resetTransientRuntime()
  networkIntentController.reset()
  networkClock.reset()
  economyClock.reset()
  vehicleSync.reset()
  aboardMilestoneIntegration.reset()
  -- Custody of an origin-applied (already natively mutated) operation lives
  -- in module-locals: the deferred queue, the awaiting-order latch, and the
  -- token registry all die with a script reload while the native mutation
  -- sits inside the saved world. The persisted marker outlives them, so a
  -- non-empty marker after load means custody was lost with the mutation
  -- applied. Fault closed rather than continue with divergent worlds.
  local custody = state.world and state.world.originResidueCustody or nil
  local lost = custody and util.tableCount(custody) or 0
  proposalPreparation.originAppliedOperations = {}
  proposalPreparation.pending = {}
  if state.world then
    state.world.originResidueCustody = {}
    proposalPreparation.nextOriginToken = math.max(1,
      util.integer(state.world.originResidueNextToken, 1))
  else
    proposalPreparation.nextOriginToken = 1
  end
  if lost > 0 and networkIntentController.raiseOriginResidueFault then
    networkIntentController.raiseOriginResidueFault(
      "origin-applied-custody-lost-on-reload", { pending = lost })
  end
end

local guiLoadRuntime = guiLoadRuntimeModule.new({
  gui = gui, stateVersion = STATE_VERSION, migrate = migrate,
  getState = function() return state end,
  setState = function(value) state = value end,
  isEngineThread = isEngineThread, resetTransientRuntime = resetTransientRuntime,
  config = config, activeCompany = activeCompany,
  publicSnapshot = publicSnapshot, renderGui = renderGui,
})

local script = {
  init = function()
    if not isEngineThread() then return end
    resetTransientRuntime()
    state = migrate(state)
    state.probes.capabilities = world.capabilityProbe()
    diagnosticLog("engine-init", {
      buildVersion = state.probes.capabilities.buildVersion or "unknown",
      peer = state.bridge.peerId,
      session = state.bridge.sessionId,
      networkMode = state.networkMode,
    })
    markNativeContext("engine")
    local authorityReady, authorityError = configureNativeAuthority(state.networkMode)
    if not authorityReady then
      state.lastError = authorityError
    end
  end,

  update = function()
    if not isEngineThread() then return end
    state.tick = (state.tick or 0) + 1
    local clockOk, clockError = xpcall(networkClock.update, debug.traceback)
    if not clockOk then state.world.networkClock.lastError = tostring(clockError) end
    local economyClockOk, economyClockError = xpcall(economyClock.update, debug.traceback)
    if not economyClockOk then state.probes.lastError = tostring(economyClockError) end
    local vehicleOk, vehicleError = xpcall(vehicleSync.update, debug.traceback)
    if not vehicleOk then state.probes.vehicleSync.lastError = tostring(vehicleError) end
    if state.tick % 300 == 0 then
      local cosmeticOk, cosmeticError = xpcall(refreshPassengerCosmetics, debug.traceback)
      if not cosmeticOk then state.probes.passengerCosmetics.lastError = tostring(cosmeticError) end
    end
    enforceProxyLoanLimit()
    local constructionOk, constructionResult, constructionError =
      xpcall(processCanonicalConstructionProposals, debug.traceback)
    if not constructionOk then
      state.lastError = "canonical construction processing failed: " .. tostring(constructionResult)
    elseif constructionResult ~= true then
      state.lastError = tostring(type(constructionError) == "table"
        and constructionError.error or constructionError or "canonical construction failed")
    end
    local pendingFinanceOk, pendingFinanceError = xpcall(processPendingProposalFinances, debug.traceback)
    if not pendingFinanceOk then state.lastError = tostring(pendingFinanceError) end
    local financeHousekeepingInvoked, financeHousekeepingOk, financeHousekeepingError =
      xpcall(networkFinanceHousekeeping, debug.traceback)
    if not financeHousekeepingInvoked or financeHousekeepingOk ~= true then
      state.probes.lastError = tostring(financeHousekeepingError or financeHousekeepingOk)
    end
    local manualBootstrapOk, manualBootstrapError = xpcall(
      networkClock.maintainManualBootstrap, debug.traceback)
    if not manualBootstrapOk then state.probes.lastError = tostring(manualBootstrapError) end
    local validator = config().networkAutoValidate
      and runAutomatedNetworkValidation or runAutomatedValidation
    local validationOk, validationError = xpcall(validator, debug.traceback)
    if not validationOk then validationFail(validationError) end
    local operationalOk, operationalError = xpcall(maintainOperationalCapture, debug.traceback)
    if not operationalOk then state.probes.operational.lastError = tostring(operationalError) end
    local cfg = config()
    if state.tick % cfg.updateStride == 0 then
      bridge.pollCompanionStatus(state.bridge)
      -- A transient outbox write failure must not lose the second-phase
      -- physical completion report. Completed native proposals remain in the
      -- bounded record set and are retried until the bridge accepts them.
      for _, record in pairs(state.world.proposals.byId or {}) do
        if (record.status == "applied" or record.status == "failed")
          and record.completionEmitted ~= true then
          emitProposalCompletion(record, record.status == "applied", record.result)
        end
      end
      for _, record in pairs(state.world.operations.byId or {}) do
        if (record.status == "applied" or record.status == "failed")
          and record.completionEmitted ~= true then
          emitOperationCompletion(record, record.status == "applied", record.result)
        end
      end
      for _, barrier in pairs(state.world.checkpointConsensus.byBoundary or {}) do
        if barrier.status == "pending" and barrier.exported ~= true then
          exportCheckpointBarrier(barrier.boundarySeq, barrier.reason, barrier.proposalId)
        end
      end
      if state.world.proxyMode then
        if state.finance.neutralizer.enabled then
          state.finance.neutralizer.enabled = false
          state.finance.neutralizer.lastError = "disabled because proxy journal entries must not be neutralized"
        end
      else
        local neutralized, neutralizeErr = finance.updateNeutralizer(state.finance)
        if not neutralized then state.probes.lastError = tostring(neutralizeErr) end
      end
    end
    -- Ordered network ingress is deliberately separated from housekeeping.
    -- Each physical action crosses three barriers, so polling it at the old
    -- 15-tick cadence multiplied latency even though the TCP companions had
    -- already exchanged the relevant record.  The default one-tick cadence is
    -- only a bounded read of the next expected inbox file; checkpoint export
    -- and completion retry remain on the conservative housekeeping stride.
    if state.networkMode == "network"
      and state.tick % cfg.networkBridgeStride == 0 then
      pumpNetworkBridge(true)
    end
  end,

  save = function()
    return state
  end,

  load = function(saved)
    return guiLoadRuntime.load(saved)
  end,

  handleEvent = function(src, id, name, param)
    if id ~= EVENT_ID then return end
    if not isEngineThread() then
      if name == "snapshot" and type(param) == "table" then gui.snapshot = param; renderGui() end
      return
    end
    if name == "intent" then
      local called, accepted, result = pcall(submitIntent, param)
      if not called then
        state.lastError = tostring(accepted)
        publishSnapshot()
      elseif accepted ~= true then
        local detail = type(result) == "table" and result.error or result
        state.lastError = tostring(detail or "intent rejected")
        diagnosticLog("intent-rejected", {
          type = type(param) == "table" and tostring(param.type or "") or "",
          error = state.lastError,
          tick = state.tick,
        })
        publishSnapshot()
      end
    elseif name == "proposal.result" then
      local proposalId = type(param) == "table" and tostring(param.proposalId or "") or ""
      pendingProposalResults[proposalId] = util.deepCopy(param)
      local invoked, success, result = xpcall(function()
        return applyCommitted({
          type = "proposal.finalise",
          proposalId = proposalId,
          localOnly = true,
        }, "native-" .. tostring(state.bridge.peerId), nil)
      end, debug.traceback)
      if not invoked then state.lastError = tostring(success)
      elseif not success then
        state.lastError = tostring(type(result) == "table" and result.error or result)
      else state.lastError = nil end
      diagnosticLog("proposal-native-result", {
        proposalId = proposalId,
        success = invoked and success == true,
        error = state.lastError,
        tick = state.tick,
      })
      publishSnapshot()
    elseif name == "operation.result" then
      local operationId = type(param) == "table" and tostring(param.operationId or "") or ""
      pendingOperationResults[operationId] = util.deepCopy(param)
      local invoked, success, result = xpcall(function()
        return applyCommitted({
          type = "operation.finalise",
          operationId = operationId,
          localOnly = true,
        }, "native-" .. tostring(state.bridge.peerId), nil)
      end, debug.traceback)
      if not invoked then state.lastError = tostring(success)
      elseif not success then state.lastError = tostring(type(result) == "table" and result.error or result)
      else state.lastError = nil end
      diagnosticLog("operation-native-result", {
        operationId = operationId,
        success = invoked and success == true,
        error = state.lastError,
        tick = state.tick,
      })
      publishSnapshot()
    elseif name == "snapshot.request" then
      -- GUI snapshot requests continue while the simulation is paused.  They
      -- are therefore the wake-up path for post-load manual bootstrap and for
      -- ordered controls/checkpoints that arrive while both players are at
      -- speed zero.
      if state.networkMode == "network" then
        -- The persistent launcher/UI Lua state can observe files created after
        -- load even when the engine sandbox cannot. Its explicit readiness bit
        -- is only a wake signal; native authority, host ordering, and the
        -- two-peer checkpoint remain mandatory.
        local launcherReady = type(param) == "table" and param.launcherReady == true
        if launcherReady and not networkClock.manualBootstrap.launcherDiagnosticEmitted then
          networkClock.manualBootstrap.launcherDiagnosticEmitted = true
          local proposalFault = state.world.proposalConsensus.sessionFault
          local operationFault = state.world.operationConsensus.sessionFault
          local diagnostic = {
            event = "launcher-bootstrap-state",
            initialized = state.initialized == true,
            networkMode = state.networkMode,
            sessionId = state.bridge.sessionId,
            peerId = state.bridge.peerId,
            nextOutSeq = state.bridge.nextOutSeq,
            freshReason = state.recovery and state.recovery.freshNetworkBootstrap
              and state.recovery.freshNetworkBootstrap.reason or nil,
            proposalFault = proposalFault and proposalFault.errorCode or nil,
            operationFault = operationFault and operationFault.errorCode or nil,
          }
          diagnosticLog("launcher-bootstrap-state", diagnostic)
          pcall(bridge.emit, state.bridge, "telemetry", diagnostic, state.tick)
        end
        local bootstrapOk, bootstrapError = xpcall(
          function() return networkClock.maintainManualBootstrap(launcherReady) end,
          debug.traceback)
        if not bootstrapOk then state.probes.lastError = tostring(bootstrapError) end
        -- Paused GUI frames repeat one engine tick. The wall-throttled health
        -- path keeps samples fresh without flooding the telemetry outbox.
        local pumpOk, pumpError = xpcall(function()
          return pumpNetworkBridge(false)
        end, debug.traceback)
        if not pumpOk then state.bridge.lastError = tostring(pumpError) end
        if config().networkAutoValidate then
          local validationOk, validationError = xpcall(runAutomatedNetworkValidation, debug.traceback)
          if not validationOk then validationFail(validationError) end
        end
      end
      publishSnapshot()
    end
  end,

  guiInit = function() return guiEventRuntime.init() end,

  guiUpdate = function()
    local result = guiEventRuntime.update()
    pcall(guiStockPresentation.update, gui, gui.snapshot or {})
    return result
  end,

  guiHandleEvent = function(id, name, param)
    local result = guiEventRuntime.handleEvent(id, name, param)
    pcall(guiStockPresentation.handleEvent, gui, gui.snapshot or {}, id, name, param)
    return result
  end,
}

function data()
  return script
end
