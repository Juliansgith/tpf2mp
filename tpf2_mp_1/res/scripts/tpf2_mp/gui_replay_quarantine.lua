local selectorGuard = require "tpf2_mp/gui_native_selector_guard"
local M = {}

function M.arm(gui, proposalId)
  assert(type(gui) == "table", "GUI state is required")
  if gui.proposalReplayQuarantine then return nil, "another proposal replay is active" end
  local value = {}
  local suspended, suspendError = selectorGuard.suspend(value)
  if not suspended then return nil, "could not suspend native selector: " .. tostring(suspendError) end
  gui.proposalReplayQuarantine = {
    proposalId = tostring(proposalId), startedFrame = gui.frames,
    issueAfterFrame = (tonumber(gui.frames) or 0) + 1, phase = "armed",
    selectorSuspended = value.selectorSuspended, selectorWasEnabled = value.selectorWasEnabled,
    previews = 0, applies = 0,
  }
  if type(gui.invalidateBuildCorrelation) == "function" then
    gui.invalidateBuildCorrelation("canonical-replay-begin", { clearConstruction = true })
  end
  return true
end

function M.ready(gui, proposalId)
  local value = gui and gui.proposalReplayQuarantine
  return value and value.phase == "armed"
    and tostring(value.proposalId) == tostring(proposalId)
    and (tonumber(gui.frames) or 0) >= (tonumber(value.issueAfterFrame) or math.huge)
end

function M.beforeIssue(gui, proposalId)
  local value = gui and gui.proposalReplayQuarantine
  if not value then
    local armed, err = M.arm(gui, proposalId)
    return armed and "armed" or nil, err
  end
  if tostring(value.proposalId) ~= tostring(proposalId) then return "busy" end
  if not M.ready(gui, proposalId) then return "waiting" end
  M.markIssued(gui, proposalId)
  return "ready"
end

function M.markIssued(gui, proposalId)
  local value = gui and gui.proposalReplayQuarantine
  if not value or tostring(value.proposalId) ~= tostring(proposalId) then return false end
  value.phase = "issued"
  return true
end

function M.nativeSettled(gui, proposalId)
  local value = gui and gui.proposalReplayQuarantine
  if not value or tostring(value.proposalId) ~= tostring(proposalId) then return false end
  value.phase = "settling"
  value.selectorReleaseFrame = (tonumber(gui.frames) or 0) + 3
  return true
end

function M.update(gui)
  local value = gui and gui.proposalReplayQuarantine
  selectorGuard.update(value, gui and gui.frames)
end

function M.finish(gui, proposalId)
  assert(type(gui) == "table", "GUI state is required")
  local quarantine = gui.proposalReplayQuarantine
  if not quarantine or tostring(quarantine.proposalId) ~= tostring(proposalId) then return false end
  if type(gui.invalidateBuildCorrelation) == "function" then
    gui.invalidateBuildCorrelation("canonical-replay-finish", {
      clearConstruction = true, silent = true,
    })
  end
  selectorGuard.release(quarantine)
  gui.proposalReplayQuarantine = nil
  return true
end

function M.reset(gui)
  assert(type(gui) == "table", "GUI state is required")
  selectorGuard.release(gui.proposalReplayQuarantine)
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
