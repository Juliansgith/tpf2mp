local restoreBootstrapRuntime = require "tpf2_mp/restore_bootstrap_runtime"
local networkBootstrapPolicy = require "tpf2_mp/network_bootstrap_policy"
local M = {}

local function initialState()
  return {
    nextAttemptTick = 240, attempts = 0, submitted = false,
    launcherReady = false, restoreNextAttemptAt = nil, waitingFor = nil,
    savedMatchAttempts = 0, savedMatchSubmitted = false,
    savedMatchNextAttemptAt = nil,
  }
end

function M.new(deps)
  local getState = assert(deps.getState, "manual bootstrap requires state")
  local config = assert(deps.config, "manual bootstrap requires config")
  local diagnosticLog = assert(deps.diagnosticLog,
    "manual bootstrap requires diagnostic logging")
  local submitIntent = assert(deps.submitIntent, "manual bootstrap requires submitIntent")
  local awaitingOrder = assert(deps.awaitingOrder, "manual bootstrap requires order state")
  local pendingBarrierReason = assert(deps.pendingBarrierReason,
    "manual bootstrap requires barrier state")
  local wallTime = assert(deps.wallTime, "manual bootstrap requires wall time")
  local maintainSavedMatchContinuation = deps.maintainSavedMatchContinuation
  local runtime = { bootstrap = initialState() }
  local restoreBootstrap = restoreBootstrapRuntime.new({
    getState = getState, config = config, diagnosticLog = diagnosticLog,
    submitIntent = submitIntent, awaitingOrder = awaitingOrder,
    pendingBarrierReason = pendingBarrierReason, wallTime = wallTime,
  })

  function runtime.maintain(launcherReady)
    local state, cfg, bootstrap = getState(), config(), runtime.bootstrap
    if launcherReady == true then bootstrap.launcherReady = true end
    local ready = cfg.manualBootstrapReady == true or bootstrap.launcherReady == true
    if not cfg.manualNetwork or not ready or state.networkMode ~= "network"
      or state.bridge.peerId ~= "player1" then return end
    if restoreBootstrap.maintain(bootstrap) then return end
    -- Rebinding a save to a new room deliberately clears its old content
    -- attestation. Re-establish content authority before either a fresh match
    -- or exact-save continuation becomes the first checkpointed boundary.
    if networkBootstrapPolicy.deferForContent(state, bootstrap, diagnosticLog) then return end
    if type(maintainSavedMatchContinuation) == "function"
      and maintainSavedMatchContinuation(bootstrap, {
        submitIntent = submitIntent, awaitingOrder = awaitingOrder,
        pendingBarrierReason = pendingBarrierReason,
        diagnosticLog = diagnosticLog, wallTime = wallTime,
      }) then return end
    if state.tick < math.max(240, tonumber(bootstrap.nextAttemptTick) or 240)
      or state.initialized or awaitingOrder() or pendingBarrierReason() then return end
    local authority = state.probes.networkAuthority or {}
    if authority.ready ~= true then bootstrap.nextAttemptTick = state.tick + 30; return end
    bootstrap.attempts = bootstrap.attempts + 1
    local ok, result = submitIntent({ type = "match.initialise" })
    bootstrap.submitted = ok == true
    bootstrap.nextAttemptTick = state.tick + (ok and 600 or 60)
    diagnosticLog("manual-network-bootstrap", {
      success = ok == true, attempt = bootstrap.attempts,
      localSeq = type(result) == "table" and (result.local_seq or result.localSeq) or nil,
      error = not ok and tostring(type(result) == "table" and result.error or result) or nil,
      tick = state.tick,
    })
  end

  function runtime.reset()
    local replacement = initialState()
    for key in pairs(runtime.bootstrap) do runtime.bootstrap[key] = nil end
    for key, value in pairs(replacement) do runtime.bootstrap[key] = value end
  end
  return runtime
end

return M
