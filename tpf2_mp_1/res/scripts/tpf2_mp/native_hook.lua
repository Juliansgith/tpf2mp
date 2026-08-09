local util = require "tpf2_mp/util"
local json = require "tpf2_mp/json"

local M = {}

function M.compactStatus(payload)
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
  local suppressedVehicleCommands = type(commandGate.suppressedVehicleCommands) == "table"
    and commandGate.suppressedVehicleCommands
    or type(payload.suppressedVehicleCommands) == "table" and payload.suppressedVehicleCommands
    or {}
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
      local commandEvent = {
        localSequence = tonumber(event.localSequence),
        batch = tonumber(event.batch),
        index = tonumber(event.index),
        tag = tonumber(event.tag),
        name = tostring(event.name or "unknown"),
      }
      if event.success == true then commandEvent.success = true
      elseif event.success == false then commandEvent.success = false end
      commandEvents[#commandEvents + 1] = commandEvent
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
    suppressedVehicleCommands = {
      queued = math.max(0, tonumber(suppressedVehicleCommands.queued) or 0),
      captured = math.max(0, tonumber(suppressedVehicleCommands.captured) or 0),
      consumed = math.max(0, tonumber(suppressedVehicleCommands.consumed) or 0),
      invalid = math.max(0, tonumber(suppressedVehicleCommands.invalid) or 0),
      dropped = math.max(0, tonumber(suppressedVehicleCommands.dropped) or 0),
      lastTag = tonumber(suppressedVehicleCommands.lastTag),
      lastTarget = tonumber(suppressedVehicleCommands.lastTarget),
      lastSecondary = tonumber(suppressedVehicleCommands.lastSecondary),
    },
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

function M.status()
  local fn = rawget(_G, "tpf2mp_native_status")
  if type(fn) ~= "function" then return { available = false } end
  local ok, payload = pcall(fn)
  if not ok then return { available = true, error = tostring(payload) } end
  if type(payload) == "table" then
    return M.compactStatus(payload)
  end
  if type(payload) == "string" then
    local decodedOk, decoded = pcall(json.decode, payload)
    if decodedOk and type(decoded) == "table" then
      return M.compactStatus(decoded)
    end
    return { available = true, error = "native status JSON decode failed", raw = payload:sub(1, 512) }
  end
  return { available = true, error = "native status returned " .. type(payload) }
end

function M.validatedNetworkAuthority(nativeStatus)
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

function M.markContext(context)
  local fn = rawget(_G, "tpf2mp_native_mark_context")
  if type(fn) ~= "function" then return false end
  return pcall(fn, tostring(context))
end


return M
