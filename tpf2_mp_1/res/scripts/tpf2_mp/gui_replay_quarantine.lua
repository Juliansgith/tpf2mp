local M = {}

function M.begin(gui, proposalId)
  assert(type(gui) == "table", "GUI state is required")
  gui.proposalReplayQuarantine = {
    proposalId = tostring(proposalId),
    startedFrame = gui.frames,
    previews = 0,
    applies = 0,
  }
  if type(gui.invalidateBuildCorrelation) == "function" then
    gui.invalidateBuildCorrelation("canonical-replay-begin", { clearConstruction = true })
  end
end

function M.finish(gui, proposalId)
  assert(type(gui) == "table", "GUI state is required")
  local quarantine = gui.proposalReplayQuarantine
  if not quarantine or tostring(quarantine.proposalId) ~= tostring(proposalId) then return false end
  gui.proposalReplayQuarantine = nil
  return true
end

function M.reset(gui)
  assert(type(gui) == "table", "GUI state is required")
  gui.proposalReplayQuarantine = nil
  if type(gui.invalidateBuildCorrelation) == "function" then
    gui.invalidateBuildCorrelation("canonical-replay-reset", { clearConstruction = true })
  end
end

function M.handleBuilderEvent(gui, id, isProposalCreate, isProposalApply, diagnosticLog)
  assert(type(gui) == "table", "GUI state is required")
  local quarantine = gui.proposalReplayQuarantine
  if not quarantine or (not isProposalCreate and not isProposalApply) then return false, nil end

  -- Do not accept or read the event payload here.  After a delayed canonical
  -- signal/track replay, its proposal userdata can retain a native pointer to
  -- the edge just replaced by that replay.  Projecting that stale ghost caused
  -- Build 35924's internal-error minidump on the issuing peer.
  if type(gui.invalidateBuildCorrelation) == "function" then
    gui.invalidateBuildCorrelation("canonical-replay-builder-callback", {
      clearConstruction = true, silent = true,
    })
  else
    gui.builderContext = nil
  end
  gui.nativeBuildCapture = gui.nativeBuildCapture or {}
  if isProposalCreate then
    quarantine.previews = (quarantine.previews or 0) + 1
    gui.nativeBuildCapture.replayPreviewsQuarantined =
      (gui.nativeBuildCapture.replayPreviewsQuarantined or 0) + 1
    if quarantine.previews == 1 and type(diagnosticLog) == "function" then
      diagnosticLog("proposal-replay-preview-quarantined", {
        proposalId = quarantine.proposalId,
        sourceId = tostring(id or ""),
      })
    end
    return true, nil
  end

  quarantine.applies = (quarantine.applies or 0) + 1
  gui.nativeBuildCapture.replayAppliesRejected =
    (gui.nativeBuildCapture.replayAppliesRejected or 0) + 1
  if type(diagnosticLog) == "function" then
    diagnosticLog("proposal-replay-apply-rejected", {
      proposalId = quarantine.proposalId,
      sourceId = tostring(id or ""),
    })
  end
  return true, {
    errorMessages = { "TPF2MP: the previous multiplayer build is still synchronising" },
    warnings = {},
  }
end

return M
