local project = assert(arg[1], "project root argument required"):gsub("\\", "/")
package.path = project .. "/tpf2_mp_1/res/scripts/?.lua;" .. package.path

local runtimeConfig = require "tpf2_mp/runtime_config"
local stateSchema = require "tpf2_mp/state_schema"
local nativeHook = require "tpf2_mp/native_hook"
local guiState = require "tpf2_mp/gui_state"
local guiView = require "tpf2_mp/gui_view"
local guiCaptureModule = require "tpf2_mp/gui_capture"
local proposalRuntimeModule = require "tpf2_mp/proposal_runtime"
local networkIntentRuntimeModule = require "tpf2_mp/network_intent_runtime"
local networkClockRuntimeModule = require "tpf2_mp/network_clock_runtime"
local validationRuntimeModule = require "tpf2_mp/validation_runtime"

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
  local current = {
    networkMode = "network",
    initialized = false,
    tick = 240,
    bridge = { peerId = "player1" },
    probes = { networkAuthority = { ready = true } },
  }
  local submissions = 0
  local clock = networkClockRuntimeModule.new({
    getState = function() return current end,
    config = function() return { manualNetwork = true } end,
    diagnosticLog = function() end,
    submitIntent = function(action)
      submissions = submissions + 1
      return action.type == "match.initialise", { local_seq = 9 }
    end,
    awaitingOrder = function() return nil end,
    pendingBarrierReason = function() return nil end,
  })
  clock.maintainManualBootstrap()
  assert(submissions == 1 and clock.manualBootstrap.submitted == true,
    "manual clock bootstrap did not submit the host match intent")
  clock.reset()
  assert(clock.manualBootstrap.attempts == 0 and clock.manualBootstrap.nextAttemptTick == 240,
    "network clock reset did not restore bootstrap defaults")
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
  }
  local cfg = runtimeConfig.read({
    source = {
      protocolVersion = 3,
      localProxyEnabled = true,
      maxEpochs = 12,
    },
    environment = function(name) return environment[name] end,
  })
  assert(cfg.protocol == 3 and cfg.startNetwork == true, "injected network configuration was lost")
  assert(cfg.peerId == "player2" and cfg.sessionId == "injected-session",
    "injected peer/session identity was lost")
  assert(cfg.root == "C:/bridge/injected" and cfg.startingCash == 75000000,
    "injected bridge/economy configuration was lost")
  assert(cfg.localProxy == false, "network mode must disable the local proxy")
end

do
  local versions = { stateVersion = 19, checkpointVersion = 2 }
  local cfg = baseConfig()
  local first = stateSchema.new(cfg, versions)
  local second = stateSchema.new(cfg, versions)
  first.world.logicalOwners.test = "company:1"
  assert(second.world.logicalOwners.test == nil, "new states share mutable nested tables")
  assert(first.version == 19 and first.checkpoint.version == 2,
    "new state did not retain its schema versions")
  assert(first.networkMode == "network" and first.bridge.peerId == "player1",
    "new state did not retain its runtime identity")

  first.version = 7
  first.world.networkClock = nil
  first.probes.operational = nil
  local migrated = stateSchema.migrate(first, {
    newState = function() return stateSchema.new(cfg, versions) end,
    config = function() return cfg end,
    stateVersion = 19,
    checkpointVersion = 2,
  })
  assert(migrated.version == 19 and migrated.world.networkClock.generation == 0,
    "migration did not restore current clock/schema defaults")
  assert(type(migrated.probes.operational.samples) == "table",
    "migration did not restore operational telemetry defaults")
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

print("PASS runtime config/state, proposal, intent, clock, validation, native authority, and GUI module boundaries")
