local project = assert(arg[1], "project root argument required"):gsub("\\", "/")
package.path = project .. "/tpf2_mp_1/res/scripts/?.lua;" .. package.path

local runtimeConfig = require "tpf2_mp/runtime_config"
local stateSchema = require "tpf2_mp/state_schema"
local nativeHook = require "tpf2_mp/native_hook"
local guiState = require "tpf2_mp/gui_state"
local guiView = require "tpf2_mp/gui_view"
local guiEntryPointsModule = require "tpf2_mp/gui_entry_points"
local guiCaptureModule = require "tpf2_mp/gui_capture"
local guiNetworkBootstrapModule = require "tpf2_mp/gui_network_bootstrap"
local guiLoadRuntimeModule = require "tpf2_mp/gui_load_runtime"
local proposalCodec = require "tpf2_mp/proposal_codec"
local proposalRuntimeModule = require "tpf2_mp/proposal_runtime"
local networkIntentRuntimeModule = require "tpf2_mp/network_intent_runtime"
local networkClockRuntimeModule = require "tpf2_mp/network_clock_runtime"
local authoredFollowupRuntimeModule = require "tpf2_mp/authored_followup_runtime"
local networkSpeedIndicatorModule = require "tpf2_mp/network_speed_indicator"
local vehicleSyncRuntimeModule = require "tpf2_mp/vehicle_sync_runtime"
local vehicleSyncStateModule = require "tpf2_mp/vehicle_sync_state"
local validationRuntimeModule = require "tpf2_mp/validation_runtime"
local townDevelopmentValidationModule = require "tpf2_mp/validation_town_development"
local checkpointRuntimeModule = require "tpf2_mp/checkpoint_runtime"
local recoveryPrepareRuntimeModule = require "tpf2_mp/recovery_prepare_runtime"
local operationRuntimeModule = require "tpf2_mp/operation_runtime"
local operationVehiclePostcondition = require "tpf2_mp/operation_vehicle_postcondition"
local publicSnapshotModule = require "tpf2_mp/public_snapshot"
local researchReportModule = require "tpf2_mp/research_report"
local economyModule = require "tpf2_mp/economy"
local economyClockRuntimeModule = require "tpf2_mp/economy_clock_runtime"
local economyAssetCostRuntimeModule = require "tpf2_mp/economy_asset_cost_runtime"
local economyPublicViewModule = require "tpf2_mp/economy_public_view"
local financeModule = require "tpf2_mp/finance"
local bridgeModule = require "tpf2_mp/bridge"
local cargoPresentationModule = require "tpf2_mp/cargo_presentation"
local freightIndustryModelModule = require "tpf2_mp/freight_industry_model"
local freightMilestoneRuntimeModule = require "tpf2_mp/freight_milestone_runtime"
local passengerMilestoneRuntimeModule = require "tpf2_mp/passenger_milestone_runtime"
local hashModule = require "tpf2_mp/hash"
local util = require "tpf2_mp/util"

do
  local gui = { frames = 0, status = {} }
  local current, engineThread = nil, false
  local migrated, reset, projected, rendered = 0, 0, 0, 0
  local function saved(errorValue)
    return {
      version = 26, initialized = true, networkMode = "network",
      bridge = { sessionId = "load-test" }, lastError = errorValue,
    }
  end
  local runtime = guiLoadRuntimeModule.new({
    gui = gui, stateVersion = 26,
    migrate = function(value) migrated = migrated + 1; value.version = 26; return value end,
    getState = function() return current end,
    setState = function(value) current = value end,
    isEngineThread = function() return engineThread end,
    resetTransientRuntime = function() reset = reset + 1 end,
    config = function() return { networkAutoValidate = false } end,
    activeCompany = function() return "company:1", {} end,
    publicSnapshot = function()
      projected = projected + 1
      return {
        initialized = current.initialized == true,
        activeCompanyCid = "company:1", networkMode = current.networkMode,
        sessionId = current.bridge.sessionId, lastError = current.lastError,
      }
    end,
    renderGui = function() rendered = rendered + 1 end,
  })
  local first = saved(nil)
  runtime.load(first)
  assert(current == first and migrated == 0 and projected == 1 and rendered == 1,
    "current GUI state was remigrated or its first snapshot was not projected")
  gui.frames = 29
  runtime.load(first)
  assert(projected == 1, "GUI snapshot cadence projected before thirty frames")
  gui.frames = 30
  runtime.load(first)
  assert(projected == 2, "GUI snapshot cadence did not refresh at thirty frames")
  local errored = saved("new error")
  runtime.load(errored)
  assert(projected == 3, "priority GUI state change waited for the ordinary cadence")
  engineThread = true
  runtime.load(saved(nil))
  assert(migrated == 1 and reset == 1,
    "engine load bypassed migration or transient-runtime reset")
end

do
  local config = {
    vehicles = {
      { model = "vehicle/train/example.mdl", reversed = false, loadConfig = { 0 },
        color = { r = 1000, g = 1000, b = 1000 }, logo = "" },
      { model = "vehicle/waggon/example.mdl", reversed = true, loadConfig = { 1, 0 },
        color = { r = 1000, g = 1000, b = 1000 }, logo = "" },
    },
    vehicleGroups = { 2 },
  }
  local observed = {
    exists = true, vehicleParts = 2, vehicleConfigKnown = true,
    vehicleConfig = { vehicles = {
      { model = "vehicle/train/example.mdl", reversed = false, loadConfig = { 0 } },
      { model = "vehicle/waggon/example.mdl", reversed = true, loadConfig = { 1, 0 } },
    } },
  }
  local projected = operationVehiclePostcondition.project({
    transportVehicleConfig = { vehicles = {
      { part = { modelId = 10, reversed = false, loadConfig = { 0 } },
        targetMaintenanceState = 0.75 },
      { part = { modelId = 11, reversed = true, loadConfig = { 1, 0 } },
        targetMaintenanceState = 0.75 },
    } },
  }, { res = { modelRep = { getName = function(id)
    return id == 10 and "vehicle/train/example.mdl" or "vehicle/waggon/example.mdl"
  end } } })
  assert(projected.vehicleConfigKnown == true
      and projected.targetMaintenanceKnown == true
      and projected.vehicleParts == 2
      and projected.vehicleConfig.vehicles[2].reversed == true
      and projected.targetMaintenanceBasisPoints[1] == 7500
      and projected.targetMaintenanceBasisPoints[2] == 7500,
    "native vehicle wrappers did not project into bounded portable postconditions")
  assert(operationVehiclePostcondition.validate({
      kind = "vehicle.buy", data = { config = config },
    }, observed) == true,
    "an exact native purchased consist failed its ordered postcondition")
  local wrongConsist = util.deepCopy(observed)
  wrongConsist.vehicleConfig.vehicles[2].model = "vehicle/waggon/wrong.mdl"
  local accepted, configError = operationVehiclePostcondition.validate({
    kind = "vehicle.replace", data = { config = config },
  }, wrongConsist)
  assert(accepted == false
      and configError == "native vehicle config does not match the ordered transaction",
    "a wrong replacement consist passed physical validation")
  assert(operationVehiclePostcondition.validate({
      kind = "vehicle.stop", data = { stopped = true },
    }, { userStopped = true }) == true,
    "the ordered native stop state was rejected")
  assert(operationVehiclePostcondition.validate({
      kind = "vehicle.stop", data = { stopped = true },
    }, { userStopped = false }) == false,
    "an unchanged native stop state passed physical validation")
  assert(operationVehiclePostcondition.validate({
      kind = "vehicle.maintenance", data = { valueBasisPoints = 7500 },
    }, {
      vehicleParts = 2, targetMaintenanceKnown = true,
      targetMaintenanceBasisPoints = { 7500, 7500 },
    }) == true,
    "exact per-part native maintenance targets were rejected")
  assert(operationVehiclePostcondition.validate({
      kind = "vehicle.maintenance", data = { valueBasisPoints = 7500 },
    }, {
      vehicleParts = 2, targetMaintenanceKnown = true,
      targetMaintenanceBasisPoints = { 7500, 7499 },
    }) == false,
    "a partially applied native maintenance target passed physical validation")
  assert(operationVehiclePostcondition.validate({
      kind = "vehicle.assign", data = { lineCid = "line:test:1" },
    }, { lineCid = "line:test:1" }) == true
      and operationVehiclePostcondition.validate({
        kind = "vehicle.assign", data = { lineCid = "line:test:1" },
      }, { lineCid = "line:test:2" }) == false,
    "native line assignment was not tied to its ordered target")
  assert(operationVehiclePostcondition.validate({
      kind = "vehicle.send_to_depot", data = { sellOnArrival = true },
    }, { sellOnArrival = true }) == true
      and operationVehiclePostcondition.validate({
        kind = "vehicle.send_to_depot", data = { sellOnArrival = true },
      }, { sellOnArrival = false }) == false,
    "native sell-on-arrival state was not tied to its ordered target")
end

