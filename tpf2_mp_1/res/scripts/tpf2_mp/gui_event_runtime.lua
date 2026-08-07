local util = require "tpf2_mp/util"
local hash = require "tpf2_mp/hash"
local canonical = require "tpf2_mp/canonical"
local world = require "tpf2_mp/world"
local proposalCodec = require "tpf2_mp/proposal_codec"
local operationCodec = require "tpf2_mp/operation_codec"
local runtimeConfig = require "tpf2_mp/runtime_config"
local guiCaptureModule = require "tpf2_mp/gui_capture"
local guiReplayRuntimeModule = require "tpf2_mp/gui_replay_runtime"
local replayQuarantine = require "tpf2_mp/gui_replay_quarantine"
local guiVehicleCaptureRuntimeModule = require "tpf2_mp/gui_vehicle_capture_runtime"
local guiNetworkBootstrapModule = require "tpf2_mp/gui_network_bootstrap"
local guiLineCommandCodec = require "tpf2_mp/gui_line_command_codec"
local M = {}
function M.new(deps)
  assert(type(deps) == "table", "GUI event runtime dependencies are required")
  local getState = assert(deps.getState, "getState dependency is required")
  local gui = assert(deps.gui, "gui dependency is required")
  local config = assert(deps.config, "config dependency is required")
  local queueAction = assert(deps.queueAction, "queueAction dependency is required")
  local renderGui = assert(deps.renderGui, "renderGui dependency is required")
  local ensureWindow = assert(deps.ensureWindow, "ensureWindow dependency is required")
  local installMultiplayerEntryPoints = assert(
    deps.installMultiplayerEntryPoints, "installMultiplayerEntryPoints dependency is required")
  local enforceProxyGuiLocks = assert(deps.enforceProxyGuiLocks, "enforceProxyGuiLocks dependency is required")
  local componentEntitySet = assert(deps.componentEntitySet, "componentEntitySet dependency is required")
  local balanceOf = assert(deps.balanceOf, "balanceOf dependency is required")
  local nativeHookStatus = assert(deps.nativeHookStatus, "nativeHookStatus dependency is required")
  local markNativeContext = assert(deps.markNativeContext, "markNativeContext dependency is required")
  local diagnosticLog = assert(deps.diagnosticLog, "diagnosticLog dependency is required")
  local projectNetworkSpeedIndicator = assert(
    deps.projectNetworkSpeedIndicator, "projectNetworkSpeedIndicator dependency is required")
  local EVENT_ID = tostring(deps.eventId or "tpf2mp")
  local SCRIPT_FILE = tostring(deps.scriptFile or "tpf2_mp.lua")
  local setDifference = util.setDifference
  local state = setmetatable({}, {
    __index = function(_, key) return getState()[key] end,
    __newindex = function(_, key, value) getState()[key] = value end,
  })
  guiVehicleCaptureRuntimeModule.install(gui, {
    queueAction = queueAction,
    maxStops = operationCodec.MAX_STOPS,
  })
  local proposalCost
  local guiCapture = guiCaptureModule.install(gui, {
    proposalCost = function(param)
      return proposalCost and proposalCost(param) or nil
    end,
  })
  local collectNumeric = guiCapture.collectNumeric
  local safeField = guiCapture.safeField
  local eventShape = guiCapture.eventShape
  local proposalSnapshot = guiCapture.proposalSnapshot
  local COMMAND_USERDATA_FIELDS = guiCapture.commandUserdataFields
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
  
  local nativeBuildCaptureFailure

  local function queueNetworkProposalCapture(pending)
    local snapshot = pending and pending.proposalSnapshot
    if not snapshot then return false, "native build capture had no proposal snapshot" end
    if pending.deferredConstructionRebase == true then
      local rebased, rebaseError = gui.rebaseConstructionPreviewSnapshot(
        util.deepCopy(snapshot), pending.constructionPlacement
      )
      if not rebased then
        return nativeBuildCaptureFailure(
          "suppressed construction click could not rebase its lightweight preview",
          { error = tostring(rebaseError) }
        )
      end
      snapshot = rebased
    end
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
        deferredConstructionRebase = pending.deferredConstructionRebase == true,
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
  
  nativeBuildCaptureFailure = function(message, details)
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

  local function armLightweightConstructionPreview(snapshot, placement, companyCid, sourceId)
    local snapshotState = gui.snapshot or {}
    if snapshotState.networkMode ~= "network" or type(placement) ~= "table"
      or not gui.proposalSnapshotHasConstructionChange(snapshot) then return false end
    if gui.buildGateSuppressedSeen == nil then
      local suppressed, statusError = currentBuildGateSuppressed()
      if suppressed == nil then
        gui.lastError = "cannot arm vanilla construction capture: " .. tostring(statusError)
        renderGui()
        return false
      end
      gui.buildGateSuppressedSeen = suppressed
    end
    gui.pendingNetworkBuildPreview = gui.lightweightConstructionPending(
      snapshot, placement, companyCid, sourceId)
    gui.nativeBuildCapture.constructionPreviewsArmed = (gui.nativeBuildCapture.constructionPreviewsArmed or 0) + 1
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
    local clock = state.world and state.world.networkClock or snapshot.networkClock or {}
    local requested = tonumber(clock.requestedSpeed)
    local effective = tonumber(clock.effectiveSpeed)
    if requested == latest and effective == latest then
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
  
  gui.nativeLineCaptureInteger = guiLineCommandCodec.integer
  gui.decodeNativeLineName = guiLineCommandCodec.decodeName
  gui.decodeSuppressedNativeLineCommand = function(raw)
    return guiLineCommandCodec.decode(
      raw, operationCodec.MAX_STOPS, operationCodec.MAX_ALTERNATIVE_TERMINALS)
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
      -- Stock Line Manager selection events do not consistently expose the
      -- line entity in their GUI payload.  The native line command does: keep
      -- that exact target as the manual-panel selection after every surviving
      -- line mutation.  This makes fare/re-check actions work for pre-existing
      -- lines without asking the player to select an invisible world entity.
      -- A deleted line deliberately clears the retained selection instead of
      -- leaving a stale local ID behind.
      guiLineCommandCodec.retainSelection(gui, capture)
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
        -- The pass-through CreateLine already mutated this world; without an
        -- identifiable output it can never be ordered, so this is residue.
        queueAction({
          type = "network.origin_residue",
          errorCode = "origin-applied-create-unidentified",
          detail = {
            tag = 3,
            capturedFrame = tonumber(pending.capturedFrame),
            stops = #(pending.decoded and pending.decoded.stops or {}),
          },
        })
        table.remove(gui.pendingNativeLinePassThroughCaptures, pendingIndex)
      else pendingIndex = pendingIndex + 1 end
    end
    for _ = 1, 8 do
      local called, raw = pcall(take)
      if not called then
        gui.lastError = "cannot read suppressed native line command: " .. tostring(raw)
        queueAction({
          type = "network.origin_residue",
          errorCode = "origin-applied-native-line-capture-read-failed",
          detail = { error = tostring(raw) },
        })
        return true
      end
      if raw == nil then break end
      local dropped = type(raw) == "string" and raw:match("^F1|queue%-overflow|(%d+)$") or nil
      if dropped then
        gui.nativeLineCapture.invalid = (gui.nativeLineCapture.invalid or 0) + 1
        gui.lastError = "native optimistic-line capture queue overflowed after an applied command"
        queueAction({
          type = "network.origin_residue",
          errorCode = "origin-applied-native-line-capture-overflow",
          detail = { dropped = tonumber(dropped) },
        })
        return true
      end
      local decoded, decodeError = gui.decodeSuppressedNativeLineCommand(raw)
      if not decoded then
        gui.nativeLineCapture.invalid = (gui.nativeLineCapture.invalid or 0) + 1
        gui.lastError = tostring(decodeError)
        queueAction({
          type = "network.origin_residue",
          errorCode = "origin-applied-native-line-envelope-invalid",
          detail = {
            error = tostring(decodeError),
            envelopePrefix = type(raw) == "string" and raw:sub(1, 64) or type(raw),
          },
        })
        return true
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

  local attemptGuiNetworkAuthorityBootstrap = guiNetworkBootstrapModule.new({
    installObserver = installNativeCommandObserver,
    markNativeContext = markNativeContext,
    configureAuthority = deps.configureNativeAuthority,
    freezeGame = deps.freezeNetworkGame,
    freezeCalendar = deps.freezeNetworkCalendar,
  })
  
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
  
  local guiReplayRuntime = guiReplayRuntimeModule.new({
    getState = getState,
    gui = gui,
    collectNumeric = collectNumeric,
    safeField = safeField,
    eventShape = eventShape,
    componentEntitySet = componentEntitySet,
    balanceOf = balanceOf,
    queueAction = queueAction,
    eventId = EVENT_ID,
    scriptFile = SCRIPT_FILE,
  })
  proposalCost = guiReplayRuntime.proposalCost
  local guiNativeBalance = guiReplayRuntime.guiNativeBalance
  local guiSelectedEntity = guiReplayRuntime.guiSelectedEntity
  local guiSelectedLine = guiReplayRuntime.guiSelectedLine
  local scheduleVehicleCapture = guiReplayRuntime.scheduleVehicleCapture
  local processVehicleCaptures = guiReplayRuntime.processVehicleCaptures
  local sendToEngine = guiReplayRuntime.sendToEngine
  local processGuiProposalQueue = guiReplayRuntime.processProposalQueue
  local processGuiOperationQueue = guiReplayRuntime.processOperationQueue
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
      stationTerminalType = hasType("StationTerminal"),
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
      nativeVehicleCommandCaptureApi =
        type(rawget(_G, "tpf2mp_native_take_suppressed_vehicle_command")) == "function",
      interfaceSendScriptEvent = type(interface.sendScriptEvent) == "function",
      simPersonCount = systems.simPersonSystem and type(systems.simPersonSystem.getCount) == "function" or false,
      simPersonsForLine = systems.simPersonSystem and type(systems.simPersonSystem.getSimPersonsForLine) == "function" or false,
      simCargosForLine = systems.simCargoSystem and type(systems.simCargoSystem.getSimCargosForLine) == "function" or false,
      simPersonTerminalInfo = systems.simPersonAtTerminalSystem
        and type(systems.simPersonAtTerminalSystem.getEdgeInfoMap) == "function" or false,
    }
  end
  
  local function guiInit()
      replayQuarantine.reset(gui)
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
  end
  
  local function dispatchQueuedAction()
      local action = gui.queue[1]
      if not action then return false end
      local name = action.type == "snapshot.request" and "snapshot.request" or "intent"
      local payload = name == "snapshot.request" and {} or action
      local called, result, detail = pcall(function()
        return sendToEngine(name, payload)
      end)
      if not called or result == false then
        gui.lastError = tostring(not called and result or detail or "GUI-to-engine dispatch rejected")
        renderGui()
        return false
      end
      table.remove(gui.queue, 1)
      return true
  end

  local function guiUpdate()
      gui.frames = gui.frames + 1
      local indicatorOk, indicatorError = pcall(projectNetworkSpeedIndicator)
      if not indicatorOk then gui.lastError = tostring(indicatorError) end
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
        gui.pendingNativeVehicleGuiCaptures = {}
        gui.pendingNativeVehicleCommands = {}
        gui.awaitingManualHandoff = false
        local windowOk, windowError = pcall(ensureWindow)
        if not windowOk then gui.lastError = tostring(windowError) end
        pcall(installMultiplayerEntryPoints)
        queueAction({ type = "snapshot.request", localOnly = true })
        local markerOk, markerError = runtimeConfig.writeBridgeMarker(
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
          or gui.networkAuthorityBootstrap.gameReady ~= true
          or gui.networkAuthorityBootstrap.calendarReady ~= true)
        and gui.frames % 15 == 0 then
        local priorError = gui.networkAuthorityBootstrap and gui.networkAuthorityBootstrap.error or nil
        gui.networkAuthorityBootstrap = attemptGuiNetworkAuthorityBootstrap()
        if (gui.networkAuthorityBootstrap.gameReady == true
            and gui.networkAuthorityBootstrap.calendarReady == true)
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
        local vehicleOk, vehicleError = pcall(gui.processSuppressedNativeVehicleCommandCapture)
        if not vehicleOk then gui.lastError = tostring(vehicleError) end
        local captureOk, captureWork = pcall(processSuppressedNativeBuildCapture, false)
        if not captureOk then gui.lastError = tostring(captureWork) end
        local proposalOk, proposalWork = pcall(processGuiProposalQueue)
        if not proposalOk then gui.lastError = tostring(proposalWork) end
        if proposalOk and not proposalWork then
          local operationOk, operationWork = pcall(processGuiOperationQueue)
          if not operationOk then gui.lastError = tostring(operationWork) end
        end
        if #gui.queue > 0 then
          dispatchQueuedAction()
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
      local nativeVehicleOk, nativeVehicleError =
        pcall(gui.processSuppressedNativeVehicleCommandCapture)
      if not nativeVehicleOk then gui.lastError = tostring(nativeVehicleError) end
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
        dispatchQueuedAction()
      elseif gui.frames % ((gui.selectedEntityId and 30) or 120) == 0 then
        queueAction({ type = "snapshot.request", localOnly = true })
      end
  end
  
  local function guiHandleEvent(id, name, param)
      if config().networkAutoValidate then return nil end
      local ok, result = pcall(function()
        local eventName = tostring(name or "")
        local isProposalCreate = eventName:find("builder.proposalCreate", 1, true) ~= nil
        local isProposalApply = eventName:find("builder.apply", 1, true) ~= nil
        local quarantined, quarantineResult = replayQuarantine.handleBuilderEvent(gui, id, isProposalCreate, isProposalApply, diagnosticLog)
        if quarantined then return quarantineResult end
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
          gui.selectedLineId = guiSelectedLine(param) or gui.selectedLineId
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
            and constructionPlacement.templateSignature ~= nil and constructionPlacement.templateSignature == gui.lastConstructionPreviewSignature
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
            armLightweightConstructionPreview(
              gui.lastConstructionPreviewSnapshot, constructionPlacement,
              activeCompanyCid, tostring(id)
            )
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
            if constructionPlacement and constructionPlacement.topologyCacheable and moduleSentinels then
              constructionPlacement.moduleSignature = moduleSentinels.signature
              constructionPlacement.templateSignature =
                constructionPlacement.scalarSignature .. "|modules=" .. moduleSentinels.signature .. "|topology=" .. constructionPlacement.topologySignature
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
              local capture = {
                kind = "vehicle.buy",
                depotLocalId = gui.selectedDepotId,
                vehicleConfig = type(param) == "table" and util.deepCopy(param.vehicleConfig) or nil,
              }
              if type(rawget(_G, "tpf2mp_native_take_suppressed_vehicle_command")) == "function" then
                gui.pendingNativeVehicleGuiCaptures[#gui.pendingNativeVehicleGuiCaptures + 1] = {
                  capture = capture,
                  capturedFrame = gui.frames,
                  maximumFrame = gui.frames + 240,
                }
              elseif capture.depotLocalId then
                -- Compatibility fallback for an older hook. It remains useful
                -- for development, but the capability report makes clear that
                -- the real visitor correlation is absent.
                queueAction({ type = "operation.capture", capture = capture })
              else
                gui.lastError = "vehicle purchase requires native hook 0.13 or a selected railway depot"
                renderGui()
              end
            end
          else scheduleVehicleCapture(id, param) end
        end
        return nil
      end)
      if not ok then gui.lastError = tostring(result); renderGui(); return nil end
      return result
  end

  return {
    init = guiInit,
    update = guiUpdate,
    handleEvent = guiHandleEvent,
    capabilityProbe = guiCapabilityProbe,
  }
end

return M
