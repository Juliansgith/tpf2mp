local M = { REJECT_IF_BUSY = "reject-if-busy" }

local function pending(section)
  return math.max(0, tonumber(section and section.pending) or 0)
end

local function unfinished(section)
  local queued = math.max(0, tonumber(section and section.queued) or 0)
  local finished = math.max(0, tonumber(section and section.applied) or 0)
    + math.max(0, tonumber(section and section.failed) or 0)
  return math.max(0, queued - finished)
end

function M.reason(snapshot)
  snapshot = type(snapshot) == "table" and snapshot or {}
  if snapshot.networkMode ~= "network" then return nil end
  local companion = snapshot.bridge and snapshot.bridge.companion or {}
  if companion.connected == false then return "the network companion is disconnected" end
  local proposalFault = snapshot.proposalConsensus and snapshot.proposalConsensus.sessionFault
  local operationFault = snapshot.operationConsensus and snapshot.operationConsensus.sessionFault
  if proposalFault or operationFault then return "the multiplayer session is faulted" end
  local clock = snapshot.networkClock or {}
  if clock.rendezvous then return "the shared clock is completing a rendezvous" end
  local queue = snapshot.deferredNetworkQueue or {}
  if queue.awaitingOrder then return "the previous action is awaiting host order" end
  if (tonumber(queue.count) or 0) > 0 then return "earlier physical actions are queued" end
  if unfinished(snapshot.proposals) > 0 then return "a physical build is still applying" end
  if unfinished(snapshot.operations) > 0 then return "a vehicle or line operation is still applying" end
  if pending(snapshot.proposalConsensus) > 0 then return "a physical build is awaiting peer consensus" end
  if pending(snapshot.operationConsensus) > 0 then return "a vehicle or line operation is awaiting peer consensus" end
  if pending(snapshot.checkpointConsensus) > 0 then return "the current checkpoint is awaiting peer consensus" end
  return nil
end

function M.message(reason)
  return "TPF2MP: " .. tostring(reason or "multiplayer is synchronising")
    .. "; this construction click was not queued. Retry when synchronisation completes."
end

function M.refresh(gui, snapshot)
  local capture = snapshot and snapshot.probes and snapshot.probes.capture or {}
  local failures = math.max(0, tonumber(capture.proposalCodecFailureCount) or 0)
  if gui.observedProposalCodecFailures == nil then
    gui.observedProposalCodecFailures = failures
  elseif failures > gui.observedProposalCodecFailures then
    gui.observedProposalCodecFailures = failures
    if type(gui.invalidateBuildCorrelation) == "function" then
      gui.invalidateBuildCorrelation("proposal-codec-rejection", { clearConstruction = true })
    end
  end
  if M.reason(snapshot) then return end
  gui.blockedConstructionApplyUntilFrame = nil
  gui.constructionBusyNoticeActive = false
end

function M.queuePolicy(gui, snapshot)
  -- Engine-local IDs are valid only against the topology visible at click time.
  if M.reason(snapshot or gui.snapshot)
      and type(gui.invalidateBuildCorrelation) == "function" then
    gui.invalidateBuildCorrelation("busy-build-capture-retired", {
      clearConstruction = true, silent = true,
    })
  end
  return M.REJECT_IF_BUSY
end

local function capturedConstruction(gui, pending)
  return pending and gui.proposalSnapshotHasConstructionChange
    and gui.proposalSnapshotHasConstructionChange(pending.proposalSnapshot)
end

function M.handleBuilderEvent(gui, id, isCreate, isApply, param, diagnosticLog)
  local reason = M.reason(gui.snapshot)
  if not reason then
    gui.blockedConstructionApplyUntilFrame = nil
    gui.constructionBusyNoticeActive = false
    return false
  end
  local construction = isCreate and gui.rawProposalHasConstruction(param)
  if isApply then
    construction = gui.rawProposalHasConstruction(param)
      or (gui.blockedConstructionApplyUntilFrame or -1) >= (gui.frames or 0)
      or capturedConstruction(gui, gui.builderContext)
      or capturedConstruction(gui, gui.pendingNetworkBuildPreview)
      or capturedConstruction(gui, gui.pendingNetworkBuildExact)
      or capturedConstruction(gui, gui.pendingNetworkBuildSuppression
        and gui.pendingNetworkBuildSuppression.pending)
  end
  if not construction then return false end
  if not isApply then return false end
  local capture = gui.nativeBuildCapture or {}
  local firstNotice = gui.constructionBusyNoticeActive ~= true
  if firstNotice then capture.busyRejected = (capture.busyRejected or 0) + 1 end
  gui.constructionBusyNoticeActive = true
  gui.nativeBuildCapture = capture
  local message = M.message(reason)
  gui.lastError = message
  if firstNotice then
    gui.lastConstructionBusyDiagnosticFrame = gui.frames or 0
    diagnosticLog("construction-input-busy-rejected", {
      sourceId = tostring(id or ""), reason = reason,
      builderEvent = isApply and "builder.apply" or "builder.proposalCreate", rejected = capture.busyRejected,
    })
  end
  -- Native suppression still prevents mutation; the exact capture is rejected.
  return false
end

return M
