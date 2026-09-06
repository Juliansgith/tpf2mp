local util = require "tpf2_mp/util"

local M = {
  QUIET_WALL_SECONDS = 1,
  QUIET_PASSES = 2,
}

local function wallTime()
  if not (os and type(os.time) == "function") then return nil end
  local ok, value = pcall(os.time)
  return ok and tonumber(value) or nil
end

function M.new(deps)
  assert(type(deps) == "table" and type(deps.getState) == "function",
    "checkpoint batch state provider is required")
  local exportCheckpoint = assert(deps.exportCheckpoint,
    "checkpoint batch exporter is required")
  local originWorkState = assert(deps.originWorkState,
    "checkpoint batch origin-work provider is required")
  local diagnosticLog = deps.diagnosticLog or function() end
  local now = deps.wallTime or wallTime
  local quietSeconds = math.max(0, util.integer(
    deps.quietWallSeconds, M.QUIET_WALL_SECONDS))
  local quietPasses = math.max(1, util.integer(deps.quietPasses, M.QUIET_PASSES))
  local pending

  local function schedule(boundarySeq, reason, proposalId)
    boundarySeq = math.max(1, util.integer(boundarySeq, 0))
    local currentWall = now()
    pending = {
      boundarySeq = boundarySeq,
      reason = tostring(reason or "physical-consensus"),
      proposalId = proposalId and tostring(proposalId) or nil,
      notBeforeWall = currentWall and currentWall + quietSeconds or nil,
      remainingPasses = quietPasses,
    }
    diagnosticLog("checkpoint-batch-scheduled", {
      boundarySeq = boundarySeq, reason = pending.reason,
      quietWallSeconds = quietSeconds, quietPasses = quietPasses,
      tick = deps.getState().tick,
    })
    return true, util.deepCopy(pending)
  end

  local function supersede(action, authoritySeq)
    if type(action) ~= "table" then return false end
    local boundary = util.integer(action.supersedesCheckpointBoundarySeq, 0)
    if boundary < 1 then return false end
    authoritySeq = math.max(0, util.integer(authoritySeq, 0))
    if authoritySeq <= boundary then
      error("checkpoint supersession must be ordered after its boundary")
    end
    local changed = false
    if pending and pending.boundarySeq == boundary then
      pending, changed = nil, true
    end
    local barriers = deps.getState().world.checkpointConsensus.byBoundary or {}
    local record = barriers[tostring(boundary)] or barriers[boundary]
    if type(record) == "table" and record.status == "pending" then
      record.status = "superseded"
      record.supersededBySeq = authoritySeq
      record.supersededByOperation = tostring(
        action.transaction and action.transaction.transactionId or "")
      changed = true
    end
    diagnosticLog("checkpoint-batch-superseded", {
      boundarySeq = boundary, supersededBySeq = authoritySeq,
      operationKind = action.transaction and action.transaction.kind or nil,
      tick = deps.getState().tick,
    })
    return changed
  end

  local function maintain()
    if not pending then return false end
    local state = deps.getState()
    if state.networkMode ~= "network" then pending = nil; return false end
    local work = originWorkState() or {}
    if work.pending == true then
      pending.remainingPasses = quietPasses
      return false
    end
    local currentWall = now()
    if pending.notBeforeWall and currentWall and currentWall < pending.notBeforeWall then
      return false
    end
    pending.remainingPasses = math.max(0,
      util.integer(pending.remainingPasses, quietPasses) - 1)
    if pending.remainingPasses > 0 then return false end
    local candidate = pending
    local ok, result = exportCheckpoint(
      candidate.boundarySeq, candidate.reason, candidate.proposalId)
    if ok then
      pending = nil
      diagnosticLog("checkpoint-batch-exported", {
        boundarySeq = candidate.boundarySeq, reason = candidate.reason,
        tick = state.tick,
      })
      return true, result
    end
    candidate.remainingPasses = quietPasses
    candidate.notBeforeWall = currentWall and currentWall + quietSeconds or nil
    diagnosticLog("checkpoint-batch-export-failed", {
      boundarySeq = candidate.boundarySeq, reason = candidate.reason,
      error = tostring(result), tick = state.tick,
    })
    return false, result
  end

  return {
    schedule = schedule,
    supersede = supersede,
    maintain = maintain,
    pending = function() return util.deepCopy(pending) end,
    reset = function() pending = nil end,
  }
end

return M
