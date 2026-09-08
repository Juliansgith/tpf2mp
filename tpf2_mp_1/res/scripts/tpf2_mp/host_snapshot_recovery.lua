local util = require "tpf2_mp/util"
local M = {}

-- This is an explicit new-session takeover, never an in-place fault reset.
-- The pinned host save remains the evidence for all retired session work.
function M.prepare(source, cfg, version)
  if cfg.hostSnapshotRecovery ~= true or cfg.continueSavedMatch ~= true
    or cfg.startNetwork ~= true or cfg.restoreResume ~= nil then
    return nil, "host snapshot recovery requires explicit shared-save continuation"
  end
  if type(source) ~= "table" or source.version ~= version
    or source.networkMode ~= "network" or source.initialized ~= true
    or type(source.bridge) ~= "table" or source.bridge.peerId ~= "player1"
    or type(source.world) ~= "table" then
    return nil, "host snapshot recovery requires a current-version player1 network save"
  end
  if tostring(source.bridge.sessionId or "") == tostring(cfg.sessionId or "") then
    return nil, "host snapshot recovery requires a new session id"
  end
  if type(cfg.matchFingerprint) ~= "string" or #cfg.matchFingerprint ~= 64
    or not cfg.matchFingerprint:match("^[0-9a-f]+$") then
    return nil, "host snapshot recovery requires an exact save fingerprint"
  end
  if util.tableCount(source.world.originResidueCustody or {}) > 0 then
    return nil, "host snapshot has unowned native changes; use a verified earlier restore point"
  end
  local saved = util.deepCopy(source)
  local evidence = {
    fromSession = source.bridge.sessionId, sourcePeer = "player1",
    saveFingerprint = cfg.matchFingerprint, status = "adopted-awaiting-checkpoint",
    retiredProposals = util.tableCount((source.world.proposals or {}).byId or {}),
    retiredOperations = util.tableCount((source.world.operations or {}).byId or {}),
    priorProposalFault = util.deepCopy((source.world.proposalConsensus or {}).sessionFault),
    priorOperationFault = util.deepCopy((source.world.operationConsensus or {}).sessionFault),
  }
  -- Native geometry, canonical identities, companies, accounts, economy,
  -- cargo and authorized vehicle-round cursors are the host's chosen truth.
  for _, name in ipairs({ "proposals", "operations", "proposalConsensus", "operationConsensus" }) do
    saved.world[name] = { byId = {} }
  end
  saved.world.checkpointConsensus = { byBoundary = {} }
  saved.world.networkClock = nil
  saved.probes, saved.validation, saved.eventLog = nil, nil, nil
  saved.lastError, saved.lastAction, saved.lastResult = nil, nil, nil
  saved.recovery = { schemaVersion = 1, hostSnapshot = evidence }
  return saved
end

return M
