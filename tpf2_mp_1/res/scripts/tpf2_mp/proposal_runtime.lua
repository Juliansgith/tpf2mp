local util = require "tpf2_mp/util"
local hash = require "tpf2_mp/hash"
local canonical = require "tpf2_mp/canonical"
local bridge = require "tpf2_mp/bridge"
local finance = require "tpf2_mp/finance"
local world = require "tpf2_mp/world"
local proposalCodec = require "tpf2_mp/proposal_codec"
local proposalCollateralRuntime = require "tpf2_mp/proposal_collateral_runtime"
local proposalBindingRuntime = require "tpf2_mp/proposal_binding_runtime"
local edgeOwnership = require "tpf2_mp/edge_ownership"
local networkFinanceHousekeepingModule = require "tpf2_mp/network_finance_housekeeping"
local resourceCompatibility = require "tpf2_mp/resource_compatibility"
local activeRecordIndex = require "tpf2_mp/active_record_index"
local proposalWorkScheduler = require "tpf2_mp/proposal_work_scheduler"
local constructionVerificationModule = require "tpf2_mp/construction_verification_runtime"
local constructionReplayState, constructionDeltaAttestation = require "tpf2_mp/construction_replay_state", require "tpf2_mp/construction_delta_attestation"
local constructionOutputOrder = require "tpf2_mp/construction_output_order"

local M = {}

-- buildConstruction returns its root before every generated station child and
-- topology component is visible to the engine component iterators.  A busy
-- two-instance Build 35924 session has now been observed taking longer than
-- 120 script updates even though both peers ultimately produced byte-for-byte
-- equivalent worlds.  Keep the wait bounded, but allow enough headroom for
local CONSTRUCTION_SETTLE_TIMEOUT_TICKS = 600
local CONSTRUCTION_FIRST_VERIFY_DELAY_TICKS = 2
local CONSTRUCTION_VERIFY_INTERVAL_TICKS, CONSTRUCTION_PENDING_RESCAN_TICKS, CONSTRUCTION_STABLE_TICKS = 3, 6, 3
M.verifyTopologyCollateralRemoved = proposalCollateralRuntime.verifyRemoved
M.verifyRemovalOnlyInputsRemoved = proposalCollateralRuntime.verifyTopologyRemoved