do
  local previousApi = rawget(_G, "api")
  local registry, hudItems, pauseItems = {}, {}, {}
  local function layout(items)
    return { addItem = function(_, value) items[#items + 1] = value end }
  end
  registry["gameInfo.layout"] = layout(hudItems)
  local pauseLayout = layout(pauseItems)
  registry["ingameMenu.quitButton"] = {
    getParent = function()
      return { getLayout = function() return pauseLayout end }
    end,
  }
  api = { gui = {
    util = { getById = function(id) return registry[id] end },
    comp = {
      TextView = { new = function(value) return { text = value } end },
      Button = { new = function(label)
        local button = { label = label }
        function button:setId(id) self.id = id; registry[id] = self end
        function button:onClick(callback) self.callback = callback end
        return button
      end },
    },
  } }
  local state, opened = {}, 0
  assert(guiEntryPointsModule.install(state, function() opened = opened + 1 end) == true
      and state.entryPointsInstalled == true
      and #hudItems == 1 and hudItems[1].id == "tpf2mp.hudEntry"
      and #pauseItems == 1 and pauseItems[1].id == "tpf2mp.pauseEntry",
    "multiplayer entry points did not bind the stock HUD layout and pause-button parent")
  hudItems[1].callback()
  assert(opened == 1, "multiplayer HUD entry did not reopen its window")
  assert(guiEntryPointsModule.install(state, function() end) == true
      and #hudItems == 1 and #pauseItems == 1,
    "multiplayer entry-point installation was not idempotent")
  api = previousApi
end

do
  local observerCalls, marked, gameCalls, calendarCalls = 0, nil, 0, 0
  local authorityReady = false
  local bootstrap = guiNetworkBootstrapModule.new({
    installObserver = function() observerCalls = observerCalls + 1 end,
    markNativeContext = function(value) marked = value end,
    configureAuthority = function()
      if authorityReady then return true end
      return false, "authority-not-ready"
    end,
    freezeGame = function() gameCalls = gameCalls + 1; return true end,
    freezeCalendar = function() calendarCalls = calendarCalls + 1; return true end,
  })
  local waiting = bootstrap()
  assert(waiting.authorityReady == false and waiting.gameReady == false
      and waiting.calendarReady == false and waiting.error == "authority-not-ready"
      and gameCalls == 0 and calendarCalls == 0,
    "GUI network bootstrap mutated native clocks before authority was ready")
  authorityReady = true
  local ready = bootstrap()
  assert(ready.authorityReady == true and ready.gameReady == true
      and ready.calendarReady == true and ready.error == nil
      and observerCalls == 2 and marked == "gui" and gameCalls == 1 and calendarCalls == 1,
    "GUI network bootstrap did not prove both post-load clock controls")
end

local function baseConfig(overrides)
  local result = {
    protocol = 1,
    root = ".",
    peerId = "player1",
    sessionId = "runtime-module-test",
    startNetwork = true,
    pauseOnSwitch = false,
    autoValidate = false,
    networkAutoValidate = false,
    operationalCapture = false,
    operationalSampleTicks = 120,
    startingCash = 5000000,
    economyDifficulty = "normal",
    maxEpochs = 24,
    valuationTargetCents = 50000000,
    neutralizer = false,
  }
  for key, value in pairs(overrides or {}) do result[key] = value end
  return result
end

do
  local current = {
    networkMode = "network", initialized = true,
    world = { networkClock = { effectiveSpeed = 4 } },
  }
  local buttons, emitted, wakeups = {}, {}, 0
  for index = 0, 3 do
    local button = { selected = index == 0 or index == 3 }
    function button:isSelected() return self.selected end
    function button:setSelected(value, emit)
      self.selected = value == true
      emitted[#emitted + 1] = emit
    end
    buttons["menu.speedButton" .. index] = button
  end
  local indicator = networkSpeedIndicatorModule.new({
    getState = function() return current end,
    getById = function(id) return buttons[id] end,
    wakeClock = function() wakeups = wakeups + 1 end,
    wallTime = function() return 100 end,
  })
  assert(indicator.project() == true
      and buttons["menu.speedButton0"].selected == false
      and buttons["menu.speedButton3"].selected == true,
    "authoritative running speed did not repair a dual-selected stock clock")
  assert(emitted[1] == false and wakeups == 1,
    "clock-indicator repair emitted a synthetic player click")
  buttons["menu.speedButton0"].selected = true
  indicator.project()
  assert(wakeups == 1,
    "persistent modal pause flooded the paused snapshot wake path")
  current.world.networkClock.effectiveSpeed = 0
  buttons["menu.speedButton0"].selected = false
  buttons["menu.speedButton3"].selected = false
  assert(indicator.project() == true
      and buttons["menu.speedButton0"].selected == true
      and buttons["menu.speedButton3"].selected == false,
    "authoritative pause did not repair a blank stock clock selection")
  current.world.networkClock.effectiveSpeed = 3
  assert(indicator.project() == true
      and buttons["menu.speedButton3"].selected == true,
    "adaptive native speed 3 was not projected onto the fastest stock button")
  current.networkMode = "standalone"
  buttons["menu.speedButton0"].selected = true
  assert(indicator.project() == false
      and buttons["menu.speedButton0"].selected == true,
    "network clock projection mutated a standalone speed bar")
end

do
  local current = stateSchema.new(baseConfig(), {
    stateVersion = 24,
    checkpointVersion = 4,
  })
  current.initialized = true
  current.companyOrder = { "company:1", "company:2" }
  current.companies = {
    ["company:1"] = { cid = "company:1", name = "Company 1", playerId = 25 },
    ["company:2"] = { cid = "company:2", name = "Company 2", playerId = 26 },
  }
  financeModule.initialiseNetworkAccounts(
    current.finance, current.companyOrder, 50000000, { reason = "test" })
  current.probes.freightMilestone = {
    aboardCheckpointed = true, lineCid = "line:event:cargo",
    vehicleCid = "vehicle:event:cargo", observedRound = 2, aboard = 7,
  }
  current.probes.passengerMilestone = { stale = true, aboardCheckpointed = false }
  local nativeReads = 0
  local snapshot = publicSnapshotModule.new({
    getState = function() return current end,
    activeCompany = function() return "company:1", current.companies["company:1"] end,
    refreshOwnershipProbe = function()
      return { companies = {}, pinned = { companies = {} }, unassigned = { total = 0 } }
    end,
    balanceOf = function()
      nativeReads = nativeReads + 1
      error("GUI load must not inspect a newly-created native PLAYER")
    end,
    accountOf = function()
      nativeReads = nativeReads + 1
      error("GUI load must not inspect a newly-created native PLAYER")
    end,
    coreDigest = function() return "core" end,
    authoredDigest = function() return "model" end,
    deferredNetworkIntents = function() return {} end,
    networkIntentAwaitingOrder = function() return nil end,
    maxDeferredNetworkIntents = 32,
  })({ allowNativeAccounts = false })
  assert(nativeReads == 0,
    "GUI-safe public snapshot touched the native PLAYER entity view")
  assert(snapshot.companies["company:1"].balance == 50000000
      and snapshot.companies["company:2"].balance == 50000000,
    "GUI-safe public snapshot did not use canonical network accounts")
  assert(snapshot.companies["company:1"].nativeBalance == nil,
    "GUI-safe public snapshot published an unavailable native balance")
  assert(type(snapshot.economyPresentation) == "table"
      and snapshot.economyPresentation.activeCompanyCid == "company:1",
    "public snapshot omitted the authoritative economy presentation view")
  assert(snapshot.probes.freightMilestone.aboard == 7
      and snapshot.probes.passengerMilestone.stale == true,
    "public snapshot omitted automatic aboard-receipt progress")
end

do
  local current = stateSchema.new(baseConfig(), {
    stateVersion = 29,
    checkpointVersion = 5,
  })
  current.tick = 73
  current.networkMode = "network"
  current.bridge.sessionId = "research-report-test"
  current.bridge.peerId = "player2"
  current.companyOrder = { "company:1" }
  current.companies = {
    ["company:1"] = { cid = "company:1", playerId = 25, name = "Company 1" },
  }
  current.world.controlPlayerId = 99
  current.world.proposals.queued = 2
  current.world.operations.applied = 3
  current.probes.capture = { observed = 4 }
  current.probes.freightMilestone = {
    aboardCheckpointed = true, lineCid = "line:event:freight",
    vehicleCid = "vehicle:event:freight", observedRound = 2, aboard = 11,
  }
  current.probes.passengerMilestone = { stale = true }
  local emitted, fail = nil, false
  local runtime = researchReportModule.new({
    getState = function() return current end,
    nativeHookStatus = function() return { loaded = true, active = true } end,
    authoredDigest = function() return "model-digest" end,
    coreDigest = function() return "core-digest" end,
    publicSnapshot = function()
      return { economyPresentation = { activeCompanyCid = "company:1" } }
    end,
    accountOf = function(playerId)
      return { balance = playerId * 100, loan = playerId }
    end,
    researchSnapshot = function(worldState, registry, companies)
      assert(worldState == current.world and registry == current.canonical
          and companies == current.companies,
        "research report did not receive the active state domains")
      return { schemaVersion = 1, structural = { digest = "structure-digest" } }
    end,
    emit = function(report, tick)
      emitted = { report = report, tick = tick }
      if fail then return false, "test bridge unavailable" end
      return true, { local_seq = 91 }
    end,
  })
  local built = runtime.build()
  assert(built.tick == 73 and built.sessionId == "research-report-test"
      and built.peerId == "player2" and built.modelDigest == "model-digest"
      and built.coreDigest == "core-digest",
    "research report lost its ordered identity or digest fields")
  assert(built.proposals.queued == 2 and built.operations.applied == 3
      and built.operations.schemaVersion ~= nil,
    "research report lost proposal/operation diagnostics")
  assert(built.freightMilestone.aboard == 11
      and built.passengerMilestone.stale == true,
    "research report lost automatic load-receipt diagnostics")
  assert(built.accounts.control.balance == 9900
      and built.accounts.companies["company:1"].balance == 2500,
    "research report lost native account diagnostics")
  assert(type(built.knownLimits) == "table"
      and table.concat(built.knownLimits, "\n"):find("Format%-5 checkpoints"),
    "research report retained stale checkpoint-limit documentation")

  local ok, result = runtime.export()
  assert(ok == true and result.localSeq == 91 and result.error == nil
      and result.structuralDigest == "structure-digest"
      and emitted.tick == 73 and emitted.report.coreDigest == "core-digest",
    string.format(
      "research report export did not retain bridge receipt metadata: ok=%s seq=%s error=%s structure=%s tick=%s core=%s",
      tostring(ok), tostring(result and result.localSeq),
      tostring(result and result.error), tostring(result and result.structuralDigest),
      tostring(emitted and emitted.tick),
      tostring(emitted and emitted.report and emitted.report.coreDigest)))
  emitted.report.capture.observed = 99
  assert(current.probes.capture.observed == 4,
    "research report leaked mutable diagnostic state")
  fail = true
  ok, result = runtime.export()
  assert(ok == false and result.localSeq == nil
      and result.error == "test bridge unavailable",
    "research report did not surface a bridge export failure")
end

do
  local view = economyPublicViewModule.build({
    economy = {
      params = { economyDifficulty = "easy" },
      markets = { ["market:test"] = { demand = 640, metadata = {
        townA = "town:test:a", townB = "town:test:b",
        townSizeA = 400, townSizeB = 480,
      } } },
      towns = {
        ["town:test:a"] = { size = 420 },
        ["town:test:b"] = { size = 500 },
      },
      services = {
        ["line:event:economy:1"] = {
          lineCid = "line:event:economy:1", marketCid = "market:test",
          companyCid = "company:1", name = "Fast Link", fareCents = 1200,
          journeySeconds = 900, headwaySeconds = 600, capacity = 80,
          metadata = { topSpeedKmh = 160, cruiseSpeedKmh = 112,
            vehicleCount = 1, departuresPerHourPerDirection = 6 },
        },
      },
      vehicleCosts = {
        ["vehicle:event:economy:1"] = {
          companyCid = "company:1", annualVehicleUpkeepCents = 120000000,
        },
      },
      lastResults = {
        intervalSeconds = 300,
        companies = { ["company:1"] = { grossRevenueCents = 240000,
          vehicleUpkeepCents = 13699, infrastructureUpkeepCents = 500,
          netRevenueCents = 225801 } },
        markets = { ["market:test"] = {
          gcOutsideCents = 2500,
          services = { ["line:event:economy:1"] = {
            allocated = 200, grossRevenueCents = 240000,
            vehicleUpkeepCents = 13699, netRevenueCents = 226301,
            factors = { fareCents = 1200, timeCostCents = 112,
              waitCostCents = 75, gcCents = 1387 },
          } },
        } },
      },
    },
    canonical = { byCanonical = {
      ["line:event:economy:1"] = {
        kind = "line", localId = 70, metadata = {},
      },
      ["vehicle:event:economy:1"] = {
        kind = "vehicle", localId = 71, metadata = {
          owner = "company:1", lineCid = "line:event:economy:1",
          purchasePriceDollars = 7200000,
          vehicleCostSource = "consensus-native-maintenance",
        },
      },
    } },
  }, "company:1")
  assert(view.localLines["70"] == "line:event:economy:1"
      and view.localVehicles["71"] == "vehicle:event:economy:1"
      and view.vehicles["vehicle:event:economy:1"].projectedHourlyVehicleUpkeepCents == 40000000
      and view.vehicles["vehicle:event:economy:1"].intervalVehicleUpkeepCents == 3333333
      and view.services["line:event:economy:1"].fareAtOutsideParityCents == 2313
      and view.services["line:event:economy:1"].hourlyMarketDemand == 640
      and view.services["line:event:economy:1"].modelTownSizeA == 420
      and view.economyDifficulty == "easy",
    "economy presentation did not project exact selected-line/vehicle figures")
end

do
  local view = economyPublicViewModule.build({
    economy = {
      params = { economyDifficulty = "normal" },
      markets = { ["market:cargo"] = { kind = "cargo", demand = 120 } },
      services = { ["line:cargo"] = {
        lineCid = "line:cargo", marketCid = "market:cargo",
        companyCid = "company:1", name = "Grain Shuttle",
        fareCents = 1000, journeySeconds = 600, headwaySeconds = 900,
        capacity = 80, metadata = {},
      } },
      deliveryCursors = { ["line:cargo"] = {
        deliveredCargo = 5, earnedRevenueCents = 500,
      } },
      lastResults = { intervalSeconds = 300, companies = {}, markets = {} },
    },
    world = {
      passengerPresentation = { lines = {} },
      cargoPresentation = { lines = { ["line:cargo"] = {
        deliveredTotal = 8, earnedRevenueCents = 800,
      } } },
    },
    canonical = { byCanonical = {} },
  }, "company:1")
  local cargo = view.services["line:cargo"]
  assert(cargo.kind == "cargo" and cargo.pendingDelivered == 3
      and cargo.pendingRawGrossRevenueCents == 300
      and view.companies["company:1"].pendingGrossRevenueCents == 300,
    "economy presentation omitted unsettled completed cargo deliveries")
end

do
  local firstStop = {
    stationGroupCid = "station_group:test:1", station = 0, terminal = 0,
    alternativeTerminals = { { station = 0, terminal = 1 }, { station = 0, terminal = 2 } },
  }
  local secondStop = {
    stationGroupCid = "station_group:test:2", station = 0, terminal = 0,
    alternativeTerminals = {},
  }
  local transaction = {
    kind = "line.update",
    data = { line = { stops = { util.deepCopy(firstStop) } } },
  }
  local exact = {
    kind = "line.update", targetCid = "line:test", exists = true,
    stops = { util.deepCopy(firstStop) },
  }
  local canonical, canonicalError = operationRuntimeModule.reconcileLinePostcondition(
    transaction, "line:test", exact, false)
  assert(canonical and canonicalError == nil and #canonical.stops == 1,
    "exact replay line state did not satisfy the canonical postcondition")

  local advanced = util.deepCopy(exact)
  advanced.stops[2] = util.deepCopy(secondStop)
  local rejected, replayError = operationRuntimeModule.reconcileLinePostcondition(
    transaction, "line:test", advanced, false)
  assert(rejected == nil
      and replayError == "native line postcondition does not match the ordered transaction",
    "a replay peer accepted a line state beyond the ordered intermediate state")

  local wrongAlternatives = util.deepCopy(exact)
  wrongAlternatives.stops[1].alternativeTerminals = { { station = 0, terminal = 2 } }
  assert(operationRuntimeModule.reconcileLinePostcondition(
      transaction, "line:test", wrongAlternatives, false) == nil,
    "a replay peer accepted divergent alternative terminal selections")

  local optimistic, optimisticError = operationRuntimeModule.reconcileLinePostcondition(
    transaction, "line:test", advanced, true)
  assert(optimistic and optimisticError == nil and #optimistic.stops == 1
      and optimistic.stops[1].stationGroupCid == firstStop.stationGroupCid,
    "an optimistic origin could not certify its captured intermediate line state")
  assert(#advanced.stops == 2,
    "line postcondition reconciliation mutated the observed physical state")

  local binding = { metadata = {
    owner = "company:1", lineCid = "line:test",
    models = { { model = "vehicle/train/old.mdl" } },
  } }
  local replacementParts = {
    { model = "vehicle/bus/new.mdl", reversed = false, loadConfig = { 0 },
      color = { r = 1000, g = 1000, b = 1000 }, logo = "" },
  }
  operationRuntimeModule.applyBindingMetadata(binding, {
    kind = "vehicle.replace", digest = "replacement-digest",
    data = { config = { vehicles = replacementParts, vehicleGroups = { 1 } } },
  }, "company:1")
  assert(binding.metadata.models[1].model == "vehicle/bus/new.mdl"
      and binding.metadata.lastOperationDigest == "replacement-digest"
      and binding.metadata.lineCid == "line:test",
    "vehicle replacement retained stale canonical consist metadata")
  replacementParts[1].model = "vehicle/bus/mutated-after-apply.mdl"
  assert(binding.metadata.models[1].model == "vehicle/bus/new.mdl",
    "replacement metadata retained a mutable transaction reference")
end

do
  local current = {
    canonical = {
      byCanonical = {
        ["edge:test"] = { localId = 10, metadata = { owner = "company:1" } },
      },
    },
    world = {
      logicalOwners = {},
      pinnedCustody = {},
    },
  }
  local function proposalRuntime()
    local engineSteps = current.engineSteps
    return proposalRuntimeModule.new({
      getState = function() return current end,
      requireRunningMatch = function() return true end,
      balanceOf = function() return 0 end,
      coreDigest = function() return "00000000" end,
      refreshOwnershipProbe = function() return {} end,
      componentEntitySet = function() return {} end,
      inspectCreatedNodes = function() return {} end,
      inspectCreatedEdges = function() return {} end,
      nodePosition = function() return nil end,
      applyCommitted = function()
        if engineSteps then engineSteps.count = engineSteps.count + 1 end
        return true
      end,
    })
  end
  local first, second = proposalRuntime(), proposalRuntime()
  first.preparation.pending.test = { transactionId = "first" }
  assert(second.preparation.pending.test == nil,
    "proposal runtimes share machine-local preparation state")
  assert(first.preparation.owner("edge:test") == "company:1",
    "proposal runtime lost canonical owner metadata")
  current = {
    canonical = { byCanonical = {} },
    world = { logicalOwners = { ["20"] = "company:2" }, pinnedCustody = {} },
  }
  assert(first.preparation.owner("edge:replacement", 20) == "company:2",
    "proposal runtime retained a stale script.load state table")

  local removalOk, removalError = proposalRuntimeModule.verifyTopologyCollateralRemoved({
    { kind = "construction", cid = "construction:pre:house", localId = 90 },
    { kind = "edge", cid = "edge:old", localId = 91 },
  }, {
    entityExists = function(localId) return localId == 91 end,
    kindOf = function() return "edge" end,
  })
  assert(removalOk and removalError == nil,
    "topology collateral verifier rejected a removed construction or reused edge id")
  local retained, retainedError = proposalRuntimeModule.verifyTopologyCollateralRemoved({
    { kind = "construction", cid = "construction:pre:house", localId = 90 },
  }, {
    entityExists = function() return true end,
    kindOf = function() return "construction" end,
  })
  assert(retained == false and retainedError:find("remained after topology replay", 1, true),
    "topology collateral verifier accepted a construction left in the world")

  local topologyRemoved, topologyRemovalError =
    proposalRuntimeModule.verifyRemovalOnlyInputsRemoved({
      { kind = "edge", cid = "edge:event:test:old", localId = 91 },
      { kind = "node", cid = "node:event:test:old", localId = 92 },
      { kind = "construction", cid = "construction:pre:ignored", localId = 93 },
    }, {
      entityExists = function(localId) return localId == 93 end,
      kindOf = function() return "construction" end,
    })
  assert(topologyRemoved and topologyRemovalError == nil,
    "removal-only verifier rejected absent topology or inspected unrelated collateral")
  local topologyRetained, topologyRetainedError =
    proposalRuntimeModule.verifyRemovalOnlyInputsRemoved({
      { kind = "edge", cid = "edge:event:test:old", localId = 91 },
    }, {
      entityExists = function() return true end,
      kindOf = function() return "edge" end,
    })
  assert(topologyRetained == false
      and topologyRetainedError:find("remained after removal%-only replay"),
    "removal-only verifier accepted a topology entity left in the world")

  local steps = { count = 0 }
  current = {
    engineSteps = steps,
    bridge = { peerId = "player1" },
    canonical = { byCanonical = {} },
    world = {
      logicalOwners = {}, pinnedCustody = {},
      proposals = { byId = {
        compound = {
          status = "queued",
          transaction = {
            schemaVersion = proposalCodec.CONSTRUCTION_SCHEMA_VERSION,
            nodes = {}, edges = { {} },
            edgeObjects = { add = {}, retain = {}, remove = {} },
            remove = { edges = {}, nodes = {} },
            constructions = { { mode = "remove" } },
          },
        },
      } },
    },
  }
  proposalRuntime().processConstructions()
  assert(steps.count == 0,
    "compound topology demolition was incorrectly routed to the construction helper")
end

do
  local current = {
    networkMode = "standalone",
    initialized = false,
    tick = 1,
    bridge = { peerId = "player1" },
    probes = {},
    world = {
      proposalConsensus = { byId = {} },
      operationConsensus = { byId = {} },
      checkpointConsensus = { byBoundary = {} },
    },
    finance = {},
  }
  local committed, published = 0, 0
  local controller = networkIntentRuntimeModule.new({
    getState = function() return current end,
    normaliseForNetwork = function(action) return action end,
    normaliseOperationCapture = function(action) return action end,
    applyCommitted = function(action)
      committed = committed + 1
      return true, { type = action.type }
    end,
    activeCompany = function() return "company:1" end,
    publishSnapshot = function() published = published + 1 end,
    diagnosticLog = function() end,
    coreDigest = function() return "00000000" end,
    proposalPreparation = { pending = {} },
  })
  local ok, result = controller.submit({ type = "probe.run", localOnly = true })
  assert(ok and result.type == "probe.run" and committed == 1 and published == 1,
    "standalone intent did not cross the explicit commit/snapshot boundary")
  current.world.checkpointConsensus.byBoundary[7] = { status = "pending" }
  assert(controller.pendingBarrierReason():find("checkpoint boundary", 1, true),
    "network intent controller lost checkpoint back-pressure")
  local copy = controller.deferredIntents()
  copy[1] = { action = { type = "corrupt" } }
  assert(#controller.deferredIntents() == 0,
    "network intent controller exposed its mutable queue")
  controller.reset()
  assert(controller.awaitingOrder() == nil and #controller.deferredIntents() == 0,
    "network intent controller reset did not clear machine-local state")
end

do
  local current = {
    networkMode = "network", tick = 12, bridge = { nextInSeq = 10 }, recovery = {},
  }
  local emitted, barriers = 0, {}
  local runtime = recoveryPrepareRuntimeModule.new({
    getState = function() return current end,
    emitCheckpoint = function(reason) emitted = emitted + 1; return true, reason end,
    exportCheckpointBarrier = function(boundary, reason)
      barriers[#barriers + 1] = { boundary = boundary, reason = reason }
      return true, barriers[#barriers]
    end,
  })
  local prepared, preparation = runtime.prepare({}, nil, 7)
  assert(prepared and preparation.preparationSeq == 7
      and current.recovery.anchorPreparation.status == "requested",
    "ordered recovery preparation did not enter game-side state")
  local requested, checkpoint = runtime.checkpointRequest({
    preparationSeq = 7, reason = "recovery-prepare:7",
  }, nil, 8)
  assert(requested and checkpoint.boundary == 8 and checkpoint.reason == "recovery-prepare:7",
    "host checkpoint request did not export its exact ordered boundary")
  runtime.checkpointOutcome({ boundarySeq = 8 }, true,
    { reason = "recovery-prepare:7" })
  assert(current.recovery.anchorPreparation.status == "ready"
      and current.recovery.anchorPreparation.errorCode == nil,
    "checkpoint consensus did not complete persisted preparation state")
  assert(runtime.checkpointRequest({ preparationSeq = 7, reason = "wrong" }, nil, 8) == false,
    "malformed host checkpoint request was accepted")
  local manual, manualResult = runtime.manualCheckpoint({ reason = "manual-ui" })
  assert(manual and manualResult.boundary == 9 and emitted == 0,
    "network manual checkpoint did not use a consensus barrier at the inbox tip")
  current.networkMode = "standalone"
  assert(runtime.manualCheckpoint({ reason = "debug" }) == true and emitted == 1,
    "standalone debug checkpoint no longer uses the direct exporter")
end

do
  -- Lua must accept and reject exactly the same authored follow-up payloads
  -- as the Python protocol validator.  In particular, a canonical-looking
  -- town id is not enough: every peer must have a manifest binding before
  -- the first native development call is made.
  local current = {
    initialized = true,
    canonical = {
      byCanonical = {
        ["town:pre:bound"] = {
          canonicalId = "town:pre:bound", kind = "town", localId = 17,
        },
      },
      byLocal = { ["town:17"] = "town:pre:bound" },
    },
  }
  local valid, validationError = authoredFollowupRuntimeModule.validateTownBatch(
    current, { ["town:pre:bound"] = 8 }, true)
  assert(valid == true and validationError == nil,
    "a valid bound town-development batch was rejected")
  local invalidBatches = {
    {},
    { ["city:pre:bound"] = 1 },
    { ["town:pre:bound"] = 0 },
    { ["town:pre:bound"] = 9 },
    { ["town:pre:bound"] = 1.5 },
    { ["town:pre:missing"] = 1 },
  }
  for _, batch in ipairs(invalidBatches) do
    assert(authoredFollowupRuntimeModule.validateTownBatch(current, batch, true) == false,
      "Lua accepted a town-development batch Python rejects")
  end

  local receipt = {
    type = "recovery.save_receipt", boundarySeq = 4, savedAtUnix = 1717171717,
    saveSha256 = string.rep("a", 64), coreDigest = "core-1",
    convergenceKey = "key-4", paused = true,
  }
  local acknowledged, receiptResult = authoredFollowupRuntimeModule.acknowledgeSaveReceipt(
    current, receipt)
  assert(acknowledged == true and receiptResult.boundarySeq == 4,
    "valid save receipt was not acknowledged by the game")
  local receiptMutations = {
    { field = "paused", value = false },
    { field = "boundarySeq", value = 0 },
    { field = "savedAtUnix", value = -1 },
    { field = "saveSha256", value = "not-a-hash" },
    { field = "coreDigest", value = "" },
  }
  for _, mutation in ipairs(receiptMutations) do
    local broken = util.deepCopy(receipt)
    broken[mutation.field] = mutation.value
    assert(authoredFollowupRuntimeModule.acknowledgeSaveReceipt(current, broken) == false,
      "Lua accepted a save receipt Python rejects: " .. mutation.field)
  end
  local tooLarge = util.deepCopy(receipt)
  tooLarge.boundarySeq = 9007199254740992
  assert(authoredFollowupRuntimeModule.acknowledgeSaveReceipt(current, tooLarge) == false,
    "Lua accepted an integer outside the shared exact-safe range")
  local extra = util.deepCopy(receipt)
  extra.unexpected = true
  assert(authoredFollowupRuntimeModule.acknowledgeSaveReceipt(current, extra) == false,
    "Lua accepted an unknown save-receipt field")

  local exported = {}
  local function exportBoundary(boundary, reason)
    exported[#exported + 1] = { boundary = boundary, reason = reason }
    return true
  end
  assert(authoredFollowupRuntimeModule.afterCommit(
      current, { type = "economy.settle" }, true, 11, exportBoundary, function() end)
      and exported[1].boundary == 11
      and exported[1].reason == "economy-settlement",
    "an authoritative economy settlement did not request a convergence checkpoint")
  assert(authoredFollowupRuntimeModule.afterCommit(
      current, { type = "fare.adjust" }, true, 12, exportBoundary, function() end) == false,
    "an unrelated authored action requested an economy checkpoint")
end

do
  -- Commit-derived work must never emit recursively. Repeated registrations
  -- to one line collapse into one eventual action.
  local current = {
    networkMode = "network", initialized = false, tick = 20,
    bridge = { peerId = "player1" },
    probes = { networkAuthority = { ready = true } },
    world = {
      proposalConsensus = { byId = {} },
      operationConsensus = { byId = {} },
      checkpointConsensus = { byBoundary = {} },
    },
    finance = {},
  }
  local emitted, bridgeAvailable = {}, true
  local originalEmit = bridgeModule.emit
  local ok, failure = xpcall(function()
    bridgeModule.emit = function(_, kind, payload)
      if not bridgeAvailable then return false, "synthetic bridge outage" end
      emitted[#emitted + 1] = { kind = kind, payload = util.deepCopy(payload) }
      return true, { local_seq = #emitted }
    end
    local controller = networkIntentRuntimeModule.new({
      getState = function() return current end,
      normaliseForNetwork = function(action) return util.deepCopy(action) end,
      normaliseOperationCapture = function(action) return action end,
      applyCommitted = function() return true, {} end,
      activeCompany = function() return "company:1" end,
      publishSnapshot = function() end,
      diagnosticLog = function() end,
      coreDigest = function() return "00000000" end,
      proposalPreparation = { pending = {} },
    })
    for _ = 1, 8 do
      local queued, result = controller.scheduleFollowup({
        type = "line.register", lineCid = "line:event:storm:1",
        companyCid = "company:1",
      })
      assert(queued == true and result.deferred == true,
        "auto-registration storm lost a derived line registration")
    end
    assert(#emitted == 0 and #controller.deferredFollowups() == 1
        and controller.deferredFollowups()[1].coalesced == 7,
      "auto-registration storm emitted reentrantly or failed to coalesce")
    local work = controller.localWorkState()
    assert(work.pending == true and work.followupCount == 1 and work.deferredCount == 1,
      "anchor health cannot see a queued authored follow-up")
    assert(controller.processDeferred() == true and #emitted == 1
        and emitted[1].payload.action.type == "line.register"
        and #controller.deferredFollowups() == 0,
      "coalesced registration did not drain in one ordered round")

    controller.reset()
    emitted = {}
    current.world.checkpointConsensus.byBoundary[99] = { status = "pending" }
    local physicalQueued, physicalResult = controller.submit({
      type = "proposal.build", companyCid = "company:1",
    })
    current.world.checkpointConsensus.byBoundary[99] = nil
    assert(physicalQueued == true and physicalResult.deferred == true
        and #controller.deferredIntents() == 1,
      "synthetic physical work did not enter the deferred lane")
    controller.scheduleFollowup({
      type = "freight.milestone", stage = "aboard",
      lineCid = "line:event:priority:cargo",
      vehicleCid = "vehicle:event:priority:cargo",
      observedRound = 1, boardedTotal = 4, aboard = 4,
    })
    assert(controller.processDeferred() == true and #emitted == 1
        and emitted[1].payload.action.type == "freight.milestone"
        and #controller.deferredIntents() == 1,
      "bounded load evidence did not outrun older uncommitted physical work")

    controller.reset()
    emitted = {}
    controller.scheduleFollowup({
      type = "line.register", lineCid = "line:event:deleted:1",
      companyCid = "company:1",
    })
    controller.scheduleFollowup({
      type = "line.register", lineCid = "line:event:surviving:1",
      companyCid = "company:1",
    })
    assert(controller.cancelLineRegistration("line:event:deleted:1") == 1
        and #controller.deferredFollowups() == 1
        and controller.deferredFollowups()[1].action.lineCid == "line:event:surviving:1",
      "deleting a line did not cancel its stale registration without disturbing FIFO order")
    assert(controller.cancelLineRegistration("line:event:deleted:1") == 0,
      "line-registration cancellation was not idempotent")
    assert(controller.processDeferred() == true and #emitted == 1
        and emitted[1].payload.action.lineCid == "line:event:surviving:1",
      "a deleted line registration starved the surviving line behind it")

    controller.reset()
    emitted = {}
    local registrationSupported = false
    local quarantineController = networkIntentRuntimeModule.new({
      getState = function() return current end,
      normaliseForNetwork = function(action)
        if action.type == "line.register" and not registrationSupported then
          return nil, "line endpoints do not map to two distinct towns"
        end
        return util.deepCopy(action)
      end,
      normaliseOperationCapture = function(action) return action end,
      applyCommitted = function() return true, {} end,
      activeCompany = function() return "company:1" end,
      publishSnapshot = function() end,
      diagnosticLog = function() end,
      coreDigest = function() return "00000000" end,
      proposalPreparation = { pending = {} },
    })
    quarantineController.scheduleFollowup({
      type = "line.register", lineCid = "line:event:feeder:1",
      companyCid = "company:1",
    })
    assert(quarantineController.processDeferred() == true
        and #quarantineController.deferredFollowups() == 0
        and quarantineController.localWorkState().pending == false
        and current.probes.serviceRegistration.quarantined == 1
        and current.probes.serviceRegistration.current["line:event:feeder:1"],
      "a permanently unsupported line registration poisoned the authored follow-up lane")
    assert(#emitted == 0,
      "a line registration that failed normalization reached the bridge")
    registrationSupported = true
    quarantineController.scheduleFollowup({
      type = "line.register", lineCid = "line:event:feeder:1",
      companyCid = "company:1",
    })
    assert(quarantineController.processDeferred() == true
        and #emitted == 1
        and current.probes.serviceRegistration.current["line:event:feeder:1"] == nil
        and current.probes.serviceRegistration.recovered == 1,
      "a later supported edit did not recover a quarantined line registration")
    quarantineController.reset()
    quarantineController.scheduleFollowup({
      type = "line.register", lineCid = "line:event:legacy-cargo:1",
      companyCid = "company:1",
      market = { cid = "market:legacy" },
      service = { metadata = { registrationQuarantine = "cargo-authority-unavailable" } },
      vehicleCosts = {},
    })
    assert(quarantineController.processDeferred() == true
        and #quarantineController.deferredFollowups() == 0
        and current.probes.serviceRegistration.current["line:event:legacy-cargo:1"]
        and current.probes.serviceRegistration.current["line:event:legacy-cargo:1"].error
          == "cargo-authority-unavailable",
      "an ordered stale-service disable lost its visible quarantine diagnostic")

    local retryController = networkIntentRuntimeModule.new({
      getState = function() return current end,
      normaliseForNetwork = function(action) return util.deepCopy(action) end,
      normaliseOperationCapture = function(action) return action end,
      applyCommitted = function() return true, {} end,
      activeCompany = function() return "company:1" end,
      publishSnapshot = function() end,
      diagnosticLog = function() end,
      coreDigest = function() return "00000000" end,
      proposalPreparation = { pending = {} },
    })
    bridgeAvailable, emitted = false, {}
    retryController.scheduleFollowup({
      type = "line.register", lineCid = "line:event:outage:1",
      companyCid = "company:1",
    })
    assert(retryController.processDeferred() == true
        and #retryController.deferredFollowups() == 1
        and retryController.deferredFollowups()[1].failures == 1,
      "a transient bridge failure discarded an authored registration")
    bridgeAvailable, current.tick = true, current.tick + 15
    assert(retryController.processDeferred() == true and #emitted == 1
        and #retryController.deferredFollowups() == 0,
      "a retained registration did not recover after its bridge retry delay")

    controller.reset()
    emitted = {}
    controller.scheduleFollowup({
      type = "town.develop", batch = { ["town:event:1"] = 6 },
    })
    controller.scheduleFollowup({
      type = "town.develop", batch = { ["town:event:1"] = 6 },
    })
    assert(#emitted == 0 and controller.deferredFollowups()[1].action.batch["town:event:1"] == 12,
      "nested town-development commits did not accumulate without reentrant emission")
    controller.processDeferred()
    assert(emitted[1].payload.action.batch["town:event:1"] == 8
        and controller.deferredFollowups()[1].action.batch["town:event:1"] == 4,
      "town-development follow-up was not split into protocol-valid chunks")

    controller.reset()
    emitted = {}
    local invalidQueued = controller.scheduleFollowup({
      type = "freight.milestone", stage = "aboard",
      lineCid = "line:event:invalid", vehicleCid = "vehicle:event:invalid",
      observedRound = 0, boardedTotal = 1, aboard = 1,
    })
    assert(invalidQueued == false and #controller.deferredFollowups() == 0,
      "invalid internal aboard witness entered the persistent retry queue")
    local milestoneQueued, milestoneResult = controller.scheduleFollowup({
      type = "freight.milestone", stage = "aboard",
      lineCid = "line:event:cargo:1", vehicleCid = "vehicle:event:cargo:1",
      observedRound = 1, boardedTotal = 4, aboard = 4,
    })
    local duplicateMilestone = controller.scheduleFollowup({
      type = "freight.milestone", stage = "aboard",
      lineCid = "line:event:cargo:2", vehicleCid = "vehicle:event:cargo:2",
      observedRound = 2, boardedTotal = 9, aboard = 5,
    })
    assert(milestoneQueued == true and milestoneResult.deferred == true
        and duplicateMilestone == true and #emitted == 0
        and #controller.deferredFollowups() == 1
        and controller.deferredFollowups()[1].coalesced == 1
        and controller.deferredFollowups()[1].action.lineCid == "line:event:cargo:2"
        and controller.deferredFollowups()[1].action.observedRound == 2,
      "cargo milestone bypassed or duplicated the ordered follow-up lane")
    current.bridge.companion = { connected = false }
    assert(controller.processDeferred() == false and #emitted == 0
        and #controller.deferredFollowups() == 1,
      "consensus-bound follow-up emitted while its required peer was disconnected")
    current.bridge.companion.connected = true
    assert(controller.processDeferred() == true and #emitted == 1
        and emitted[1].payload.action.type == "freight.milestone"
        and emitted[1].payload.action.vehicleCid == "vehicle:event:cargo:2"
        and #controller.deferredFollowups() == 0,
      "cargo milestone did not drain its newest witness through one ordered round")

    controller.reset()
    emitted = {}
    local passengerQueued, passengerResult = controller.scheduleFollowup({
      type = "passenger.milestone", stage = "aboard",
      lineCid = "line:event:feeder:1", vehicleCid = "vehicle:event:bus:1",
    })
    local duplicatePassenger = controller.scheduleFollowup({
      type = "passenger.milestone", stage = "aboard",
      lineCid = "line:event:feeder:2", vehicleCid = "vehicle:event:tram:2",
    })
    assert(passengerQueued == true and passengerResult.deferred == true
        and duplicatePassenger == true and #emitted == 0
        and #controller.deferredFollowups() == 1
        and controller.deferredFollowups()[1].coalesced == 1,
      "passenger milestone bypassed or duplicated the ordered follow-up lane")
    assert(controller.processDeferred() == true and #emitted == 1
        and emitted[1].payload.action.type == "passenger.milestone"
        and #controller.deferredFollowups() == 0,
      "passenger milestone did not drain through one ordered network round")

    controller.reset()
    emitted = {}
    controller.scheduleFollowup({
      type = "line.register", lineCid = "line:event:after-evidence",
      companyCid = "company:1",
    })
    controller.scheduleFollowup({
      type = "freight.milestone", stage = "aboard",
      lineCid = "line:event:cargo:both", vehicleCid = "vehicle:event:cargo:both",
    })
    controller.scheduleFollowup({
      type = "passenger.milestone", stage = "aboard",
      lineCid = "line:event:feeder:both", vehicleCid = "vehicle:event:bus:both",
    })
    local evidenceQueue = controller.deferredFollowups()
    assert(#evidenceQueue == 3
        and evidenceQueue[1].action.type == "freight.milestone"
        and evidenceQueue[2].action.type == "passenger.milestone"
        and evidenceQueue[3].action.type == "line.register",
      "evidence priorities crossed domains, reversed FIFO order, or stayed behind registration")
  end, debug.traceback)
  bridgeModule.emit = originalEmit
  if not ok then error(failure, 0) end
end

do
  -- Only a real same-town ROAD/TRAM feeder may open the one-time passenger
  -- aboard checkpoint. Rail corridors and malformed local bindings must not
  -- consume that proof opportunity before the feeder runs.
  passengerMilestoneRuntimeModule.reset()
  local lineCid = "line:event:feeder-proof"
  local vehicleCid = "vehicle:event:feeder-proof"
  local current = {
    initialized = true, networkMode = "network", tick = 51,
    match = { status = "running" },
    bridge = {
      peerId = "player2", sessionId = "passenger-proof",
      companion = { connected = true },
    },
    probes = {},
    economy = { services = { [lineCid] = {
      lineCid = lineCid, enabled = true,
      metadata = {
        carrier = "ROAD", marketScope = "local",
        stationGroupCids = { "station_group:event:a", "station_group:event:b" },
        endpointTownCids = { "town:pre:a", "town:pre:a" },
      },
    } } },
    world = { passengerPresentation = {
      lines = { [lineCid] = { lineCid = lineCid, boardedTotal = 7 } },
      vehicles = { [vehicleCid] = {
        lineCid = lineCid, aboard = 7, lastRound = 3, boardedTotal = 7,
      } },
    } },
  }
  local handlers = {}
  passengerMilestoneRuntimeModule.installHandler(handlers, {
    getState = function() return current end,
    requireRunningMatch = function() return true end,
  })
  local action = {
    type = "passenger.milestone", stage = "aboard",
    lineCid = lineCid, vehicleCid = vehicleCid,
  }
  assert(passengerMilestoneRuntimeModule.normaliseIntent(current, action) == nil,
    "client peer was allowed to author a passenger milestone")
  local applied, result = handlers["passenger.milestone"](action)
  assert(applied == true and result.aboard == 7
      and current.probes.passengerMilestone.aboardCheckpointed == true,
    "client peer rejected a valid host-authored passenger milestone")
  assert(handlers["passenger.milestone"]({
      type = "passenger.milestone", stage = "aboard", lineCid = lineCid,
      vehicleCid = vehicleCid, unexpected = true,
    }) == false,
    "passenger milestone accepted an unknown wire field")

  current.bridge.peerId = "player1"
  current.probes.passengerMilestone = nil
  current.bridge.companion.connected = false
  local scheduled, diagnostics = {}, {}
  local controller = { scheduleFollowup = function(pending)
    if #scheduled == 0 then scheduled[1] = util.deepCopy(pending) end
    return true, { deferred = true, coalesced = #scheduled > 0 }
  end }
  local function log(kind, fields)
    diagnostics[#diagnostics + 1] = { kind = kind, fields = fields }
  end
  assert(passengerMilestoneRuntimeModule.observeRelease(
      current, { vehicleCid = vehicleCid }, controller, log) == false
      and #scheduled == 0,
    "disconnected host scheduled a passenger milestone")
  current.bridge.companion.connected = true
  current.world.passengerPresentation.vehicles[vehicleCid].lastRound = 0
  assert(passengerMilestoneRuntimeModule.observeRelease(
      current, { vehicleCid = vehicleCid }, controller, log) == false,
    "passenger proof scheduled an invalid zero-round witness")
  current.world.passengerPresentation.vehicles[vehicleCid].lastRound = 3
  assert(passengerMilestoneRuntimeModule.observeRelease(
      current, { vehicleCid = vehicleCid }, controller, log) == true
      and #scheduled == 1 and scheduled[1].type == "passenger.milestone"
      and scheduled[1].observedRound == 3 and scheduled[1].boardedTotal == 7
      and scheduled[1].aboard == 7,
    "first authoritative feeder load did not schedule its proof milestone")
  current.world.passengerPresentation.vehicles[vehicleCid].aboard = 0
  assert(handlers["passenger.milestone"](scheduled[1]) == true,
    "host could not apply a witnessed passenger milestone after alighting")

  local exported = {}
  assert(passengerMilestoneRuntimeModule.afterCommit(
      current, scheduled[1], true, 23, function(boundary, reason)
        exported[#exported + 1] = { boundary = boundary, reason = reason }
        return true
      end, log) == true
      and exported[1].boundary == 23
      and exported[1].reason == "passenger-milestone:aboard",
    "passenger milestone did not open its convergence checkpoint")

  current.probes.passengerMilestone = nil
  current.world.passengerPresentation.lines[lineCid].boardedTotal = 6
  local staleOk, staleResult = handlers["passenger.milestone"](scheduled[1])
  assert(staleOk == true and staleResult.stale == true
      and current.probes.passengerMilestone.aboardCheckpointed == false,
    "stale passenger witness faulted the session or consumed the proof")
  current.world.passengerPresentation.lines[lineCid].boardedTotal = 7

  current.probes.passengerMilestone = nil
  current.economy.services[lineCid].metadata.carrier = "RAIL"
  scheduled = {}
  assert(passengerMilestoneRuntimeModule.observeRelease(
      current, { vehicleCid = vehicleCid }, controller, log) == false
      and #scheduled == 0,
    "rail corridor consumed the local-feeder passenger proof milestone")
  current.economy.services[lineCid].metadata.carrier = "TRAM"
  current.economy.services[lineCid].metadata.stationGroupCids = {
    "station_group:event:a", "station_group:event:a",
  }
  assert(passengerMilestoneRuntimeModule.observeRelease(
      current, { vehicleCid = vehicleCid }, controller, log) == false,
    "duplicate-stop feeder consumed the passenger proof milestone")
  passengerMilestoneRuntimeModule.reset()
end

do
  -- The host authors the first non-zero cargo milestone, but both peers must
  -- apply and verify it against their local authored cargo ledger.
  freightMilestoneRuntimeModule.reset()
  local lineCid, vehicleCid = "line:event:freight-proof", "vehicle:event:freight-proof"
  local current = {
    initialized = true, networkMode = "network", tick = 44,
    match = { status = "running" },
    bridge = { peerId = "player2", companion = { connected = true } },
    probes = {},
    world = { cargoPresentation = {
      lines = { [lineCid] = { retired = false, boardedTotal = 12 } },
      vehicles = { [vehicleCid] = {
        lineCid = lineCid, aboard = 12, lastRound = 1, boardedTotal = 12,
      } },
    } },
  }
  local handlers = {}
  freightMilestoneRuntimeModule.installHandler(handlers, {
    getState = function() return current end,
    requireRunningMatch = function() return true end,
  })
  assert(freightMilestoneRuntimeModule.normaliseIntent(current, {
      type = "freight.milestone", stage = "aboard",
      lineCid = lineCid, vehicleCid = vehicleCid,
    }) == nil,
    "client peer was allowed to author a freight milestone")
  local applied, result = handlers["freight.milestone"]({
    type = "freight.milestone", stage = "aboard",
    lineCid = lineCid, vehicleCid = vehicleCid,
  })
  assert(applied == true and result.aboard == 12
      and current.probes.freightMilestone.aboardCheckpointed == true,
    "client peer rejected or failed to record a valid host-authored milestone")
  assert(handlers["freight.milestone"]({
      type = "freight.milestone", stage = "aboard", lineCid = lineCid,
      vehicleCid = vehicleCid, unexpected = true,
    }) == false,
    "freight milestone accepted an unknown wire field")

  freightMilestoneRuntimeModule.reset()
  current.bridge.peerId = "player1"
  current.probes.freightMilestone = nil
  current.bridge.companion.connected = false
  local scheduled, diagnostics = {}, {}
  local controller = { scheduleFollowup = function(action)
    if #scheduled == 0 then scheduled[1] = util.deepCopy(action) end
    return true, { deferred = true, coalesced = #scheduled > 0 }
  end }
  local function log(kind, fields)
    diagnostics[#diagnostics + 1] = { kind = kind, fields = fields }
  end
  assert(freightMilestoneRuntimeModule.observeRelease(
      current, { vehicleCid = vehicleCid }, controller, log) == false
      and #scheduled == 0,
    "disconnected host scheduled a consensus-bound cargo milestone")
  current.bridge.companion.connected = true
  current.world.cargoPresentation.vehicles[vehicleCid].lastRound = 0
  assert(freightMilestoneRuntimeModule.observeRelease(
      current, { vehicleCid = vehicleCid }, controller, log) == false,
    "cargo proof scheduled an invalid zero-round witness")
  current.world.cargoPresentation.vehicles[vehicleCid].lastRound = 1
  local queued = freightMilestoneRuntimeModule.observeRelease(
    current, { vehicleCid = vehicleCid }, controller, log)
  assert(queued == true and #scheduled == 1
      and scheduled[1].lineCid == lineCid and scheduled[1].vehicleCid == vehicleCid
      and scheduled[1].observedRound == 1 and scheduled[1].boardedTotal == 12
      and scheduled[1].aboard == 12,
    "first authoritative cargo load did not schedule its proof milestone")
  assert(freightMilestoneRuntimeModule.observeRelease(
      current, { vehicleCid = vehicleCid }, controller, log) == true
      and #scheduled == 1,
    "pending cargo proof did not defer to queue-owned duplicate suppression")
  current.world.cargoPresentation.vehicles[vehicleCid].aboard = 0
  assert(handlers["freight.milestone"](scheduled[1]) == true,
    "host could not apply a witnessed cargo milestone after alighting")

  local exported = {}
  assert(freightMilestoneRuntimeModule.afterCommit(
      current, scheduled[1], true, 19, function(boundary, reason)
        exported[#exported + 1] = { boundary = boundary, reason = reason }
        return true
      end, log) == true
      and exported[1].boundary == 19
      and exported[1].reason == "freight-milestone:aboard",
    "cargo milestone did not automatically open its convergence checkpoint")
  current.world.cargoPresentation.vehicles[vehicleCid].boardedTotal = 0
  current.probes.freightMilestone = nil
  freightMilestoneRuntimeModule.reset()
  local staleOk, staleResult = handlers["freight.milestone"](scheduled[1])
  assert(staleOk == true and staleResult.stale == true
      and current.probes.freightMilestone.aboardCheckpointed == false,
    "stale cargo witness faulted the session or consumed the proof")
  current.world.cargoPresentation.vehicles[vehicleCid].boardedTotal = 12
  current.world.cargoPresentation.vehicles[vehicleCid].aboard = 12
  current.probes.freightMilestone = {
    aboardCheckpointed = true, sessionId = "superseded-session",
  }
  assert(freightMilestoneRuntimeModule.observeRelease(
      current, { vehicleCid = vehicleCid }, controller, log) == true,
    "a saved milestone from another session suppressed fresh-session evidence")
  freightMilestoneRuntimeModule.reset()
end

do
  -- The extracted live validator must retain the exact three-round protocol:
  -- development checkpoint, native settle window, then an ordered structural
  -- checkpoint before the generic drift soak begins.
  local townCid = "town:pre:validation"
  local state = {
    tick = 0,
    bridge = { peerId = "player1" },
    canonical = { byCanonical = {
      [townCid] = { canonicalId = townCid, kind = "town", localId = 41 },
    } },
    companies = {}, world = {},
    probes = { structural = {
      digest = "initial", towns = { { cid = townCid, totalCapacity = 10 } },
    } },
    validation = { values = {} },
  }
  local stage, checkpointRecord, soakBoundary
  local submissions, checks, snapshotIndex = {}, {}, 0
  local runtime = townDevelopmentValidationModule.new({
    getState = function() return state end,
    transition = function(value) stage = value end,
    check = function(name, passed)
      assert(passed, "town validator check failed: " .. tostring(name))
      checks[name] = true
    end,
    submit = function(action)
      submissions[#submissions + 1] = util.deepCopy(action)
      return { local_seq = #submissions }
    end,
    checkpoint = function(predicate)
      return checkpointRecord and predicate(checkpointRecord) and checkpointRecord or nil
    end,
    structuralSnapshot = function()
      snapshotIndex = snapshotIndex + 1
      return {
        digest = "physical-" .. tostring(snapshotIndex),
        towns = { { cid = townCid, totalCapacity = 10 + snapshotIndex } },
      }
    end,
    beginSoak = function(boundary) soakBoundary = boundary end,
  })
  runtime.begin(5)
  assert(stage == "wait-for-town-development-checkpoint"
      and submissions[1].type == "town.develop"
      and submissions[1].batch[townCid] == 8,
    "town validator did not queue its first bounded development round")
  for round = 1, 3 do
    checkpointRecord = {
      reason = "town-development", boundarySeq = 5 + round, success = true,
    }
    state.probes.townDevelopment = {
      towns = 1, calls = 8, activated = 1, refrozen = 1, errors = {},
    }
    assert(runtime.maintain(stage) == true
        and stage == "wait-for-town-development-settle",
      "town validator did not accept round checkpoint " .. tostring(round))
    state.tick = state.tick + 90
    assert(runtime.maintain(stage) == true,
      "town validator did not finish native settle round " .. tostring(round))
    if round < 3 then
      assert(stage == "wait-for-town-development-checkpoint"
          and submissions[#submissions].type == "town.develop",
        "town validator did not queue the next development round")
    else
      assert(stage == "wait-for-post-town-structural-checkpoint"
          and submissions[#submissions].type == "probe.structural",
        "town validator skipped its final ordered structural sample")
    end
  end
  checkpointRecord = { reason = "structural-probe", boundarySeq = 9, success = true }
  assert(runtime.maintain(stage) == true and soakBoundary == 9
      and checks["ordered-town-development-changed-native-world"] == true
      and #submissions == 4,
    "town validator did not close the physical experiment at a shared boundary")
end

do
  -- Model the actual eight-assignment burst: one operation is in flight,
  -- seven fit in the physical FIFO, and all eight commit-derived registration
  -- requests coalesce behind that FIFO into one final ordered action.
  local current = {
    networkMode = "network", initialized = false, tick = 40,
    bridge = { peerId = "player1" },
    probes = { networkAuthority = { ready = true } },
    world = {
      proposalConsensus = { byId = {} },
      operationConsensus = { byId = {} },
      checkpointConsensus = { byBoundary = {} },
    },
    finance = {},
  }
  local envelopes, pollQueue, controller = {}, {}
  local originalEmit, originalPoll = bridgeModule.emit, bridgeModule.poll
  local ok, failure = xpcall(function()
    local sequence = 0
    bridgeModule.emit = function(_, kind, payload)
      sequence = sequence + 1
      local envelope = {
        kind = kind, payload = util.deepCopy(payload), local_seq = sequence,
      }
      envelopes[#envelopes + 1] = envelope
      return true, envelope
    end
    bridgeModule.poll = function()
      local result = pollQueue
      pollQueue = {}
      return result
    end
    controller = networkIntentRuntimeModule.new({
      getState = function() return current end,
      normaliseForNetwork = function(action) return util.deepCopy(action) end,
      normaliseOperationCapture = function(action) return action end,
      applyCommitted = function(action)
        if action.type == "operation.execute" then
          local registered = controller.scheduleFollowup({
            type = "line.register", lineCid = "line:event:storm:1",
            companyCid = "company:1",
          })
          assert(registered == true, "commit-derived registration was dropped")
        end
        return true, {}, { postDigest = "00000000" }
      end,
      activeCompany = function() return "company:1" end,
      publishSnapshot = function() end,
      diagnosticLog = function() end,
      coreDigest = function() return "00000000" end,
      proposalPreparation = { pending = {} },
    })
    local operation = {
      type = "operation.execute",
      transaction = { companyCid = "company:1", kind = "vehicle.assign" },
    }
    for index = 1, 8 do
      local submitted, result = controller.submit(util.deepCopy(operation))
      assert(submitted == true, "assignment burst rejected item " .. tostring(index))
      if index > 1 then
        assert(result.deferred == true and result.queuePosition == index - 1,
          "assignment burst did not enter FIFO order")
      end
    end
    assert(#controller.deferredIntents() == 7,
      "eight assignments overflowed or bypassed the 32-entry physical FIFO")

    for authoritySeq = 1, 8 do
      local intent
      for index = #envelopes, 1, -1 do
        if envelopes[index].kind == "intent"
          and envelopes[index].payload.action.type == "operation.execute" then
          intent = envelopes[index]
          break
        end
      end
      assert(intent, "assignment operation was not emitted")
      pollQueue = { {
        kind = "commit", seq = authoritySeq, origin_peer = "player1",
        origin_local_seq = intent.local_seq,
        payload = { action = util.deepCopy(operation) },
      } }
      controller.consume()
      if authoritySeq < 8 then assert(controller.processDeferred() == true) end
    end
    assert(#controller.deferredIntents() == 0
        and #controller.deferredFollowups() == 1
        and controller.deferredFollowups()[1].coalesced == 7,
      "assignment storm did not drain FIFO-first into one registration")
    assert(controller.processDeferred() == true,
      "coalesced registration did not emit after the assignment FIFO")
    local intentCount, registrationCount = 0, 0
    for _, envelope in ipairs(envelopes) do
      if envelope.kind == "intent" then
        intentCount = intentCount + 1
        if envelope.payload.action.type == "line.register" then
          registrationCount = registrationCount + 1
        end
      end
    end
    assert(intentCount == 9 and registrationCount == 1,
      "eight assignments produced redundant registration consensus rounds")
  end, debug.traceback)
  bridgeModule.emit, bridgeModule.poll = originalEmit, originalPoll
  if not ok then error(failure, 0) end
end

do
  -- An origin-applied capture is a native mutation that already happened.
  -- Every rejection path must convert into an operation-consensus session
  -- fault instead of a status-line whisper.
  local function faultHarness(captureResult, options)
    options = options or {}
    local current = {
      networkMode = "network",
      initialized = false,
      tick = 9,
      bridge = { peerId = "player1" },
      probes = { networkAuthority = { ready = true } },
      world = {
        proposalConsensus = { byId = {} },
        operationConsensus = { byId = {} },
        checkpointConsensus = { byBoundary = {} },
      },
      finance = {},
    }
    local logged = {}
    local controller = networkIntentRuntimeModule.new({
      getState = function() return current end,
      normaliseForNetwork = function(action) return action end,
      normaliseOperationCapture = function() return captureResult, "operation cannot mutate rival-owned line" end,
      applyCommitted = function(action) return true, { type = action.type } end,
      activeCompany = function() return "company:1" end,
      publishSnapshot = function() end,
      diagnosticLog = function(event, payload) logged[#logged + 1] = { event = event, payload = payload } end,
      coreDigest = function() return "00000000" end,
      proposalPreparation = { pending = {} },
      maxDeferredIntents = options.maxDeferredIntents,
    })
    return current, controller, logged
  end

  local current, controller, logged = faultHarness(nil)
  local ok = controller.submit({
    type = "operation.capture",
    capture = { kind = "line.update", originApplied = true, targetLocalId = 7 },
  })
  local fault = current.world.operationConsensus.sessionFault
  assert(ok == false and fault
    and fault.errorCode:find("origin%-applied%-capture%-rejected:") == 1
    and fault.status == "faulted" and fault.detail.kind == "line.update",
    "rejected origin-applied capture did not fault the session")
  assert(logged[1] and logged[1].event == "origin-applied-residue-fault",
    "origin residue fault was not logged for the audit trail")
  local blockedOk, blockedError = controller.submit({ type = "proposal.build", transaction = {} })
  assert(blockedOk == false and tostring(blockedError):find("faulted"),
    "faulted session accepted a further physical action")

  current, controller = faultHarness(nil)
  local plainOk = controller.submit({
    type = "operation.capture",
    capture = { kind = "line.update", targetLocalId = 7 },
  })
  assert(plainOk == false and current.world.operationConsensus.sessionFault == nil,
    "a rejected mod-panel capture without native residue must not fault the session")

  current, controller = faultHarness(nil)
  local residueOk, residueResult = controller.submit({
    type = "network.origin_residue",
    errorCode = "origin-applied-create-unidentified",
    detail = { tag = 3 },
  })
  fault = current.world.operationConsensus.sessionFault
  assert(residueOk == true and residueResult.faulted == true and fault
    and fault.errorCode == "origin-applied-create-unidentified"
    and fault.detail.tag == 3,
    "GUI-reported origin residue did not fault the session")

  current, controller = faultHarness(nil)
  current.networkMode = "standalone"
  local standaloneOk = controller.submit({
    type = "network.origin_residue",
    errorCode = "origin-applied-create-unidentified",
  })
  assert(standaloneOk == false and current.world.operationConsensus.sessionFault == nil,
    "origin residue faults must exist only in network mode")

  local normalizedCapture = {
    type = "operation.execute",
    kind = "line.update",
    companyCid = "company:1",
    originCaptureToken = "player1:operation-origin:1",
  }

  current, controller = faultHarness(normalizedCapture)
  local emitOk = controller.submit({
    type = "operation.capture",
    capture = { kind = "line.update", originApplied = true, targetLocalId = 7 },
  })
  fault = current.world.operationConsensus.sessionFault
  assert(emitOk == false and fault
    and fault.errorCode:find("origin%-applied%-intent%-emit%-failed:") == 1,
    "an immediate bridge failure left an origin-applied capture unfaulted")

  current, controller = faultHarness(normalizedCapture)
  current.probes.networkAuthority.ready = false
  local authorityOk = controller.submit({
    type = "operation.capture",
    capture = { kind = "line.update", originApplied = true, targetLocalId = 7 },
  })
  fault = current.world.operationConsensus.sessionFault
  assert(authorityOk == false and fault
    and fault.errorCode:find("origin%-applied%-authority%-unavailable:") == 1,
    "authority bootstrap rejection left an origin-applied capture unfaulted")

  current, controller = faultHarness(normalizedCapture)
  current.initialized = true
  local financeOk = controller.submit({
    type = "operation.capture",
    capture = { kind = "line.update", originApplied = true, targetLocalId = 7 },
  })
  fault = current.world.operationConsensus.sessionFault
  assert(financeOk == false and fault
    and fault.errorCode:find("origin%-applied%-finance%-unavailable:") == 1,
    "canonical-account rejection left an origin-applied capture unfaulted")

  current, controller = faultHarness(normalizedCapture, { maxDeferredIntents = 1 })
  current.world.checkpointConsensus.byBoundary[3] = { status = "pending" }
  local queuedOk, queuedResult = controller.submit({
    type = "operation.capture",
    capture = { kind = "line.update", originApplied = true, targetLocalId = 7 },
  })
  assert(queuedOk == true and queuedResult.deferred == true,
    "origin-applied capture was not queued behind a consensus barrier")
  local overflowOk = controller.submit({
    type = "operation.capture",
    capture = { kind = "line.update", originApplied = true, targetLocalId = 8 },
  })
  fault = current.world.operationConsensus.sessionFault
  assert(overflowOk == false and fault
    and fault.errorCode == "origin-applied-deferred-queue-full"
    and fault.detail.queueDepth == 1 and fault.detail.queueCapacity == 1,
    "deferred FIFO overflow left an origin-applied capture unfaulted")

  -- A normalizer that throws must not lose an already-applied mutation to
  -- the outer handleEvent pcall.
  do
    local thrown = {
      networkMode = "network", initialized = false, tick = 9,
      bridge = { peerId = "player1" },
      probes = { networkAuthority = { ready = true } },
      world = {
        proposalConsensus = { byId = {} },
        operationConsensus = { byId = {} },
        checkpointConsensus = { byBoundary = {} },
      },
      finance = {},
    }
    local thrownController = networkIntentRuntimeModule.new({
      getState = function() return thrown end,
      normaliseForNetwork = function(action) return action end,
      normaliseOperationCapture = function() error("station group lookup exploded") end,
      applyCommitted = function(action) return true, { type = action.type } end,
      activeCompany = function() return "company:1" end,
      publishSnapshot = function() end,
      diagnosticLog = function() end,
      coreDigest = function() return "00000000" end,
      proposalPreparation = { pending = {} },
    })
    local throwOk = thrownController.submit({
      type = "operation.capture",
      capture = { kind = "line.update", originApplied = true, targetLocalId = 7 },
    })
    local throwFault = thrown.world.operationConsensus.sessionFault
    assert(throwOk == false and throwFault
      and throwFault.errorCode:find("origin%-applied%-capture%-rejected:") == 1
      and throwFault.errorCode:find("exploded", 1, true),
      "a throwing normalization left an origin-applied capture unfaulted")
  end

  -- The deferred-emit failure variant: a token-bearing action that reaches
  -- the front of the FIFO and then fails to emit.
  do
    local deferred = {
      networkMode = "network", initialized = false, tick = 9,
      bridge = { peerId = "player1" },
      probes = { networkAuthority = { ready = true } },
      world = {
        proposalConsensus = { byId = {} },
        operationConsensus = { byId = {} },
        checkpointConsensus = { byBoundary = { [3] = { status = "pending" } } },
      },
      finance = {},
    }
    local deferredController = networkIntentRuntimeModule.new({
      getState = function() return deferred end,
      normaliseForNetwork = function(action) return action end,
      normaliseOperationCapture = function() return normalizedCapture end,
      applyCommitted = function(action) return true, { type = action.type } end,
      activeCompany = function() return "company:1" end,
      publishSnapshot = function() end,
      diagnosticLog = function() end,
      coreDigest = function() return "00000000" end,
      proposalPreparation = { pending = {} },
    })
    local queued = deferredController.submit({
      type = "operation.capture",
      capture = { kind = "line.update", originApplied = true, targetLocalId = 7 },
    })
    assert(queued == true, "token-bearing capture did not defer behind the barrier")
    deferred.world.checkpointConsensus.byBoundary[3] = nil
    deferredController.processDeferred()
    local deferredFault = deferred.world.operationConsensus.sessionFault
    assert(deferredFault
      and deferredFault.errorCode:find("origin%-applied%-intent%-emit%-failed:") == 1,
      "a deferred token-bearing emit failure left the mutation unfaulted")
  end
end

do
  local current = {
    networkMode = "network",
    initialized = false,
    tick = 240,
    bridge = { peerId = "player1" },
    probes = {
      networkAuthority = { ready = true },
      networkCalendar = { requested = true, frozen = true },
    },
  }
  local submissions = 0
  local bootstrapReady = false
  local clock = networkClockRuntimeModule.new({
    getState = function() return current end,
    config = function()
      return { manualNetwork = true, manualBootstrapReady = bootstrapReady }
    end,
    diagnosticLog = function() end,
    submitIntent = function(action)
      submissions = submissions + 1
      return action.type == "match.initialise", { local_seq = 9 }
    end,
    awaitingOrder = function() return nil end,
    pendingBarrierReason = function() return nil end,
  })
  clock.maintainManualBootstrap()
  assert(submissions == 0,
    "manual clock bootstrap ran before the launcher confirmed both worlds")
  current.tick = 120
  clock.maintainManualBootstrap(true)
  assert(submissions == 0 and clock.manualBootstrap.launcherReady == true,
    "manual clock bootstrap did not latch an early launcher/UI readiness handoff")
  current.tick = 240
  clock.maintainManualBootstrap()
  assert(submissions == 1 and clock.manualBootstrap.submitted == true,
    "manual clock bootstrap lost its latched launcher/UI readiness handoff")
  clock.reset()
  bootstrapReady = true
  clock.maintainManualBootstrap()
  assert(submissions == 2,
    "manual clock bootstrap ignored a directly visible readiness marker")
  clock.reset()
  assert(clock.manualBootstrap.attempts == 0 and clock.manualBootstrap.nextAttemptTick == 240
      and clock.manualBootstrap.launcherReady == false,
    "network clock reset did not restore bootstrap defaults")
end

do
  local submitted
  local current = {
    networkMode = "network", initialized = true, tick = 240,
    bridge = { peerId = "player1" },
    recovery = { restoreResume = { status = "validated" } },
    probes = { networkAuthority = { ready = true } },
  }
  local clock = networkClockRuntimeModule.new({
    getState = function() return current end,
    config = function()
      return { manualNetwork = true, manualBootstrapReady = true,
        restoreResume = { requested = true } }
    end,
    diagnosticLog = function() end,
    submitIntent = function(action) submitted = action; return true, { local_seq = 3 } end,
    awaitingOrder = function() return nil end,
    pendingBarrierReason = function() return nil end,
  })
  clock.maintainManualBootstrap()
  assert(submitted and submitted.type == "recovery.resume",
    "loaded initialized match did not submit its restore handshake")
  current.recovery.restoreResume.status = "failed"
  submitted = nil
  clock.reset()
  clock.maintainManualBootstrap()
  assert(submitted == nil, "failed restore silently fell back to new-match initialisation")
end

do
  local gameTime, gameSpeed = 10, 1
  local wall = 100
  local commands, emitted = {}, {}
  local current = {
    networkMode = "network", initialized = true, tick = 30,
    bridge = { peerId = "player1", nextInSeq = 3 },
    probes = {
      networkAuthority = { ready = true },
      networkCalendar = { requested = true, frozen = true },
    },
    world = {
      networkClock = {
        requestedSpeed = 1, effectiveSpeed = 1, generation = 0,
        rendezvousReached = 0, rendezvousFaults = 0,
        startupPause = { requested = true, confirmed = true },
      },
      proposalConsensus = { byId = {} },
    },
  }
  local clock = networkClockRuntimeModule.new({
    getState = function() return current end,
    config = function() return {} end,
    diagnosticLog = function() end,
    submitIntent = function() return true, {} end,
    awaitingOrder = function() return nil end,
    pendingBarrierReason = function() return nil end,
    clockSnapshot = function()
      return { time = gameTime, gameSpeed = gameSpeed }
    end,
    wallTime = function() return wall end,
    commandFactory = function(kind)
      return function(speed) return { kind = kind, speed = speed } end
    end,
    authorizeCommand = function(tag) return tag == 0 end,
    sendCommand = function(command, callback)
      commands[#commands + 1] = util.deepCopy(command)
      if command.kind == "setGameSpeed" then gameSpeed = command.speed end
      if callback then callback(command, true) end
      return true
    end,
    emit = function(kind, payload)
      emitted[#emitted + 1] = { kind = kind, payload = util.deepCopy(payload) }
      return true, { local_seq = #emitted }
    end,
  })
  local armed = clock.arm({
    type = "clock.rendezvous", requestedSpeed = 3, approachSpeed = 1,
    releaseSpeed = 3, generation = 1, targetGameTime = 12,
    reason = "runtime-test",
  })
  assert(armed == true and #commands == 0
      and current.world.networkClock.rendezvous.status == "approaching",
    "future clock rendezvous did not arm without pausing early")
  gameTime, current.tick = 11.99, 31
  clock.update()
  assert(#commands == 0 and #emitted == 0,
    "future clock rendezvous paused or reported before its target")
  gameTime, current.tick = 12, 32
  clock.update()
  assert(#commands == 1 and commands[1].speed == 0 and gameSpeed == 0
      and current.world.networkClock.rendezvous.status == "reached"
      and current.world.networkClock.rendezvousReached == 1,
    "clock rendezvous did not pause exactly at the local target")
  local reached
  for _, envelope in ipairs(emitted) do
    if envelope.kind == "clock_reached" then reached = envelope.payload end
  end
  assert(reached and reached.generation == 1 and reached.targetGameTime == 12
      and reached.actualGameTime == 12 and reached.success == true,
    "clock rendezvous did not report its observed arrival")
  current.tick = 33
  local applied = clock.apply({
    type = "clock.set", requestedSpeed = 3, effectiveSpeed = 3,
    generation = 2, reason = "release-runtime-test",
  })
  assert(applied == true and gameSpeed == 3 and #commands == 2
      and current.world.networkClock.rendezvous == nil
      and current.world.networkClock.lastRendezvous.generation == 1,
    "ordered post-rendezvous speed did not release the shared clock")
  local prerequisite, waitReason = clock.operationPrerequisite({
    type = "operation.execute", transaction = { kind = "line.update" },
  })
  assert(prerequisite and prerequisite.type == "clock.request"
      and prerequisite.requestedSpeed == 0 and waitReason:find("rendezvous", 1, true),
    "non-origin line mutation was not guarded by a shared pause prerequisite")
  local originPrerequisite = clock.operationPrerequisite({
    type = "operation.execute", originCaptureToken = "already-applied",
    transaction = { kind = "vehicle.sell" },
  })
  assert(originPrerequisite and originPrerequisite.requestedSpeed == 0,
    "origin-applied vehicle capture did not pause both worlds before replication")
  current.world.networkClock.effectiveSpeed, gameSpeed = 0, 1
  local nativeMismatchPrerequisite = clock.operationPrerequisite({
    type = "operation.execute", transaction = { kind = "vehicle.assign" },
  })
  assert(nativeMismatchPrerequisite and nativeMismatchPrerequisite.requestedSpeed == 0,
    "native running state bypassed the authoritative operation pause")
  local healthBefore = #emitted
  gameSpeed = 0
  assert(clock.emitPausedHealth() == true, "paused clock did not emit its first heartbeat")
  wall = 101
  assert(clock.emitPausedHealth() == false,
    "paused clock heartbeat ignored its wall-time throttle")
  wall = 102
  assert(clock.emitPausedHealth() == true and #emitted == healthBefore + 2,
    "paused clock did not refresh telemetry before the host freshness deadline")
  gameSpeed = 3
  local startupPaused = clock.freezeGame()
  assert(startupPaused == true and gameSpeed == 0
      and current.world.networkClock.startupPause.confirmed == false,
    "network startup did not issue a deterministic native pause request")
  clock.update()
  assert(current.world.networkClock.startupPause.confirmed == true,
    "network startup pause was not confirmed by post-init readback")

  -- Fresh-world init is evaluated against duplicate script states.  The
  -- first pause can change native speed before the second state initializes;
  -- both authored records must nevertheless serialize identically.
  gameSpeed = 3
  local firstState = util.deepCopy(current.world.networkClock)
  clock.freezeGame()
  firstState = util.deepCopy(current.world.networkClock.startupPause)
  clock.freezeGame()
  local secondState = util.deepCopy(current.world.networkClock.startupPause)
  assert(require("tpf2_mp/hash").value(firstState)
      == require("tpf2_mp/hash").value(secondState)
      and firstState.confirmed == false and firstState.observedBefore == nil,
    "startup pause persisted native pre-pause readback across duplicate init states")
  gameTime = nil
  assert(clock.arm({
    type = "clock.rendezvous", requestedSpeed = 1, approachSpeed = 1,
    releaseSpeed = 1, generation = 3, targetGameTime = 20,
  }) == false, "clock rendezvous accepted an unavailable local game time")
  local calendarOk, calendarError = clock.freezeCalendar()
  assert(calendarOk == false and calendarError:find("authorize", 1, true),
    "calendar freeze ignored a rejected native authorization")
end

do
  local current = { validation = { enabled = false } }
  local function noop() return true, {} end
  local validation = validationRuntimeModule.new({
    getState = function() return current end,
    config = function() return { autoValidate = false, networkAutoValidate = false } end,
    diagnosticLog = function() end,
    coreDigest = function() return "00000000" end,
    authoredDigest = function() return "00000000" end,
    exportResearch = noop,
    balanceOf = function() return 0 end,
    proposalResourceName = function() return nil end,
    applyCommitted = noop,
    submitIntent = noop,
    awaitingOrder = function() return nil end,
    pendingBarrierReason = function() return nil end,
    activeCompany = function() return nil end,
    refreshOwnershipProbe = function() return {} end,
  })
  assert(validation.runStandalone() == nil and validation.runNetwork() == nil,
    "disabled validation runtime performed work")
end

do
  local environment = {
    TPF2MP_MANUAL_NETWORK = "yes",
    TPF2MP_PEER_ID = "player2",
    TPF2MP_SESSION_ID = "injected-session",
    TPF2MP_BRIDGE_DIR = "C:/bridge/injected",
    TPF2MP_STARTING_CASH = "75000000",
    TPF2MP_ECONOMY_DIFFICULTY = "relaxed",
    TPF2MP_NETWORK_CLOCK_RUN_TICKS = "900",
    TPF2MP_STARTING_COMPANY_PLAYER_IDS = "9478,9479,9478",
    TPF2MP_RESTORE_RESUME = "1",
    TPF2MP_RESTORE_FROM_SESSION = "saved-session",
    TPF2MP_RESTORE_BOUNDARY = "7",
    TPF2MP_RESTORE_CORE_DIGEST = "1234abcd",
    TPF2MP_RESTORE_CONVERGENCE_KEY = "2345bcde",
    TPF2MP_RESTORE_PLAN_CHECKSUM = "3456cdef",
  }
  local cfg = runtimeConfig.read({
    source = {
      protocolVersion = 3,
      localProxyEnabled = true,
      maxEpochs = 12,
    },
    environment = function(name) return environment[name] end,
    bridgeMarkerExists = function() return false end,
    bridgeMarkerValue = function() return "waiting" end,
  })
  assert(cfg.protocol == 3 and cfg.startNetwork == true, "injected network configuration was lost")
  assert(cfg.peerId == "player2" and cfg.sessionId == "injected-session",
    "injected peer/session identity was lost")
  assert(cfg.root == "C:/bridge/injected" and cfg.startingCash == 75000000,
    "injected bridge/economy configuration was lost")
  assert(cfg.economyDifficulty == "relaxed"
      and cfg.revenueMultiplierPpm == 2000000,
    "save-owned economy difficulty was not normalized as an exact preset")
  assert(cfg.networkClockRunTicks == 900,
    "injected network clock run window was lost")
  assert(#cfg.startingCompanyPlayerIds == 2
      and cfg.startingCompanyPlayerIds[1] == 9478
      and cfg.startingCompanyPlayerIds[2] == 9479,
    "launcher save-owner identities were not parsed deterministically")
  assert(cfg.localProxy == false, "network mode must disable the local proxy")
  assert(cfg.manualBootstrapReady == false,
    "manual network bootstrap ignored the launcher world-ready boundary")
  assert(cfg.restoreResume and cfg.restoreResume.valid == true
      and cfg.restoreResume.fromSession == "saved-session"
      and cfg.restoreResume.boundarySeq == 7
      and cfg.restoreResume.error == nil,
    "launcher restore attestation was not parsed")
  local armed = runtimeConfig.read({
    source = {},
    environment = function(name) return environment[name] end,
    bridgeMarkerValue = function(_, name)
      return name == "manual-bootstrap-ready" and "ready" or nil
    end,
  })
  assert(armed.manualBootstrapReady == true,
    "manual network bootstrap did not arm after the launcher marker")
end

do
  local versions = { stateVersion = 23, checkpointVersion = 3 }
  local cfg = baseConfig()
  local first = stateSchema.new(cfg, versions)
  local second = stateSchema.new(cfg, versions)
  first.world.logicalOwners.test = "company:1"
  assert(second.world.logicalOwners.test == nil, "new states share mutable nested tables")
  assert(first.version == 23 and first.checkpoint.version == 3,
    "new state did not retain its schema versions")
  assert(first.networkMode == "network" and first.bridge.peerId == "player1",
    "new state did not retain its runtime identity")
  assert(first.match.rules.economyDifficulty == "normal"
      and first.match.rules.revenueMultiplierPpm == 1000000
      and first.economy.params.economyDifficulty == "normal",
    "new state did not bind the selected economy mode into authored state")

  local easy = stateSchema.new(baseConfig({ economyDifficulty = "easy" }), versions)
  assert(easy.match.rules.economyDifficulty == "easy"
      and easy.match.rules.revenueMultiplierPpm == 1500000
      and easy.economy.params.revenueMultiplierPpm == 1500000,
    "non-default world difficulty did not reach both rules and economy state")

  first.version = 7
  first.world.networkClock = nil
  first.probes.operational = nil
  local migrated = stateSchema.migrate(first, {
    newState = function() return stateSchema.new(cfg, versions) end,
    config = function() return cfg end,
    stateVersion = 23,
    checkpointVersion = 3,
  })
  assert(migrated.version == 23 and migrated.world.networkClock.generation == 0,
    "migration did not restore current clock/schema defaults")
  assert(type(migrated.probes.operational.samples) == "table",
    "migration did not restore operational telemetry defaults")

  -- A native save can be taken while a synchronized freight train is between
  -- terminals. Preserve that exact authored load, then preserve the delivered
  -- stock/cursor state on a second load. A partial or edited ledger must be
  -- surfaced instead of silently creating cargo.
  local cargoSave = stateSchema.new(cfg, versions)
  cargoSave.initialized = true
  local function freightRecipe(cid, resource, capacity, stocks, inputs, outputs)
    local recipe = {
      cid = cid, resource = resource, params = { productionLevel = 0 },
      capacity = capacity, stocks = stocks, inputs = inputs, outputs = outputs,
    }
    recipe.recipeDigest = hashModule.value({
      resource = recipe.resource, params = recipe.params, stocks = recipe.stocks,
      inputs = recipe.inputs, outputs = recipe.outputs, capacity = recipe.capacity,
    })
    return recipe
  end
  local sourceCid, sinkCid = "industry:pre:save-source", "industry:pre:save-sink"
  local bootstrap = assert(freightIndustryModelModule.bootstrapAction(
    "edc7a517", 1, {
      freightRecipe(sourceCid, "industry/farm.con", 120, {}, { {} },
        { { cargoType = "GRAIN", amount = 1 } }),
      freightRecipe(sinkCid, "mod/sink.con", 120,
        { { index = 0, cargoType = "GRAIN", stockType = "RECEIVING", moreCapacity = 0 } },
        { { { stockIndex = 0, cargoType = "GRAIN", amount = 1 } } }, {}),
    }))
  assert(freightIndustryModelModule.applyBootstrap(
    cargoSave.world.freightIndustry, bootstrap,
    { ready = true, digest = "edc7a517" }))
  cargoSave.world.freightIndustry.industries[sourceCid].outputStock.GRAIN = 100
  economyModule.upsertMarket(cargoSave.economy, {
    cid = "market:save-cargo", kind = "cargo", demand = 120,
  })
  economyModule.upsertService(cargoSave.economy, {
    lineCid = "line:save-cargo", marketCid = "market:save-cargo",
    companyCid = "company:1", fareCents = 1000, capacity = 40,
    metadata = {
      freightContractSchema = 1, freightContractDigest = "1234abcd",
      sourceIndustryCid = sourceCid, destinationIndustryCid = sinkCid,
      destinationStockIndex = 0, cargoType = "GRAIN",
      sourceStationGroupCid = "station_group:save-source",
      destinationStationGroupCid = "station_group:save-sink",
      sourceStopIndex = 0, destinationStopIndex = 1,
      stationGroupCids = {
        "station_group:save-source", "station_group:save-sink",
      },
      vehicleCids = { "vehicle:save-cargo" }, vehicleCount = 1,
      cargoCapacityPerVehicle = 40,
      cargoCapacityByVehicleCid = { ["vehicle:save-cargo"] = 40 },
      distanceMeters = 10000,
    },
  })
  cargoSave.economy.epoch = 1
  cargoSave.economy.lastResults.markets["market:save-cargo"] = {
    services = { ["line:save-cargo"] = { allocated = 40 } },
  }
  assert(cargoPresentationModule.beginEpoch(
    cargoSave.world.cargoPresentation, cargoSave.economy))
  local loaded, loadResult = cargoPresentationModule.applyRelease(
    cargoSave.world.cargoPresentation, cargoSave.economy,
    cargoSave.world.freightIndustry, {
      type = "vehicle.sync_release", vehicleCid = "vehicle:save-cargo",
      lineCid = "line:save-cargo", round = 1, stopIndex = 0,
    }, { owner = "company:1" })
  assert(loaded and loadResult.aboard == 40, "cargo save fixture did not board")
  cargoSave.world.vehicleSync.vehicles["vehicle:save-cargo"] = {
    vehicleCid = "vehicle:save-cargo", lineCid = "line:save-cargo",
    companyCid = "company:1", lastAuthorizedRound = 1, stopIndex = 0,
    releaseAtGameTime = 100, releaseWhilePaused = false,
    schedule = { schemaVersion = 1, enabled = false },
  }
  local aboardDigest = hashModule.value(
    cargoPresentationModule.digestView(cargoSave.world.cargoPresentation))
  local loadedSave = stateSchema.migrate(util.deepCopy(cargoSave), {
    newState = function() return stateSchema.new(cfg, versions) end,
    config = function() return cfg end,
    stateVersion = 23, checkpointVersion = 3,
  })
  assert(loadedSave.lastError == nil
      and loadedSave.world.cargoPresentation.vehicles["vehicle:save-cargo"].aboard == 40
      and hashModule.value(cargoPresentationModule.digestView(
        loadedSave.world.cargoPresentation)) == aboardDigest,
    "save/load changed authoritative cargo aboard a synchronized train")
  local tamperedCargoSave = util.deepCopy(cargoSave)
  tamperedCargoSave.world.cargoPresentation.vehicles[
    "vehicle:save-cargo"].aboard = 39
  local rejectedCargoSave = stateSchema.migrate(tamperedCargoSave, {
    newState = function() return stateSchema.new(cfg, versions) end,
    config = function() return cfg end,
    stateVersion = 23, checkpointVersion = 3,
  })
  assert(type(rejectedCargoSave.lastError) == "string"
      and rejectedCargoSave.lastError:find("conservation", 1, true),
    "save migration silently accepted a non-conserving cargo ledger")

  local delivered, deliveryResult = cargoPresentationModule.applyRelease(
    loadedSave.world.cargoPresentation, loadedSave.economy,
    loadedSave.world.freightIndustry, {
      type = "vehicle.sync_release", vehicleCid = "vehicle:save-cargo",
      lineCid = "line:save-cargo", round = 2, stopIndex = 1,
    }, { owner = "company:1" })
  assert(delivered and deliveryResult.delivered == 40,
    "loaded cargo could not complete its destination release")
  loadedSave.world.vehicleSync.vehicles["vehicle:save-cargo"].lastAuthorizedRound = 2
  loadedSave.world.vehicleSync.vehicles["vehicle:save-cargo"].stopIndex = 1
  local transport = cargoPresentationModule.economySnapshot(
    loadedSave.world.cargoPresentation)
  assert(freightIndustryModelModule.applyTransportSnapshot(
    loadedSave.world.freightIndustry, transport.lines))
  loadedSave.economy.deliveryCursors["line:save-cargo"] = {
    deliveredCargo = 40,
    earnedRevenueCents = loadedSave.world.cargoPresentation.lines[
      "line:save-cargo"].earnedRevenueCents,
  }
  local deliveredDigest = hashModule.value(
    cargoPresentationModule.digestView(loadedSave.world.cargoPresentation))
  local settledSave = stateSchema.migrate(util.deepCopy(loadedSave), {
    newState = function() return stateSchema.new(cfg, versions) end,
    config = function() return cfg end,
    stateVersion = 23, checkpointVersion = 3,
  })
  assert(settledSave.lastError == nil
      and settledSave.world.freightIndustry.totalDelivered.GRAIN == 40
      and settledSave.economy.deliveryCursors["line:save-cargo"].deliveredCargo == 40
      and hashModule.value(cargoPresentationModule.digestView(
        settledSave.world.cargoPresentation)) == deliveredDigest,
    "save/load changed delivered cargo, destination stock, or revenue cursor")
  local overpaidCargoSave = util.deepCopy(loadedSave)
  overpaidCargoSave.economy.deliveryCursors[
    "line:save-cargo"].deliveredCargo = 41
  local rejectedOverpaidSave = stateSchema.migrate(overpaidCargoSave, {
    newState = function() return stateSchema.new(cfg, versions) end,
    config = function() return cfg end,
    stateVersion = 23, checkpointVersion = 3,
  })
  assert(type(rejectedOverpaidSave.lastError) == "string"
      and rejectedOverpaidSave.lastError:find("economy settlement", 1, true),
    "save migration silently accepted an economy cursor ahead of delivered cargo")

  local legacyEconomy = stateSchema.new(cfg, versions)
  legacyEconomy.economy.version = 5
  legacyEconomy.match.rules.maxEpochs = 24
  legacyEconomy.match.rules.valuationTargetCents = 50000000
  local durationMigrated = stateSchema.migrate(legacyEconomy, {
    newState = function() return stateSchema.new(cfg, versions) end,
    config = function() return cfg end,
    stateVersion = 23,
    checkpointVersion = 3,
  })
  assert(durationMigrated.economy.version == economyModule.VERSION
      and durationMigrated.match.rules.maxEpochs == 288
      and durationMigrated.match.rules.valuationTargetCents == 50000000000
      and durationMigrated.match.rules.economyDifficulty == "normal"
      and durationMigrated.economy.params.revenueMultiplierPpm == 1000000,
    "hourly match duration/value was not preserved across the five-minute migration")

  local preDifficulty = stateSchema.new(baseConfig(), versions)
  preDifficulty.economy.version = 6
  preDifficulty.match.rules.economyDifficulty = nil
  preDifficulty.match.rules.revenueMultiplierPpm = nil
  preDifficulty.economy.params.economyDifficulty = nil
  preDifficulty.economy.params.revenueMultiplierPpm = nil
  local migratedNormal = stateSchema.migrate(preDifficulty, {
    newState = function()
      return stateSchema.new(baseConfig({ economyDifficulty = "relaxed" }), versions)
    end,
    config = function() return baseConfig({ economyDifficulty = "relaxed" }) end,
    stateVersion = 23,
    checkpointVersion = 3,
  })
  assert(migratedNormal.match.rules.economyDifficulty == "normal"
      and migratedNormal.economy.params.revenueMultiplierPpm == 1000000,
    "a pre-difficulty save inherited a machine-local setting instead of migrating to Normal")

  local legacyUnlimited = stateSchema.new(cfg, versions)
  legacyUnlimited.economy.version = 5
  legacyUnlimited.match.rules.maxEpochs = 0
  local unlimitedMigrated = stateSchema.migrate(legacyUnlimited, {
    newState = function() return stateSchema.new(cfg, versions) end,
    config = function() return cfg end,
    stateVersion = 23,
    checkpointVersion = 3,
  })
  assert(unlimitedMigrated.match.rules.maxEpochs == 0,
    "unlimited legacy match acquired a duration during migration")

  local prior = stateSchema.new(baseConfig({ startNetwork = false }), versions)
  prior.initialized = true
  prior.networkMode = "standalone"
  prior.companyOrder = { "company:1", "company:2" }
  prior.companies = {
    ["company:1"] = { cid = "company:1", playerId = 9478 },
    ["company:2"] = { cid = "company:2", playerId = 9479 },
  }
  prior.world.logicalOwners["4184"] = "company:1"
  prior.world.autonomyFrozen = true
  prior.world.lastFreezeResult = {
    freeze = true,
    towns = 2,
    industries = 5,
    errors = {},
  }
  prior.canonical.byCanonical["construction:test"] = {
    canonicalId = "construction:test",
    kind = "construction",
    localId = 9500,
    metadata = { owner = "company:2" },
  }
  local fresh = stateSchema.migrate(prior, {
    newState = function() return stateSchema.new(cfg, versions) end,
    config = function() return cfg end,
    stateVersion = 23,
    checkpointVersion = 3,
  })
  local hints = fresh.world.startingOwnershipHints
  assert(fresh.initialized == false and hints
      and hints.companyPlayerIds[1] == 9478 and hints.companyPlayerIds[2] == 9479
      and hints.logicalOwners["4184"] == "company:1"
      and hints.logicalOwners["9500"] == "company:2"
      and fresh.world.autonomyFrozen == true
      and fresh.world.lastFreezeResult.towns == 2
      and fresh.world.lastFreezeResult.industries == 5
      and fresh.recovery.freshNetworkBootstrap.autonomyFreezePreserved == true
      and fresh.recovery.freshNetworkBootstrap.ownershipHintCompanies == 2
      and fresh.recovery.freshNetworkBootstrap.ownershipHintEntities == 2,
    "fresh network migration discarded validated ownership provenance")

  prior.initialized = false
  prior.world.lastFreezeResult.errors = { "incomplete freeze" }
  prior.world.proposalConsensus.sessionFault = {
    errorCode = "checkpoint-consensus-timeout:player1,player2",
  }
  local cleanRetry = stateSchema.migrate(prior, {
    newState = function() return stateSchema.new(cfg, versions) end,
    config = function() return cfg end,
    stateVersion = 23,
    checkpointVersion = 3,
  })
  assert(cleanRetry.initialized == false
      and cleanRetry.world.autonomyFrozen == false
      and cleanRetry.recovery.freshNetworkBootstrap.autonomyFreezePreserved == false
      and cleanRetry.world.proposalConsensus.sessionFault == nil
      and cleanRetry.recovery.freshNetworkBootstrap ~= nil,
    "a faulted uninitialised state leaked across a new network session")

  local function restoreSource()
    local sourceCfg = baseConfig({ sessionId = "saved-network" })
    local source = stateSchema.new(sourceCfg, versions)
    source.initialized = true
    source.canonical.byCanonical["company:1"] = {
      canonicalId = "company:1", kind = "company", localId = 7,
    }
    source.world.checkpointConsensus.byBoundary["7"] = {
      boundarySeq = 7, status = "complete", success = true,
      coreDigest = "1234abcd", convergenceKey = "2345bcde",
    }
    source.world.checkpointConsensus.lastAgreed =
      util.deepCopy(source.world.checkpointConsensus.byBoundary["7"])
    source.recovery.anchorPreparation = {
      status = "ready", preparationSeq = 6, boundarySeq = 7,
    }
    source.bridge.nextInSeq, source.bridge.nextOutSeq = 9, 11
    return source
  end
  local resumeCfg = baseConfig({
    sessionId = "saved-network-r7",
    restoreResume = {
      requested = true, valid = true, fromSession = "saved-network",
      boundarySeq = 7, coreDigest = "1234abcd",
      convergenceKey = "2345bcde", planChecksum = "3456cdef",
    },
  })
  local resumed = stateSchema.migrate(restoreSource(), {
    newState = function() return stateSchema.new(resumeCfg, versions) end,
    config = function() return resumeCfg end,
    stateVersion = 23, checkpointVersion = 3,
  })
  assert(resumed.initialized == true
      and resumed.canonical.byCanonical["company:1"].localId == 7
      and resumed.bridge.sessionId == "saved-network-r7"
      and resumed.bridge.nextInSeq == 1 and resumed.bridge.nextOutSeq == 1
      and resumed.recovery.restoreResume.status == "validated"
      and resumed.recovery.anchorPreparation == nil
      and next(resumed.world.checkpointConsensus.byBoundary) == nil
      and resumed.world.networkClock.generation == 0,
    "attested restore did not preserve canonical state and reset only bridge identity")

  local refusedCfg = util.deepCopy(resumeCfg)
  refusedCfg.restoreResume.coreDigest = "ffffffff"
  local refused = stateSchema.migrate(restoreSource(), {
    newState = function() return stateSchema.new(refusedCfg, versions) end,
    config = function() return refusedCfg end,
    stateVersion = 23, checkpointVersion = 3,
  })
  assert(refused.initialized == false and refused.recovery.restoreResume.status == "failed"
      and refused.lastError:find("restore refused", 1, true),
    "mismatched restore plan did not fail closed")
end

do
  local status = nativeHook.compactStatus({
    schemaVersion = 4,
    hookVersion = "test",
    active = true,
    validation = { valid = true, signatures = {} },
    hooks = {
      enabled = true,
      buildProposalVisitor = true,
      authorityCommandVisitors = 23,
    },
    gates = {
      buildProposal = { enabled = true, tagMismatches = 0 },
      commandVisitors = { enabled = true, hooked = 23, tagMismatches = 0 },
    },
    commandEvents = {
      { localSequence = 1, tag = 15, name = "BuildProposal", success = false },
      { localSequence = 2, tag = 8, name = "SetLine", success = true },
    },
  })
  assert(status.commandEvents[1].success == false
      and status.commandEvents[2].success == true,
    "native command status erased an explicit false result")
  local ready, boundary = nativeHook.validatedNetworkAuthority(status)
  assert(ready == true and boundary.commandVisitors == 23,
    "validated native authority status was not accepted")
  status.gates.commandVisitors.tagMismatches = 1
  assert(nativeHook.validatedNetworkAuthority(status) == false,
    "ABI-mismatched native authority status was accepted")
end

do
  local first, second = guiState.new(), guiState.new()
  first.queue[1] = { type = "test" }
  assert(#second.queue == 0, "GUI states share their mutable queues")

  local capture = guiCaptureModule.install(first, { proposalCost = function() return 42 end })
  local shaped = capture.eventShape({ z = 2, a = 1 })
  assert(shaped.a == 1 and shaped.z == 2 and shaped.__type == "table",
    "GUI event projection lost a plain deterministic payload")

  local status, details = {}, {}
  function status:setText(value) self.value = value end
  function details:setText(value) self.value = value end
  first.status, first.details = status, details
  guiView.render(first, {
    networkMode = "network",
    peerId = "player1",
    sessionId = "runtime-module-test",
    activeCompanyName = "Company 1",
    match = { status = "running", rules = {} },
    bridge = { companion = { connected = true, status = "connected" } },
    companyOrder = {},
    cargoPresentation = {
      lines = {
        ["line:cargo:a"] = { retired = false },
        ["line:cargo:retired"] = { retired = true },
      },
      totals = { waiting = 17, aboard = 8, capacity = 40, delivered = 29 },
    },
    deliveryCursors = {
      ["line:cargo:a"] = { deliveredCargo = 23, earnedRevenueCents = 456700 },
      ["line:cargo:retired"] = { deliveredCargo = 99, earnedRevenueCents = 999900 },
      ["line:passenger:a"] = { deliveredCargo = 88, earnedRevenueCents = 888800 },
    },
    probes = {
      freightMilestone = {
        aboardCheckpointed = true, aboard = 8, lineCid = "line:cargo:a",
        observedRound = 3,
      },
      passengerMilestone = { aboardCheckpointed = false, stale = true },
    },
  }, { maxDeferredNetworkIntents = 32 })
  assert(status.value:find("Peer: player1", 1, true), "GUI status formatter lost peer identity")
  assert(details.value:find("Session: runtime-module-test", 1, true),
    "GUI detail formatter lost session identity")
  assert(details.value:find(
      "Cargo proof: 1 active lines | 17 waiting | 8/40 aboard | 29 delivered | 23 settled / $4567.00",
      1, true),
    "GUI did not expose authored cargo progress and settled evidence")
  assert(details.value:find(
      "Automatic load receipts: freight PROVED 8 on line:cargo:a round 3 | local passenger stale witness; waiting to retry",
      1, true),
    "GUI did not expose automatic passenger/cargo proof progress")

  -- The panel must present the model as the contest and native agents as
  -- scenery, so a player never has to infer which layer is authoritative.
  guiView.render(first, {
    networkMode = "network",
    peerId = "player1",
    sessionId = "runtime-module-test",
    activeCompanyName = "Company 1",
    match = { status = "running", rules = {} },
    bridge = { companion = { connected = true, status = "connected" } },
    companyOrder = {},
    lastResults = { markets = { ["market:x"] = {
      name = "Alpha to Beta", demand = 1000, outside = 400,
      services = { ["line:a"] = {
        name = "Alpha Express", allocated = 480, revenueCents = 480000,
        sharePpm = 480000, equilibriumPpm = 560000,
        factors = { gcCents = 1312, fareCents = 1000, timeCostCents = 300,
          waitCostCents = 112, transferCostCents = 0, crowdCostCents = 0,
          comfortCents = 100 },
      } },
    } } },
    probes = { mobility = { totalPersons = 413, totals = {} } },
  }, { maxDeferredNetworkIntents = 32 })
  assert(details.value:find("platforms are scenery", 1, true),
    "the market section did not frame itself as the contest")
  assert(details.value:find("600 of 1000 travelling", 1, true),
    "the market line did not report induced travel in player terms")
  assert(details.value:find("480 carried", 1, true)
      and details.value:find("GAINING", 1, true),
    "the service line did not report carried passengers and its trend")
  assert(details.value:find("costs the passenger $13.12", 1, true),
    "the generalized-cost breakdown lost its legible framing")
  assert(details.value:find("Native agents (scenery, not scored)", 1, true),
    "native agent counts were not demoted to labelled diagnostics")
end

do
  local model = economyModule.newState()
  economyModule.upsertMarket(model, {
    cid = "market:digest", name = "Digest market", demand = 1000,
    votCentsPerHour = 450, gcOutsideCents = 2500, thetaCents = 250,
    metadata = { townA = "town:digest:a", townB = "town:digest:b",
      townSizeA = 80, townSizeB = 120, corridorMeters = 3000 },
  })
  economyModule.upsertService(model, {
    lineCid = "line:digest", marketCid = "market:digest", companyCid = "company:1",
    name = "Digest service", headwaySeconds = 900, journeySeconds = 2400,
    fareCents = 1000, capacity = 600, quality = 100, transfers = 0,
  })
  economyModule.evaluateAll(model)
  local current = {
    initialized = true,
    match = { status = "running", rules = {} },
    companies = { ["company:1"] = { cid = "company:1", name = "Company 1" } },
    companyOrder = { "company:1" },
    economy = model,
    finance = financeModule.newState(),
    world = {
      autonomyFrozen = true,
      townDevelopment = {
        schemaVersion = 1, enabled = true,
        points = { ["town:digest"] = 7 },
        cursor = { ["town:digest"] = 3 },
      },
    },
  }
  local runtime = checkpointRuntimeModule.new({
    getState = function() return current end,
    maxEvents = function() return 100 end,
    stateVersion = 23,
    checkpointVersion = 3,
    eventRecordVersion = 1,
  })
  local original = util.deepCopy(model)
  local baseline = runtime.authoredDigest()
  current.world.townDevelopment.points["town:digest"] = 8
  assert(runtime.authoredDigest() ~= baseline,
    "authored digest hides town-development point remainder")
  current.world.townDevelopment.points["town:digest"] = 7
  current.world.townDevelopment.cursor["town:digest"] = 4
  assert(runtime.authoredDigest() ~= baseline,
    "authored digest hides town-development position cursor")
  current.world.townDevelopment.cursor["town:digest"] = 3
  local mutations = {
    { "params.alphaUpPm", function(value) value.params.alphaUpPm = value.params.alphaUpPm + 1 end },
    { "params.alphaDownPm", function(value) value.params.alphaDownPm = value.params.alphaDownPm + 1 end },
    { "params.maxWaitSeconds", function(value) value.params.maxWaitSeconds = value.params.maxWaitSeconds + 1 end },
    { "params.transferSeconds", function(value) value.params.transferSeconds = value.params.transferSeconds + 1 end },
    { "params.crowdThresholdPpm", function(value) value.params.crowdThresholdPpm = value.params.crowdThresholdPpm + 1 end },
    { "params.economyDifficulty", function(value) value.params.economyDifficulty = "easy" end },
    { "params.revenueMultiplierPpm", function(value) value.params.revenueMultiplierPpm = 1500000 end },
    { "market.name", function(value) value.markets["market:digest"].name = "Other" end },
    { "market.demand", function(value) value.markets["market:digest"].demand = 1001 end },
    { "market.votCentsPerHour", function(value) value.markets["market:digest"].votCentsPerHour = 451 end },
    { "market.gcOutsideCents", function(value) value.markets["market:digest"].gcOutsideCents = 2501 end },
    { "market.thetaCents", function(value) value.markets["market:digest"].thetaCents = 251 end },
    { "market.demandResid", function(value) value.markets["market:digest"].demandResid = value.markets["market:digest"].demandResid + 1 end },
    { "town.size", function(value) value.towns["town:digest:a"].size = value.towns["town:digest:a"].size + 1 end },
    { "town.growthResid", function(value) value.towns["town:digest:a"].growthResid = value.towns["town:digest:a"].growthResid + 1 end },
    { "service.marketCid", function(value) value.services["line:digest"].marketCid = "market:other" end },
    { "service.companyCid", function(value) value.services["line:digest"].companyCid = "company:2" end },
    { "service.name", function(value) value.services["line:digest"].name = "Other" end },
    { "service.headwaySeconds", function(value) value.services["line:digest"].headwaySeconds = 901 end },
    { "service.journeySeconds", function(value) value.services["line:digest"].journeySeconds = 2401 end },
    { "service.fareCents", function(value) value.services["line:digest"].fareCents = 1001 end },
    { "service.capacity", function(value) value.services["line:digest"].capacity = 601 end },
    { "service.quality", function(value) value.services["line:digest"].quality = 101 end },
    { "service.transfers", function(value) value.services["line:digest"].transfers = 1 end },
    { "service.enabled", function(value) value.services["line:digest"].enabled = false end },
    { "service.sharePpm", function(value) value.services["line:digest"].sharePpm = value.services["line:digest"].sharePpm + 1 end },
    { "service.shareResid", function(value) value.services["line:digest"].shareResid = value.services["line:digest"].shareResid + 1 end },
    { "service.lagLoadPpm", function(value) value.services["line:digest"].lagLoadPpm = value.services["line:digest"].lagLoadPpm + 1 end },
    { "service.lastFareCents", function(value) value.services["line:digest"].lastFareCents = value.services["line:digest"].lastFareCents + 1 end },
    { "service.capacityResid", function(value) value.services["line:digest"].capacityResid = value.services["line:digest"].capacityResid + 1 end },
    { "service.revenueMultiplierResid", function(value) value.services["line:digest"].revenueMultiplierResid = value.services["line:digest"].revenueMultiplierResid + 1 end },
    { "service.metadata", function(value) value.services["line:digest"].metadata = {
      stationGroupCids = { "station_group:digest:a", "station_group:digest:b" },
    } end },
  }
  for _, mutation in ipairs(mutations) do
    current.economy = util.deepCopy(original)
    mutation[2](current.economy)
    assert(runtime.authoredDigest() ~= baseline,
      "authored digest hides evaluator input " .. mutation[1])
  end
  current.economy = model
end

do
  local priorApi = api
  api = { type = { ComponentType = { TRANSPORT_VEHICLE = "TRANSPORT_VEHICLE" } } }
  local transportVehicle = {
    line = 50, state = 1, stopIndex = 0, userStopped = false,
  }
  local currentTime, currentSpeed = 10, 1
  local emitted, commands = {}, {}
  local current = {
    networkMode = "network",
    initialized = true,
    tick = 1,
    bridge = { peerId = "player1" },
    canonical = {
      byCanonical = {
        ["line:event:test:1"] = {
          canonicalId = "line:event:test:1", kind = "line", localId = 50, metadata = {},
        },
        ["vehicle:event:test:1"] = {
          canonicalId = "vehicle:event:test:1", kind = "vehicle", localId = 60,
          -- A pinned starting-save vehicle has no operation-authored lineCid;
          -- the runtime must derive its canonical line from the local mapping.
          metadata = { owner = "company:1" },
        },
      },
      byLocal = { ["line:50"] = "line:event:test:1" },
    },
    world = {
      vehicleSync = {
        schemaVersion = 2, enabled = true, vehicles = {},
        scheduleReservations = {
          ["line:event:test:1#0"] = {
            lineCid = "line:event:test:1", stopIndex = 0,
            periodSeconds = 60, phaseSeconds = 5,
            lastSlotIndex = 1, lastScheduledDepartureAt = 65,
          },
        },
      },
    },
    economy = {
      services = {
        ["line:event:test:1"] = {
          lineCid = "line:event:test:1",
          enabled = true,
          headwaySeconds = 60,
          journeySeconds = 120,
          metadata = { carrier = "ROAD", stationGroupCids = {
            "station_group:test:1", "station_group:test:middle", "station_group:test:2",
          } },
        },
      },
    },
    probes = {
      vehicleSync = {
        managed = 0, held = 0, released = 0, faults = 0,
        reports = 0, reportedReleases = {},
      },
    },
  }
  local runtime = vehicleSyncRuntimeModule.new({
    getState = function() return current end,
    diagnosticLog = function() end,
    component = function(localId)
      if localId == 60 then return transportVehicle end
    end,
    clockSnapshot = function()
      return { time = currentTime, gameSpeed = currentSpeed }
    end,
    commandFactory = function(name)
      assert(name == "setUserStopped")
      return function(localId, stopped) return { localId = localId, stopped = stopped } end
    end,
    authorizeCommand = function(tag) return tag == 8 end,
    sendCommand = function(command, callback)
      commands[#commands + 1] = util.deepCopy(command)
      transportVehicle.userStopped = command.stopped
      callback(command, true)
      return true
    end,
    emit = function(kind, payload)
      emitted[#emitted + 1] = { kind = kind, payload = util.deepCopy(payload) }
      return true, { local_seq = #emitted }
    end,
  })
  runtime.update()
  assert(#commands == 0, "en-route synchronized vehicle was mutated")
  transportVehicle.state = 2
  current.tick = 2
  runtime.update()
  assert(#commands == 1 and commands[1].stopped == true
      and emitted[1].payload.state == "held" and emitted[1].payload.round == 1,
    "first terminal arrival was not held and reported")
  local policy = emitted[1].payload.schedule
  assert(policy.enabled == false,
    "registered service headway leaked into physical station synchronization")
  local promptDeparture = currentTime + 10
  local releaseOk = runtime.applyRelease({
    type = "vehicle.sync_release",
    vehicleCid = "vehicle:event:test:1",
    lineCid = "line:event:test:1",
    round = 1,
    stopIndex = 0,
    releaseAtGameTime = promptDeparture,
    releaseWhilePaused = false,
    schedule = { schemaVersion = 1, enabled = false },
  })
  assert(releaseOk == true, "ordered station release was rejected")
  currentTime, currentSpeed, current.tick = promptDeparture - 1, 0, 3
  runtime.update()
  assert(#commands == 1,
    "paused vehicle released before its canonical prompt departure")
  currentTime, current.tick = promptDeparture, 4
  runtime.update()
  assert(#commands == 2 and commands[2].stopped == false
      and emitted[#emitted].payload.state == "released",
    "vehicle did not release/report at the ordered target")
  local digestView = vehicleSyncRuntimeModule.digestView(current.world)
  assert(digestView.schemaVersion == 4
      and digestView.vehicles[1].lastAuthorizedRound == 1
      and digestView.vehicles[1].stopIndex == 0
      and digestView.vehicles[1].schedule.enabled == false
      and #digestView.scheduleReservations == 0
      and digestView.passengerPresentation.schemaVersion == 2
      and digestView.passengerPresentation.vehicles[1].vehicleCid
        == "vehicle:event:test:1"
      and digestView.passengerPresentation.vehicles[1].lastRound == 1
      and digestView.cargoPresentation.schemaVersion == 1,
    "prompt vehicle release/presentation ledgers are absent from the convergence view")
  transportVehicle.state, current.tick = 1, 5
  runtime.update()
  transportVehicle.state, transportVehicle.stopIndex, current.tick = 2, 1, 6
  runtime.update()
  assert(#commands == 2 and current.probes.vehicleSync.passThroughStops == 1,
    "an intermediate road stop created an unnecessary all-peer station round")
  assert(vehicleSyncStateModule.synchronizesStop(current.economy,
      "line:event:test:1", 0)
      and not vehicleSyncStateModule.synchronizesStop(current.economy,
        "line:event:test:1", 1)
      and vehicleSyncStateModule.synchronizesStop(current.economy,
        "line:event:test:1", 2),
    "road/tram endpoint synchronization policy is inconsistent")
  transportVehicle.state, current.tick = 1, 7
  runtime.update()
  current.economy.services["line:event:test:1"] = nil
  transportVehicle.state, transportVehicle.stopIndex, current.tick = 2, 1, 8
  runtime.update()
  assert(commands[#commands].stopped == true
      and emitted[#emitted].payload.round == 2
      and emitted[#emitted].payload.stopIndex == 1
      and emitted[#emitted].payload.schedule.enabled == false,
    "ordinary line did not advance with synchronization-only release policy")
  transportVehicle.state, current.tick = 1, 9
  runtime.update()
  assert(emitted[#emitted].payload.state == "fault"
      and current.probes.vehicleSync.faults == 1,
    "departure before authority release did not fault closed")
  api = priorApi
end

do
  local gameTime, busy = 159, false
  local submitted, diagnostics = {}, {}
  local current = {
    initialized = true,
    match = { status = "running" },
    networkMode = "network",
    bridge = { peerId = "player1", companion = { connected = true } },
    tick = 1,
    economy = economyModule.newState(),
  }
  economyModule.startScheduler(current.economy, 100, 60)
  local runtime = economyClockRuntimeModule.new({
    getState = function() return current end,
    submitIntent = function(action)
      submitted[#submitted + 1] = util.deepCopy(action)
      return true, { queued = true }
    end,
    localWorkState = function()
      return { pending = busy, barrierReason = busy and "test-barrier" or nil }
    end,
    diagnosticLog = function(kind, payload)
      diagnostics[#diagnostics + 1] = { kind = kind, payload = util.deepCopy(payload) }
    end,
    clockSnapshot = function() return { time = gameTime } end,
  })
  local ok, reason = runtime.update()
  assert(ok == false and reason == "not-due" and #submitted == 0,
    "economy clock submitted before its accounting boundary")
  gameTime, busy, current.tick = 160, true, 2
  ok, reason = runtime.update()
  assert(ok == false and reason == "test-barrier" and #submitted == 0,
    "economy clock crossed an active authority barrier")
  busy, current.tick = false, 3
  ok = runtime.update()
  assert(ok == true and #submitted == 1
      and submitted[1].type == "economy.settle"
      and submitted[1].scheduled == true
      and submitted[1].boundaryGameTimeSeconds == 160,
    "host did not submit the exact due economy boundary")
  current.tick = 4
  ok, reason = runtime.update()
  assert(ok == false and reason == "submitted" and #submitted == 1,
    "pending economy boundary was submitted more than once")
  -- A peer loss clears the stale submission without needing an engine tick;
  -- reconnect may therefore retry the still-due boundary while paused.
  current.bridge.companion.connected = false
  ok, reason = runtime.update()
  assert(ok == false and reason == "peer-disconnected" and #submitted == 1,
    "economy clock emitted settlement work while a peer was disconnected")
  current.bridge.companion.connected = true
  ok, reason = runtime.update()
  assert(ok == true and #submitted == 2
      and submitted[2].boundaryGameTimeSeconds == 160,
    "reconnected economy boundary did not retry while simulation ticks were paused")
  assert(diagnostics[#diagnostics - 1]
      and diagnostics[#diagnostics - 1].kind == "economy-clock-peer-disconnected",
    "paused economy retry did not explain why its stale submission was cleared")
  economyModule.evaluateAll(current.economy, 160)
  gameTime, current.tick = 220, 5
  current.bridge.peerId = "player2"
  ok, reason = runtime.update()
  assert(ok == false and reason == "host-only" and #submitted == 2,
    "a client attempted to author an economy settlement")
  assert(diagnostics[1] and diagnostics[1].kind == "economy-clock-submit",
    "automatic economy submission was not observable")
end

do
  local previousApi = rawget(_G, "api")
  local maintenanceById = { [41] = 900000, [42] = 600000 }
  api = {
    type = { ComponentType = { MAINTENANCE_COST = "MAINTENANCE_COST" } },
    engine = { getComponent = function(localId, componentType)
      if componentType == "MAINTENANCE_COST" and maintenanceById[localId] then
        return { maintenanceCost = maintenanceById[localId] }
      end
    end },
  }
  local current = {
    economy = economyModule.newState(),
    canonical = { byCanonical = {} },
    companies = {},
    world = {},
  }
  local runtime = economyAssetCostRuntimeModule.new({
    getState = function() return current end,
  })
  current.canonical.byCanonical["edge:new:1"] = { metadata = { private = true } }
  local build = {
    companyCid = "company:1",
    localInputs = {},
    result = { outputs = { { cid = "edge:new:1", kind = "edge" } } },
  }
  local first = runtime.recordProposal(build, -100)
  assert(first.spendCents == 10000 and first.addedCapitalCents == 10000
      and current.canonical.byCanonical["edge:new:1"].metadata.capitalCostCents == 10000
      and current.economy.companyCosts["company:1"].infrastructureCapitalCents == 10000,
    "private proposal spend was not added to its canonical capital basis")
  assert(runtime.recordProposal(build, -100) == nil,
    "proposal capital was recorded twice")

  current.canonical.byCanonical["edge:new:2"] = { metadata = { private = true } }
  local replacement = {
    companyCid = "company:1",
    localInputs = { { cid = "edge:new:1", capitalCostCents = 10000 } },
    result = { outputs = { { cid = "edge:new:2", kind = "edge" } } },
  }
  local second = runtime.recordProposal(replacement, -50)
  assert(second.retiredCapitalCents == 10000 and second.addedCapitalCents == 15000
      and current.economy.companyCosts["company:1"].infrastructureCapitalCents == 15000,
    "replacement failed to carry old capital plus new authoritative spend")
  local demolition = {
    companyCid = "company:1",
    localInputs = { { cid = "edge:new:2", capitalCostCents = 15000 } },
    result = { outputs = {} },
  }
  local removed = runtime.recordProposal(demolition, 20)
  assert(removed.addedCapitalCents == 0
      and current.economy.companyCosts["company:1"].infrastructureCapitalCents == 0,
    "demolition did not retire the canonical infrastructure cost basis")

  current.canonical.byCanonical["vehicle:new:1"] = {
    kind = "vehicle", localId = 41, metadata = {},
  }
  assert(runtime.recordVehicle({ result = { outputs = {} } }, -1) == nil,
    "malformed operation record reached vehicle costing")
  local purchase = {
    companyCid = "company:1",
    transaction = { kind = "vehicle.buy" },
    result = { outputs = { { cid = "vehicle:new:1", kind = "vehicle" } } },
    completion = { postcondition = { annualMaintenanceDollars = 900000 } },
  }
  local vehicle = runtime.recordVehicle(purchase, -7200000)
  assert(vehicle.purchasePriceDollars == 7200000
      and vehicle.annualVehicleUpkeepCents == 90000000
      and current.economy.vehicleCosts["vehicle:new:1"].annualVehicleUpkeepCents
        == 90000000
      and current.canonical.byCanonical["vehicle:new:1"].metadata.vehicleCostSource
        == "consensus-native-maintenance",
    "resolved native maintenance did not become the vehicle's authored upkeep")

  maintenanceById[41] = 750000
  local replacement = runtime.recordVehicle({
    companyCid = "company:1",
    transaction = { kind = "vehicle.replace", data = { targetCid = "vehicle:new:1" } },
    result = { postcondition = { annualMaintenanceDollars = 750000 } },
  }, -500000)
  assert(replacement.purchasePriceDollars == 7200000
      and replacement.annualVehicleUpkeepCents == 75000000
      and current.canonical.byCanonical["vehicle:new:1"].metadata.purchasePriceDollars == 7200000,
    "vehicle replacement did not refresh upkeep while retaining original capital history")

  current.canonical.byCanonical["vehicle:pre:2"] = {
    kind = "vehicle", localId = 42, metadata = { owner = "company:2" },
  }
  local backfill = runtime.backfillVehicles()
  assert(backfill.priced == 1
      and current.economy.vehicleCosts["vehicle:pre:2"].annualVehicleUpkeepCents == 60000000
      and current.canonical.byCanonical["vehicle:pre:2"].metadata.vehicleCostSource
        == "manifest-native-maintenance",
    "manifest-bound pre-existing vehicle did not receive its native upkeep")

  local sold = runtime.recordVehicle({
    companyCid = "company:1",
    transaction = { kind = "vehicle.sell", data = { targetCid = "vehicle:new:1" } },
  }, 1000000)
  assert(sold.removed == true and current.economy.vehicleCosts["vehicle:new:1"] == nil,
    "sold vehicle continued accruing authored upkeep")
  api = previousApi
end

print("PASS runtime config/state, proposal, intent, clock, validation, native authority, and GUI module boundaries")
