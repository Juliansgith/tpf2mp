local util = require "tpf2_mp/util"
local constructionDeltaAttestation = require "tpf2_mp/construction_delta_attestation"

local M = {}

function M.prepare(record, deps)
  local spec, specError = deps.codec.materialiseConstruction(record.transaction)
  if not spec then return nil, tostring(specError) end
  local before, captureError = deps.verification.snapshot()
  if not before then return nil, tostring(captureError) end
  local beforeFingerprints = {}
  if spec.mode == "upgrade" then
    beforeFingerprints = deps.verification.captureUpgradeFingerprints(
      before, spec, deps.fingerprint)
  end
  return {
    rootEntity = nil,
    sourceRootEntity = spec.mode ~= "build" and tonumber(
      record.localRefs and record.localRefs[spec.sourceCid]) or nil,
    spec = util.deepCopy(spec),
    before = before,
    beforeFingerprints = beforeFingerprints,
    startedTick = deps.tick,
    deadlineTick = deps.tick + deps.timeoutTicks,
    stableSinceTick = nil,
    lastSignature = nil,
    lastReadySignature = nil,
    nextVerificationTick = deps.tick + deps.firstVerifyDelayTicks,
    verificationScans = 0,
  }
end

function M.isExact(record, codec)
  local transaction = record and record.transaction
  local construction = type(transaction) == "table"
    and type(transaction.constructions) == "table" and transaction.constructions[1] or nil
  local edgeObjects = type(transaction) == "table"
    and type(transaction.edgeObjects) == "table" and transaction.edgeObjects or {}
  -- Assigning a typed ConstructionEntity to SimpleProposal.constructionsToAdd
  -- makes Build 35924 expand the construction's generated graph itself.  The
  -- exact GUI path therefore owns only fresh builds whose adjunct edge-object
  -- edits do not need a separately materialised street proposal. Upgrades and
  -- removals retain the live-proven engine helper until their replacement and
  -- retirement semantics have their own native proof.
  return type(transaction) == "table"
    and transaction.schemaVersion == codec.CONSTRUCTION_SCHEMA_VERSION
    and type(construction) == "table" and construction.mode == "build"
    and #(edgeObjects.add or {}) == 0 and #(edgeObjects.retain or {}) == 0
    and not codec.isTopologyConstructionRemoval(transaction)
end

function M.prime(record, pending)
  pending.phase = "awaiting-gui-build"
  record.constructionPending = pending
  record.replayPath = "gui-build-proposal"
end

function M.fallback(record)
  record.constructionPending = nil
  record.replayPath = "helper-fallback"
  record.status = "queued"
  return { helperFallback = true, proposalId = record.proposalId }
end

function M.accept(record, payload, tick, firstVerifyDelayTicks, maximumOutputs)
  local pending = record.constructionPending
  if type(pending) ~= "table" or pending.phase ~= "awaiting-gui-build" then
    return nil, "exact construction replay state is unavailable"
  end
  pending.phase = "settling-gui-build"
  local delta, deltaError = constructionDeltaAttestation.normalise(
    payload.constructionDelta, maximumOutputs)
  if not delta then return nil, deltaError end
  pending.guiDelta = delta
  if pending.spec.mode ~= "build" then pending.rootEntity = pending.sourceRootEntity end
  pending.nextVerificationTick = tick + firstVerifyDelayTicks
  record.status = "building-construction"
  return { constructionVerificationPending = true, guiAttested = true,
    proposalId = record.proposalId }
end

function M.identifyBuiltRoot(pending, added, rootKind)
  if pending.spec.mode == "build" and pending.rootEntity == nil
    and #(added[rootKind] or {}) == 1 then pending.rootEntity = added[rootKind][1] end
end

return M
