-- Bounded, read-only evidence for disposable UI tests. Never enabled by a save.
local M = {}
local token = os.getenv("TPF2MP_LIVE_UI_TOKEN") or ""
local session = os.getenv("TPF2MP_SESSION_ID") or ""
local enabled = #token == 32 and token:match("^[a-f0-9]+$")
  and session:match("^localhost%-ui%-%w[%w_.%-]*$")

function M.capture(gui, pending)
  if not enabled then return end
  -- proposalSnapshot is already a bounded plain-Lua copy, not native userdata.
  gui.liveUiLastBuildCapture = { frame = gui.frames, exact = pending.exact,
    sourceId = pending.sourceId, correlationId = pending.correlationId,
    snapshot = pending.proposalSnapshot }
end

function M.replay(gui, proposalId, command, shape)
  if not enabled then return end
  gui.liveUiLastBuildReplay = { frame = gui.frames, proposalId = proposalId,
    command = shape(command, 0, {}, { remaining = 8192 }, {
      expandUserdata = true, expandUserdataPairs = true, maxDepth = 12, maxEntries = 256,
      userdataFields = { "proposal", "data", "context", "streetProposal",
        "toAdd", "toRemove", "addedNodes", "addedSegments", "removedNodes",
        "removedSegments", "entity", "comp", "node0", "node1", "position",
        "tangent0", "tangent1", "x", "y", "z", "trackEdge", "streetEdge",
        "type", "typeIndex", "trackType", "streetType", "catenary",
        "hasBus", "tramTrackType", "resultProposalData", "proposalData",
        "withCostRep", "ignoreErrors", "costs", "error", "errors",
        "critical", "errorState", "collisionEntities", "resultEntities",
        "flags", "cleanupStreetGraph", "checkTerrainAlignment", "player" },
    }) }
end
return M
