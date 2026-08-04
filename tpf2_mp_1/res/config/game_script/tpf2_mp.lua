local util = require "tpf2_mp/util"
local json = require "tpf2_mp/json"
local hash = require "tpf2_mp/hash"
local canonical = require "tpf2_mp/canonical"
local economy = require "tpf2_mp/economy"
local bridge = require "tpf2_mp/bridge"
local finance = require "tpf2_mp/finance"
local world = require "tpf2_mp/world"
local proposalCodec = require "tpf2_mp/proposal_codec"
local operationCodec = require "tpf2_mp/operation_codec"
local edgeOwnership = require "tpf2_mp/edge_ownership"

local SCRIPT_FILE = "tpf2_mp.lua"
local EVENT_ID = "tpf2mp"
local STATE_VERSION = 19
local CHECKPOINT_VERSION = 2
local EVENT_RECORD_VERSION = 1

local function oneShotValidationConfig()
  if not (io and io.open and os and os.getenv) then return nil end
  local ok, result = pcall(function()
    local temp = os.getenv("TEMP") or "."
    local base = temp .. "/tpf2mp_bridge/auto-live"
    local marker = io.open(base .. "/enable", "r")
    if not marker then return nil end
    marker:close()
    return { root = base .. "/player1", peerId = "player1", sessionId = "auto-live" }
  end)
  return ok and result or nil
end

local function processEnvironment(name)
  if not (os and os.getenv) then return nil end
  local ok, value = pcall(os.getenv, name)
  if ok and value and value ~= "" then return value end
  return nil
end

local function processEnvironmentEnabled(name)
  local value = processEnvironment(name)
  if value == nil then return false end
  value = string.lower(tostring(value))
  return value == "1" or value == "true" or value == "yes" or value == "on"
end

local function bridgeMarkerExists(root, name)
  if not (io and io.open) then return false end
  if type(root) ~= "string" or root == "" or type(name) ~= "string"
    or not name:match("^[%w_.%-]+$") then return false end
  local file = io.open(root .. "/launcher/" .. name, "rb")
  if not file then return false end
  file:close()
  return true
end

local function writeBridgeMarker(root, name, content)
  if not (io and io.open) then return false, "Lua file IO is unavailable" end
  if type(root) ~= "string" or root == "" or type(name) ~= "string"
    or not name:match("^[%w_.%-]+$") then return false, "invalid bridge marker" end
  local file, err = io.open(root .. "/launcher/" .. name, "wb")
  if not file then return false, tostring(err) end
  file:write(tostring(content or "ready"))
  file:close()
  return true
end

local function config()
  local source = game and game.config and game.config.tpf2mp or {}
  local forced = oneShotValidationConfig()
  -- app.startGame() creates a default test world without necessarily running
  -- an installed mod's runFn. Read the same explicit process overrides here so
  -- injected/unattended worlds still receive an isolated peer, bridge, and
  -- validation mode. In normal games mod.lua has already populated `source`.
  local root = tostring((forced and forced.root) or processEnvironment("TPF2MP_BRIDGE_DIR")
    or source.bridgeDir or ".")
  local manualNetwork = source.manualNetwork == true
    or processEnvironmentEnabled("TPF2MP_MANUAL_NETWORK")
  local networkValidationRequested = source.networkAutoValidate == true
    or processEnvironmentEnabled("TPF2MP_NETWORK_AUTOTEST")
  local networkRuntimeRequested = networkValidationRequested or manualNetwork
  -- The two-process validator and the human lab use the same exact processes.
  -- Once PowerShell has independently accepted both validation records it
  -- writes this per-peer marker. Both Lua states then leave validator-only GUI
  -- handling without weakening the native command gates or unfreezing autonomy.
  local networkManualHandoff = networkValidationRequested
    and bridgeMarkerExists(root, "manual-handoff")
  local networkAutoValidate = networkValidationRequested and not networkManualHandoff
  local operationalCapture = source.operationalCapture == true
    or processEnvironmentEnabled("TPF2MP_OPERATIONAL_CAPTURE")
  local startNetwork = source.startNetwork == true
    or processEnvironmentEnabled("TPF2MP_START_NETWORK") or networkAutoValidate or manualNetwork
  local localProxy = source.localProxyEnabled ~= false
  if networkRuntimeRequested then localProxy = false end
  return {
    protocol = tonumber(source.protocolVersion) or 1,
    root = root,
    peerId = tostring((forced and forced.peerId) or processEnvironment("TPF2MP_PEER_ID")
      or source.peerId or "player1"),
    sessionId = tostring((forced and forced.sessionId) or processEnvironment("TPF2MP_SESSION_ID")
      or source.sessionId or "local-dev"),
    updateStride = math.max(1, tonumber(source.updateStride) or 15),
    networkBridgeStride = math.max(1, tonumber(
      processEnvironment("TPF2MP_NETWORK_BRIDGE_STRIDE")
        or source.networkBridgeStride) or 1),
    maxEvents = math.max(32, tonumber(source.maxEvents) or 512),
    autoFreeze = source.autoFreeze == true or networkRuntimeRequested or operationalCapture,
    neutralizer = source.journalNeutralizerEnabled == true,
    startNetwork = startNetwork,
    localProxy = localProxy,
    pauseOnSwitch = not forced and not networkRuntimeRequested and not operationalCapture
      and source.pauseOnSwitch ~= false,
    autoValidate = forced ~= nil or source.autoValidate == true
      or processEnvironmentEnabled("TPF2MP_AUTOVALIDATE"),
    networkAutoValidate = networkAutoValidate,
    networkManualHandoff = networkManualHandoff,
    manualNetwork = manualNetwork,
    operationalCapture = operationalCapture,
    operationalSampleTicks = math.max(30, util.integer(
      processEnvironment("TPF2MP_OPERATIONAL_SAMPLE_TICKS")
        or source.operationalSampleTicks, 120)),
    networkSoakTicks = math.max(60, util.integer(
      processEnvironment("TPF2MP_NETWORK_SOAK_TICKS") or source.networkSoakTicks, 300)),
    startingCash = math.max(0, util.integer(
      processEnvironment("TPF2MP_STARTING_CASH") or source.startingCash, 5000000)),
    maxEpochs = math.max(0, util.integer(source.maxEpochs, 24)),
    valuationTargetCents = math.max(0, util.integer(source.valuationTargetCents, 50000000)),
  }
end

local function newState()
  local cfg = config()
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

local state = newState()
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
local MAX_DEFERRED_NETWORK_INTENTS = 32
local deferredNetworkIntents = {}
local networkIntentAwaitingOrder = nil
local proposalPreparation = {
  pending = {},
  -- Vanilla line commands are allowed to finish on their initiating machine
  -- so the stock Line Manager receives the real entity/revision its callback
  -- expects. This machine-local table bridges that optimistic result to the
  -- later host-ordered operation. Only an opaque token crosses the wire.
  originAppliedOperations = {},
  nextOriginToken = 1,
}
local networkClock = {
  manualBootstrap = { nextAttemptTick = 240, attempts = 0, submitted = false },
}

local function diagnosticLog(event, values)
  local record = { event = tostring(event), stateVersion = STATE_VERSION }
  for key, value in pairs(values or {}) do
    local valueType = type(value)
    if valueType == "string" or valueType == "number" or valueType == "boolean" then record[key] = value end
  end
  local ok, encoded = pcall(json.encode, record)
  print("[TPF2MP] " .. (ok and encoded or tostring(event)))
end

local function compactNativeHookStatus(payload)
  local states = type(payload.luaStates) == "table" and payload.luaStates or {}
  local wrappedStates, commandCalls, registeredStates, observerStates = 0, 0, 0, 0
  local bindings, mirroredBindings = {}, {}
  for _, observed in ipairs(states) do
    if observed.sendCommandWrapped == true then wrappedStates = wrappedStates + 1 end
    if observed.nativeApiRegistered == true then registeredStates = registeredStates + 1 end
    if observed.commandObserverRegistered == true then observerStates = observerStates + 1 end
    commandCalls = commandCalls + math.max(0, tonumber(observed.commandCalls) or 0)
    for _, name in ipairs(type(observed.bindings) == "table" and observed.bindings or {}) do
      if type(name) == "string" then bindings[name] = true end
    end
    for _, name in ipairs(type(observed.mirroredBindings) == "table" and observed.mirroredBindings or {}) do
      if type(name) == "string" then mirroredBindings[name] = true end
    end
  end
  local bindingNames = util.sortedKeys(bindings)
  local mirroredBindingNames = util.sortedKeys(mirroredBindings)
  local validation = type(payload.validation) == "table" and payload.validation or {}
  local hooks = type(payload.hooks) == "table" and payload.hooks or {}
  local setup = type(payload.setupCommandInterface) == "table" and payload.setupCommandInterface or {}
  local gates = type(payload.gates) == "table" and payload.gates or {}
  local buildGate = type(gates.buildProposal) == "table" and gates.buildProposal or {}
  local commandGate = type(gates.commandVisitors) == "table" and gates.commandVisitors or {}
  local commandList = type(payload.commandList) == "table" and payload.commandList or {}
  local applyCommand = type(payload.applyCommand) == "table" and payload.applyCommand or {}
  local rawCommandEvents = type(payload.commandEvents) == "table" and payload.commandEvents or {}
  local function compactTagCounts(value)
    local result = {}
    for _, entry in ipairs(type(value) == "table" and value or {}) do
      if type(entry) == "table" then
        result[#result + 1] = {
          tag = tonumber(entry.tag),
          name = tostring(entry.name or "unknown"),
          count = math.max(0, tonumber(entry.count) or 0),
        }
      end
    end
    return result
  end
  local commandEvents = {}
  local firstEvent = math.max(1, #rawCommandEvents - 31)
  for index = firstEvent, #rawCommandEvents do
    local event = rawCommandEvents[index]
    if type(event) == "table" then
      commandEvents[#commandEvents + 1] = {
        localSequence = tonumber(event.localSequence),
        batch = tonumber(event.batch),
        index = tonumber(event.index),
        tag = tonumber(event.tag),
        name = tostring(event.name or "unknown"),
        success = event.success == true and true or event.success == false and false or nil,
      }
    end
  end
  return {
    available = true,
    schemaVersion = tonumber(payload.schemaVersion),
    hookVersion = tostring(payload.hookVersion or "unknown"),
    profile = tostring(payload.profile or "unknown"),
    stage = tostring(payload.stage or "unknown"),
    active = payload.active == true,
    scope = tostring(payload.scope or "unknown"),
    lastError = tostring(payload.lastError or ""),
    validation = {
      valid = validation.valid == true,
      observedSha256 = tostring(validation.observedSha256 or ""),
      signatureCount = #(type(validation.signatures) == "table" and validation.signatures or {}),
    },
    hooks = {
      enabled = hooks.enabled == true,
      luaPrint = hooks.luaPrint == true,
      luaSetField = hooks.luaSetField == true,
      setupCommandInterface = hooks.setupCommandInterface == true,
      commandListSwap = hooks.commandListSwap == true,
      applyCommand = hooks.applyCommand == true,
      buildProposalVisitor = hooks.buildProposalVisitor == true,
      authorityCommandVisitors = math.max(0, tonumber(hooks.authorityCommandVisitors) or 0),
      sendCommandWrapping = hooks.sendCommandWrapping == true,
    },
    setupCalls = math.max(0, tonumber(setup.calls) or 0),
    luaStateCount = #states,
    nativeApiStateCount = registeredStates,
    wrappedStateCount = wrappedStates,
    commandObserverStateCount = observerStates,
    commandCalls = commandCalls,
    bindings = bindingNames,
    mirroredBindings = mirroredBindingNames,
    commandList = {
      swapCalls = math.max(0, tonumber(commandList.swapCalls) or 0),
      nonEmptyBatches = math.max(0, tonumber(commandList.nonEmptyBatches) or 0),
      commands = math.max(0, tonumber(commandList.commands) or 0),
      invalidLayouts = math.max(0, tonumber(commandList.invalidLayouts) or 0),
      unknownTags = math.max(0, tonumber(commandList.unknownTags) or 0),
      lastBatchCount = math.max(0, tonumber(commandList.lastBatchCount) or 0),
      lastBatchId = math.max(0, tonumber(commandList.lastBatchId) or 0),
      pendingCommands = math.max(0, tonumber(commandList.pendingCommands) or 0),
      pendingOverwrites = math.max(0, tonumber(commandList.pendingOverwrites) or 0),
      tagCounts = compactTagCounts(commandList.tagCounts),
    },
    applyCommand = {
      calls = math.max(0, tonumber(applyCommand.calls) or 0),
      succeeded = math.max(0, tonumber(applyCommand.succeeded) or 0),
      failed = math.max(0, tonumber(applyCommand.failed) or 0),
      unknown = math.max(0, tonumber(applyCommand.unknown) or 0),
      unknownTags = math.max(0, tonumber(applyCommand.unknownTags) or 0),
      direct = math.max(0, tonumber(applyCommand.direct) or 0),
      tagMismatches = math.max(0, tonumber(applyCommand.tagMismatches) or 0),
      filteredScriptEvents = math.max(0, tonumber(applyCommand.filteredScriptEvents) or 0),
      lastTag = tonumber(applyCommand.lastTag),
      lastTagName = tostring(applyCommand.lastTagName or "unknown"),
      tagCounts = compactTagCounts(applyCommand.tagCounts),
    },
    commandEvents = commandEvents,
    commandEventFilter = tostring(payload.commandEventFilter or "unknown"),
    gates = {
      buildProposal = {
        enabled = buildGate.enabled == true,
        authorizations = math.max(0, tonumber(buildGate.authorizations) or 0),
        allowed = math.max(0, tonumber(buildGate.allowed) or 0),
        suppressed = math.max(0, tonumber(buildGate.suppressed) or 0),
        calls = math.max(0, tonumber(buildGate.calls) or 0),
        tagMismatches = math.max(0, tonumber(buildGate.tagMismatches) or 0),
        lastTag = tonumber(buildGate.lastTag),
        lastThread = math.max(0, tonumber(buildGate.lastThread) or 0),
      },
      commandVisitors = {
        enabled = commandGate.enabled == true,
        hooked = math.max(0, tonumber(commandGate.hooked) or 0),
        tagMismatches = math.max(0, tonumber(commandGate.tagMismatches) or 0),
        pendingTotal = math.max(0, tonumber(commandGate.pendingTotal) or 0),
        allowedTotal = math.max(0, tonumber(commandGate.allowedTotal) or 0),
        suppressedTotal = math.max(0, tonumber(commandGate.suppressedTotal) or 0),
        gatedTags = compactTagCounts(commandGate.gatedTags),
        pending = compactTagCounts(commandGate.pending),
        allowed = compactTagCounts(commandGate.allowed),
        suppressed = compactTagCounts(commandGate.suppressed),
        calls = compactTagCounts(commandGate.calls),
      },
    },
  }
end

local function nativeHookStatus()
  local fn = rawget(_G, "tpf2mp_native_status")
  if type(fn) ~= "function" then return { available = false } end
  local ok, payload = pcall(fn)
  if not ok then return { available = true, error = tostring(payload) } end
  if type(payload) == "table" then
    return compactNativeHookStatus(payload)
  end
  if type(payload) == "string" then
    local decodedOk, decoded = pcall(json.decode, payload)
    if decodedOk and type(decoded) == "table" then
      return compactNativeHookStatus(decoded)
    end
    return { available = true, error = "native status JSON decode failed", raw = payload:sub(1, 512) }
  end
  return { available = true, error = "native status returned " .. type(payload) }
end

local function validatedNetworkAuthority(nativeStatus)
  nativeStatus = type(nativeStatus) == "table" and nativeStatus or {}
  local nativeGates = type(nativeStatus.gates) == "table" and nativeStatus.gates or {}
  local buildStatus = type(nativeGates.buildProposal) == "table"
    and nativeGates.buildProposal or {}
  local commandStatus = type(nativeGates.commandVisitors) == "table"
    and nativeGates.commandVisitors or {}
  local nativeValidation = type(nativeStatus.validation) == "table"
    and nativeStatus.validation or {}
  local nativeHooks = type(nativeStatus.hooks) == "table" and nativeStatus.hooks or {}
  local ready = nativeStatus.available == true
    and nativeStatus.active == true
    and nativeValidation.valid == true
    and nativeHooks.enabled == true
    and nativeHooks.buildProposalVisitor == true
    and (tonumber(nativeHooks.authorityCommandVisitors) or 0) == 23
    and buildStatus.enabled == true
    and (tonumber(buildStatus.tagMismatches) or 0) == 0
    and commandStatus.enabled == true
    and (tonumber(commandStatus.hooked) or 0) == 23
    and (tonumber(commandStatus.tagMismatches) or 0) == 0
  return ready, {
    buildGateEnabled = buildStatus.enabled == true,
    commandGateEnabled = commandStatus.enabled == true,
    commandVisitors = tonumber(commandStatus.hooked) or 0,
  }
end

local function markNativeContext(context)
  local fn = rawget(_G, "tpf2mp_native_mark_context")
  if type(fn) ~= "function" then return false end
  return pcall(fn, tostring(context))
end

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

local function freezeNetworkCalendar()
  if state.networkMode ~= "network" then
    state.probes.networkCalendar = { frozen = false, requested = false, standalone = true }
    return true
  end
  local factory = util.commandFactory("setCalendarSpeed")
  local authorize = rawget(_G, "tpf2mp_native_authorize_command")
  if not factory or type(authorize) ~= "function"
    or not (api and api.cmd and type(api.cmd.sendCommand) == "function") then
    local message = "network mode requires an authorized setCalendarSpeed command to freeze native finance drift"
    state.probes.networkCalendar = { frozen = false, requested = false, error = message }
    return false, message
  end
  local authorized, authorizeError = pcall(authorize, "1")
  if not authorized then
    local message = "could not authorize the network calendar freeze: " .. tostring(authorizeError)
    state.probes.networkCalendar = { frozen = false, requested = false, error = message }
    return false, message
  end
  local made, commandOrError = pcall(factory, 0)
  if not made then
    local message = "could not create the network calendar freeze command: " .. tostring(commandOrError)
    state.probes.networkCalendar = { frozen = false, requested = false, error = message }
    return false, message
  end
  local sent, sendError = util.sendCommand(
    commandOrError, nil, "mod.network.freeze-calendar")
  if not sent then
    local message = "could not issue the network calendar freeze command: " .. tostring(sendError)
    state.probes.networkCalendar = { frozen = false, requested = true, error = message }
    return false, message
  end
  state.probes.networkCalendar = {
    frozen = true,
    requested = true,
    speed = 0,
    commandTag = 1,
    tick = state.tick,
  }
  return true
end

local function migrate(saved)
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
  saved.economy = saved.economy or economy.newState()
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

local function economyDigestView()
  local markets, services = {}, {}
  for _, cid in ipairs(util.sortedKeys(state.economy.markets)) do
    local value = state.economy.markets[cid]
    markets[cid] = {
      cid = value.cid,
      name = value.name,
      demand = value.demand,
      outsideWeight = value.outsideWeight,
      metadata = util.deepCopy(value.metadata or {}),
    }
  end
  for _, cid in ipairs(util.sortedKeys(state.economy.services)) do
    local value = state.economy.services[cid]
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
    version = state.economy.version,
    epoch = state.economy.epoch,
    markets = markets,
    services = services,
    lastResults = util.deepCopy(state.economy.lastResults),
    ledger = util.deepCopy(state.economy.ledger),
  }
end

local function authoredStateSnapshot()
  local companies = {}
  for _, cid in ipairs(util.sortedKeys(state.companies)) do
    companies[cid] = { cid = cid, name = state.companies[cid].name }
  end
  -- Local engine ticks are diagnostic clocks, not authored match state. Two
  -- machines can consume the same ordered command on different update ticks.
  -- Keep lifecycle ticks in saves/research, but exclude them from convergence.
  local match = state.match or {}
  local authoredMatch = {
    status = match.status,
    winnerCid = match.winnerCid,
    finishReason = match.finishReason,
    rules = util.deepCopy(match.rules or {}),
  }
  return {
    initialized = state.initialized,
    match = authoredMatch,
    companies = companies,
    companyOrder = util.deepCopy(state.companyOrder),
    economy = economyDigestView(),
    networkFinance = finance.networkDigestView(state.finance),
    autonomyFrozen = state.world.autonomyFrozen,
  }
end

local function authoredDigest()
  return hash.value(authoredStateSnapshot())
end

local function coreStateSnapshot()
  local result = authoredStateSnapshot()
  result.canonical = canonical.digestView(state.canonical)
  return result
end

local function coreDigest()
  return hash.value(coreStateSnapshot())
end

local function trimEvents()
  local maximum = config().maxEvents
  while #state.eventLog.items > maximum do table.remove(state.eventLog.items, 1) end
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
  if state.networkMode == "network" then
    local view = finance.networkDigestView(state.finance)
    if view.initialized ~= true then
      return nil, "canonical network accounts are not initialised"
    end
    return { companies = util.deepCopy(view.accounts) }
  end
  local companies = {}
  for _, companyCid in ipairs(util.sortedKeys(state.companies or {})) do
    local company = state.companies[companyCid]
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
  local canonicalView = canonical.digestView(state.canonical)
  local financial, financialError = checkpointFinancialSnapshot()
  if not financial then
    state.checkpoint.lastError = tostring(financialError)
    return false, state.checkpoint.lastError
  end
  local items = state.eventLog.items or {}
  local nextEventSeq = state.eventLog.nextSeq or 1
  local firstRetainedSeq = #items > 0 and items[1].seq or nextEventSeq
  local lastEventSeq = nextEventSeq - 1
  local structuralDigest = state.probes.structural and state.probes.structural.digest or nil
  local worldManifestDigest = state.probes.worldManifest and state.probes.worldManifest.digest or nil
  local lastCommitSeq = tonumber(boundarySeq)
  if lastCommitSeq then
    lastCommitSeq = math.max(0, util.integer(lastCommitSeq, 0))
  else
    lastCommitSeq = math.max(0, (state.bridge.nextInSeq or 1) - 1)
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
    protocol = state.bridge.protocol,
    sessionId = state.bridge.sessionId,
    peerId = state.bridge.peerId,
    networkMode = state.networkMode,
    tick = state.tick,
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
  local ok, outbound = bridge.emit(state.bridge, "checkpoint", payload, state.tick)
  state.checkpoint.exports = (state.checkpoint.exports or 0) + (ok and 1 or 0)
  state.checkpoint.lastLocalSeq = ok and outbound.local_seq or state.checkpoint.lastLocalSeq
  state.checkpoint.lastDigest = ok and payload.checkpointDigest or state.checkpoint.lastDigest
  state.checkpoint.lastModelDigest = ok and payload.modelDigest or state.checkpoint.lastModelDigest
  state.checkpoint.lastEventSeq = ok and lastEventSeq or state.checkpoint.lastEventSeq
  state.checkpoint.lastReason = tostring(reason or "manual")
  state.checkpoint.lastError = ok and nil or tostring(outbound)
  state.checkpoint.lastConvergenceKey = ok and payload.convergenceKey
    or state.checkpoint.lastConvergenceKey
  state.checkpoint.lastCoreDigest = ok and payload.coreDigest or state.checkpoint.lastCoreDigest
  state.checkpoint.lastFinancialDigest = ok and payload.financialDigest
    or state.checkpoint.lastFinancialDigest
  state.checkpoint.lastBoundarySeq = ok and lastCommitSeq or state.checkpoint.lastBoundarySeq
  return ok, ok and {
    localSeq = outbound.local_seq,
    checkpointDigest = payload.checkpointDigest,
    convergenceKey = payload.convergenceKey,
    modelDigest = payload.modelDigest,
    coreDigest = payload.coreDigest,
    financialDigest = payload.financialDigest,
    lastEventSeq = lastEventSeq,
  } or state.checkpoint.lastError
end

