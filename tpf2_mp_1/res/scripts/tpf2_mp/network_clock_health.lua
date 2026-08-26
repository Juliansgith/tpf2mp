local util = require "tpf2_mp/util"

local M = {}

function M.payload(state, observed, clock, work)
  local proposalPending = false
  for _, record in pairs(state.world.proposalConsensus.byId or {}) do
    if record.status == "pending" then proposalPending = true; break end
  end
  local rendezvous = clock.rendezvous
  local proposalFault = state.world.proposalConsensus
    and state.world.proposalConsensus.sessionFault or nil
  local operationFault = state.world.operationConsensus
    and state.world.operationConsensus.sessionFault or nil
  return {
    schemaVersion = 4,
    requestedSpeed = util.integer(clock.requestedSpeed, 0),
    effectiveSpeed = util.integer(clock.effectiveSpeed, 0),
    generation = util.integer(clock.generation, 0),
    observedSpeed = tonumber(observed.gameSpeed),
    gameTime = tonumber(observed.time),
    engineTick = state.tick,
    lastCommitSeq = math.max(0, util.integer((state.bridge.nextInSeq or 1) - 1, 0)),
    proposalPending = proposalPending,
    localWorkPending = work.pending == true,
    deferredIntentCount = math.max(0, util.integer(work.deferredCount, 0)),
    faultCode = tostring((proposalFault or operationFault or {}).errorCode or ""),
    originResidueCount = util.tableCount(state.world.originResidueCustody or {}),
    rendezvousGeneration = rendezvous and util.integer(rendezvous.generation, 0) or 0,
    rendezvousState = rendezvous and tostring(rendezvous.status or "armed") or "idle",
    rendezvousTargetTime = rendezvous and tonumber(rendezvous.targetGameTime) or 0,
  }
end

return M
