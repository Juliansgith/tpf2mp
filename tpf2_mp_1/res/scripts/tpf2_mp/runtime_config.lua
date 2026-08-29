local util = require "tpf2_mp/util"
local economyDifficulty = require "tpf2_mp/economy_difficulty"

local M = {}

local function oneShotValidationConfig()
  if not (io and io.open and os and os.getenv) then return nil end
  local ok, result = pcall(function()
    local temp = os.getenv("TEMP") or "."
    local base = temp .. "/tpf2mp_bridge/auto-live"
    local marker = io.open(base .. "/enable", "r")
    if not marker then return nil end
    marker:close()
    return { root = base .. "/player1", peerId = "player1", sessionId = "auto-live" }
  end)
  return ok and result or nil
end

local function processEnvironment(name)
  if not (os and os.getenv) then return nil end
  local ok, value = pcall(os.getenv, name)
  if ok and value and value ~= "" then return value end
  return nil
end

local function bridgeMarkerExists(root, name)
  if not (io and io.open) then return false end
  if type(root) ~= "string" or root == "" or type(name) ~= "string"
    or not name:match("^[%w_.%-]+$") then return false end
  local file = io.open(root .. "/launcher/" .. name, "rb")
  if not file then return false end
  file:close()
  return true
end

local function bridgeMarkerValue(root, name)
  if not (io and io.open) then return nil end
  if type(root) ~= "string" or root == "" or type(name) ~= "string"
    or not name:match("^[%w_.%-]+$") then return nil end
  local file = io.open(root .. "/launcher/" .. name, "rb")
  if not file then return nil end
  local value = file:read("*a")
  file:close()
  return tostring(value or ""):match("^%s*(.-)%s*$")
end

