local M = {}

local function expected(validation)
  return validation.values.industryContentExpected == true
end

function M.observe(state, validation)
  local probe = state.probes and state.probes.industryContent or nil
  validation.values.industryContentExpected = type(probe) == "table"
    and type(probe.localDigest) == "string" and probe.localDigest ~= ""
  return expected(validation)
end

function M.ready(state, validation)
  return not expected(validation)
    or (state.world.industryContent and state.world.industryContent.ready == true)
end

local function canSubmit(state, validation, deps)
  return M.ready(state, validation)
    and not deps.awaitingOrder()
    and not deps.pendingBarrierReason()
end

function M.trySubmit(state, validation, deps, label, retry)
  validation.values.lastInitialiseAttemptTick = state.tick
  if not canSubmit(state, validation, deps) then
    deps.log("auto-validation-bootstrap-deferred", {
      stage = validation.stage,
      reason = not M.ready(state, validation)
        and "industry-content-not-ready" or "ordered-lane-busy",
      tick = state.tick,
    })
    return false
  end
  local result = deps.submit({ type = "match.initialise" }, label)
  validation.values.initialiseLocalSeq = result and result.local_seq
  if retry then
    deps.log("auto-validation-retry", {
      stage = validation.stage,
      localSeq = result and result.local_seq or nil,
      tick = state.tick,
    })
  end
  return true, result
end

function M.retry(state, validation, deps, minimumTicks)
  local lastAttempt = tonumber(validation.values.lastInitialiseAttemptTick)
    or tonumber(validation.stageStartedTick) or 0
  if state.tick - lastAttempt < minimumTicks then return false end
  return M.trySubmit(state, validation, deps,
    "host-match-initialise-retry-queued", true)
end

function M.expected(validation)
  return expected(validation)
end

return M
