local project = assert(arg[1], "project root argument required"):gsub("\\", "/")
package.path = project .. "/tpf2_mp_1/res/scripts/?.lua;" .. package.path

local runtimeConfig = require "tpf2_mp/runtime_config"
local stateSchema = require "tpf2_mp/state_schema"
local nativeHook = require "tpf2_mp/native_hook"
local guiState = require "tpf2_mp/gui_state"
local guiView = require "tpf2_mp/gui_view"
local guiCaptureModule = require "tpf2_mp/gui_capture"
local guiNetworkBootstrapModule = require "tpf2_mp/gui_network_bootstrap"
local proposalRuntimeModule = require "tpf2_mp/proposal_runtime"
local networkIntentRuntimeModule = require "tpf2_mp/network_intent_runtime"
local networkClockRuntimeModule = require "tpf2_mp/network_clock_runtime"
local vehicleSyncRuntimeModule = require "tpf2_mp/vehicle_sync_runtime"
local validationRuntimeModule = require "tpf2_mp/validation_runtime"
local checkpointRuntimeModule = require "tpf2_mp/checkpoint_runtime"
local operationRuntimeModule = require "tpf2_mp/operation_runtime"
local publicSnapshotModule = require "tpf2_mp/public_snapshot"
local economyModule = require "tpf2_mp/economy"
local financeModule = require "tpf2_mp/finance"
local util = require "tpf2_mp/util"

do
  local observerCalls, marked, gameCalls, calendarCalls = 0, nil, 0, 0
  local authorityReady = false
  local bootstrap = guiNetworkBootstrapModule.new({
    installObserver = function() observerCalls = observerCalls + 1 end,
    markNativeContext = function(value) marked = value end,
    configureAuthority = function()
      if authorityReady then return true end
      return false, "authority-not-ready"
    end,
    freezeGame = function() gameCalls = gameCalls + 1; return true end,
    freezeCalendar = function() calendarCalls = calendarCalls + 1; return true end,
  })
  local waiting = bootstrap()
  assert(waiting.authorityReady == false and waiting.gameReady == false
      and waiting.calendarReady == false and waiting.error == "authority-not-ready"
      and gameCalls == 0 and calendarCalls == 0,
    "GUI network bootstrap mutated native clocks before authority was ready")
  authorityReady = true
  local ready = bootstrap()
  assert(ready.authorityReady == true and ready.gameReady == true
      and ready.calendarReady == true and ready.error == nil
      and observerCalls == 2 and marked == "gui" and gameCalls == 1 and calendarCalls == 1,
    "GUI network bootstrap did not prove both post-load clock controls")
end

local function baseConfig(overrides)
  local result = {
    protocol = 1,
    root = ".",
    peerId = "player1",
    sessionId = "runtime-module-test",
    startNetwork = true,
    pauseOnSwitch = false,
    autoValidate = false,
    networkAutoValidate = false,
    operationalCapture = false,
    operationalSampleTicks = 120,
    startingCash = 5000000,
    maxEpochs = 24,
    valuationTargetCents = 50000000,
    neutralizer = false,
  }
  for key, value in pairs(overrides or {}) do result[key] = value end
  return result
end

do
  local current = stateSchema.new(baseConfig(), {
    stateVersion = 21,
    checkpointVersion = 3,
  })
  current.initialized = true
  current.companyOrder = { "company:1", "company:2" }
  current.companies = {
    ["company:1"] = { cid = "company:1", name = "Company 1", playerId = 25 },
    ["company:2"] = { cid = "company:2", name = "Company 2", playerId = 26 },
  }
  financeModule.initialiseNetworkAccounts(
    current.finance, current.companyOrder, 50000000, { reason = "test" })
  local nativeReads = 0
  local snapshot = publicSnapshotModule.new({
    getState = function() return current end,
    activeCompany = function() return "company:1", current.companies["company:1"] end,
    refreshOwnershipProbe = function()
      return { companies = {}, pinned = { companies = {} }, unassigned = { total = 0 } }
    end,
    balanceOf = function()
      nativeReads = nativeReads + 1
      error("GUI load must not inspect a newly-created native PLAYER")
    end,
    accountOf = function()
      nativeReads = nativeReads + 1
      error("GUI load must not inspect a newly-created native PLAYER")
    end,
    coreDigest = function() return "core" end,
    authoredDigest = function() return "model" end,
    deferredNetworkIntents = function() return {} end,
    networkIntentAwaitingOrder = function() return nil end,
    maxDeferredNetworkIntents = 32,
  })({ allowNativeAccounts = false })
  assert(nativeReads == 0,
    "GUI-safe public snapshot touched the native PLAYER entity view")
  assert(snapshot.companies["company:1"].balance == 50000000
      and snapshot.companies["company:2"].balance == 50000000,
    "GUI-safe public snapshot did not use canonical network accounts")
  assert(snapshot.companies["company:1"].nativeBalance == nil,
    "GUI-safe public snapshot published an unavailable native balance")
end