local function playerIdList(value)
  local result, seen = {}, {}
  for raw in tostring(value or ""):gmatch("%d+") do
    local playerId = tonumber(raw)
    if playerId and playerId >= 0 and playerId == math.floor(playerId)
      and not seen[playerId] and #result < 8 then
      seen[playerId] = true
      result[#result + 1] = playerId
    end
  end
  return result
end

local function restoreResumeConfig(readEnvironment, enabled)
  if not enabled then return nil end
  local sourceSession = tostring(readEnvironment("TPF2MP_RESTORE_FROM_SESSION") or "")
  local boundarySeq = tonumber(readEnvironment("TPF2MP_RESTORE_BOUNDARY"))
  local coreDigest = tostring(readEnvironment("TPF2MP_RESTORE_CORE_DIGEST") or "")
  local convergenceKey = tostring(readEnvironment("TPF2MP_RESTORE_CONVERGENCE_KEY") or "")
  local planChecksum = tostring(readEnvironment("TPF2MP_RESTORE_PLAN_CHECKSUM") or "")
  local vehiclePhaseDigest = tostring(
    readEnvironment("TPF2MP_RESTORE_VEHICLE_PHASE_DIGEST") or "")
  local valid = sourceSession:match("^[%w][%w_.%-]*$") ~= nil and #sourceSession <= 64
    and boundarySeq and boundarySeq >= 1 and boundarySeq == math.floor(boundarySeq)
    and coreDigest:match("^[0-9a-f]+$") ~= nil and #coreDigest == 8
    and convergenceKey:match("^[0-9a-f]+$") ~= nil and #convergenceKey == 8
    and planChecksum:match("^[0-9a-f]+$") ~= nil and #planChecksum == 8
    and vehiclePhaseDigest:match("^[0-9a-f]+$") ~= nil and #vehiclePhaseDigest == 8
  return {
    requested = true,
    valid = valid and true or false,
    fromSession = sourceSession,
    boundarySeq = boundarySeq,
    coreDigest = coreDigest,
    convergenceKey = convergenceKey,
    planChecksum = planChecksum,
    vehiclePhaseDigest = vehiclePhaseDigest,
    error = not valid and "launcher restore attestation is malformed" or nil,
  }
end

function M.writeBridgeMarker(root, name, content)
  if not (io and io.open) then return false, "Lua file IO is unavailable" end
  if type(root) ~= "string" or root == "" or type(name) ~= "string"
    or not name:match("^[%w_.%-]+$") then return false, "invalid bridge marker" end
  local file, err = io.open(root .. "/launcher/" .. name, "wb")
  if not file then return false, tostring(err) end
  file:write(tostring(content or "ready"))
  file:close()
  return true
end

function M.read(options)
  local injected = type(options) == "table"
  options = injected and options or {}
  local source = injected and (options.source or {})
    or (game and game.config and game.config.tpf2mp or {})
  -- Supplying options creates a deterministic, side-effect-free configuration
  -- boundary for tests and tooling. Production calls intentionally retain the
  -- process environment and one-shot bridge marker behavior.
  local readEnvironment = injected and (options.environment or function() return nil end)
    or processEnvironment
  local environmentEnabled = function(name)
    local value = readEnvironment(name)
    if value == nil then return false end
    value = string.lower(tostring(value))
    return value == "1" or value == "true" or value == "yes" or value == "on"
  end
  local markerExists = injected and (options.bridgeMarkerExists or function() return false end)
    or bridgeMarkerExists
  local markerValue = injected and (options.bridgeMarkerValue or function() return nil end)
    or bridgeMarkerValue
  local forced = injected and options.forcedValidation or oneShotValidationConfig()
  -- app.startGame() creates a default test world without necessarily running
  -- an installed mod's runFn. Read the same explicit process overrides here so
  -- injected/unattended worlds still receive an isolated peer, bridge, and
  -- validation mode. In normal games mod.lua has already populated `source`.
  local root = tostring((forced and forced.root) or readEnvironment("TPF2MP_BRIDGE_DIR")
    or source.bridgeDir or ".")
  local manualNetwork = source.manualNetwork == true
    or environmentEnabled("TPF2MP_MANUAL_NETWORK")
  -- A launcher-managed manual session must not emit match.initialise from the
  -- transient menu/pre-load world. PowerShell writes this marker only after
  -- both exact processes have loaded the pinned save and activated authority.
  local manualBootstrapReady = not manualNetwork
    or markerValue(root, "manual-bootstrap-ready") == "ready"
  local networkValidationRequested = source.networkAutoValidate == true
    or environmentEnabled("TPF2MP_NETWORK_AUTOTEST")
  local networkRuntimeRequested = networkValidationRequested or manualNetwork
  local restoreResume = restoreResumeConfig(readEnvironment,
    environmentEnabled("TPF2MP_RESTORE_RESUME"))
  local matchFingerprint = string.lower(tostring(
    readEnvironment("TPF2MP_MATCH_FINGERPRINT") or ""))
  if not matchFingerprint:match("^[0-9a-f]+$") or #matchFingerprint ~= 64 then
    matchFingerprint = ""
  end
  -- The two-process validator and the human lab use the same exact processes.
  -- Once PowerShell has independently accepted both validation records it
  -- writes this per-peer marker. Both Lua states then leave validator-only GUI
  -- handling without weakening the native command gates or unfreezing autonomy.
  local networkManualHandoff = networkValidationRequested
    and markerExists(root, "manual-handoff")
  local networkAutoValidate = networkValidationRequested and not networkManualHandoff
  local operationalCapture = source.operationalCapture == true
    or environmentEnabled("TPF2MP_OPERATIONAL_CAPTURE")
  local startNetwork = source.startNetwork == true
    or environmentEnabled("TPF2MP_START_NETWORK") or networkAutoValidate or manualNetwork
  local localProxy = source.localProxyEnabled ~= false
  if networkRuntimeRequested then localProxy = false end
  return {
    protocol = tonumber(source.protocolVersion) or 1,
    root = root,
    peerId = tostring((forced and forced.peerId) or readEnvironment("TPF2MP_PEER_ID")
      or source.peerId or "player1"),
    sessionId = tostring((forced and forced.sessionId) or readEnvironment("TPF2MP_SESSION_ID")
      or source.sessionId or "local-dev"),
    updateStride = math.max(1, tonumber(source.updateStride) or 15),
    networkBridgeStride = math.max(1, tonumber(
      readEnvironment("TPF2MP_NETWORK_BRIDGE_STRIDE")
        or source.networkBridgeStride) or 1),
    networkBridgeFallbackStride = math.max(1, tonumber(
      readEnvironment("TPF2MP_NETWORK_FALLBACK_STRIDE")
        or source.networkBridgeFallbackStride) or 1),
    maxEvents = math.max(32, tonumber(source.maxEvents) or 64),
    autoFreeze = source.autoFreeze == true or networkRuntimeRequested or operationalCapture,
    neutralizer = source.journalNeutralizerEnabled == true,
    startNetwork = startNetwork,
    localProxy = localProxy,
    pauseOnSwitch = not forced and not networkRuntimeRequested and not operationalCapture
      and source.pauseOnSwitch ~= false,
    autoValidate = forced ~= nil or source.autoValidate == true
      or environmentEnabled("TPF2MP_AUTOVALIDATE"),
    networkAutoValidate = networkAutoValidate,
    networkValidationSlice = tostring(
      readEnvironment("TPF2MP_NETWORK_VALIDATION_SLICE")
        or source.networkValidationSlice or "full"),
    networkManualHandoff = networkManualHandoff,
    manualNetwork = manualNetwork,
    developerEconomyControls = source.developerEconomyControls == true
      or environmentEnabled("TPF2MP_DEVELOPER_ECONOMY")
      or networkAutoValidate or forced ~= nil,
    manualBootstrapReady = manualBootstrapReady,
    -- Test/launcher automation may request the same safe host-authored action
    -- as the in-game Prepare & Save button. The marker grants no save or
    -- restore authority; normal ordering, quiescence and receipt checks remain
    -- mandatory.
    automaticRecoveryPrepare = manualNetwork
      and markerValue(root, "prepare-restore") == "ready",
    restoreResume = restoreResume,
    -- Launcher-managed shared saves use one of two explicit paths: a
    -- receipt-bound restore plan, or an exact-clone continuation that must
    -- establish a fresh all-peer checkpoint before gameplay. This flag is an
    -- authorization request only; state migration still rejects dirty,
    -- faulted, uninitialised, or fingerprint-unbound source saves.
    continueSavedMatch = manualNetwork
      and environmentEnabled("TPF2MP_CONTINUE_SAVED_MATCH")
      and restoreResume == nil,
    matchFingerprint = matchFingerprint,
    operationalCapture = operationalCapture,
    -- Agent presentation policy is match content; the label and its
    -- fingerprint travel into state so peers can compare them.
    -- Loss conditions are match settings; the defaults come from the mod
    -- parameters and any of them can be switched off for a build-together
    -- session that only compares company value at the end.
    -- Physical town development is an experiment: it lets vanilla choose
    -- lots and relies on the structural digest to say whether the two
    -- worlds agreed. Off by default until a live run answers that.
    townDevelopment = source.townDevelopment == true
      or environmentEnabled("TPF2MP_TOWN_DEVELOPMENT"),
    bankruptcyEnabled = source.bankruptcyEnabled ~= false,
    insolventSettlements = util.integer(source.insolventSettlements, 3),
    creditBaseLimitCents = util.integer(source.creditBaseLimitCents, 500000000),
    creditRevenueMultiple = util.integer(source.creditRevenueMultiple, 4),
    creditInterestPermille = util.integer(source.creditInterestPermille, 15),
    agentMode = tostring(readEnvironment("TPF2MP_AGENT_MODE") or source.agentMode or "skeleton"),
    agentPolicyFingerprint = tostring(source.agentPolicyFingerprint or ""),
    operationalSampleTicks = math.max(30, util.integer(
      readEnvironment("TPF2MP_OPERATIONAL_SAMPLE_TICKS")
        or source.operationalSampleTicks, 120)),
    networkSoakTicks = math.max(60, util.integer(
      readEnvironment("TPF2MP_NETWORK_SOAK_TICKS") or source.networkSoakTicks, 300)),
    networkClockRunTicks = math.max(30, util.integer(
      readEnvironment("TPF2MP_NETWORK_CLOCK_RUN_TICKS")
        or source.networkClockRunTicks, 30)),
    startingCash = math.max(0, util.integer(
      readEnvironment("TPF2MP_STARTING_CASH") or source.startingCash, 50000000)),
    economyDifficulty = economyDifficulty.normaliseKey(
      readEnvironment("TPF2MP_ECONOMY_DIFFICULTY") or source.economyDifficulty),
    revenueMultiplierPpm = economyDifficulty.multiplier(
      readEnvironment("TPF2MP_ECONOMY_DIFFICULTY") or source.economyDifficulty),
    startingCompanyPlayerIds = playerIdList(
      readEnvironment("TPF2MP_STARTING_COMPANY_PLAYER_IDS")
        or source.startingCompanyPlayerIds),
    maxEpochs = math.max(0, util.integer(source.maxEpochs, 288)),
    valuationTargetCents = math.max(0, util.integer(source.valuationTargetCents, 50000000000)),
  }
end

-- Process environment, mod parameters, and the launcher identity are immutable
-- for one game-script VM.  Only three one-way launcher markers can change
-- after load.  Rebuilding the complete configuration on every engine/GUI
-- update used to perform dozens of getenv calls and up to three file opens per
-- call.  This reader retains the exact configuration table and samples only
-- those sticky markers at a bounded call cadence.
function M.newReader(options)
  options = type(options) == "table" and options or {}
  local stride = math.max(1, util.integer(options.dynamicStride, 30))
  local readConfig = options.readConfig or function() return M.read() end
  local emptySource = {}
  local sourceIdentity = options.sourceIdentity or function()
    return game and game.config and game.config.tpf2mp or emptySource
  end
  local markerExists = options.bridgeMarkerExists or bridgeMarkerExists
  local markerValue = options.bridgeMarkerValue or bridgeMarkerValue
  local cached, cachedSource, validationRequested
  local callsUntilRefresh = 0
  local stats = { reads = 0, dynamicRefreshes = 0, markerReads = 0 }

  local function rebuild(source)
    cached, cachedSource = readConfig(), source
    validationRequested = cached.networkAutoValidate == true
      or cached.networkManualHandoff == true
    callsUntilRefresh = stride
    stats.reads = stats.reads + 1
  end

  local function refreshDynamic()
    stats.dynamicRefreshes = stats.dynamicRefreshes + 1
    if cached.manualNetwork and cached.manualBootstrapReady ~= true then
      stats.markerReads = stats.markerReads + 1
      cached.manualBootstrapReady = markerValue(
        cached.root, "manual-bootstrap-ready") == "ready"
    end
    if validationRequested and cached.networkManualHandoff ~= true then
      stats.markerReads = stats.markerReads + 1
      if markerExists(cached.root, "manual-handoff") then
        cached.networkManualHandoff, cached.networkAutoValidate = true, false
      end
    end
    if cached.manualNetwork and cached.automaticRecoveryPrepare ~= true then
      stats.markerReads = stats.markerReads + 1
      cached.automaticRecoveryPrepare = markerValue(
        cached.root, "prepare-restore") == "ready"
    end
  end

  local reader = {}
  function reader.read(force)
    local source = sourceIdentity()
    if cached == nil or source ~= cachedSource then rebuild(source) end
    callsUntilRefresh = callsUntilRefresh - 1
    if force == true or callsUntilRefresh <= 0 then
      callsUntilRefresh = stride
      refreshDynamic()
    end
    return cached
  end
  function reader.invalidate()
    cached, cachedSource, validationRequested = nil, nil, nil
    callsUntilRefresh = 0
  end
  function reader.status()
    return {
      reads = stats.reads,
      dynamicRefreshes = stats.dynamicRefreshes,
      markerReads = stats.markerReads,
    }
  end
  return reader
end

return M
