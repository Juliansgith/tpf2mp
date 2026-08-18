local util = require "tpf2_mp/util"
local hash = require "tpf2_mp/hash"
local bridge = require "tpf2_mp/bridge"
local world = require "tpf2_mp/world"

local M = {}

function M.new(deps)
  assert(type(deps) == "table", "operational capture dependencies are required")
  local getState = assert(deps.getState, "getState dependency is required")
  local config = assert(deps.config, "config dependency is required")
  local accountOf = assert(deps.accountOf, "accountOf dependency is required")
  local activeCompany = assert(deps.activeCompany, "activeCompany dependency is required")
  local authoredDigest = assert(deps.authoredDigest, "authoredDigest dependency is required")
  local coreDigest = assert(deps.coreDigest, "coreDigest dependency is required")
  local digestPair = type(deps.digestPair) == "function" and deps.digestPair or function()
    return coreDigest(), authoredDigest()
  end
  local nativeHookStatus = assert(deps.nativeHookStatus, "nativeHookStatus dependency is required")
  local applyCommitted = assert(deps.applyCommitted, "applyCommitted dependency is required")

  local function accountSnapshot(state)
    local accounts = { companies = {} }
    for _, companyCid in ipairs(state.companyOrder or {}) do
      local company = state.companies[companyCid]
      if company and company.playerId then
        accounts.companies[companyCid] = accountOf(company.playerId)
      end
    end
    if state.world.controlPlayerId then
      accounts.control = accountOf(state.world.controlPlayerId)
    end
    accounts.activeCompanyCid = activeCompany()
    return accounts
  end

  local function sample(reason)
    local state = getState()
    local operational = state.probes.operational
    if not (operational and operational.enabled) then
      return false, "operational capture is disabled"
    end
    local sampled, runtimeOrError = xpcall(function()
      return world.operationalSnapshot(
        state.canonical, state.world, state.companies, operational.lastJournalTimeMs)
    end, debug.traceback)
    if not sampled then
      operational.lastError = tostring(runtimeOrError)
      return false, operational.lastError
    end
    local runtime = runtimeOrError
    runtime.tick = state.tick
    runtime.reason = tostring(reason or "interval")
    runtime.scope = "local-operational-observation-only"
    runtime.peerId = state.bridge.peerId
    runtime.sessionId = state.bridge.sessionId
    runtime.initialized = state.initialized == true
    runtime.matchStatus = state.match and state.match.status or nil
    runtime.activeCompanyCid = activeCompany()
    runtime.accounts = accountSnapshot(state)
    -- Keep the configured/runtime verdict beside the native population. A low
    -- person count alone is not proof that construction scaling ran.
    runtime.agentPolicy = util.deepCopy(state.probes.agentPolicy)
    local coreValue, modelValue = digestPair()
    runtime.digests = {
      model = modelValue,
      core = coreValue,
      structural = runtime.structural and runtime.structural.digest or nil,
      mobility = runtime.mobility and runtime.mobility.digest or nil,
      autonomy = runtime.autonomy and runtime.autonomy.digest or nil,
      journal = runtime.journal and runtime.journal.digest or nil,
      accounts = hash.value(runtime.accounts),
    }
    state.probes.nativeHook = nativeHookStatus()
    runtime.nativePipeline = {
      hook = util.deepCopy(state.probes.nativeHook),
      observedSendCommands = state.probes.capture.nativeCommandCount or 0,
      observedGuiActions = state.probes.capture.operationalGuiCount or 0,
      origins = util.deepCopy(state.probes.capture.nativeCommandOrigins or {}),
    }
    runtime.digest = hash.value({
      tick = runtime.tick,
      initialized = runtime.initialized,
      clock = runtime.clock,
      digests = runtime.digests,
      commandCount = runtime.nativePipeline.observedSendCommands,
      guiActionCount = runtime.nativePipeline.observedGuiActions,
      commandOrigins = runtime.nativePipeline.origins,
    })

    state.probes.structural = runtime.structural
    state.probes.mobility = runtime.mobility
    if runtime.journal and runtime.journal.toTimeMs then
      operational.lastJournalTimeMs = runtime.journal.toTimeMs
    end
    operational.sampleCount = (operational.sampleCount or 0) + 1
    local summary = {
      sequence = operational.sampleCount,
      tick = state.tick,
      reason = runtime.reason,
      initialized = runtime.initialized,
      activeCompanyCid = runtime.activeCompanyCid,
      gameSpeed = runtime.clock and runtime.clock.gameSpeed or nil,
      gameTime = runtime.clock and runtime.clock.time or nil,
      paused = runtime.clock and runtime.clock.paused or nil,
      townCount = runtime.structural and #(runtime.structural.towns or {}) or 0,
      industryCount = runtime.structural and runtime.structural.industryCount or 0,
      lineCount = runtime.structural and #(runtime.structural.lines or {}) or 0,
      vehicleCount = runtime.structural and runtime.structural.vehicleCount or 0,
      mobilityTotals = util.deepCopy(runtime.mobility and runtime.mobility.totals or {}),
      mobilityAvailability = util.deepCopy(runtime.mobility and runtime.mobility.availability or {}),
      autonomyTotals = util.deepCopy(runtime.autonomy and runtime.autonomy.totals or {}),
      journalScalars = util.deepCopy(runtime.journal and runtime.journal.scalars or {}),
      accounts = util.deepCopy(runtime.accounts),
      agentPolicy = util.deepCopy(runtime.agentPolicy),
      digests = util.deepCopy(runtime.digests),
      commandCount = runtime.nativePipeline.observedSendCommands,
      guiActionCount = runtime.nativePipeline.observedGuiActions,
      commandOrigins = util.deepCopy(runtime.nativePipeline.origins),
      digest = runtime.digest,
    }
    operational.lastSample = util.deepCopy(summary)
    operational.samples[#operational.samples + 1] = util.deepCopy(summary)
    while #operational.samples > 64 do table.remove(operational.samples, 1) end
    local emitted, outbound = bridge.emit(state.bridge, "operational", runtime, state.tick)
    if emitted then
      operational.emittedCount = (operational.emittedCount or 0) + 1
      operational.lastError = nil
    else
      operational.lastError = tostring(outbound)
    end
    return emitted, emitted and summary or operational.lastError
  end

  local function maintain()
    local state = getState()
    local cfg = config()
    local operational = state.probes.operational
    if not cfg.operationalCapture then return end
    operational.enabled = true
    operational.mode = "local-observation-only"
    operational.intervalTicks = cfg.operationalSampleTicks
    if not operational.autoInitAttempted and (state.initialized or state.tick >= 60) then
      operational.autoInitAttempted = true
      if state.initialized then
        operational.autoInit = {
          tick = state.tick, invoked = true, success = true, alreadyInitialized = true,
        }
      else
        local invoked, success, result = xpcall(function()
          return applyCommitted(
            { type = "match.initialise" }, "operational-capture:auto-init", nil)
        end, debug.traceback)
        operational.autoInit = {
          tick = state.tick,
          invoked = invoked == true,
          success = invoked == true and success == true,
          result = invoked and util.deepCopy(result) or nil,
          error = not invoked and tostring(success)
            or (success ~= true and tostring(type(result) == "table" and result.error or result) or nil),
        }
      end
      operational.nextSampleTick = state.tick
    end
    if state.tick >= math.max(1, tonumber(operational.nextSampleTick) or 1) then
      local reason = operational.sampleCount == 0 and "capture-ready" or "interval"
      local ok, err = sample(reason)
      if not ok then operational.lastError = tostring(err) end
      operational.nextSampleTick = state.tick + cfg.operationalSampleTicks
    end
  end

  return { sample = sample, maintain = maintain }
end

return M