do
  local firstStop = {
    stationGroupCid = "station_group:test:1", station = 0, terminal = 0,
  }
  local secondStop = {
    stationGroupCid = "station_group:test:2", station = 0, terminal = 0,
  }
  local transaction = {
    kind = "line.update",
    data = { line = { stops = { util.deepCopy(firstStop) } } },
  }
  local exact = {
    kind = "line.update", targetCid = "line:test", exists = true,
    stops = { util.deepCopy(firstStop) },
  }
  local canonical, canonicalError = operationRuntimeModule.reconcileLinePostcondition(
    transaction, "line:test", exact, false)
  assert(canonical and canonicalError == nil and #canonical.stops == 1,
    "exact replay line state did not satisfy the canonical postcondition")

  local advanced = util.deepCopy(exact)
  advanced.stops[2] = util.deepCopy(secondStop)
  local rejected, replayError = operationRuntimeModule.reconcileLinePostcondition(
    transaction, "line:test", advanced, false)
  assert(rejected == nil
      and replayError == "native line postcondition does not match the ordered transaction",
    "a replay peer accepted a line state beyond the ordered intermediate state")

  local optimistic, optimisticError = operationRuntimeModule.reconcileLinePostcondition(
    transaction, "line:test", advanced, true)
  assert(optimistic and optimisticError == nil and #optimistic.stops == 1
      and optimistic.stops[1].stationGroupCid == firstStop.stationGroupCid,
    "an optimistic origin could not certify its captured intermediate line state")
  assert(#advanced.stops == 2,
    "line postcondition reconciliation mutated the observed physical state")
end

do
  local current = {
    canonical = {
      byCanonical = {
        ["edge:test"] = { localId = 10, metadata = { owner = "company:1" } },
      },
    },
    world = {
      logicalOwners = {},
      pinnedCustody = {},
    },
  }
  local function proposalRuntime()
    return proposalRuntimeModule.new({
      getState = function() return current end,
      requireRunningMatch = function() return true end,
      balanceOf = function() return 0 end,
      coreDigest = function() return "00000000" end,
      refreshOwnershipProbe = function() return {} end,
      componentEntitySet = function() return {} end,
      inspectCreatedNodes = function() return {} end,
      inspectCreatedEdges = function() return {} end,
      nodePosition = function() return nil end,
      applyCommitted = function() return true end,
    })
  end
  local first, second = proposalRuntime(), proposalRuntime()
  first.preparation.pending.test = { transactionId = "first" }
  assert(second.preparation.pending.test == nil,
    "proposal runtimes share machine-local preparation state")
  assert(first.preparation.owner("edge:test") == "company:1",
    "proposal runtime lost canonical owner metadata")
  current = {
    canonical = { byCanonical = {} },
    world = { logicalOwners = { ["20"] = "company:2" }, pinnedCustody = {} },
  }
  assert(first.preparation.owner("edge:replacement", 20) == "company:2",
    "proposal runtime retained a stale script.load state table")
end

do
  local current = {
    networkMode = "standalone",
    initialized = false,
    tick = 1,
    bridge = { peerId = "player1" },
    probes = {},
    world = {
      proposalConsensus = { byId = {} },
      operationConsensus = { byId = {} },
      checkpointConsensus = { byBoundary = {} },
    },
    finance = {},
  }
  local committed, published = 0, 0
  local controller = networkIntentRuntimeModule.new({
    getState = function() return current end,
    normaliseForNetwork = function(action) return action end,
    normaliseOperationCapture = function(action) return action end,
    applyCommitted = function(action)
      committed = committed + 1
      return true, { type = action.type }
    end,
    activeCompany = function() return "company:1" end,
    publishSnapshot = function() published = published + 1 end,
    diagnosticLog = function() end,
    coreDigest = function() return "00000000" end,
    proposalPreparation = { pending = {} },
  })
  local ok, result = controller.submit({ type = "probe.run", localOnly = true })
  assert(ok and result.type == "probe.run" and committed == 1 and published == 1,
    "standalone intent did not cross the explicit commit/snapshot boundary")
  current.world.checkpointConsensus.byBoundary[7] = { status = "pending" }
  assert(controller.pendingBarrierReason():find("checkpoint boundary", 1, true),
    "network intent controller lost checkpoint back-pressure")
  local copy = controller.deferredIntents()
  copy[1] = { action = { type = "corrupt" } }
  assert(#controller.deferredIntents() == 0,
    "network intent controller exposed its mutable queue")
  controller.reset()
  assert(controller.awaitingOrder() == nil and #controller.deferredIntents() == 0,
    "network intent controller reset did not clear machine-local state")
end

