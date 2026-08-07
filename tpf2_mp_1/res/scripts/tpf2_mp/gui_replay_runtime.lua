local util = require "tpf2_mp/util"
local world = require "tpf2_mp/world"
local proposalCodec = require "tpf2_mp/proposal_codec"
local operationCodec = require "tpf2_mp/operation_codec"
local replayQuarantine = require "tpf2_mp/gui_replay_quarantine"

local M = {}

function M.new(deps)
  assert(type(deps) == "table", "GUI replay runtime dependencies are required")
  local getState = assert(deps.getState, "getState dependency is required")
  local gui = assert(deps.gui, "gui dependency is required")
  local collectNumeric = assert(deps.collectNumeric, "collectNumeric dependency is required")
  local safeField = assert(deps.safeField, "safeField dependency is required")
  local eventShape = assert(deps.eventShape, "eventShape dependency is required")
  local componentEntitySet = assert(deps.componentEntitySet, "componentEntitySet dependency is required")
  local balanceOf = assert(deps.balanceOf, "balanceOf dependency is required")
  local queueAction = assert(deps.queueAction, "queueAction dependency is required")
  local EVENT_ID = tostring(deps.eventId or "tpf2mp")
  local SCRIPT_FILE = tostring(deps.scriptFile or "tpf2_mp.lua")
  local setDifference = util.setDifference

  local state = setmetatable({}, {
    __index = function(_, key) return getState()[key] end,
    __newindex = function(_, key, value) getState()[key] = value end,
  })
  local proposalCost

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
      -- Keep the origin's builder ghost quarantined until the native result has
      -- crossed back into engine state.  Clearing this in the command callback
      -- is too early: Build 35924 can emit stale signal/track previews while
      -- the post-build wallet sample is still settling.
      replayQuarantine.finish(gui, payload.proposalId)
      return true
    end
    -- Physical authority permits one proposal at a time.  If a malformed save
    -- or future caller exposes another queued record, do not overlap its native
    -- replay with the proposal whose builder userdata is being quarantined.
    if gui.proposalReplayQuarantine then return true end
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
        replayQuarantine.begin(gui, proposalId)
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
        -- Generated API userdata can reject a structurally valid Lua value by
        -- throwing before a command factory is entered. Close that ordered
        -- operation explicitly: the outer GUI update pcall can keep the game
        -- alive, but by itself would leave operationIssued latched forever and
        -- strand both peers behind a consensus barrier.
        local materialised, spec, materialiseError = pcall(
          operationCodec.materialise, record.transaction, {
            api = api,
            nativePlayerId = record.nativePlayerId,
            resolveLocal = function(cid)
              return record.localRefs and record.localRefs[cid]
            end,
          })
        if not materialised then
          materialiseError, spec = spec, nil
        end
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
  

  return {
    proposalCost = proposalCost,
    guiNativeBalance = guiNativeBalance,
    guiSelectedEntity = guiSelectedEntity,
    guiSelectedLine = guiSelectedLine,
    scheduleVehicleCapture = scheduleVehicleCapture,
    processVehicleCaptures = processVehicleCaptures,
    sendToEngine = sendToEngine,
    processProposalQueue = processGuiProposalQueue,
    processOperationQueue = processGuiOperationQueue,
  }
end

return M