function M.new(deps)
  assert(type(deps) == "table", "proposal runtime dependencies are required")
  local getState = assert(deps.getState, "getState dependency is required")
  local requireRunningMatch = assert(deps.requireRunningMatch, "requireRunningMatch dependency is required")
  local balanceOf = assert(deps.balanceOf, "balanceOf dependency is required")
  local coreDigest = assert(deps.coreDigest, "coreDigest dependency is required")
  local refreshOwnershipProbe = assert(deps.refreshOwnershipProbe, "refreshOwnershipProbe dependency is required")
  local componentEntitySet = assert(deps.componentEntitySet, "componentEntitySet dependency is required")
  local inspectCreatedNodes = assert(deps.inspectCreatedNodes, "inspectCreatedNodes dependency is required")
  local inspectCreatedEdges = assert(deps.inspectCreatedEdges, "inspectCreatedEdges dependency is required")
  local nodePosition = assert(deps.nodePosition, "nodePosition dependency is required")
  local applyCommitted = assert(deps.applyCommitted, "applyCommitted dependency is required")
  local observeProposal = deps.observeProposal or resourceCompatibility.observer(getState)
  local networkFinanceHousekeeping, networkFinanceHousekeepingDue =
    networkFinanceHousekeepingModule.new({ getState = getState })

  -- Transport Fever replaces the persisted table during script.load. This
  -- proxy keeps every read/write aimed at the current table without forcing
  -- the transaction code to retain a stale save-state reference.
  local state = setmetatable({}, {
    __index = function(_, key) return getState()[key] end,
    __newindex = function(_, key, value) getState()[key] = value end,
  })

  local proposalPreparation = {
    pending = {},
    -- Vanilla line commands are allowed to finish on their initiating machine
    -- so the stock Line Manager receives the real entity/revision its callback
    -- expects. This machine-local table bridges that optimistic result to the
    -- later host-ordered operation. Only an opaque token crosses the wire.
    originAppliedOperations = {},
    nextOriginToken = 1,
  }

  local financeWork = activeRecordIndex.new(function(record)
    return type(record) == "table" and record.status == "awaiting-finance"
      and type(record.pendingFinance) == "table"
  end)
  local constructionWork = activeRecordIndex.new(function(record)
    return type(record) == "table" and type(record.transaction) == "table"
      and record.transaction.schemaVersion == proposalCodec.CONSTRUCTION_SCHEMA_VERSION
      and not proposalCodec.isTopologyConstructionRemoval(record.transaction)
      and ((record.status == "queued" and record.replayPath ~= "gui-build-proposal")
        or (record.status == "building-construction" and record.constructionPending))
  end)

  local constructionVerification = constructionVerificationModule.new({
    getState = getState,
    componentEntitySet = componentEntitySet,
    componentEntityExists = deps.componentEntityExists,
  })

  local function prepareConstructionReplay(record)
    return constructionReplayState.prepare(record, {
      codec = proposalCodec, verification = constructionVerification, fingerprint = world.fingerprint,
      tick = state.tick, timeoutTicks = CONSTRUCTION_SETTLE_TIMEOUT_TICKS,
      firstVerifyDelayTicks = CONSTRUCTION_FIRST_VERIFY_DELAY_TICKS,
    })
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

  local function proposalFailure(record, message, options)
    options = type(options) == "table" and options or {}
    if options.rollbackLazyBindings == true then proposalBindingRuntime.rollback(state, record) end
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
      for _, collateral in ipairs(construction and construction.collateral or {}) do
        local _, err = checkOwnedReference(
          collateral.cid, collateral.kind, true,
          "proposal cannot demolish a rival construction ")
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
    return proposalBindingRuntime.bind(state, inspected, eventId)
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
  
    local localRefs, localInputs, bindError, newlyBoundCids, canonicalRevisionBefore =
      proposalPreparation.bind(inspected, eventId)
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
      newlyBoundCids = newlyBoundCids,
      canonicalRevisionBefore = canonicalRevisionBefore,
      issuerPlayerId = issuerPlayerId,
      nativeOwnerPlayerId = nativeOwnerPlayerId,
      -- Compatibility alias for version <= 9 saves/research readers.
      controlPlayerId = issuerPlayerId,
      balanceBefore = balanceOf(issuerPlayerId),
      nativeOwnerBalanceBefore = balanceOf(nativeOwnerPlayerId),
      status = "queued",
      queuedTick = state.tick,
    }
    if record.balanceBefore == nil then
      proposalBindingRuntime.rollback(state, record)
      return false, "proposal issuer balance is unavailable"
    end
    if constructionReplayState.isExact(record, proposalCodec) then
      local pending, pendingError = prepareConstructionReplay(record)
      if not pending then proposalBindingRuntime.rollback(state, record); return false, pendingError end
      constructionReplayState.prime(record, pending)
    end
    state.world.proposals.byId[eventId] = record
    if type(observeProposal) == "function" then
      -- The manager is diagnostic and must never become a second authority
      -- gate after codec validation and peer resource preflight succeeded.
      pcall(observeProposal, transaction)
    end
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
    record.newlyBoundCids = nil
    record.canonicalRevisionBefore = nil
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
    for _, proposalId in ipairs(financeWork.candidates(state.world.proposals)) do
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

  local finaliseCanonicalConstruction
  local function finaliseCanonicalProposal(payload)
    financeWork.invalidate(); constructionWork.invalidate()
    payload = type(payload) == "table" and payload or {}
    local proposalId = tostring(payload.proposalId or "")
    local record = state.world.proposals.byId[proposalId]
    if not record then return false, "unknown pending canonical proposal" end
    if record.status == "applied" then return true, util.deepCopy(record.result) end
    if record.status == "failed" then return false, util.deepCopy(record.result) end
    local exactConstruction = constructionReplayState.isExact(record, proposalCodec)
    if exactConstruction and payload.fallbackHelper == true and payload.worldUnchanged == true then
      return true, constructionReplayState.fallback(record) end
    if payload.success ~= true then
      return proposalFailure(record, {
        error = tostring(payload.error or "GUI-state BuildProposal was rejected"),
      }, {
        -- Only the GUI replay layer can attest this: it snapshots every
        -- relevant native component set and both wallets around the rejected
        -- command. Restoring commit-time lazy bindings then returns the core
        -- digest to the all-peer PREPARE boundary, allowing a strict
        -- recoverable rejection instead of poisoning the whole session.
        rollbackLazyBindings = payload.worldUnchanged == true,
      })
    end
    if exactConstruction then
      local accepted, acceptError = constructionReplayState.accept(
        record, payload, state.tick, 0, proposalCodec.MAX_CONSTRUCTION_NODES)
      if not accepted then return proposalFailure(record, acceptError) end
      return finaliseCanonicalConstruction(record)
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
    local topologyConstructionRemoval = proposalCodec.isTopologyConstructionRemoval(transaction)
    if topologyConstructionRemoval then
      local removed, removalError = M.verifyTopologyCollateralRemoved(record.localInputs, world)
      if not removed then return proposalFailure(record, removalError) end
      local edgeObjects = transaction.edgeObjects or {}
      local hasTopologyOutputs = #(transaction.nodes or {}) > 0 or #(transaction.edges or {}) > 0
        or #(edgeObjects.add or {}) > 0 or #(edgeObjects.retain or {}) > 0
      if not hasTopologyOutputs then
        -- A public-road bulldoze with attached houses has no replacement graph.
        -- Native success must prove both the constructions and every explicit
        -- topology input disappeared before canonical identities are retired.
        removed, removalError = M.verifyRemovalOnlyInputsRemoved(record.localInputs, world)
        if not removed then return proposalFailure(record, removalError) end
      end
    elseif proposalCodec.isRemovalOnly(transaction) then
      local removed, removalError = M.verifyRemovalOnlyInputsRemoved(record.localInputs, world)
      if not removed then return proposalFailure(record, removalError) end
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
  
  proposalPreparation.construction = {
    componentKinds = constructionVerification.componentKinds,
  }
  
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
      local rows, rowsError = constructionOutputOrder.rows(descriptor.kind, values, {
        exact = pending.guiDelta ~= nil, proposalDigest = record.transaction.digest,
        fingerprint = world.fingerprint,
      })
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
          -- Build 35924 exposes the generated IDs to the GUI immediately, but
          -- touching some of their freshly created native components from the
          -- engine game-script thread terminates that script environment.  The
          -- GUI delta and proposal-derived fingerprint are the authoritative
          -- attestation for exact replay; background probes must not re-enter
          -- those component userdata just to rediscover the same identity.
          nativeReadUnsafe = pending.guiDelta ~= nil,
        })
        if not ok then return nil, bindError end
        state.world.logicalOwners[tostring(localId)] = record.companyCid
        state.world.pinnedCustody[tostring(localId)] = {
          cid = cid,
          kind = descriptor.kind,
          logicalOwnerCid = record.companyCid,
          nativePlayerId = pending.guiDelta and record.nativeOwnerPlayerId
            or world.ownerOf(localId) or record.nativeOwnerPlayerId,
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
  
  local function buildCanonicalConstructionRoot(record, pending)
    local interface = game and game.interface or {}
    if interface.buildConstruction == nil then
      return nil, "engine construction build API is unavailable"
    end
    local activePlayer = type(interface.getPlayer) == "function" and tonumber(interface.getPlayer()) or nil
    if activePlayer ~= tonumber(record.issuerPlayerId) then
      return nil, "construction replay player mapping changed before execution"
    end
    local started = constructionVerification.started()
    local called, entityOrError = pcall(
      interface.buildConstruction, pending.spec.fileName, pending.spec.params, pending.spec.transform)
    constructionVerification.recordTiming("native-build-helper", started)
    local rootEntity = called and tonumber(entityOrError) or nil
    if not rootEntity or rootEntity < 0 then
      return nil, tostring(called and "construction helper returned no entity" or entityOrError)
    end
    if type(interface.setPlayer) == "function" then
      local assigned, assignError = pcall(interface.setPlayer, rootEntity, record.nativeOwnerPlayerId)
      if not assigned then
        return nil, "station ownership assignment failed: " .. tostring(assignError)
      end
    end
    pending.rootEntity = rootEntity
    pending.phase = "settling-build"
    pending.stableSinceTick = nil
    pending.lastSignature = nil
    pending.lastReadySignature = nil
    pending.nextVerificationTick = state.tick + CONSTRUCTION_FIRST_VERIFY_DELAY_TICKS
    return rootEntity
  end

  local function beginCanonicalConstruction(record)
    local activePlayer = type(game.interface.getPlayer) == "function" and tonumber(game.interface.getPlayer()) or nil
    if activePlayer ~= tonumber(record.issuerPlayerId) then
      return proposalFailure(record, "construction replay player mapping changed before execution")
    end
    local pending, materialiseError = prepareConstructionReplay(record)
    if not pending then return proposalFailure(record, tostring(materialiseError)) end
    local spec = pending.spec
    record.balanceBefore = balanceOf(record.issuerPlayerId)
    record.nativeOwnerBalanceBefore = balanceOf(record.nativeOwnerPlayerId)
    local interface = game and game.interface or {}
    local called, entityOrError, rootEntity
    if spec.mode == "build" then
      if interface.buildConstruction == nil then
        return proposalFailure(record, "engine construction build API is unavailable")
      end
      if #(spec.collateral or {}) > 0 and interface.bulldoze == nil then
        return proposalFailure(record, "engine collateral bulldoze API is unavailable")
      end
      for _, collateral in ipairs(spec.collateral or {}) do
        local collateralLocalId = record.localRefs and tonumber(record.localRefs[collateral.cid]) or nil
        if not collateralLocalId then
          return proposalFailure(record, "construction collateral is not mapped locally")
        end
        local demolished, demolishError = pcall(interface.bulldoze, collateralLocalId)
        if not demolished then return proposalFailure(record, tostring(demolishError)) end
      end
      if #(spec.collateral or {}) > 0 then
        -- Native demolition retires construction graphs over later script ticks.
        -- Building in the same tick can make the helper resolve its transform
        -- relative to the doomed obstacle.  Wait until every canonical input is
        -- observably absent, then replay the captured absolute transform.
        pending.phase = "clearing-collateral"
      else
        local buildError
        rootEntity, buildError = buildCanonicalConstructionRoot(record, pending)
        if not rootEntity then return proposalFailure(record, buildError) end
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
      pending.rootEntity = rootEntity
      pending.phase = "settling-change"
      pending.nextVerificationTick = state.tick + CONSTRUCTION_FIRST_VERIFY_DELAY_TICKS
    end
    if spec.mode == "upgrade" and type(game.interface.setPlayer) == "function" then
      local assigned, assignError = pcall(game.interface.setPlayer, rootEntity, record.nativeOwnerPlayerId)
      if not assigned then return proposalFailure(record, "station ownership assignment failed: " .. tostring(assignError)) end
    end
    record.status = "building-construction"
    record.constructionPending = pending
    return true, {
      building = pending.phase ~= "clearing-collateral",
      clearingCollateral = pending.phase == "clearing-collateral",
      rootEntity = rootEntity,
    }
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

  function proposalPreparation.construction.pendingRemovalInputs(record, after)
    local counts, total = {}, 0
    for _, input in ipairs(record.localInputs or {}) do
      local kind = tostring(input.kind or "")
      local localId = tonumber(input.localId)
      if localId and after[kind] and after[kind][localId] then
        counts[kind] = (counts[kind] or 0) + 1
        total = total + 1
      end
    end
    return total, counts
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
      newRows = constructionOutputOrder.rows(kind, added[kind] or {}, {
        fingerprint = world.fingerprint,
      })
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
  
  finaliseCanonicalConstruction = function(record)
    local pending = record.constructionPending
    if pending.phase == "clearing-collateral" then
      local pendingRemovalInputs, pendingRemovalKinds, targetedError =
        constructionVerification.inputsPending(record.localInputs)
      local after, captureError
      if pendingRemovalInputs == nil then
        after, captureError = constructionVerification.snapshot()
        if not after then
          return proposalFailure(record, tostring(captureError or targetedError))
        end
        pendingRemovalInputs, pendingRemovalKinds =
          proposalPreparation.construction.pendingRemovalInputs(record, after)
      end
      if pendingRemovalInputs > 0 then
        if state.tick < pending.deadlineTick then
          pending.nextVerificationTick = state.tick + CONSTRUCTION_PENDING_RESCAN_TICKS
          return true, {
            waiting = true,
            phase = pending.phase,
            pendingRemovalInputs = pendingRemovalInputs,
            pendingRemovalKinds = pendingRemovalKinds,
          }
        end
        return proposalFailure(record, {
          error = "construction collateral did not retire before the build deadline",
          pendingRemovalInputs = pendingRemovalInputs,
          pendingRemovalKinds = pendingRemovalKinds,
        })
      end
      local rootEntity, buildError = buildCanonicalConstructionRoot(record, pending)
      if not rootEntity then return proposalFailure(record, buildError) end
      return true, { building = true, rootEntity = rootEntity }
    end
    if not pending.guiDelta
      and state.tick < util.integer(pending.nextVerificationTick, state.tick) then
      return true, {
        waiting = true, phase = pending.phase, verificationDeferred = true,
        nextVerificationTick = pending.nextVerificationTick,
      }
    end
    local mode = pending.spec.mode
    local rootKind = pending.spec.kind == "asset" and "asset" or "construction"
    -- A targeted getComponent(CONSTRUCTION) lookup can transiently report nil
    -- for a root returned by BuildProposal while the same root is already in
    -- forEachEntityWithComponent and its generated station graph is complete.
    -- We need the full before/after sets below in every case, so make that
    -- snapshot authoritative instead of turning a false-negative shortcut
    -- into a verification timeout.
    local after, added, removed
    if pending.guiDelta then
      added, removed = pending.guiDelta.added, pending.guiDelta.removed
      after = constructionDeltaAttestation.apply(pending.before, pending.guiDelta)
    else
      local captureError
      after, captureError = constructionVerification.snapshot()
      if not after then return proposalFailure(record, tostring(captureError)) end
      added = constructionVerification.delta(after, pending.before)
      removed = constructionVerification.delta(pending.before, after)
    end
    pending.verificationScans = util.integer(pending.verificationScans, 0) + 1
    constructionReplayState.identifyBuiltRoot(pending, added, rootKind)
    local counts, removedCounts = constructionVerification.counts(added), constructionVerification.counts(removed)
    local signature = constructionVerification.signature(added, removed)
    pending.lastSignature = signature
    pending.lastCounts, pending.lastRemovedCounts = counts, removedCounts
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
    local pendingRemovalInputs, pendingRemovalKinds =
      proposalPreparation.construction.pendingRemovalInputs(record, after)
    if mode == "build" then
      ready = ready and rootSet[pending.rootEntity] == true
        and beforeRootSet[pending.rootEntity] ~= true and pendingRemovalInputs == 0
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
        and pendingRemovalInputs == 0
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
    if ready then
      if pending.lastReadySignature ~= signature or pending.stableSinceTick == nil then
        pending.lastReadySignature = signature
        pending.stableSinceTick = state.tick
      end
    else
      pending.lastReadySignature = nil
      pending.stableSinceTick = nil
    end
    local stable = pending.guiDelta and ready or (ready and state.tick
      - util.integer(pending.stableSinceTick, state.tick) >= CONSTRUCTION_STABLE_TICKS)
    if not ready or not stable then
      if not pending.guiDelta and state.tick < pending.deadlineTick then
        pending.nextVerificationTick = state.tick
          + (ready and CONSTRUCTION_VERIFY_INTERVAL_TICKS or CONSTRUCTION_PENDING_RESCAN_TICKS)
        return true, {
          waiting = true, mode = mode, counts = counts, removedCounts = removedCounts,
          verificationScans = pending.verificationScans,
          nextVerificationTick = pending.nextVerificationTick,
        }
      end
      return proposalFailure(record, {
        error = "construction change did not stabilize to its canonical postcondition",
        mode = mode, counts = counts, removedCounts = removedCounts,
        expected = {
          node = expectedNodes, edge = expectedEdges, kind = pending.spec.kind,
          upgradeChanged = mode == "upgrade" and upgradeChanged or nil,
          pendingRemovalInputs = mode ~= "upgrade" and pendingRemovalInputs or nil,
          pendingRemovalKinds = mode ~= "upgrade" and pendingRemovalKinds or nil,
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
      constructionReplayPath = record.replayPath or "engine-helper",
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
    for _, proposalId in ipairs(constructionWork.candidates(state.world.proposals)) do
      local record = state.world.proposals.byId[proposalId]
      if type(record) == "table" and record.transaction
        and record.transaction.schemaVersion == proposalCodec.CONSTRUCTION_SCHEMA_VERSION
        and not proposalCodec.isTopologyConstructionRemoval(record.transaction) then
        if (record.status == "queued" and record.replayPath ~= "gui-build-proposal")
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

  return {
    preparation = proposalPreparation,
    queue = queueCanonicalProposal,
    finalise = finaliseCanonicalProposal,
    beginConstruction = beginCanonicalConstruction,
    finaliseConstruction = finaliseCanonicalConstruction,
    processConstructions = processCanonicalConstructionProposals,
    hasConstructionWork = function()
      return proposalWorkScheduler.hasDueConstruction(state, constructionWork)
    end,
    processFinances = processPendingProposalFinances,
    hasFinanceWork = function()
      return proposalWorkScheduler.hasDueFinance(state, financeWork)
    end,
    financeHousekeeping = networkFinanceHousekeeping,
    financeHousekeepingDue = networkFinanceHousekeepingDue,
    emitCompletion = emitProposalCompletion,
  }
end

return M
