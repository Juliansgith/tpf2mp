function data()
  local minorVersion = 22
  local peerValues = { "player1 (host)", "player2 (client)" }
  local peerIds = { "player1", "player2" }
  local sessionValues = { "local-dev", "match-1", "match-2", "sync-lab" }
  local epochLimits = { 0, 12, 24, 48 }
  local valuationTargets = { 0, 25000000, 50000000, 100000000 }
  local startingCashValues = { 5000000, 10000000, 20000000 }

  local function env(name, fallback)
    if os and os.getenv then
      local ok, value = pcall(os.getenv, name)
      if ok and value and value ~= "" then return value end
    end
    return fallback
  end

  local function envEnabled(name)
    local value = string.lower(tostring(env(name, "0")))
    return value == "1" or value == "true" or value == "yes" or value == "on"
  end

  local function launcherConfig(temp)
    local result = {}
    if not (io and io.open) then return result end
    local path = tostring(temp or ".") .. "/tpf2mp_launcher/active.ini"
    local file = io.open(path, "rb")
    if not file then return result end
    for line in file:lines() do
      local key, value = tostring(line):match("^([%w_]+)=(.*)$")
      if key and value then result[key] = value:gsub("\r$", "") end
    end
    file:close()
    if tonumber(result.schemaVersion) ~= 1 then return {} end
    local expires = tonumber(result.expiresAtUnix)
    if expires and os and os.time and expires < os.time() then return {} end
    if result.peerId ~= "player1" and result.peerId ~= "player2" then return {} end
    if not tostring(result.sessionId or ""):match("^[%w_.%-]+$") then return {} end
    if tostring(result.bridgeDir or "") == "" then return {} end
    result.startNetwork = tostring(result.startNetwork):lower() == "true"
    return result
  end

  return {
    version = 2,
    info = {
      minorVersion = minorVersion,
      severityAdd = "NONE",
      severityRemove = "CRITICAL",
      visible = true,
      name = _("TPF2MP_NAME"),
      description = _("TPF2MP_DESCRIPTION"),
      tags = { "Script Mod" },
      authors = {
        { name = "Sepgi", role = "CREATOR", text = "Concept and direction" },
        { name = "OpenAI Codex", role = "CO_CREATOR", text = "Prototype implementation" },
      },
      params = {
        { key = "peer", name = "Local peer", values = peerValues, defaultIndex = 0 },
        { key = "session", name = "Match session", values = sessionValues, defaultIndex = 0 },
        { key = "startupMode", name = "Startup mode", values = { "Standalone / hot-seat", "Network companion" }, defaultIndex = 0 },
        { key = "freeze", name = "Freeze autonomous development on match init", values = { "No", "Yes" }, defaultIndex = 0 },
        { key = "neutralizer", name = "Experimental native-income neutralizer", values = { "Off", "On" }, defaultIndex = 0 },
        { key = "proxyMode", name = "Standalone ownership mode", values = { "Native turn proxy (recommended)", "Legacy post-build attribution" }, defaultIndex = 0 },
        { key = "pauseOnSwitch", name = "Pause simulation on company switch", values = { "Yes", "No" }, defaultIndex = 0 },
        { key = "startingCash", name = "Company starting cash", values = { "5 million", "10 million", "20 million" }, defaultIndex = 0 },
        { key = "epochLimit", name = "Match length (settlement epochs)", values = { "Unlimited", "12", "24", "48" }, defaultIndex = 2 },
        { key = "valuationTarget", name = "Victory model value", values = { "Disabled", "$250k", "$500k", "$1m" }, defaultIndex = 2 },
        { key = "liveValidator", name = "Developer disposable-world validator", values = { "Off", "Run once" }, defaultIndex = 0 },
      },
    },
    runFn = function(settings, modParams)
      local selected = {}
      if modParams and getCurrentModId then selected = modParams[getCurrentModId()] or {} end
      local selectedPeer = peerIds[(tonumber(selected.peer) or 0) + 1] or peerIds[1]
      local selectedSession = sessionValues[(tonumber(selected.session) or 0) + 1] or sessionValues[1]
      local temp = env("TEMP", ".")
      local launched = launcherConfig(temp)
      game.config.tpf2mp = game.config.tpf2mp or {}
      local cfg = game.config.tpf2mp
      cfg.protocolVersion = 1
      cfg.minorVersion = minorVersion
      cfg.peerId = env("TPF2MP_PEER_ID", launched.peerId or selectedPeer)
      cfg.sessionId = env("TPF2MP_SESSION_ID", launched.sessionId or selectedSession)
      cfg.bridgeDir = env("TPF2MP_BRIDGE_DIR",
        launched.bridgeDir or (temp .. "/tpf2mp_bridge/" .. cfg.peerId))
      cfg.updateStride = 15
      -- Network commits are small ordered files and must be consumed much more
      -- frequently than the heavier housekeeping pass.  On Build 35924 an
      -- engine-script update arrives roughly five times per wall-clock second;
      -- sharing the old 15-tick stride added about three seconds at each of the
      -- commit, proposal-outcome, and checkpoint-outcome barriers.
      cfg.networkBridgeStride = math.max(1, math.floor(
        tonumber(env("TPF2MP_NETWORK_BRIDGE_STRIDE", "1")) or 1))
      cfg.maxEvents = 512
      cfg.startNetwork = envEnabled("TPF2MP_START_NETWORK") or launched.startNetwork == true
        or tonumber(selected.startupMode) == 1
      cfg.launcherManaged = launched.startNetwork == true
      cfg.autoFreeze = tonumber(selected.freeze) == 1
      cfg.journalNeutralizerEnabled = tonumber(selected.neutralizer) == 1
      cfg.localProxyEnabled = tonumber(selected.proxyMode) ~= 1
      cfg.pauseOnSwitch = tonumber(selected.pauseOnSwitch) ~= 1
      local selectedStartingCash = startingCashValues[(tonumber(selected.startingCash) or 0) + 1]
        or startingCashValues[1]
      cfg.startingCash = math.max(0, math.floor(
        tonumber(env("TPF2MP_STARTING_CASH", tostring(selectedStartingCash)))
          or selectedStartingCash))
      cfg.maxEpochs = epochLimits[(tonumber(selected.epochLimit) or 2) + 1] or epochLimits[3]
      cfg.valuationTargetCents = valuationTargets[(tonumber(selected.valuationTarget) or 2) + 1] or valuationTargets[3]
      local parameterValidation = tonumber(selected.liveValidator) == 1
      cfg.autoValidate = envEnabled("TPF2MP_AUTOVALIDATE") or parameterValidation
      cfg.networkAutoValidate = envEnabled("TPF2MP_NETWORK_AUTOTEST")
      cfg.networkSoakTicks = math.max(60, tonumber(env("TPF2MP_NETWORK_SOAK_TICKS", "300")) or 300)
      cfg.networkClockRunTicks = math.max(30,
        tonumber(env("TPF2MP_NETWORK_CLOCK_RUN_TICKS", "30")) or 30)
      cfg.operationalCapture = envEnabled("TPF2MP_OPERATIONAL_CAPTURE")
      cfg.operationalSampleTicks = math.max(30,
        tonumber(env("TPF2MP_OPERATIONAL_SAMPLE_TICKS", "120")) or 120)
      -- Steam launches the game from its already-running client, so process
      -- environment overrides do not reliably reach the game. This fixed,
      -- isolated route lets the temporary settings profile request validation.
      if parameterValidation and not envEnabled("TPF2MP_AUTOVALIDATE") then
        cfg.peerId = "player1"
        cfg.sessionId = "auto-live"
        cfg.bridgeDir = temp .. "/tpf2mp_bridge/auto-live/player1"
        cfg.startNetwork = false
      end
      if cfg.networkAutoValidate then
        cfg.startNetwork = true
        cfg.autoFreeze = true
        cfg.autoValidate = false
        cfg.localProxyEnabled = false
        cfg.pauseOnSwitch = false
      end
      if cfg.operationalCapture then
        cfg.startNetwork = false
        cfg.autoFreeze = true
        cfg.autoValidate = false
        cfg.networkAutoValidate = false
        cfg.localProxyEnabled = true
        cfg.pauseOnSwitch = false
      end
      -- A paused simulation can stop engine-script updates on some builds. The
      -- unattended validator therefore keeps the disposable test game moving.
      if cfg.autoValidate then cfg.pauseOnSwitch = false end
    end,
  }
end