do
  -- An origin-applied capture is a native mutation that already happened.
  -- Every rejection path must convert into an operation-consensus session
  -- fault instead of a status-line whisper.
  local function faultHarness(captureResult, options)
    options = options or {}
    local current = {
      networkMode = "network",
      initialized = false,
      tick = 9,
      bridge = { peerId = "player1" },
      probes = { networkAuthority = { ready = true } },
      world = {
        proposalConsensus = { byId = {} },
        operationConsensus = { byId = {} },
        checkpointConsensus = { byBoundary = {} },
      },
      finance = {},
    }
    local logged = {}
    local controller = networkIntentRuntimeModule.new({
      getState = function() return current end,
      normaliseForNetwork = function(action) return action end,
      normaliseOperationCapture = function() return captureResult, "operation cannot mutate rival-owned line" end,
      applyCommitted = function(action) return true, { type = action.type } end,
      activeCompany = function() return "company:1" end,
      publishSnapshot = function() end,
      diagnosticLog = function(event, payload) logged[#logged + 1] = { event = event, payload = payload } end,
      coreDigest = function() return "00000000" end,
      proposalPreparation = { pending = {} },
      maxDeferredIntents = options.maxDeferredIntents,
    })
    return current, controller, logged
  end

  local current, controller, logged = faultHarness(nil)
  local ok = controller.submit({
    type = "operation.capture",
    capture = { kind = "line.update", originApplied = true, targetLocalId = 7 },
  })
  local fault = current.world.operationConsensus.sessionFault
  assert(ok == false and fault
    and fault.errorCode:find("origin%-applied%-capture%-rejected:") == 1
    and fault.status == "faulted" and fault.detail.kind == "line.update",
    "rejected origin-applied capture did not fault the session")
  assert(logged[1] and logged[1].event == "origin-applied-residue-fault",
    "origin residue fault was not logged for the audit trail")
  local blockedOk, blockedError = controller.submit({ type = "proposal.build", transaction = {} })
  assert(blockedOk == false and tostring(blockedError):find("faulted"),
    "faulted session accepted a further physical action")

  current, controller = faultHarness(nil)
  local plainOk = controller.submit({
    type = "operation.capture",
    capture = { kind = "line.update", targetLocalId = 7 },
  })
  assert(plainOk == false and current.world.operationConsensus.sessionFault == nil,
    "a rejected mod-panel capture without native residue must not fault the session")

  current, controller = faultHarness(nil)
  local residueOk, residueResult = controller.submit({
    type = "network.origin_residue",
    errorCode = "origin-applied-create-unidentified",
    detail = { tag = 3 },
  })
  fault = current.world.operationConsensus.sessionFault
  assert(residueOk == true and residueResult.faulted == true and fault
    and fault.errorCode == "origin-applied-create-unidentified"
    and fault.detail.tag == 3,
    "GUI-reported origin residue did not fault the session")

  current, controller = faultHarness(nil)
  current.networkMode = "standalone"
  local standaloneOk = controller.submit({
    type = "network.origin_residue",
    errorCode = "origin-applied-create-unidentified",
  })
  assert(standaloneOk == false and current.world.operationConsensus.sessionFault == nil,
    "origin residue faults must exist only in network mode")

  local normalizedCapture = {
    type = "operation.execute",
    kind = "line.update",
    companyCid = "company:1",
    originCaptureToken = "player1:operation-origin:1",
  }

  current, controller = faultHarness(normalizedCapture)
  local emitOk = controller.submit({
    type = "operation.capture",
    capture = { kind = "line.update", originApplied = true, targetLocalId = 7 },
  })
  fault = current.world.operationConsensus.sessionFault
  assert(emitOk == false and fault
    and fault.errorCode:find("origin%-applied%-intent%-emit%-failed:") == 1,
    "an immediate bridge failure left an origin-applied capture unfaulted")

  current, controller = faultHarness(normalizedCapture)
  current.probes.networkAuthority.ready = false
  local authorityOk = controller.submit({
    type = "operation.capture",
    capture = { kind = "line.update", originApplied = true, targetLocalId = 7 },
  })
  fault = current.world.operationConsensus.sessionFault
  assert(authorityOk == false and fault
    and fault.errorCode:find("origin%-applied%-authority%-unavailable:") == 1,
    "authority bootstrap rejection left an origin-applied capture unfaulted")

  current, controller = faultHarness(normalizedCapture)
  current.initialized = true
  local financeOk = controller.submit({
    type = "operation.capture",
    capture = { kind = "line.update", originApplied = true, targetLocalId = 7 },
  })
  fault = current.world.operationConsensus.sessionFault
  assert(financeOk == false and fault
    and fault.errorCode:find("origin%-applied%-finance%-unavailable:") == 1,
    "canonical-account rejection left an origin-applied capture unfaulted")

  current, controller = faultHarness(normalizedCapture, { maxDeferredIntents = 1 })
  current.world.checkpointConsensus.byBoundary[3] = { status = "pending" }
  local queuedOk, queuedResult = controller.submit({
    type = "operation.capture",
    capture = { kind = "line.update", originApplied = true, targetLocalId = 7 },
  })
  assert(queuedOk == true and queuedResult.deferred == true,
    "origin-applied capture was not queued behind a consensus barrier")
  local overflowOk = controller.submit({
    type = "operation.capture",
    capture = { kind = "line.update", originApplied = true, targetLocalId = 8 },
  })
  fault = current.world.operationConsensus.sessionFault
  assert(overflowOk == false and fault
    and fault.errorCode == "origin-applied-deferred-queue-full"
    and fault.detail.queueDepth == 1 and fault.detail.queueCapacity == 1,
    "deferred FIFO overflow left an origin-applied capture unfaulted")

  -- A normalizer that throws must not lose an already-applied mutation to
  -- the outer handleEvent pcall.
  do
    local thrown = {
      networkMode = "network", initialized = false, tick = 9,
      bridge = { peerId = "player1" },
      probes = { networkAuthority = { ready = true } },
      world = {
        proposalConsensus = { byId = {} },
        operationConsensus = { byId = {} },
        checkpointConsensus = { byBoundary = {} },
      },
      finance = {},
    }
    local thrownController = networkIntentRuntimeModule.new({
      getState = function() return thrown end,
      normaliseForNetwork = function(action) return action end,
      normaliseOperationCapture = function() error("station group lookup exploded") end,
      applyCommitted = function(action) return true, { type = action.type } end,
      activeCompany = function() return "company:1" end,
      publishSnapshot = function() end,
      diagnosticLog = function() end,
      coreDigest = function() return "00000000" end,
      proposalPreparation = { pending = {} },
    })
    local throwOk = thrownController.submit({
      type = "operation.capture",
      capture = { kind = "line.update", originApplied = true, targetLocalId = 7 },
    })
    local throwFault = thrown.world.operationConsensus.sessionFault
    assert(throwOk == false and throwFault
      and throwFault.errorCode:find("origin%-applied%-capture%-rejected:") == 1
      and throwFault.errorCode:find("exploded", 1, true),
      "a throwing normalization left an origin-applied capture unfaulted")
  end

  -- The deferred-emit failure variant: a token-bearing action that reaches
  -- the front of the FIFO and then fails to emit.
  do
    local deferred = {
      networkMode = "network", initialized = false, tick = 9,
      bridge = { peerId = "player1" },
      probes = { networkAuthority = { ready = true } },
      world = {
        proposalConsensus = { byId = {} },
        operationConsensus = { byId = {} },
        checkpointConsensus = { byBoundary = { [3] = { status = "pending" } } },
      },
      finance = {},
    }
    local deferredController = networkIntentRuntimeModule.new({
      getState = function() return deferred end,
      normaliseForNetwork = function(action) return action end,
      normaliseOperationCapture = function() return normalizedCapture end,
      applyCommitted = function(action) return true, { type = action.type } end,
      activeCompany = function() return "company:1" end,
      publishSnapshot = function() end,
      diagnosticLog = function() end,
      coreDigest = function() return "00000000" end,
      proposalPreparation = { pending = {} },
    })
    local queued = deferredController.submit({
      type = "operation.capture",
      capture = { kind = "line.update", originApplied = true, targetLocalId = 7 },
    })
    assert(queued == true, "token-bearing capture did not defer behind the barrier")
    deferred.world.checkpointConsensus.byBoundary[3] = nil
    deferredController.processDeferred()
    local deferredFault = deferred.world.operationConsensus.sessionFault
    assert(deferredFault
      and deferredFault.errorCode:find("origin%-applied%-intent%-emit%-failed:") == 1,
      "a deferred token-bearing emit failure left the mutation unfaulted")
  end
end

do
  local current = {
    networkMode = "network",
    initialized = false,
    tick = 240,
    bridge = { peerId = "player1" },
    probes = {
      networkAuthority = { ready = true },
      networkCalendar = { requested = true, frozen = true },
    },
  }
  local submissions = 0
  local bootstrapReady = false
  local clock = networkClockRuntimeModule.new({
    getState = function() return current end,
    config = function()
      return { manualNetwork = true, manualBootstrapReady = bootstrapReady }
    end,
    diagnosticLog = function() end,
    submitIntent = function(action)
      submissions = submissions + 1
      return action.type == "match.initialise", { local_seq = 9 }
    end,
    awaitingOrder = function() return nil end,
    pendingBarrierReason = function() return nil end,
  })
  clock.maintainManualBootstrap()
  assert(submissions == 0,
    "manual clock bootstrap ran before the launcher confirmed both worlds")
  current.tick = 120
  clock.maintainManualBootstrap(true)
  assert(submissions == 0 and clock.manualBootstrap.launcherReady == true,
    "manual clock bootstrap did not latch an early launcher/UI readiness handoff")
  current.tick = 240
  clock.maintainManualBootstrap()
  assert(submissions == 1 and clock.manualBootstrap.submitted == true,
    "manual clock bootstrap lost its latched launcher/UI readiness handoff")
  clock.reset()
  bootstrapReady = true
  clock.maintainManualBootstrap()
  assert(submissions == 2,
    "manual clock bootstrap ignored a directly visible readiness marker")
  clock.reset()
  assert(clock.manualBootstrap.attempts == 0 and clock.manualBootstrap.nextAttemptTick == 240
      and clock.manualBootstrap.launcherReady == false,
    "network clock reset did not restore bootstrap defaults")
end

do
  local gameTime, gameSpeed = 10, 1
  local wall = 100
  local commands, emitted = {}, {}
  local current = {
    networkMode = "network", initialized = true, tick = 30,
    bridge = { peerId = "player1", nextInSeq = 3 },
    probes = {
      networkAuthority = { ready = true },
      networkCalendar = { requested = true, frozen = true },
    },
    world = {
      networkClock = {
        requestedSpeed = 1, effectiveSpeed = 1, generation = 0,
        rendezvousReached = 0, rendezvousFaults = 0,
        startupPause = { requested = true, confirmed = true },
      },
      proposalConsensus = { byId = {} },
    },
  }
  local clock = networkClockRuntimeModule.new({
    getState = function() return current end,
    config = function() return {} end,
    diagnosticLog = function() end,
    submitIntent = function() return true, {} end,
    awaitingOrder = function() return nil end,
    pendingBarrierReason = function() return nil end,
    clockSnapshot = function()
      return { time = gameTime, gameSpeed = gameSpeed }
    end,
    wallTime = function() return wall end,
    commandFactory = function(kind)
      return function(speed) return { kind = kind, speed = speed } end
    end,
    authorizeCommand = function(tag) return tag == 0 end,
    sendCommand = function(command, callback)
      commands[#commands + 1] = util.deepCopy(command)
      if command.kind == "setGameSpeed" then gameSpeed = command.speed end
      if callback then callback(command, true) end
      return true
    end,
    emit = function(kind, payload)
      emitted[#emitted + 1] = { kind = kind, payload = util.deepCopy(payload) }
      return true, { local_seq = #emitted }
    end,
  })
  local armed = clock.arm({
    type = "clock.rendezvous", requestedSpeed = 3, approachSpeed = 1,
    releaseSpeed = 3, generation = 1, targetGameTime = 12,
    reason = "runtime-test",
  })
  assert(armed == true and #commands == 0
      and current.world.networkClock.rendezvous.status == "approaching",
    "future clock rendezvous did not arm without pausing early")
  gameTime, current.tick = 11.99, 31
  clock.update()
  assert(#commands == 0 and #emitted == 0,
    "future clock rendezvous paused or reported before its target")
  gameTime, current.tick = 12, 32
  clock.update()
  assert(#commands == 1 and commands[1].speed == 0 and gameSpeed == 0
      and current.world.networkClock.rendezvous.status == "reached"
      and current.world.networkClock.rendezvousReached == 1,
    "clock rendezvous did not pause exactly at the local target")
  local reached
  for _, envelope in ipairs(emitted) do
    if envelope.kind == "clock_reached" then reached = envelope.payload end
  end
  assert(reached and reached.generation == 1 and reached.targetGameTime == 12
      and reached.actualGameTime == 12 and reached.success == true,
    "clock rendezvous did not report its observed arrival")
  current.tick = 33
  local applied = clock.apply({
    type = "clock.set", requestedSpeed = 3, effectiveSpeed = 3,
    generation = 2, reason = "release-runtime-test",
  })
  assert(applied == true and gameSpeed == 3 and #commands == 2
      and current.world.networkClock.rendezvous == nil
      and current.world.networkClock.lastRendezvous.generation == 1,
    "ordered post-rendezvous speed did not release the shared clock")
  local prerequisite, waitReason = clock.operationPrerequisite({
    type = "operation.execute", transaction = { kind = "line.update" },
  })
  assert(prerequisite and prerequisite.type == "clock.request"
      and prerequisite.requestedSpeed == 0 and waitReason:find("rendezvous", 1, true),
    "non-origin line mutation was not guarded by a shared pause prerequisite")
  local originPrerequisite = clock.operationPrerequisite({
    type = "operation.execute", originCaptureToken = "already-applied",
    transaction = { kind = "vehicle.sell" },
  })
  assert(originPrerequisite and originPrerequisite.requestedSpeed == 0,
    "origin-applied vehicle capture did not pause both worlds before replication")
  current.world.networkClock.effectiveSpeed, gameSpeed = 0, 1
  local nativeMismatchPrerequisite = clock.operationPrerequisite({
    type = "operation.execute", transaction = { kind = "vehicle.assign" },
  })
  assert(nativeMismatchPrerequisite and nativeMismatchPrerequisite.requestedSpeed == 0,
    "native running state bypassed the authoritative operation pause")
  local healthBefore = #emitted
  gameSpeed = 0
  assert(clock.emitPausedHealth() == true, "paused clock did not emit its first heartbeat")
  wall = 101
  assert(clock.emitPausedHealth() == false,
    "paused clock heartbeat ignored its wall-time throttle")
  wall = 102
  assert(clock.emitPausedHealth() == true and #emitted == healthBefore + 2,
    "paused clock did not refresh telemetry before the host freshness deadline")
  gameSpeed = 3
  local startupPaused = clock.freezeGame()
  assert(startupPaused == true and gameSpeed == 0
      and current.world.networkClock.startupPause.confirmed == true,
    "network startup did not pause the loaded native world immediately")
  gameTime = nil
  assert(clock.arm({
    type = "clock.rendezvous", requestedSpeed = 1, approachSpeed = 1,
    releaseSpeed = 1, generation = 3, targetGameTime = 20,
  }) == false, "clock rendezvous accepted an unavailable local game time")
  local calendarOk, calendarError = clock.freezeCalendar()
  assert(calendarOk == false and calendarError:find("authorize", 1, true),
    "calendar freeze ignored a rejected native authorization")
end

do
  local current = { validation = { enabled = false } }
  local function noop() return true, {} end
  local validation = validationRuntimeModule.new({
    getState = function() return current end,
    config = function() return { autoValidate = false, networkAutoValidate = false } end,
    diagnosticLog = function() end,
    coreDigest = function() return "00000000" end,
    authoredDigest = function() return "00000000" end,
    exportResearch = noop,
    balanceOf = function() return 0 end,
    proposalResourceName = function() return nil end,
    applyCommitted = noop,
    submitIntent = noop,
    awaitingOrder = function() return nil end,
    pendingBarrierReason = function() return nil end,
    activeCompany = function() return nil end,
    refreshOwnershipProbe = function() return {} end,
  })
  assert(validation.runStandalone() == nil and validation.runNetwork() == nil,
    "disabled validation runtime performed work")
end

do
  local environment = {
    TPF2MP_MANUAL_NETWORK = "yes",
    TPF2MP_PEER_ID = "player2",
    TPF2MP_SESSION_ID = "injected-session",
    TPF2MP_BRIDGE_DIR = "C:/bridge/injected",
    TPF2MP_STARTING_CASH = "75000000",
    TPF2MP_NETWORK_CLOCK_RUN_TICKS = "900",
    TPF2MP_STARTING_COMPANY_PLAYER_IDS = "9478,9479,9478",
  }
  local cfg = runtimeConfig.read({
    source = {
      protocolVersion = 3,
      localProxyEnabled = true,
      maxEpochs = 12,
    },
    environment = function(name) return environment[name] end,
    bridgeMarkerExists = function() return false end,
    bridgeMarkerValue = function() return "waiting" end,
  })
  assert(cfg.protocol == 3 and cfg.startNetwork == true, "injected network configuration was lost")
  assert(cfg.peerId == "player2" and cfg.sessionId == "injected-session",
    "injected peer/session identity was lost")
  assert(cfg.root == "C:/bridge/injected" and cfg.startingCash == 75000000,
    "injected bridge/economy configuration was lost")
  assert(cfg.networkClockRunTicks == 900,
    "injected network clock run window was lost")
  assert(#cfg.startingCompanyPlayerIds == 2
      and cfg.startingCompanyPlayerIds[1] == 9478
      and cfg.startingCompanyPlayerIds[2] == 9479,
    "launcher save-owner identities were not parsed deterministically")
  assert(cfg.localProxy == false, "network mode must disable the local proxy")
  assert(cfg.manualBootstrapReady == false,
    "manual network bootstrap ignored the launcher world-ready boundary")
  local armed = runtimeConfig.read({
    source = {},
    environment = function(name) return environment[name] end,
    bridgeMarkerValue = function(_, name)
      return name == "manual-bootstrap-ready" and "ready" or nil
    end,
  })
  assert(armed.manualBootstrapReady == true,
    "manual network bootstrap did not arm after the launcher marker")
end

do
  local versions = { stateVersion = 21, checkpointVersion = 3 }
  local cfg = baseConfig()
  local first = stateSchema.new(cfg, versions)
  local second = stateSchema.new(cfg, versions)
  first.world.logicalOwners.test = "company:1"
  assert(second.world.logicalOwners.test == nil, "new states share mutable nested tables")
  assert(first.version == 21 and first.checkpoint.version == 3,
    "new state did not retain its schema versions")
  assert(first.networkMode == "network" and first.bridge.peerId == "player1",
    "new state did not retain its runtime identity")

  first.version = 7
  first.world.networkClock = nil
  first.probes.operational = nil
  local migrated = stateSchema.migrate(first, {
    newState = function() return stateSchema.new(cfg, versions) end,
    config = function() return cfg end,
    stateVersion = 21,
    checkpointVersion = 3,
  })
  assert(migrated.version == 21 and migrated.world.networkClock.generation == 0,
    "migration did not restore current clock/schema defaults")
  assert(type(migrated.probes.operational.samples) == "table",
    "migration did not restore operational telemetry defaults")

  local prior = stateSchema.new(baseConfig({ startNetwork = false }), versions)
  prior.initialized = true
  prior.networkMode = "standalone"
  prior.companyOrder = { "company:1", "company:2" }
  prior.companies = {
    ["company:1"] = { cid = "company:1", playerId = 9478 },
    ["company:2"] = { cid = "company:2", playerId = 9479 },
  }
  prior.world.logicalOwners["4184"] = "company:1"
  prior.world.autonomyFrozen = true
  prior.world.lastFreezeResult = {
    freeze = true,
    towns = 2,
    industries = 5,
    errors = {},
  }
  prior.canonical.byCanonical["construction:test"] = {
    canonicalId = "construction:test",
    kind = "construction",
    localId = 9500,
    metadata = { owner = "company:2" },
  }
  local fresh = stateSchema.migrate(prior, {
    newState = function() return stateSchema.new(cfg, versions) end,
    config = function() return cfg end,
    stateVersion = 21,
    checkpointVersion = 3,
  })
  local hints = fresh.world.startingOwnershipHints
  assert(fresh.initialized == false and hints
      and hints.companyPlayerIds[1] == 9478 and hints.companyPlayerIds[2] == 9479
      and hints.logicalOwners["4184"] == "company:1"
      and hints.logicalOwners["9500"] == "company:2"
      and fresh.world.autonomyFrozen == true
      and fresh.world.lastFreezeResult.towns == 2
      and fresh.world.lastFreezeResult.industries == 5
      and fresh.recovery.freshNetworkBootstrap.autonomyFreezePreserved == true
      and fresh.recovery.freshNetworkBootstrap.ownershipHintCompanies == 2
      and fresh.recovery.freshNetworkBootstrap.ownershipHintEntities == 2,
    "fresh network migration discarded validated ownership provenance")

  prior.initialized = false
  prior.world.lastFreezeResult.errors = { "incomplete freeze" }
  prior.world.proposalConsensus.sessionFault = {
    errorCode = "checkpoint-consensus-timeout:player1,player2",
  }
  local cleanRetry = stateSchema.migrate(prior, {
    newState = function() return stateSchema.new(cfg, versions) end,
    config = function() return cfg end,
    stateVersion = 21,
    checkpointVersion = 3,
  })
  assert(cleanRetry.initialized == false
      and cleanRetry.world.autonomyFrozen == false
      and cleanRetry.recovery.freshNetworkBootstrap.autonomyFreezePreserved == false
      and cleanRetry.world.proposalConsensus.sessionFault == nil
      and cleanRetry.recovery.freshNetworkBootstrap ~= nil,
    "a faulted uninitialised state leaked across a new network session")
end

do
  local status = nativeHook.compactStatus({
    schemaVersion = 4,
    hookVersion = "test",
    active = true,
    validation = { valid = true, signatures = {} },
    hooks = {
      enabled = true,
      buildProposalVisitor = true,
      authorityCommandVisitors = 23,
    },
    gates = {
      buildProposal = { enabled = true, tagMismatches = 0 },
      commandVisitors = { enabled = true, hooked = 23, tagMismatches = 0 },
    },
  })
  local ready, boundary = nativeHook.validatedNetworkAuthority(status)
  assert(ready == true and boundary.commandVisitors == 23,
    "validated native authority status was not accepted")
  status.gates.commandVisitors.tagMismatches = 1
  assert(nativeHook.validatedNetworkAuthority(status) == false,
    "ABI-mismatched native authority status was accepted")
end

do
  local first, second = guiState.new(), guiState.new()
  first.queue[1] = { type = "test" }
  assert(#second.queue == 0, "GUI states share their mutable queues")

  local capture = guiCaptureModule.install(first, { proposalCost = function() return 42 end })
  local shaped = capture.eventShape({ z = 2, a = 1 })
  assert(shaped.a == 1 and shaped.z == 2 and shaped.__type == "table",
    "GUI event projection lost a plain deterministic payload")

  local status, details = {}, {}
  function status:setText(value) self.value = value end
  function details:setText(value) self.value = value end
  first.status, first.details = status, details
  guiView.render(first, {
    networkMode = "network",
    peerId = "player1",
    sessionId = "runtime-module-test",
    activeCompanyName = "Company 1",
    match = { status = "running", rules = {} },
    bridge = { companion = { connected = true, status = "connected" } },
    companyOrder = {},
    probes = {},
  }, { maxDeferredNetworkIntents = 32 })
  assert(status.value:find("Peer: player1", 1, true), "GUI status formatter lost peer identity")
  assert(details.value:find("Session: runtime-module-test", 1, true),
    "GUI detail formatter lost session identity")
end

do
  local model = economyModule.newState()
  economyModule.upsertMarket(model, {
    cid = "market:digest", name = "Digest market", demand = 1000,
    votCentsPerHour = 450, gcOutsideCents = 2500, thetaCents = 250,
  })
  economyModule.upsertService(model, {
    lineCid = "line:digest", marketCid = "market:digest", companyCid = "company:1",
    name = "Digest service", headwaySeconds = 900, journeySeconds = 2400,
    fareCents = 1000, capacity = 600, quality = 100, transfers = 0,
  })
  economyModule.evaluateAll(model)
  local current = {
    initialized = true,
    match = { status = "running", rules = {} },
    companies = { ["company:1"] = { cid = "company:1", name = "Company 1" } },
    companyOrder = { "company:1" },
    economy = model,
    finance = financeModule.newState(),
    world = { autonomyFrozen = true },
  }
  local runtime = checkpointRuntimeModule.new({
    getState = function() return current end,
    maxEvents = function() return 100 end,
    stateVersion = 21,
    checkpointVersion = 3,
    eventRecordVersion = 1,
  })
  local original = util.deepCopy(model)
  local baseline = runtime.authoredDigest()
  local mutations = {
    { "params.alphaUpPm", function(value) value.params.alphaUpPm = value.params.alphaUpPm + 1 end },
    { "params.alphaDownPm", function(value) value.params.alphaDownPm = value.params.alphaDownPm + 1 end },
    { "params.maxWaitSeconds", function(value) value.params.maxWaitSeconds = value.params.maxWaitSeconds + 1 end },
    { "params.transferSeconds", function(value) value.params.transferSeconds = value.params.transferSeconds + 1 end },
    { "params.crowdThresholdPpm", function(value) value.params.crowdThresholdPpm = value.params.crowdThresholdPpm + 1 end },
    { "market.name", function(value) value.markets["market:digest"].name = "Other" end },
    { "market.demand", function(value) value.markets["market:digest"].demand = 1001 end },
    { "market.votCentsPerHour", function(value) value.markets["market:digest"].votCentsPerHour = 451 end },
    { "market.gcOutsideCents", function(value) value.markets["market:digest"].gcOutsideCents = 2501 end },
    { "market.thetaCents", function(value) value.markets["market:digest"].thetaCents = 251 end },
    { "service.marketCid", function(value) value.services["line:digest"].marketCid = "market:other" end },
    { "service.companyCid", function(value) value.services["line:digest"].companyCid = "company:2" end },
    { "service.name", function(value) value.services["line:digest"].name = "Other" end },
    { "service.headwaySeconds", function(value) value.services["line:digest"].headwaySeconds = 901 end },
    { "service.journeySeconds", function(value) value.services["line:digest"].journeySeconds = 2401 end },
    { "service.fareCents", function(value) value.services["line:digest"].fareCents = 1001 end },
    { "service.capacity", function(value) value.services["line:digest"].capacity = 601 end },
    { "service.quality", function(value) value.services["line:digest"].quality = 101 end },
    { "service.transfers", function(value) value.services["line:digest"].transfers = 1 end },
    { "service.enabled", function(value) value.services["line:digest"].enabled = false end },
    { "service.sharePpm", function(value) value.services["line:digest"].sharePpm = value.services["line:digest"].sharePpm + 1 end },
    { "service.shareResid", function(value) value.services["line:digest"].shareResid = value.services["line:digest"].shareResid + 1 end },
    { "service.lagLoadPpm", function(value) value.services["line:digest"].lagLoadPpm = value.services["line:digest"].lagLoadPpm + 1 end },
    { "service.lastFareCents", function(value) value.services["line:digest"].lastFareCents = value.services["line:digest"].lastFareCents + 1 end },
  }
  for _, mutation in ipairs(mutations) do
    current.economy = util.deepCopy(original)
    mutation[2](current.economy)
    assert(runtime.authoredDigest() ~= baseline,
      "authored digest hides evaluator input " .. mutation[1])
  end
  current.economy = model
end

do
  local priorApi = api
  api = { type = { ComponentType = { TRANSPORT_VEHICLE = "TRANSPORT_VEHICLE" } } }
  local transportVehicle = {
    line = 50, state = 1, stopIndex = 0, userStopped = false,
  }
  local currentTime, currentSpeed = 10, 1
  local emitted, commands = {}, {}
  local current = {
    networkMode = "network",
    initialized = true,
    tick = 1,
    bridge = { peerId = "player1" },
    canonical = {
      byCanonical = {
        ["line:event:test:1"] = {
          canonicalId = "line:event:test:1", kind = "line", localId = 50, metadata = {},
        },
        ["vehicle:event:test:1"] = {
          canonicalId = "vehicle:event:test:1", kind = "vehicle", localId = 60,
          -- A pinned starting-save vehicle has no operation-authored lineCid;
          -- the runtime must derive its canonical line from the local mapping.
          metadata = { owner = "company:1" },
        },
      },
      byLocal = { ["line:50"] = "line:event:test:1" },
    },
    world = {
      vehicleSync = { schemaVersion = 1, enabled = true, vehicles = {} },
    },
    probes = {
      vehicleSync = {
        managed = 0, held = 0, released = 0, faults = 0,
        reports = 0, reportedReleases = {},
      },
    },
  }
  local runtime = vehicleSyncRuntimeModule.new({
    getState = function() return current end,
    diagnosticLog = function() end,
    component = function(localId)
      if localId == 60 then return transportVehicle end
    end,
    clockSnapshot = function()
      return { time = currentTime, gameSpeed = currentSpeed }
    end,
    commandFactory = function(name)
      assert(name == "setUserStopped")
      return function(localId, stopped) return { localId = localId, stopped = stopped } end
    end,
    authorizeCommand = function(tag) return tag == 8 end,
    sendCommand = function(command, callback)
      commands[#commands + 1] = util.deepCopy(command)
      transportVehicle.userStopped = command.stopped
      callback(command, true)
      return true
    end,
    emit = function(kind, payload)
      emitted[#emitted + 1] = { kind = kind, payload = util.deepCopy(payload) }
      return true, { local_seq = #emitted }
    end,
  })
  runtime.update()
  assert(#commands == 0, "en-route synchronized vehicle was mutated")
  transportVehicle.state = 2
  current.tick = 2
  runtime.update()
  assert(#commands == 1 and commands[1].stopped == true
      and emitted[1].payload.state == "held" and emitted[1].payload.round == 1,
    "first terminal arrival was not held and reported")
  local releaseOk = runtime.applyRelease({
    type = "vehicle.sync_release",
    vehicleCid = "vehicle:event:test:1",
    lineCid = "line:event:test:1",
    round = 1,
    stopIndex = 0,
    releaseAtGameTime = 12,
    releaseWhilePaused = false,
  })
  assert(releaseOk == true, "ordered station release was rejected")
  currentTime, current.tick = 11, 3
  runtime.update()
  assert(#commands == 1, "vehicle released before its simulation-time target")
  currentTime, current.tick = 12, 4
  runtime.update()
  assert(#commands == 2 and commands[2].stopped == false
      and emitted[#emitted].payload.state == "released",
    "vehicle did not release/report at the ordered target")
  local digestView = vehicleSyncRuntimeModule.digestView(current.world)
  assert(digestView.vehicles[1].lastAuthorizedRound == 1
      and digestView.vehicles[1].stopIndex == 0,
    "authorized vehicle leg is absent from the convergence view")
  transportVehicle.state, current.tick = 1, 5
  runtime.update()
  transportVehicle.state, transportVehicle.stopIndex, current.tick = 2, 1, 6
  runtime.update()
  assert(commands[#commands].stopped == true
      and emitted[#emitted].payload.round == 2
      and emitted[#emitted].payload.stopIndex == 1,
    "next station did not advance the canonical vehicle round")
  transportVehicle.state, current.tick = 1, 7
  runtime.update()
  assert(emitted[#emitted].payload.state == "fault"
      and current.probes.vehicleSync.faults == 1,
    "departure before authority release did not fault closed")
  api = priorApi
end

print("PASS runtime config/state, proposal, intent, clock, validation, native authority, and GUI module boundaries")
