-- Loaded defensively: a mod whose entry point throws does not load at all,
-- and losing the whole multiplayer mod to a module path problem would be a
-- far worse failure than running the vanilla crowd. Absence therefore
-- degrades to the vanilla policy rather than a partial one.
local presentationOk, presentation = pcall(require, "tpf2_mp/presentation")
local industryFactsOk, industryFacts = pcall(require, "tpf2_mp/industry_resource_facts")

-- Resource loading is parallel and Build 35924 may invoke runFn more than once
-- in the same loader VM. Keep one loader-owned registry for those repeated
-- passes: replacing it on every call can erase recipes captured by an earlier
-- partition just before game.config is serialized for the engine script.
local activeIndustryResourceFacts = nil
local activeIndustryResourceFactsError = nil

local function isIndustryConstruction(fileName, construction)
  if type(construction) ~= "table" then return false end
  local constructionType = construction.type
  if constructionType == "INDUSTRY" or tostring(constructionType) == "INDUSTRY"
      or tonumber(constructionType) == 10 then return true end
  local portableName = tostring(fileName or ""):gsub("\\", "/"):lower()
  return portableName:match("^industry/") ~= nil
    or portableName:match("/industry/") ~= nil
end

function data()
  local minorVersion = 32
  local agentModeKeys = { "skeleton", "vanilla", "empty" }
  local economyDifficultyKeys = { "normal", "hard", "easy", "relaxed" }
  local peerValues = { "player1 (host)", "player2 (client)" }
  local peerIds = { "player1", "player2" }
  local sessionValues = { "local-dev", "match-1", "match-2", "sync-lab" }
  local epochLimits = { 0, 144, 288, 576 }
  local valuationTargets = { 0, 25000000000, 50000000000, 100000000000 }
  local startingCashValues = { 25000000, 50000000, 100000000 }

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
    if result.townDevelopment ~= nil then
      result.townDevelopment = tostring(result.townDevelopment):lower() == "true"
    end
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
        { key = "startingCash", name = "Company starting cash", values = { "25 million", "50 million", "100 million" }, defaultIndex = 1 },
        { key = "economyDifficulty", name = "TPF2MP economy difficulty",
          values = { "Normal (100% revenue)", "Hard (60% revenue)",
            "Easy (150% revenue)", "Relaxed (200% revenue)" },
          defaultIndex = 0 },
        { key = "epochLimit", name = "Match length (financial hours)", values = { "Unlimited", "12 hours", "24 hours", "48 hours" }, defaultIndex = 2 },
        { key = "valuationTarget", name = "Victory model value", values = { "Disabled", "$250m", "$500m", "$1b" }, defaultIndex = 2 },
        { key = "townDevelopment", name = "Physical town growth (experimental)",
          values = { "Off (capacities only)", "On (ordered native development)" },
          defaultIndex = 0 },
        { key = "bankruptcy", name = "Bankruptcy elimination",
          values = { "On (3-hour grace)", "Off (build together)", "Harsh (1-hour grace)" },
          defaultIndex = 0 },
        { key = "credit", name = "Competitive credit",
          values = { "Standard", "Tight", "Generous" }, defaultIndex = 0 },
        { key = "agentMode", name = "Native crowd simulation",
          values = {
            "Skeleton crew (recommended)",
            "Full vanilla population",
            "Minimum safe crowd (fastest)",
          }, defaultIndex = 0 },
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
      local selectedStartingCash = startingCashValues[(tonumber(selected.startingCash) or 1) + 1]
        or startingCashValues[2]
      cfg.startingCash = math.max(0, math.floor(
        tonumber(env("TPF2MP_STARTING_CASH", tostring(selectedStartingCash)))
          or selectedStartingCash))
      local selectedDifficulty = tostring(env("TPF2MP_ECONOMY_DIFFICULTY",
        launched.economyDifficulty
          or economyDifficultyKeys[(tonumber(selected.economyDifficulty) or 0) + 1]
          or "normal")):lower()
      local validDifficulties = { normal = true, hard = true, easy = true, relaxed = true }
      cfg.economyDifficulty = validDifficulties[selectedDifficulty]
        and selectedDifficulty or "normal"
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

      -- Loss conditions are a match setting. "Off" keeps credit and interest
      -- meaningful but never eliminates anyone, which is the build-together
      -- session people ask for.
      local townDevelopmentEnvironment = env("TPF2MP_TOWN_DEVELOPMENT", nil)
      if townDevelopmentEnvironment ~= nil then
        cfg.townDevelopment = tostring(townDevelopmentEnvironment):lower() == "1"
          or tostring(townDevelopmentEnvironment):lower() == "true"
      elseif launched.townDevelopment ~= nil then
        cfg.townDevelopment = launched.townDevelopment == true
      else
        cfg.townDevelopment = tonumber(selected.townDevelopment) == 1
      end
      local bankruptcyChoice = tonumber(selected.bankruptcy) or 0
      cfg.bankruptcyEnabled = bankruptcyChoice ~= 1
      cfg.insolventSettlements = bankruptcyChoice == 2 and 1 or 3
      local creditChoice = tonumber(selected.credit) or 0
      local creditProfiles = {
        [0] = { base = 500000000, multiple = 4, interest = 15 },
        [1] = { base = 150000000, multiple = 2, interest = 30 },
        [2] = { base = 1500000000, multiple = 8, interest = 8 },
      }
      local creditProfile = creditProfiles[creditChoice] or creditProfiles[0]
      cfg.creditBaseLimitCents = creditProfile.base
      cfg.creditRevenueMultiple = creditProfile.multiple
      cfg.creditInterestPermille = creditProfile.interest

      -- Agent presentation policy. The competitive model owns demand and
      -- score; native crowds are decoration whose cost the player chooses.
      -- This is match content: it changes town-building data, so the policy
      -- fingerprint travels with the pinned mod set and both peers must
      -- agree before a session starts.
      local policy
      if not presentationOk then
        cfg.agentMode = "vanilla"
        cfg.agentPolicyFingerprint = ""
        cfg.agentPolicyError = tostring(presentation)
      else
        local agentModeKey = env("TPF2MP_AGENT_MODE",
          launched.agentMode
            or agentModeKeys[(tonumber(selected.agentMode) or 0) + 1]
            or presentation.DEFAULT_MODE)
        policy = presentation.mode(agentModeKey)
        cfg.agentMode = policy.label
        cfg.agentPolicyFingerprint = presentation.fingerprint(policy)
      end

      -- The resource loader is the only supported surface that still sees a
      -- static construction's actual updateFn. Capture the evaluated rule and
      -- stock list there, then expose only normalized data through game.config
      -- to the engine script. Dynamic callbacks whose recipe depends on seed,
      -- year or opaque state become ambiguous and fail closed.
      if industryFactsOk then
        -- The loader may invoke runFn repeatedly in one VM. Reuse the same
        -- partial registry so later calls cannot erase facts captured by an
        -- earlier parallel resource pass.
        activeIndustryResourceFacts = activeIndustryResourceFacts
          or industryFacts.newRegistry()
        -- Parallel loader VMs exchange only serialized game.config values.
        -- Fold any partition published by an earlier runFn invocation into
        -- this VM's accumulator before publishing our copy back.
        local merged = industryFacts.merge(
          activeIndustryResourceFacts, cfg.industryResourceFacts)
        if merged then activeIndustryResourceFacts = merged end
        activeIndustryResourceFactsError = nil
        cfg.industryResourceFacts = activeIndustryResourceFacts
        cfg.industryResourceFactsError = nil
      else
        activeIndustryResourceFacts = nil
        activeIndustryResourceFactsError = tostring(industryFacts)
        cfg.industryResourceFacts = nil
        cfg.industryResourceFactsError = activeIndustryResourceFactsError
      end

      -- Load speed is per-vehicle data, so pinning it makes dwell independent
      -- of how many agents board. The model's fixed per-stop dwell then
      -- describes the world exactly instead of approximating it.
      if policy and policy.pinLoadSpeed then
        addModifier("loadModel", function(_, data)
          local transport = data and data.metadata and data.metadata.transportVehicle or nil
          if transport and transport.loadSpeed ~= nil then
            transport.loadSpeed = presentation.PINNED_LOAD_SPEED
          end
          return data
        end)
      end

      -- Town buildings carry personCapacity, and sims exist because of it.
      -- Scaling it here is the same supported surface the ecosystem uses;
      -- buildings created from this point carry the scaled value.
      local scaleTownBuildings = policy
        and (policy.capacityDenominator > 1 or policy.capacityNumerator ~= 1)
      local loaderIndustryResourceFacts = activeIndustryResourceFacts
      local function publishIndustryResource(fileName, registry)
        if not (industryFactsOk and registry) then return end
        local ok, result = industryFacts.writeResourceArtifact(
          registry, fileName, cfg.bridgeDir)
        local diagnostics = registry.diagnostics
        diagnostics.artifactWrites = diagnostics.artifactWrites or {}
        diagnostics.artifactErrors = diagnostics.artifactErrors or {}
        local canonicalName = industryFacts.canonicalResourceName(fileName)
        local firstAttempt = diagnostics.artifactWrites[canonicalName] == nil
          and diagnostics.artifactErrors[canonicalName] == nil
        if ok then
          diagnostics.artifactWrites[canonicalName] = tostring(result)
          diagnostics.artifactErrors[canonicalName] = nil
        else
          diagnostics.artifactErrors[canonicalName] = tostring(result)
          if firstAttempt then
            print("[TPF2MP-INDUSTRY] could not write " .. canonicalName
              .. ": " .. tostring(result) .. " bridge=" .. tostring(cfg.bridgeDir))
          end
        end
      end
      if scaleTownBuildings or industryFactsOk then
        addModifier("loadConstruction", function(fileName, data)
          if industryFactsOk and loaderIndustryResourceFacts then
            local diagnostics = loaderIndustryResourceFacts.diagnostics
            diagnostics.loadConstructionCount =
              (tonumber(diagnostics.loadConstructionCount) or 0) + 1
            diagnostics.typeCounts = diagnostics.typeCounts or {}
            local typeKey = tostring(data and data.type or "<nil>")
            diagnostics.typeCounts[typeKey] = (tonumber(diagnostics.typeCounts[typeKey]) or 0) + 1
          end
          if industryFactsOk and isIndustryConstruction(fileName, data) then
            local _, wrapped = industryFacts.wrap(
              loaderIndustryResourceFacts, fileName, data, publishIndustryResource)
            if wrapped then
              local diagnostics = loaderIndustryResourceFacts.diagnostics
              diagnostics.industryConstructionCount =
                (tonumber(diagnostics.industryConstructionCount) or 0) + 1
              industryFacts.captureStandardVariants(
                loaderIndustryResourceFacts, fileName, data)
              publishIndustryResource(fileName, loaderIndustryResourceFacts)
            end
          end
          if scaleTownBuildings and data and data.type == "TOWN_BUILDING"
              and type(data.updateFn) == "function" then
            local inner = data.updateFn
            data.updateFn = function(params)
              local result = inner(params)
              if result and result.personCapacity and result.personCapacity.capacity then
                result.personCapacity.capacity = presentation.scaledCapacity(
                  result.personCapacity.capacity, policy)
              end
              return result
            end
          end
          return data
        end)
      end

      -- Shipped decouplers: cargo weight is what makes load affect physics,
      -- and destination recomputation is the dominant per-agent cost.
      if policy then
        game.config.simulateCargoWeight = policy.simulateCargoWeight
        game.config.simPersonDestinationRecomputationProbability =
          policy.destinationRecomputationPermille / 1000
      end
    end,
  }
end