local function exportCheckpointBarrier(boundarySeq, reason, proposalId)
  boundarySeq = math.max(1, util.integer(boundarySeq, 0))
  local key = tostring(boundarySeq)
  local barriers = state.world.checkpointConsensus
  local record = barriers.byBoundary[key]
  if not record then
    record = {
      boundarySeq = boundarySeq,
      reason = tostring(reason),
      proposalId = proposalId and tostring(proposalId) or nil,
      status = "pending",
      exported = false,
      tick = state.tick,
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
  local ok, result = bridge.emit(state.bridge, "event", payload, state.tick)
  if not ok then state.checkpoint.lastError = tostring(result) end
  return ok, result
end

local balanceOf
local accountOf

local function refreshOwnershipProbe()
  state.probes.ownership = world.ownershipSummary(state.world, state.companies)
  return state.probes.ownership
end

local function publicSnapshot()
  local cid, company = activeCompany()
  local ownership = state.probes.ownership or refreshOwnershipProbe()
  local proxyBalanceDelta = 0
  if state.world.proxyMode and state.world.turn and state.world.turn.active then
    local currentProxyBalance = balanceOf and balanceOf(state.world.controlPlayerId) or nil
    if currentProxyBalance and state.world.turn.balanceStart then
      proxyBalanceDelta = currentProxyBalance - state.world.turn.balanceStart
    end
  end
  local publicCompanies = {}
  for _, companyCid in ipairs(util.sortedKeys(state.companies)) do
    local nativeBalance = balanceOf and balanceOf(state.companies[companyCid].playerId) or nil
    local nativeAccount = accountOf and accountOf(state.companies[companyCid].playerId) or {}
    local canonicalAccount = state.networkMode == "network"
      and finance.networkAccount(state.finance, companyCid) or nil
    local publicBalance = canonicalAccount and canonicalAccount.balance or nativeBalance
    publicCompanies[companyCid] = {
      cid = companyCid,
      name = state.companies[companyCid].name,
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
  local first = math.max(1, #state.eventLog.items - 7)
  for index = first, #state.eventLog.items do recent[#recent + 1] = util.deepCopy(state.eventLog.items[index]) end
  local structural = state.probes.structural
  local mobility = state.probes.mobility
  local publicProbes = {
    capabilities = util.deepCopy(state.probes.capabilities),
    guiCapabilities = util.deepCopy(state.probes.guiCapabilities),
    nativeHook = util.deepCopy(state.probes.nativeHook),
    networkAuthority = util.deepCopy(state.probes.networkAuthority),
    networkCalendar = util.deepCopy(state.probes.networkCalendar),
    capture = util.deepCopy(state.probes.capture),
    operational = util.deepCopy(state.probes.operational),
    lastError = state.probes.lastError,
    structuralDigest = structural and structural.digest or nil,
    worldManifestDigest = state.probes.worldManifest and state.probes.worldManifest.digest or nil,
    worldManifest = state.probes.worldManifest and {
      total = state.probes.worldManifest.total,
      uniqueBound = state.probes.worldManifest.uniqueBound,
      deferredUnique = state.probes.worldManifest.deferredUnique,
      ambiguousCount = state.probes.worldManifest.ambiguousCount,
      digest = state.probes.worldManifest.digest,
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
    version = state.version,
    tick = state.tick,
    initialized = state.initialized,
    match = util.deepCopy(state.match),
    networkMode = state.networkMode,
    peerId = state.bridge.peerId,
    sessionId = state.bridge.sessionId,
    activeCompanyCid = cid,
    activeCompanyName = company and company.name or nil,
    companies = publicCompanies,
    companyOrder = util.deepCopy(state.companyOrder),
    marketCount = util.tableCount(state.economy.markets),
    serviceCount = util.tableCount(state.economy.services),
    epoch = state.economy.epoch,
    lastResults = util.deepCopy(state.economy.lastResults),
    ledger = util.deepCopy(state.economy.ledger),
    scoreboard = economy.scoreboard(state.economy, state.companies),
    autonomyFrozen = state.world.autonomyFrozen,
    neutralizer = util.deepCopy(state.finance.neutralizer),
    transfers = util.deepCopy(state.finance.transfers),
    startingCash = util.deepCopy(state.finance.startingCash),
    networkAccounts = util.deepCopy(state.finance.networkAccounts),
    networkClock = util.deepCopy(state.world.networkClock),
    proxyMode = state.world.proxyMode == true,
    controlAccount = state.world.controlPlayerId and accountOf and accountOf(state.world.controlPlayerId) or nil,
    turn = util.deepCopy(state.world.turn),
    lastTransition = util.deepCopy(state.world.lastTransition),
    ownership = util.deepCopy(ownership),
    proposals = {
      queued = state.world.proposals.queued or 0,
      applied = state.world.proposals.applied or 0,
      failed = state.world.proposals.failed or 0,
      retained = util.tableCount(state.world.proposals.byId),
    },
    operations = {
      queued = state.world.operations.queued or 0,
      applied = state.world.operations.applied or 0,
      failed = state.world.operations.failed or 0,
      retained = util.tableCount(state.world.operations.byId),
    },
    proposalConsensus = {
      completed = state.world.proposalConsensus.completed or 0,
      failed = state.world.proposalConsensus.failed or 0,
      pending = (function()
        local count = 0
        for _, item in pairs(state.world.proposalConsensus.byId or {}) do
          if item.status == "pending" then count = count + 1 end
        end
        return count
      end)(),
      lastOutcome = util.deepCopy(state.world.proposalConsensus.lastOutcome),
      sessionFault = util.deepCopy(state.world.proposalConsensus.sessionFault),
    },
    operationConsensus = {
      completed = state.world.operationConsensus.completed or 0,
      failed = state.world.operationConsensus.failed or 0,
      pending = (function()
        local count = 0
        for _, item in pairs(state.world.operationConsensus.byId or {}) do
          if item.status == "pending" then count = count + 1 end
        end
        return count
      end)(),
      lastOutcome = util.deepCopy(state.world.operationConsensus.lastOutcome),
      sessionFault = util.deepCopy(state.world.operationConsensus.sessionFault),
    },
    checkpointConsensus = {
      completed = state.world.checkpointConsensus.completed or 0,
      failed = state.world.checkpointConsensus.failed or 0,
      pending = (function()
        local count = 0
        for _, item in pairs(state.world.checkpointConsensus.byBoundary or {}) do
          if item.status == "pending" then count = count + 1 end
        end
        return count
      end)(),
      lastOutcome = util.deepCopy(state.world.checkpointConsensus.lastOutcome),
      lastAgreed = util.deepCopy(state.world.checkpointConsensus.lastAgreed),
    },
    deferredNetworkIntent = deferredNetworkIntents[1] and {
      type = deferredNetworkIntents[1].action and deferredNetworkIntents[1].action.type or nil,
      companyCid = deferredNetworkIntents[1].companyCid,
      queuedTick = deferredNetworkIntents[1].queuedTick,
      reason = deferredNetworkIntents[1].reason,
      queueDepth = #deferredNetworkIntents,
      capacity = MAX_DEFERRED_NETWORK_INTENTS,
    } or nil,
    deferredNetworkQueue = {
      count = #deferredNetworkIntents,
      capacity = MAX_DEFERRED_NETWORK_INTENTS,
      awaitingOrder = networkIntentAwaitingOrder and {
        localSeq = networkIntentAwaitingOrder.localSeq,
        type = networkIntentAwaitingOrder.type,
        emittedTick = networkIntentAwaitingOrder.emittedTick,
      } or nil,
    },
    bridge = {
      nextOutSeq = state.bridge.nextOutSeq,
      nextInSeq = state.bridge.nextInSeq,
      emitted = state.bridge.emitted,
      received = state.bridge.received,
      lastError = state.bridge.lastError,
      lastInboundKind = state.bridge.lastInboundKind,
      companion = util.deepCopy(state.bridge.companion),
    },
    checkpoint = util.deepCopy(state.checkpoint),
    recovery = util.deepCopy(state.recovery),
    canonicalCount = util.tableCount(state.canonical.byCanonical),
    digest = coreDigest(),
    modelDigest = authoredDigest(),
    probes = publicProbes,
    validation = util.deepCopy(state.validation),
    recentEvents = recent,
    lastAction = util.deepCopy(state.lastAction),
    lastResult = util.deepCopy(state.lastResult),
    lastError = state.lastError,
  }
end

local function publishSnapshot()
  -- The game regularly calls the GUI state's load callback with the engine
  -- script's shared save state. Avoid serialising the same snapshot as a
  -- second command event; the load callback updates gui.snapshot.
  return true
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

local function normaliseMatchRules(rules)
  rules = type(rules) == "table" and rules or {}
  local cfg = config()
  return {
    startingCash = math.max(0, util.integer(rules.startingCash, cfg.startingCash)),
    maxEpochs = math.max(0, util.integer(rules.maxEpochs, cfg.maxEpochs)),
    valuationTargetCents = math.max(0, util.integer(rules.valuationTargetCents, cfg.valuationTargetCents)),
  }
end

local function initialiseMatch(rules)
  if state.initialized then return false, "match is already initialised" end
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
  local worldManifest = world.canonicalManifest(state.canonical)
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
  state.match = {
    status = "running",
    startedTick = state.tick,
    finishedTick = nil,
    winnerCid = nil,
    finishReason = nil,
    rules = matchRules,
  }
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
    funding = funding,
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
  local first = state.companyOrder[1]
  local second = state.companyOrder[2]
  if not first or not second then return false, "initialise the match first" end
  economy.upsertMarket(state.economy, {
    cid = "market:prototype-corridor",
    name = "Prototype intercity corridor",
    demand = 1000,
    outsideWeight = 2500,
  })
  economy.upsertService(state.economy, {
    lineCid = "line:prototype-company-1",
    marketCid = "market:prototype-corridor",
    companyCid = first,
    name = state.companies[first].name .. " service",
    headwaySeconds = 900,
    journeySeconds = 2400,
    fareCents = 1000,
    capacity = 600,
    quality = 100,
  })
  economy.upsertService(state.economy, {
    lineCid = "line:prototype-company-2",
    marketCid = "market:prototype-corridor",
    companyCid = second,
    name = state.companies[second].name .. " service",
    headwaySeconds = 1100,
    journeySeconds = 2200,
    fareCents = 900,
    capacity = 600,
    quality = 100,
  })
  -- Seeding is a setup/preview action, not an authoritative settlement. Run
  -- the evaluator on a copy so opening the demo does not consume an epoch.
  local previewState = util.deepCopy(state.economy)
  local preview = economy.evaluateAll(previewState)
  preview.epoch = state.economy.epoch
  preview.preview = true
  state.economy.lastResults = util.deepCopy(preview)
  return true, preview
end

local function rankedWinner()
  local scores = economy.scoreboard(state.economy, state.companies)
  local ranked = {}
  for _, cid in ipairs(util.sortedKeys(scores)) do ranked[#ranked + 1] = scores[cid] end
  table.sort(ranked, function(a, b)
    if a.modelValueCents ~= b.modelValueCents then return a.modelValueCents > b.modelValueCents end
    if a.settledRevenueCents ~= b.settledRevenueCents then return a.settledRevenueCents > b.settledRevenueCents end
    if a.settledDemand ~= b.settledDemand then return a.settledDemand > b.settledDemand end
    if a.marketWins ~= b.marketWins then return a.marketWins > b.marketWins end
    return a.companyCid < b.companyCid
  end)
  return ranked[1] and ranked[1].companyCid or nil, ranked
end

local function finishMatch(reason, winnerCid)
  if not state.initialized then return false, "initialise the match first" end
  if state.match.status == "finished" then return false, "match is already finished" end
  if winnerCid ~= nil and not state.companies[winnerCid] then return false, "unknown winner company" end
  local rankedWinnerCid, ranked = rankedWinner()
  state.match.status = "finished"
  state.match.finishedTick = state.tick
  state.match.finishReason = tostring(reason or "manual")
  state.match.winnerCid = winnerCid or rankedWinnerCid
  return true, { match = util.deepCopy(state.match), ranking = ranked }
end

local function evaluateMatchEnd()
  if state.match.status ~= "running" then return nil end
  local rules = state.match.rules or {}
  local winnerCid, ranked = rankedWinner()
  local leader = ranked[1]
  local reason
  if util.integer(rules.valuationTargetCents, 0) > 0
    and leader and leader.modelValueCents >= util.integer(rules.valuationTargetCents, 0) then
    reason = "valuation-target"
  elseif util.integer(rules.maxEpochs, 0) > 0 and state.economy.epoch >= util.integer(rules.maxEpochs, 0) then
    reason = "epoch-limit"
  end
  if not reason then return nil end
  local ok, result = finishMatch(reason, winnerCid)
  return ok and result or nil
end

local function requireRunningMatch()
  if not state.initialized then return false, "initialise the match first" end
  if state.match.status ~= "running" then return false, "match is not running" end
  return true
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
  local ownerCid = state.world.logicalOwners
    and state.world.logicalOwners[tostring(localId)] or nil
  if cid then
    local binding = state.canonical.byCanonical[cid]
    if ownerCid and binding then
      binding.metadata = binding.metadata or {}
      binding.metadata.owner = ownerCid
    end
    return cid
  end
  if ownerCid then
    return world.bindExisting(state.canonical, localId, kind, { owner = ownerCid })
  end
  return world.bindExisting(state.canonical, localId, kind)
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

local function setDifference(after, before)
  local result = {}
  for entity in pairs(after or {}) do
    if not (before or {})[entity] then result[#result + 1] = entity end
  end
  table.sort(result)
  return result
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

local function routeProposalFinance(record, observation)
  local companyCid = record.companyCid
  local company = state.companies[companyCid]
  if not company then return false, "proposal company is unavailable" end
  observation = type(observation) == "table" and observation or {}
  local issuerPlayerId = tonumber(record.issuerPlayerId or record.controlPlayerId)
  local nativeOwnerPlayerId = tonumber(record.nativeOwnerPlayerId or issuerPlayerId)
  local walletPlayerId = tonumber(company.playerId)
  local issuerBalanceBefore = tonumber(observation.issuerBalanceBefore or record.balanceBefore)
  local issuerBalanceAfter = tonumber(observation.issuerBalanceAfter)
    or (issuerPlayerId and balanceOf(issuerPlayerId) or nil)
  if not issuerPlayerId or issuerBalanceBefore == nil or issuerBalanceAfter == nil then
    return false, "proposal issuer balance delta is unavailable"
  end
  local issuerDelta = issuerBalanceAfter - issuerBalanceBefore
  local ownerBalanceBefore = tonumber(observation.nativeOwnerBalanceBefore or record.nativeOwnerBalanceBefore)
  local ownerBalanceAfter = tonumber(observation.nativeOwnerBalanceAfter)
    or (nativeOwnerPlayerId and balanceOf(nativeOwnerPlayerId) or nil)
  local nativeOwnerDelta = ownerBalanceBefore and ownerBalanceAfter
    and (ownerBalanceAfter - ownerBalanceBefore) or nil
  local result = {
    companyCid = companyCid,
    issuerPlayerId = issuerPlayerId,
    nativeOwnerPlayerId = nativeOwnerPlayerId,
    walletPlayerId = walletPlayerId,
    issuerDelta = issuerDelta,
    nativeOwnerDelta = nativeOwnerDelta,
    -- Legacy result names remain useful to old research readers.
    controlPlayerId = issuerPlayerId,
    ownerPlayerId = walletPlayerId,
    delta = issuerDelta,
    routed = issuerPlayerId ~= walletPlayerId and issuerDelta ~= 0,
  }
  if result.routed then
    local restored, restoreError = finance.book(issuerPlayerId, -issuerDelta)
    if not restored then return false, "could not restore proposal issuer wallet: " .. tostring(restoreError) end
    local charged, chargeError = finance.book(walletPlayerId, issuerDelta)
    if not charged then
      finance.book(issuerPlayerId, issuerDelta)
      return false, "could not route proposal cost to canonical company: " .. tostring(chargeError)
    end
  end
  result.issuerBalance = balanceOf(issuerPlayerId)
  result.nativeOwnerBalance = balanceOf(nativeOwnerPlayerId)
  result.walletBalance = balanceOf(walletPlayerId)
  if issuerPlayerId == walletPlayerId then
    result.walletDelta = issuerDelta
  elseif nativeOwnerPlayerId == walletPlayerId and nativeOwnerDelta ~= nil then
    -- A remote replay may be charged either to the command issuer or directly
    -- to PlayerOwned by the native command. The canonical wallet effect is the
    -- sum of the observed native-owner delta and any issuer delta routed here.
    result.walletDelta = nativeOwnerDelta + issuerDelta
  else
    -- Standalone proxy: the native desk is neither the permanent company
    -- wallet nor a remote owner, so its complete delta is what was routed.
    result.walletDelta = issuerDelta
  end
  result.controlBalance = result.issuerBalance
  result.ownerBalance = result.walletBalance
  return true, result
end

local function bindProposalOutputs(transaction, eventId, matched, nativeOwnerPlayerId)
  local bound, ownershipBackups = {}, {}
  local privateNodeSlots = {}
  for _, edge in ipairs(transaction.edges or {}) do
    if edge.private then
      for _, reference in ipairs({ edge.node0, edge.node1 }) do
        if type(reference) == "table" and type(reference.slot) == "string" then
          privateNodeSlots[reference.slot] = true
        end
      end
    end
  end
  local function rememberOwnership(localId)
    local key = tostring(localId)
    if ownershipBackups[key] == nil then
      ownershipBackups[key] = {
        logicalOwnerCid = state.world.logicalOwners[key],
        pinnedCustody = util.deepCopy(state.world.pinnedCustody[key]),
      }
    end
    return key
  end
  local function rollback()
    for index = #bound, 1, -1 do canonical.unbindCanonical(state.canonical, bound[index].cid) end
    for key, backup in pairs(ownershipBackups) do
      state.world.logicalOwners[key] = backup.logicalOwnerCid
      state.world.pinnedCustody[key] = util.deepCopy(backup.pinnedCustody)
    end
  end
  for index, node in ipairs(transaction.nodes) do
    local localId = matched.nodes[node.slot]
    local cid = canonical.createdId("node", eventId, index)
    local nodeOwnerCid = privateNodeSlots[node.slot] and transaction.companyCid or nil
    local ok, err = canonical.bind(state.canonical, cid, "node", localId, {
      owner = nodeOwnerCid,
      private = nodeOwnerCid ~= nil,
      proposalDigest = transaction.digest,
      outputSlot = node.slot,
      position = util.deepCopy(node.position),
    })
    if not ok then rollback(); return nil, err end
    bound[#bound + 1] = { kind = "node", cid = cid, localId = localId, slot = node.slot }
    if nodeOwnerCid then
      local key = rememberOwnership(localId)
      state.world.logicalOwners[key] = nodeOwnerCid
    end
  end
  for index, edge in ipairs(transaction.edges) do
    local localId = matched.edges[edge.slot]
    local cid = canonical.createdId("edge", eventId, index)
    local ok, err = canonical.bind(state.canonical, cid, "edge", localId, {
      owner = edge.private and transaction.companyCid or nil,
      carrier = edge.carrier,
      private = edge.private,
      proposalDigest = transaction.digest,
      outputSlot = edge.slot,
    })
    if not ok then rollback(); return nil, err end
    bound[#bound + 1] = { kind = "edge", cid = cid, localId = localId, slot = edge.slot }
    if edge.private then
      local key = rememberOwnership(localId)
      state.world.logicalOwners[key] = transaction.companyCid
      state.world.pinnedCustody[key] = {
        cid = cid,
        kind = "edge",
        logicalOwnerCid = transaction.companyCid,
        nativePlayerId = world.ownerOf(localId) or nativeOwnerPlayerId,
        requestedPlayerId = state.companies[transaction.companyCid].playerId,
        reason = "canonical-proposal-replay",
      }
    end
  end
  for index, object in ipairs(transaction.edgeObjects and transaction.edgeObjects.add or {}) do
    local localId = matched.edgeObjects and matched.edgeObjects[object.slot] or nil
    if not localId then rollback(); return nil, "edge-object output was not matched: " .. object.slot end
    local cid = canonical.createdId("edge_object", eventId, index)
    local ok, err = canonical.bind(state.canonical, cid, "edge_object", localId, {
      owner = object.private and transaction.companyCid or nil,
      private = object.private,
      model = object.model,
      category = object.category,
      proposalDigest = transaction.digest,
      outputSlot = object.slot,
    })
    if not ok then rollback(); return nil, err end
    bound[#bound + 1] = { kind = "edge_object", cid = cid, localId = localId, slot = object.slot }
    if object.private then
      local key = rememberOwnership(localId)
      state.world.logicalOwners[key] = transaction.companyCid
      state.world.pinnedCustody[key] = {
        cid = cid,
        kind = "edge_object",
        logicalOwnerCid = transaction.companyCid,
        nativePlayerId = world.ownerOf(localId) or nativeOwnerPlayerId,
        requestedPlayerId = state.companies[transaction.companyCid].playerId,
        reason = "canonical-edge-object-replay",
      }
    end
  end
  return bound
end

local function retireProposalInputs(transaction, localInputs)
  for _, item in ipairs(localInputs) do
    canonical.unbindCanonical(state.canonical, item.cid)
    state.world.logicalOwners[tostring(item.localId)] = nil
    state.world.pinnedCustody[tostring(item.localId)] = nil
  end
end

local function proposalBindingBackup()
  return {
    byCanonical = util.deepCopy(state.canonical.byCanonical),
    byLocal = util.deepCopy(state.canonical.byLocal),
    revisions = state.canonical.revisions,
    logicalOwners = util.deepCopy(state.world.logicalOwners),
    pinnedCustody = util.deepCopy(state.world.pinnedCustody),
  }
end

local function restoreProposalBindings(backup)
  -- Preserve the registry/world table identities held by the rest of the
  -- game script while restoring their complete contents. A native
  -- BuildProposal cannot be rolled back here, but canonical bookkeeping must
  -- never be left half-retired or half-bound when validation fails closed.
  state.canonical.byCanonical = util.deepCopy(backup.byCanonical)
  state.canonical.byLocal = util.deepCopy(backup.byLocal)
  state.canonical.revisions = backup.revisions
  state.world.logicalOwners = util.deepCopy(backup.logicalOwners)
  state.world.pinnedCustody = util.deepCopy(backup.pinnedCustody)
end

local function emitProposalCompletion(record, success, result)
  if state.networkMode ~= "network" or record.completionEmitted == true then return true end
  local outputs = {}
  if success and type(result) == "table" then
    for _, output in ipairs(type(result.outputs) == "table" and result.outputs or {}) do
      outputs[#outputs + 1] = {
        kind = tostring(output.kind or "unknown"),
        cid = tostring(output.cid or ""),
        slot = tostring(output.slot or ""),
      }
    end
  end
  local completionView = {
    proposalId = record.proposalId,
    commitSeq = tonumber(record.commitSeq),
    proposalDigest = record.transaction and record.transaction.digest or nil,
    success = success == true,
    outputs = outputs,
    coreDigest = coreDigest(),
  }
  local payload = util.deepCopy(completionView)
  -- Native journals contain peer-local loan interest and may expose a build
  -- debit on different updates. The builder's signed quoted cost is part of
  -- the canonical transaction, so every completion reports the same wallet
  -- effect; observed native deltas remain diagnostics/reconciliation inputs.
  payload.financeDelta = success and -util.integer(record.transaction.cost, 0) or nil
  payload.resultDigest = hash.value(completionView)
  if not success then payload.errorCode = "native-proposal-failed" end
  local emitted, messageOrError = bridge.emit(state.bridge, "completion", payload, state.tick)
  if not emitted then
    record.completionError = tostring(messageOrError)
    return false, record.completionError
  end
  record.completionEmitted = true
  record.completionError = nil
  record.completion = util.deepCopy(payload)
  return true, payload
end

local function proposalFailure(record, message)
  local errorValue = type(message) == "table" and message or { error = tostring(message) }
  if errorValue.error == nil then errorValue.error = "canonical proposal failed" end
  record.status = "failed"
  record.completedTick = state.tick
  record.error = tostring(errorValue.error)
  record.result = util.deepCopy(errorValue)
  state.world.proposals.failed = (state.world.proposals.failed or 0) + 1
  state.world.proposalFailure = {
    tick = state.tick,
    proposalId = record.proposalId,
    digest = record.transaction and record.transaction.digest or nil,
    error = record.error,
  }
  state.probes.capture.proposalReplayFailureCount =
    (state.probes.capture.proposalReplayFailureCount or 0) + 1
  emitProposalCompletion(record, false, record.result)
  return false, record.result
end

local function pruneProposalRecords(targetRetained)
  targetRetained = math.max(0, util.integer(targetRetained, 16))
  local proposals = state.world.proposals.byId
  local completed = {}
  for proposalId, record in pairs(proposals) do
    if record.status == "applied" or record.status == "failed" then
      completed[#completed + 1] = {
        proposalId = proposalId,
        completedTick = util.integer(record.completedTick, record.queuedTick or 0),
        queuedTick = util.integer(record.queuedTick, 0),
      }
    end
  end
  table.sort(completed, function(a, b)
    if a.completedTick ~= b.completedTick then return a.completedTick < b.completedTick end
    if a.queuedTick ~= b.queuedTick then return a.queuedTick < b.queuedTick end
    return tostring(a.proposalId) < tostring(b.proposalId)
  end)
  local removed = 0
  for _, item in ipairs(completed) do
    if util.tableCount(proposals) <= targetRetained then break end
    proposals[item.proposalId] = nil
    state.world.proposalConsensus.byId[item.proposalId] = nil
    removed = removed + 1
  end
  return removed
end

function proposalPreparation.owner(cid, localId)
  local binding = state.canonical.byCanonical[cid]
  local resolvedLocalId = localId or (binding and binding.localId)
  if resolvedLocalId == nil then return nil end
  local key = tostring(resolvedLocalId)
  local custody = state.world.pinnedCustody and state.world.pinnedCustody[key] or nil
  return (state.world.logicalOwners and state.world.logicalOwners[key])
    or (binding and binding.metadata and binding.metadata.owner)
    or (type(custody) == "table" and custody.logicalOwnerCid or nil)
end

-- Inspect every local dependency without mutating native or canonical state.
-- This is deliberately shared by PREPARE and COMMIT so a successful prepare
-- proves the exact resolver and ownership policy that the later build uses.
function proposalPreparation.inspect(transaction, requirePortable)
  local valid, validationError
  if requirePortable then valid, validationError = proposalCodec.validatePortable(transaction)
  else valid, validationError = proposalCodec.validate(transaction) end
  if not valid then return nil, validationError end
  if not state.companies[transaction.companyCid] then
    return nil, "proposal targets an unknown company"
  end
  if requirePortable then
    local resources, resourceError = proposalCodec.preflightResources(transaction, api)
    if not resources then return nil, resourceError end
  end

  local inspected = { localRefs = {}, referenceKinds = {}, removal = {}, referenceCount = 0 }
  local function resolve(cid, kind, isRemoval)
    local localId = canonical.resolveLocal(state.canonical, cid)
    local resolution = "bound"
    if localId == nil then
      local findError
      localId, findError = world.findPreExistingLocal(state.canonical, cid, kind)
      if localId == nil then
        return nil, "canonical " .. kind .. " is not mapped locally: "
          .. tostring(cid) .. " (" .. tostring(findError) .. ")"
      end
      resolution = "geometric"
    end
    local existingKind = inspected.referenceKinds[cid]
    if existingKind and existingKind ~= kind then
      return nil, "canonical proposal reference changes kind: " .. tostring(cid)
    end
    if inspected.localRefs[cid] == nil then inspected.referenceCount = inspected.referenceCount + 1 end
    inspected.localRefs[cid] = localId
    inspected.referenceKinds[cid] = kind
    inspected.removal[cid] = inspected.removal[cid] == true or isRemoval == true
    inspected[cid] = resolution
    return localId
  end
  local function checkOwnedReference(cid, kind, isRemoval, message)
    local localId, resolveError = resolve(cid, kind, isRemoval)
    if localId == nil then return nil, resolveError end
    local ownerCid = proposalPreparation.owner(cid, localId)
    if ownerCid and ownerCid ~= transaction.companyCid then return nil, message .. tostring(cid) end
    return localId
  end
  for _, cid in ipairs(transaction.remove.edges) do
    local _, err = checkOwnedReference(
      cid, "edge", true, "proposal cannot remove rival private infrastructure ")
    if err then return nil, err end
  end
  for _, cid in ipairs(transaction.remove.nodes) do
    local _, err = checkOwnedReference(
      cid, "node", true, "proposal cannot remove rival private node ")
    if err then return nil, err end
  end
  for _, cid in ipairs(transaction.edgeObjects and transaction.edgeObjects.remove or {}) do
    local _, err = checkOwnedReference(
      cid, "edge_object", true, "proposal cannot remove a rival edge object ")
    if err then return nil, err end
  end
  for _, object in ipairs(transaction.edgeObjects and transaction.edgeObjects.retain or {}) do
    local _, err = checkOwnedReference(
      object.cid, "edge_object", false, "proposal cannot carry a rival edge object ")
    if err then return nil, err end
  end
  if transaction.schemaVersion == proposalCodec.CONSTRUCTION_SCHEMA_VERSION then
    local construction = transaction.constructions and transaction.constructions[1]
    if construction and construction.mode ~= "build" then
      local sourceKind = construction.kind == "asset" and "asset" or "construction"
      local _, err = checkOwnedReference(
        construction.sourceCid, sourceKind, true,
        "proposal cannot change a rival construction ")
      if err then return nil, err end
    end
  end
  for _, edge in ipairs(transaction.edges) do
    for _, reference in ipairs({ edge.node0, edge.node1 }) do
      if reference.cid then
        local _, err = checkOwnedReference(
          reference.cid, "node", false, "proposal cannot attach to rival private node ")
        if err then return nil, err end
      end
    end
  end
  return inspected
end

function proposalPreparation.bind(inspected, eventId)
  local localInputs = {}
  for _, cid in ipairs(util.sortedKeys(inspected.localRefs)) do
    local localId = inspected.localRefs[cid]
    local kind = inspected.referenceKinds[cid]
    if canonical.resolveLocal(state.canonical, cid) == nil then
      local ownerCid = state.world.logicalOwners
        and state.world.logicalOwners[tostring(localId)] or nil
      local resolved, resolveError = world.resolvePreExisting(state.canonical, cid, kind, {
        owner = ownerCid,
        resolvedForProposal = eventId,
      })
      if resolved == nil then return nil, nil, resolveError end
      localId = resolved
      inspected.localRefs[cid] = localId
    end
    if inspected.removal[cid] then
      localInputs[#localInputs + 1] = { kind = kind, cid = cid, localId = localId }
    end
  end
  return inspected.localRefs, localInputs
end

function proposalPreparation.prepare(transaction, eventId, commitSeq)
  local running, runningError = requireRunningMatch()
  if not running then return false, runningError end
  if state.networkMode ~= "network" then return false, "proposal prepare is network-only" end
  local inspected, inspectionError = proposalPreparation.inspect(transaction, true)
  if not inspected then return false, inspectionError end
  proposalPreparation.pending[transaction.digest] = {
    eventId = eventId,
    commitSeq = tonumber(commitSeq),
    transactionId = transaction.transactionId,
    companyCid = transaction.companyCid,
    referenceCount = inspected.referenceCount,
    tick = state.tick,
  }
  return true, {
    prepared = true,
    proposalDigest = transaction.digest,
    transactionId = transaction.transactionId,
    companyCid = transaction.companyCid,
    referenceCount = inspected.referenceCount,
    resourceCount = #transaction.edges,
  }
end

local function queueCanonicalProposal(transaction, eventId, commitSeq)
  local running, runningError = requireRunningMatch()
  if not running then return false, runningError end
  local inspected, inspectionError = proposalPreparation.inspect(
    transaction, state.networkMode == "network")
  if not inspected then return false, inspectionError end
  -- Keep enough completed records for diagnostics, but never let a long match
  -- permanently exhaust the bounded transaction queue. Pending records are
  -- never pruned; reaching the cap with 32 genuinely in-flight proposals is a
  -- real back-pressure condition.
  if util.tableCount(state.world.proposals.byId) >= 32 then pruneProposalRecords(16) end
  if util.tableCount(state.world.proposals.byId) >= 32 then return false, "too many in-flight proposal transactions" end
  if state.world.proposals.byId[eventId] then return false, "duplicate canonical proposal event" end

  local localRefs, localInputs, bindError = proposalPreparation.bind(inspected, eventId)
  if not localRefs then return false, bindError end
  proposalPreparation.pending[transaction.digest] = nil

  local issuerPlayerId = game.interface.getPlayer()
  local company = state.companies[transaction.companyCid]
  local nativeOwnerPlayerId = state.world.proxyMode and issuerPlayerId or company.playerId
  local record = {
    proposalId = eventId,
    transactionId = transaction.transactionId,
    eventId = eventId,
    commitSeq = tonumber(commitSeq),
    originPeer = tostring(eventId):match(":([^:]+):%d+$"),
    companyCid = transaction.companyCid,
    transaction = util.deepCopy(transaction),
    localInputs = localInputs,
    localRefs = localRefs,
    issuerPlayerId = issuerPlayerId,
    nativeOwnerPlayerId = nativeOwnerPlayerId,
    -- Compatibility alias for version <= 9 saves/research readers.
    controlPlayerId = issuerPlayerId,
    balanceBefore = balanceOf(issuerPlayerId),
    nativeOwnerBalanceBefore = balanceOf(nativeOwnerPlayerId),
    status = "queued",
    queuedTick = state.tick,
  }
  if record.balanceBefore == nil then return false, "proposal issuer balance is unavailable" end
  state.world.proposals.byId[eventId] = record
  if state.networkMode == "network" then
    state.world.proposalConsensus.byId[eventId] = {
      proposalId = eventId,
      commitSeq = tonumber(commitSeq),
      proposalDigest = transaction.digest,
      status = "pending",
    }
  end
  state.world.proposals.queued = (state.world.proposals.queued or 0) + 1
  return true, {
    queued = true,
    proposalId = eventId,
    transactionId = transaction.transactionId,
    proposalDigest = transaction.digest,
    companyCid = transaction.companyCid,
  }
end

local function completeProposalFinance(record, result, finalEdgeIds, createdNodeIds, observation)
  local financeOk, financeResult = routeProposalFinance(record, observation)
  if not financeOk then
    record.pendingFinance = nil
    return proposalFailure(record, tostring(financeResult))
  end
  result.finance = financeResult
  record.status = "applied"
  record.completedTick = state.tick
  record.result = util.deepCopy(result)
  record.pendingFinance = nil
  state.world.proposals.applied = (state.world.proposals.applied or 0) + 1
  state.probes.capture.proposalReplayCount = (state.probes.capture.proposalReplayCount or 0) + 1
  state.probes.capture.lastProposalReplay = {
    tick = state.tick,
    digest = record.transaction.digest,
    companyCid = record.transaction.companyCid,
    createdEdgeIds = util.deepCopy(finalEdgeIds),
    createdNodeIds = util.deepCopy(createdNodeIds),
  }
  refreshOwnershipProbe()
  emitProposalCompletion(record, true, result)
  return true, result
end

local function processPendingProposalFinances()
  for _, proposalId in ipairs(util.sortedKeys(state.world.proposals.byId or {})) do
    local record = state.world.proposals.byId[proposalId]
    local pending = type(record) == "table" and record.pendingFinance or nil
    if record.status == "awaiting-finance" and type(pending) == "table"
      and state.tick >= util.integer(pending.earliestTick or pending.dueTick, state.tick) then
      -- The topology callback can precede its native journal entry by several
      -- dozen engine updates. Observe the effective company-wallet delta until
      -- a non-zero value is stable, while retaining a bounded deadline for
      -- genuinely free proposals.
      local issuerBalance = balanceOf(record.issuerPlayerId)
      local nativeOwnerBalance = balanceOf(record.nativeOwnerPlayerId)
      local issuerBefore = tonumber(record.balanceBefore)
      local nativeOwnerBefore = tonumber(record.nativeOwnerBalanceBefore)
      local issuerDelta = issuerBalance and issuerBefore and (issuerBalance - issuerBefore) or nil
      local nativeOwnerDelta = nativeOwnerBalance and nativeOwnerBefore
        and (nativeOwnerBalance - nativeOwnerBefore) or nil
      local company = state.companies[record.companyCid]
      local walletPlayerId = company and tonumber(company.playerId) or nil
      local walletDelta
      if walletPlayerId and walletPlayerId == tonumber(record.issuerPlayerId) then
        walletDelta = issuerDelta
      elseif walletPlayerId and walletPlayerId == tonumber(record.nativeOwnerPlayerId)
        and issuerDelta ~= nil and nativeOwnerDelta ~= nil then
        walletDelta = nativeOwnerDelta + issuerDelta
      else
        walletDelta = issuerDelta
      end
      local signature = walletDelta ~= nil and tostring(util.integer(walletDelta, 0)) or "unavailable"
      if pending.lastSignature ~= signature then
        pending.lastSignature = signature
        pending.stableSinceTick = state.tick
      end
      pending.samples = math.max(0, util.integer(pending.samples, 0)) + 1
      pending.lastSample = {
        tick = state.tick,
        issuerBalance = issuerBalance,
        nativeOwnerBalance = nativeOwnerBalance,
        issuerDelta = issuerDelta,
        nativeOwnerDelta = nativeOwnerDelta,
        walletDelta = walletDelta,
      }
      local stableTicks = state.tick - util.integer(pending.stableSinceTick, state.tick)
      local nonZeroStable = walletDelta ~= nil and math.abs(walletDelta) >= 0.5 and stableTicks >= 5
      local deadlineReached = state.tick >= util.integer(pending.deadlineTick, state.tick)
      if nonZeroStable or deadlineReached then
        completeProposalFinance(record, pending.result, pending.finalEdgeIds,
          pending.createdNodeIds, {
            issuerBalanceAfter = issuerBalance,
            nativeOwnerBalanceAfter = nativeOwnerBalance,
          })
        return true
      end
    end
  end
  return false
end

local function networkFinanceHousekeeping()
  if state.networkMode ~= "network" or state.initialized ~= true then return true end
  local ledger = finance.ensureNetworkAccounts(state.finance)
  if ledger.initialized ~= true then return false, "canonical network accounts are not initialised" end
  local reconciliation = ledger.reconciliation or {}
  if reconciliation.nextHousekeepingTick == nil then
    reconciliation.nextHousekeepingTick = state.tick + 60
    return true
  end
  local nextTick = util.integer(reconciliation.nextHousekeepingTick, state.tick + 60)
  if state.tick < nextTick then return true end
  -- Never erase a native construction debit while it is still being sampled,
  -- and never alter wallet presentation inside a physical/checkpoint barrier.
  for _, record in pairs(state.world.proposals.byId or {}) do
    if record.status == "queued" or record.status == "awaiting-finance"
      or record.status == "building-construction" then return true end
  end
  for _, record in pairs(state.world.operations.byId or {}) do
    if record.status == "queued" or record.status == "awaiting-result" then return true end
  end
  for _, record in pairs(state.world.proposalConsensus.byId or {}) do
    if record.status == "pending" then return true end
  end
  for _, record in pairs(state.world.operationConsensus.byId or {}) do
    if record.status == "pending" then return true end
  end
  for _, record in pairs(state.world.checkpointConsensus.byBoundary or {}) do
    if record.status == "pending" then return true end
  end
  reconciliation.nextHousekeepingTick = state.tick + 60
  local ok, result = finance.reconcileNetworkAccounts(state.finance, state.companies, {
    reason = "periodic-native-wallet-cache",
    tick = state.tick,
  })
  if not ok then return false, type(result) == "table" and result.error or result end
  return true, result
end

local function finaliseCanonicalProposal(payload)
  payload = type(payload) == "table" and payload or {}
  local proposalId = tostring(payload.proposalId or "")
  local record = state.world.proposals.byId[proposalId]
  if not record then return false, "unknown pending canonical proposal" end
  if record.status == "applied" then return true, util.deepCopy(record.result) end
  if record.status == "failed" then return false, util.deepCopy(record.result) end
  if payload.success ~= true then
    return proposalFailure(record, { error = tostring(payload.error or "GUI-state BuildProposal was rejected") })
  end
  local createdEdgeIds = type(payload.createdEdgeIds) == "table" and payload.createdEdgeIds or {}
  local createdNodeIds = type(payload.createdNodeIds) == "table" and payload.createdNodeIds or {}
  if #createdEdgeIds > proposalCodec.MAX_EDGES or #createdNodeIds > proposalCodec.MAX_NODES then
    return proposalFailure(record, "GUI proposal result exceeded topology limits")
  end
  local transaction = record.transaction
  local matched, matchError = proposalCodec.matchCreated(
    transaction,
    inspectCreatedNodes(createdNodeIds),
    inspectCreatedEdges(createdEdgeIds),
    0.5,
    function(cid)
      local localId = canonical.resolveLocal(state.canonical, cid)
      return localId and nodePosition(localId) or nil
    end,
    function(cid)
      return canonical.resolveLocal(state.canonical, cid)
    end
  )
  if not matched or #matched.unmatchedNodes > 0 or #matched.unmatchedEdges > 0
    or #matched.unmatchedEdgeObjects > 0 then
    return proposalFailure(record, tostring(matchError or "proposal created unexpected topology"))
  end
  for _, edge in ipairs(transaction.edges) do
    if edge.private then
      local localId = matched.edges[edge.slot]
      local observedOwner = world.ownerOf(localId)
      if tonumber(observedOwner) ~= tonumber(record.nativeOwnerPlayerId) then
        if observedOwner ~= nil and tonumber(observedOwner) ~= -1 then
          return proposalFailure(record, {
            error = "private proposal edge was created under an unexpected rival owner",
            slot = edge.slot,
            observedOwner = observedOwner,
            expectedOwner = record.nativeOwnerPlayerId,
          })
        end
        local beforeEdges, captureError = edgeOwnership.captureBaseEdges()
        if not beforeEdges then return proposalFailure(record, tostring(captureError)) end
        local ownershipProposal, ownershipError = edgeOwnership.makeProposal(localId, record.nativeOwnerPlayerId)
        if not ownershipProposal then return proposalFailure(record, tostring(ownershipError)) end
        local factory = util.commandFactory("buildProposal")
        if not (factory and api and api.cmd and type(api.cmd.sendCommand) == "function") then
          return proposalFailure(record, "ownership replacement BuildProposal API is unavailable")
        end
        if state.networkMode == "network" then
          local authorize = rawget(_G, "tpf2mp_native_authorize_build")
          if type(authorize) ~= "function" then
            return proposalFailure(record, "ownership replacement requires native authorization")
          end
          local called, authorized, authorizeError = pcall(authorize)
          if not called or authorized == false then
            return proposalFailure(record, tostring(authorizeError or authorized))
          end
        end
        local commandOk, commandOrError = pcall(factory, ownershipProposal, nil, false)
        if not commandOk then return proposalFailure(record, tostring(commandOrError)) end
        local callbackCalled, replacementSuccess, replacementResult = false, false, nil
        local sent, sendError = util.sendCommand(commandOrError, function(result, success)
          callbackCalled, replacementSuccess, replacementResult = true, success == true, result
        end, "mod.proposal.rebind-edge-owner")
        if not sent then return proposalFailure(record, tostring(sendError)) end
        if not callbackCalled then return proposalFailure(record, "ownership replacement callback was not synchronous") end
        if not replacementSuccess then return proposalFailure(record, "ownership replacement BuildProposal was rejected") end
        local replacementId, candidates, replacementError = edgeOwnership.findReplacement(
          beforeEdges, localId, replacementResult, record.nativeOwnerPlayerId
        )
        if not replacementId then
          return proposalFailure(record, {
            error = tostring(replacementError),
            slot = edge.slot,
            candidates = candidates,
          })
        end
        matched.edges[edge.slot] = replacementId
      end
    end
  end
  local finalEdgeIds = {}
  for _, edge in ipairs(transaction.edges) do finalEdgeIds[#finalEdgeIds + 1] = matched.edges[edge.slot] end
  -- Build 35924 can reuse a removed BASE_EDGE entity ID for its replacement
  -- in the same successful command. Retire every canonical input before
  -- binding event-derived outputs so a reused local ID is not mistaken for a
  -- collision with the edge it just replaced. Keep the registry and custody
  -- move atomic: a later binding failure restores the exact pre-finalise view.
  local bindingBackup = proposalBindingBackup()
  retireProposalInputs(transaction, record.localInputs)
  local bound, bindError = bindProposalOutputs(transaction, record.eventId, matched, record.nativeOwnerPlayerId)
  if not bound then
    restoreProposalBindings(bindingBackup)
    return proposalFailure(record, tostring(bindError))
  end

  local result = {
    transactionId = transaction.transactionId,
    proposalId = record.proposalId,
    proposalDigest = transaction.digest,
    companyCid = transaction.companyCid,
    outputs = (function()
      local values = {}
      for _, item in ipairs(bound) do values[#values + 1] = { kind = item.kind, cid = item.cid, slot = item.slot } end
      return values
    end)(),
  }
  -- The GUI result is deliberately held for at least 90 GUI frames and until
  -- its wallet samples stabilize. It therefore already carries the delayed
  -- Build 35924 journal observation needed by routeProposalFinance. Waiting a
  -- second 180 engine updates here added roughly 35-40 seconds to every live
  -- build even though network consensus uses the signed quoted cost. Complete
  -- from that settled observation immediately; periodic account reconciliation
  -- remains the safety net for a genuinely later native cache entry.
  return completeProposalFinance(record, result, finalEdgeIds, createdNodeIds, payload)
end

local function constructionComponentSets()
  local types = api and api.type and api.type.ComponentType or {}
  local descriptors = {
    { kind = "construction", componentType = types.CONSTRUCTION, required = true },
    { kind = "station", componentType = types.STATION, required = true },
    { kind = "station_group", componentType = types.STATION_GROUP, required = true },
    { kind = "depot", componentType = types.VEHICLE_DEPOT, required = true },
    { kind = "asset", componentType = types.ASSET_GROUP, required = false },
    { kind = "edge_object", componentType = types.SIGNAL_LIST, required = false },
    { kind = "node", componentType = types.BASE_NODE, required = true },
    { kind = "edge", componentType = types.BASE_EDGE, required = true },
  }
  local result = {}
  for _, descriptor in ipairs(descriptors) do
    if not descriptor.componentType then
      if descriptor.required then
        return nil, "construction component type is unavailable: " .. descriptor.kind
      end
      result[descriptor.kind] = {}
    else
      local set, setError = componentEntitySet(descriptor.componentType)
      if not set then return nil, setError end
      result[descriptor.kind] = set
    end
  end
  return result
end

proposalPreparation.construction = {
  componentKinds = {
    "construction", "station", "station_group", "depot", "asset", "edge_object", "node", "edge",
  },
}

local function constructionSetDelta(after, before)
  local result = {}
  for _, kind in ipairs(proposalPreparation.construction.componentKinds) do
    result[kind] = setDifference(after and after[kind], before and before[kind])
  end
  return result
end

local function constructionDeltaCounts(delta)
  local result = {}
  for _, kind in ipairs(proposalPreparation.construction.componentKinds) do
    result[kind] = #(delta and delta[kind] or {})
  end
  return result
end

function proposalPreparation.construction.sortedOutputs(kind, values)
  local rows, seen = {}, {}
  for _, localId in ipairs(values or {}) do
    local ok, fingerprint = pcall(world.fingerprint, localId, kind)
    if not ok or type(fingerprint) ~= "string" or fingerprint == "" then
      return nil, "construction output fingerprint is unavailable for " .. kind
    end
    if seen[fingerprint] then
      return nil, "construction produced ambiguous duplicate " .. kind .. " outputs"
    end
    seen[fingerprint] = true
    rows[#rows + 1] = { localId = localId, fingerprint = fingerprint }
  end
  table.sort(rows, function(a, b) return a.fingerprint < b.fingerprint end)
  return rows
end

local function bindConstructionOutputs(record, existing, delta, pending)
  local bound = existing or {}
  local construction = record.transaction.constructions[1]
  local rootEntity = pending and tonumber(pending.rootEntity) or nil
  local rootKind = construction.kind == "asset" and "asset" or "construction"
  if construction.mode == "upgrade" then
    if not rootEntity then return nil, "upgraded construction root is unavailable" end
    local cid = construction.sourceCid
    local ok, bindError = canonical.bind(state.canonical, cid, rootKind, rootEntity, {
      owner = record.companyCid,
      private = true,
      proposalDigest = record.transaction.digest,
      outputSlot = construction.slot,
      upgraded = true,
    })
    if not ok then return nil, bindError end
    state.world.logicalOwners[tostring(rootEntity)] = record.companyCid
    state.world.pinnedCustody[tostring(rootEntity)] = {
      cid = cid, kind = rootKind, logicalOwnerCid = record.companyCid,
      nativePlayerId = world.ownerOf(rootEntity) or record.nativeOwnerPlayerId,
      requestedPlayerId = state.companies[record.companyCid].playerId,
      reason = "canonical-construction-upgrade",
    }
    bound[#bound + 1] = {
      kind = rootKind, cid = cid, localId = rootEntity, slot = construction.slot,
    }
  end
  for _, descriptor in ipairs({
    { kind = "construction", values = delta.construction },
    { kind = "station", values = delta.station },
    { kind = "station_group", values = delta.station_group },
    { kind = "depot", values = delta.depot },
    { kind = "asset", values = delta.asset },
  }) do
    local values = {}
    for _, localId in ipairs(descriptor.values or {}) do
      if not (construction.mode == "upgrade" and descriptor.kind == rootKind
        and tonumber(localId) == rootEntity) then values[#values + 1] = localId end
    end
    local rows, rowsError = proposalPreparation.construction.sortedOutputs(descriptor.kind, values)
    if not rows then return nil, rowsError end
    for index, row in ipairs(rows) do
      local localId = row.localId
      local slot = descriptor.kind .. ":" .. tostring(index)
      local cid = canonical.createdId(descriptor.kind, record.eventId, index)
      local ok, bindError = canonical.bind(state.canonical, cid, descriptor.kind, localId, {
        owner = record.companyCid,
        private = true,
        proposalDigest = record.transaction.digest,
        outputSlot = slot,
        fingerprint = row.fingerprint,
      })
      if not ok then return nil, bindError end
      state.world.logicalOwners[tostring(localId)] = record.companyCid
      state.world.pinnedCustody[tostring(localId)] = {
        cid = cid,
        kind = descriptor.kind,
        logicalOwnerCid = record.companyCid,
        nativePlayerId = world.ownerOf(localId) or record.nativeOwnerPlayerId,
        requestedPlayerId = state.companies[record.companyCid].playerId,
        reason = "canonical-construction-replay",
      }
      bound[#bound + 1] = { kind = descriptor.kind, cid = cid, localId = localId, slot = slot }
    end
  end
  return bound
end

local function normaliseConstructionDebit(record)
  local company = state.companies[record.companyCid]
  if not company then return nil, "proposal company is unavailable" end
  local issuerPlayerId = tonumber(record.issuerPlayerId or record.controlPlayerId)
  local nativeOwnerPlayerId = tonumber(record.nativeOwnerPlayerId or issuerPlayerId)
  local walletPlayerId = tonumber(company.playerId)
  local issuerBefore = tonumber(record.balanceBefore)
  local ownerBefore = tonumber(record.nativeOwnerBalanceBefore)
  local issuerAfter = issuerPlayerId and balanceOf(issuerPlayerId) or nil
  local ownerAfter = nativeOwnerPlayerId and balanceOf(nativeOwnerPlayerId) or nil
  if not issuerPlayerId or issuerBefore == nil or issuerAfter == nil then
    return nil, "construction issuer balance is unavailable"
  end
  local issuerDelta = issuerAfter - issuerBefore
  local ownerDelta = ownerBefore and ownerAfter and (ownerAfter - ownerBefore) or 0
  local effectiveDelta
  if walletPlayerId == issuerPlayerId then
    effectiveDelta = issuerDelta
  elseif walletPlayerId == nativeOwnerPlayerId then
    effectiveDelta = ownerDelta + issuerDelta
  else
    effectiveDelta = issuerDelta
  end
  local targetDelta = -util.integer(record.transaction.cost, 0)
  local correction = targetDelta - effectiveDelta
  if math.abs(correction) >= 0.5 then
    local booked, bookError = finance.book(issuerPlayerId, correction)
    if not booked then return nil, "could not normalize construction cost: " .. tostring(bookError) end
  end
  return {
    issuerBalanceBefore = issuerBefore,
    issuerBalanceAfter = balanceOf(issuerPlayerId),
    nativeOwnerBalanceBefore = ownerBefore,
    nativeOwnerBalanceAfter = nativeOwnerPlayerId and balanceOf(nativeOwnerPlayerId) or nil,
    quotedDelta = targetDelta,
    correction = correction,
  }
end

local function beginCanonicalConstruction(record)
  local activePlayer = type(game.interface.getPlayer) == "function" and tonumber(game.interface.getPlayer()) or nil
  if activePlayer ~= tonumber(record.issuerPlayerId) then
    return proposalFailure(record, "construction replay player mapping changed before execution")
  end
  local spec, materialiseError = proposalCodec.materialiseConstruction(record.transaction)
  if not spec then return proposalFailure(record, tostring(materialiseError)) end
  local before, captureError = constructionComponentSets()
  if not before then return proposalFailure(record, tostring(captureError)) end
  local beforeFingerprints = {}
  for _, kind in ipairs(proposalPreparation.construction.componentKinds) do
    beforeFingerprints[kind] = {}
    for localId in pairs(before[kind] or {}) do
      local ok, fingerprint = pcall(world.fingerprint, localId, kind)
      if ok then beforeFingerprints[kind][localId] = fingerprint end
    end
  end
  record.balanceBefore = balanceOf(record.issuerPlayerId)
  record.nativeOwnerBalanceBefore = balanceOf(record.nativeOwnerPlayerId)
  local interface = game and game.interface or {}
  local called, entityOrError, rootEntity
  if spec.mode == "build" then
    if interface.buildConstruction == nil then
      return proposalFailure(record, "engine construction build API is unavailable")
    end
    called, entityOrError = pcall(
      interface.buildConstruction, spec.fileName, spec.params, spec.transform)
    rootEntity = called and tonumber(entityOrError) or nil
    if not rootEntity or rootEntity < 0 then
      return proposalFailure(record, tostring(called and "construction helper returned no entity" or entityOrError))
    end
  else
    local sourceLocalId = record.localRefs and tonumber(record.localRefs[spec.sourceCid]) or nil
    if not sourceLocalId then return proposalFailure(record, "construction source is not mapped locally") end
    rootEntity = sourceLocalId
    if spec.mode == "upgrade" then
      if interface.upgradeConstruction == nil then
        return proposalFailure(record, "engine construction upgrade API is unavailable")
      end
      called, entityOrError = pcall(
        interface.upgradeConstruction, sourceLocalId, spec.fileName, spec.params)
      local returnedEntity = called and tonumber(entityOrError) or nil
      if returnedEntity and returnedEntity >= 0 then rootEntity = returnedEntity end
    else
      if interface.bulldoze == nil then
        return proposalFailure(record, "engine construction bulldoze API is unavailable")
      end
      called, entityOrError = pcall(interface.bulldoze, sourceLocalId)
    end
    if not called then return proposalFailure(record, tostring(entityOrError)) end
  end
  if spec.mode ~= "remove" and type(game.interface.setPlayer) == "function" then
    local assigned, assignError = pcall(game.interface.setPlayer, rootEntity, record.nativeOwnerPlayerId)
    if not assigned then return proposalFailure(record, "station ownership assignment failed: " .. tostring(assignError)) end
  end
  record.status = "building-construction"
  record.constructionPending = {
    rootEntity = rootEntity,
    sourceRootEntity = spec.mode ~= "build" and tonumber(
      record.localRefs and record.localRefs[spec.sourceCid]) or nil,
    spec = util.deepCopy(spec),
    before = before,
    beforeFingerprints = beforeFingerprints,
    startedTick = state.tick,
    deadlineTick = state.tick + 120,
    stableSinceTick = nil,
    lastSignature = nil,
  }
  return true, { building = true, rootEntity = rootEntity }
end

function proposalPreparation.construction.topologyCandidates(kind, record, added, after)
  local values, seen = {}, {}
  local function add(localId)
    localId = tonumber(localId)
    if localId and not seen[localId] then seen[localId] = true; values[#values + 1] = localId end
  end
  for _, localId in ipairs(added[kind] or {}) do add(localId) end
  for _, input in ipairs(record.localInputs or {}) do
    if input.kind == kind and after[kind] and after[kind][tonumber(input.localId)] then add(input.localId) end
  end
  table.sort(values)
  return values
end

function proposalPreparation.construction.changeSignature(added, removed)
  local parts = {}
  for _, kind in ipairs(proposalPreparation.construction.componentKinds) do
    parts[#parts + 1] = kind .. "+" .. tostring(#(added[kind] or {}))
      .. "-" .. tostring(#(removed[kind] or {}))
  end
  return table.concat(parts, ":")
end

function proposalPreparation.construction.unexpectedTopologyRemoval(record, removed)
  local expected = { node = {}, edge = {}, edge_object = {} }
  for _, input in ipairs(record.localInputs or {}) do
    if expected[input.kind] then expected[input.kind][tonumber(input.localId)] = true end
  end
  for kind, values in pairs(expected) do
    for _, localId in ipairs(removed[kind] or {}) do
      if not values[tonumber(localId)] then
        return kind .. " " .. tostring(localId) .. " was removed without a canonical input"
      end
    end
  end
  return nil
end

function proposalPreparation.construction.reconcileChangedOutputs(record, bound, added, removed, pending)
  if pending.spec.mode ~= "upgrade" then
    for _, kind in ipairs({ "station", "station_group", "depot", "asset" }) do
      for _, localId in ipairs(removed[kind] or {}) do
        local cid = canonical.resolveCanonical(state.canonical, kind, localId)
        if cid then canonical.unbindCanonical(state.canonical, cid) end
        state.world.logicalOwners[tostring(localId)] = nil
        state.world.pinnedCustody[tostring(localId)] = nil
      end
    end
    return true
  end
  local changedKinds = pending.spec.kind == "asset"
    and { "station", "station_group", "depot" }
    or { "station", "station_group", "depot", "asset" }
  for _, kind in ipairs(changedKinds) do
    local oldRows, newRows = {}, nil
    for _, localId in ipairs(removed[kind] or {}) do
      oldRows[#oldRows + 1] = {
        localId = localId,
        fingerprint = pending.beforeFingerprints[kind]
          and pending.beforeFingerprints[kind][localId] or nil,
        cid = canonical.resolveCanonical(state.canonical, kind, localId),
      }
    end
    newRows = proposalPreparation.construction.sortedOutputs(kind, added[kind] or {})
    if not newRows then return nil, "changed " .. kind .. " outputs are ambiguous" end
    table.sort(oldRows, function(a, b)
      return tostring(a.fingerprint or "") < tostring(b.fingerprint or "")
    end)
    local preserve = #oldRows > 0 and #oldRows == #newRows
    for _, row in ipairs(oldRows) do
      if not row.cid or not row.fingerprint then preserve = false; break end
    end
    if preserve then
      for index, old in ipairs(oldRows) do
        local new = newRows[index]
        canonical.unbindCanonical(state.canonical, old.cid)
        state.world.logicalOwners[tostring(old.localId)] = nil
        state.world.pinnedCustody[tostring(old.localId)] = nil
        local ok, bindError = canonical.bind(state.canonical, old.cid, kind, new.localId, {
          owner = record.companyCid,
          private = true,
          proposalDigest = record.transaction.digest,
          outputSlot = kind .. ":preserved:" .. tostring(index),
          fingerprint = new.fingerprint,
          upgraded = true,
        })
        if not ok then return nil, bindError end
        state.world.logicalOwners[tostring(new.localId)] = record.companyCid
        state.world.pinnedCustody[tostring(new.localId)] = {
          cid = old.cid, kind = kind, logicalOwnerCid = record.companyCid,
          nativePlayerId = world.ownerOf(new.localId) or record.nativeOwnerPlayerId,
          requestedPlayerId = state.companies[record.companyCid].playerId,
          reason = "canonical-construction-child-upgrade",
        }
        bound[#bound + 1] = {
          kind = kind, cid = old.cid, localId = new.localId,
          slot = kind .. ":preserved:" .. tostring(index),
        }
      end
      added[kind] = {}
    else
      for _, old in ipairs(oldRows) do
        if old.cid then canonical.unbindCanonical(state.canonical, old.cid) end
        state.world.logicalOwners[tostring(old.localId)] = nil
        state.world.pinnedCustody[tostring(old.localId)] = nil
      end
    end
  end
  return true
end

local function finaliseCanonicalConstruction(record)
  local pending = record.constructionPending
  local after, captureError = constructionComponentSets()
  if not after then return proposalFailure(record, tostring(captureError)) end
  local added = constructionSetDelta(after, pending.before)
  local removed = constructionSetDelta(pending.before, after)
  local counts, removedCounts = constructionDeltaCounts(added), constructionDeltaCounts(removed)
  local signature = proposalPreparation.construction.changeSignature(added, removed)
  if pending.lastSignature ~= signature then
    pending.lastSignature = signature
    pending.stableSinceTick = state.tick
  end
  pending.lastCounts, pending.lastRemovedCounts = counts, removedCounts
  local mode = pending.spec.mode
  local rootKind = pending.spec.kind == "asset" and "asset" or "construction"
  local rootSet = after[rootKind] or {}
  local beforeRootSet = pending.before[rootKind] or {}
  if mode == "upgrade" and not rootSet[pending.rootEntity]
    and #(added[rootKind] or {}) == 1 then
    pending.rootEntity = added[rootKind][1]
  end
  local expectedNodes, expectedEdges = #(record.transaction.nodes or {}), #(record.transaction.edges or {})
  local candidateNodes = proposalPreparation.construction.topologyCandidates("node", record, added, after)
  local candidateEdges = proposalPreparation.construction.topologyCandidates("edge", record, added, after)
  local ready = #candidateNodes == expectedNodes and #candidateEdges == expectedEdges
  local upgradeChanged = true
  if mode == "build" then
    ready = ready and rootSet[pending.rootEntity] == true
      and beforeRootSet[pending.rootEntity] ~= true
  elseif mode == "upgrade" then
    ready = ready and rootSet[pending.rootEntity] == true
    upgradeChanged = false
    for _, kind in ipairs(proposalPreparation.construction.componentKinds) do
      if #(added[kind] or {}) > 0 or #(removed[kind] or {}) > 0 then
        upgradeChanged = true
        break
      end
    end
    if not upgradeChanged then
      local sourceEntity = tonumber(pending.sourceRootEntity or pending.rootEntity)
      local beforeFingerprint = sourceEntity and pending.beforeFingerprints[rootKind]
        and pending.beforeFingerprints[rootKind][sourceEntity] or nil
      local fingerprintOk, afterFingerprint = pcall(
        world.fingerprint, pending.rootEntity, rootKind)
      upgradeChanged = beforeFingerprint ~= nil and fingerprintOk
        and type(afterFingerprint) == "string" and afterFingerprint ~= beforeFingerprint
    end
    -- Some legacy helpers return successfully for an unsupported construction
    -- class while leaving the entity untouched (ASSET_GROUP does this on
    -- Build 35924). Never acknowledge such a no-op on the wire.
    ready = ready and upgradeChanged
  else
    ready = rootSet[pending.rootEntity] ~= true
      and expectedNodes == 0 and expectedEdges == 0
    for _, kind in ipairs(proposalPreparation.construction.componentKinds) do
      if #(added[kind] or {}) > 0 then ready = false end
    end
  end
  if pending.spec.kind == "rail_station" or pending.spec.kind == "station" then
    if mode == "build" then ready = ready and counts.station >= 1 and counts.station_group >= 1 end
  elseif pending.spec.kind == "depot" and mode == "build" then
    ready = ready and counts.depot >= 1
  elseif pending.spec.kind == "asset" and mode == "build" then
    ready = ready and counts.asset >= 1
  end
  for _, kind in ipairs(proposalPreparation.construction.componentKinds) do
    if #(added[kind] or {}) > proposalCodec.MAX_CONSTRUCTION_NODES
      or #(removed[kind] or {}) > proposalCodec.MAX_CONSTRUCTION_NODES then ready = false end
  end
  local stable = state.tick - util.integer(pending.stableSinceTick, state.tick) >= 3
  if not ready or not stable then
    if state.tick < pending.deadlineTick then
      return true, { waiting = true, mode = mode, counts = counts, removedCounts = removedCounts }
    end
    return proposalFailure(record, {
      error = "construction change did not stabilize to its canonical postcondition",
      mode = mode, counts = counts, removedCounts = removedCounts,
      expected = {
        node = expectedNodes, edge = expectedEdges, kind = pending.spec.kind,
        upgradeChanged = mode == "upgrade" and upgradeChanged or nil,
      },
    })
  end
  local unexpectedRemoval = proposalPreparation.construction.unexpectedTopologyRemoval(record, removed)
  if unexpectedRemoval then return proposalFailure(record, unexpectedRemoval) end

  local matched = { nodes = {}, edges = {}, edgeObjects = {},
    unmatchedNodes = {}, unmatchedEdges = {}, unmatchedEdgeObjects = {} }
  if mode ~= "remove" then
    local matchError
    matched, matchError = proposalCodec.matchCreated(
      record.transaction,
      inspectCreatedNodes(candidateNodes),
      inspectCreatedEdges(candidateEdges),
      0.5,
      function(cid)
        local localId = canonical.resolveLocal(state.canonical, cid)
        return localId and nodePosition(localId) or nil
      end,
      function(cid) return canonical.resolveLocal(state.canonical, cid) end
    )
    if not matched or #matched.unmatchedNodes > 0 or #matched.unmatchedEdges > 0
      or #matched.unmatchedEdgeObjects > 0 then
      return proposalFailure(record, tostring(matchError or "construction created unexpected topology"))
    end
    for _, edge in ipairs(record.transaction.edges) do
      if edge.private then
        local observedOwner = world.ownerOf(matched.edges[edge.slot])
        if tonumber(observedOwner) ~= tonumber(record.nativeOwnerPlayerId) then
          return proposalFailure(record, {
            error = "construction track/street was created under an unexpected owner",
            slot = edge.slot, observedOwner = observedOwner,
            expectedOwner = record.nativeOwnerPlayerId,
          })
        end
      end
    end
  end

  local bindingBackup = proposalBindingBackup()
  retireProposalInputs(record.transaction, record.localInputs or {})
  local bound, bindError = {}, nil
  local mutableAdded = util.deepCopy(added)
  local reconciled, reconcileError = proposalPreparation.construction.reconcileChangedOutputs(
    record, bound, mutableAdded, removed, pending)
  if not reconciled then bindError = reconcileError end
  if not bindError and mode ~= "remove" then
    local preservedBound = bound
    local graphBound
    graphBound, bindError = bindProposalOutputs(
      record.transaction, record.eventId, matched, record.nativeOwnerPlayerId)
    if graphBound then
      for _, item in ipairs(preservedBound) do graphBound[#graphBound + 1] = item end
      bound = graphBound
      bound, bindError = bindConstructionOutputs(record, bound, mutableAdded, pending)
    end
  end
  if bindError then
    restoreProposalBindings(bindingBackup)
    return proposalFailure(record, tostring(bindError))
  end
  local observation, financeError = normaliseConstructionDebit(record)
  if not observation then
    restoreProposalBindings(bindingBackup)
    return proposalFailure(record, tostring(financeError))
  end
  local finalEdgeIds, createdNodeIds = {}, {}
  for _, edge in ipairs(record.transaction.edges) do finalEdgeIds[#finalEdgeIds + 1] = matched.edges[edge.slot] end
  for _, node in ipairs(record.transaction.nodes) do createdNodeIds[#createdNodeIds + 1] = matched.nodes[node.slot] end
  local result = {
    transactionId = record.transactionId,
    proposalId = record.proposalId,
    proposalDigest = record.transaction.digest,
    companyCid = record.companyCid,
    constructionKind = pending.spec.kind,
    constructionMode = mode,
    outputs = {},
  }
  for _, item in ipairs(bound) do
    result.outputs[#result.outputs + 1] = { kind = item.kind, cid = item.cid, slot = item.slot }
  end
  table.sort(result.outputs, function(a, b)
    if a.kind ~= b.kind then return a.kind < b.kind end
    if a.slot ~= b.slot then return a.slot < b.slot end
    return a.cid < b.cid
  end)
  record.constructionPending = nil
  return completeProposalFinance(record, result, finalEdgeIds, createdNodeIds, observation)
end

local function processCanonicalConstructionProposals()
  for _, proposalId in ipairs(util.sortedKeys(state.world.proposals.byId or {})) do
    local record = state.world.proposals.byId[proposalId]
    if type(record) == "table" and record.transaction
      and record.transaction.schemaVersion == proposalCodec.CONSTRUCTION_SCHEMA_VERSION then
      if record.status == "queued"
        or (record.status == "building-construction" and record.constructionPending) then
        -- The helper mutates the native world over several ticks.  Record every
        -- bounded step as a machine-local event; the final step then captures
        -- the canonical bindings and ledger debit instead of allowing them to
        -- appear silently between the preceding checkpoint and consensus.
        return applyCommitted({
          type = "proposal.construction_step",
          proposalId = proposalId,
          localOnly = true,
        }, "native-" .. tostring(state.bridge.peerId), nil)
      end
    end
  end
  return true
end

local function pruneOperationRecords(targetRetained)
  targetRetained = math.max(0, util.integer(targetRetained, 24))
  local records, completed = state.world.operations.byId, {}
  for operationId, record in pairs(records) do
    if record.status == "applied" or record.status == "failed" then
      completed[#completed + 1] = {
        operationId = operationId,
        completedTick = util.integer(record.completedTick, record.queuedTick or 0),
      }
    end
  end
  table.sort(completed, function(a, b)
    if a.completedTick ~= b.completedTick then return a.completedTick < b.completedTick end
    return tostring(a.operationId) < tostring(b.operationId)
  end)
  for _, item in ipairs(completed) do
    if util.tableCount(records) <= targetRetained then break end
    records[item.operationId] = nil
    state.world.operationConsensus.byId[item.operationId] = nil
  end
end

local function operationResolve(record, cid, expectedKind)
  local localId = record.localRefs and record.localRefs[cid]
    or canonical.resolveLocal(state.canonical, cid)
  if not localId then return nil, "canonical object is not mapped locally: " .. tostring(cid) end
  local binding = state.canonical.byCanonical[cid]
  if expectedKind and expectedKind ~= "entity" and binding and binding.kind ~= expectedKind then
    return nil, "canonical object kind mismatch for " .. tostring(cid)
  end
  return tonumber(localId)
end

local function operationOwner(localId)
  return world.logicalOwnerOf(state.world, state.companies, localId)
end

local function operationAccess(transaction, cid, expectedKind, localRefs)
  local binding = state.canonical.byCanonical[cid]
  local localId = binding and binding.localId or canonical.resolveLocal(state.canonical, cid)
  if not localId then return false, "canonical object is not mapped locally: " .. tostring(cid) end
  if state.networkMode == "network" and cid:find(":pre:", 1, true)
    and not (binding and binding.metadata and binding.metadata.manifestBound == true) then
    return false, "pre-existing object is not uniquely bound by the world manifest: " .. tostring(cid)
  end
  if expectedKind and expectedKind ~= "entity" and binding and binding.kind ~= expectedKind then
    return false, "canonical object kind mismatch for " .. tostring(cid)
  end
  local owner = operationOwner(localId)
  local metadataOwner = binding and binding.metadata and binding.metadata.owner or nil
  owner = owner or metadataOwner
  if owner and owner ~= transaction.companyCid then
    return false, "operation cannot mutate rival-owned " .. tostring(expectedKind or "entity")
      .. " " .. tostring(cid)
  end
  localRefs[cid] = localId
  return true, localId
end

local function queueCanonicalOperation(transaction, eventId, commitSeq, originCaptureToken)
  local running, runningError = requireRunningMatch()
  if not running then return false, runningError end
  local valid, validationError = operationCodec.validate(transaction)
  if not valid then return false, validationError end
  local company = state.companies[transaction.companyCid]
  if not company then return false, "operation targets an unknown company" end
  if util.tableCount(state.world.operations.byId) >= 48 then pruneOperationRecords(24) end
  if util.tableCount(state.world.operations.byId) >= 48 then
    return false, "too many in-flight canonical operations"
  end
  if state.world.operations.byId[eventId] then return false, "duplicate canonical operation event" end

  local data, localRefs = transaction.data, {}
  local spec = operationCodec.spec(transaction.kind)
  if data.targetCid then
    local ok, err = operationAccess(transaction, data.targetCid, spec.targetKind, localRefs)
    if not ok then return false, err end
  end
  if data.depotCid then
    local ok, err = operationAccess(transaction, data.depotCid, "depot", localRefs)
    if not ok then return false, err end
  end
  if data.lineCid then
    local ok, err = operationAccess(transaction, data.lineCid, "line", localRefs)
    if not ok then return false, err end
  end
  if data.line and type(data.line.stops) == "table" then
    for _, stop in ipairs(data.line.stops) do
      local cid = stop.stationGroupCid
      local binding = state.canonical.byCanonical[cid]
      local localId = binding and binding.localId or canonical.resolveLocal(state.canonical, cid)
      if not localId then return false, "line stop is not mapped locally: " .. tostring(cid) end
      if state.networkMode == "network" and cid:find(":pre:", 1, true)
        and not (binding and binding.metadata and binding.metadata.manifestBound == true) then
        return false, "station group is ambiguous in the pre-existing world manifest: " .. tostring(cid)
      end
      -- Public station groups are legal; a positively identified rival group
      -- is not. This keeps shared/public infrastructure possible without
      -- reopening the rival-asset mutation hole.
      local owner = operationOwner(localId)
      if owner and owner ~= transaction.companyCid then
        return false, "line cannot use a rival-owned station group: " .. tostring(cid)
      end
      localRefs[cid] = localId
    end
  end

  local originPeer = tostring(eventId):match(":([^:]+):%d+$")
  local originApplied
  originCaptureToken = originCaptureToken ~= nil and tostring(originCaptureToken) or nil
  if originPeer == state.bridge.peerId and originCaptureToken then
    originApplied = proposalPreparation.originAppliedOperations[originCaptureToken]
    proposalPreparation.originAppliedOperations[originCaptureToken] = nil
    if not originApplied then
      return false, "optimistic local operation result is unavailable for "
        .. tostring(originCaptureToken)
    end
    if originApplied.transactionId ~= transaction.transactionId
      or originApplied.kind ~= transaction.kind
      or originApplied.companyCid ~= transaction.companyCid then
      return false, "optimistic local operation result does not match the ordered transaction"
    end
  end

  local issuerPlayerId = game.interface.getPlayer()
  local nativePlayerId = state.world.proxyMode and issuerPlayerId or company.playerId
  local record = {
    operationId = eventId,
    transactionId = transaction.transactionId,
    eventId = eventId,
    commitSeq = tonumber(commitSeq),
    originPeer = originPeer,
    originCaptureToken = originCaptureToken,
    originApplied = originApplied and {
      localId = tonumber(originApplied.localId),
      capturedTick = tonumber(originApplied.capturedTick),
    } or nil,
    companyCid = transaction.companyCid,
    transaction = util.deepCopy(transaction),
    localRefs = localRefs,
    issuerPlayerId = tonumber(issuerPlayerId),
    nativePlayerId = tonumber(nativePlayerId),
    balanceBefore = balanceOf(nativePlayerId),
    status = "queued",
    queuedTick = state.tick,
  }
  if record.balanceBefore == nil then return false, "operation company balance is unavailable" end
  state.world.operations.byId[eventId] = record
  state.world.operations.queued = (state.world.operations.queued or 0) + 1
  if state.networkMode == "network" then
    state.world.operationConsensus.byId[eventId] = {
      operationId = eventId,
      commitSeq = tonumber(commitSeq),
      operationDigest = transaction.digest,
      status = "pending",
    }
  end
  return true, {
    queued = true,
    operationId = eventId,
    transactionId = transaction.transactionId,
    operationDigest = transaction.digest,
    kind = transaction.kind,
    companyCid = transaction.companyCid,
  }
end

local function operationFailure(record, message)
  local value = type(message) == "table" and message or { error = tostring(message) }
  if value.error == nil then value.error = "canonical operation failed" end
  record.status = "failed"
  record.completedTick = state.tick
  record.error = tostring(value.error)
  record.result = util.deepCopy(value)
  state.world.operations.failed = (state.world.operations.failed or 0) + 1
  state.probes.capture.operationReplayFailureCount =
    (state.probes.capture.operationReplayFailureCount or 0) + 1
  return false, record.result
end

local function safeOperationComponent(localId, componentType)
  if not componentType then return nil end
  local ok, value = pcall(api.engine.getComponent, localId, componentType)
  return ok and value or nil
end

local function operationPostcondition(record, outputCid, outputLocalId)
  local transaction, data = record.transaction, record.transaction.data
  local kind, types = transaction.kind, api.type.ComponentType
  local targetCid = outputCid or data.targetCid
  local localId = outputLocalId
  if not localId and data.targetCid then localId = operationResolve(record, data.targetCid) end
  if kind == "line.delete" or kind == "vehicle.sell" then
    return { kind = kind, targetCid = data.targetCid, exists = world.entityExists(localId) }
  end
  if not localId or not world.entityExists(localId) then
    return nil, "operation output/target does not exist after native success"
  end
  local result = { kind = kind, targetCid = targetCid, exists = true }
  if kind == "line.create" or kind == "line.update" then
    local line = safeOperationComponent(localId, types.LINE)
    if not line then return nil, "native line component is unavailable after operation" end
    result.stops = {}
    for _, stop in ipairs(line.stops or {}) do
      local groupId = tonumber(stop.stationGroup or stop.group or stop.station)
      local cid = groupId and canonical.resolveCanonical(state.canonical, "station_group", groupId) or nil
      if not cid then return nil, "native line contains an unmapped station group" end
      result.stops[#result.stops + 1] = {
        stationGroupCid = cid,
        station = util.integer(stop.station, 0),
        terminal = util.integer(stop.terminal, 0),
      }
    end
  elseif kind:sub(1, 8) == "vehicle." then
    local vehicle = safeOperationComponent(localId, types.TRANSPORT_VEHICLE)
    if not vehicle then return nil, "native vehicle component is unavailable after operation" end
    result.userStopped = vehicle.userStopped == true
    result.sellOnArrival = vehicle.sellOnArrival == true
    local lineId = tonumber(vehicle.line)
    if lineId and lineId >= 0 then
      result.lineCid = canonical.resolveCanonical(state.canonical, "line", lineId)
    end
    result.stopIndex = tonumber(vehicle.stopIndex)
    local config = vehicle.transportVehicleConfig
    result.vehicleParts = config and #(config.vehicles or {}) or nil
  elseif kind == "entity.name" then
    local name = safeOperationComponent(localId, types.NAME)
    result.name = name and tostring(name.name or "") or nil
  elseif kind == "entity.color" then
    -- Color userdata layout has varied between API states. Callback success,
    -- target existence, and the canonical transaction remain authoritative;
    -- retain an explicit marker instead of guessing component fields.
    result.colorApplied = safeOperationComponent(localId, types.COLOR) ~= nil
  end
  return result
end

local function bindOperationOutput(record, localId)
  local spec = operationCodec.spec(record.transaction.kind)
  if not spec.outputKind then return nil end
  if not localId or not world.entityExists(localId) then
    return nil, "native operation did not produce a valid local output"
  end
  if world.kindOf(localId) ~= spec.outputKind then
    return nil, "native operation output kind mismatch"
  end
  local cid = canonical.createdId(spec.outputKind, record.eventId, 1)
  local metadata = {
    owner = record.companyCid,
    operationDigest = record.transaction.digest,
    outputSlot = spec.outputKind .. ":1",
  }
  if spec.outputKind == "line" then
    metadata.name = record.transaction.data.name
    metadata.stops = util.deepCopy(record.transaction.data.line.stops)
  elseif spec.outputKind == "vehicle" then
    metadata.models = util.deepCopy(record.transaction.data.config.vehicles)
    metadata.depotCid = record.transaction.data.depotCid
  end
  local ok, err = canonical.bind(state.canonical, cid, spec.outputKind, localId, metadata)
  if not ok then return nil, err end
  state.world.logicalOwners[tostring(localId)] = record.companyCid
  return { kind = spec.outputKind, cid = cid, slot = spec.outputKind .. ":1", localId = localId }
end

local function applyOperationMetadata(record)
  local transaction, data = record.transaction, record.transaction.data
  local binding = data.targetCid and state.canonical.byCanonical[data.targetCid] or nil
  if binding then
    binding.metadata = binding.metadata or {}
    binding.metadata.owner = binding.metadata.owner or record.companyCid
    binding.metadata.lastOperationDigest = transaction.digest
    if transaction.kind == "line.update" then binding.metadata.stops = util.deepCopy(data.line.stops)
    elseif transaction.kind == "vehicle.assign" then binding.metadata.lineCid = data.lineCid
    elseif transaction.kind == "entity.name" then binding.metadata.name = data.name
    elseif transaction.kind == "entity.color" then binding.metadata.color = util.deepCopy(data.color)
    elseif transaction.kind == "vehicle.stop" then binding.metadata.userStopped = data.stopped
    elseif transaction.kind == "vehicle.maintenance" then
      binding.metadata.maintenanceBasisPoints = data.valueBasisPoints
    end
  end
  if transaction.kind == "line.delete" or transaction.kind == "vehicle.sell" then
    local localId = binding and binding.localId or record.localRefs[data.targetCid]
    canonical.unbindCanonical(state.canonical, data.targetCid)
    if localId then state.world.logicalOwners[tostring(localId)] = nil end
  end
end

local function emitOperationCompletion(record, success, result)
  if state.networkMode ~= "network" or record.completionEmitted == true then return true end
  local outputs = {}
  for _, output in ipairs(success and type(result) == "table" and (result.outputs or {}) or {}) do
    outputs[#outputs + 1] = { kind = output.kind, cid = output.cid, slot = output.slot }
  end
  local view = {
    operationId = record.operationId,
    commitSeq = tonumber(record.commitSeq),
    operationDigest = record.transaction.digest,
    success = success == true,
    outputs = outputs,
    postcondition = success and util.deepCopy(result.postcondition) or {},
    coreDigest = coreDigest(),
  }
  local payload = util.deepCopy(view)
  payload.financeDelta = success and util.integer(result.financeDelta, 0) or nil
  payload.resultDigest = hash.value(view)
  if not success then payload.errorCode = "native-operation-failed" end
  local emitted, messageOrError = bridge.emit(
    state.bridge, "operation_completion", payload, state.tick)
  if not emitted then record.completionError = tostring(messageOrError); return false, record.completionError end
  record.completionEmitted = true
  record.completionError = nil
  record.completion = util.deepCopy(payload)
  return true, payload
end

local function finaliseCanonicalOperation(payload)
  payload = type(payload) == "table" and payload or {}
  local operationId = tostring(payload.operationId or "")
  local record = state.world.operations.byId[operationId]
  if not record then return false, "unknown pending canonical operation" end
  if record.status == "applied" then return true, util.deepCopy(record.result) end
  if record.status == "failed" then return false, util.deepCopy(record.result) end
  if payload.success ~= true then
    local ok, result = operationFailure(record,
      { error = tostring(payload.error or "GUI-state native operation was rejected") })
    emitOperationCompletion(record, false, result)
    return ok, result
  end

  local output
  if operationCodec.spec(record.transaction.kind).outputKind then
    local bound, bindError = bindOperationOutput(record, tonumber(payload.outputLocalId))
    if not bound then
      local ok, result = operationFailure(record, bindError)
      emitOperationCompletion(record, false, result)
      return ok, result
    end
    output = bound
  end
  local postcondition, postError = operationPostcondition(
    record, output and output.cid or nil, output and output.localId or nil)
  if not postcondition then
    if output then canonical.unbindCanonical(state.canonical, output.cid) end
    local ok, result = operationFailure(record, postError)
    emitOperationCompletion(record, false, result)
    return ok, result
  end
  if (record.transaction.kind == "line.delete" or record.transaction.kind == "vehicle.sell")
    and postcondition.exists == true then
    local ok, result = operationFailure(record, "native delete/sell left the target entity alive")
    emitOperationCompletion(record, false, result)
    return ok, result
  end
  applyOperationMetadata(record)
  local balanceAfter = tonumber(payload.balanceAfter) or balanceOf(record.nativePlayerId)
  local financeDelta = tonumber(payload.financeDelta) ~= nil
    and util.integer(payload.financeDelta, 0)
    or (balanceAfter and record.balanceBefore
      and util.integer(balanceAfter - record.balanceBefore, 0) or 0)
  local result = {
    operationId = operationId,
    transactionId = record.transaction.transactionId,
    operationDigest = record.transaction.digest,
    kind = record.transaction.kind,
    companyCid = record.companyCid,
    outputs = output and { {
      kind = output.kind, cid = output.cid, slot = output.slot,
    } } or {},
    postcondition = postcondition,
    financeDelta = financeDelta,
  }
  record.status = "applied"
  record.completedTick = state.tick
  record.result = util.deepCopy(result)
  state.world.operations.applied = (state.world.operations.applied or 0) + 1
  state.probes.capture.operationReplayCount =
    (state.probes.capture.operationReplayCount or 0) + 1
  refreshOwnershipProbe()
  emitOperationCompletion(record, true, result)
  return true, result
end

local handlers = {}

handlers["match.initialise"] = function(action)
  return initialiseMatch(action and action.rules)
end

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
  return success, util.deepCopy(outcome)
end

handlers["network.proposal_outcome"] = function(action)
  if state.networkMode ~= "network" then return false, "proposal consensus exists only in network mode" end
  local proposalId = type(action) == "table" and tostring(action.proposalId or "") or ""
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
      status = "faulted",
      proposalDigest = tostring(action.proposalDigest or ""),
      resultDigest = tostring(action.resultDigest or ""),
      coreDigest = tostring(action.coreDigest or ""),
      peers = util.deepCopy(type(action.peers) == "table" and action.peers or {}),
      errorCode = tostring(action.errorCode or "proposal-consensus-failed"),
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
      and tostring(existing.resultDigest or "") == tostring(action.resultDigest or "")
      and tostring(existing.coreDigest or "") == tostring(action.coreDigest or "")
    if not same then return false, "conflicting proposal consensus outcome" end
    return existing.success, util.deepCopy(existing)
  end
  local localCompletion = record.completion
  local success = action.success == true
  if success and (not localCompletion
    or localCompletion.success ~= true
    or tostring(localCompletion.resultDigest or "") ~= tostring(action.resultDigest or "")
    or tostring(localCompletion.coreDigest or "") ~= tostring(action.coreDigest or "")) then
    success = false
    action = util.deepCopy(action)
    action.errorCode = "local-completion-does-not-match-consensus"
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
  local outcome = {
    proposalId = proposalId,
    commitSeq = tonumber(action.commitSeq),
    success = success,
    status = success and "complete" or "faulted",
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
  else
    consensus.failed = (consensus.failed or 0) + 1
    consensus.sessionFault = util.deepCopy(outcome)
  end
  return success, util.deepCopy(outcome)
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

handlers["line.register"] = function(action)
  local running, runningError = requireRunningMatch()
  if not running then return false, runningError end
  local activeCid, _, companyErr = requireCompany()
  local companyCid = action.companyCid or activeCid
  local company = state.companies[companyCid]
  if not company then return false, companyErr or ("unknown company: " .. tostring(companyCid)) end
  local lineId, _, lineErr = lineIdFromAction(action)
  if not lineId then return false, lineErr end
  local result
  if action.market and action.service then
    if action.service.companyCid ~= companyCid or action.service.lineCid ~= action.lineCid then
      return false, "authoritative line service identity mismatch"
    end
    economy.upsertMarket(state.economy, action.market)
    economy.upsertService(state.economy, action.service)
    result = { lineCid = action.lineCid, marketCid = action.market.cid, owner = companyCid, authoritativeFacts = true }
  else
    local ok
    ok, result = world.makeLineService(state.canonical, economy, state.economy, lineId, companyCid)
    if not ok then return false, result end
  end
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
  local results
  if action.results then
    local accepted, resultOrError = economy.acceptAuthoritativeResults(state.economy, action.results)
    if not accepted then return false, resultOrError end
    results = resultOrError
  else
    results = economy.evaluateAll(state.economy)
  end
  local recorded, recordError = economy.recordSettlement(state.economy, results)
  if not recorded then return false, recordError end
  local ok, errors = true, {}
  local nativeReconciliation
  if state.networkMode == "network" then
    state.finance.lastPayouts = {}
    for _, companyCid in ipairs(util.sortedKeys(results.companies or {})) do
      local companyResult = results.companies[companyCid]
      local amount = math.floor((companyResult.revenueCents or 0) / 100)
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
        })
      nativeReconciliation = type(reconciliationOrError) == "table"
        and reconciliationOrError or { error = tostring(reconciliationOrError) }
      if not reconciled then
        ok = false
        errors[#errors + 1] = tostring(nativeReconciliation.error or reconciliationOrError)
      end
    end
  else
    ok, errors = finance.payResults(state.finance, state.companies, results)
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
    local calendarReady = bootstrap.calendarReady == true
    state.probes.networkAuthority = {
      ready = authorityReady and calendarReady,
      mode = "network",
      buildGateEnabled = authorityView.buildGateEnabled,
      commandGateEnabled = authorityView.commandGateEnabled,
      commandVisitors = authorityView.commandVisitors,
      source = "validated-gui-native-bootstrap",
      error = authorityReady and calendarReady and nil
        or tostring(bootstrap.error or "GUI native authority bootstrap was incomplete"),
    }
    if authorityReady and calendarReady then
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

local validationConstruction = {}

function validationConstruction.year()
  local currentYear = 1850
  if type(game.interface.getGameTime) == "function" then
    local timeOk, gameTime = pcall(game.interface.getGameTime)
    local observedYear = timeOk and type(gameTime) == "table" and type(gameTime.date) == "table"
      and tonumber(gameTime.date.year) or nil
    if observedYear then currentYear = math.floor(observedYear) end
  end
  return currentYear
end

function validationConstruction.stationModules(currentYear, catenary)
  local era = currentYear < 1920 and "a" or (currentYear < 1980 and "b" or "c")
  local prefix = "station/rail/modular_station/"
  local eraIndex = era == "a" and 0 or (era == "b" and 1 or 2)
  local passengerCapacity = era == "a" and 20 or (era == "b" and 25 or 30)
  local function stationModule(name, metadata)
    return { name = prefix .. name, metadata = metadata }
  end
  local trackModule = catenary and "platform_track_catenary.module" or "platform_track.module"
  return {
    [3400020] = stationModule("main_building_1_era_" .. era .. ".module", {
      era = eraIndex,
      level = 1,
      span = { 1, 2 },
      moreCapacity = { cargo = 0, passenger = passengerCapacity },
      snapPoint = {
        0, -1, 0, 0,
        1, 0, 0, 0,
        0, 0, 1, 0,
        -14, 0, 0, 1,
      },
    }),
    [7400000] = stationModule("platform_passenger_era_" .. era .. ".module", {
      platform = true, passenger_platform = true,
    }),
    [7400010] = stationModule("platform_passenger_era_" .. era .. ".module", {
      platform = true, passenger_platform = true,
    }),
    [8401000] = stationModule(trackModule, { track = true }),
    [8401010] = stationModule(trackModule, { track = true }),
    [10400000] = stationModule("platform_passenger_roof_era_" .. era .. ".module", {
      platform_roof = true,
    }),
    [10400010] = stationModule("platform_passenger_roof_era_" .. era .. ".module", {
      platform_roof = true,
    }),
    [10800000] = stationModule("addon_platform_passenger_stairs_era_" .. era .. ".module", {
      underground = true,
    }),
  }
end

function validationConstruction.spec(kind, currentYear, edited)
  if kind == "depot" then
    return {
      fileName = "depot/train_depot_era_a.con",
      params = { trackType = 0, catenary = 0, year = currentYear },
    }
  elseif kind == "station" then
    return {
      fileName = "station/rail/modular_station/modular_station.con",
      params = {
        templateIndex = 0,
        tracks = 0,
        length = 0,
        trackType = 0,
        catenary = edited and 1 or 0,
        year = currentYear,
        modules = validationConstruction.stationModules(currentYear, edited == true),
      },
    }
  elseif kind == "asset" then
    return {
      fileName = edited and "asset/default_multi_bench_new.con"
        or "asset/default_multi_bench_old.con",
      params = { paramX = 0, paramY = 0, seed = 0, year = currentYear },
    }
  end
  return nil
end

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
  state.probes.mobility = world.mobilitySnapshot(state.canonical)
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
    totalPersons = payload.totalPersons,
    lineCount = #(payload.lines or {}),
    totals = util.deepCopy(payload.totals),
    emitted = emitted and true or false,
    bridgeError = emitted and nil or tostring(outbound),
  }
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
  report.match = util.deepCopy(state.match)
  report.modelDigest = authoredDigest()
  report.coreDigest = coreDigest()
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
    "BuildProposal has a payload-aware pre-mutation gate. Of the twenty-three additional exact visitor gates, fifteen line/railway-vehicle/name/color tags have strict canonical operation codecs. Native SetGameSpeed is now host-ordered; calendar/logo/field/terrain/date/cheat/person-debug categories stay fail-closed for player input.",
    "Proposal schema 5 canonically serializes road/track changes plus named signal/waypoint edge objects, including retained objects across edge replacement, with quoted cost and no machine-local IDs. Schema 7 adds stock rail-station placement and bounded generic named .con/.module payloads for depots, ordinary constructions, ASSET_DEFAULT roots, upgrades, modular station edits, and removal. Both paths use repository names, strict ownership, preflight and physical consensus. Opaque/script callbacks and ambiguous dependency migration fail closed; every peer still requires an identical pinned mod pack.",
    "Construction uses all-peer prepare before native mutation, then two-peer physical completion consensus, ordered success/fault controls, a bounded timeout, and fail-closed dependency gating. A readiness rejection is non-fatal because neither world changed. Match start and each successful physical result are followed by a host-verified checkpoint barrier; in-place native geometry rollback is deliberately not claimed.",
    "The shared network clock orders pause/speed generations and adaptively caps the effective speed from peer heartbeat, engine-tick and command-backlog health. It is offline-tested but still needs live pause/resume and slowdown/recovery proof; it is not deterministic native-agent lockstep.",
    "Line/vehicle creation IDs are discovered from the native callback result or an exact before/after component-set delta, then bound to event-derived canonical IDs.",
    "The GUI rejects known mutating actions against rival logical entities. Native visitors now stop selected unsupported line, vehicle, naming, speed, terrain, date, and cheat commands in network mode; unlisted/autonomous categories still require dedicated authority analysis.",
    "Populated local hot-seat validation covers stations, depots, lines, two running trains and real passenger/cargo trips. Canonical network sale/replacement/maintenance and long-running income/expense still require live destructive tests.",
    "Native loan principal is not mirrored; borrowing/repayment is disabled on the turn desk and requires a dedicated competitive credit model.",
    "The desk retains the base game's loan, so unpaused month-boundary interest can contaminate a long proxy turn; pause-on-switch is the supported local-test configuration.",
    "Company starting cash is an explicit, idempotent match-setup grant; it is audited separately and is not a money-conserving operational transfer.",
    "Build 35924 asserts when legacy setPlayer is used directly on BASE_EDGE. Tracked edges therefore use logical ownership and normally stay on the desk; a depot/station transfer may cascade attached edges to their rightful company. Either native holder is valid, rival holders fail closed, and rival builder proposals are vetoed before commit.",
    "Autonomous town/industry evolution is not yet a complete host-driven replicated event system; unsupported subsystems must remain frozen for network experiments.",
    "Native person and cargo entity IDs are intentionally treated as local; only canonical aggregate counts are compared across peers. Direct SIM_* component fallback is implemented but must be re-proven in a populated Build 35924 session.",
    "Passenger/cargo steering is not implemented, so native loads and queues can still disagree with the authoritative competitive score.",
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

function networkClock.apply(action)
  if state.networkMode ~= "network" then return false, "ordered clock control is network-only" end
  local requested = util.integer(action and action.requestedSpeed, -1)
  local effective = util.integer(action and action.effectiveSpeed, -1)
  local generation = util.integer(action and action.generation, -1)
  if requested < 0 or requested > 4 or effective < 0 or effective > requested then
    return false, "invalid requested/effective network speed"
  end
  local current = state.world.networkClock
  if generation <= util.integer(current.generation, 0) then
    return false, "stale network clock generation"
  end
  local factory = util.commandFactory("setGameSpeed")
  local authorize = rawget(_G, "tpf2mp_native_authorize_command")
  if not factory or type(authorize) ~= "function"
    or not (api and api.cmd and type(api.cmd.sendCommand) == "function") then
    return false, "network clock requires SetGameSpeed factory and native tag-0 authority"
  end
  local made, commandOrError = pcall(factory, effective)
  if not made then return false, "could not create SetGameSpeed: " .. tostring(commandOrError) end
  local called, authorized, authorizeError = pcall(authorize, "0")
  if not called or authorized == false then
    return false, "could not authorize SetGameSpeed: " .. tostring(authorizeError or authorized)
  end

  local previous = util.deepCopy(current)
  current.requestedSpeed = requested
  current.effectiveSpeed = effective
  current.generation = generation
  current.reason = tostring(action.reason or "host-order")
  current.lastCommandTick = state.tick
  current.lastError = nil
  local sent, sendError = util.sendCommand(commandOrError, function(_, success)
    current.lastNativeSuccess = success == true
    if success ~= true then current.lastError = "native SetGameSpeed command was rejected" end
  end, "mod.network.set-game-speed")
  if not sent then
    state.world.networkClock = previous
    return false, "could not issue SetGameSpeed: " .. tostring(sendError)
  end
  return true, {
    requestedSpeed = requested,
    effectiveSpeed = effective,
    generation = generation,
    reason = current.reason,
  }
end

function networkClock.emitHealth()
  if state.networkMode ~= "network" or not state.initialized or state.tick % 15 ~= 0 then
    return false
  end
  local observed = world.clockSnapshot()
  local clock = state.world.networkClock
  local proposalPending = false
  for _, record in pairs(state.world.proposalConsensus.byId or {}) do
    if record.status == "pending" then proposalPending = true; break end
  end
  local ok, envelope = bridge.emit(state.bridge, "clock_health", {
    schemaVersion = 1,
    requestedSpeed = util.integer(clock.requestedSpeed, 0),
    effectiveSpeed = util.integer(clock.effectiveSpeed, 0),
    generation = util.integer(clock.generation, 0),
    observedSpeed = tonumber(observed.gameSpeed),
    gameTime = tonumber(observed.time),
    engineTick = state.tick,
    lastCommitSeq = math.max(0, util.integer((state.bridge.nextInSeq or 1) - 1, 0)),
    proposalPending = proposalPending,
  }, state.tick)
  if ok then
    clock.healthEmitted = (clock.healthEmitted or 0) + 1
    clock.lastHealthLocalSeq = envelope.local_seq
  else
    clock.lastError = tostring(envelope)
  end
  return ok
end

handlers["clock.set"] = function(action)
  return networkClock.apply(action)
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
  if mode == "network" and state.networkMode ~= "network" and state.initialized then
    return false, "network mode must be selected before match initialisation"
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
  return emitCheckpoint(action and action.reason or "manual")
end

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

local function operationModelNames(value, output, seen)
  output, seen = output or {}, seen or {}
  if type(value) == "string" then
    local normalized = value:gsub("\\", "/")
    if normalized:sub(1, 14) == "vehicle/train/" and normalized:sub(-4) == ".mdl" then
      output[#output + 1] = normalized
    end
  elseif type(value) == "table" and not seen[value] then
    seen[value] = true
    for _, key in ipairs(util.sortedKeys(value)) do operationModelNames(value[key], output, seen) end
    seen[value] = nil
  end
  return output
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
        }
      end
    else
      for _, localId in ipairs(capture.stationGroupLocalIds or {}) do
        local groupId, groupError = world.stationGroupFor(localId)
        if not groupId then return nil, groupError end
        local cid, cidError = bindLocal(groupId, "station_group")
        if not cid then return nil, cidError end
        encodedStops[#encodedStops + 1] = {
          stationGroupCid = cid, station = 0, terminal = 0,
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
    local depotCid, depotError = bindLocal(capture.depotLocalId, "depot")
    if not depotCid then return nil, depotError end
    local names = operationModelNames(capture.modelNames or capture.vehicleConfig)
    data = { depotCid = depotCid, config = operationCodec.defaultVehicleConfig(names) }
  elseif kind == "vehicle.replace" then
    local targetCid, targetError = bindLocal(capture.targetLocalId, "vehicle")
    if not targetCid then return nil, targetError end
    local names = operationModelNames(capture.modelNames or capture.vehicleConfig)
    data = { targetCid = targetCid, config = operationCodec.defaultVehicleConfig(names) }
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
        if state.networkMode == "network" and targetCid:find(":pre:", 1, true)
          and not (binding and binding.metadata and binding.metadata.manifestBound == true) then
          targetCid = nil
          targetError = "selected pre-existing line is ambiguous across peers"
        elseif binding and binding.metadata and binding.metadata.owner
          and binding.metadata.owner ~= companyCid then
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
    -- Keep the table bounded even if authority rejects an intent before it is
    -- ordered. Tokens are monotonic, so stale entries can never attach to a
    -- later operation accidentally.
    if util.tableCount(proposalPreparation.originAppliedOperations) >= 64 then
      local oldestToken, oldestSequence
      for token, pending in pairs(proposalPreparation.originAppliedOperations) do
        local sequence = tonumber(pending.sequence) or math.huge
        if oldestSequence == nil or sequence < oldestSequence then
          oldestToken, oldestSequence = token, sequence
        end
      end
      if oldestToken then proposalPreparation.originAppliedOperations[oldestToken] = nil end
    end
    local sequence = proposalPreparation.nextOriginToken
    proposalPreparation.nextOriginToken = proposalPreparation.nextOriginToken + 1
    originCaptureToken = tostring(state.bridge.peerId) .. ":operation-origin:" .. tostring(sequence)
    proposalPreparation.originAppliedOperations[originCaptureToken] = {
      sequence = sequence,
      localId = localId,
      kind = kind,
      companyCid = companyCid,
      transactionId = transaction.transactionId,
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
    local preview = util.deepCopy(state.economy)
    local ok, result = world.makeLineService(state.canonical, economy, preview, lineId, companyCid)
    if not ok then return nil, result end
    copy.companyCid = companyCid
    copy.market = util.deepCopy(preview.markets[result.marketCid])
    copy.service = util.deepCopy(preview.services[result.lineCid])
  elseif copy.type == "operation.execute" then
    local companyCid, company, companyError = requireCompany()
    if not company then return nil, companyError end
    if copy.transaction.companyCid ~= companyCid then
      return nil, "canonical operation company does not match this peer's assigned company"
    end
  elseif copy.type == "economy.settle" then
    if state.bridge.peerId ~= "player1" then return nil, "only the host peer can settle the authoritative economy" end
    local preview = util.deepCopy(state.economy)
    copy.results = economy.evaluateAll(preview)
  elseif copy.type == "probe.mobility" then
    if state.bridge.peerId ~= "player1" then return nil, "only the host peer can request an ordered mobility sample" end
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
  if success and action.type == "match.initialise" then
    local checkpointed, checkpointError
    if state.networkMode == "network" and authoritySeq then
      checkpointed, checkpointError = exportCheckpointBarrier(authoritySeq, "match-initialised")
    else
      checkpointed, checkpointError = emitCheckpoint("match-initialised")
    end
    if not checkpointed then
      diagnosticLog("checkpoint-error", { tick = state.tick, error = tostring(checkpointError) })
    end
  elseif success and action.type == "network.proposal_outcome"
    and action.success == true and authoritySeq then
    local reason = "physical-consensus:" .. tostring(action.proposalId or "unknown")
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

local function networkPendingBarrierReason()
  for digest, preparation in pairs(proposalPreparation.pending) do
    return "proposal is prepared and awaiting host commit: "
      .. tostring(preparation.transactionId or digest)
  end
  for _, boundarySeq in ipairs(util.sortedKeys(state.world.checkpointConsensus.byBoundary or {})) do
    local outcome = state.world.checkpointConsensus.byBoundary[boundarySeq]
    if outcome.status == "pending" then
      return "checkpoint boundary is awaiting two-peer consensus: " .. tostring(boundarySeq)
    end
  end
  for _, proposalId in ipairs(util.sortedKeys(state.world.proposalConsensus.byId or {})) do
    local outcome = state.world.proposalConsensus.byId[proposalId]
    if outcome.status == "pending" then
      return "physical proposal is awaiting two-peer consensus: " .. tostring(proposalId)
    end
  end
  for _, operationId in ipairs(util.sortedKeys(state.world.operationConsensus.byId or {})) do
    local outcome = state.world.operationConsensus.byId[operationId]
    if outcome.status == "pending" then
      return "physical operation is awaiting two-peer consensus: " .. tostring(operationId)
    end
  end
  return nil
end

local function emitNetworkIntent(action)
  local networkAction, err = normaliseForNetwork(action)
  if not networkAction then state.lastError = tostring(err); publishSnapshot(); return false, err end
  local ok, messageOrError = bridge.emit(state.bridge, "intent", { action = networkAction }, state.tick)
  state.lastAction = networkAction
  state.lastResult = ok and { queued = true, localSeq = messageOrError.local_seq } or messageOrError
  if ok then
    state.lastError = nil
    networkIntentAwaitingOrder = {
      localSeq = tonumber(messageOrError.local_seq),
      type = networkAction.type,
      emittedTick = state.tick,
    }
  else
    state.lastError = tostring(messageOrError)
  end
  publishSnapshot()
  return ok, messageOrError
end

local function submitIntent(action)
  if type(action) ~= "table" then return false, "action must be a table" end
  if action.type == "operation.capture" then
    local normalized, normalizeError = normaliseOperationCapture(action)
    if not normalized then
      state.lastError = tostring(normalizeError)
      publishSnapshot()
      return false, normalizeError
    end
    action = normalized
  end
  local localControl = action.type == "network.set_mode" or action.type == "snapshot.export"
    or action.type == "checkpoint.export"
    or action.type == "native.build_gate" or action.type == "native.build_authorize"
    or action.type == "native.command_gate" or action.type == "native.command_authorize"
    or action.type == "native.observed" or action.type == "probe.run" or action.type == "probe.export_research"
    or action.type == "probe.gui_capabilities"
    or action.type == "company.cycle" or action.type == "company.reconcile"
    or action.type == "finance.repair_starting_cash"
  if state.networkMode ~= "network" or localControl or action.localOnly then
    local ok, result = applyCommitted(action, state.bridge.peerId, nil)
    publishSnapshot()
    return ok, result
  end
  local authority = state.probes.networkAuthority or {}
  if authority.ready ~= true then
    state.lastError = "network authority is not ready: "
      .. tostring(authority.error or "native gates unavailable")
    publishSnapshot()
    return false, state.lastError
  end
  local networkAccounts = finance.ensureNetworkAccounts(state.finance)
  if state.initialized and networkAccounts.initialized ~= true then
    state.lastError = tostring(networkAccounts.migrationError
      or "canonical network accounts are not initialised; start a fresh match")
    publishSnapshot()
    return false, state.lastError
  end
  if action.type == "clock.request" then
    local faulted = state.world.proposalConsensus.sessionFault
      or state.world.operationConsensus.sessionFault
    if faulted and util.integer(action.requestedSpeed, -1) ~= 0 then
      state.lastError = "a faulted multiplayer session may only be paused"
      publishSnapshot()
      return false, state.lastError
    end
    return emitNetworkIntent(action)
  end
  local consensus = state.world.proposalConsensus
  if consensus.sessionFault then
    local reason = consensus.sessionFault.errorCode or "proposal-consensus-failed"
    state.lastError = "network session is faulted: " .. tostring(reason)
    publishSnapshot()
    return false, state.lastError
  end
  local operationConsensus = state.world.operationConsensus
  if operationConsensus.sessionFault then
    local reason = operationConsensus.sessionFault.errorCode or "operation-consensus-failed"
    state.lastError = "network session is faulted: " .. tostring(reason)
    publishSnapshot()
    return false, state.lastError
  end
  local pendingReason = networkPendingBarrierReason()
  if not pendingReason and networkIntentAwaitingOrder then
    pendingReason = "local intent is awaiting its host order: "
      .. tostring(networkIntentAwaitingOrder.localSeq or "-")
  end
  if not pendingReason and #deferredNetworkIntents > 0 then
    pendingReason = "earlier multiplayer physical actions are queued locally"
  end
  if pendingReason then
    local deferablePhysical = action.type == "proposal.capture" or action.type == "proposal.prepare"
      or action.type == "proposal.build" or action.type == "operation.execute"
    if deferablePhysical and #deferredNetworkIntents < MAX_DEFERRED_NETWORK_INTENTS then
      deferredNetworkIntents[#deferredNetworkIntents + 1] = {
        action = util.deepCopy(action),
        companyCid = action.companyCid
          or (type(action.transaction) == "table" and action.transaction.companyCid)
          or activeCompany(),
        queuedTick = state.tick,
        reason = pendingReason,
      }
      local queuePosition = #deferredNetworkIntents
      diagnosticLog("network-intent-deferred", {
        type = action.type,
        companyCid = deferredNetworkIntents[queuePosition].companyCid,
        reason = pendingReason,
        queuePosition = queuePosition,
        queueDepth = queuePosition,
        awaitingLocalSeq = networkIntentAwaitingOrder
          and networkIntentAwaitingOrder.localSeq or nil,
        tick = state.tick,
      })
      state.lastAction = { type = action.type, deferred = true, queuePosition = queuePosition }
      state.lastResult = {
        queued = true,
        deferred = true,
        queuedTick = state.tick,
        reason = pendingReason,
        queuePosition = queuePosition,
        queueDepth = queuePosition,
        queueCapacity = MAX_DEFERRED_NETWORK_INTENTS,
      }
      state.lastError = nil
      publishSnapshot()
      return true, util.deepCopy(state.lastResult)
    elseif deferablePhysical then
      state.lastError = "multiplayer physical-action queue is full ("
        .. tostring(MAX_DEFERRED_NETWORK_INTENTS) .. "); wait for synchronization"
      publishSnapshot()
      return false, state.lastError
    else
      state.lastError = pendingReason
      publishSnapshot()
      return false, state.lastError
    end
  end
  return emitNetworkIntent(action)
end

local function processDeferredNetworkIntent()
  local pending = deferredNetworkIntents[1]
  if not pending then return false end
  local consensus = state.world.proposalConsensus or {}
  local operationConsensus = state.world.operationConsensus or {}
  if consensus.sessionFault or operationConsensus.sessionFault then
    local count = #deferredNetworkIntents
    deferredNetworkIntents = {}
    local fault = consensus.sessionFault or operationConsensus.sessionFault or {}
    state.lastError = tostring(count) .. " queued multiplayer physical action(s) discarded because the session faulted: "
      .. tostring(fault.errorCode or "consensus-failed")
    publishSnapshot()
    return true
  end
  if networkIntentAwaitingOrder then
    pending.reason = "local intent is awaiting its host order: "
      .. tostring(networkIntentAwaitingOrder.localSeq or "-")
    if pending.lastLoggedReason ~= pending.reason then
      pending.lastLoggedReason = pending.reason
      diagnosticLog("network-intent-deferred-blocked", {
        type = pending.action and pending.action.type or nil,
        reason = pending.reason,
        queueDepth = #deferredNetworkIntents,
        tick = state.tick,
      })
    end
    return false
  end
  local pendingReason = networkPendingBarrierReason()
  if pendingReason then
    pending.reason = pendingReason
    if pending.lastLoggedReason ~= pending.reason then
      pending.lastLoggedReason = pending.reason
      diagnosticLog("network-intent-deferred-blocked", {
        type = pending.action and pending.action.type or nil,
        reason = pending.reason,
        queueDepth = #deferredNetworkIntents,
        tick = state.tick,
      })
    end
    return false
  end
  table.remove(deferredNetworkIntents, 1)
  if state.networkMode ~= "network" then
    local discarded = 1 + #deferredNetworkIntents
    deferredNetworkIntents = {}
    state.lastError = tostring(discarded)
      .. " deferred multiplayer physical action(s) discarded because network mode ended"
    publishSnapshot()
    return true
  end
  local ok, result = emitNetworkIntent(pending.action)
  if ok then
    diagnosticLog("network-intent-deferred-emitted", {
      type = pending.action and pending.action.type or nil,
      deferredFromTick = pending.queuedTick,
      queueRemaining = #deferredNetworkIntents,
      localSeq = type(result) == "table" and result.local_seq or nil,
      tick = state.tick,
    })
    if type(state.lastResult) == "table" then
      state.lastResult.deferred = true
      state.lastResult.deferredFromTick = pending.queuedTick
      state.lastResult.queueRemaining = #deferredNetworkIntents
    end
  else
    state.lastError = "deferred multiplayer physical action failed: "
      .. tostring(type(result) == "table" and result.error or result)
  end
  publishSnapshot()
  return true
end

local function consumeBridge()
  if state.networkMode ~= "network" then return end
  local authority = state.probes.networkAuthority or {}
  if authority.ready ~= true then
    state.lastError = "network authority is not ready: "
      .. tostring(authority.error or "native gates unavailable")
    return
  end
  for _, message in ipairs(bridge.poll(state.bridge, 16)) do
    if message.kind == "commit" and message.payload and message.payload.action then
      local originPeer = message.origin_peer or message.peer
      if networkIntentAwaitingOrder and originPeer == state.bridge.peerId
        and tonumber(message.origin_local_seq) == tonumber(networkIntentAwaitingOrder.localSeq) then
        networkIntentAwaitingOrder = nil
      end
      local ok, result, event = applyCommitted(message.payload.action, originPeer, message.seq)
      local acknowledgement = {
        commitSeq = message.seq,
        success = ok,
        digest = event and event.postDigest or coreDigest(),
      }
      if not ok then
        acknowledgement.error = tostring(type(result) == "table" and result.error or result)
      end
      bridge.emit(state.bridge, "ack", acknowledgement, state.tick)
      publishSnapshot()
    elseif message.kind == "control" and message.payload and message.payload.action then
      local action = message.payload.action
      if action.type == "network.intent_rejected" then
        local matchesOrigin = tostring(action.originPeer or "") == tostring(state.bridge.peerId)
          and networkIntentAwaitingOrder
          and tonumber(action.originLocalSeq) == tonumber(networkIntentAwaitingOrder.localSeq)
        if matchesOrigin then networkIntentAwaitingOrder = nil end
        diagnosticLog("network-intent-rejected", {
          originPeer = action.originPeer,
          originLocalSeq = action.originLocalSeq,
          actionType = action.actionType,
          error = action.errorCode,
          released = matchesOrigin == true,
          tick = state.tick,
        })
        if matchesOrigin then
          state.lastError = "network intent rejected: " .. tostring(action.errorCode or "unknown")
        end
      else
        applyCommitted(action, message.origin_peer or "host", message.seq)
      end
      publishSnapshot()
    end
  end
end

local gui = {
  window = nil,
  status = nil,
  details = nil,
  queue = {},
  selectedLineId = nil,
  selectedVehicleId = nil,
  selectedDepotId = nil,
  routeDraft = {},
  selectedEntityId = nil,
  selectedEntityKind = nil,
  snapshot = nil,
  frames = 0,
  nextCaptureId = 1,
  pendingVehicleCaptures = {},
  proposalIssued = {},
  proposalResults = {},
  pendingProposalCaptures = {},
  operationIssued = {},
  operationResults = {},
  pendingOperationCaptures = {},
  builderContext = nil,
  pendingNetworkBuildPreview = nil,
  pendingNetworkBuildExact = nil,
  pendingNetworkBuildSuppression = nil,
  buildGateSuppressedSeen = nil,
  observerSuppressionCredits = 0,
  networkAuthorityBootstrap = nil,
  awaitingManualHandoff = false,
  manualHandoffReady = false,
  nativeBuildCapture = {
    captured = 0,
    duplicates = 0,
    orphaned = 0,
    counterResets = 0,
    exactCaptures = 0,
    previewFallbacks = 0,
    constructionPreviewsProjected = 0,
    constructionPreviewsSkipped = 0,
    coalescedConstructionSuppressions = 0,
  },
  nativeClockCapture = {
    captured = 0,
    invalid = 0,
    duplicates = 0,
    lastRequestedSpeed = nil,
  },
  nativeLineKnownIds = nil,
  -- A stock Line Manager callback can publish its new LINE entity one GUI
  -- update before the native visitor capture becomes readable.  Keep only
  -- those post-baseline additions for a short, machine-local correlation
  -- window so that ordering cannot make an otherwise valid New Line vanish.
  nativeLineRecentAdded = {},
  pendingNativeLinePassThroughCaptures = {},
  nativeLineCapture = {
    captured = 0,
    invalid = 0,
    creates = 0,
    deletes = 0,
    updates = 0,
    names = 0,
    colors = 0,
    lastTag = nil,
    lastTarget = nil,
    lastStopCount = 0,
  },
  lastNetworkProposalDigest = nil,
  lastNetworkProposalFrame = -1000,
  lastProposalProbeFrame = -1000,
  lastConstructionPreviewDecision = nil,
  lastConstructionPreviewSnapshot = nil,
  lastConstructionPreviewPlacement = nil,
  lastConstructionPreviewSignature = nil,
  lastConstructionPreviewModuleSentinels = nil,
  lastAccessDenialProbeFrame = -1000,
  lastEntityAccessDenialProbeFrame = -1000,
  lastOperationalGuiDigest = nil,
  lastOperationalGuiFrame = -1000,
  lastError = nil,
}

local function compactResult(value)
  if value == nil then return "-" end
  if type(value) ~= "table" then return tostring(value) end
  if value.mode then return "mode=" .. tostring(value.mode) end
  if value.lineCid then return tostring(value.lineCid) .. (value.fareCents and (" fare=" .. value.fareCents .. "c") or "") end
  if value.queued then return "queued seq " .. tostring(value.localSeq) end
  if value.mobilityDigest then return "mobility=" .. tostring(value.mobilityDigest) end
  if value.structuralDigest then return "world=" .. tostring(value.structuralDigest) end
  return "table"
end

local function renderGui()
  if not gui.status then return end
  local snapshot = gui.snapshot or publicSnapshot()
  local companion = snapshot.bridge and snapshot.bridge.companion or {}
  local linkStatus = snapshot.networkMode ~= "network" and "local"
    or (companion.connected == true and "connected" or tostring(companion.status or "offline"))
  local status = string.format(
    "Mode: %s | Peer: %s | Link: %s | Active: %s | Proxy: %s | Selected: %s (%s) | Markets: %d | Services: %d | Epoch: %d",
    tostring(snapshot.networkMode or "?"),
    tostring(snapshot.peerId or "?"),
    linkStatus,
    tostring(snapshot.activeCompanyName or "not initialised"),
    tostring(snapshot.proxyMode == true),
    tostring(gui.selectedEntityId or "none"),
    tostring(gui.selectedEntityKind or "-"),
    tonumber(snapshot.marketCount) or 0,
    tonumber(snapshot.serviceCount) or 0,
    tonumber(snapshot.epoch) or 0
  )
  gui.status:setText(status)
  local lines = {
    "Session: " .. tostring(snapshot.sessionId or "?") .. " | digest " .. tostring(snapshot.digest or "?"),
    string.format("Match: %s | epoch limit %s | value target %.2f | winner %s",
      tostring(snapshot.match and snapshot.match.status or "setup"),
      tostring(snapshot.match and snapshot.match.rules and snapshot.match.rules.maxEpochs or "-"),
      (snapshot.match and snapshot.match.rules and snapshot.match.rules.valuationTargetCents or 0) / 100,
      tostring(snapshot.match and snapshot.match.winnerCid or "-")),
    string.format("Starting cash: target %.0f | setup grants %.0f | repairs %d%s",
      snapshot.startingCash and snapshot.startingCash.target or 0,
      snapshot.startingCash and snapshot.startingCash.totalGranted or 0,
      snapshot.startingCash and snapshot.startingCash.repairs or 0,
      snapshot.startingCash and snapshot.startingCash.lastError and (" | ERROR " .. tostring(snapshot.startingCash.lastError)) or ""),
    "Canonical objects: " .. tostring(snapshot.canonicalCount or 0) .. " | autonomy frozen: " .. tostring(snapshot.autonomyFrozen == true),
    "World manifest: " .. tostring(snapshot.probes and snapshot.probes.worldManifestDigest or "-")
      .. " | ambiguous operational fingerprints "
      .. tostring(snapshot.probes and snapshot.probes.worldManifest
        and snapshot.probes.worldManifest.ambiguousCount or 0)
      .. " | deferred scenery "
      .. tostring(snapshot.probes and snapshot.probes.worldManifest
        and snapshot.probes.worldManifest.deferredUnique or 0),
    "Bridge out/in: " .. tostring(snapshot.bridge and snapshot.bridge.emitted or 0) .. "/" .. tostring(snapshot.bridge and snapshot.bridge.received or 0),
    "Last result: " .. compactResult(snapshot.lastResult),
    "Route draft: " .. tostring(#(gui.routeDraft or {}))
      .. " stops | retained line " .. tostring(gui.selectedLineId or "-")
      .. " | vehicle " .. tostring(gui.selectedVehicleId or "-")
      .. " | depot " .. tostring(gui.selectedDepotId or "-"),
  }
  if snapshot.networkMode == "network" then
    local endpoint = companion.role == "host"
      and (tostring(companion.bind or "?") .. ":" .. tostring(companion.port or "?"))
      or (tostring(companion.host or "?") .. ":" .. tostring(companion.port or "?"))
    local peers = type(companion.connectedPeers) == "table"
      and table.concat(companion.connectedPeers, ",") or "-"
    lines[#lines + 1] = string.format(
      "Companion: %s/%s | endpoint %s | TCP %s | remote peers %s",
      tostring(companion.role or "missing"),
      tostring(companion.status or "not-running"),
      endpoint,
      companion.connected == true and "connected" or "waiting",
      peers
    )
    local capture = gui.nativeBuildCapture or {}
    lines[#lines + 1] = string.format(
      "Vanilla build bridge: %s | captured %d (%d exact/%d fallback) | duplicate %d | unmatched %d | construction previews %d/%d projected/skipped",
      gui.pendingNetworkBuildSuppression and "settling click"
        or (gui.pendingNetworkBuildExact and "exact click latched"
          or (gui.pendingNetworkBuildPreview and "preview armed" or "idle")),
      tonumber(capture.captured) or 0,
      tonumber(capture.exactCaptures) or 0,
      tonumber(capture.previewFallbacks) or 0,
      tonumber(capture.duplicates) or 0,
      tonumber(capture.orphaned) or 0,
      tonumber(capture.constructionPreviewsProjected) or 0,
      tonumber(capture.constructionPreviewsSkipped) or 0
    )
    local clock = snapshot.networkClock or {}
    lines[#lines + 1] = string.format(
      "Shared clock: requested %s | effective %s | generation %s | %s",
      tostring(clock.requestedSpeed or 0),
      tostring(clock.effectiveSpeed or 0),
      tostring(clock.generation or 0),
      tostring(clock.reason or "waiting for host"))
    local clockCapture = gui.nativeClockCapture or {}
    lines[#lines + 1] = string.format(
      "Vanilla clock bridge: captured %d | duplicate %d | invalid %d | last %s",
      tonumber(clockCapture.captured) or 0,
      tonumber(clockCapture.duplicates) or 0,
      tonumber(clockCapture.invalid) or 0,
      tostring(clockCapture.lastRequestedSpeed or "-"))
  end
  if snapshot.validation and snapshot.validation.enabled then
    lines[#lines + 1] = string.format(
      "Unattended validation: %s | stage %s | checks %d",
      tostring(snapshot.validation.status or "?"),
      tostring(snapshot.validation.stage or "?"),
      #(snapshot.validation.checks or {})
    )
  end
  if snapshot.turn and snapshot.turn.lastFailure then
    local failure = snapshot.turn.lastFailure
    local migration = failure.failure and failure.failure.migration or nil
    local failedAssets = failure.failed or (migration and migration.failed) or {}
    local recoveryFailures = failure.recoveryFailed or (migration and migration.recoveryFailed) or {}
    lines[#lines + 1] = string.format(
      "TURN FAILURE: stage %s at tick %s | failed assets %d | recovery failures %d",
      tostring(failure.stage or "unknown"),
      tostring(failure.tick or "?"),
      #failedAssets,
      #recoveryFailures
    )
  end
  local errorText = gui.lastError or snapshot.lastError or (snapshot.bridge and snapshot.bridge.lastError)
  if errorText then lines[#lines + 1] = "ERROR: " .. tostring(errorText) end
  local results = snapshot.lastResults or {}
  local scoreboard = snapshot.scoreboard or {}
  for _, companyCid in ipairs(snapshot.companyOrder or {}) do
    local company = snapshot.companies and snapshot.companies[companyCid] or {}
    local score = results.companies and results.companies[companyCid] or {}
    local total = scoreboard[companyCid] or {}
    lines[#lines + 1] = string.format(
      "%s: balance %.0f, loan %.0f | assets %d | epoch demand %d, revenue %.2f | value %.2f, reach %d, wins %d",
      company.name or companyCid,
      company.effectiveBalance or company.balance or 0,
      company.loan or 0,
      company.assets and company.assets.total or 0,
      score.demand or 0,
      (score.revenueCents or 0) / 100,
      (total.modelValueCents or 0) / 100,
      total.marketsReached or 0,
      total.marketWins or 0
    )
  end
  local shownMarkets = 0
  for _, marketCid in ipairs(util.sortedKeys(results.markets or {})) do
    if shownMarkets >= 8 then break end
    shownMarkets = shownMarkets + 1
    local market = results.markets[marketCid]
    lines[#lines + 1] = string.format("Market %s: demand %d, outside %d", market.name or marketCid, market.demand or 0, market.outside or 0)
    for _, lineCid in ipairs(util.sortedKeys(market.services or {})) do
      local service = market.services[lineCid]
      local factors = service.factors or {}
      lines[#lines + 1] = string.format(
        "  %s: %d pax (%d.%02d%%), fare %.2f | freq +%d time +%d quality +%d fare -%d",
        service.name or lineCid,
        service.allocated or 0,
        math.floor((service.shareBasisPoints or 0) / 100),
        (service.shareBasisPoints or 0) % 100,
        (service.fareCents or 0) / 100,
        factors.frequency or 0,
        factors.journey or 0,
        factors.quality or 0,
        factors.farePenalty or 0
      )
    end
  end
  local capture = snapshot.probes and snapshot.probes.capture or {}
  lines[#lines + 1] = string.format(
    "Observed proposals GUI/native/commits: %d/%d/%d | vehicle accepts/resolved: %d/%d | claimed: %d",
    capture.preCommitCount or 0,
    capture.nativePreCommitCount or 0,
    capture.postCommitCount or 0,
    capture.vehicleIntentCount or 0,
    capture.vehicleResolvedCount or 0,
    capture.claimedCount or 0
  )
  local operational = snapshot.probes and snapshot.probes.operational or {}
  if operational.enabled then
    local sample = operational.lastSample or {}
    lines[#lines + 1] = string.format(
      "OPERATIONAL CAPTURE ONLY (not synchronized): samples %d | speed %s | lines %d | vehicles %d | native commands %d | GUI actions %d",
      operational.sampleCount or 0,
      tostring(sample.gameSpeed or "-"),
      sample.lineCount or 0,
      sample.vehicleCount or 0,
      capture.nativeCommandCount or 0,
      capture.operationalGuiCount or 0
    )
    if operational.autoInit and operational.autoInit.success ~= true then
      lines[#lines + 1] = "CAPTURE AUTO-INIT ERROR: " .. tostring(operational.autoInit.error or "unknown")
    end
  end
  lines[#lines + 1] = string.format(
    "Edge replacements observed/rebound/failures/recoveries: %d/%d/%d/%d",
    capture.replacementObservedCount or 0,
    capture.replacementReboundCount or 0,
    capture.replacementFailureCount or 0,
    capture.replacementRecoveryCount or 0
  )
  lines[#lines + 1] = string.format(
    "Rival edits blocked before commit: proposals %d | entity actions %d",
    capture.accessDeniedCount or 0,
    capture.entityAccessDeniedCount or 0
  )
  local proposals = snapshot.proposals or {}
  lines[#lines + 1] = string.format(
    "Canonical proposals queued/applied/failed/retained: %d/%d/%d/%d",
    proposals.queued or 0, proposals.applied or 0, proposals.failed or 0, proposals.retained or 0
  )
  local operations = snapshot.operations or {}
  lines[#lines + 1] = string.format(
    "Canonical line/vehicle operations queued/applied/failed/retained: %d/%d/%d/%d",
    operations.queued or 0, operations.applied or 0,
    operations.failed or 0, operations.retained or 0)
  local consensus = snapshot.proposalConsensus or {}
  lines[#lines + 1] = string.format(
    "Physical consensus pending/complete/faulted: %d/%d/%d | session %s",
    consensus.pending or 0,
    consensus.completed or 0,
    consensus.failed or 0,
    consensus.sessionFault and "FAULTED" or "healthy"
  )
  local operationConsensus = snapshot.operationConsensus or {}
  lines[#lines + 1] = string.format(
    "Operation consensus pending/complete/faulted: %d/%d/%d | session %s",
    operationConsensus.pending or 0,
    operationConsensus.completed or 0,
    operationConsensus.failed or 0,
    operationConsensus.sessionFault and "FAULTED" or "healthy")
  local checkpoints = snapshot.checkpointConsensus or {}
  lines[#lines + 1] = string.format(
    "Checkpoint barriers pending/complete/faulted: %d/%d/%d | last agreed %s",
    checkpoints.pending or 0,
    checkpoints.completed or 0,
    checkpoints.failed or 0,
    checkpoints.lastAgreed and tostring(checkpoints.lastAgreed.boundarySeq or "yes") or "-"
  )
  local deferred = snapshot.deferredNetworkIntent
  if deferred then
    lines[#lines + 1] = string.format(
      "Queued multiplayer physical actions: %d/%d | oldest tick %s | %s",
      deferred.queueDepth or 1,
      deferred.capacity or MAX_DEFERRED_NETWORK_INTENTS,
      tostring(deferred.queuedTick or "-"),
      tostring(deferred.reason or "waiting for authority"))
  end
  local deferredQueue = snapshot.deferredNetworkQueue or {}
  if deferredQueue.awaitingOrder then
    lines[#lines + 1] = string.format(
      "Outbound intent %s awaiting host order | %s",
      tostring(deferredQueue.awaitingOrder.localSeq or "-"),
      tostring(deferredQueue.awaitingOrder.type or "action"))
  end
  local mobility = snapshot.probes and snapshot.probes.mobility or nil
  if mobility then
    lines[#lines + 1] = string.format(
      "Native mobility: people %s | line uses pax %s cargo %s | vehicles %s | digest %s",
      tostring(mobility.totalPersons or "-"),
      tostring(mobility.totals and mobility.totals.passengerLineUses or "-"),
      tostring(mobility.totals and mobility.totals.cargoLineUses or "-"),
      tostring(mobility.totals and mobility.totals.vehicles or "-"),
      tostring(snapshot.probes.mobilityDigest or "-")
    )
  end
  local native = snapshot.probes and snapshot.probes.nativeHook or {}
  lines[#lines + 1] = string.format(
    "Native hook: %s | stage %s | active %s",
    native.available == true and "loaded" or "not loaded",
    tostring(native.stage or "-"),
    tostring(native.active == true)
  )
  lines[#lines + 1] = string.format(
    "Native pre-issue observer states: %d | sendCommand calls: %d",
    tonumber(native.commandObserverStateCount) or 0,
    tonumber(native.commandCalls) or 0
  )
  local buildGate = native.gates and native.gates.buildProposal or {}
  lines[#lines + 1] = string.format(
    "Build gate: %s | calls %d | pending auth %d | passed %d | suppressed %d | ABI mismatches %d",
    tostring(buildGate.enabled == true),
    tonumber(buildGate.calls) or 0,
    tonumber(buildGate.authorizations) or 0,
    tonumber(buildGate.allowed) or 0,
    tonumber(buildGate.suppressed) or 0,
    tonumber(buildGate.tagMismatches) or 0
  )
  local commandGate = native.gates and native.gates.commandVisitors or {}
  lines[#lines + 1] = string.format(
    "Command gates: %s | visitors %d | passed %d | suppressed %d | mismatches %d",
    tostring(commandGate.enabled == true),
    tonumber(commandGate.hooked) or 0,
    tonumber(commandGate.allowedTotal) or 0,
    tonumber(commandGate.suppressedTotal) or 0,
    tonumber(commandGate.tagMismatches) or 0
  )
  local nativeLines = gui.nativeLineCapture or {}
  lines[#lines + 1] = string.format(
    "Vanilla line manager captured create/delete/update/name/color: %d/%d/%d/%d/%d | invalid %d | last stops %d",
    tonumber(nativeLines.creates) or 0,
    tonumber(nativeLines.deletes) or 0,
    tonumber(nativeLines.updates) or 0,
    tonumber(nativeLines.names) or 0,
    tonumber(nativeLines.colors) or 0,
    tonumber(nativeLines.invalid) or 0,
    tonumber(nativeLines.lastStopCount) or 0)
  local authority = snapshot.probes and snapshot.probes.networkAuthority or {}
  if snapshot.networkMode == "network" then
    lines[#lines + 1] = "Network authority: "
      .. (authority.ready == true and "ready" or "FAULTED - " .. tostring(authority.error or "unknown"))
    local calendar = snapshot.probes and snapshot.probes.networkCalendar or {}
    lines[#lines + 1] = "Network calendar: "
      .. (calendar.frozen == true and "frozen (native recurring finance disabled)"
        or "FAULTED - " .. tostring(calendar.error or "freeze unavailable"))
    local sessionFault = (snapshot.proposalConsensus and snapshot.proposalConsensus.sessionFault)
      or (snapshot.operationConsensus and snapshot.operationConsensus.sessionFault)
    local ready = authority.ready == true and companion.connected == true and not sessionFault
    lines[#lines + 1] = "Multiplayer readiness: " .. (ready and "READY"
      or "WAITING - start the matching host/client companion and use the same session/manifest")
    local networkAccounts = snapshot.networkAccounts or {}
    local reconciliation = networkAccounts.reconciliation or {}
    lines[#lines + 1] = string.format(
      "Canonical finance: %s | entries %d | native reconciliations %d/%d failed",
      networkAccounts.initialized == true and "active" or "NOT READY",
      #(networkAccounts.entries or {}),
      tonumber(reconciliation.attempts) or 0,
      tonumber(reconciliation.failures) or 0
    )
  end
  if snapshot.proxyMode then
    local turn = snapshot.turn or {}
    lines[#lines + 1] = string.format("Turn desk: %s | leased assets %d | started tick %s | build pause %s",
      tostring(turn.companyCid or "inactive"), turn.leasedAssets or 0, tostring(turn.startedTick or "-"), tostring(turn.paused == true))
    local pinned = snapshot.ownership and snapshot.ownership.pinned or {}
    lines[#lines + 1] = string.format(
      "Tracked edge custody: %d | native holder desk/rightful company; rival edits blocked before commit",
      tonumber(pinned.total) or 0)
    lines[#lines + 1] = "Native borrow/repay is locked on the turn desk; competitive credit is not implemented yet."
  end
  local codecFailure = capture.lastProposalCodecFailure
  if codecFailure then
    local diagnostic = codecFailure.diagnostic or {}
    local counts = diagnostic.counts or {}
    local sample = diagnostic.constructionSamples and diagnostic.constructionSamples[1] or nil
    lines[#lines + 1] = string.format(
      "Last unsupported build: %s | construction add/remove %d/%d%s",
      tostring(codecFailure.error or "unknown"),
      tonumber(counts.constructionsToAdd) or 0,
      tonumber(counts.constructionsToRemove) or 0,
      sample and (" | " .. tostring(sample.fileName or sample.kindHint or "construction")) or ""
    )
  end
  lines[#lines + 1] = "Implemented multiplayer slice: canonical roads/tracks/signals, portable depot/construction/asset build and removal, modular station placement/edit/removal, plus host-ordered line and railway-vehicle operations. Unsupported opaque mod callbacks fail closed; host-owned autonomous simulation remains a research gate."
  gui.details:setText(table.concat(lines, "\n"))
end

local function queueAction(action)
  gui.queue[#gui.queue + 1] = action
  gui.lastError = nil
  renderGui()
end

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
    { "Seed Demo Market", function() return { type = "economy.seed_demo" } end },
    { "Settle Epoch", function() return { type = "economy.settle" } end },
  })
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
    { "Register Selected Line", function() return { type = "line.register", localLineId = assert(gui.selectedLineId, "select a line first") } end },
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
    { "Speed 3", function() return { type = "clock.request", requestedSpeed = 3 } end },
    { "Speed 4", function() return { type = "clock.request", requestedSpeed = 4 } end },
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
    { "Export Research", function() return { type = "probe.export_research" } end },
    { "Export Snapshot", function() return { type = "snapshot.export" } end },
    { "Export Checkpoint", function() return { type = "checkpoint.export", reason = "manual-ui" } end },
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
  if gui.entryPointsInstalled then return true end
  local utilGui = api and api.gui and api.gui.util
  if not (utilGui and type(utilGui.getById) == "function") then return false end
  local installed = 0
  local function addEntry(parentId, label, componentId)
    local existingOk, existing = pcall(utilGui.getById, componentId)
    if existingOk and existing then return true end
    local parentOk, parent = pcall(utilGui.getById, parentId)
    if not parentOk or not parent or type(parent.getLayout) ~= "function" then return false end
    local layoutOk, layout = pcall(parent.getLayout, parent)
    if not layout or not layoutOk or type(layout.addItem) ~= "function" then return false end
    local value = api.gui.comp.Button.new(api.gui.comp.TextView.new(label), true)
    if type(value.setId) == "function" then pcall(value.setId, value, componentId) end
    value:onClick(function() ensureWindow() end)
    local added = pcall(layout.addItem, layout, value)
    if added then installed = installed + 1 end
    return added
  end
  -- gameInfo is the always-visible bottom HUD strip. ingameMenu is the ESC
  -- menu. Either entry can reopen the hidden window; both use public UI APIs.
  addEntry("gameInfo", "MULTIPLAYER", "tpf2mp.hudEntry")
  addEntry("ingameMenu", "Multiplayer", "tpf2mp.pauseEntry")
  gui.entryPointsInstalled = installed > 0
  return gui.entryPointsInstalled
end

local function collectNumeric(value, output, seen)
  output, seen = output or {}, seen or {}
  if type(value) == "number" then
    if not seen[value] then seen[value] = true; output[#output + 1] = value end
  elseif type(value) == "table" then
    for _, nested in pairs(value) do collectNumeric(nested, output, seen) end
  end
  return output
end

local PROPOSAL_USERDATA_FIELDS = {
  "proposal", "data", "context", "streetProposal", "toAdd", "toRemove", "old2new",
  "edgesToAdd", "edgesToRemove",
  "nodesToAdd", "nodesToRemove", "addedSegments", "removedSegments", "new2oldSegments",
  "addedNodes", "removedNodes", "edgeObjectsToAdd", "edgeObjectsToRemove",
  "entity", "entityId", "id", "fileName", "transf", "params", "type", "comp",
  "streetEdge", "trackEdge", "node0", "node1", "tangent0", "tangent1", "typeIndex",
  "streetType", "trackType", "catenary",
  "streetTypes", "trackTypes", "construction", "constructions", "module", "modules",
  "constructionEntity", "constructionEntities", "constructionParams", "moduleData", "metadata",
  "transform", "transformation", "templateIndex", "tracks", "length", "year", "seed",
  "stationType", "depotType", "terminal", "terminals", "trackCount", "streetConnection",
  "cargo", "passenger", "capacity", "updateScript", "updateFn", "createTemplateFn",
  "upgrade", "isUpgrade", "buildMode", "mode", "cost", "result",
  "objects", "position", "param", "left", "oneWay", "category", "segmentEntity", "edgeEntity",
  "edgeObjectEntity", "originalEntity", "model", "modelId", "modelName", "modelInstance", "name",
  "x", "y", "z", "costs", "player", "owner", "playerEntity", "playerOwned",
  "resultEntities", "resultProposalData", "proposalData", "withCostRep", "ignoreErrors",
}

local COMMAND_USERDATA_FIELDS = util.deepCopy(PROPOSAL_USERDATA_FIELDS)
for _, field in ipairs({
  "line", "lineId", "lineEntity", "lines", "stops", "stop", "station",
  "stationId", "stationGroup", "vehicle", "vehicleId", "vehicleEntity",
  "vehicles", "depot", "depotId", "target", "targetEntity", "name", "color",
  "reverse", "userStopped", "shouldDepart", "manualDeparture", "maintenanceState",
  "vehicleConfig", "vehicleConfigs", "modelId", "modelIds", "replacement",
  "transportModes", "carrier", "amount", "journal", "time", "date", "speed",
  "gameSpeed", "calendarSpeed", "noCosts", "state", "value",
}) do
  COMMAND_USERDATA_FIELDS[#COMMAND_USERDATA_FIELDS + 1] = field
end

local function safeField(value, key)
  local valueType = type(value)
  if valueType ~= "table" and valueType ~= "userdata" then return nil end
  local ok, nested = pcall(function() return value[key] end)
  if not ok then return nil end
  return nested
end

local function eventShape(value, depth, seen, budget, options)
  depth = depth or 0
  seen = seen or {}
  budget = budget or { remaining = 96 }
  options = options or {}
  local maxDepth = options.maxDepth or 4
  local maxEntries = options.maxEntries or 32
  local maxString = options.maxString or 160
  if budget.remaining <= 0 then return "<budget-exhausted>" end
  budget.remaining = budget.remaining - 1
  local valueType = type(value)
  if valueType == "nil" or valueType == "boolean" or valueType == "number" then return value end
  if valueType == "string" then
    if #value > maxString then return value:sub(1, math.max(0, maxString - 3)) .. "..." end
    return value
  end
  if valueType == "userdata" and options.expandUserdata then
    if seen[value] then return "<cycle>" end
    if depth >= maxDepth then return "<userdata-depth-limit>" end
    seen[value] = true
    local result, count = { __type = "userdata" }, 0
    local lengthOk, length = pcall(function() return #value end)
    if lengthOk and type(length) == "number" and length >= 0 and length == math.floor(length) then
      for index = 1, math.min(length, maxEntries) do
        local readOk, nested = pcall(function() return value[index] end)
        if readOk and nested ~= nil then
          count = count + 1
          result[tostring(index)] = eventShape(nested, depth + 1, seen, budget, options)
        end
      end
      if length > maxEntries then result.__truncated = length - maxEntries end
    end
    -- Mat4f-like proposal userdata in Build 35924 can expose numeric indices
    -- while not implementing a useful length operator. Only the dedicated
    -- construction projection enables this bounded probe.
    if options.probeNumericUserdata and count < maxEntries then
      for index = 1, math.min(16, maxEntries - count) do
        if result[tostring(index)] == nil then
          local readOk, nested = pcall(function() return value[index] end)
          if readOk and nested ~= nil then
            count = count + 1
            result[tostring(index)] = eventShape(nested, depth + 1, seen, budget, options)
          end
        end
      end
    end
    -- Some Build 35924 proposal proxies expose dynamic keys through __pairs
    -- while returning nil for fields absent from the generated public type
    -- table. Enumerate that surface defensively and boundedly: this is still a
    -- pointer-free projection, and every iterator access remains protected by
    -- pcall because not all engine userdata supports iteration.
    if options.expandUserdataPairs and count < maxEntries then
      local pairsOk, iterator, invariant, control = pcall(pairs, value)
      if pairsOk and type(iterator) == "function" then
        local dynamic, attempts = {}, 0
        while attempts < maxEntries * 2 and #dynamic < maxEntries - count do
          attempts = attempts + 1
          local readOk, key, nested = pcall(iterator, invariant, control)
          if not readOk or key == nil then break end
          control = key
          local keyType = type(key)
          if (keyType == "string" or keyType == "number" or keyType == "boolean") and nested ~= nil then
            dynamic[#dynamic + 1] = { key = tostring(key), value = nested }
          end
        end
        table.sort(dynamic, function(a, b) return a.key < b.key end)
        for _, entry in ipairs(dynamic) do
          if count >= maxEntries then result.__truncated = true; break end
          if result[entry.key] == nil then
            count = count + 1
            result[entry.key] = eventShape(entry.value, depth + 1, seen, budget, options)
          end
        end
      end
    end
    for _, field in ipairs(options.userdataFields or PROPOSAL_USERDATA_FIELDS) do
      if count >= maxEntries then result.__truncated = true; break end
      local readOk, nested = pcall(function() return value[field] end)
      if readOk and nested ~= nil and result[field] == nil then
        count = count + 1
        result[field] = eventShape(nested, depth + 1, seen, budget, options)
      end
    end
    seen[value] = nil
    if count == 0 then return "<userdata>" end
    return result
  end
  if valueType ~= "table" then return "<" .. valueType .. ">" end
  if seen[value] then return "<cycle>" end
  if depth >= maxDepth then return "<table-depth-limit>" end
  seen[value] = true
  local result, entries = { __type = "table" }, {}
  for key, nested in pairs(value) do
    local keyType = type(key)
    local keyText = (keyType == "string" or keyType == "number" or keyType == "boolean")
      and tostring(key) or ("<" .. keyType .. ">")
    entries[#entries + 1] = { key = keyText, value = nested }
  end
  table.sort(entries, function(a, b) return a.key < b.key end)
  for index, entry in ipairs(entries) do
    if index > maxEntries then result.__truncated = #entries - maxEntries; break end
    result[entry.key] = eventShape(entry.value, depth + 1, seen, budget, options)
  end
  seen[value] = nil
  return result
end

local proposalCost

-- Mat4f userdata used by processed signal/waypoint records exposes numeric
-- indices but neither a useful length nor named matrix fields. The generic
-- bounded projector intentionally leaves such values opaque. Preserve only
-- edge-object transforms through a dedicated 16-number projection so the
-- canonical codec can recover the spline parameter from real GUI geometry.
gui.projectEdgeObjectTransforms = function(snapshot, rawProposal)
  if type(snapshot) ~= "table"
    or (type(rawProposal) ~= "table" and type(rawProposal) ~= "userdata") then
    return 0
  end
  local rawSimple = safeField(rawProposal, "proposal") or rawProposal
  local rawAdds = safeField(rawSimple, "edgeObjectsToAdd")
  local projectedSimple = type(snapshot.proposal) == "table" and snapshot.proposal or snapshot
  local projectedAdds = type(projectedSimple) == "table" and projectedSimple.edgeObjectsToAdd or nil
  if (type(rawAdds) ~= "table" and type(rawAdds) ~= "userdata")
    or type(projectedAdds) ~= "table" then return 0 end
  local projected = 0
  for index = 1, 64 do
    local raw = safeField(rawAdds, index) or safeField(rawAdds, tostring(index))
    local target = projectedAdds[index] or projectedAdds[tostring(index)]
    if raw == nil then break end
    if type(target) == "table" then
      local instance = safeField(raw, "modelInstance")
      local transform = safeField(instance, "transf") or safeField(instance, "transform")
      local matrix = gui.previewMatrix and gui.previewMatrix(transform) or nil
      if matrix then
        if type(target.modelInstance) ~= "table" then target.modelInstance = {} end
        target.modelInstance.transf = matrix
        projected = projected + 1
      end
    end
  end
  return projected
end

local function proposalSnapshot(param)
  local proposal = safeField(param, "proposal")
  if type(proposal) ~= "table" and type(proposal) ~= "userdata" then return nil end
  local rawConstructionAdds = safeField(proposal, "constructionsToAdd")
    or safeField(proposal, "toAdd")
  local rawConstructionRemovals = safeField(proposal, "constructionsToRemove")
    or safeField(proposal, "toRemove")
  local isConstruction = safeField(rawConstructionAdds, 1)
    or safeField(rawConstructionAdds, "1")
    or safeField(rawConstructionRemovals, 1)
    or safeField(rawConstructionRemovals, "1")
  isConstruction = isConstruction ~= nil
  local options = {
    maxDepth = isConstruction and 12 or 8,
    maxEntries = isConstruction and 1024 or 128,
    maxString = 240,
    expandUserdata = true,
    expandUserdataPairs = true,
    userdataFields = PROPOSAL_USERDATA_FIELDS,
  }
  -- The largest stock menu station contains hundreds of nodes and edges. Its
  -- projection happens only on a template refresh/click; ordinary mouse moves
  -- use the lightweight rebase path. Give that bounded event enough room to
  -- remain complete instead of silently exhausting the generic 2K budget.
  local snapshot = eventShape(
    proposal, 0, nil, { remaining = isConstruction and 65536 or 2048 }, options
  )
  gui.projectEdgeObjectTransforms(snapshot, proposal)
  local quotedCost = proposalCost and proposalCost(param) or nil
  if quotedCost ~= nil then snapshot.__observedCost = quotedCost end
  -- builder.proposalCreate's proposal userdata has live-proven geometry but
  -- can hide carrier selections (trackType/catenary/streetType). The adjacent
  -- builder data proxy is the supported pre-commit source for those values,
  -- so retain a separate bounded projection for codec discovery/fallback.
  for _, descriptor in ipairs({
    { field = "data", output = "__builderData" },
    { field = "params", output = "__builderParams" },
    { field = "context", output = "__builderContext" },
  }) do
    local nested = safeField(param, descriptor.field)
    if type(nested) == "table" or type(nested) == "userdata" then
      snapshot[descriptor.output] = eventShape(nested, 0, nil, { remaining = 1024 }, options)
    end
  end
  -- Construction payloads are substantially deeper than a linear edge and
  -- can exhaust the general proposal projection before reaching file/params/
  -- module facts. Preserve their outer vectors with an independent budget so
  -- a fail-closed station/depot attempt still produces actionable evidence.
  for _, descriptor in ipairs({
    { field = "constructionsToAdd", fallback = "toAdd", output = "__constructionAdditions" },
    { field = "constructionsToRemove", fallback = "toRemove", output = "__constructionRemovals" },
  }) do
    local nested = safeField(proposal, descriptor.field) or safeField(proposal, descriptor.fallback)
    local first = safeField(nested, 1)
    if first ~= nil then
      local constructionOptions = util.deepCopy(options)
      constructionOptions.maxDepth = 14
      constructionOptions.maxEntries = 1024
      constructionOptions.probeNumericUserdata = true
      snapshot[descriptor.output] = eventShape(
        nested, 0, nil, { remaining = isConstruction and 32768 or 4096 }, constructionOptions
      )
    end
  end
  return snapshot
end

-- Compound construction proposals are several orders of magnitude more
-- expensive to project than a road/track edge. Build 35924 can publish many
-- proposalCreate callbacks for one rendered mouse position, so a full station
-- graph is projected once per template and then transformed once at the exact
-- builder.apply boundary below.
-- Build 35924 can deliver builder.apply on the next simulation update while
-- rendering many GUI frames in between (especially on an uncapped peer).  A
-- three-frame grace period therefore allowed the throttled station preview to
-- be committed before the exact click payload arrived.  Keep the preview only
-- as a bounded recovery path and give the click-boundary event a full 60 GUI
-- frames to replace it.  The normal path does not pay this latency: apply
-- immediately upgrades and settles the pending suppression when it arrives.
gui.nativeBuildApplySettleFrames = 60
-- builder.apply can precede the hook status-file update that exposes the
-- matching native suppression.  Meanwhile the construction tool immediately
-- emits another proposalCreate for its next ghost.  Keep the exact click in a
-- separate, higher-priority latch so that post-click previews cannot overwrite
-- it while the suppression counter catches up.  Expiry prevents an unmatched
-- apply event from ever being paired with a later, unrelated click.
gui.nativeBuildExactLatchFrames = 180

gui.rawProposalHasConstruction = function(param)
  -- The live Build 35924 station callback uses this direct shape. Resolve it
  -- in one protected read; retain the recursive probe only for alternative
  -- builders/mods whose proposal wraps the construction more deeply.
  local directOk, direct = pcall(function()
    local proposal = param.proposal
    local additions = proposal and (proposal.constructionsToAdd or proposal.toAdd)
    local construction = additions and (additions[1] or additions["1"])
    if construction ~= nil then return construction.fileName or construction.name or true end
    local removals = proposal and (proposal.constructionsToRemove or proposal.toRemove)
    return removals and (removals[1] or removals["1"]) ~= nil and true or nil
  end)
  if directOk and direct ~= nil then
    return direct == true or (type(direct) == "string" and direct:match("%.con$") ~= nil)
  end
  local seen = {}
  local function walk(value, depth)
    local valueType = type(value)
    if (valueType ~= "table" and valueType ~= "userdata") or seen[value] or depth > 4 then
      return false
    end
    seen[value] = true
    for _, field in ipairs({ "constructionsToAdd", "constructionsToRemove", "toAdd", "toRemove" }) do
      local container = safeField(value, field)
      local first = safeField(container, 1) or safeField(container, "1")
      if first ~= nil then
        if field == "constructionsToAdd" or field == "constructionsToRemove"
          or field == "toRemove" then return true end
        local fileName = safeField(first, "fileName") or safeField(first, "name")
        if type(fileName) == "string" and fileName:match("%.con$") then return true end
      end
    end
    for _, field in ipairs({ "proposal", "streetProposal", "data" }) do
      if walk(safeField(value, field), depth + 1) then return true end
    end
    return false
  end
  return walk(safeField(param, "proposal"), 0)
end

gui.finitePreviewNumber = function(value)
  local number = tonumber(value)
  if not number or number ~= number or number == math.huge or number == -math.huge then return nil end
  return number
end

gui.previewMatrix = function(value)
  if type(value) ~= "table" and type(value) ~= "userdata" then return nil end
  local readOk, raw = pcall(function()
    local captured = {}
    for index = 1, 16 do captured[index] = value[index] or value[tostring(index)] end
    return captured
  end)
  if not readOk then return nil end
  local result = {}
  for index = 1, 16 do
    local number = gui.finitePreviewNumber(raw[index])
    if not number then return nil end
    result[index] = number
  end
  return result
end

-- A stock station can expose 158 module records. Hashing and sorting all of
-- them on every mouse-move callback still reduced a 320 m/8-track preview to
-- single-digit FPS. A bounded sentinel (count + head/middle/tail records) is
-- enough to distinguish the stock passenger/cargo and through/terminus module
-- sets; scalar length/track/catenary parameters are fingerprinted separately.
gui.previewModuleSignature = function(modules)
  if type(modules) ~= "table" and type(modules) ~= "userdata" then return nil end
  local sentinels = gui.lastConstructionPreviewModuleSentinels
  if type(sentinels) == "table" and type(sentinels.entries) == "table"
    and #sentinels.entries > 0 then
    local readOk, matches = pcall(function()
      for _, sentinel in ipairs(sentinels.entries) do
        local module = modules[sentinel.slotNumber] or modules[sentinel.slot]
        if module == nil then return false end
        local name = module.name or module.fileName
        local variant = tonumber(module.variant) or 0
        if name ~= sentinel.name or variant ~= sentinel.variant then return false end
      end
      return true
    end)
    if readOk and matches then return sentinels.signature end
    -- A direct mismatch is a template change. Return a distinct value so the
    -- caller projects that new template once and replaces the sentinels.
    return "module-sentinel-mismatch"
  end
  local rows, seen, moduleCount = {}, {}, nil
  local function add(key, module)
    local keyText = tostring(key)
    if seen[keyText] then return end
    local readOk, name, variant = pcall(function()
      return module.name or module.fileName, module.variant
    end)
    if not readOk then return end
    if type(name) ~= "string" then return end
    seen[keyText] = true
    rows[#rows + 1] = {
      slot = keyText,
      name = name,
      variant = tonumber(variant) or 0,
    }
  end

  local lengthOk, length = pcall(function() return #modules end)
  if lengthOk and type(length) == "number" and length > 0 then
    moduleCount = math.floor(length)
    local indices = {
      1, 2, 3, 4,
      math.max(1, math.floor((moduleCount + 1) / 2)),
      math.max(1, moduleCount - 2), math.max(1, moduleCount - 1), moduleCount,
    }
    for _, index in ipairs(indices) do add(index, safeField(modules, index)) end
  end
  if #rows == 0 then
    -- Some userdata views are sparse maps and do not implement length. Sample
    -- a small, stable subset instead of traversing hundreds of module entries.
    local pairsOk, iterator, invariant, control = pcall(pairs, modules)
    if pairsOk and type(iterator) == "function" then
      local attempts = 0
      while attempts < 16 and #rows < 12 do
        attempts = attempts + 1
        local readOk, key, module = pcall(iterator, invariant, control)
        if not readOk or key == nil then break end
        control = key
        add(key, module)
      end
    end
  end
  if #rows == 0 then return nil end
  table.sort(rows, function(a, b)
    if a.slot ~= b.slot then return a.slot < b.slot end
    if a.name ~= b.name then return a.name < b.name end
    return a.variant < b.variant
  end)
  local parts = { tostring(moduleCount or -1) }
  for _, row in ipairs(rows) do
    parts[#parts + 1] = row.slot .. ":" .. row.name .. ":" .. tostring(row.variant)
  end
  -- This value never crosses the network; direct string equality is both
  -- sufficient and much cheaper than canonical-JSON hashing per callback.
  return table.concat(parts, "|")
end

-- Select deterministic slots from the already projected module map. The
-- lowest slot identifies the main-building family (through/terminus), while
-- the remaining spread catches passenger/cargo/platform variants. Directly
-- probing these slots is constant-time even for a 158-module station.
gui.constructionModuleSentinels = function(snapshot)
  local construction = gui.projectedFirst(snapshot and snapshot.__constructionAdditions)
  local params = type(construction) == "table" and (construction.params or construction.param) or nil
  local modules = type(params) == "table" and params.modules or nil
  if type(modules) ~= "table" then return nil end
  local candidates = {}
  for key, module in pairs(modules) do
    if key ~= "__type" and key ~= "__truncated" and type(module) == "table" then
      local slotNumber = tonumber(key)
      local name = module.name or module.fileName
      if slotNumber and type(name) == "string" then
        candidates[#candidates + 1] = {
          slot = tostring(key), slotNumber = slotNumber, name = name,
          variant = tonumber(module.variant) or 0,
        }
      end
    end
  end
  if #candidates == 0 then return nil end
  table.sort(candidates, function(a, b) return a.slotNumber < b.slotNumber end)
  local wanted, entries = {
    1,
    math.max(1, math.floor((#candidates + 1) / 3)),
    math.max(1, math.floor((#candidates * 2 + 1) / 3)),
    #candidates,
  }, {}
  local seen = {}
  for _, index in ipairs(wanted) do
    local entry = candidates[index]
    if entry and not seen[entry.slot] then
      seen[entry.slot] = true
      entries[#entries + 1] = entry
    end
  end
  local parts = { tostring(#candidates) }
  for _, entry in ipairs(entries) do
    parts[#parts + 1] = entry.slot .. ":" .. entry.name .. ":" .. tostring(entry.variant)
  end
  return { entries = entries, signature = table.concat(parts, "|") }
end

-- A lightweight sample of the construction ghost.  Unlike eventShape(), this
-- deliberately avoids the node/edge graph and deep module metadata, so it can
-- run on every proposalCreate without returning the host to single-digit FPS.
gui.constructionPreviewPlacement = function(param)
  local readOk, fileName, rawTransform, sourceParams, modules, previewCost = pcall(function()
    local proposal = param.proposal
    local additions = proposal and (proposal.constructionsToAdd or proposal.toAdd)
    local construction = additions and (additions[1] or additions["1"])
    if construction == nil then return nil end
    local params = construction.params or construction.param
    local directData = param.resultProposalData or param.proposalData or param.data
    local nestedData = proposal and (proposal.resultProposalData or proposal.proposalData)
    local costs = (directData and directData.costs)
      or (nestedData and nestedData.costs) or param.costs
    return construction.fileName or construction.name,
      construction.transf or construction.transform,
      params, params and params.modules, costs
  end)
  if not readOk then return nil end
  if type(fileName) ~= "string" or not fileName:match("%.con$") then return nil end
  local transform = gui.previewMatrix(rawTransform)
  if not transform or (type(sourceParams) ~= "table" and type(sourceParams) ~= "userdata") then
    return nil
  end
  local paramsOk, rawParams = pcall(function()
    return {
      year = sourceParams.year,
      seed = sourceParams.seed,
      trackType = sourceParams.trackType,
      catenary = sourceParams.catenary,
      length = sourceParams.length,
      tracks = sourceParams.tracks,
      paramX = sourceParams.paramX,
      paramY = sourceParams.paramY,
    }
  end)
  if not paramsOk then return nil end
  local params, templateParts = {}, { fileName }
  for _, field in ipairs({
    "year", "seed", "trackType", "catenary", "length", "tracks", "paramX", "paramY",
  }) do
    local value = gui.finitePreviewNumber(rawParams[field])
    if value ~= nil then
      params[field] = value
      if field ~= "seed" then
        templateParts[#templateParts + 1] = field .. "=" .. tostring(value)
      end
    end
  end
  local moduleSignature = gui.previewModuleSignature(modules)
  local scalarSignature = table.concat(templateParts, "|")
  return {
    fileName = fileName,
    transform = transform,
    params = params,
    moduleSignature = moduleSignature,
    scalarSignature = scalarSignature,
    -- Seed changes after a successful placement but does not alter graph
    -- layout, so it is deliberately absent from this local-only signature.
    templateSignature = scalarSignature .. "|modules=" .. tostring(moduleSignature or "-"),
    cost = tonumber(previewCost) and util.integer(previewCost) or nil,
    frame = gui.frames,
  }
end

gui.projectedFirst = function(value)
  if type(value) ~= "table" then return nil end
  return value[1] or value["1"]
end

gui.transformPreviewPoint = function(position, old, new, vector)
  if type(position) ~= "table" then return false end
  local x, y, z = gui.finitePreviewNumber(position.x), gui.finitePreviewNumber(position.y),
    gui.finitePreviewNumber(position.z)
  if not x or not y or not z then return false end
  local dx, dy = x, y
  if not vector then dx, dy = x - old[13], y - old[14] end
  local determinant = old[1] * old[6] - old[5] * old[2]
  if math.abs(determinant) < 0.000001 then return false end
  local localX = (old[6] * dx - old[5] * dy) / determinant
  local localY = (-old[2] * dx + old[1] * dy) / determinant
  position.x = new[1] * localX + new[5] * localY + (vector and 0 or new[13])
  position.y = new[2] * localX + new[6] * localY + (vector and 0 or new[14])
  position.z = vector and z or (z - old[15] + new[15])
  return true
end

-- Rebase the last fully projected station graph onto the newest cheap ghost
-- transform.  Template changes are never rebased: callers force a fresh full
-- projection for those, which is what prevents an 8-track selection from
-- inheriting the previous two-track graph/module map.
gui.rebaseConstructionPreviewSnapshot = function(snapshot, placement)
  if type(snapshot) ~= "table" or type(placement) ~= "table" then
    return nil, "construction preview cache is unavailable"
  end
  local construction = gui.projectedFirst(snapshot.__constructionAdditions)
  if type(construction) ~= "table" then return nil, "projected construction is unavailable" end
  local projectedTransform = construction.transf or construction.transform
  local old = gui.previewMatrix(projectedTransform)
  local new = placement.transform
  if not old or type(new) ~= "table" then return nil, "construction transform is unavailable" end

  local seen, nodeCount, edgeCount = {}, 0, 0
  local function transformEntries(container, nodes)
    if type(container) ~= "table" then return end
    for key, entry in pairs(container) do
      if key ~= "__type" and key ~= "__truncated" and type(entry) == "table" then
        local component = entry.comp or entry
        if nodes then
          if gui.transformPreviewPoint(component.position or entry.position, old, new, false) then
            nodeCount = nodeCount + 1
          end
        else
          local changed = false
          if gui.transformPreviewPoint(component.tangent0, old, new, true) then changed = true end
          if gui.transformPreviewPoint(component.tangent1, old, new, true) then changed = true end
          if changed then edgeCount = edgeCount + 1 end
        end
      end
    end
  end
  local function walk(value, depth)
    if type(value) ~= "table" or seen[value] or depth > 10 then return end
    seen[value] = true
    for key, nested in pairs(value) do
      local name = tostring(key)
      if name == "nodesToAdd" or name == "addedNodes" then transformEntries(nested, true)
      elseif name == "edgesToAdd" or name == "addedSegments" then transformEntries(nested, false) end
    end
    for key, nested in pairs(value) do
      if key ~= "__type" and key ~= "__truncated" then walk(nested, depth + 1) end
    end
  end
  walk(snapshot, 0)
  -- Portable constructions do not necessarily own a transport graph.  Stock
  -- decorative assets, for example, produce an ASSET_GROUP from the named
  -- .con and have no proposal nodes or edges to move.  Their authoritative
  -- placement is the construction transform below.  A half-present graph is
  -- still unsafe: it means the cached projection is incomplete, rather than
  -- intentionally graphless.
  if (nodeCount == 0) ~= (edgeCount == 0) then
    return nil, "projected construction graph is incomplete"
  end
  for index = 1, 16 do
    if projectedTransform[tostring(index)] ~= nil then projectedTransform[tostring(index)] = new[index]
    else projectedTransform[index] = new[index] end
  end
  local projectedParams = construction.params or construction.param
  if type(projectedParams) == "table" then
    for field, value in pairs(placement.params or {}) do projectedParams[field] = value end
  end
  if placement.cost ~= nil then snapshot.__observedCost = placement.cost end
  return snapshot
end

gui.mergedAppliedProposalSnapshot = function(applied, preview)
  if type(applied) ~= "table" then return util.deepCopy(preview) end
  local result = util.deepCopy(applied)
  if type(preview) ~= "table" then return result end
  -- A suppressed native construction exposes an empty builder.apply proposal
  -- on Build 35924.  In that ordering the exact click is the latest pre-apply
  -- preview cached above, not the empty apply envelope.
  if gui.proposalSnapshotHasChange and not gui.proposalSnapshotHasChange(result)
    and gui.proposalSnapshotHasChange(preview) then
    return util.deepCopy(preview)
  end
  -- builder.apply reports zero cost for a natively suppressed command on Build
  -- 35924. Keep the last pre-commit quote and carrier/construction fallbacks,
  -- while taking geometry and the primary construction payload from apply.
  if result.__observedCost == nil or result.__observedCost == 0 then
    result.__observedCost = preview.__observedCost
  end
  for _, field in ipairs({ "__builderData", "__builderParams", "__builderContext" }) do
    if result[field] == nil and preview[field] ~= nil then
      result[field] = util.deepCopy(preview[field])
    elseif type(result[field]) == "table" and type(preview[field]) == "table" then
      for key, value in pairs(preview[field]) do
        if result[field][key] == nil then result[field][key] = util.deepCopy(value) end
      end
    end
  end
  for _, field in ipairs({ "__constructionAdditions", "__constructionRemovals" }) do
    if result[field] == nil and preview[field] ~= nil then
      result[field] = util.deepCopy(preview[field])
    end
  end
  return result
end

local function proposalAccessMessage(decision)
  if not decision or not decision.blocked or #decision.blocked == 0 then
    return "TPF2MP: the active company cannot modify this infrastructure"
  end
  local first = decision.blocked[1]
  local company = gui.snapshot and gui.snapshot.companies
    and gui.snapshot.companies[first.logicalOwnerCid] or nil
  local ownerName = company and company.name or first.logicalOwnerCid or "another company"
  local suffix = #decision.blocked > 1
    and string.format(" and %d other protected entities", #decision.blocked - 1) or ""
  return string.format(
    "TPF2MP: entity %s belongs to %s%s; switch companies or use public/unowned infrastructure",
    tostring(first.localId or "?"), tostring(ownerName), suffix
  )
end

local ENTITY_EVENT_FIELDS = {
  entity = true, entityId = true, vehicle = true, vehicleEntity = true,
  line = true, lineEntity = true, station = true, stationEntity = true,
  stationGroup = true, stationGroupEntity = true, depot = true, depotEntity = true,
  construction = true, constructionEntity = true, targetEntity = true,
}
local ENTITY_EVENT_CONTAINERS = {
  entities = true, entityIds = true, vehicles = true, vehicleEntities = true,
  lines = true, lineEntities = true, stations = true, stationEntities = true,
  depots = true, depotEntities = true, constructions = true, constructionEntities = true,
}

local function mutatingEntityEvent(id, name)
  local text = (tostring(id or "") .. "." .. tostring(name or "")):lower()
  for _, token in ipairs({
    "accept", "apply", "assign", "buy", "change", "delete", "electr", "remove",
    "rename", "replace", "reverse", "sell", "send", "set", "toggle", "update", "upgrade",
  }) do
    if text:find(token, 1, true) then return true end
  end
  return false
end

local function operationalGuiMutation(id, name)
  local text = (tostring(id or "") .. "." .. tostring(name or "")):lower()
  local subject = false
  for _, token in ipairs({
    "line", "vehicle", "depot", "station", "terminal", "construction",
    "maintenance", "replacement",
  }) do
    if text:find(token, 1, true) then subject = true; break end
  end
  if not subject then return false end
  for _, token in ipairs({
    "accept", "add", "apply", "assign", "buy", "change", "create", "delete",
    "depart", "electr", "remove", "rename", "replace", "reverse", "sell",
    "send", "set", "stop", "toggle", "update", "upgrade",
  }) do
    if text:find(token, 1, true) then return true end
  end
  return false
end

local function eventEntityIds(param)
  local result, seenIds, seenTables = {}, {}, {}
  local function add(value)
    local entity = tonumber(value)
    if entity and entity >= 0 and entity == math.floor(entity) and not seenIds[entity] then
      seenIds[entity] = true
      result[#result + 1] = entity
    end
  end
  local function walk(value, depth, acceptNumbers)
    local valueType = type(value)
    if depth > 8 or (valueType ~= "table" and valueType ~= "userdata") or seenTables[value] then return end
    seenTables[value] = true
    local function inspect(field, item, numericKey)
      if ENTITY_EVENT_FIELDS[field] then
        if type(item) == "table" or type(item) == "userdata" then
          add(safeField(item, "entity") or safeField(item, "entityId") or safeField(item, "id"))
        else add(item) end
      elseif ENTITY_EVENT_CONTAINERS[field] then
        if type(item) == "table" then
          for _, nested in pairs(item) do
            if type(nested) == "table" or type(nested) == "userdata" then
              add(safeField(nested, "entity") or safeField(nested, "entityId") or safeField(nested, "id"))
              walk(nested, depth + 1, true)
            else add(nested) end
          end
        end
      elseif type(item) == "table" or type(item) == "userdata" then
        walk(item, depth + 1, acceptNumbers)
      elseif acceptNumbers and numericKey then
        add(item)
      end
    end
    if valueType == "table" then
      for key, item in pairs(value) do
        inspect(tostring(key), item, type(key) == "number")
        if #result >= 128 then break end
      end
    else
      for field in pairs(ENTITY_EVENT_FIELDS) do inspect(field, safeField(value, field), false) end
      for field in pairs(ENTITY_EVENT_CONTAINERS) do inspect(field, safeField(value, field), false) end
    end
  end
  walk(param, 0, false)
  table.sort(result)
  return result
end

local function checkEntityEventAccess(id, name, param)
  local ownershipIsolated = gui.snapshot
    and (gui.snapshot.proxyMode or gui.snapshot.networkMode == "network")
  if not (ownershipIsolated and mutatingEntityEvent(id, name)) then
    return { allowed = true, blocked = {} }
  end
  local activeCompanyCid = gui.snapshot.activeCompanyCid
  local ids = eventEntityIds(param)
  if #ids == 0 and gui.selectedEntityId then ids[1] = gui.selectedEntityId end
  local blocked = {}
  for _, localId in ipairs(ids) do
    local key = tostring(localId)
    local custody = state.world.pinnedCustody and state.world.pinnedCustody[key] or nil
    local remembered = state.world.logicalOwners and state.world.logicalOwners[key] or nil
    remembered = remembered or (type(custody) == "table" and custody.logicalOwnerCid or nil)
    local ownerCid = remembered and state.companies[remembered] and remembered
      or world.logicalOwnerOf(state.world, state.companies, localId)
    if ownerCid and ownerCid ~= activeCompanyCid then
      blocked[#blocked + 1] = {
        localId = localId,
        canonicalId = canonical.resolveCanonical(state.canonical, world.kindOf(localId), localId),
        logicalOwnerCid = ownerCid,
      }
    end
  end
  return { allowed = #blocked == 0, activeCompanyCid = activeCompanyCid, blocked = blocked }
end

local function expandedCommandEnvelope(value)
  return eventShape(value, 0, nil, { remaining = 4096 }, {
    maxDepth = 9,
    maxEntries = 160,
    maxString = 240,
    expandUserdata = true,
    expandUserdataPairs = true,
    userdataFields = COMMAND_USERDATA_FIELDS,
  })
end

local function nativeCommandSnapshot(command)
  local proposal = safeField(command, "proposal")
  local envelope = expandedCommandEnvelope(command)
  local hasProposal = type(proposal) == "table" or type(proposal) == "userdata"
  return envelope, hasProposal and envelope or nil
end

local BUILD_CHANGE_FIELDS = {
  edgesToAdd = true, addedSegments = true, edgesToRemove = true, removedSegments = true,
  nodesToAdd = true, addedNodes = true, nodesToRemove = true, removedNodes = true,
  constructionsToAdd = true, toAdd = true, constructionsToRemove = true, toRemove = true,
  edgeObjectsToAdd = true, edgeObjectsToRemove = true,
}

local function projectedCollectionNonEmpty(value)
  if type(value) ~= "table" then return false end
  for key, nested in pairs(value) do
    if key ~= "__type" and key ~= "__truncated" and nested ~= nil then return true end
  end
  return false
end

gui.proposalSnapshotHasChange = function(root)
  local seen = {}
  local function walk(value, depth)
    if type(value) ~= "table" or seen[value] or depth > 10 then return false end
    seen[value] = true
    for key, nested in pairs(value) do
      if BUILD_CHANGE_FIELDS[tostring(key)] and projectedCollectionNonEmpty(nested) then return true end
    end
    for key, nested in pairs(value) do
      if key ~= "__type" and key ~= "__truncated" and walk(nested, depth + 1) then return true end
    end
    return false
  end
  return walk(root, 0)
end

gui.proposalSnapshotHasConstructionChange = function(root)
  local seen = {}
  local function walk(value, depth)
    if type(value) ~= "table" or seen[value] or depth > 10 then return false end
    seen[value] = true
    for key, nested in pairs(value) do
      local name = tostring(key)
      if (name == "constructionsToAdd" or name == "constructionsToRemove"
        or name == "toAdd" or name == "toRemove")
        and projectedCollectionNonEmpty(nested) then return true end
    end
    for key, nested in pairs(value) do
      if key ~= "__type" and key ~= "__truncated" and walk(nested, depth + 1) then return true end
    end
    return false
  end
  return walk(root, 0)
end

local function currentBuildGateSuppressed()
  local hook = nativeHookStatus()
  local gate = hook.gates and hook.gates.buildProposal or {}
  if hook.available ~= true then return nil, "native hook status is unavailable" end
  if gate.enabled ~= true then return nil, "native BuildProposal gate is disabled" end
  if (tonumber(gate.tagMismatches) or 0) > 0 then
    return nil, "native BuildProposal visitor reported an ABI tag mismatch"
  end
  return math.max(0, tonumber(gate.suppressed) or 0), nil, gate
end

local function queueNetworkProposalCapture(pending)
  local snapshot = pending and pending.proposalSnapshot
  if not snapshot then return false, "native build capture had no proposal snapshot" end
  local accessDecision = world.checkProposalAccess(state.world, snapshot, pending.companyCid)
  if not accessDecision.allowed then
    gui.nativeBuildCapture.orphaned = (gui.nativeBuildCapture.orphaned or 0) + 1
    queueAction({
      type = "native.observed",
      observation = "native.buildProposal.captureDenied",
      companyCid = pending.companyCid,
      ids = {},
      sourceId = pending.sourceId,
      accessDecision = accessDecision,
      localOnly = true,
    })
    gui.lastError = proposalAccessMessage(accessDecision)
    renderGui()
    return false, gui.lastError
  end
  local captureDigest = hash.value(snapshot)
  if gui.lastNetworkProposalDigest == captureDigest
    and gui.frames - (gui.lastNetworkProposalFrame or -1000) <= 30 then
    gui.nativeBuildCapture.duplicates = (gui.nativeBuildCapture.duplicates or 0) + 1
    return false, "duplicate"
  end
  gui.lastNetworkProposalDigest = captureDigest
  gui.lastNetworkProposalFrame = gui.frames
  gui.nativeBuildCapture.captured = (gui.nativeBuildCapture.captured or 0) + 1
  if pending.exact == true then
    gui.nativeBuildCapture.exactCaptures = (gui.nativeBuildCapture.exactCaptures or 0) + 1
  else
    gui.nativeBuildCapture.previewFallbacks = (gui.nativeBuildCapture.previewFallbacks or 0) + 1
  end
  queueAction({
    type = "native.observed",
    observation = "native.buildProposal.suppressedCapture",
    companyCid = pending.companyCid,
    ids = {},
    sourceId = pending.sourceId,
    eventShape = {
      previewFrame = pending.frame,
      captureFrame = gui.frames,
      captureDigest = captureDigest,
      exactApply = pending.exact == true,
      suppressedCalls = pending.suppressedCalls or 1,
      previewAgeFrames = math.max(0, gui.frames - (pending.frame or gui.frames)),
      suppressionWaitFrames = math.max(0,
        gui.frames - (pending.suppressionDetectedFrame or gui.frames)),
    },
    proposalSnapshot = snapshot,
    localOnly = true,
  })
  -- The canonical capture is latency-sensitive and must precede diagnostic
  -- observations already queued by repeated builder previews.
  table.insert(gui.queue, 1, {
    type = "proposal.capture",
    companyCid = pending.companyCid,
    proposalSnapshot = util.deepCopy(snapshot),
  })
  renderGui()
  return true
end

local function nativeBuildCaptureFailure(message, details)
  gui.nativeBuildCapture.orphaned = (gui.nativeBuildCapture.orphaned or 0) + 1
  gui.pendingNetworkBuildPreview = nil
  gui.pendingNetworkBuildExact = nil
  gui.pendingNetworkBuildSuppression = nil
  queueAction({
    type = "native.observed",
    observation = "native.buildProposal.captureError",
    companyCid = gui.snapshot and gui.snapshot.activeCompanyCid or nil,
    ids = {},
    sourceId = "BuildProposalVisitor",
    eventShape = { error = tostring(message), details = details },
    localOnly = true,
  })
  gui.lastError = tostring(message)
  renderGui()
  return false
end

gui.finishSuppressedNativeBuildCapture = function()
  local waiting = gui.pendingNetworkBuildSuppression
  if not waiting then return false end
  local pending = waiting.pending
  if not pending then
    return nativeBuildCaptureFailure(
      "a suppressed native build lost its correlated proposal snapshot; no command was replicated",
      { suppressed = waiting.suppressed }
    )
  end
  if pending.exact ~= true
    and gui.frames - (waiting.detectedFrame or gui.frames) < gui.nativeBuildApplySettleFrames then
    return false
  end
  gui.pendingNetworkBuildSuppression = nil
  return queueNetworkProposalCapture(pending)
end

local function processSuppressedNativeBuildCapture(force)
  local snapshotState = gui.snapshot or {}
  if snapshotState.networkMode ~= "network" then
    gui.pendingNetworkBuildPreview = nil
    gui.pendingNetworkBuildExact = nil
    gui.pendingNetworkBuildSuppression = nil
    gui.buildGateSuppressedSeen = nil
    return false
  end
  if gui.finishSuppressedNativeBuildCapture() then return true end
  if not force and not gui.pendingNetworkBuildPreview and not gui.pendingNetworkBuildExact
    and not gui.pendingNetworkBuildSuppression then return false end
  if not force and gui.frames - (gui.lastBuildGatePollFrame or -1000) < 2 then return false end
  gui.lastBuildGatePollFrame = gui.frames
  local current, statusError = currentBuildGateSuppressed()
  if current == nil then
    if gui.pendingNetworkBuildPreview then
      gui.lastError = "cannot correlate vanilla build: " .. tostring(statusError)
      renderGui()
    end
    return false
  end
  if gui.buildGateSuppressedSeen == nil then
    gui.buildGateSuppressedSeen = current
    return false
  end
  if current < gui.buildGateSuppressedSeen then
    gui.nativeBuildCapture.counterResets = (gui.nativeBuildCapture.counterResets or 0) + 1
    gui.buildGateSuppressedSeen = current
    gui.pendingNetworkBuildPreview = nil
    gui.pendingNetworkBuildExact = nil
    gui.lastError = "native BuildProposal suppression counter reset; discarded the pending preview"
    renderGui()
    return false
  end
  local delta = current - gui.buildGateSuppressedSeen
  if delta == 0 then return gui.finishSuppressedNativeBuildCapture() end
  gui.buildGateSuppressedSeen = current
  local exact = gui.pendingNetworkBuildExact
  if exact and gui.frames - (exact.frame or gui.frames) > gui.nativeBuildExactLatchFrames then
    exact = nil
    gui.pendingNetworkBuildExact = nil
  end
  local pending = exact or gui.pendingNetworkBuildPreview
  local waiting = gui.pendingNetworkBuildSuppression
  if waiting and not pending then
    local constructionBatch = delta <= 16 and waiting.pending
      and gui.proposalSnapshotHasConstructionChange(waiting.pending.proposalSnapshot)
    if not constructionBatch then
      return nativeBuildCaptureFailure(
        "another native build was suppressed before the prior click acquired its apply payload",
        { suppressed = current, suppressedDelta = delta }
      )
    end
    waiting.pending.suppressedCalls = (waiting.pending.suppressedCalls or 1) + delta
    waiting.suppressed = current
    gui.nativeBuildCapture.coalescedConstructionSuppressions =
      (gui.nativeBuildCapture.coalescedConstructionSuppressions or 0) + delta
    return gui.finishSuppressedNativeBuildCapture()
  end
  if delta ~= 1 then
    local constructionBatch = delta <= 16 and pending
      and gui.proposalSnapshotHasConstructionChange(pending.proposalSnapshot)
    if not constructionBatch then
      return nativeBuildCaptureFailure(
        "multiple native builds were suppressed before they could be correlated; no command was replicated",
        { suppressedDelta = delta }
      )
    end
    pending.suppressedCalls = delta
    gui.nativeBuildCapture.coalescedConstructionSuppressions =
      (gui.nativeBuildCapture.coalescedConstructionSuppressions or 0) + delta - 1
  end
  if not pending then
    return nativeBuildCaptureFailure(
      "a native build was suppressed without a matching pre-commit proposal; no command was replicated",
      { suppressed = current }
    )
  end
  gui.pendingNetworkBuildPreview = nil
  gui.pendingNetworkBuildExact = nil
  -- A waiting capture with no replacement pending was handled above. Reaching
  -- this branch with both is an exact builder.apply upgrade of that capture.
  gui.pendingNetworkBuildSuppression = {
    pending = pending,
    detectedFrame = gui.frames,
    suppressed = current,
  }
  pending.suppressionDetectedFrame = gui.frames
  pending.suppressed = current
  return gui.finishSuppressedNativeBuildCapture()
end

local function armNetworkBuildCapture(snapshot, companyCid, sourceId, exact)
  local snapshotState = gui.snapshot or {}
  if snapshotState.networkMode ~= "network" or not gui.proposalSnapshotHasChange(snapshot) then return false end
  -- Settle a previous commit before a newer mouse-move preview replaces it.
  processSuppressedNativeBuildCapture(true)
  local suppressed, statusError = currentBuildGateSuppressed()
  if suppressed == nil then
    gui.lastError = "cannot arm vanilla build capture: " .. tostring(statusError)
    renderGui()
    return false
  end
  if gui.buildGateSuppressedSeen == nil then gui.buildGateSuppressedSeen = suppressed end
  local pending = {
    companyCid = companyCid,
    sourceId = tostring(sourceId or "builder"),
    frame = gui.frames,
    digest = hash.value(snapshot),
    proposalSnapshot = util.deepCopy(snapshot),
    exact = exact == true,
  }
  -- If the native visitor reported suppression just before builder.apply, the
  -- waiting preview is atomically upgraded to this exact click payload.
  if pending.exact and gui.pendingNetworkBuildSuppression then
    pending.suppressionDetectedFrame = gui.pendingNetworkBuildSuppression.detectedFrame
    pending.suppressed = gui.pendingNetworkBuildSuppression.suppressed
    gui.pendingNetworkBuildSuppression.pending = pending
    gui.pendingNetworkBuildPreview = nil
    gui.pendingNetworkBuildExact = nil
    return gui.finishSuppressedNativeBuildCapture()
  end
  if pending.exact then
    gui.pendingNetworkBuildExact = pending
    processSuppressedNativeBuildCapture(true)
  else
    gui.pendingNetworkBuildPreview = pending
  end
  return true
end

local function installNativeCommandObserver()
  local setter = rawget(_G, "tpf2mp_native_set_command_observer")
  if type(setter) ~= "function" then return false end
  local callback = function(command)
    local ok, capturedOrError = pcall(function()
      local envelope, proposalSnapshot = nativeCommandSnapshot(command)
      local origin = util.currentCommandOrigin() or "unmarked-player-or-engine"
      queueAction({
        type = "native.observed",
        observation = proposalSnapshot and "native.sendCommand.buildProposal"
          or "native.sendCommand.command",
        companyCid = gui.snapshot and gui.snapshot.activeCompanyCid or nil,
        ids = {},
        sourceId = "api.cmd.sendCommand",
        commandOrigin = origin,
        commandDigest = hash.value(envelope),
        eventShape = envelope,
        proposalSnapshot = proposalSnapshot,
        localOnly = true,
      })
      if not proposalSnapshot then return true end
      local snapshotState = gui.snapshot or {}
      if snapshotState.networkMode == "network" then
        -- Canonical replays deliberately pass through api.cmd.sendCommand.
        -- They already hold a one-shot native authorization and must never be
        -- reflected back into the intent stream as if they were fresh input.
        if gui.issuingCanonicalProposal then return true end
        local hook = nativeHookStatus()
        local gate = hook.gates and hook.gates.buildProposal or {}
        if gate.enabled ~= true then
          gui.lastError = "network BuildProposal capture observed while the native gate was disabled"
          return false
        end
        armNetworkBuildCapture(proposalSnapshot, snapshotState.activeCompanyCid, "api.cmd.sendCommand")
      end
      return true
    end)
    if not ok then gui.lastError = tostring(capturedOrError) end
  end
  local ok, err = pcall(setter, callback)
  if not ok then gui.lastError = tostring(err); return false end
  gui.nativeCommandObserverInstalled = true
  return true
end

gui.processSuppressedNativeGameSpeedCapture = function()
  local snapshot = gui.snapshot or {}
  if snapshot.networkMode ~= "network" then return false end
  local take = rawget(_G, "tpf2mp_native_take_suppressed_game_speed")
  if type(take) ~= "function" then return false end
  local latest, validCount = nil, 0
  for _ = 1, 32 do
    local called, raw = pcall(take)
    if not called then
      gui.lastError = "cannot read suppressed native game speed: " .. tostring(raw)
      return false
    end
    if raw == nil then break end
    local number = tonumber(raw)
    if number and number == math.floor(number) and number >= 0 and number <= 4 then
      latest = number
      validCount = validCount + 1
    else
      gui.nativeClockCapture.invalid = (gui.nativeClockCapture.invalid or 0) + 1
    end
  end
  if latest == nil then return false end
  gui.nativeClockCapture.captured = (gui.nativeClockCapture.captured or 0) + validCount
  gui.nativeClockCapture.lastRequestedSpeed = latest
  local requested = tonumber(snapshot.networkClock and snapshot.networkClock.requestedSpeed)
  if requested == latest then
    gui.nativeClockCapture.duplicates = (gui.nativeClockCapture.duplicates or 0) + 1
    return false
  end
  -- Speed is control-plane traffic and the host may need it to drain a slow
  -- gameplay barrier, so place the collapsed latest request ahead of ordinary
  -- observations and build intents. The engine's clock.request path still
  -- validates, orders and adaptively caps it before either peer is authorized.
  table.insert(gui.queue, 1, { type = "clock.request", requestedSpeed = latest })
  return true
end

gui.nativeLineCaptureInteger = function(value, low, high)
  local number = tonumber(value)
  if not number or number ~= math.floor(number) or number < low or number > high then return nil end
  return number
end

gui.decodeNativeLineName = function(value)
  value = tostring(value or "")
  if #value % 2 ~= 0 or #value > 320 or value:find("[^0-9a-fA-F]") then return nil end
  local result = {}
  for index = 1, #value, 2 do
    local byte = tonumber(value:sub(index, index + 1), 16)
    if not byte or byte == 0 then return nil end
    result[#result + 1] = string.char(byte)
  end
  return table.concat(result)
end

gui.decodeSuppressedNativeLineCommand = function(raw)
  if type(raw) ~= "string" or #raw > 16384 then return nil, "invalid native line envelope" end
  local fields, cursor = {}, 1
  for index = 1, 9 do
    local boundary = raw:find("|", cursor, true)
    if not boundary then return nil, "truncated native line envelope" end
    fields[index] = raw:sub(cursor, boundary - 1)
    cursor = boundary + 1
  end
  fields[10] = raw:sub(cursor)
  if fields[1] ~= "L1" then return nil, "unsupported native line envelope version" end
  local tag = gui.nativeLineCaptureInteger(fields[2], 3, 29)
  if tag ~= 3 and tag ~= 4 and tag ~= 5 and tag ~= 28 and tag ~= 29 then tag = nil end
  local target = gui.nativeLineCaptureInteger(fields[3], -1, 2147483647)
  local player = gui.nativeLineCaptureInteger(fields[4], -1, 2147483647)
  local r = gui.nativeLineCaptureInteger(fields[5], 0, 1000)
  local g = gui.nativeLineCaptureInteger(fields[6], 0, 1000)
  local b = gui.nativeLineCaptureInteger(fields[7], 0, 1000)
  local name = gui.decodeNativeLineName(fields[8])
  local count = gui.nativeLineCaptureInteger(fields[9], 0, operationCodec.MAX_STOPS)
  if not tag or not target or not player or not r or not g or not b or name == nil or not count then
    return nil, "native line envelope contains invalid scalar fields"
  end
  local stops = {}
  if count == 0 then
    if fields[10] ~= "" then return nil, "empty native line envelope contains stop bytes" end
  else
    for encoded in fields[10]:gmatch("[^;]+") do
      local groupText, stationText, terminalText = encoded:match("^(-?%d+),(-?%d+),(-?%d+)$")
      local stationGroup = gui.nativeLineCaptureInteger(groupText, 0, 2147483647)
      local station = gui.nativeLineCaptureInteger(stationText, 0, 4095)
      local terminal = gui.nativeLineCaptureInteger(terminalText, 0, 4095)
      if not stationGroup or not station or not terminal then
        return nil, "native line envelope contains an invalid stop"
      end
      stops[#stops + 1] = {
        stationGroupLocalId = stationGroup,
        station = station,
        terminal = terminal,
      }
    end
    if #stops ~= count then return nil, "native line envelope stop count mismatch" end
  end
  if tag == 3 and (target ~= -1 or player < 0) then
    return nil, "native CreateLine envelope has invalid identity fields"
  elseif (tag == 4 or tag == 5 or tag == 28 or tag == 29) and target < 0 then
    return nil, "native line mutation envelope has no target"
  end
  return {
    tag = tag,
    targetLocalId = target,
    nativePlayerId = player,
    name = name,
    color = { r = r, g = g, b = b },
    stops = stops,
  }
end

gui.processSuppressedNativeLineCommandCapture = function()
  local snapshot = gui.snapshot or {}
  if snapshot.networkMode ~= "network" then return false end
  local take = rawget(_G, "tpf2mp_native_take_line_command")
    or rawget(_G, "tpf2mp_native_take_suppressed_line_command")
  if type(take) ~= "function" then return false end
  local types = api.type and api.type.ComponentType or {}
  local currentLines, lineSetError = componentEntitySet(types.LINE)
  if not currentLines then
    gui.lastError = "cannot enumerate optimistic vanilla line results: " .. tostring(lineSetError)
    return false
  end
  if gui.nativeLineKnownIds == nil then gui.nativeLineKnownIds = util.deepCopy(currentLines) end
  local addedLineIds = setDifference(currentLines, gui.nativeLineKnownIds)
  table.sort(addedLineIds)

  gui.nativeLineRecentAdded = gui.nativeLineRecentAdded or {}
  for _, localId in ipairs(addedLineIds) do
    if not gui.nativeLineRecentAdded[localId] then
      gui.nativeLineRecentAdded[localId] = { firstFrame = gui.frames }
    end
  end
  for localId, recent in pairs(gui.nativeLineRecentAdded) do
    if not currentLines[localId]
      or gui.frames - (tonumber(recent.firstFrame) or gui.frames) > 240 then
      gui.nativeLineRecentAdded[localId] = nil
    end
  end

  local function takeAddedLine(decoded)
    local candidates = {}
    for localId, recent in pairs(gui.nativeLineRecentAdded) do
      candidates[#candidates + 1] = {
        localId = localId,
        firstFrame = tonumber(recent.firstFrame) or gui.frames,
      }
    end
    table.sort(candidates, function(left, right)
      if left.firstFrame ~= right.firstFrame then return left.firstFrame < right.firstFrame end
      return left.localId < right.localId
    end)
    if #candidates == 0 then return nil end
    -- An authorised remote replay can become visible in the same GUI frame as
    -- a local New Line. Prefer the candidate owned by the native player from
    -- the captured CreateLine payload. If ownership is already observable,
    -- never consume a rival result merely because it is the only recent line.
    local ownershipObserved = false
    for _, candidate in ipairs(candidates) do
      local ownedOk, owned = pcall(
        api.engine.getComponent, candidate.localId, types.PLAYER_OWNED
      )
      owned = ownedOk and owned or nil
      ownershipObserved = ownershipObserved or owned ~= nil
      if owned and tonumber(owned.player) == tonumber(decoded.nativePlayerId) then
        gui.nativeLineRecentAdded[candidate.localId] = nil
        return candidate.localId
      end
    end
    if ownershipObserved then return nil end
    -- PLAYER_OWNED may trail LINE by a frame (or be unavailable on a future
    -- build). Entity age and ID provide a deterministic fallback only while
    -- no candidate exposes ownership at all.
    local candidate = candidates[1]
    gui.nativeLineRecentAdded[candidate.localId] = nil
    return candidate.localId
  end

  local function queueDecoded(decoded, originLocalId)
    local kinds = {
      [3] = "line.create", [4] = "line.delete", [5] = "line.update",
      [28] = "entity.color", [29] = "entity.name",
    }
    local capture = {
      kind = kinds[decoded.tag],
      targetLocalId = decoded.targetLocalId,
      originLocalId = originLocalId or decoded.targetLocalId,
      originApplied = true,
      name = decoded.name,
      color = decoded.color,
      stops = decoded.stops,
      nativePlayerId = decoded.nativePlayerId,
    }
    queueAction({
      type = "operation.capture",
      companyCid = snapshot.activeCompanyCid,
      capture = capture,
    })
    return true
  end

  local queued = 0
  -- A CreateLine result can trail its native visitor by a render frame. Keep
  -- the decoded pointer-free payload until exactly one new local line is
  -- observable instead of guessing an entity ID or replaying a duplicate.
  local pendingIndex = 1
  while pendingIndex <= #gui.pendingNativeLinePassThroughCaptures do
    local pending = gui.pendingNativeLinePassThroughCaptures[pendingIndex]
    local localId = takeAddedLine(pending.decoded)
    if localId then
      queueDecoded(pending.decoded, localId)
      table.remove(gui.pendingNativeLinePassThroughCaptures, pendingIndex)
      queued = queued + 1
    elseif gui.frames >= pending.maximumFrame then
      gui.nativeLineCapture.invalid = (gui.nativeLineCapture.invalid or 0) + 1
      gui.lastError = "vanilla New Line completed without an identifiable local output"
      table.remove(gui.pendingNativeLinePassThroughCaptures, pendingIndex)
    else pendingIndex = pendingIndex + 1 end
  end
  for _ = 1, 8 do
    local called, raw = pcall(take)
    if not called then
      gui.lastError = "cannot read suppressed native line command: " .. tostring(raw)
      return queued > 0
    end
    if raw == nil then break end
    local decoded, decodeError = gui.decodeSuppressedNativeLineCommand(raw)
    if not decoded then
      gui.nativeLineCapture.invalid = (gui.nativeLineCapture.invalid or 0) + 1
      gui.lastError = tostring(decodeError)
    else
      if decoded.tag == 3 then
        local localId = takeAddedLine(decoded)
        if localId then
          queueDecoded(decoded, localId)
          queued = queued + 1
        else
          gui.pendingNativeLinePassThroughCaptures[#gui.pendingNativeLinePassThroughCaptures + 1] = {
            decoded = util.deepCopy(decoded),
            capturedFrame = gui.frames,
            maximumFrame = gui.frames + 120,
          }
        end
      else
        queueDecoded(decoded, decoded.targetLocalId)
        queued = queued + 1
      end
      gui.nativeLineCapture.captured = (gui.nativeLineCapture.captured or 0) + 1
      if decoded.tag == 3 then
        gui.nativeLineCapture.creates = (gui.nativeLineCapture.creates or 0) + 1
      elseif decoded.tag == 4 then
        gui.nativeLineCapture.deletes = (gui.nativeLineCapture.deletes or 0) + 1
      elseif decoded.tag == 5 then
        gui.nativeLineCapture.updates = (gui.nativeLineCapture.updates or 0) + 1
      elseif decoded.tag == 28 then
        gui.nativeLineCapture.colors = (gui.nativeLineCapture.colors or 0) + 1
      elseif decoded.tag == 29 then
        gui.nativeLineCapture.names = (gui.nativeLineCapture.names or 0) + 1
      end
      gui.nativeLineCapture.lastTag = decoded.tag
      gui.nativeLineCapture.lastTarget = decoded.targetLocalId
      gui.nativeLineCapture.lastStopCount = #decoded.stops
    end
  end
  gui.nativeLineKnownIds = util.deepCopy(currentLines)
  return queued > 0
end

local function attemptGuiNetworkAuthorityBootstrap()
  installNativeCommandObserver()
  markNativeContext("gui")
  local authorityReady, authorityError = configureNativeAuthority("network")
  local calendarReady, calendarError = false, nil
  if authorityReady then calendarReady, calendarError = freezeNetworkCalendar() end
  return {
    authorityReady = authorityReady == true,
    calendarReady = calendarReady == true,
    error = authorityError or calendarError,
  }
end

local function directResultIds(param)
  local result, seen = {}, {}
  local values = safeField(param, "result")
  local candidates = {}
  if type(values) == "table" then
    for _, value in pairs(values) do candidates[#candidates + 1] = value end
  elseif type(values) == "userdata" then
    local lengthOk, length = pcall(function() return #values end)
    if lengthOk and type(length) == "number" then
      for index = 1, math.min(math.max(0, math.floor(length)), 512) do
        local readOk, value = pcall(function() return values[index] end)
        if readOk then candidates[#candidates + 1] = value end
      end
    end
  else
    return result
  end
  for _, value in ipairs(candidates) do
    local id = type(value) == "number" and value
      or safeField(value, "entity") or safeField(value, "id") or safeField(value, "entityId")
    id = tonumber(id)
    if id and id >= 0 and not seen[id] then seen[id] = true; result[#result + 1] = id end
  end
  table.sort(result)
  return result
end

proposalCost = function(param)
  if type(param) ~= "table" and type(param) ~= "userdata" then return nil end
  local nestedProposal = safeField(param, "proposal")
  local candidates = {
    directResult = safeField(param, "resultProposalData"),
    directProposal = safeField(param, "proposalData"),
    directData = safeField(param, "data"),
    nestedResult = safeField(nestedProposal, "resultProposalData"),
    nestedProposal = safeField(nestedProposal, "proposalData"),
  }
  for _, candidate in pairs(candidates) do
    local costs = safeField(candidate, "costs")
    if tonumber(costs) then return util.integer(costs) end
  end
  local directCosts = safeField(param, "costs")
  if tonumber(directCosts) then return util.integer(directCosts) end
  return nil
end

local function guiNativeBalance()
  local okPlayer, playerId = pcall(game.interface.getPlayer)
  if not okPlayer then return nil end
  local okEntity, entity = pcall(game.interface.getEntity, playerId)
  return okEntity and entity and tonumber(entity.balance) or nil
end

local function guiSelectedEntity(param)
  local direct = type(param) == "number" and param or nil
  if type(param) == "table" then
    direct = param.entity or param.id or param.entityId or param.selectedEntity or direct
  end
  local candidates = {}
  if tonumber(direct) then candidates[#candidates + 1] = tonumber(direct) end
  for _, value in ipairs(collectNumeric(param)) do candidates[#candidates + 1] = value end
  local seen = {}
  for _, id in ipairs(candidates) do
    if id >= 0 and not seen[id] then
      seen[id] = true
      local ok, exists = pcall(world.entityExists, id)
      if ok and exists then return id, world.kindOf(id) end
    end
  end
  return nil, nil
end

local function guiSelectedLine(param)
  local candidates = collectNumeric(param)
  for _, id in ipairs(candidates) do
    local ok, entity = pcall(game.interface.getEntity, id)
    if ok and entity and string.upper(tostring(entity.type or "")) == "LINE" then return id end
    local okComponent, line = pcall(api.engine.getComponent, id, api.type.ComponentType.LINE)
    if okComponent and line then return id end
  end
  return nil
end


local function scheduleVehicleCapture(id, param)
  local captureId = string.format("%s:gui-vehicle:%d", tostring((gui.snapshot or {}).sessionId or "local"), gui.nextCaptureId)
  gui.nextCaptureId = gui.nextCaptureId + 1
  local baseline = {}
  for _, vehicleId in ipairs(world.listVehicles()) do baseline[tostring(vehicleId)] = true end
  local entity = type(param) == "table" and tonumber(param.entity) or -1
  local companyCid = gui.snapshot and gui.snapshot.activeCompanyCid or nil
  local before = guiNativeBalance()
  gui.pendingVehicleCaptures[#gui.pendingVehicleCaptures + 1] = {
    captureId = captureId,
    companyCid = companyCid,
    before = baseline,
    balanceBefore = before,
    existingEntity = entity and entity >= 0 and entity or nil,
    attempts = 0,
    dueFrame = gui.frames + 2,
  }
  queueAction({
    type = "native.observed",
    observation = "vehicle.accept",
    captureId = captureId,
    companyCid = companyCid,
    ids = entity and entity >= 0 and { entity } or {},
    balanceBefore = before,
    sourceId = tostring(id),
    eventShape = eventShape(param),
    localOnly = true,
  })
end

local function processVehicleCaptures()
  for index = #gui.pendingVehicleCaptures, 1, -1 do
    local pending = gui.pendingVehicleCaptures[index]
    if gui.frames >= pending.dueFrame then
      pending.attempts = pending.attempts + 1
      local discovered = {}
      for _, vehicleId in ipairs(world.listVehicles()) do
        if not pending.before[tostring(vehicleId)] then discovered[#discovered + 1] = vehicleId end
      end
      local ready = #discovered > 0
        or (pending.existingEntity and pending.attempts >= 3)
        or pending.attempts >= 20
      if ready then
        queueAction({
          type = "native.observed",
          observation = "vehicle.resolve",
          captureId = pending.captureId,
          companyCid = pending.companyCid,
          ids = discovered,
          balanceBefore = pending.balanceBefore,
          balanceAfter = guiNativeBalance(),
          sourceId = "vehicleManager",
          timedOut = #discovered == 0 and not pending.existingEntity,
          localOnly = true,
        })
        table.remove(gui.pendingVehicleCaptures, index)
      else
        pending.dueFrame = gui.frames + 2
      end
    end
  end
end

local function sendToEngine(name, payload)
  -- This is the documented UI -> engine bridge and the path used by the
  -- shipped mission scripts. Keep the api.cmd form as a compatibility
  -- fallback for environments that omit the legacy wrapper.
  if game and game.interface and type(game.interface.sendScriptEvent) == "function" then
    game.interface.sendScriptEvent(EVENT_ID, name, payload)
    return
  end
  local sendScriptEvent = util.commandFactory("sendScriptEvent")
  if not (sendScriptEvent and api and api.cmd and type(api.cmd.sendCommand) == "function") then
    error("no GUI-to-engine script-event command path is available")
  end
  local command = sendScriptEvent(SCRIPT_FILE, EVENT_ID, name, payload)
  local ok, err = util.sendCommand(command, nil, "mod.gui.script-event:" .. tostring(name))
  if not ok then error(tostring(err)) end
end

local function queueGuiProposalResult(payload)
  gui.proposalResults[#gui.proposalResults + 1] = payload
end

local function processPendingProposalCaptures()
  for index = #gui.pendingProposalCaptures, 1, -1 do
    local pending = gui.pendingProposalCaptures[index]
    if gui.frames >= pending.minimumFrame then
      local issuerBalance = balanceOf(pending.issuerPlayerId)
      local nativeOwnerBalance = balanceOf(pending.nativeOwnerPlayerId)
      if issuerBalance == pending.lastIssuerBalance
        and nativeOwnerBalance == pending.lastNativeOwnerBalance then
        pending.stableFrames = pending.stableFrames + 1
      else
        pending.lastIssuerBalance = issuerBalance
        pending.lastNativeOwnerBalance = nativeOwnerBalance
        pending.stableFrames = 0
      end
      if pending.stableFrames >= 3 or gui.frames >= pending.maximumFrame then
        queueGuiProposalResult({
          proposalId = pending.proposalId,
          success = true,
          createdEdgeIds = pending.createdEdgeIds,
          createdNodeIds = pending.createdNodeIds,
          issuerBalanceBefore = pending.issuerBalanceBefore,
          issuerBalanceAfter = issuerBalance,
          nativeOwnerBalanceBefore = pending.nativeOwnerBalanceBefore,
          nativeOwnerBalanceAfter = nativeOwnerBalance,
        })
        table.remove(gui.pendingProposalCaptures, index)
        return true
      end
    end
  end
  return false
end

local function processGuiProposalQueue()
  if processPendingProposalCaptures() then return true end
  if #gui.proposalResults > 0 then
    local payload = table.remove(gui.proposalResults, 1)
    sendToEngine("proposal.result", payload)
    return true
  end
  local proposals = state and state.world and state.world.proposals and state.world.proposals.byId or {}
  for _, proposalId in ipairs(util.sortedKeys(proposals)) do
    local record = proposals[proposalId]
    if type(record) == "table" and record.status == "queued" and not gui.proposalIssued[proposalId] then
      gui.proposalIssued[proposalId] = true
      -- Schema 4 uses game.interface.buildConstruction on the engine thread;
      -- issuing a second GUI BuildProposal would duplicate the compound graph.
      if record.transaction
        and record.transaction.schemaVersion == proposalCodec.CONSTRUCTION_SCHEMA_VERSION then
        return true
      end
      local localRefs = record.localRefs or {}
      local nativePlayerId = tonumber(record.nativeOwnerPlayerId)
      local issuerPlayerId = tonumber(record.issuerPlayerId or record.controlPlayerId)
      if not nativePlayerId or not issuerPlayerId then
        queueGuiProposalResult({ proposalId = proposalId, success = false, error = "proposal player mapping is unavailable" })
        return true
      end
      local issuerBalanceBefore = balanceOf(issuerPlayerId)
      local nativeOwnerBalanceBefore = balanceOf(nativePlayerId)
      local proposal, materialiseError = proposalCodec.materialise(record.transaction, {
        resolveLocal = function(cid) return localRefs[cid] end,
        nativePlayerId = nativePlayerId,
      })
      if not proposal then
        queueGuiProposalResult({ proposalId = proposalId, success = false, error = tostring(materialiseError) })
        return true
      end
      local factory = util.commandFactory("buildProposal")
      if not (factory and api and api.cmd and type(api.cmd.sendCommand) == "function") then
        queueGuiProposalResult({ proposalId = proposalId, success = false, error = "GUI BuildProposal API is unavailable" })
        return true
      end
      local types = api.type and api.type.ComponentType or {}
      local beforeEdges, edgeError = componentEntitySet(types.BASE_EDGE)
      local beforeNodes, nodeError = componentEntitySet(types.BASE_NODE)
      if not beforeEdges or not beforeNodes then
        queueGuiProposalResult({ proposalId = proposalId, success = false, error = tostring(edgeError or nodeError) })
        return true
      end
      local commandOk, commandOrError = pcall(factory, proposal, nil, false)
      if not commandOk then
        queueGuiProposalResult({ proposalId = proposalId, success = false, error = tostring(commandOrError) })
        return true
      end
      if state.networkMode == "network" then
        local authorize = rawget(_G, "tpf2mp_native_authorize_build")
        if type(authorize) ~= "function" then
          queueGuiProposalResult({
            proposalId = proposalId,
            success = false,
            error = "network proposal requires GUI-state native authorization",
          })
          return true
        end
        local called, authorized, authorizeError = pcall(authorize)
        if not called or authorized == false then
          queueGuiProposalResult({
            proposalId = proposalId,
            success = false,
            error = tostring(authorizeError or authorized),
          })
          return true
        end
      end
      gui.issuingCanonicalProposal = proposalId
      local sent, sendError = util.sendCommand(commandOrError, function(_, success)
          if success ~= true then
            queueGuiProposalResult({ proposalId = proposalId, success = false, error = "native BuildProposal rejected" })
            return
          end
          local afterEdges, afterEdgeError = componentEntitySet(types.BASE_EDGE)
          local afterNodes, afterNodeError = componentEntitySet(types.BASE_NODE)
          if not afterEdges or not afterNodes then
            queueGuiProposalResult({
              proposalId = proposalId,
              success = false,
              error = tostring(afterEdgeError or afterNodeError),
            })
            return
          end
          gui.pendingProposalCaptures[#gui.pendingProposalCaptures + 1] = {
            proposalId = proposalId,
            createdEdgeIds = setDifference(afterEdges, beforeEdges),
            createdNodeIds = setDifference(afterNodes, beforeNodes),
            issuerBalanceBefore = issuerBalanceBefore,
            nativeOwnerBalanceBefore = nativeOwnerBalanceBefore,
            issuerPlayerId = issuerPlayerId,
            nativeOwnerPlayerId = nativePlayerId,
            lastIssuerBalance = balanceOf(issuerPlayerId),
            lastNativeOwnerBalance = balanceOf(nativePlayerId),
            stableFrames = 0,
            -- Build 35924 exposes the new topology in the callback before its
            -- journal entry is always visible.  Wait for the wallet samples
            -- to settle instead of falsely reporting a zero-cost build.
            -- Under two live processes the native construction journal has
            -- been observed more than 45 GUI frames after topology success.
            -- A short "stable" window before that debit is a false zero, so
            -- do not begin settlement sampling until a conservative delay.
            minimumFrame = gui.frames + 90,
            maximumFrame = gui.frames + 360,
          }
        end, "mod.network.replay-build-proposal")
      gui.issuingCanonicalProposal = nil
      if not sent then
        queueGuiProposalResult({ proposalId = proposalId, success = false, error = tostring(sendError) })
      end
      return true
    end
  end
  return false
end

local function queueGuiOperationResult(payload)
  gui.operationResults[#gui.operationResults + 1] = util.deepCopy(payload)
end

local function operationResultEntity(command, outputKind, beforeSet)
  for _, field in ipairs({
    "resultLineEntity", "resultVehicleEntity", "resultEntity", "entity",
  }) do
    local value = tonumber(safeField(command, field))
    if value and value >= 0 and not (beforeSet and beforeSet[value]) then return value end
  end
  local types = api.type and api.type.ComponentType or {}
  local componentType = outputKind == "line" and types.LINE
    or outputKind == "vehicle" and types.TRANSPORT_VEHICLE or nil
  if not componentType then return nil, "operation output component is unavailable" end
  local afterSet, setError = componentEntitySet(componentType)
  if not afterSet then return nil, setError end
  local difference = setDifference(afterSet, beforeSet or {})
  if #difference ~= 1 then
    return nil, "native operation produced " .. tostring(#difference)
      .. " candidate outputs; expected exactly one"
  end
  return difference[1]
end

local function processPendingOperationCaptures()
  for index, pending in ipairs(gui.pendingOperationCaptures) do
    local balance = balanceOf(pending.nativePlayerId)
    local signature = balance == nil and "unavailable" or tostring(util.integer(balance, 0))
    if signature == pending.lastSignature then pending.stableFrames = pending.stableFrames + 1
    else
      pending.lastSignature = signature
      pending.stableFrames = 0
    end
    local ready = gui.frames >= pending.minimumFrame
      and (pending.stableFrames >= 5 or gui.frames >= pending.maximumFrame)
    if ready then
      local financeDelta = 0
      if pending.affectsFinance and balance ~= nil and pending.balanceBefore ~= nil then
        financeDelta = util.integer(balance - pending.balanceBefore, 0)
      end
      queueGuiOperationResult({
        operationId = pending.operationId,
        success = true,
        outputLocalId = pending.outputLocalId,
        balanceAfter = balance,
        financeDelta = financeDelta,
      })
      table.remove(gui.pendingOperationCaptures, index)
      return true
    end
  end
  return false
end

function gui.invokeOperationFactory(factory, args)
  -- Build 35924's global `unpack` cannot copy the engine-owned userdata used
  -- by Line, Vec3f and vehicle-config command arguments.  It throws a
  -- table-valued C++ binding exception before pcall(factory, ...) is entered.
  -- Invoke the small, closed set of command arities explicitly so those
  -- userdata values remain valid and any factory rejection is caught here.
  local count = #args
  if count == 0 then return pcall(factory) end
  if count == 1 then return pcall(factory, args[1]) end
  if count == 2 then return pcall(factory, args[1], args[2]) end
  if count == 3 then return pcall(factory, args[1], args[2], args[3]) end
  if count == 4 then return pcall(factory, args[1], args[2], args[3], args[4]) end
  return false, "canonical operation factory has unsupported arity " .. tostring(count)
end

local function processGuiOperationQueue()
  if processPendingOperationCaptures() then return true end
  if #gui.operationResults > 0 then
    local payload = table.remove(gui.operationResults, 1)
    sendToEngine("operation.result", payload)
    return true
  end
  local operations = state and state.world and state.world.operations
    and state.world.operations.byId or {}
  for _, operationId in ipairs(util.sortedKeys(operations)) do
    local record = operations[operationId]
    if type(record) == "table" and record.status == "queued"
      and not gui.operationIssued[operationId] then
      gui.operationIssued[operationId] = true
      if type(record.originApplied) == "table" then
        -- The initiating vanilla widget has already received native success.
        -- Do not issue the command a second time on this machine: acknowledge
        -- that exact local result so finalisation can bind/check it while the
        -- non-origin peer follows the ordinary authorised replay path below.
        queueGuiOperationResult({
          operationId = operationId,
          success = true,
          outputLocalId = operationCodec.spec(record.transaction.kind).outputKind
            and tonumber(record.originApplied.localId) or nil,
          balanceAfter = balanceOf(record.nativePlayerId),
          financeDelta = 0,
          originApplied = true,
        })
        return true
      end
      local spec, materialiseError = operationCodec.materialise(record.transaction, {
        api = api,
        nativePlayerId = record.nativePlayerId,
        resolveLocal = function(cid)
          return record.localRefs and record.localRefs[cid]
        end,
      })
      if not spec then
        queueGuiOperationResult({
          operationId = operationId, success = false, error = tostring(materialiseError),
        })
        return true
      end
      local beforeSet = {}
      if spec.outputKind then
        local types = api.type and api.type.ComponentType or {}
        local componentType = spec.outputKind == "line" and types.LINE
          or spec.outputKind == "vehicle" and types.TRANSPORT_VEHICLE or nil
        local set, setError = componentEntitySet(componentType)
        if not set then
          queueGuiOperationResult({
            operationId = operationId, success = false, error = tostring(setError),
          })
          return true
        end
        beforeSet = set
      end
      local commandOk, commandOrError = gui.invokeOperationFactory(spec.factory, spec.args)
      if not commandOk then
        queueGuiOperationResult({
          operationId = operationId, success = false, error = tostring(commandOrError),
        })
        return true
      end
      if state.networkMode == "network" then
        local authorize = rawget(_G, "tpf2mp_native_authorize_command")
        if type(authorize) ~= "function" then
          queueGuiOperationResult({
            operationId = operationId, success = false,
            error = "network operation requires GUI-state native command authorization",
          })
          return true
        end
        local called, authorized, authorizeError = pcall(authorize, tostring(spec.tag))
        if not called or authorized == false then
          queueGuiOperationResult({
            operationId = operationId, success = false,
            error = tostring(authorizeError or authorized),
          })
          return true
        end
      end
      local balanceBefore = balanceOf(record.nativePlayerId)
      local sent, sendError = util.sendCommand(commandOrError, function(command, success)
        if success ~= true then
          queueGuiOperationResult({
            operationId = operationId, success = false,
            error = "native " .. tostring(record.transaction.kind) .. " command was rejected",
          })
          return
        end
        local outputLocalId
        if spec.outputKind then
          local outputError
          outputLocalId, outputError = operationResultEntity(command, spec.outputKind, beforeSet)
          if not outputLocalId then
            queueGuiOperationResult({
              operationId = operationId, success = false, error = tostring(outputError),
            })
            return
          end
        end
        local affectsFinance = record.transaction.kind == "vehicle.buy"
          or record.transaction.kind == "vehicle.replace"
          or record.transaction.kind == "vehicle.sell"
        gui.pendingOperationCaptures[#gui.pendingOperationCaptures + 1] = {
          operationId = operationId,
          outputLocalId = outputLocalId,
          nativePlayerId = record.nativePlayerId,
          balanceBefore = balanceBefore,
          affectsFinance = affectsFinance,
          lastSignature = nil,
          stableFrames = 0,
          minimumFrame = gui.frames + (affectsFinance and 30 or 2),
          maximumFrame = gui.frames + (affectsFinance and 240 or 30),
        }
      end, "mod.canonical-operation." .. tostring(record.transaction.kind))
      if not sent then
        queueGuiOperationResult({
          operationId = operationId, success = false, error = tostring(sendError),
        })
      end
      return true
    end
  end
  return false
end

local function guiCapabilityProbe()
  local command = api and api.cmd or {}
  local systems = api and api.engine and api.engine.system or {}
  local interface = game and game.interface or {}
  local function hasFactory(name)
    return util.commandFactory(name) ~= nil
  end
  local function hasType(path)
    local value = api and api.type
    for part in tostring(path):gmatch("[^.]+") do
      if value == nil then return false end
      local ok, nested = pcall(function() return value[part] end)
      if not ok then return false end
      value = nested
    end
    return value ~= nil and util.isCallable(value.new)
  end
  return {
    luaState = "gui",
    sendCommand = type(command.sendCommand) == "function",
    bookJournalEntry = hasFactory("bookJournalEntry"),
    buildProposal = hasFactory("buildProposal"),
    buyVehicle = hasFactory("buyVehicle"),
    replaceVehicle = hasFactory("replaceVehicle"),
    reverseVehicle = hasFactory("reverseVehicle"),
    sellVehicle = hasFactory("sellVehicle"),
    sendToDepot = hasFactory("sendToDepot"),
    setVehicleLine = hasFactory("setLine"),
    setVehicleStopped = hasFactory("setUserStopped"),
    setVehicleManualDeparture = hasFactory("setVehicleManualDeparture"),
    setVehicleShouldDepart = hasFactory("setVehicleShouldDepart"),
    setVehicleMaintenance = hasFactory("setVehicleTargetMaintenanceState"),
    createLine = hasFactory("createLine"),
    updateLine = hasFactory("updateLine"),
    deleteLine = hasFactory("deleteLine"),
    saveGame = hasFactory("saveGame"),
    lineType = hasType("Line"),
    lineStopType = hasType("Line.Stop"),
    transportVehicleConfigType = hasType("TransportVehicleConfig"),
    transportVehiclePartType = hasType("TransportVehiclePart"),
    vehiclePartType = hasType("VehiclePart"),
    modelRepFind = api and api.res and api.res.modelRep
      and util.isCallable(api.res.modelRep.find) or false,
    modelRepGetName = api and api.res and api.res.modelRep
      and util.isCallable(api.res.modelRep.getName) or false,
    setName = hasFactory("setName"),
    setColor = hasFactory("setColor"),
    developTown = hasFactory("developTown"),
    setTownInfo = hasFactory("setTownInfo"),
    setTownCargoNeeds = hasFactory("instantlyUpdateTownCargoNeeds"),
    setIndustryManualDevelopment = hasFactory("setSimBuildingManualDevelopment"),
    setIndustryClosure = hasFactory("setSimBuildingClosureTimeStamp"),
    sendScriptEvent = hasFactory("sendScriptEvent"),
    nativeMirroredBuildProposal = rawget(_G, "tpf2mp_native_binding_buildProposal") ~= nil,
    nativeMirroredSendScriptEvent = rawget(_G, "tpf2mp_native_binding_sendScriptEvent") ~= nil,
    nativeBuildGate = type(rawget(_G, "tpf2mp_native_enable_build_gate")) == "function"
      and type(rawget(_G, "tpf2mp_native_disable_build_gate")) == "function" or false,
    nativeBuildAuthorize = type(rawget(_G, "tpf2mp_native_authorize_build")) == "function",
    nativeCommandGate = type(rawget(_G, "tpf2mp_native_enable_command_gate")) == "function"
      and type(rawget(_G, "tpf2mp_native_disable_command_gate")) == "function" or false,
    nativeCommandAuthorize = type(rawget(_G, "tpf2mp_native_authorize_command")) == "function",
    nativeCommandObserverApi = type(rawget(_G, "tpf2mp_native_set_command_observer")) == "function",
    nativeGameSpeedCaptureApi =
      type(rawget(_G, "tpf2mp_native_take_suppressed_game_speed")) == "function",
    nativeLineCommandCaptureApi =
      type(rawget(_G, "tpf2mp_native_take_line_command")) == "function"
      or type(rawget(_G, "tpf2mp_native_take_suppressed_line_command")) == "function",
    interfaceSendScriptEvent = type(interface.sendScriptEvent) == "function",
    simPersonCount = systems.simPersonSystem and type(systems.simPersonSystem.getCount) == "function" or false,
    simPersonsForLine = systems.simPersonSystem and type(systems.simPersonSystem.getSimPersonsForLine) == "function" or false,
    simCargosForLine = systems.simCargoSystem and type(systems.simCargoSystem.getSimCargosForLine) == "function" or false,
    simPersonTerminalInfo = systems.simPersonAtTerminalSystem
      and type(systems.simPersonAtTerminalSystem.getEdgeInfoMap) == "function" or false,
  }
end

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
  pcall(function() handlers["probe.export_research"]() end)
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
  local researchOk, researchResult = handlers["probe.export_research"]()
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
  if validation.stage == "wait-for-network" and state.tick < VALIDATION_WORLD_WARMUP_TICKS then return end
  if state.tick - (validation.stageStartedTick or 0) < VALIDATION_SETTLE_TICKS then return end

  local stage = validation.stage
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
        and not networkIntentAwaitingOrder
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
    validationCheck("initial-checkpoint-consensus", agreed.success == true, agreed)
    validationCheck("initial-checkpoint-covers-structure",
      agreed.structuralDigest == validation.values.initialStructuralDigest, agreed)
    validation.values.initialCheckpointBoundary = agreed.boundarySeq
    if state.bridge.peerId == "player1" then
      local result = networkValidationSubmit({ type = "probe.mobility" }, "initial-mobility-sample-queued")
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

local function operationalAccountSnapshot()
  local accounts = { companies = {} }
  for _, companyCid in ipairs(state.companyOrder or {}) do
    local company = state.companies[companyCid]
    if company and company.playerId then
      accounts.companies[companyCid] = accountOf(company.playerId)
    end
  end
  if state.world.controlPlayerId then
    accounts.control = accountOf(state.world.controlPlayerId)
  end
  local activeCid = activeCompany()
  accounts.activeCompanyCid = activeCid
  return accounts
end

local function sampleOperationalCapture(reason)
  local operational = state.probes.operational
  if not (operational and operational.enabled) then return false, "operational capture is disabled" end
  local sampled, runtimeOrError = xpcall(function()
    return world.operationalSnapshot(
      state.canonical, state.world, state.companies, operational.lastJournalTimeMs)
  end, debug.traceback)
  if not sampled then
    operational.lastError = tostring(runtimeOrError)
    return false, operational.lastError
  end
  local runtime = runtimeOrError
  runtime.tick = state.tick
  runtime.reason = tostring(reason or "interval")
  runtime.scope = "local-operational-observation-only"
  runtime.peerId = state.bridge.peerId
  runtime.sessionId = state.bridge.sessionId
  runtime.initialized = state.initialized == true
  runtime.matchStatus = state.match and state.match.status or nil
  runtime.activeCompanyCid = activeCompany()
  runtime.accounts = operationalAccountSnapshot()
  runtime.digests = {
    model = authoredDigest(),
    core = coreDigest(),
    structural = runtime.structural and runtime.structural.digest or nil,
    mobility = runtime.mobility and runtime.mobility.digest or nil,
    autonomy = runtime.autonomy and runtime.autonomy.digest or nil,
    journal = runtime.journal and runtime.journal.digest or nil,
    accounts = hash.value(runtime.accounts),
  }
  state.probes.nativeHook = nativeHookStatus()
  runtime.nativePipeline = {
    hook = util.deepCopy(state.probes.nativeHook),
    observedSendCommands = state.probes.capture.nativeCommandCount or 0,
    observedGuiActions = state.probes.capture.operationalGuiCount or 0,
    origins = util.deepCopy(state.probes.capture.nativeCommandOrigins or {}),
  }
  runtime.digest = hash.value({
    tick = runtime.tick,
    initialized = runtime.initialized,
    clock = runtime.clock,
    digests = runtime.digests,
    commandCount = runtime.nativePipeline.observedSendCommands,
    guiActionCount = runtime.nativePipeline.observedGuiActions,
    commandOrigins = runtime.nativePipeline.origins,
  })

  state.probes.structural = runtime.structural
  state.probes.mobility = runtime.mobility
  if runtime.journal and runtime.journal.toTimeMs then
    operational.lastJournalTimeMs = runtime.journal.toTimeMs
  end
  operational.sampleCount = (operational.sampleCount or 0) + 1
  local summary = {
    sequence = operational.sampleCount,
    tick = state.tick,
    reason = runtime.reason,
    initialized = runtime.initialized,
    activeCompanyCid = runtime.activeCompanyCid,
    gameSpeed = runtime.clock and runtime.clock.gameSpeed or nil,
    gameTime = runtime.clock and runtime.clock.time or nil,
    paused = runtime.clock and runtime.clock.paused or nil,
    townCount = runtime.structural and #(runtime.structural.towns or {}) or 0,
    industryCount = runtime.structural and runtime.structural.industryCount or 0,
    lineCount = runtime.structural and #(runtime.structural.lines or {}) or 0,
    vehicleCount = runtime.structural and runtime.structural.vehicleCount or 0,
    mobilityTotals = util.deepCopy(runtime.mobility and runtime.mobility.totals or {}),
    mobilityAvailability = util.deepCopy(runtime.mobility and runtime.mobility.availability or {}),
    autonomyTotals = util.deepCopy(runtime.autonomy and runtime.autonomy.totals or {}),
    journalScalars = util.deepCopy(runtime.journal and runtime.journal.scalars or {}),
    accounts = util.deepCopy(runtime.accounts),
    digests = util.deepCopy(runtime.digests),
    commandCount = runtime.nativePipeline.observedSendCommands,
    guiActionCount = runtime.nativePipeline.observedGuiActions,
    commandOrigins = util.deepCopy(runtime.nativePipeline.origins),
    digest = runtime.digest,
  }
  operational.lastSample = util.deepCopy(summary)
  operational.samples[#operational.samples + 1] = util.deepCopy(summary)
  while #operational.samples > 64 do table.remove(operational.samples, 1) end
  local emitted, outbound = bridge.emit(state.bridge, "operational", runtime, state.tick)
  if emitted then
    operational.emittedCount = (operational.emittedCount or 0) + 1
    operational.lastError = nil
  else operational.lastError = tostring(outbound) end
  return emitted, emitted and summary or operational.lastError
end

local function maintainOperationalCapture()
  local cfg = config()
  local operational = state.probes.operational
  if not cfg.operationalCapture then return end
  operational.enabled = true
  operational.mode = "local-observation-only"
  operational.intervalTicks = cfg.operationalSampleTicks
  if not operational.autoInitAttempted and (state.initialized or state.tick >= 60) then
    operational.autoInitAttempted = true
    if state.initialized then
      operational.autoInit = {
        tick = state.tick, invoked = true, success = true, alreadyInitialized = true,
      }
    else
      local invoked, success, result = xpcall(function()
        return applyCommitted({ type = "match.initialise" }, "operational-capture:auto-init", nil)
      end, debug.traceback)
      operational.autoInit = {
        tick = state.tick,
        invoked = invoked == true,
        success = invoked == true and success == true,
        result = invoked and util.deepCopy(result) or nil,
        error = not invoked and tostring(success)
          or (success ~= true and tostring(type(result) == "table" and result.error or result) or nil),
      }
    end
    operational.nextSampleTick = state.tick
  end
  if state.tick >= math.max(1, tonumber(operational.nextSampleTick) or 1) then
    local reason = operational.sampleCount == 0 and "capture-ready" or "interval"
    local ok, err = sampleOperationalCapture(reason)
    if not ok then operational.lastError = tostring(err) end
    operational.nextSampleTick = state.tick + cfg.operationalSampleTicks
  end
end

-- Human multiplayer sessions need the same ordered company/account bootstrap
-- as the validator, but none of the validator's synthetic infrastructure.
-- Only the host emits it; the companion orders the resulting match.initialise
-- for both peers and the usual checkpoint barrier proves that they agreed.
function networkClock.maintainManualBootstrap()
  local cfg = config()
  if not cfg.manualNetwork or state.networkMode ~= "network" or state.initialized then return end
  if state.bridge.peerId ~= "player1" then return end
  local bootstrap = networkClock.manualBootstrap
  if state.tick < math.max(240, tonumber(bootstrap.nextAttemptTick) or 240) then return end
  if networkIntentAwaitingOrder or networkPendingBarrierReason() then return end
  local authority = state.probes.networkAuthority or {}
  if authority.ready ~= true then
    bootstrap.nextAttemptTick = state.tick + 30
    return
  end
  bootstrap.attempts = bootstrap.attempts + 1
  local ok, result = submitIntent({ type = "match.initialise" })
  bootstrap.submitted = ok == true
  bootstrap.nextAttemptTick = state.tick + (ok and 600 or 60)
  diagnosticLog("manual-network-bootstrap", {
    success = ok == true,
    attempt = bootstrap.attempts,
    localSeq = type(result) == "table" and (result.local_seq or result.localSeq) or nil,
    error = not ok and tostring(type(result) == "table" and result.error or result) or nil,
    tick = state.tick,
  })
end

local script = {
  init = function()
    if not isEngineThread() then return end
    deferredNetworkIntents = {}
    networkIntentAwaitingOrder = nil
    networkClock.manualBootstrap = { nextAttemptTick = 240, attempts = 0, submitted = false }
    proposalPreparation.originAppliedOperations = {}
    proposalPreparation.nextOriginToken = 1
    proposalPreparation.pending = {}
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
    elseif state.networkMode == "network" then
      local calendarReady, calendarError = freezeNetworkCalendar()
      if not calendarReady then
        state.probes.networkAuthority.ready = false
        state.probes.networkAuthority.error = calendarError
        state.lastError = calendarError
      end
    end
  end,

  update = function()
    if not isEngineThread() then return end
    state.tick = (state.tick or 0) + 1
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
      local ok, err = pcall(consumeBridge)
      if not ok then state.bridge.lastError = tostring(err) end
      local deferredOk, deferredError = xpcall(processDeferredNetworkIntent, debug.traceback)
      if not deferredOk then
        state.lastError = "deferred multiplayer physical-action processing failed: "
          .. tostring(deferredError)
      end
      local healthOk, healthError = xpcall(networkClock.emitHealth, debug.traceback)
      if not healthOk then state.world.networkClock.lastError = tostring(healthError) end
    end
  end,

  save = function()
    return state
  end,

  load = function(saved)
    state = migrate(saved)
    if not isEngineThread() then
      -- The disposable two-process validator has no human-facing controls.
      -- Mutating the UI tree from this high-frequency load callback can enter
      -- Build 35924's stored-function renderer recursively. The GUI state must
      -- still receive engine state so it can materialise ordered proposals.
      if config().networkAutoValidate then return end
      gui.snapshot = publicSnapshot()
      if gui.status then renderGui() end
    end
  end,

  handleEvent = function(src, id, name, param)
    if id ~= EVENT_ID then return end
    if not isEngineThread() then
      if name == "snapshot" and type(param) == "table" then gui.snapshot = param; renderGui() end
      return
    end
    if name == "intent" then
      local ok, err = pcall(submitIntent, param)
      if not ok then state.lastError = tostring(err); publishSnapshot() end
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
      publishSnapshot()
    end
  end,

  guiInit = function()
    local lineTypes = api.type and api.type.ComponentType or {}
    local initialLines = componentEntitySet(lineTypes.LINE)
    if initialLines then gui.nativeLineKnownIds = initialLines end
    if config().networkAutoValidate then
      gui.awaitingManualHandoff = true
      installNativeCommandObserver()
      markNativeContext("gui")
      gui.networkAuthorityBootstrap = config().startNetwork
        and attemptGuiNetworkAuthorityBootstrap() or nil
      queueAction({
        type = "probe.gui_capabilities",
        capabilities = guiCapabilityProbe(),
        nativeHook = nativeHookStatus(),
        networkAuthorityBootstrap = gui.networkAuthorityBootstrap,
        localOnly = true,
      })
      diagnosticLog("gui-init", { success = true, automated = true })
      return
    end
    installNativeCommandObserver()
    markNativeContext("gui")
    gui.networkAuthorityBootstrap = config().startNetwork
      and attemptGuiNetworkAuthorityBootstrap() or nil
    local ok, err = pcall(ensureWindow)
    if not ok then gui.lastError = tostring(err) end
    if ok and config().manualNetwork and gui.window then
      pcall(gui.window.setVisible, gui.window, false, false)
    end
    pcall(installMultiplayerEntryPoints)
    diagnosticLog("gui-init", { success = ok and true or false, error = not ok and tostring(err) or nil })
    queueAction({
      type = "probe.gui_capabilities",
      capabilities = guiCapabilityProbe(),
      nativeHook = nativeHookStatus(),
      networkAuthorityBootstrap = gui.networkAuthorityBootstrap,
      localOnly = true,
    })
    queueAction({ type = "snapshot.request", localOnly = true })
  end,

  guiUpdate = function()
    gui.frames = gui.frames + 1
    local currentConfig = config()
    if gui.awaitingManualHandoff and currentConfig.networkManualHandoff then
      -- Ignore validator-era suppression counters so a human action cannot be
      -- mistaken for one of the validator's already completed replays.
      local suppressed = currentBuildGateSuppressed()
      if suppressed ~= nil then gui.buildGateSuppressedSeen = suppressed end
      gui.pendingNetworkBuildPreview = nil
      gui.pendingNetworkBuildExact = nil
      gui.builderContext = nil
      local handoffTypes = api.type and api.type.ComponentType or {}
      local handoffLines = componentEntitySet(handoffTypes.LINE)
      if handoffLines then gui.nativeLineKnownIds = handoffLines end
      gui.nativeLineRecentAdded = {}
      gui.pendingNativeLinePassThroughCaptures = {}
      gui.awaitingManualHandoff = false
      local windowOk, windowError = pcall(ensureWindow)
      if not windowOk then gui.lastError = tostring(windowError) end
      pcall(installMultiplayerEntryPoints)
      queueAction({ type = "snapshot.request", localOnly = true })
      local markerOk, markerError = writeBridgeMarker(
        currentConfig.root, "manual-handoff-ready", "ready"
      )
      gui.manualHandoffReady = markerOk == true
      if not markerOk then gui.lastError = tostring(markerError) end
    end
    if not gui.nativeCommandObserverInstalled and gui.frames % 15 == 0 then
      installNativeCommandObserver()
      markNativeContext("gui")
    end
    if config().startNetwork
      and (not gui.networkAuthorityBootstrap
        or gui.networkAuthorityBootstrap.calendarReady ~= true)
      and gui.frames % 15 == 0 then
      local priorError = gui.networkAuthorityBootstrap and gui.networkAuthorityBootstrap.error or nil
      gui.networkAuthorityBootstrap = attemptGuiNetworkAuthorityBootstrap()
      if gui.networkAuthorityBootstrap.calendarReady == true
        or gui.networkAuthorityBootstrap.error ~= priorError then
        queueAction({
          type = "probe.gui_capabilities",
          capabilities = guiCapabilityProbe(),
          nativeHook = nativeHookStatus(),
          networkAuthorityBootstrap = gui.networkAuthorityBootstrap,
          localOnly = true,
        })
      end
    end
    if currentConfig.networkAutoValidate then
      local speedOk, speedError = pcall(gui.processSuppressedNativeGameSpeedCapture)
      if not speedOk then gui.lastError = tostring(speedError) end
      local lineOk, lineError = pcall(gui.processSuppressedNativeLineCommandCapture)
      if not lineOk then gui.lastError = tostring(lineError) end
      local captureOk, captureWork = pcall(processSuppressedNativeBuildCapture, false)
      if not captureOk then gui.lastError = tostring(captureWork) end
      local proposalOk, proposalWork = pcall(processGuiProposalQueue)
      if not proposalOk then gui.lastError = tostring(proposalWork) end
      if proposalOk and not proposalWork then
        local operationOk, operationWork = pcall(processGuiOperationQueue)
        if not operationOk then gui.lastError = tostring(operationWork) end
      end
      if #gui.queue > 0 then
        local action = table.remove(gui.queue, 1)
        local name = action.type == "snapshot.request" and "snapshot.request" or "intent"
        local payload = name == "snapshot.request" and {} or action
        local ok, err = pcall(function() sendToEngine(name, payload) end)
        if not ok then gui.lastError = tostring(err) end
      end
      return
    end
    if gui.frames % 30 == 0 then enforceProxyGuiLocks() end
    if not gui.entryPointsInstalled and gui.frames % 60 == 0 then
      pcall(installMultiplayerEntryPoints)
    end
    local captureOk, captureError = pcall(processVehicleCaptures)
    if not captureOk then gui.lastError = tostring(captureError) end
    local speedOk, speedError = pcall(gui.processSuppressedNativeGameSpeedCapture)
    if not speedOk then gui.lastError = tostring(speedError) end
    local lineOk, lineError = pcall(gui.processSuppressedNativeLineCommandCapture)
    if not lineOk then gui.lastError = tostring(lineError) end
    local buildCaptureOk, buildCaptureError = pcall(processSuppressedNativeBuildCapture, false)
    if not buildCaptureOk then gui.lastError = tostring(buildCaptureError) end
    local proposalOk, proposalWork = pcall(processGuiProposalQueue)
    if not proposalOk then gui.lastError = tostring(proposalWork) end
    local operationOk, operationWork = true, false
    if proposalOk and not proposalWork then
      operationOk, operationWork = pcall(processGuiOperationQueue)
      if not operationOk then gui.lastError = tostring(operationWork) end
    end
    if proposalOk and proposalWork then
      -- Native proposal callbacks and their local-ID result envelope have
      -- priority over ordinary UI intents so the transaction closes quickly.
    elseif operationOk and operationWork then
      -- Canonical line/vehicle command and its callback have priority over
      -- ordinary UI intents until the operation result is returned.
    elseif #gui.queue > 0 then
      local action = table.remove(gui.queue, 1)
      local name = action.type == "snapshot.request" and "snapshot.request" or "intent"
      local payload = name == "snapshot.request" and {} or action
      local ok, err = pcall(function()
        sendToEngine(name, payload)
      end)
      if not ok then gui.lastError = tostring(err); renderGui() end
    elseif gui.frames % 300 == 0 then
      queueAction({ type = "snapshot.request", localOnly = true })
    end
  end,

  guiHandleEvent = function(id, name, param)
    if config().networkAutoValidate then return nil end
    local ok, result = pcall(function()
      local eventName = tostring(name or "")
      local isProposalCreate = eventName:find("builder.proposalCreate", 1, true) ~= nil
      local isProposalApply = eventName:find("builder.apply", 1, true) ~= nil
      if config().operationalCapture and not isProposalCreate and not isProposalApply
        and operationalGuiMutation(id, name) then
        local envelope = expandedCommandEnvelope(param)
        local digest = hash.value({
          sourceId = tostring(id or ""),
          eventName = eventName,
          envelope = envelope,
        })
        if digest ~= gui.lastOperationalGuiDigest
          or gui.frames - (gui.lastOperationalGuiFrame or -1000) > 2 then
          gui.lastOperationalGuiDigest = digest
          gui.lastOperationalGuiFrame = gui.frames
          queueAction({
            type = "native.observed",
            observation = "gui.operationalAction",
            companyCid = gui.snapshot and gui.snapshot.activeCompanyCid or nil,
            sourceId = tostring(id or ""),
            eventName = eventName,
            observedEntityIds = eventEntityIds(param),
            eventShape = envelope,
            commandDigest = digest,
            ids = {},
            localOnly = true,
          })
        end
      end
      local isFinanceLock = gui.snapshot and gui.snapshot.proxyMode
        and name == "button.click"
        and (id == "finances.borrow" or id == "finances.repay")
      if not isProposalCreate and not isProposalApply and not isFinanceLock then
        local entityAccess = checkEntityEventAccess(id, name, param)
        if not entityAccess.allowed then
          if gui.frames - gui.lastEntityAccessDenialProbeFrame >= 15 then
            gui.lastEntityAccessDenialProbeFrame = gui.frames
            queueAction({
              type = "native.observed",
              observation = "entity.accessDenied",
              companyCid = gui.snapshot and gui.snapshot.activeCompanyCid or nil,
              ids = {},
              sourceId = tostring(id),
              accessDecision = entityAccess,
              localOnly = true,
            })
          end
          return { proposalAccessMessage(entityAccess) }
        end
      end
      if gui.snapshot and gui.snapshot.proxyMode
        and name == "button.click"
        and (id == "finances.borrow" or id == "finances.repay") then
        return { "TPF2MP: native borrowing and repayment are disabled during proxy turns" }
      elseif id == "mainView" and name == "select" then
        local selectedEntity, selectedKind = guiSelectedEntity(param)
        gui.selectedEntityId, gui.selectedEntityKind = selectedEntity, selectedKind
        if selectedKind == "vehicle" then gui.selectedVehicleId = selectedEntity
        elseif selectedKind == "depot" then gui.selectedDepotId = selectedEntity
        elseif selectedKind == "line" then gui.selectedLineId = selectedEntity end
        local selected = guiSelectedLine(param)
        if selected then gui.selectedLineId = selected end
        -- The prototype inspector remains available from its explicit HUD and
        -- pause-menu entries, but ordinary stock selections must not cover the
        -- vanilla Line Manager during a human multiplayer session.
        if not config().manualNetwork then ensureWindow() end
        renderGui()
      elseif isProposalCreate then
        local activeCompanyCid = gui.snapshot and gui.snapshot.activeCompanyCid or nil
        local networkConstructionPreview = gui.snapshot
          and gui.snapshot.networkMode == "network" and gui.rawProposalHasConstruction(param)
        local constructionPlacement = networkConstructionPreview
          and gui.constructionPreviewPlacement(param) or nil
        local matchingConstructionTemplate = constructionPlacement
          and gui.lastConstructionPreviewSnapshot
          and constructionPlacement.templateSignature == gui.lastConstructionPreviewSignature
        if matchingConstructionTemplate then
          gui.nativeBuildCapture.constructionPreviewsSkipped =
            (gui.nativeBuildCapture.constructionPreviewsSkipped or 0) + 1
          -- Only retain the cheap transform/parameter sample while the ghost
          -- moves. Walking and rewriting a 320 m/8-track graph (392 nodes and
          -- 384 edges) on every proposalCreate callback held the issuing peer
          -- at roughly 3 FPS even after a successful placement. Rebase the
          -- cached graph exactly once at builder.apply instead.
          gui.lastConstructionPreviewPlacement = constructionPlacement
          local cached = gui.lastConstructionPreviewDecision
          if cached and not cached.allowed then
            gui.builderContext = nil
            return { errorMessages = { proposalAccessMessage(cached) }, warnings = {} }
          end
          gui.builderContext = {
            companyCid = activeCompanyCid,
            -- Preserve the template's last sampled balance. Querying the
            -- native player entity for every mouse-move callback is needless;
            -- builder.apply refreshes it once if this context is new.
            balanceBefore = gui.builderContext and gui.builderContext.balanceBefore or nil,
            proposalSnapshot = gui.lastConstructionPreviewSnapshot,
          }
          return nil
        end
        if networkConstructionPreview then
          gui.nativeBuildCapture.constructionPreviewsProjected =
            (gui.nativeBuildCapture.constructionPreviewsProjected or 0) + 1
        end
        local observedSnapshot = proposalSnapshot(param)
        if networkConstructionPreview then
          local moduleSentinels = gui.constructionModuleSentinels(observedSnapshot)
          gui.lastConstructionPreviewModuleSentinels = moduleSentinels
          if constructionPlacement and moduleSentinels then
            constructionPlacement.moduleSignature = moduleSentinels.signature
            constructionPlacement.templateSignature =
              constructionPlacement.scalarSignature .. "|modules=" .. moduleSentinels.signature
          end
          gui.lastConstructionPreviewSnapshot = observedSnapshot
          gui.lastConstructionPreviewPlacement = constructionPlacement
          gui.lastConstructionPreviewSignature = constructionPlacement
            and constructionPlacement.templateSignature or nil
        end
        if gui.snapshot and (gui.snapshot.proxyMode or gui.snapshot.networkMode == "network") then
          local accessDecision = world.checkProposalAccess(
            state.world, observedSnapshot, activeCompanyCid
          )
          if networkConstructionPreview then
            gui.lastConstructionPreviewDecision = util.deepCopy(accessDecision)
          end
          if not accessDecision.allowed then
            gui.builderContext = nil
            if gui.frames - gui.lastAccessDenialProbeFrame >= 15 then
              gui.lastAccessDenialProbeFrame = gui.frames
              queueAction({
                type = "native.observed",
                observation = "builder.proposalDenied",
                companyCid = activeCompanyCid,
                ids = {},
                sourceId = tostring(id),
                proposalSnapshot = observedSnapshot,
                accessDecision = accessDecision,
                localOnly = true,
              })
            end
            return { errorMessages = { proposalAccessMessage(accessDecision) }, warnings = {} }
          end
        end
        gui.builderContext = {
          companyCid = activeCompanyCid,
          balanceBefore = guiNativeBalance(),
          proposalSnapshot = observedSnapshot,
        }
        armNetworkBuildCapture(observedSnapshot, activeCompanyCid, tostring(id))
        if gui.frames - gui.lastProposalProbeFrame >= 15 then
          gui.lastProposalProbeFrame = gui.frames
          queueAction({
            type = "native.observed",
            observation = "builder.proposalCreate",
            companyCid = gui.builderContext.companyCid,
            ids = {},
            sourceId = tostring(id),
            eventShape = eventShape(param),
            proposalSnapshot = observedSnapshot,
            localOnly = true,
          })
        end
      elseif isProposalApply then
        local context = gui.builderContext or {}
        local appliedSnapshot = proposalSnapshot(param)
        local activeCompanyCid = context.companyCid
          or (gui.snapshot and gui.snapshot.activeCompanyCid or nil)
        local balanceBefore = context.balanceBefore
        if balanceBefore == nil then balanceBefore = guiNativeBalance() end
        local previewSnapshot = context.proposalSnapshot or (gui.pendingNetworkBuildPreview
          and gui.pendingNetworkBuildPreview.proposalSnapshot or nil)
        -- Matching construction previews keep only their latest lightweight
        -- placement. Materialise that transform at the click boundary, once,
        -- before the suppressed empty builder.apply payload is merged.
        if previewSnapshot ~= nil
          and previewSnapshot == gui.lastConstructionPreviewSnapshot
          and gui.lastConstructionPreviewPlacement ~= nil then
          local rebased, rebaseError = gui.rebaseConstructionPreviewSnapshot(
            gui.lastConstructionPreviewSnapshot, gui.lastConstructionPreviewPlacement
          )
          if not rebased then
            gui.builderContext = nil
            gui.lastConstructionPreviewRebaseError = tostring(rebaseError)
            nativeBuildCaptureFailure(
              "construction click could not rebase its cached preview",
              { error = tostring(rebaseError) }
            )
            return { "TPF2MP: construction click could not be serialized safely" }
          end
          gui.lastConstructionPreviewSnapshot = rebased
          previewSnapshot = rebased
        end
        local captureSnapshot = gui.mergedAppliedProposalSnapshot(
          appliedSnapshot, previewSnapshot
        )
        armNetworkBuildCapture(captureSnapshot, activeCompanyCid, tostring(id), true)
        queueAction({
          type = "native.observed",
          observation = "builder.apply",
          companyCid = activeCompanyCid,
          ids = directResultIds(param),
          cost = proposalCost(param),
          balanceBefore = balanceBefore,
          balanceAfter = guiNativeBalance(),
          sourceId = tostring(id),
          eventShape = eventShape(param),
          proposalSnapshot = appliedSnapshot,
          edgeReplacementObservation = world.matchEdgeReplacements(
            context.proposalSnapshot, appliedSnapshot
          ),
          localOnly = true,
        })
        gui.builderContext = nil
      elseif (id == "vehicleManager" or tostring(id):match("vehicle")) and (name == "accept" or tostring(name):match("accept")) then
        if gui.snapshot and gui.snapshot.networkMode == "network" then
          local entity = type(param) == "table" and tonumber(param.entity) or -1
          if entity and entity >= 0 then
            queueAction({ type = "operation.capture", capture = {
              kind = "vehicle.replace",
              targetLocalId = entity,
              vehicleConfig = type(param) == "table" and param.vehicleConfig or nil,
            } })
          else
            local depotId = gui.selectedDepotId
            if not depotId then
              gui.lastError = "select your railway depot before opening the vehicle manager"
              renderGui()
            else
              queueAction({ type = "operation.capture", capture = {
                kind = "vehicle.buy",
                depotLocalId = depotId,
                vehicleConfig = type(param) == "table" and param.vehicleConfig or nil,
              } })
            end
          end
        else scheduleVehicleCapture(id, param) end
      end
      return nil
    end)
    if not ok then gui.lastError = tostring(result); renderGui(); return nil end
    return result
  end,
}

function data()
  return script
end
