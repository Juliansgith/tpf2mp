local project = assert(arg[1], "project root argument required"):gsub("\\", "/")
package.path = project .. "/tpf2_mp_1/res/scripts/?.lua;" .. package.path
local util = require "tpf2_mp/util"
local json = require "tpf2_mp/json"

local sentEvents = {}
local enabled = {}
local textViews = {}
local guiById = {}
local nativeCommandObserver = nil
local nativeBuildGate = {
  enabled = true, authorizations = 0, allowed = 0, suppressed = 0,
  suppressedQueue = { queued = 0, captured = 0, consumed = 0, dropped = 0 },
  factoryCapture = { dropped = 0 },
}
local nativeBuildFastVersion = 1
local nativeBuildGeneration = 0
local nativeBuildDropped = 0
local nativeBuildArmedCorrelation = 0
local nativeBuildEvents = {}
local nativeFactoryCaptures = {}
local nativeSpeedRequests = {}
local nativeLineCommands = {}
local nativeVehicleCommands = {}
local authorizedCommandTags = {}
local issuedCanonicalCommands = {}
local lineEntities = {}
local lineEnumerations = 0
local nativeStatusReads = 0
local gameEntityReads = 0
local lineComponentReads = 0

tpf2mp_native_status = function()
  nativeStatusReads = nativeStatusReads + 1
  return {
    schemaVersion = 1,
    hookVersion = "0.20.0",
    active = true,
    validation = { valid = true, signatures = {} },
    hooks = {
      enabled = true,
      buildProposalVisitor = true,
      makeBuildProposal = true,
      commandListAdd = true,
      authorityCommandVisitors = 31,
      sendCommandWrapping = true,
    },
    gates = {
      buildProposal = nativeBuildGate,
      commandVisitors = { enabled = true, hooked = 31, tagMismatches = 0 },
    },
  }
end

tpf2mp_native_build_gate_sample = function()
  if nativeBuildFastVersion == 2 then
    return table.concat({
      "B2", nativeBuildGate.enabled and "1" or "0",
      tostring(nativeBuildGate.suppressed or 0),
      tostring(nativeBuildGate.tagMismatches or 0),
      tostring(nativeBuildGeneration), tostring(#nativeBuildEvents),
      tostring(nativeBuildDropped),
      tostring(nativeBuildArmedCorrelation),
    }, "|")
  end
  return table.concat({
    "B1", nativeBuildGate.enabled and "1" or "0",
    tostring(nativeBuildGate.suppressed or 0),
    tostring(nativeBuildGate.tagMismatches or 0),
  }, "|")
end

tpf2mp_native_arm_build_correlation = function(value)
  nativeBuildArmedCorrelation = assert(tonumber(value))
end

tpf2mp_native_take_suppressed_build = function()
  if #nativeBuildEvents == 0 then return nil end
  return table.remove(nativeBuildEvents, 1)
end
tpf2mp_native_take_build_factory_capture = function()
  if #nativeFactoryCaptures == 0 then return nil end
  return table.remove(nativeFactoryCaptures, 1)
end

tpf2mp_native_set_command_observer = function(callback)
  assert(type(callback) == "function", "native observer setter did not receive a function")
  nativeCommandObserver = callback
end

tpf2mp_native_take_suppressed_game_speed = function()
  if #nativeSpeedRequests == 0 then return nil end
  return table.remove(nativeSpeedRequests, 1)
end

tpf2mp_native_take_suppressed_line_command = function()
  if #nativeLineCommands == 0 then return nil end
  return table.remove(nativeLineCommands, 1)
end

tpf2mp_native_take_suppressed_vehicle_command = function()
  if #nativeVehicleCommands == 0 then return nil end
  return table.remove(nativeVehicleCommands, 1)
end

tpf2mp_native_authorize_command = function(tag)
  authorizedCommandTags[#authorizedCommandTags + 1] = tonumber(tag)
  return true
end
tpf2mp_native_revoke_command = function() return true end

local function object(methods)
  methods = methods or {}
  return setmetatable(methods, { __index = function() return function() end end })
end

local TextView = {
  new = function(text)
    local view = object({ text = text or "", visible = true, name = "TextView" })
    function view:setText(value) self.text = tostring(value) end
    function view:setId(id) self.id = id; guiById[id] = self end
    function view:setTooltip(value) self.tooltip = tostring(value) end
    function view:setVisible(value) self.visible = value == true end
    function view:getName() return self.name end
    function view:setName(value) self.name = tostring(value) end
    textViews[#textViews + 1] = view
    return view
  end,
}

local Button = {
  new = function()
    local value = object()
    function value:onClick(callback) self.callback = callback end
    return value
  end,
}

local Component = {
  new = function(id)
    local value = object({ id = id, name = id, visible = true })
    guiById[id] = value
    function value:setLayout(layout) self.layout = layout end
    function value:getLayout() return self.layout end
    function value:getName() return self.name end
    function value:setName(name) self.name = name end
    function value:getId() return self.id end
    function value:getParent() return self.parent end
    function value:setId(newId) self.id = newId; guiById[newId] = self end
    function value:setTooltip(text) self.tooltip = tostring(text) end
    function value:setVisible(visible) self.visible = visible end
    return value
  end,
}

local Window = {
  new = function(title, root)
    local value = object({ title = title, root = root })
    function value:setVisible(visible) self.visible = visible end
    return value
  end,
}

local BoxLayout = {
  new = function(direction)
    local value = object({ direction = direction, items = {} })
    function value:addItem(item) self.items[#self.items + 1] = item end
    function value:insertItem(item, index) table.insert(self.items, index + 1, item) end
    function value:getNumItems() return #self.items end
    function value:getItem(index) return self.items[index + 1] end
    return value
  end,
}

local gameInfoLayout = BoxLayout.new("HORIZONTAL")
guiById["gameInfo.layout"] = gameInfoLayout

game = {
  config = {
    tpf2mp = {
      protocolVersion = 1,
      peerId = "player1",
      sessionId = "gui-test",
      bridgeDir = ".",
      updateStride = 15,
      maxEvents = 64,
      startNetwork = false,
      localProxyEnabled = true,
      pauseOnSwitch = true,
    },
  },
  gui = {
    setEnabled = function(id, value) enabled[id] = value end,
  },
  interface = {
    getPlayer = function() return 100 end,
    getEntity = function(id)
      gameEntityReads = gameEntityReads + 1
      if id == 100 then return { id = 100, type = "PLAYER", balance = 10000000, loan = 10000000 } end
      return nil
    end,
    getTowns = function() return {} end,
    getLines = function() return {} end,
    getVehicles = function() return {} end,
    getDepots = function() return {} end,
    sendScriptEvent = function(id, name, param)
      sentEvents[#sentEvents + 1] = { id = id, name = name, param = param }
    end,
  },
}

api = {
  res = {
    modelRep = {
      find = function(name)
        return ({
          ["vehicle/train/db_v100_v2.mdl"] = 17,
          ["vehicle/waggon/open_1910.mdl"] = 18,
        })[name] or -1
      end,
      get = function(id)
        local loadConfigCount = id == 18 and 4 or 1
        local loadConfigs = {}
        for index = 1, loadConfigCount do loadConfigs[index] = {} end
        return { metadata = { transportVehicle = {
          compartments = { { loadConfigs = loadConfigs } },
        } } }
      end,
    },
  },
  gui = {
    comp = { TextView = TextView, Button = Button, Component = Component, Window = Window },
    layout = { BoxLayout = BoxLayout },
    util = { getById = function(id) return guiById[id] end },
  },
  type = {
    ComponentType = {
      NAME = "NAME", LINE = "LINE", TRANSPORT_VEHICLE = "TRANSPORT_VEHICLE",
      VEHICLE_DEPOT = "VEHICLE_DEPOT", CONSTRUCTION = "CONSTRUCTION",
      STATION_GROUP = "STATION_GROUP", STATION = "STATION", BASE_EDGE = "BASE_EDGE",
      BASE_NODE = "BASE_NODE", SIM_BUILDING = "SIM_BUILDING", TOWN = "TOWN",
      PLAYER = "PLAYER", PLAYER_OWNED = "PLAYER_OWNED",
    },
    JournalEntryCategory = { new = function() return {} end },
    JournalEntry = { new = function() return {} end },
    Line = { new = function() return {} end },
    Vec3f = { new = function(r, g, b) return { r = r, g = g, b = b } end },
  },
  engine = {
    entityExists = function() return false end,
    getComponent = function(id, componentType)
      if componentType == "LINE" then lineComponentReads = lineComponentReads + 1 end
      if componentType == "LINE" and (id == 700 or id == 702 or lineEntities[id]) then
        return { stops = {} }
      end
      if componentType == "PLAYER_OWNED" then
        if id == 700 or id == 799 then return { player = 100 } end
        if id == 701 or id == 702 then return { player = 101 } end
      end
      return nil
    end,
    forEachEntityWithComponent = function(callback, componentType)
      if componentType == "LINE" then
        lineEnumerations = lineEnumerations + 1
        for entity in pairs(lineEntities) do callback(entity) end
      end
    end,
    system = {
      lineSystem = { getLines = function() return {} end },
      transportVehicleSystem = { getLineVehicles = function() return {} end },
      townBuildingSystem = { getLandUsePersonCapacities = function() return { 100, 100, 100 } end },
      stationSystem = { getStation2TownMap = function() return {} end },
      stationGroupSystem = { getStationGroup = function() return nil end },
    },
  },
  cmd = {
    make = {
      buyVehicle = function() end,
      createLine = function(name, color, player, line)
        return { kind = "create-line", name = name, color = color, player = player, line = line }
      end,
      sendScriptEvent = function() error("documented interface bridge should be preferred") end,
      setLine = function() end,
      updateLine = function() end,
    },
    sendCommand = function(command, callback)
      issuedCanonicalCommands[#issuedCanonicalCommands + 1] = command
      if command and command.kind == "create-line" then lineEntities[800] = true end
      if callback then callback(command, true) end
      return true
    end,
  },
}

assert(loadfile(project .. "/tpf2_mp_1/res/config/game_script/tpf2_mp.lua"))()
local script = assert(data())
script.load(nil)
script.guiInit()
assert(type(nativeCommandObserver) == "function", "GUI did not register the native pre-issue observer")
script.guiUpdate()
script.guiUpdate()

assert(#sentEvents == 2, "GUI did not send its capability report and initial snapshot request")
assert(sentEvents[1].id == "tpf2mp" and sentEvents[1].name == "intent", "GUI capability report used the wrong script-event envelope")
assert(sentEvents[1].param.type == "probe.gui_capabilities", "GUI did not report its Lua-state capabilities")
assert(sentEvents[1].param.capabilities.sendCommand == true, "GUI command capability was not detected")
assert(sentEvents[1].param.capabilities.buyVehicle == true, "GUI vehicle factory capability was not detected")
assert(sentEvents[1].param.capabilities.createLine == true, "GUI line factory capability was not detected")
assert(sentEvents[1].param.capabilities.setVehicleLine == true, "GUI vehicle-line factory capability was not detected")
assert(sentEvents[1].param.capabilities.updateLine == true, "GUI line-update factory capability was not detected")
assert(sentEvents[1].param.capabilities.buildProposal == false, "missing GUI proposal factory was misreported")
assert(sentEvents[1].param.capabilities.nativeCommandObserverApi == true, "native observer API was not reported")
assert(sentEvents[1].param.capabilities.nativeGameSpeedCaptureApi == true,
  "native game-speed capture API was not reported")
assert(sentEvents[1].param.capabilities.nativeLineCommandCaptureApi == true,
  "native line-command capture API was not reported")
assert(sentEvents[1].param.capabilities.nativeVehicleCommandCaptureApi == true,
  "native vehicle-command capture API was not reported")
assert(sentEvents[1].param.capabilities.nativeCommandRevoke == true,
  "native command-authorization revocation API was not reported")
assert(sentEvents[1].param.capabilities.nativeBuildCorrelationApi == true,
  "native build-correlation API was not reported")
assert(sentEvents[2].id == "tpf2mp" and sentEvents[2].name == "snapshot.request", "GUI used the wrong snapshot envelope")

nativeCommandObserver({
  proposal = {
    streetProposal = {
      addedSegments = { { entity = 77, playerOwned = { player = 101 } } },
    },
  },
})
script.guiUpdate()
local nativeProposalEvent = sentEvents[#sentEvents]
assert(nativeProposalEvent.param.observation == "native.sendCommand.buildProposal",
  "native pre-issue observer did not queue a BuildProposal observation")
assert(nativeProposalEvent.param.proposalSnapshot.proposal.streetProposal.addedSegments["1"].playerOwned.player == 101,
  "native pre-issue observer lost ownership proposal fields")

nativeCommandObserver({ vehicle = 501, line = 601, shouldDepart = true })
script.guiUpdate()
local nativeVehicleEvent = sentEvents[#sentEvents]
assert(nativeVehicleEvent.param.observation == "native.sendCommand.command"
  and nativeVehicleEvent.param.commandOrigin == "unmarked-player-or-engine",
  "non-build native command was not captured with a conservative origin")
assert(nativeVehicleEvent.param.eventShape.vehicle == 501
  and nativeVehicleEvent.param.eventShape.line == 601
  and nativeVehicleEvent.param.eventShape.shouldDepart == true,
  "line/vehicle command envelope lost its bounded fields")

local signalMatrix = { 1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1, 0, 456, 789, 12, 1 }
local signalMatrixProxy = newproxy(true)
getmetatable(signalMatrixProxy).__index = function(_, key) return signalMatrix[key] end
script.guiHandleEvent("streetBuilder", "builder.proposalCreate", {
  data = { costs = 1234 },
  proposal = {
    toAdd = { { fileName = "station/test.con" } },
    proposal = {
      edgeObjectsToAdd = { {
        category = 0,
        position = { x = 12, y = 34 },
        modelInstance = { modelId = 2014, transf = signalMatrixProxy },
      } },
      removedSegments = {
        { entity = 77, type = 1, comp = { node0 = 10, node1 = 11 } },
      },
    },
    opaque = io.stdout,
  },
})
script.guiUpdate()
local proposalEvent = sentEvents[#sentEvents]
assert(proposalEvent.param.type == "native.observed", "pre-commit proposal probe was not queued")
assert(proposalEvent.param.proposalSnapshot.toAdd["1"].fileName == "station/test.con", "proposal snapshot lost nested construction data")
assert(proposalEvent.param.proposalSnapshot.proposal.edgeObjectsToAdd["1"].position.x == 12, "proposal snapshot depth was insufficient")
assert(proposalEvent.param.proposalSnapshot.proposal.edgeObjectsToAdd["1"]
    .modelInstance.transf[13] == 456,
  "proposal snapshot left the live Mat4f edge-object transform opaque")
assert(proposalEvent.param.proposalSnapshot.opaque == "<userdata>", "proposal snapshot leaked a userdata address")
assert(proposalEvent.param.proposalSnapshot.__builderData.costs == 1234,
  "proposal snapshot did not retain adjacent builder data")

script.guiHandleEvent("streetBuilder", "builder.apply", {
  data = { costs = 1234 },
  proposal = { proposal = { addedSegments = {
    { entity = 88, type = 1, comp = { node0 = 10, node1 = 11 } },
  } } },
  result = {},
})
script.guiUpdate()
local applyEvent = sentEvents[#sentEvents]
assert(applyEvent.param.observation == "builder.apply", "builder apply observation was not queued")
assert(applyEvent.param.proposalSnapshot.proposal.addedSegments["1"].entity == 88,
  "applied proposal snapshot was not retained for reverse engineering")
assert(applyEvent.param.edgeReplacementObservation.sourceCount == 1
  and #applyEvent.param.edgeReplacementObservation.pairs == 1
  and applyEvent.param.edgeReplacementObservation.pairs[1].oldLocalId == 77
  and applyEvent.param.edgeReplacementObservation.pairs[1].newLocalId == 88,
  "GUI builder lifecycle did not pair old and replacement edge IDs")

local saved = script.save()
saved.networkMode = "network"
saved.initialized = true
saved.companies = {
  ["company:1"] = { cid = "company:1", name = "Company 1", playerId = 100 },
  ["company:2"] = { cid = "company:2", name = "Company 2", playerId = 101 },
}
saved.companyOrder = { "company:1", "company:2" }
saved.activeCompanyIndex = 1
saved.world.proxyMode = true
saved.world.controlPlayerId = 100
saved.world.turn = { active = true, companyCid = "company:1", startedTick = 1, leasedAssets = 0, paused = true }
saved.world.logicalOwners = {
  ["700"] = "company:1",
  ["701"] = "company:2",
  ["702"] = "company:2",
}
saved.world.pinnedCustody = {
  ["700"] = { cid = "edge:own", logicalOwnerCid = "company:1" },
  ["701"] = { cid = "edge:rival", logicalOwnerCid = "company:2" },
}
script.load(saved)

assert(textViews[1].text:match("Mode: network"), "shared-state load did not refresh the visible status")
nativeSpeedRequests[#nativeSpeedRequests + 1] = "4"
script.guiUpdate()
assert(sentEvents[#sentEvents].name == "intent"
    and sentEvents[#sentEvents].param.type == "clock.request"
    and sentEvents[#sentEvents].param.requestedSpeed == 4,
  "suppressed vanilla game speed was not converted into an ordered clock request")

-- A safety fence retains the player's requested speed while temporarily
-- forcing effective speed zero.  Re-selecting that requested speed is the
-- resume signal and must not be discarded as a duplicate.
local recoveryState = script.save()
recoveryState.world.networkClock.requestedSpeed = 4
recoveryState.world.networkClock.effectiveSpeed = 0
recoveryState.world.networkClock.generation = 9
script.load(recoveryState)
local recoveryEventCount = #sentEvents
nativeSpeedRequests[#nativeSpeedRequests + 1] = "4"
script.guiUpdate()
assert(#sentEvents == recoveryEventCount + 1
    and sentEvents[#sentEvents].name == "intent"
    and sentEvents[#sentEvents].param.type == "clock.request"
    and sentEvents[#sentEvents].param.requestedSpeed == 4,
  "a fenced shared clock discarded its same-requested-speed resume signal")

-- Reproduce the live stock-widget race: LINE can become enumerable one GUI
-- update before the post-visitor native capture is readable. The correlation
-- ledger must retain that exact owned result instead of losing the command.
lineEntities[799] = true
local idleLineEnumerations = lineEnumerations
script.guiUpdate()
assert(lineEnumerations == idleLineEnumerations,
  "an idle GUI update enumerated every native line with an empty capture queue")
nativeLineCommands[#nativeLineCommands + 1] =
  "L1|3|-1|100|950|250|100|4c696e652031|0|"
nativeLineCommands[#nativeLineCommands + 1] =
  "L3|5|700|-1|0|0|0||2|901,1,2,0.5:0.6;902,3,4,3.7"
nativeLineCommands[#nativeLineCommands + 1] =
  "L1|29|700|-1|0|0|0|4d79204c696e65|0|"
nativeLineCommands[#nativeLineCommands + 1] =
  "L1|28|700|-1|125|500|875||0|"
nativeLineCommands[#nativeLineCommands + 1] =
  "L1|4|700|-1|0|0|0||0|"
script.guiUpdate()
local vanillaCreate = sentEvents[#sentEvents]
assert(vanillaCreate.name == "intent" and vanillaCreate.param.type == "operation.capture"
  and vanillaCreate.param.capture.kind == "line.create"
  and vanillaCreate.param.capture.originApplied == true
  and vanillaCreate.param.capture.originLocalId == 799
  and vanillaCreate.param.capture.name == "Line 1"
  and vanillaCreate.param.capture.color.r == 950
  and #vanillaCreate.param.capture.stops == 0,
  "suppressed vanilla New Line was not converted into an exact line.create capture")
script.guiUpdate()
local vanillaUpdate = sentEvents[#sentEvents]
assert(vanillaUpdate.name == "intent" and vanillaUpdate.param.type == "operation.capture"
  and vanillaUpdate.param.capture.kind == "line.update"
  and vanillaUpdate.param.capture.originApplied == true
  and vanillaUpdate.param.capture.originLocalId == 700
  and vanillaUpdate.param.capture.targetLocalId == 700
  and #vanillaUpdate.param.capture.stops == 2
  and vanillaUpdate.param.capture.stops[1].stationGroupLocalId == 901
  and vanillaUpdate.param.capture.stops[1].station == 1
  and vanillaUpdate.param.capture.stops[1].terminal == 2
  and vanillaUpdate.param.capture.stops[1].alternativeTerminals[1].station == 0
  and vanillaUpdate.param.capture.stops[1].alternativeTerminals[1].terminal == 5
  and vanillaUpdate.param.capture.stops[1].alternativeTerminals[2].station == 0
  and vanillaUpdate.param.capture.stops[1].alternativeTerminals[2].terminal == 6
  and vanillaUpdate.param.capture.stops[2].stationGroupLocalId == 902
  and vanillaUpdate.param.capture.stops[2].station == 3
  and vanillaUpdate.param.capture.stops[2].terminal == 4
  and vanillaUpdate.param.capture.stops[2].alternativeTerminals[1].station == 3
  and vanillaUpdate.param.capture.stops[2].alternativeTerminals[1].terminal == 7,
  "suppressed vanilla stop edit lost its target or native stop tuple")
script.guiUpdate()
local vanillaName = sentEvents[#sentEvents]
assert(vanillaName.name == "intent" and vanillaName.param.type == "operation.capture"
  and vanillaName.param.capture.kind == "entity.name"
  and vanillaName.param.capture.originApplied == true
  and vanillaName.param.capture.originLocalId == 700
  and vanillaName.param.capture.targetLocalId == 700
  and vanillaName.param.capture.name == "My Line",
  "vanilla line rename was not converted into an exact entity.name capture")
script.guiUpdate()
local vanillaColor = sentEvents[#sentEvents]
assert(vanillaColor.name == "intent" and vanillaColor.param.type == "operation.capture"
  and vanillaColor.param.capture.kind == "entity.color"
  and vanillaColor.param.capture.originApplied == true
  and vanillaColor.param.capture.originLocalId == 700
  and vanillaColor.param.capture.targetLocalId == 700
  and vanillaColor.param.capture.color.r == 125
  and vanillaColor.param.capture.color.g == 500
  and vanillaColor.param.capture.color.b == 875,
  "vanilla line colour was not converted into an exact entity.color capture")
script.guiUpdate()
local vanillaDelete = sentEvents[#sentEvents]
assert(vanillaDelete.name == "intent" and vanillaDelete.param.type == "operation.capture"
  and vanillaDelete.param.capture.kind == "line.delete"
  and vanillaDelete.param.capture.originApplied == true
  and vanillaDelete.param.capture.originLocalId == 700
  and vanillaDelete.param.capture.targetLocalId == 700,
  "suppressed vanilla Delete Line was not converted into line.delete")

-- A queue overflow means at least one pass-through line mutation was already
-- applied and then dropped. It must become an ordered session fault, and a
-- transient GUI-to-engine send failure must retain that action for retry.
local workingSendScriptEvent = game.interface.sendScriptEvent
local sentBeforeRetry = #sentEvents
game.interface.sendScriptEvent = function() error("transient test bridge failure") end
nativeLineCommands[#nativeLineCommands + 1] = "F1|queue-overflow|3"
script.guiUpdate()
assert(#sentEvents == sentBeforeRetry,
  "failed GUI-to-engine dispatch was incorrectly reported as sent")
game.interface.sendScriptEvent = workingSendScriptEvent
script.guiUpdate()
local overflowFault = sentEvents[#sentEvents]
assert(overflowFault.name == "intent"
  and overflowFault.param.type == "network.origin_residue"
  and overflowFault.param.errorCode == "origin-applied-native-line-capture-overflow"
  and overflowFault.param.detail.dropped == 3,
  "native line queue overflow was not retained and converted into a residue fault")

nativeLineCommands[#nativeLineCommands + 1] = "L1|malformed"
script.guiUpdate()
local decodeFault = sentEvents[#sentEvents]
assert(decodeFault.name == "intent"
  and decodeFault.param.type == "network.origin_residue"
  and decodeFault.param.errorCode == "origin-applied-native-line-envelope-invalid",
  "invalid post-apply line envelope was not converted into a residue fault")
local lock = script.guiHandleEvent("finances.borrow", "button.click", nil)
assert(type(lock) == "table" and tostring(lock[1]):match("disabled"), "borrow event was not vetoed in proxy mode")

local blocked = script.guiHandleEvent("trackBuilder", "builder.proposalCreate", {
  proposal = { proposal = { removedSegments = {
    { entity = 701, type = 1, comp = { node0 = 20, node1 = 21 } },
  } } },
})
assert(type(blocked) == "table" and type(blocked.errorMessages) == "table"
  and #blocked.errorMessages == 1 and blocked.errorMessages[1]:match("Company 2")
  and type(blocked.warnings) == "table" and #blocked.warnings == 0,
  "rival track modification did not return the game's proposal veto contract")
script.guiUpdate()
local deniedEvent = sentEvents[#sentEvents]
assert(deniedEvent.param.observation == "builder.proposalDenied"
  and deniedEvent.param.accessDecision.allowed == false
  and deniedEvent.param.accessDecision.blocked[1].localId == 701,
  "rival proposal denial was not queued as bounded local evidence")

local ownTrack = script.guiHandleEvent("trackBuilder", "builder.proposalCreate", {
  proposal = { proposal = { removedSegments = {
    { entity = 700, type = 1, comp = { node0 = 22, node1 = 23 } },
  } } },
})
assert(ownTrack == nil, "active company's own track modification was vetoed")

local publicRoad = script.guiHandleEvent("streetBuilder", "builder.proposalCreate", {
  proposal = { proposal = { removedSegments = {
    { entity = 799, type = 0, comp = { node0 = 24, node1 = 25 } },
  } } },
})
assert(publicRoad == nil, "public/untracked road modification was vetoed")

local newTrack = script.guiHandleEvent("trackBuilder", "builder.proposalCreate", {
  proposal = { proposal = { removedSegments = {
    { entity = -1, type = 1, comp = { node0 = -2, node1 = -3 } },
  } } },
})
assert(newTrack == nil, "brand-new track preview was vetoed")

local newSignal = script.guiHandleEvent("streetTerminalBuilder", "builder.proposalCreate", {
  proposal = { streetProposal = { edgeObjectsToAdd = {
    { edgeEntity = 700, category = 0, model = "railroad/signal_path_a.mdl" },
  } } },
})
assert(newSignal == nil and tonumber(nativeBuildArmedCorrelation) > 0,
  "Build 35924's streetTerminalBuilder was misclassified as a stale station preview")
local liveSignalSplit = script.guiHandleEvent(
  "streetTerminalBuilder", "builder.proposalCreate", {
    proposal = { streetProposal = {
      edgesToAdd = {
        { type = 1, trackEdge = { trackType = 0 } },
        { type = 0, streetEdge = { streetType = 0, hasBus = false, tramTrackType = 0 } },
      },
      edgeObjectsToAdd = {
        { edgeEntity = 700, category = 0, model = "railroad/signal_path_a.mdl" },
      },
    } },
  })
assert(liveSignalSplit == nil and tonumber(nativeBuildArmedCorrelation) > 0,
  "the live mixed-topology signal preview was rejected as a stale build tool")

local rivalConstruction = script.guiHandleEvent("constructionBuilder", "builder.proposalCreate.preview", {
  proposal = { toRemove = { { entity = 702 } } },
})
assert(type(rivalConstruction) == "table" and rivalConstruction.errorMessages[1]:match("Company 2"),
  "tracked rival construction or proposal event variant bypassed the general source policy")

local rivalLine = script.guiHandleEvent("lineManager", "delete", { lineEntity = 702 })
assert(type(rivalLine) == "table" and tostring(rivalLine[1]):match("Company 2"),
  "rival line mutation bypassed the generic logical-owner veto")
script.guiUpdate()
local deniedEntityEvent = sentEvents[#sentEvents]
assert(deniedEntityEvent.param.observation == "entity.accessDenied"
  and deniedEntityEvent.param.accessDecision.allowed == false
  and deniedEntityEvent.param.accessDecision.blocked[1].localId == 702,
  "generic entity denial was not queued as bounded local evidence")

local ownLine = script.guiHandleEvent("lineManager", "delete", { lineEntity = 700 })
assert(ownLine == nil, "active company's own line action was vetoed")
local lineReadsBeforeStopEdit = lineComponentReads
assert(script.guiHandleEvent("lineManager", "addStop", {
  lineEntity = 700,
  stop = { stationEntity = 901, terminal = 0 },
}) == nil, "line stop edit changed the native event contract")
assert(lineComponentReads == lineReadsBeforeStopEdit + 1,
  "line stop edit did not retain its explicit line carrier")
local entityReadsBeforeHover = gameEntityReads
local lineReadsBeforeHover = lineComponentReads
for _ = 1, 240 do
  assert(script.guiHandleEvent("mainView", "hover", {
    worldPosition = { x = 700, y = 702, z = 100 },
    screenPosition = { x = 799, y = 701 },
    frame = 700,
  }) == nil, "ordinary main-view hover changed the native event contract")
end
assert(gameEntityReads == entityReadsBeforeHover and lineComponentReads == lineReadsBeforeHover,
  "main-view hover probed coordinate values as native line entity IDs")
script.guiHandleEvent("mainView", "select", {})
local retainedLineVisible = false
for _, view in ipairs(textViews) do
  if view.text:match("retained line 700") then retainedLineVisible = true end
end
assert(retainedLineVisible,
  "line-manager event did not retain its line for panel registration controls")

local baseGuiConfig = game.config.tpf2mp
local operationalGuiConfig = {}
for key, value in pairs(baseGuiConfig) do operationalGuiConfig[key] = value end
operationalGuiConfig.operationalCapture = true
game.config.tpf2mp = operationalGuiConfig
local operationalLine = script.guiHandleEvent("lineManager", "update", {
  lineEntity = 700,
  stops = { { stationEntity = 901 }, { stationEntity = 902 } },
})
assert(operationalLine == nil, "operational GUI observation changed the native event contract")
script.guiUpdate()
local operationalGuiEvent = sentEvents[#sentEvents]
assert(operationalGuiEvent.param.observation == "gui.operationalAction"
  and operationalGuiEvent.param.sourceId == "lineManager"
  and operationalGuiEvent.param.eventName == "update",
  "operational mode did not capture a non-build GUI mutation envelope")
assert(operationalGuiEvent.param.commandDigest
  and operationalGuiEvent.param.eventShape.lineEntity == 700
  and operationalGuiEvent.param.eventShape.stops["1"].stationEntity == 901,
  "operational GUI mutation capture lost its bounded line/station fields")
assert(operationalGuiEvent.param.observedEntityIds[1] == 700
  and operationalGuiEvent.param.observedEntityIds[2] == 901
  and operationalGuiEvent.param.observedEntityIds[3] == 902,
  "operational GUI mutation capture lost referenced entity IDs")
game.config.tpf2mp = baseGuiConfig

local function proposalCaptureEvents()
  local result = {}
  for _, event in ipairs(sentEvents) do
    if event.name == "intent" and event.param and event.param.type == "proposal.capture" then
      result[#result + 1] = event
    end
  end
  return result
end

local function observedEvents(observation)
  local count = 0
  for _, event in ipairs(sentEvents) do
    if event.name == "intent" and event.param
      and event.param.type == "native.observed"
      and event.param.observation == observation then
      count = count + 1
    end
  end
  return count
end

local networkPreview = {
  data = { trackType = 7, catenary = true },
  proposal = {
    streetProposal = {
      edgesToAdd = {{
        entity = -1,
        type = 1,
        comp = {
          node0 = -2, node1 = -3,
          tangent0 = { x = 80, y = 0, z = 0 },
          tangent1 = { x = 80, y = 0, z = 0 },
          type = 0, typeIndex = -1,
        },
        trackEdge = io.stdout,
        playerOwned = { player = 100 },
      }},
      nodesToAdd = {
        { entity = -2, comp = { position = { x = 10, y = 20, z = 3 } } },
        { entity = -3, comp = { position = { x = 90, y = 20, z = 3 } } },
      },
      edgesToRemove = {}, nodesToRemove = {},
    },
  },
}
local captureCount = #proposalCaptureEvents()
local nativeStatusBeforePreview = nativeStatusReads
local previewDiagnosticsBefore = observedEvents("builder.proposalCreate")
assert(script.guiHandleEvent("trackBuilder", "builder.proposalCreate", networkPreview) == nil,
  "network track preview was unexpectedly vetoed")
for _ = 1, 120 do
  assert(script.guiHandleEvent("trackBuilder", "builder.proposalCreate", networkPreview) == nil,
    "repeated network hover was unexpectedly vetoed")
end
for _ = 1, 3 do script.guiUpdate() end
assert(#proposalCaptureEvents() == captureCount,
  "a mouse-move proposal preview was replicated before native commit evidence")
assert(nativeStatusReads == nativeStatusBeforePreview,
  "ordinary network hover used the heavyweight full native-status serializer")
assert(observedEvents("builder.proposalCreate") == previewDiagnosticsBefore,
  "ordinary network hover emitted a diagnostic intent/journal record")
nativeBuildGate.suppressed = nativeBuildGate.suppressed + 1
for _ = 1, 59 do script.guiUpdate() end
assert(#proposalCaptureEvents() == captureCount,
  "preview fallback settled before the bounded exact-apply window elapsed")
for _ = 1, 2 do script.guiUpdate() end
local captures = proposalCaptureEvents()
assert(#captures == captureCount + 1,
  "a natively suppressed vanilla build was not converted into exactly one proposal.capture intent")
local bridged = captures[#captures].param.proposalSnapshot
assert(bridged.__builderData.trackType == 7 and bridged.__builderData.catenary == true,
  "vanilla capture bridge lost the carrier-selection fallback")
for _ = 1, 6 do script.guiUpdate() end
assert(#proposalCaptureEvents() == captureCount + 1,
  "one native suppression was replicated more than once")

-- A suppressed click may be observed one GUI update before builder.apply.
-- Hold the preview briefly, then replace it with the exact apply geometry and
-- retain the preview's non-zero quote/carrier selection fallbacks.
local exactPreview = {
  data = { costs = 7654, trackType = 8, catenary = false },
  proposal = {
    constructionsToAdd = {{
      fileName = "station/rail/modular_station/modular_station.con",
      params = {
        year = 1990, seed = 10, trackType = 0, catenary = 0,
        length = 1, tracks = 0, paramX = 0, paramY = 0,
      },
      transf = { 1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1, 0, 200, 20, 3, 1 },
    }},
    -- The first ghost overlaps an owned construction. Moving this unchanged
    -- station template to clear ground must invalidate the cached removal set.
    constructionsToRemove = { 700 },
    streetProposal = {
    edgesToAdd = {{
      entity = -21, type = 1,
      comp = {
        node0 = -22, node1 = -23,
        tangent0 = { x = 60, y = 0, z = 0 },
        tangent1 = { x = 60, y = 0, z = 0 }, type = 0, typeIndex = -1,
      },
      trackEdge = { trackType = 8, catenary = false },
      playerOwned = { player = 100 },
    }},
    nodesToAdd = {
      { entity = -22, comp = { position = { x = 200, y = 20, z = 3 } } },
      { entity = -23, comp = { position = { x = 260, y = 20, z = 3 } } },
    },
    edgesToRemove = {}, nodesToRemove = {},
    },
  },
}
-- Construction input remains capturable while a prior ordered action is in
-- flight, but its raw native IDs must be rejected instead of surviving behind
-- topology-changing work.
script.handleEvent("test", "tpf2mp", "snapshot", {
  networkMode = "network", activeCompanyCid = "company:1",
  proposals = { queued = 1, applied = 0, failed = 0 },
  operations = { queued = 0, applied = 0, failed = 0 },
  proposalConsensus = { pending = 1 }, operationConsensus = { pending = 0 },
  checkpointConsensus = { pending = 0 }, deferredNetworkQueue = { count = 0 },
})
local busyPreview = script.guiHandleEvent("constructionBuilder", "builder.proposalCreate", exactPreview)
assert(busyPreview == nil, "busy construction preview was vetoed before exact capture")
local busyApply = script.guiHandleEvent("constructionBuilder", "builder.apply", {
  proposal = { streetProposal = { edgesToAdd = {}, nodesToAdd = {} } }, result = {},
})
assert(busyApply == nil, "busy construction apply was vetoed before native correlation")
nativeBuildGate.suppressed = nativeBuildGate.suppressed + 1
for _ = 1, 35 do script.guiUpdate() end
local busyCaptures = proposalCaptureEvents()
assert(#busyCaptures == captureCount + 2
    and busyCaptures[#busyCaptures].param.queuePolicy == "reject-if-busy",
  "busy construction click missed its fail-closed raw-snapshot queue policy")
captureCount = captureCount + 1
script.handleEvent("test", "tpf2mp", "snapshot", {
  networkMode = "network", activeCompanyCid = "company:1",
  proposals = { queued = 1, applied = 1, failed = 0 },
  operations = { queued = 0, applied = 0, failed = 0 },
  proposalConsensus = { pending = 0 }, operationConsensus = { pending = 0 },
  checkpointConsensus = { pending = 0 }, deferredNetworkQueue = { count = 0 },
})
assert(script.guiHandleEvent("constructionBuilder", "builder.proposalCreate", exactPreview) == nil)
for _ = 1, 2 do script.guiUpdate() end
-- Move the same station template. The lightweight path must retain only its
-- latest placement and rebase the cached full graph once at builder.apply.
exactPreview.proposal.constructionsToRemove = {}
exactPreview.proposal.constructionsToAdd[1].transf[13] = 333
exactPreview.proposal.streetProposal.nodesToAdd[1].comp.position.x = 333
exactPreview.proposal.streetProposal.nodesToAdd[2].comp.position.x = 393
assert(script.guiHandleEvent("constructionBuilder", "builder.proposalCreate", exactPreview) == nil,
  "lightweight construction preview update was unexpectedly vetoed")
-- Live Build 35924 ordering is apply -> next ghost preview -> delayed native
-- status counter. Its apply proposal is empty after native suppression, so the
-- exact click must come from the latest rebased pre-apply ghost and survive the
-- construction tool's subsequent preview.
script.guiHandleEvent("constructionBuilder", "builder.apply", {
  data = { costs = 0 },
  proposal = { streetProposal = {
    edgesToAdd = {}, nodesToAdd = {}, edgesToRemove = {}, nodesToRemove = {},
  }},
  result = {},
})
for _ = 1, 31 do script.guiUpdate() end
exactPreview.data.costs = 9999
exactPreview.proposal.constructionsToAdd[1].params.length = 4
exactPreview.proposal.constructionsToAdd[1].transf[13] = 777
exactPreview.proposal.streetProposal.nodesToAdd[1].comp.position.x = 777
exactPreview.proposal.streetProposal.nodesToAdd[2].comp.position.x = 837
assert(script.guiHandleEvent("constructionBuilder", "builder.proposalCreate", exactPreview) == nil,
  "post-click station preview was unexpectedly vetoed")
assert(#proposalCaptureEvents() == captureCount + 1,
  "builder.apply was replicated without matching native suppression")
nativeBuildGate.suppressed = nativeBuildGate.suppressed + 1
for _ = 1, 4 do script.guiUpdate() end
captures = proposalCaptureEvents()
assert(#captures == captureCount + 2,
  "exact builder.apply payload was not converted into one capture")
local exactCapture = captures[#captures].param.proposalSnapshot
assert(exactCapture.streetProposal.nodesToAdd["1"].comp.position.x == 333,
  "suppression correlation retained stale preview geometry instead of builder.apply")
assert(exactCapture.__constructionAdditions["1"].transf["13"] == 333
    and exactCapture.__constructionAdditions["1"].params.length == 1
    and exactCapture.__constructionAdditions["1"].params.tracks == 0,
  "suppression correlation retained the stale station transform/template instead of builder.apply")
assert((exactCapture.constructionsToRemove == nil
      or (exactCapture.constructionsToRemove[1] == nil
        and exactCapture.constructionsToRemove["1"] == nil))
    and exactCapture.__constructionRemovals == nil,
  "clear-ground station capture retained a stale construction removal from an earlier ghost")
assert(exactCapture.__observedCost == 7654
  and exactCapture.__builderData.trackType == 8
  and exactCapture.__builderData.catenary == false,
  "exact apply capture lost the preview's authoritative quote or carrier fallback: cost="
    .. tostring(exactCapture.__observedCost) .. " track="
    .. tostring(exactCapture.__builderData and exactCapture.__builderData.trackType)
    .. " catenary="
     .. tostring(exactCapture.__builderData and exactCapture.__builderData.catenary))

-- After one successful placement, Build 35924 reuses the same construction
-- template and can report the next native suppression before builder.apply.
-- The lightweight repeated-preview path must therefore keep a cheap pending
-- latch; otherwise every second station produces dust but no replicated build.
local repeatedStationCaptureCount = #proposalCaptureEvents()
exactPreview.proposal.constructionsToAdd[1].transf[13] = 888
exactPreview.proposal.streetProposal.nodesToAdd[1].comp.position.x = 888
exactPreview.proposal.streetProposal.nodesToAdd[2].comp.position.x = 948
assert(script.guiHandleEvent("constructionBuilder", "builder.proposalCreate", exactPreview) == nil,
  "same-template station preview was unexpectedly vetoed")
nativeBuildGate.suppressed = nativeBuildGate.suppressed + 1
for _ = 1, 3 do script.guiUpdate() end
assert(#proposalCaptureEvents() == repeatedStationCaptureCount,
  "suppression-first station capture settled before its exact apply grace period")
script.guiHandleEvent("constructionBuilder", "builder.apply", {
  data = { costs = 0 },
  proposal = { streetProposal = {
    edgesToAdd = {}, nodesToAdd = {}, edgesToRemove = {}, nodesToRemove = {},
  }},
  result = {},
})
for _ = 1, 3 do script.guiUpdate() end
captures = proposalCaptureEvents()
assert(#captures == repeatedStationCaptureCount + 1,
  "suppression-first repeated station click was not captured")
local repeatedStationCapture = captures[#captures].param.proposalSnapshot
assert(repeatedStationCapture.__constructionAdditions["1"].transf["13"] == 888
    and repeatedStationCapture.streetProposal.nodesToAdd["1"].comp.position.x == 888,
  "repeated station capture did not rebase the cached template onto the clicked placement")

-- Airport direction, passenger/cargo template, hangar and terminal count are
-- scalar stock-construction options.  Some combinations retain the same small
-- module sentinel sample even though they produce a different runway/taxiway
-- graph.  Changing one must invalidate the lightweight topology cache instead
-- of replaying the previous airport layout at the new transform.
local airportPreview = util.deepCopy(exactPreview)
local airportAddition = airportPreview.proposal.constructionsToAdd[1]
airportAddition.fileName = "station/air/airport.con"
airportAddition.params = {
  year = 1990, seed = 41, templateIndex = 0,
  hangar = 0, terminals = 2, dir = 0,
  modules = {
    [1002] = { name = "station/air/airport_main_building.module", variant = 0 },
    [70006] = { name = "station/air/airport_terminal.module", variant = 0 },
  },
}
airportAddition.transf[13] = 1600
airportPreview.proposal.streetProposal.nodesToAdd[1].comp.position.x = 1600
airportPreview.proposal.streetProposal.nodesToAdd[2].comp.position.x = 1660
assert(script.guiHandleEvent("constructionBuilder", "builder.proposalCreate", airportPreview) == nil,
  "airport preview was unexpectedly vetoed")
airportAddition.params.dir = 1
assert(script.guiHandleEvent("constructionBuilder", "builder.proposalCreate", airportPreview) == nil,
  "opposite-direction airport preview was unexpectedly vetoed")
script.guiHandleEvent("constructionBuilder", "builder.apply", {
  data = { costs = 0 },
  proposal = { streetProposal = {
    edgesToAdd = {}, nodesToAdd = {}, edgesToRemove = {}, nodesToRemove = {},
  } },
  result = {},
})
nativeBuildGate.suppressed = nativeBuildGate.suppressed + 1
for _ = 1, 4 do script.guiUpdate() end
captures = proposalCaptureEvents()
assert(#captures == repeatedStationCaptureCount + 2,
  "airport option change was not captured")
local airportCapture = captures[#captures].param.proposalSnapshot
assert(airportCapture.__constructionAdditions["1"].params.dir == 1
    and airportCapture.__constructionAdditions["1"].params.terminals == 2
    and airportCapture.__constructionAdditions["1"].params.hangar == 0,
  "airport capture reused stale scalar construction options")
captureCount = captureCount + 1

-- The stock 8-track/160 m graph has 200 nodes and 192 edges. Verify that the
-- construction-only projector budget keeps its tail intact; the old generic
-- 128-entry/2K budget truncated this live graph and produced a missing entity
-- error around edge 77.
local largeNodes, largeEdges, largeModules = {}, {}, {}
for track = 1, 8 do
  local firstNode = #largeNodes + 1
  for offset = 0, 24 do
    local nodeIndex = #largeNodes + 1
    largeNodes[nodeIndex] = {
      entity = -1000 - nodeIndex,
      comp = { position = { x = 1000 + offset * 10, y = 100 + track * 10, z = 3 } },
    }
  end
  for offset = 0, 23 do
    local edgeIndex = #largeEdges + 1
    largeEdges[edgeIndex] = {
      entity = -5000 - edgeIndex,
      type = 1,
      comp = {
        node0 = largeNodes[firstNode + offset].entity,
        node1 = largeNodes[firstNode + offset + 1].entity,
        tangent0 = { x = 10, y = 0, z = 0 },
        tangent1 = { x = 10, y = 0, z = 0 },
        type = 0, typeIndex = -1,
      },
      trackEdge = { trackType = 0, catenary = true },
      playerOwned = { player = 100 },
    }
  end
end
for index = 1, 80 do
  largeModules[index] = { name = "station/rail/modular_station/test_" .. index .. ".module", variant = 0 }
end
local largeStationPreview = {
  data = { costs = 800000 },
  proposal = {
    constructionsToAdd = {{
      fileName = "station/rail/modular_station/modular_station.con",
      params = {
        year = 1990, seed = 20, trackType = 0, catenary = 1,
        length = 2, tracks = 7, paramX = 0, paramY = 0, modules = largeModules,
      },
      transf = { 1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1, 0, 1000, 100, 3, 1 },
    }},
    streetProposal = {
      edgesToAdd = largeEdges, nodesToAdd = largeNodes,
      edgesToRemove = {}, nodesToRemove = {},
    },
  },
}
assert(script.guiHandleEvent("constructionBuilder", "builder.proposalCreate", largeStationPreview) == nil,
  "large station preview was unexpectedly vetoed")
-- Build 35924 can issue a preview callback every rendered frame while the
-- construction tool remains selected after placement. Exercise a sustained
-- mouse move over the large graph; only the lightweight placement should be
-- sampled until the click below.
for offset = 1, 120 do
  largeStationPreview.proposal.constructionsToAdd[1].transf[13] = 1000 + offset
  assert(script.guiHandleEvent(
    "constructionBuilder", "builder.proposalCreate", largeStationPreview
  ) == nil, "large station lightweight preview was unexpectedly vetoed")
end
script.guiHandleEvent("constructionBuilder", "builder.apply", {
  data = { costs = 0 },
  proposal = { streetProposal = {
    edgesToAdd = {}, nodesToAdd = {}, edgesToRemove = {}, nodesToRemove = {},
  }},
  result = {},
})
nativeBuildGate.suppressed = nativeBuildGate.suppressed + 1
for _ = 1, 4 do script.guiUpdate() end
captures = proposalCaptureEvents()
assert(#captures == captureCount + 4, "large station click was not captured")
local largeCapture = captures[#captures].param.proposalSnapshot
assert(largeCapture.streetProposal.edgesToAdd["192"].entity == -5192
    and largeCapture.streetProposal.nodesToAdd["200"].entity == -1200,
  "large station graph was truncated by the construction projector")
assert(largeCapture.__constructionAdditions["1"].params.tracks == 7
    and largeCapture.__constructionAdditions["1"].params.modules["80"] ~= nil,
  "large station construction parameters or module map were truncated")
assert(largeCapture.__constructionAdditions["1"].transf["13"] == 1120
    and largeCapture.streetProposal.nodesToAdd["1"].comp.position.x == 1120,
  "large station click did not apply the latest deferred preview transform")

nativeCommandObserver({ proposal = networkPreview.proposal })
for _ = 1, 2 do script.guiUpdate() end
assert(#proposalCaptureEvents() == captureCount + 4,
  "Lua issuing-path observation bypassed native suppression confirmation")
nativeBuildGate.suppressed = nativeBuildGate.suppressed + 1
for _ = 1, 65 do script.guiUpdate() end
assert(#proposalCaptureEvents() == captureCount + 5,
  "Lua issuing-path build was not correlated with its native suppression: got "
    .. tostring(#proposalCaptureEvents()) .. " expected " .. tostring(captureCount + 5))

-- Build 35924's modular station editor issues several native BuildProposal
-- visitors for one logical module edit. A single bounded construction snapshot
-- must coalesce that native batch, while ordinary road/track ambiguity remains
-- fail-closed.
local multiStationEdit = {
  data = { costs = 12000 },
  proposal = {
    constructionsToAdd = {{
      entity = -31,
      fileName = "station/rail/modular_station/modular_station.con",
      params = {
        year = 1990, seed = 30, trackType = 0, catenary = 1,
        length = 0, tracks = 0, paramX = 0, paramY = 0,
        modules = { [3400020] = {
          name = "station/rail/modular_station/main_building_1_era_c.module", variant = 0,
        } },
      },
      transf = { 1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1, 0, 1400, 100, 3, 1 },
    }},
    constructionsToRemove = { 800 },
    streetProposal = {
      edgesToAdd = {}, nodesToAdd = {}, edgesToRemove = {}, nodesToRemove = {},
    },
  },
}
assert(script.guiHandleEvent("constructionBuilder", "builder.proposalCreate", multiStationEdit) == nil,
  "station module edit preview was unexpectedly vetoed")
nativeBuildGate.suppressed = nativeBuildGate.suppressed + 4
for _ = 1, 65 do script.guiUpdate() end
assert(#proposalCaptureEvents() == captureCount + 6,
  "four native station-editor suppressions were not coalesced into one logical capture")

assert(script.guiHandleEvent("trackBuilder", "builder.proposalCreate", networkPreview) == nil)
nativeBuildGate.suppressed = nativeBuildGate.suppressed + 2
for _ = 1, 4 do script.guiUpdate() end
assert(#proposalCaptureEvents() == captureCount + 6,
  "ambiguous multi-command track input was incorrectly coalesced")

for _ = 1, 29 do script.guiUpdate() end

-- A portable decorative asset has a construction transform but deliberately
-- no street/track graph.  Its repeated mouse-move previews use the same cheap
-- placement cache as a large station, so the click must rebase the named .con
-- transform without inventing graph nodes or rejecting the proposal.
local assetCaptureCount = #proposalCaptureEvents()
local assetPreview = {
  data = { costs = 250 },
  proposal = {
    constructionsToAdd = {{
      fileName = "asset/decoration/bench.con",
      params = { year = 1990, seed = 40 },
      transf = { 1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1, 0, 50, 60, 2, 1 },
    }},
    streetProposal = {
      edgesToAdd = {}, nodesToAdd = {}, edgesToRemove = {}, nodesToRemove = {},
    },
  },
}
assert(script.guiHandleEvent("constructionBuilder", "builder.proposalCreate", assetPreview) == nil,
  "graphless asset preview was unexpectedly vetoed")
assetPreview.proposal.constructionsToAdd[1].transf[13] = 75
assert(script.guiHandleEvent("constructionBuilder", "builder.proposalCreate", assetPreview) == nil,
  "graphless asset lightweight preview was unexpectedly vetoed")
script.guiHandleEvent("constructionBuilder", "builder.apply", {
  data = { costs = 0 },
  proposal = { streetProposal = {
    edgesToAdd = {}, nodesToAdd = {}, edgesToRemove = {}, nodesToRemove = {},
  }},
  result = {},
})
nativeBuildGate.suppressed = nativeBuildGate.suppressed + 1
for _ = 1, 4 do script.guiUpdate() end
captures = proposalCaptureEvents()
assert(#captures == assetCaptureCount + 1,
  "graphless asset click was not converted into one proposal.capture intent")
local assetCapture = captures[#captures].param.proposalSnapshot
assert(assetCapture.__constructionAdditions["1"].fileName == "asset/decoration/bench.con"
    and assetCapture.__constructionAdditions["1"].transf["13"] == 75,
  "graphless asset capture lost its named resource or latest placement transform")
assert(assetCapture.streetProposal.edgesToAdd["1"] == nil
    and assetCapture.streetProposal.nodesToAdd["1"] == nil,
  "graphless asset capture unexpectedly invented a transport graph")

-- The stock headquarters is also graphless, but its native ConstructionEntity
-- has a semantic boolean outside params.  Preserve it through the same cached
-- preview/apply path used by ordinary assets.
local headquartersCaptureCount = #proposalCaptureEvents()
local headquartersPreview = {
  data = { costs = 100000 },
  proposal = {
    constructionsToAdd = {{
      fileName = "asset/headquarter.con", headquarters = true,
      params = { size = 0, year = 1990, seed = 41 },
      transf = { 1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1, 0, 85, 65, 2, 1 },
    }},
    streetProposal = {
      edgesToAdd = {}, nodesToAdd = {}, edgesToRemove = {}, nodesToRemove = {},
    },
  },
}
assert(script.guiHandleEvent(
  "constructionBuilder", "builder.proposalCreate", headquartersPreview) == nil,
  "headquarters preview was unexpectedly vetoed")
script.guiHandleEvent("constructionBuilder", "builder.apply", {
  data = { costs = 0 },
  proposal = { streetProposal = {
    edgesToAdd = {}, nodesToAdd = {}, edgesToRemove = {}, nodesToRemove = {},
  }},
  result = {},
})
nativeBuildGate.suppressed = nativeBuildGate.suppressed + 1
for _ = 1, 4 do script.guiUpdate() end
captures = proposalCaptureEvents()
assert(#captures == headquartersCaptureCount + 1
    and captures[#captures].param.proposalSnapshot.__constructionAdditions["1"].headquarters == true,
  "headquarters marker was lost between cached GUI preview and capture")

-- The release hook carries an explicit preview token on every suppressed
-- BuildProposal. Exercise the adversarial station -> tool switch -> track
-- ordering: a late station token must be rejected, never substituted for the
-- current track preview, and a clean retry must still succeed.
nativeBuildFastVersion = 2
tpf2mp_native_take_suppressed_build = function()
  if #nativeBuildEvents == 0 then return nil end
  return table.remove(nativeBuildEvents, 1)
end

-- Reproduce the live public-road crossing order exactly: the suppression and
-- native factory payload arrive while a GUI preview is pending, followed by a
-- builder.apply envelope whose replacement street edge omits the default
-- tramTrackType. The exact upgrade must retain native topology rather than
-- replacing it with the weaker GUI-only snapshot.
do
local crossingCase = {}
crossingCase.captureCount = #proposalCaptureEvents()
crossingCase.preview = {
  data = { costs = 2250, trackType = 3, catenary = false },
  proposal = { streetProposal = {
    nodesToAdd = {
      { entity = -101, comp = { position = { x = 0, y = 0, z = 1 } } },
      { entity = -102, comp = { position = { x = 50, y = 0, z = 1 } } },
      { entity = -103, comp = { position = { x = 25, y = -10, z = 1 } } },
      { entity = -104, comp = { position = { x = 25, y = 10, z = 1 } } },
    },
    edgesToAdd = {
      { entity = -111, type = 1, comp = {
        node0 = -101, node1 = -102,
        tangent0 = { x = 50, y = 0, z = 0 },
        tangent1 = { x = 50, y = 0, z = 0 }, type = 0, typeIndex = -1,
      }, trackEdge = { trackType = 3, catenary = false } },
      { entity = -112, type = 0, comp = {
        node0 = -103, node1 = -104,
        tangent0 = { x = 0, y = 20, z = 0 },
        tangent1 = { x = 0, y = 20, z = 0 }, type = 0, typeIndex = 0,
      }, streetEdge = { streetType = 2, hasBus = false } },
    },
    nodesToRemove = {}, edgesToRemove = {},
    edgeObjectsToAdd = {}, edgeObjectsToRemove = {},
  } },
}
assert(script.guiHandleEvent("trackBuilder", "builder.proposalCreate", crossingCase.preview) == nil,
  "mixed track/public-road crossing preview was unexpectedly vetoed")
crossingCase.correlation = nativeBuildArmedCorrelation
nativeBuildGeneration = nativeBuildGeneration + 1
nativeBuildGate.suppressed = nativeBuildGate.suppressed + 1
crossingCase.nativeCapture = {
  schemaVersion = 1, generation = 1201, correlation = crossingCase.correlation,
  valid = true, captureSource = "factory", optionFieldsKnown = true,
  factoryThread = 11, addThread = 11,
  factoryCallerRva = 0x459E97, addCallerRva = 0x459EB7,
  callerType = "track-builder", withCost = true, ignoreErrors = false,
  addedNodes = {
    { e = -101, x = 0, y = 0, z = 1, t = 0, f = 0 },
    { e = -102, x = 50, y = 0, z = 1, t = 0, f = 0 },
    { e = -103, x = 25, y = -10, z = 1, t = 0, f = 0 },
    { e = -104, x = 25, y = 10, z = 1, t = 0, f = 0 },
  },
  removedNodes = {},
  addedEdges = {
    { e = -111, n0 = -101, n1 = -102, t0 = { 50, 0, 0 }, t1 = { 50, 0, 0 },
      carrier = 1, w28 = 0, w2c = -1, trackType = 3, f64 = 0, player = 100, owned = 1 },
    { e = -112, n0 = -103, n1 = -104, t0 = { 0, 20, 0 }, t1 = { 0, 20, 0 },
      carrier = 0, w28 = 0, w2c = 0, streetType = 2, w50 = 0,
      tramTrackType = 0, player = -1, owned = 0 },
  },
  removedEdges = {}, edgeObjectsToAdd = {}, edgeObjectsToRemove = {},
  constructionsToAdd = {}, constructionsToRemove = {},
  frozenNodeIndices = {}, segmentTags = {},
}
nativeFactoryCaptures[#nativeFactoryCaptures + 1] = json.encode(crossingCase.nativeCapture)
nativeBuildEvents[#nativeBuildEvents + 1] = table.concat({
  "S1", nativeBuildGeneration, crossingCase.correlation, 15,
}, "|")
script.guiUpdate()
assert(script.guiHandleEvent("trackBuilder", "builder.apply", crossingCase.preview) == nil,
  "exact mixed crossing apply was unexpectedly vetoed")
for _ = 1, 4 do script.guiUpdate() end
captures = proposalCaptureEvents()
crossingCase.result = captures[#captures] and captures[#captures].param.proposalSnapshot
assert(#captures == crossingCase.captureCount + 1
    and crossingCase.result.__nativeTopology.edgesToAdd[2].streetEdge.tramTrackType == 0
    and crossingCase.result.__nativeFactoryCapture.correlation == crossingCase.correlation,
  "exact crossing apply discarded its already-captured native street defaults")

-- The exact GUI callback can be the only place a mixed track/road proposal
-- exposes a collateral town-building removal. Build 35924's native topology
-- vector is still authoritative for the carrier graph, but an empty native
-- construction vector must not erase this correlation-bound semantic fact.
crossingCase.collateralCaptureCount = #proposalCaptureEvents()
crossingCase.collateralPreview = util.deepCopy(crossingCase.preview)
crossingCase.collateralPreview.data.costs = 47851
crossingCase.collateralPreview.proposal.constructionsToRemove = { 700 }
assert(script.guiHandleEvent("trackBuilder", "builder.proposalCreate",
    crossingCase.collateralPreview) == nil,
  "mixed crossing/demolition preview was unexpectedly vetoed")
crossingCase.collateralCorrelation = nativeBuildArmedCorrelation
crossingCase.collateralNativeCapture = util.deepCopy(crossingCase.nativeCapture)
crossingCase.collateralNativeCapture.generation = 1202
crossingCase.collateralNativeCapture.correlation = crossingCase.collateralCorrelation
crossingCase.collateralNativeCapture.constructionsToRemove = {}
nativeBuildGeneration = nativeBuildGeneration + 1
nativeBuildGate.suppressed = nativeBuildGate.suppressed + 1
nativeFactoryCaptures[#nativeFactoryCaptures + 1] = json.encode(
  crossingCase.collateralNativeCapture)
nativeBuildEvents[#nativeBuildEvents + 1] = table.concat({
  "S1", nativeBuildGeneration, crossingCase.collateralCorrelation, 15,
}, "|")
script.guiUpdate()
assert(script.guiHandleEvent("trackBuilder", "builder.apply",
    crossingCase.collateralPreview) == nil,
  "exact mixed crossing/demolition apply was unexpectedly vetoed")
for _ = 1, 4 do script.guiUpdate() end
captures = proposalCaptureEvents()
crossingCase.collateralResult = captures[#captures]
  and captures[#captures].param.proposalSnapshot
assert(#captures == crossingCase.collateralCaptureCount + 1
    and (crossingCase.collateralResult.__constructionRemovals[1]
      or crossingCase.collateralResult.__constructionRemovals["1"]) == 700
    and crossingCase.collateralResult.__nativeFactoryCapture.nativeConstructionRemoveCount == 0
    and crossingCase.collateralResult.__nativeFactoryCapture.semanticConstructionRemoveCount == 1
    and crossingCase.collateralResult.__nativeFactoryCapture.mergedConstructionRemoveCount == 1,
  "suppression-first exact upgrade discarded GUI-only construction collateral")
end

local transitionCaptureCount = #proposalCaptureEvents()
local transitionErrors = observedEvents("native.buildProposal.captureError")
assert(script.guiHandleEvent(
  "constructionBuilder", "builder.proposalCreate", exactPreview) == nil)
local staleStationCorrelation = nativeBuildArmedCorrelation
script.guiHandleEvent("menu.construction.rail", "button.click", {})
assert(nativeBuildArmedCorrelation == 0,
  "build-tool switch did not disarm the stale construction token")
assert(script.guiHandleEvent("trackBuilder", "builder.proposalCreate", networkPreview) == nil)
nativeBuildGeneration = nativeBuildGeneration + 1
nativeBuildGate.suppressed = nativeBuildGate.suppressed + 1
nativeBuildEvents[#nativeBuildEvents + 1] = table.concat({
  "S1", nativeBuildGeneration, staleStationCorrelation, 15,
}, "|")
for _ = 1, 3 do script.guiUpdate() end
assert(#proposalCaptureEvents() == transitionCaptureCount
    and observedEvents("native.buildProposal.captureError") == transitionErrors + 1,
  "late station correlation was allowed to masquerade as a track click")

assert(script.guiHandleEvent("trackBuilder", "builder.proposalCreate", networkPreview) == nil)
local retryTrackCorrelation = nativeBuildArmedCorrelation
script.guiHandleEvent("trackBuilder", "builder.apply", networkPreview)
nativeBuildGeneration = nativeBuildGeneration + 1
nativeBuildGate.suppressed = nativeBuildGate.suppressed + 1
nativeBuildEvents[#nativeBuildEvents + 1] = table.concat({
  "S1", nativeBuildGeneration, retryTrackCorrelation, 15,
}, "|")
for _ = 1, 4 do script.guiUpdate() end
captures = proposalCaptureEvents()
assert(#captures == transitionCaptureCount + 1
    and captures[#captures].param.proposalSnapshot.__constructionAdditions == nil
    and captures[#captures].param.proposalSnapshot.streetProposal.edgesToAdd["1"] ~= nil,
  "generation-bound track retry did not recover cleanly after stale-token rejection")

local overflowCaptureCount = #proposalCaptureEvents()
local overflowErrors = observedEvents("native.buildProposal.captureError")
nativeBuildEvents[#nativeBuildEvents + 1] = "F1|suppressed-build-queue-overflow|1"
assert(script.guiHandleEvent("trackBuilder", "builder.proposalCreate", networkPreview) == nil)
for _ = 1, 4 do script.guiUpdate() end
assert(#proposalCaptureEvents() == overflowCaptureCount
    and observedEvents("native.buildProposal.captureError") > overflowErrors,
  "a pending native correlation-queue overflow resumed accepting builds")
-- Once that exact loss was consumed, a cumulative status counter from the
-- process lifetime must not poison a reset/new match.
nativeBuildDropped = 1
local historicalErrors = observedEvents("native.buildProposal.captureError")
for _ = 1, 2 do script.guiUpdate() end
assert(observedEvents("native.buildProposal.captureError") == historicalErrors,
  "a consumed historical native queue loss remained a sticky build fault")
nativeBuildDropped = 0

-- Build 35924 throws a table-valued native exception when its global unpack
-- is asked to copy Line/Vec3f userdata.  Canonical replay must call the command
-- factory with explicit arity, otherwise a queued vanilla New Line never
-- reaches api.cmd.sendCommand on either peer.
local operationCodec = require "tpf2_mp/operation_codec"
local lineTransaction = assert(operationCodec.make("line.create", "company:1", {
  name = "GUI replay regression",
  color = { r = 950, g = 250, b = 100 },
  line = { stops = {} },
}))
saved.world.operations.byId["gui-operation-regression"] = {
  operationId = "gui-operation-regression",
  transaction = lineTransaction,
  localRefs = {},
  nativePlayerId = 100,
  status = "queued",
}
script.load(saved)
local originalUnpack = unpack
unpack = function() error({ code = "engine-userdata-unpack" }) end
local replayOk, replayError = pcall(script.guiUpdate)
unpack = originalUnpack
assert(replayOk, tostring(replayError))
assert(#issuedCanonicalCommands == 1
    and issuedCanonicalCommands[1].kind == "create-line"
    and issuedCanonicalCommands[1].name == "GUI replay regression",
  "canonical line replay depended on Build 35924's userdata-unsafe unpack")
assert(authorizedCommandTags[#authorizedCommandTags] == 3,
  "canonical line replay did not authorize the exact CreateLine visitor tag")

-- The initiating peer must acknowledge the already-applied widget result,
-- not create a duplicate line while the remote peer performs normal replay.
local issuedBeforeOriginAck = #issuedCanonicalCommands
saved.world.operations.byId["gui-origin-applied-regression"] = {
  operationId = "gui-origin-applied-regression",
  transaction = lineTransaction,
  localRefs = {},
  nativePlayerId = 100,
  status = "queued",
  originApplied = { localId = 799, capturedTick = 1 },
}
script.load(saved)
script.guiUpdate()
script.guiUpdate()
local originAck = sentEvents[#sentEvents]
assert(#issuedCanonicalCommands == issuedBeforeOriginAck,
  "initiating vanilla line command was replayed a second time locally")
assert(originAck.name == "operation.result"
    and originAck.param.operationId == "gui-origin-applied-regression"
    and originAck.param.success == true
    and originAck.param.outputLocalId == 799
    and originAck.param.originApplied == true,
  "optimistic vanilla line result was not returned to canonical finalisation")

-- The stock manager can retire a newly-created empty line while its ordered
-- event is in flight (the live P2 crash occurred when opening a depot).  Once
-- absence is proven, replay exactly once and mark the result so the engine
-- finaliser performs strict postcondition checking rather than optimistic
-- origin attestation.
lineEntities[799] = nil
lineEntities[800] = nil
local issuedBeforeOriginRecovery = #issuedCanonicalCommands
saved.world.operations.byId["gui-origin-recovery-regression"] = {
  operationId = "gui-origin-recovery-regression",
  transaction = lineTransaction,
  localRefs = {},
  nativePlayerId = 100,
  status = "queued",
  originApplied = { localId = 799, capturedTick = 1 },
}
script.load(saved)
for _ = 1, 10 do script.guiUpdate() end
local originRecovery
for index = #sentEvents, 1, -1 do
  local candidate = sentEvents[index]
  if candidate.name == "operation.result"
    and candidate.param.operationId == "gui-origin-recovery-regression" then
    originRecovery = candidate
    break
  end
end
assert(#issuedCanonicalCommands == issuedBeforeOriginRecovery + 1
    and issuedCanonicalCommands[#issuedCanonicalCommands].kind == "create-line",
  "a vanished optimistic line was not recovered through canonical replay")
assert(originRecovery and originRecovery.param.success == true
    and originRecovery.param.outputLocalId == 800
    and originRecovery.param.originReplayed == true,
  "recovered optimistic line did not carry its strict-finalisation marker")
lineEntities[799] = true

-- Buying is pre-mutation: the stock GUI contributes the consist while the
-- pinned visitor contributes the actual player/depot identity. Retain the
-- live train+waggon resource namespaces, then exercise direct SetLine capture.
script.guiHandleEvent("vehicleManager", "accept", {
  entity = -1,
  vehicleConfig = {
    "vehicle/train/db_v100_v2.mdl",
    "vehicle/waggon/open_1910.mdl",
    "vehicle/waggon/open_1910.mdl",
  },
})
nativeVehicleCommands[#nativeVehicleCommands + 1] = "V2|13|100|750|0"
script.guiUpdate()
local vanillaBuy = sentEvents[#sentEvents]
assert(vanillaBuy.name == "intent" and vanillaBuy.param.type == "operation.capture"
  and vanillaBuy.param.capture.kind == "vehicle.buy"
  and vanillaBuy.param.capture.depotLocalId == 750
  and vanillaBuy.param.capture.nativePlayerId == 100
  and vanillaBuy.param.capture.vehicleConfig[1] == "vehicle/train/db_v100_v2.mdl"
  and vanillaBuy.param.capture.vehicleConfig[2] == "vehicle/waggon/open_1910.mdl",
  "suppressed stock train purchase was not correlated into vehicle.buy")

local replacementConfig = {
  "vehicle/train/db_v100_v2.mdl",
  "vehicle/waggon/open_1910.mdl",
}
script.guiHandleEvent("vehicleManager", "accept", {
  entity = 760,
  vehicleConfig = replacementConfig,
})
local replacementEventCount = #sentEvents
nativeVehicleCommands[#nativeVehicleCommands + 1] = "V2|14|760|0|0"
local vanillaReplace
for _ = 1, 8 do
  script.guiUpdate()
  for eventIndex = replacementEventCount + 1, #sentEvents do
    local candidate = sentEvents[eventIndex]
    if candidate.name == "intent" and candidate.param.type == "operation.capture"
      and candidate.param.capture.kind == "vehicle.replace" then
      vanillaReplace = candidate
      break
    end
  end
  if vanillaReplace then break end
end
assert(vanillaReplace and vanillaReplace.param.capture.targetLocalId == 760
    and vanillaReplace.param.capture.vehicleConfig[1] == replacementConfig[1]
    and vanillaReplace.param.capture.vehicleConfig[2] == replacementConfig[2],
  "suppressed stock replacement was not correlated into vehicle.replace")

-- GUI/native correlation must preserve carrier-neutral model resources.  The
-- game-script normalizer now extracts these exact names instead of silently
-- discarding everything outside train/ and waggon/.
for index, model in ipairs({
  "vehicle/bus/ecitaro_v2.mdl",
  "vehicle/truck/40_tons_universal_v2.mdl",
  "vehicle/tram/asia/ktm_1_v2.mdl",
  "vehicle/ship/damen_ferry_v2.mdl",
  "vehicle/plane/airbus_a320_v2.mdl",
  "vehicle/example_mod/hoverbus.mdl",
}) do
  local priorEventCount = #sentEvents
  script.guiHandleEvent("vehicleManager", "accept", {
    entity = -1, vehicleConfig = { model },
  })
  nativeVehicleCommands[#nativeVehicleCommands + 1] =
    "V2|13|100|" .. tostring(750 + index) .. "|0"
  local capture
  for _ = 1, 8 do
    script.guiUpdate()
    for eventIndex = priorEventCount + 1, #sentEvents do
      local candidate = sentEvents[eventIndex]
      local value = candidate and candidate.param and candidate.param.capture
      if candidate.name == "intent" and candidate.param.type == "operation.capture"
        and value and value.kind == "vehicle.buy" and value.vehicleConfig[1] == model then
        capture = value
        break
      end
    end
    if capture then break end
  end
  assert(capture and capture.depotLocalId == 750 + index,
    "stock vehicle-manager correlation lost portable carrier " .. model)
end

nativeVehicleCommands[#nativeVehicleCommands + 1] = "V2|6|760|700|-1"
script.guiUpdate()
local vanillaAssign = sentEvents[#sentEvents]
assert(vanillaAssign.name == "intent" and vanillaAssign.param.type == "operation.capture"
  and vanillaAssign.param.capture.kind == "vehicle.assign"
  and vanillaAssign.param.capture.targetLocalId == 760
  and vanillaAssign.param.capture.lineLocalId == 700
  and vanillaAssign.param.capture.stopIndex == -1,
  "suppressed stock automatic-stop SetLine was not converted into vehicle.assign")

local lifecycleCases = {
  { "V2|7|760|0|0", "vehicle.reverse", function(capture)
      return capture.targetLocalId == 760
    end, "Reverse" },
  { "V2|8|760|0|1", "vehicle.stop", function(capture)
      return capture.targetLocalId == 760 and capture.stopped == true
    end, "SetUserStopped" },
  { "V2|9|760|0|8750", "vehicle.maintenance", function(capture)
      return capture.targetLocalId == 760 and capture.valueBasisPoints == 8750
    end, "maintenance" },
  { "V2|10|760|0|0", "vehicle.depart", function(capture)
      return capture.targetLocalId == 760
    end, "SetVehicleShouldDepart" },
  { "V2|11|760|0|0", "vehicle.send_to_depot", function(capture)
      return capture.targetLocalId == 760 and capture.sellOnArrival == false
    end, "SendToDepot" },
  { "V2|12|760|1|0", "vehicle.sell", function(capture)
      return capture.targetLocalId == 760
    end, "single SellVehicle" },
  { "V2|30|760|0|1", "vehicle.manual_departure", function(capture)
      return capture.targetLocalId == 760 and capture.manual == true
    end, "manual departure" },
}
for _, case in ipairs(lifecycleCases) do
  local priorEventCount = #sentEvents
  nativeVehicleCommands[#nativeVehicleCommands + 1] = case[1]
  local event, capture
  for _ = 1, 8 do
    script.guiUpdate()
    for eventIndex = priorEventCount + 1, #sentEvents do
      local candidate = sentEvents[eventIndex]
      local candidateCapture = candidate and candidate.param and candidate.param.capture or {}
      if candidate.name == "intent" and candidate.param.type == "operation.capture"
        and candidateCapture.kind == case[2] then
        event, capture = candidate, candidateCapture
        break
      end
    end
    if event then break end
  end
  assert(event and case[3](capture),
    "suppressed stock " .. case[4] .. " was not converted into " .. case[2])
end

-- V1 remains a narrow compatibility decoder for a stale 0.13 hook. It must
-- never be accepted as evidence for lifecycle tags introduced by V2.
local decoderGui = {
  snapshot = { networkMode = "network", activeCompanyCid = "company:1" },
  frames = 1,
  pendingNativeVehicleCommands = {}, pendingNativeVehicleGuiCaptures = {},
  nativeVehicleCapture = {},
}
local decodedActions = {}
local decoderRuntime = require("tpf2_mp/gui_vehicle_capture_runtime").install(decoderGui, {
  queueAction = function(action) decodedActions[#decodedActions + 1] = action end,
  maxStops = 256,
})
local decoder = decoderRuntime.decode
assert(decoder("V1|6|760|700|-1") and decoder("V1|13|100|750|0"),
  "narrow V1 vehicle envelope compatibility regressed")
for _, invalid in ipairs({
  "V1|7|760|0|0", "V2|8|760|0|2", "V2|9|760|0|10001",
  "V2|10|760|1|0", "V2|12|760|0|0", "V2|12|760|257|0",
  "V2|12|760|2|0", "V2|12|760|1|1", "V2|14|760|0|1",
  "V2|30|760|0|-1", "V3|12|0|760", "V3|12|2|760",
  "V3|12|2|760,760", "V3|12|2|760,-1", "V3|12|2|760,",
}) do
  assert(not decoder(invalid), "invalid native lifecycle envelope was admitted: " .. invalid)
end
nativeVehicleCommands[#nativeVehicleCommands + 1] = "V3|12|2|760,761"
assert(decoderRuntime.process() == true and #decodedActions == 1
    and decodedActions[1].type == "operation.capture"
    and decodedActions[1].capture.kind == "vehicle.sell_batch"
    and decodedActions[1].capture.targetLocalIds[1] == 760
    and decodedActions[1].capture.targetLocalIds[2] == 761
    and decoderGui.nativeVehicleCapture.sales == 2
    and decoderGui.nativeVehicleCapture.saleBatches == 1,
  "multi-vehicle stock sale was not preserved as one canonical batch capture")

-- A canonical replay arrives after the issuing builder's original command was
-- suppressed.  If that replay replaces a signalled edge, Build 35924 can keep
-- emitting proposal userdata backed by the removed edge until the replay's
-- callback/wallet sample has settled.  The origin must not dereference those
-- stale previews, and a second click in that short interval must fail visibly.
local proposalCodec = require "tpf2_mp/proposal_codec"
local replayRuntimeModule = require "tpf2_mp/gui_replay_runtime"
local eventRuntimeModule = require "tpf2_mp/gui_event_runtime"
local replayGui = require("tpf2_mp/gui_state").new()
replayGui.frames = 500
local replayState = {
  networkMode = "network",
  world = { proposals = { byId = {
    ["gui-replay-quarantine"] = {
      proposalId = "gui-replay-quarantine",
      status = "queued",
      transaction = { schemaVersion = proposalCodec.SCHEMA_VERSION, digest = "quarantine" },
      localRefs = {},
      nativeOwnerPlayerId = 100,
      issuerPlayerId = 100,
    },
  } } },
}
local originalMaterialise = proposalCodec.materialise
local originalBuildFactory = api.cmd.make.buildProposal
local originalAuthorizeBuild = rawget(_G, "tpf2mp_native_authorize_build")
local replayMaterialiseCalls = {}
proposalCodec.materialise = function(transaction, options)
  replayMaterialiseCalls[#replayMaterialiseCalls + 1] = {
    transaction = transaction, options = options,
  }
  return { replay = true }
end
local replayBuildCalls = {}
api.cmd.make.buildProposal = function(proposal, context, ignoreErrors)
  replayBuildCalls[#replayBuildCalls + 1] = {
    context = context, ignoreErrors = ignoreErrors,
  }
  return { kind = "build-proposal", proposal = proposal }
end
tpf2mp_native_authorize_build = function() return true end
local replayRuntime = replayRuntimeModule.new({
  getState = function() return replayState end,
  gui = replayGui,
  collectNumeric = function() return {} end,
  safeField = function(value, key) return type(value) == "table" and value[key] or nil end,
  eventShape = function() return {} end,
  componentEntitySet = function() return {} end,
  balanceOf = function() return 10000000 end,
  queueAction = function() end,
})
assert(replayRuntime.processProposalQueue() == true
    and replayGui.proposalReplayQuarantine
    and replayGui.proposalReplayQuarantine.proposalId == "gui-replay-quarantine"
    and replayGui.proposalReplayQuarantine.phase == "armed"
    and enabled.mainView == false and #replayBuildCalls == 0,
  "canonical replay did not suspend the native selector before materialisation")
replayGui.frames = replayGui.frames + 1
assert(replayRuntime.processProposalQueue() == true
    and replayBuildCalls[#replayBuildCalls].ignoreErrors == false
    and replayGui.pendingProposalCaptures[1].captureStartedFrame == 501
    and replayGui.pendingProposalCaptures[1].canonicalFinanceFallbackFrame == 591
    and replayGui.pendingProposalCaptures[1].maximumFrame == 861,
  "canonical BuildProposal replay did not arm its stale-builder quarantine")
for expectedFrame = 502, 503 do
  replayGui.frames = expectedFrame
  replayRuntime.processProposalQueue()
  assert(enabled.mainView == false, "native selector resumed before replay components settled")
end
replayGui.frames = 504
replayRuntime.processProposalQueue()
assert(enabled.mainView == true and replayGui.proposalReplayQuarantine,
  "native selector did not resume independently of the longer finance quarantine")

local referenceGuard = require "tpf2_mp/gui_replay_reference_guard"
local stagedFreshStation = {
  edges = {
    { node0 = { slot = "node:1" }, node1 = { slot = "node:2" } },
    { node0 = { slot = "node:3" }, node1 = { slot = "node:4" } },
  },
  constructions = { {
    mode = "build", kind = "rail_station",
    collateral = {
      { kind = "construction", cid = "construction:pre:house:1" },
      { kind = "construction", cid = "construction:pre:house:2" },
    },
  } },
}
assert(referenceGuard.validate(stagedFreshStation, {}, nil, {
    omitConstructionCollateral = true,
  }),
  "slot-local station after collateral demolition incorrectly required a canonical-node API")

-- Connected depots use a helper-built shell followed by a topology-only GUI
-- repair. Their collateral has already been demolished before that second
-- replay. The old path-name special case covered staged stations only, so the
-- guard demanded the now-absent house and faulted both otherwise equal worlds.
local guiConstructionReplay = require "tpf2_mp/gui_construction_replay"
local depotConnectionRepairForCollateral = require "tpf2_mp/construction_depot_connection_repair"
local originalDepotMaterialiseForCollateral = depotConnectionRepairForCollateral.materialise
depotConnectionRepairForCollateral.materialise = function()
  return { repaired = true }, { transaction = { nodes = {}, edges = {} } }
end
local postCollateralDepot, postCollateralDepotError = guiConstructionReplay.materialise({
  replayPath = "helper-depot-connection",
  constructionPending = { collateralRetired = true },
  transaction = {
    nodes = {}, edges = {}, remove = { nodes = {}, edges = {} },
    edgeObjects = { add = {}, retain = {}, remove = {} },
    constructions = { {
      mode = "build", kind = "depot",
      collateral = {
        { kind = "construction", cid = "construction:pre:demolished-house" },
      },
    } },
  },
}, { ["construction:pre:demolished-house"] = 901 }, 100, nil)
depotConnectionRepairForCollateral.materialise = originalDepotMaterialiseForCollateral
assert(postCollateralDepot and postCollateralDepot.repaired == true,
  "post-collateral depot connector revalidated its demolished house: "
    .. tostring(postCollateralDepotError))
local referenceTransaction = { edges = {{
  node0 = { cid = "node:event:prior:3" }, node1 = { slot = "node:1" },
}} }
local referenceApi = {
  type = { ComponentType = { BASE_NODE = "BASE_NODE" } },
  engine = {
    entityExists = function(id) return id == 77 end,
    getComponent = function(id, component) return id == 77 and component == "BASE_NODE" and {} or nil end,
  },
}
assert(referenceGuard.validate(referenceTransaction, { ["node:event:prior:3"] = 77 }, referenceApi),
  "live canonical attachment node failed immediate replay preflight")
local callableReferenceApi = {
  type = referenceApi.type,
  engine = {
    entityExists = referenceApi.engine.entityExists,
    getComponent = setmetatable({}, { __call = function(_, id, component)
      return referenceApi.engine.getComponent(id, component)
    end }),
  },
}
assert(referenceGuard.validate(
    referenceTransaction, { ["node:event:prior:3"] = 77 }, callableReferenceApi),
  "callable native component reader was mistaken for an unavailable Lua function")
local missingApiReference, missingApiReferenceError = referenceGuard.validate(
  referenceTransaction, { ["node:event:prior:3"] = 77 }, nil)
assert(not missingApiReference and missingApiReferenceError:find("API is unavailable", 1, true),
  "canonical attachment bypassed the fail-closed preflight when its API was unavailable")
local missingReference, missingReferenceError = referenceGuard.validate(
  referenceTransaction, { ["node:event:prior:3"] = 78 }, referenceApi)
assert(not missingReference and missingReferenceError:find("disappeared", 1, true),
  "stale canonical attachment node was allowed into native materialisation")

do
-- A native BuildProposal rejection can mutate an existing edge in place while
-- leaving every entity ID intact. That is the residue sequence which later
-- reached Build 35924's StreetGeometry assertion in live relay sessions.
local topologyGuard = require "tpf2_mp/gui_native_topology_guard"
local topologyComponents = {
  BASE_NODE = {
    [201] = { position = { x = 0, y = 0, z = 0 } },
    [202] = { position = { x = 20, y = 0, z = 0 } },
  },
  BASE_EDGE = { [203] = {
    node0 = 201, node1 = 202,
    tangent0 = { x = 20, y = 0, z = 0 },
    tangent1 = { x = 20, y = 0, z = 0 }, objects = {},
  } },
  BASE_EDGE_TRACK = { [203] = { trackType = 4, catenary = false } },
}
local topologyApi = {
  type = { ComponentType = {
    BASE_NODE = "BASE_NODE", BASE_EDGE = "BASE_EDGE",
    BASE_EDGE_STREET = "BASE_EDGE_STREET", BASE_EDGE_TRACK = "BASE_EDGE_TRACK",
    PLAYER_OWNED = "PLAYER_OWNED",
  } },
  engine = {
    entityExists = function(id)
      return topologyComponents.BASE_NODE[id] ~= nil
        or topologyComponents.BASE_EDGE[id] ~= nil
    end,
    getComponent = function(id, kind)
      return topologyComponents[kind] and topologyComponents[kind][id] or nil
    end,
  },
}
local topologyTransaction = {
  nodes = {}, edges = {},
  edgeObjects = { add = {}, retain = {}, remove = {} },
  remove = { edges = { "edge:event:prior:1" }, nodes = {} },
}
local topologyBefore = assert(topologyGuard.capture(
  topologyTransaction, { ["edge:event:prior:1"] = 203 }, topologyApi))
topologyComponents.BASE_EDGE[203].tangent0.x = 17
local topologyAfter = assert(topologyGuard.recapture(topologyBefore, topologyApi))
local topologySame, topologyMutation = topologyGuard.compare(topologyBefore, topologyAfter)
assert(not topologySame and topologyMutation:find("edge:203", 1, true),
  "in-place native edge mutation escaped rejection residue attestation")
topologyComponents.BASE_EDGE[203].tangent0.x = 20

local rejectionSnapshotModule = require "tpf2_mp/gui_proposal_rejection_snapshot"
local rejectionSnapshot = rejectionSnapshotModule.new({
  componentEntitySet = function(kind)
    if kind == "BASE_EDGE" then return { [203] = true } end
    if kind == "BASE_NODE" then return { [201] = true, [202] = true } end
    return {}
  end,
  balanceOf = function() return 5000000 end,
  getApi = function() return topologyApi end,
})
local rejectionBefore = assert(rejectionSnapshot.capture(
  topologyApi.type.ComponentType, 100, 100, false, topologyTransaction,
  { ["edge:event:prior:1"] = 203 }))
topologyComponents.BASE_NODE[202].position.y = 3
local rejectionUnchanged, rejectionMutation = rejectionSnapshot.unchanged(
  rejectionBefore, topologyApi.type.ComponentType, 100, 100)
assert(not rejectionUnchanged and rejectionMutation:find("topology", 1, true),
  "unchanged ID sets concealed an in-place native node mutation")
topologyComponents.BASE_NODE[202].position.y = 0

local staleFingerprint, staleFingerprintError = referenceGuard.validate(
  { edges = {}, edgeObjects = { add = {}, retain = {}, remove = {} },
    remove = { edges = { "edge:pre:deadbeef" }, nodes = {} } },
  { ["edge:pre:deadbeef"] = 203 }, topologyApi,
  { fingerprint = function() return "cafebabe" end })
assert(not staleFingerprint and staleFingerprintError:find("fingerprint changed", 1, true),
  "stale canonical edge fingerprint reached native replay")
end

local quarantineLogs = {}
local quarantineRuntime = eventRuntimeModule.new({
  getState = function() return replayState end,
  gui = replayGui,
  config = function() return { networkAutoValidate = false } end,
  queueAction = function() error("quarantined builder event escaped into the action queue") end,
  renderGui = function() end,
  ensureWindow = function() end,
  installMultiplayerEntryPoints = function() end,
  enforceProxyGuiLocks = function() end,
  componentEntitySet = function() return {} end,
  balanceOf = function() return 10000000 end,
  nativeHookStatus = function() return { available = true, gates = { buildProposal = nativeBuildGate } } end,
  markNativeContext = function() end,
  configureNativeAuthority = function() return true end,
  freezeNetworkGame = function() return true end,
  freezeNetworkCalendar = function() return true end,
  diagnosticLog = function(name, details)
    quarantineLogs[#quarantineLogs + 1] = { name = name, details = details }
  end,
  projectNetworkSpeedIndicator = function() end,
})
local stalePreviewTouched = false
local stalePreview = setmetatable({}, {
  __index = function()
    stalePreviewTouched = true
    error("stale native proposal userdata was dereferenced")
  end,
})
-- Lua 5.1 does not honour __pairs, so intercept iteration explicitly as well
-- as indexing. This makes the regression prove that the event envelope itself
-- is never traversed, rather than only proving that no named field is read.
local originalPairs = pairs
local originalIpairs = ipairs
pairs = function(value)
  if rawequal(value, stalePreview) then
    stalePreviewTouched = true
    error("stale native proposal userdata was traversed")
  end
  return originalPairs(value)
end
ipairs = function(value)
  if rawequal(value, stalePreview) then
    stalePreviewTouched = true
    error("stale native proposal userdata was traversed")
  end
  return originalIpairs(value)
end
assert(quarantineRuntime.handleEvent(
    "streetTerminalBuilder", "builder.proposalCreate", stalePreview) == nil
    and stalePreviewTouched == false
    and replayGui.nativeBuildCapture.replayPreviewsQuarantined == 1
    and quarantineLogs[1].name == "proposal-replay-preview-quarantined",
  "in-flight signal-builder preview was not quarantined without dereferencing its payload")
local rejectedReplayClick = quarantineRuntime.handleEvent(
  "streetTerminalBuilder", "builder.apply", stalePreview)
pairs = originalPairs
ipairs = originalIpairs
assert(type(rejectedReplayClick) == "table"
    and rejectedReplayClick.errorMessages[1]:find("still synchronising", 1, true)
    and stalePreviewTouched == false
    and replayGui.nativeBuildCapture.replayAppliesRejected == 1,
  "a second builder click crossed the canonical replay quarantine")

-- The guard ends only after proposal.result crosses back to engine state.
replayGui.pendingProposalCaptures = {}
replayGui.proposalResults = {{
  proposalId = "gui-replay-quarantine", success = true,
}}
local resultCountBeforeQuarantineRelease = #sentEvents
assert(replayRuntime.processProposalQueue() == true
    and replayGui.proposalReplayQuarantine == nil
    and enabled.mainView == true
    and #sentEvents == resultCountBeforeQuarantineRelease + 1
    and sentEvents[#sentEvents].name == "proposal.result",
  "proposal replay quarantine did not release at the engine result boundary")

local replayQuarantineModule = require "tpf2_mp/gui_replay_quarantine"
local function issueQueuedReplay()
  local result = replayRuntime.processProposalQueue()
  if replayGui.proposalReplayQuarantine
      and replayGui.proposalReplayQuarantine.phase == "armed" then
    replayGui.frames = replayGui.frames + 1
    result = replayRuntime.processProposalQueue()
  end
  return result
end

-- Schema 7 normally belongs to the engine-thread construction helper, except
-- when its construction removal is collateral to topology. That exact native
-- proposal must cross the ordinary GUI BuildProposal route atomically.
replayState.world.proposals.byId["gui-helper-upgrade"] = {
  proposalId = "gui-helper-upgrade",
  status = "queued",
  transaction = {
    schemaVersion = proposalCodec.CONSTRUCTION_SCHEMA_VERSION,
    nodes = {}, edges = {},
    edgeObjects = { add = {}, retain = {}, remove = {} },
    remove = { edges = {}, nodes = {} },
    constructions = { { mode = "upgrade" } },
  },
  localRefs = {}, nativeOwnerPlayerId = 100, issuerPlayerId = 100,
}
assert(replayRuntime.processProposalQueue() == false
    and replayGui.proposalReplayQuarantine == nil,
  "helper-owned construction upgrade leaked into GUI BuildProposal replay")
replayState.world.proposals.byId["gui-topology-collateral"] = {
  proposalId = "gui-topology-collateral",
  status = "queued",
  transaction = {
    schemaVersion = proposalCodec.CONSTRUCTION_SCHEMA_VERSION,
    nodes = {}, edges = { {} },
    edgeObjects = { add = {}, retain = {}, remove = {} },
    remove = { edges = {}, nodes = {} },
    constructions = { { mode = "remove" } },
  },
  localRefs = {}, nativeOwnerPlayerId = 100, issuerPlayerId = 100,
}
assert(issueQueuedReplay() == true
    and replayGui.proposalReplayQuarantine
    and replayGui.proposalReplayQuarantine.proposalId == "gui-topology-collateral",
  "schema-7 topology demolition did not use atomic GUI BuildProposal replay")
assert(replayBuildCalls[#replayBuildCalls].ignoreErrors == true,
  "GUI-approved topology demolition did not preserve vanilla soft-error acceptance")
replayQuarantineModule.reset(replayGui)

replayState.world.proposals.byId["gui-town-road-collateral"] = {
  proposalId = "gui-town-road-collateral",
  status = "queued",
  transaction = {
    schemaVersion = proposalCodec.CONSTRUCTION_SCHEMA_VERSION,
    nodes = {}, edges = {},
    edgeObjects = { add = {}, retain = {}, remove = {} },
    remove = { edges = { "edge:pre:town-road" }, nodes = { "node:pre:road-end" } },
    constructions = { {
      mode = "remove", kind = "construction",
      collateral = { { kind = "construction", cid = "construction:pre:house" } },
    } },
  },
  localRefs = {}, nativeOwnerPlayerId = 100, issuerPlayerId = 100,
}
assert(issueQueuedReplay() == true
    and replayGui.proposalReplayQuarantine
    and replayGui.proposalReplayQuarantine.proposalId == "gui-town-road-collateral",
  "removal-only town road and attached buildings did not use atomic GUI replay")
assert(replayBuildCalls[#replayBuildCalls].ignoreErrors == true,
  "town-road collateral demolition did not preserve vanilla soft-error acceptance")
replayQuarantineModule.reset(replayGui)

local stagedEntityExists = api.engine.entityExists
local stagedGetComponent = api.engine.getComponent
api.type.ComponentType.BASE_EDGE_TRACK = "BASE_EDGE_TRACK"
api.engine.entityExists = function(id)
  return id == 77 or id == 78 or id == 79 or stagedEntityExists(id)
end
api.engine.getComponent = function(id, componentType)
  if id == 77 and componentType == "BASE_EDGE" then
    return {
      node0 = 78, node1 = 79,
      tangent0 = { x = 20, y = 0, z = 0 },
      tangent1 = { x = 20, y = 0, z = 0 }, objects = {},
    }
  end
  if (id == 78 or id == 79) and componentType == "BASE_NODE" then
    return { position = { x = id, y = 0, z = 0 } }
  end
  if id == 77 and componentType == "BASE_EDGE_TRACK" then
    return { trackType = 0, catenary = false }
  end
  return stagedGetComponent(id, componentType)
end
replayState.world.proposals.byId["gui-staged-connected-terminal"] = {
  proposalId = "gui-staged-connected-terminal",
  status = "queued",
  replayPath = "staged-gui-build-proposal",
  transaction = {
    schemaVersion = proposalCodec.CONSTRUCTION_SCHEMA_VERSION,
    nodes = {}, edges = {},
    edgeObjects = { add = {}, retain = {}, remove = {} },
    remove = { edges = { "edge:pre:town-road" }, nodes = {} },
    constructions = { {
      mode = "build", kind = "station",
      collateral = { { kind = "construction", cid = "construction:pre:house" } },
    } },
  },
  localRefs = { ["edge:pre:town-road"] = 77 },
  nativeOwnerPlayerId = 100, issuerPlayerId = 100,
}
local stagedReplayIssued
for _ = 1, 6 do
  stagedReplayIssued = issueQueuedReplay()
  if replayGui.proposalReplayQuarantine
      and replayGui.proposalReplayQuarantine.proposalId == "gui-staged-connected-terminal" then break end
end
assert(stagedReplayIssued == true
    and replayGui.proposalReplayQuarantine
    and replayGui.proposalReplayQuarantine.proposalId == "gui-staged-connected-terminal"
    and replayMaterialiseCalls[#replayMaterialiseCalls].options.omitConstructionCollateral == true
    and replayBuildCalls[#replayBuildCalls].ignoreErrors == true,
  "post-collateral terminal did not use pointer-free exact GUI replay")
replayQuarantineModule.reset(replayGui)
api.engine.entityExists = stagedEntityExists
api.engine.getComponent = stagedGetComponent
api.type.ComponentType.BASE_EDGE_TRACK = nil

local successfulSendCommand = api.cmd.sendCommand
api.cmd.sendCommand = function(command, callback)
  if callback then callback(command, false) end
  return true
end
replayState.world.proposals.byId["gui-rejected-unchanged"] = {
  proposalId = "gui-rejected-unchanged", status = "queued",
  transaction = { schemaVersion = proposalCodec.SCHEMA_VERSION, digest = "rejected" },
  localRefs = {}, nativeOwnerPlayerId = 100, issuerPlayerId = 100,
}
assert(issueQueuedReplay() == true,
  "rejected canonical proposal did not enter GUI replay")
local rejectedResultCount = #sentEvents
assert(replayRuntime.processProposalQueue() == true
    and #sentEvents == rejectedResultCount + 1
    and sentEvents[#sentEvents].name == "proposal.result"
    and sentEvents[#sentEvents].param.success == false
    and sentEvents[#sentEvents].param.worldUnchanged == true,
  "unchanged native rejection was not attested for PREPARE-core rollback")
api.cmd.sendCommand = successfulSendCommand

-- A typed-userdata ABI mismatch must never strand a proposal before the
-- native callback.  Convert the exception into an unchanged-world result so
-- consensus can reject the prepared action and release the quarantine.
proposalCodec.materialise = function()
  error("unknown BaseEdgeStreet field 'bus'")
end
replayState.world.proposals.byId["gui-materialise-exception"] = {
  proposalId = "gui-materialise-exception", status = "queued",
  transaction = {
    schemaVersion = proposalCodec.SCHEMA_VERSION,
    digest = "materialise-exception",
  },
  localRefs = {}, nativeOwnerPlayerId = 100, issuerPlayerId = 100,
}
assert(issueQueuedReplay() == true,
  "proposal materialisation exception did not enter guarded GUI replay")
local materialiseExceptionResultCount = #sentEvents
local materialiseExceptionResult
for _ = 1, 8 do
  replayGui.frames = replayGui.frames + 1
  replayRuntime.processProposalQueue()
  for index = materialiseExceptionResultCount + 1, #sentEvents do
    local candidate = sentEvents[index]
    if candidate.name == "proposal.result"
        and candidate.param.proposalId == "gui-materialise-exception" then
      materialiseExceptionResult = candidate
      break
    end
  end
  if materialiseExceptionResult then break end
end
assert(materialiseExceptionResult
    and materialiseExceptionResult.param.success == false
    and materialiseExceptionResult.param.worldUnchanged == true
    and tostring(materialiseExceptionResult.param.error):find(
      "proposal materialisation failed", 1, true),
  "proposal materialisation exception did not fail closed with a result")
proposalCodec.materialise = originalMaterialise
api.cmd.make.buildProposal = originalBuildFactory
rawset(_G, "tpf2mp_native_authorize_build", originalAuthorizeBuild)

local economySnapshot = {
  activeCompanyCid = "company:1",
  economyPresentation = {
    activeCompanyCid = "company:1",
    localVehicles = { ["60"] = "vehicle:event:test:1" },
    localLines = { ["70"] = "line:event:test:1" },
    vehicles = { ["vehicle:event:test:1"] = {
      purchasePriceDollars = 8000000,
      annualVehicleUpkeepCents = 120000000,
      intervalVehicleUpkeepCents = 3333333,
      projectedHourlyVehicleUpkeepCents = 40000000,
      line = { pendingGrossRevenueCents = 640000,
        grossRevenueCents = 250000, netRevenueCents = 110000 },
    } },
    services = { ["line:event:test:1"] = {
      fareCents = 1200, topSpeedKmh = 160,
      journeySeconds = 900, headwaySeconds = 600,
      delivered = 24, pendingDelivered = 8, pendingGrossRevenueCents = 640000,
      grossRevenueCents = 250000, vehicleUpkeepCents = 140000,
      netRevenueCents = 110000, projectedHourlyNetRevenueCents = 1320000,
      outsideCostCents = 2500,
      fareAtOutsideParityCents = 2313,
    } },
    companies = { ["company:1"] = {
      grossRevenueCents = 250000, vehicleUpkeepCents = 140000,
      infrastructureUpkeepCents = 5000, netRevenueCents = 105000,
      pendingGrossRevenueCents = 640000, projectedHourlyNetRevenueCents = 1260000,
    } },
  },
}

-- Authoritative presentation rewrites existing stock leaves only. Build 35924
-- crashes if an api.gui child is retained in a hidden native manager layout,
-- so this test also proves that the adapter creates no tpf2mp.stock widgets.
local function registerText(id, text)
  local value = TextView.new(text or "")
  value:setId(id)
  function value:getText() return self.text end
  function value:getId() return self.id end
  function value:getName() return self.name or "TextView" end
  function value:setName(name) self.name = name end
  function value:setVisible(visible) self.visible = visible end
  return value
end

local function stockNode(name, id)
  local value = object({ name = name, id = id or "", visible = true })
  function value:getName() return self.name end
  function value:getId() return self.id end
  function value:getParent() return self.parent end
  function value:getLayout() return self.layout end
  function value:setVisible(visible) self.visible = visible end
  function value:setTooltip(text) self.tooltip = tostring(text) end
  function value:getText() return self.text end
  function value:setText(text) self.text = tostring(text) end
  if id and id ~= "" then guiById[id] = value end
  return value
end

local function stockWindow(seedId, nativeName)
  local window = stockNode("Window")
  window.layout = BoxLayout.new("VERTICAL")
  local native = stockNode(nativeName or "StockContent")
  native.layout = BoxLayout.new("VERTICAL")
  native.parent = window
  window.layout:addItem(native)
  local seed = stockNode("Button", seedId)
  seed.parent = native
  native.layout:addItem(seed)
  return window, native, seed
end

registerText("gameInfo.earningsComp.earningsText", "Earnings")
registerText("gameInfo.earningsComp.earnings", "$999m")
registerText("gameInfo.passengerComp.numPassenger", "1")
registerText("gameInfo.cargoComp.numCargo", "2")
registerText("menu.financesButton.number", "999")
registerText("menu.financesButton.label", "Account")
guiById["gameInfo.passengerComp"] = stockNode("PassengerComp", "gameInfo.passengerComp")
guiById["gameInfo.cargoComp"] = stockNode("CargoComp", "gameInfo.cargoComp")
guiById["menu.financesButton"] = stockNode("FinancesButton", "menu.financesButton")

local entityWindow, entityNative = stockWindow("temp.view.entity_60", "VehicleContent")
local nativeVehicleCargo = stockNode("VehicleCargo")
nativeVehicleCargo.parent = entityNative
entityNative.layout:addItem(nativeVehicleCargo)
local nativeFinancesLabel = registerText("test.native.vehicle.finances", "Finances")
nativeFinancesLabel.parent = entityNative
entityNative.layout:addItem(nativeFinancesLabel)
stockWindow("lineManager.newLine", "LineManager")
stockWindow("vehicleManager.buyVehicles", "VehicleManager")
local _, nativeFinances = stockWindow("finances.borrow", "FinancesManager")
stockWindow("menu.stats.lines.table", "LinesTable")
stockWindow("menu.stats.vehicles.table", "VehiclesTable")
stockWindow("menu.stats.stations.table", "StationsTable")

local stockPresentation = require "tpf2_mp/gui_stock_presentation"
local stockGui = {
  frames = 30,
  selectedEntityKind = "vehicle",
  selectedEntityId = 60,
  selectedVehicleId = 60,
  selectedLineId = 70,
}
local stockSnapshot = {
  initialized = true,
  activeCompanyCid = "company:1",
  activeCompanyName = "Company 1",
  epoch = 3,
  companies = { ["company:1"] = {
    name = "Company 1", balance = 50000000, effectiveBalance = 50000000,
  } },
  ledger = { companies = { ["company:1"] = { netRevenueCents = 315000 } } },
  economyPresentation = economySnapshot.economyPresentation,
  passengerPresentation = {
    localVehicles = { ["60"] = "vehicle:event:test:1" },
    localLines = { ["70"] = "line:event:test:1" },
    localStations = { ["80"] = "station:event:test:1" },
    totals = { aboard = 17, waiting = 29, boarded = 84 },
    vehicles = { ["vehicle:event:test:1"] = {
      name = "Express 1", aboard = 17, capacity = 40,
      originName = "Alpha", destinationName = "Beta", lineName = "Intercity",
    } },
    lines = { ["line:event:test:1"] = {
      name = "Intercity", companyCid = "company:1", allocated = 32, waiting = 29,
    } },
    stations = { ["station:event:test:1"] = {
      name = "Alpha", waiting = 29, throughput = 16,
      lines = { { companyCid = "company:1", name = "Intercity", waiting = 29, allocated = 16 } },
    } },
  },
  cargoPresentation = {
    totals = { aboard = 4, waiting = 7, boarded = 12, delivered = 8 },
    localVehicles = {}, localStations = {}, lines = {}, vehicles = {}, stations = {},
  },
}
assert(stockPresentation.update(stockGui, stockSnapshot, true) == true
    and guiById["gameInfo.earningsComp.earningsText"].text == "TPF2MP net/5m"
    and guiById["gameInfo.earningsComp.earnings"].text == "$1.1k"
    and guiById["gameInfo.passengerComp.numPassenger"].text == "84"
    and guiById["gameInfo.cargoComp.numCargo"].text == "12"
    and guiById["menu.financesButton.number"].text == "50,000,000"
    and guiById["menu.financesButton.label"].text == "TPF2MP account",
  "authoritative projection did not overwrite the stock game bar")
assert(guiById["tpf2mp.stock.entity.60"] == nil
    and guiById["tpf2mp.stock.lineManager"] == nil
    and guiById["tpf2mp.stock.vehicleManager"] == nil
    and guiById["tpf2mp.stock.finances"] == nil
    and guiById["tpf2mp.stock.lineStatistics"] == nil
    and guiById["tpf2mp.stock.vehicleStatistics"] == nil
    and guiById["tpf2mp.stock.stationStatistics"] == nil,
  "stock presentation inserted a native-layout child")
assert(nativeVehicleCargo.visible == false
    and nativeFinancesLabel.text == "Native history (cosmetic)"
    and nativeFinances.visible == true
    and guiById["menu.stats.lines.table"].visible == true
    and guiById["menu.stats.vehicles.table"].visible == true
    and guiById["menu.stats.stations.table"].visible == true
    and guiById["vehicleManager.buyVehicles"].tooltip
    and guiById["menu.stats.lines.table"].tooltip:find("cosmetic", 1, true),
  "safe stock relabel/tooltip projection did not preserve native layouts")

local stockScans = stockGui.stockPresentation.scans
stockPresentation.handleEvent(stockGui, stockSnapshot, "lineManager", "select", { line = 70 })
stockPresentation.update(stockGui, stockSnapshot)
assert(stockGui.stockPresentation.scans == stockScans,
  "stock UI traversed the native layout from the originating event frame")
stockGui.frames = stockGui.frames + 3
stockPresentation.update(stockGui, stockSnapshot)
assert(stockGui.selectedLineId == 70
    and guiById["lineManager.newLine"].tooltip
    and stockGui.stockPresentation.scans == stockScans + 1,
  "stock line-manager selection did not receive one deferred safe refresh")
for _ = 1, 20 do
  stockPresentation.handleEvent(stockGui, stockSnapshot, "lineManager", "select", { line = 70 })
  stockGui.frames = stockGui.frames + 3
  stockPresentation.update(stockGui, stockSnapshot)
end
assert(stockGui.stockPresentation.scans == stockScans + 1
    and stockGui.stockPresentation.coalescedEvents == 20,
  "repeated native selection events still caused stock-window traversal churn")
stockPresentation.handleEvent(stockGui, stockSnapshot, "lineManager", "tabChange", { line = 70 })
stockGui.frames = stockGui.frames + 3
stockPresentation.update(stockGui, stockSnapshot)
assert(stockGui.stockPresentation.scans == stockScans + 2,
  "a distinct stock-window event was swallowed by event-storm coalescing")
stockPresentation.handleEvent(stockGui, stockSnapshot,
  "streetTerminalBuilder", "builder.proposalCreate", {
    proposal = { streetProposal = { edgesToAdd = { {}, {}, {} } } },
  })
stockGui.frames = stockGui.frames + 3
stockPresentation.update(stockGui, stockSnapshot)
assert(stockGui.stockPresentation.scans == stockScans + 2
    and stockGui.stockPresentation.dirty ~= true,
  "irrelevant construction previews still entered stock-window traversal")

local lineWindow, lineNative = stockWindow("temp.view.entity_70", "line-extension")
local nativeTransported = registerText("test.native.line.transported", "Transported")
nativeTransported.parent = lineNative
lineNative.layout:addItem(nativeTransported)
stockGui.selectedEntityKind, stockGui.selectedEntityId = "line", 70
assert(stockPresentation.update(stockGui, stockSnapshot, true) == true
    and lineWindow.tooltip:find("demand model", 1, true)
    and nativeTransported.text == "Native transported (cosmetic)",
  "stock line window did not receive safe authoritative context")

local stationWindow, stationNative = stockWindow("temp.view.entity_80", "stationgroup-window")
local nativeStationBoard = stockNode("StationGroupDisplayComp")
nativeStationBoard.parent = stationNative
stationNative.layout:addItem(nativeStationBoard)
stockGui.selectedEntityKind, stockGui.selectedEntityId = "station_group", 80
assert(stockPresentation.update(stockGui, stockSnapshot, true) == true
    and stationWindow.tooltip:find("synchronized passenger and cargo queues", 1, true)
    and nativeStationBoard.visible == false,
  "stock station window did not receive safe authoritative context")

local authoritativeText = require "tpf2_mp/gui_authoritative_text"
local cargoTextSnapshot = {
  activeCompanyCid = "company:1",
  economyPresentation = {
    localLines = { ["90"] = "line:cargo" },
    localVehicles = { ["91"] = "vehicle:cargo" },
    services = { ["line:cargo"] = {
      lineCid = "line:cargo", companyCid = "company:1", kind = "cargo",
      name = "Grain Shuttle", fareCents = 1000, journeySeconds = 600,
      headwaySeconds = 900, capacity = 160, hourlyMarketDemand = 120,
      allocated = 40, delivered = 20, pendingDelivered = 5,
      netRevenueCents = 250000, projectedHourlyNetRevenueCents = 3000000,
    } },
    vehicles = { ["vehicle:cargo"] = {
      companyCid = "company:1", lineCid = "line:cargo",
      annualVehicleUpkeepCents = 1200000,
    } },
  },
  passengerPresentation = { totals = {}, vehicles = {}, stations = {} },
  cargoPresentation = {
    localVehicles = { ["91"] = "vehicle:cargo" },
    localStations = { ["92"] = "station_group:cargo" },
    totals = { aboard = 25, waiting = 15, boarded = 31, delivered = 20 },
    vehicles = { ["vehicle:cargo"] = {
      name = "Freight 1", lineCid = "line:cargo", lineName = "Grain Shuttle",
      cargoType = "GRAIN", aboard = 25, capacity = 40,
    } },
    lines = { ["line:cargo"] = {
      name = "Grain Shuttle", companyCid = "company:1", cargoType = "GRAIN",
      allocated = 40, sourceIndustryName = "Farm", destinationIndustryName = "Mill",
    } },
    stations = { ["station_group:cargo"] = {
      name = "Farm Cargo", waiting = 15, delivered = 20,
      lines = { { companyCid = "company:1", name = "Grain Shuttle",
        cargoType = "GRAIN", waiting = 15, delivered = 0, role = "source" } },
    } },
  },
}
assert(authoritativeText.vehicle(cargoTextSnapshot, 91).primary:find(
      "25/40 authored GRAIN", 1, true)
    and authoritativeText.line(cargoTextSnapshot, 90).secondary:find(
      "GRAIN demand/h", 1, true)
    and authoritativeText.station(cargoTextSnapshot, 92).primary:find(
      "15 cargo waiting", 1, true)
    and authoritativeText.station(cargoTextSnapshot, 92).primary:find(
      "20 cargo delivered", 1, true)
    and authoritativeText.toolbar(cargoTextSnapshot).transportedCargo == "31"
    and authoritativeText.vehicleList(cargoTextSnapshot):find("GRAIN", 1, true)
    and authoritativeText.stationList(cargoTextSnapshot):find("15 cargo", 1, true),
  "authoritative cargo line, vehicle, station, toolbar, or manager text is incomplete")

-- A generated userdata marshalling exception must return an explicit failed
-- result. Merely catching it at guiUpdate would leave operationIssued latched
-- and the ordered session pending forever. Keep this last so its deliberately
-- failed ordered record cannot obscure unrelated capture assertions.
saved.world.operations.byId["gui-operation-materialise-failure"] = {
  operationId = "gui-operation-materialise-failure",
  transaction = lineTransaction,
  localRefs = {},
  nativePlayerId = 100,
  status = "queued",
}
local originalOperationMaterialise = operationCodec.materialise
operationCodec.materialise = function() error("typed StationTerminal marshalling failed") end
script.load(saved)
for _ = 1, 4 do script.guiUpdate() end
operationCodec.materialise = originalOperationMaterialise
local materialiseFailure
for index = #sentEvents, 1, -1 do
  local candidate = sentEvents[index]
  if candidate.name == "operation.result"
    and candidate.param.operationId == "gui-operation-materialise-failure" then
    materialiseFailure = candidate
    break
  end
end
assert(materialiseFailure and materialiseFailure.name == "operation.result"
    and materialiseFailure.param.operationId == "gui-operation-materialise-failure"
    and materialiseFailure.param.success == false
    and tostring(materialiseFailure.param.error):find("StationTerminal", 1, true),
  "GUI operation materialisation exception did not close as an explicit failure")

assert(enabled["finances.borrow"] == false and enabled["finances.repay"] == false, "finance controls were not disabled")

-- The four panel features below need more locals than Lua 5.1 leaves in this
-- chunk, so they run in their own scope. The leading semicolon closes the
-- statement above it.
;(function()
  -- The next-action line is a pure function of the public snapshot, so every
  -- state a player can be stuck in is directly testable.
  local guiViewModule = require "tpf2_mp/gui_view"
  local nextActionModule = require "tpf2_mp/gui_next_action"
  local noticesModule = require "tpf2_mp/gui_notices"
  local scoreboardModule = require "tpf2_mp/gui_scoreboard"
  local chrome = guiViewModule.chrome

  local function nextActionCase(snapshot, expected, message)
    local actual = nextActionModule.text(snapshot)
    assert(actual:find(expected, 1, true), message .. " (got: " .. actual .. ")")
  end

  nextActionCase({ networkMode = "standalone" }, "Local mode: nothing is shared",
    "local mode did not say that nothing is shared")
  nextActionCase({
    networkMode = "network", peerId = "player1",
    bridge = { companion = { connected = true, reconnect = {
      graceSeconds = 120, waitingPeers = { player2 = { secondsRemaining = 84 } },
    } } },
  }, "Waiting for Player 2 to reconnect (84 s left)",
    "a reconnect grace countdown was not surfaced")
  nextActionCase({
    networkMode = "network", peerId = "player1",
    bridge = { companion = { connected = true, reconnect = {
      waitingPeers = { player2 = {} },
    } } },
  }, "Waiting for Player 2 to reconnect (up to 120 s)",
    "a reconnect without a published countdown did not fall back to the documented grace")
  nextActionCase({
    networkMode = "network", peerId = "player1",
    bridge = { companion = { connected = true } },
  }, "Waiting for Player 2's world to load",
    "a peer whose world is still loading was not named")
  nextActionCase({
    networkMode = "network", peerId = "player1", initialized = true,
    checkpointConsensus = { lastAgreed = { boundarySeq = 4 } },
    bridge = { companion = { connected = true } },
    networkClock = { effectiveSpeed = 0 },
  }, "Both worlds are ready. Build freely; the shared clock is paused until you press Speed 1",
    "a ready, paused session did not invite the player to build")
  nextActionCase({
    networkMode = "network", peerId = "player2", initialized = true,
    checkpointConsensus = { lastAgreed = { boundarySeq = 4 } },
    bridge = { companion = { connected = true } },
    deferredNetworkQueue = { awaitingOrder = { localSeq = 12, type = "operation.capture" } },
  }, "Your last build is waiting for the host's order",
    "an outbound intent awaiting the host order was not surfaced")
  nextActionCase({
    networkMode = "network", peerId = "player1",
    proposalConsensus = { sessionFault = true },
    bridge = { companion = { connected = true } },
  }, "The session is faulted. Use Recover / Resync Session.",
    "a faulted session did not name its recovery control")
  nextActionCase({
    networkMode = "network", peerId = "player1",
    companies = { ["company:1"] = { name = "Company 1" } },
    match = { status = "finished", winnerCid = "company:1", finishReason = "valuation-target" },
  }, "Match over: Company 1 won by valuation target",
    "a finished match did not report its winner in words")

  local liveGui = chrome.gui
  assert(type(liveGui) == "table" and liveGui.nextActionView and liveGui.noticesView,
    "the panel did not build its next-action line and notices feed")
  assert(liveGui.nextActionView.text ~= "", "the next-action line was never rendered")

  -- A staged rejection must reach both the dated feed and the floating toast.
  liveGui.lastError = nil
  liveGui.notices = { items = {} }
  noticesModule.observe(liveGui, { proposalConsensus = { rejected = 0 } })
  noticesModule.observe(liveGui, { proposalConsensus = {
    rejected = 1, lastOutcome = { reason = "native-proposal-rejected" },
  } })
  noticesModule.render(liveGui, { proposalConsensus = { rejected = 1 } })
  assert(liveGui.noticesView.text:find(
      "The game refused this build on the other computer", 1, true)
    and liveGui.noticesView.text:find("s ago", 1, true),
    "a staged rejection did not reach the dated Notices feed")
  assert(liveGui.noticeToast and liveGui.noticeToast.window.visible == true
    and liveGui.noticeToast.view.text:find("The game refused this build", 1, true),
    "a staged rejection did not reach the floating toast")
  noticesModule.observeVeto(liveGui, { errorMessages = {
    "TPF2MP: entity 701 belongs to Company 2",
  } })
  assert(liveGui.notices.items[1].text == "TPF2MP: entity 701 belongs to Company 2",
    "an ownership veto was not kept verbatim")
  assert(noticesModule.explain("the network companion is disconnected")
      == "You are disconnected; builds are not queued."
    and noticesModule.explain("some-new-code") == "Rejected: some-new-code",
    "reason-code translation lost its table or its fallback")
  for index = 1, noticesModule.LIMIT + 3 do
    noticesModule.push(liveGui, { kind = "info", text = "notice " .. tostring(index) })
  end
  assert(#liveGui.notices.items == noticesModule.LIMIT, "the notice feed is not bounded")

  -- Collapsible sections, compact mode, and preferences round-tripping through a
  -- temporary %LOCALAPPDATA%.
  local preferenceRoot = (os.getenv("TEMP") or os.getenv("TMP") or "."):gsub("\\", "/")
    .. "/tpf2mp-gui-preference-tests"
  os.execute('rmdir /s /q "' .. preferenceRoot:gsub("/", "\\") .. '" 2>nul')
  os.execute('mkdir "' .. (preferenceRoot .. "/TPF2MP"):gsub("/", "\\") .. '" 2>nul')
  local realGetenv = os.getenv
  os.getenv = function(name)
    if name == "LOCALAPPDATA" then return preferenceRoot end
    return realGetenv(name)
  end
  chrome.preferences, chrome.preferencesWrittenAt, chrome.preferencesDirty = nil, nil, false

  local vehicleSection = chrome.sections["Vehicles"]
  assert(vehicleSection and #vehicleSection.rows > 0, "the Vehicles section tracked no row components")
  assert(chrome.sections["Match"] and #chrome.sections["Match"].rows > 0,
    "the Match section tracked no row components")
  assert(chrome.sections["Native gate (testing)"] == nil,
    "the native testing gate was built without developer economy controls")
  assert(vehicleSection.expanded == false, "a secondary section did not default to collapsed")
  assert(vehicleSection.rows[1].visible == false, "a collapsed section left its rows visible")
  assert(chrome.toggleSection("Vehicles") == true, "a section header click did not expand the section")
  assert(vehicleSection.rows[1].visible == true, "expanding a section did not reveal its rows")
  assert(vehicleSection.label.text:find("v ", 1, true) == 1,
    "the section header marker did not follow the expanded state")
  assert(chrome.sections["Notices"].expanded == true and chrome.sections["Shared clock"].expanded == true,
    "a section a player needs on sight defaulted to collapsed")

  chrome.setCompact(liveGui, true)
  assert(chrome.sections["Notices"].rows[1].visible == true,
    "compact mode hid the notices feed")
  assert(chrome.sections["Shared clock"].rows[1].visible == false
      and vehicleSection.rows[1].visible == false,
    "compact mode left an ordinary section visible")
  assert(liveGui.status.visible == false, "compact mode kept the full summary line")
  chrome.setCompact(liveGui, false)
  assert(liveGui.status.visible == true and vehicleSection.rows[1].visible == true,
    "leaving compact mode did not restore the expanded sections")

  chrome.flushPreferences(true)
  chrome.preferences = nil
  local reloadedPreferences = chrome.loadPreferences(liveGui)
  assert(type(reloadedPreferences.peers) == "table"
      and type(reloadedPreferences.peers["player1"]) == "table",
    "user interface preferences were not written per player")
  assert(reloadedPreferences.peers["player1"].sections["Vehicles"] == true
      and reloadedPreferences.peers["player1"].sections["Lines and route draft"] == false
      and reloadedPreferences.peers["player1"].compact == false,
    "expanded/collapsed state and compact mode did not round-trip through the preferences file")
  chrome.preferencesDirty = false
  os.getenv = realGetenv
  chrome.preferences = nil

  -- Scoreboard and end-of-match summary from a staged finished match.
  local finishedSnapshot = {
    networkMode = "network", peerId = "player1",
    companyOrder = { "company:1", "company:2" },
    companies = {
      ["company:1"] = { cid = "company:1", name = "Company 1", balance = 90000 },
      ["company:2"] = { cid = "company:2", name = "Company 2", balance = 40000 },
    },
    scoreboard = {
      ["company:1"] = {
        companyCid = "company:1", name = "Company 1", modelValueCents = 123456789,
        settledNetRevenueCents = 4567800, settledDemand = 12345,
        activeLines = 7, marketsReached = 4, marketWins = 3,
      },
      ["company:2"] = {
        companyCid = "company:2", name = "Company 2", modelValueCents = 2345600,
        settledNetRevenueCents = 120000, settledDemand = 900,
        activeLines = 2, marketsReached = 1, marketWins = 0,
      },
    },
    match = { status = "finished", winnerCid = "company:1", finishReason = "valuation-target" },
  }
  liveGui.scoreboardFinishAnnounced = false
  liveGui.notices = { items = {} }
  scoreboardModule.render(liveGui, finishedSnapshot)
  local scoreboardText = liveGui.scoreboardView.text
  assert(scoreboardText:find("Match over: Company 1 won by valuation target", 1, true),
    "the end-of-match summary did not head the scoreboard")
  assert(scoreboardText:find("$1,234,567.89", 1, true)
      and scoreboardText:find("$45,678.00", 1, true)
      and scoreboardText:find("12,345", 1, true),
    "scoreboard money or counts lost their thousands separators")
  assert(scoreboardText:find("* Company 1  (leader)", 1, true)
      and scoreboardText:find("markets 4", 1, true)
      and scoreboardText:find("lines 7", 1, true),
    "the scoreboard did not mark the leader with its model value inputs")
  assert(scoreboardText:find("  1. Company 1", 1, true)
      and scoreboardText:find("  2. Company 2", 1, true),
    "the end-of-match summary did not rank both companies")
  assert(#liveGui.notices.items == 1 and liveGui.notices.items[1].kind == "info"
      and liveGui.notices.items[1].ttl == 20
      and liveGui.notices.items[1].text:find("Match over: Company 1", 1, true),
    "the finished match was not announced once as a toast")
  scoreboardModule.render(liveGui, finishedSnapshot)
  assert(#liveGui.notices.items == 1, "the finished match was announced more than once")
  noticesModule.render(liveGui, finishedSnapshot)
  assert(liveGui.noticeToast.view.text:find("Match over: Company 1", 1, true)
      and liveGui.noticeToast.window.visible == true,
    "the end-of-match announcement did not reach the toast")
end)()

print("PASS GUI/native commit bridge, strict rival proposal/entity veto, shared-state refresh, and proxy finance locks")

-- Social channel: chat, canned pings and the other player's build preview.
-- The channel is a side channel by design (docs/SOCIAL_CHANNEL.md), so it is
-- driven here through its own five-hertz pump against a temporary bridge root
-- rather than through the ordered outbox.
;(function()
  local guiView = require "tpf2_mp/gui_view"
  local social = require "tpf2_mp/gui_social_runtime"
  local runtimeConfig = require "tpf2_mp/runtime_config"
  local chrome = guiView.chrome
  local restoreConfig = game.config.tpf2mp
  local root = (os.getenv("TEMP") or os.getenv("TMP") or "."):gsub("\\", "/")
    .. "/tpf2mp-gui-social-tests"
  os.execute('rmdir /s /q "' .. root:gsub("/", "\\") .. '" 2>nul')
  os.execute('mkdir "' .. (root .. "/companion_state"):gsub("/", "\\") .. '" 2>nul')
  local outPath = root .. "/companion_state/social_out.json"
  local inPath = root .. "/companion_state/social_in.json"

  local zoneCalls, zoneState = {}, {}
  game.interface.setZone = function(key, zone)
    zoneCalls[#zoneCalls + 1] = { key = key, zone = zone }
    zoneState[key] = zone
  end

  -- TextInputField is a stock component that no shipped Lua script uses, so
  -- the fake mirrors exactly the usertype methods the runtime calls.
  local inputFields = {}
  api.gui.comp.TextInputField = { new = function(placeholder)
    local field = object({ text = "", placeholder = placeholder })
    function field:setText(value) self.text = tostring(value) end
    function field:getText() return self.text end
    function field:onEnter(callback) self.enter = callback end
    function field:setMaxLength(value) self.maxLength = value end
    inputFields[#inputFields + 1] = field
    return field
  end }

  -- The hook's 3D preview renderer, the resource repositories it resolves
  -- names through, and the engine types its SimpleProposal is built from. The
  -- indices below deliberately differ from the names, so an assertion that
  -- sees the right index proves the receiver resolved the name for itself.
  local socialCodec = require "tpf2_mp/gui_social_codec"
  local socialParams = require "tpf2_mp/gui_social_params"
  local socialRepNames = {
    streetTypeRep = { ["standard/country_new.lua"] = 4, ["standard/town_small_new.lua"] = 9 },
    trackTypeRep = { ["standard.lua"] = 2, ["high_speed.lua"] = 6 },
    bridgeTypeRep = { ["z_concrete_new.lua"] = 3 },
    tunnelTypeRep = { ["rock.lua"] = 5 },
    constructionRep = { ["station/rail/mock_station.con"] = 12 },
  }
  for key, names in pairs(socialRepNames) do
    local byIndex = {}
    for name, index in pairs(names) do byIndex[index] = name end
    api.res[key] = {
      find = function(name)
        if names[name] then return names[name] end
        return -1
      end,
      getName = function(index) return byIndex[index] end,
    }
  end
  local restoreVec3f = api.type.Vec3f
  api.type.Vec3f = { new = function(x, y, z) return { x = x, y = y, z = z } end }
  api.type.Vec4f = { new = function(x, y, z, w) return { x = x, y = y, z = z, w = w } end }
  api.type.Mat4f = { new = function(a, b, c, d) return { a, b, c, d } end }
  api.type.NodeAndEntity = { new = function() return { comp = {} } end }
  api.type.SegmentAndEntity = { new = function() return { comp = {} } end }
  api.type.BaseEdgeStreet = { new = function() return {} end }
  api.type.BaseEdgeTrack = { new = function() return {} end }
  api.type.SimpleProposal = {
    new = function()
      return { streetProposal = { nodesToAdd = {}, edgesToAdd = {} }, constructionsToAdd = {} }
    end,
    ConstructionEntity = { new = function() return {} end },
  }
  api.engine.util = { getPlayer = function() return 100 end }

  local nativePreview = {
    available = true, session = 7, result = "ok", accept = true,
    armed = false, calls = {}, builds = {},
  }
  local function nativeModes(peer)
    local modes = {}
    for _, call in ipairs(nativePreview.calls) do
      if call.peer == peer then modes[#modes + 1] = call.mode end
    end
    return table.concat(modes, ",")
  end
  tpf2mp_native_preview_status = function()
    return {
      available = nativePreview.available, session = nativePreview.session,
      peers = 1, drawn = 0,
    }
  end
  tpf2mp_native_preview_begin = function(peer, mode)
    nativePreview.calls[#nativePreview.calls + 1] = { peer = peer, mode = mode }
    -- "keep" and "clear" execute at once; a draw mode arms the one-shot the
    -- next conversion on this thread consumes.
    if mode == "keep" or mode == "clear" then return true end
    nativePreview.armed = nativePreview.accept
    return nativePreview.accept
  end
  tpf2mp_native_preview_result = function()
    if not nativePreview.armed then return "idle" end
    nativePreview.armed = false
    return nativePreview.result
  end
  local restoreSocialBuildFactory = api.cmd.make.buildProposal
  api.cmd.make.buildProposal = function(proposal, context, ignoreErrors)
    nativePreview.builds[#nativePreview.builds + 1] = {
      proposal = proposal, context = context, ignoreErrors = ignoreErrors,
    }
    return { kind = "build-proposal" }
  end

  game.config.tpf2mp = {
    protocolVersion = 1, peerId = "player1", sessionId = "gui-social-test",
    bridgeDir = root, updateStride = 15, maxEvents = 64,
    startNetwork = true, localProxyEnabled = false,
  }
  assert(runtimeConfig.read().root == root,
    "the social tests could not point the runtime configuration at a temporary bridge root")

  local socialGui = { snapshot = { networkMode = "network", peerId = "player1" } }
  -- os.clock() is processor time: two synthetic GUI frames would not advance
  -- it past the five-hertz gate, so the poll clock is driven explicitly.
  local fakeClock = 1000
  social.clock = function() return fakeClock end
  local function poll(step)
    fakeClock = fakeClock + (step or 0.25)
    social.tick(socialGui)
  end
  local function readOut()
    local file = io.open(outPath, "rb")
    if not file then return nil end
    local body = file:read("*a")
    file:close()
    return json.decode(body)
  end
  local function writeIn(document)
    local file = assert(io.open(inPath, "wb"), "social_in.json fixture is not writable")
    file:write(json.encode(document))
    file:close()
  end
  local function lastItem(document, channel)
    for index = #document.items, 1, -1 do
      if document.items[index].channel == channel then return document.items[index] end
    end
    return nil
  end

  -- The panel section: a chat transcript, an input row and the four pings.
  local panel = BoxLayout.new("VERTICAL")
  social.addSection(socialGui, chrome.tracked(panel), chrome)
  assert(panel:getNumItems() == 4,
    "the social section did not add a caption, a transcript, an input row and a ping row")
  assert(socialGui.socialChat and socialGui.socialChat.text:find("No messages yet", 1, true),
    "the chat transcript was not created with its empty-state hint")
  local inputRow, pingRow = panel:getItem(2):getLayout(), panel:getItem(3):getLayout()
  local inputField, sendButton = inputRow:getItem(0), inputRow:getItem(1)
  assert(inputField == inputFields[1] and inputField.maxLength == 240,
    "the chat input field was not created and bounded at 240 characters")
  assert(pingRow:getNumItems() == 4, "the four canned pings were not added")
  assert(type(inputField.enter) == "function", "the chat field has no Enter handler")

  poll()

  -- (1) A road proposal becomes one preview item; a replacement segment and a
  -- track segment inside the same proposal are not part of the planned road.
  local roadParam = {
    data = { errorState = { messages = {} } },
    proposal = { proposal = {
      addedNodes = {
        { entity = -1, comp = { position = { x = 100, y = 200, z = 0 } } },
        { entity = -2, comp = { position = { x = 300, y = 260, z = 12 } } },
        { entity = -3, comp = { position = { x = 500, y = 200, z = 0 } } },
      },
      -- The second road segment climbs onto a bridge, so the capture has to
      -- carry a terrain class and a structure name as well as the heights.
      addedSegments = {
        { entity = -11, type = 0,
          comp = { node0 = -1, node1 = -2, type = 0,
            tangent0 = { x = 200, y = 0, z = 0 }, tangent1 = { x = 200, y = 60, z = 4 } },
          streetEdge = { streetType = 4, hasBus = true, tramTrackType = 1 } },
        { entity = -12, type = 0,
          comp = { node0 = -2, node1 = -3, type = 1, typeIndex = 3,
            tangent0 = { x = 200, y = 60, z = 4 }, tangent1 = { x = 200, y = 0, z = 0 } },
          streetEdge = { streetType = 4, hasBus = false, tramTrackType = 0 } },
        { entity = -13, type = 0, comp = { node0 = -1, node1 = -3,
          tangent0 = { x = 1, y = 0, z = 0 }, tangent1 = { x = 1, y = 0, z = 0 } } },
        { entity = -14, type = 1, comp = { node0 = -1, node1 = -2,
          tangent0 = { x = 1, y = 0, z = 0 }, tangent1 = { x = 1, y = 0, z = 0 } } },
      },
      new2oldSegments = { [-13] = 77 },
    } },
  }
  assert(select("#", social.observeBuilderEvent(
      socialGui, "streetBuilder", "builder.proposalCreate", roadParam)) == 0,
    "the builder observer returned a value and could alter the builder's own validation")
  poll()
  local published = assert(readOut(), "a captured road proposal did not reach social_out.json")
  assert(published.schemaVersion == 1 and published.peer == "player1"
      and published.session == "gui-social-test" and published.seq >= 1,
    "social_out.json lost its envelope")
  local previewItem = assert(lastItem(published, "preview"),
    "no preview item was published for the captured road proposal")
  assert(previewItem.id > math.floor(os.time()) * 100,
    "outgoing item ids were not seeded above a previous GUI state's ids")
  assert(previewItem.body.kind == "road" and previewItem.body.invalid == false,
    "the published preview was not a valid road preview")
  assert(#previewItem.body.curves == 2,
    "the road preview did not carry exactly the two new road curves")
  assert(previewItem.body.curves[1][1] == 100 and previewItem.body.curves[1][2] == 200
      and previewItem.body.curves[1][3] == 300 and previewItem.body.curves[1][5] == 200,
    "the road preview lost its Hermite endpoints or tangents")
  assert(previewItem.body.curves[2][3] == 500, "the second road curve was dropped")

  -- The optional 3D detail set rides along with the same two curves, carrying
  -- resource NAMES (never the indices above) so the receiver resolves its own.
  local publishedDetails = assert(previewItem.body.details,
    "the captured road proposal published no 3D detail set")
  assert(#publishedDetails == 2,
    "the 3D detail set did not match the published curve count")
  assert(publishedDetails[1][1] == 0 and publishedDetails[1][2] == 12
      and publishedDetails[1][3] == 0 and publishedDetails[1][4] == 4,
    "the road detail lost its endpoint or tangent heights")
  assert(publishedDetails[1][5] == 0 and publishedDetails[1][6] == "standard/country_new.lua"
      and publishedDetails[1][7] == 1 and publishedDetails[1][8] == 1
      and publishedDetails[1][9] == 0 and publishedDetails[1][10] == "",
    "the ground road detail lost its terrain class, street name or lane flags")
  assert(publishedDetails[2][5] == 1 and publishedDetails[2][10] == "z_concrete_new.lua",
    "the bridge segment did not carry its bridge type name")

  -- An error state on the same proposal marks the preview invalid.
  roadParam.data.errorState.messages = { "the slope is too steep" }
  social.observeBuilderEvent(socialGui, "streetBuilder", "builder.proposalCreate", roadParam)
  poll()
  assert(lastItem(assert(readOut()), "preview").body.invalid == true,
    "a builder error state did not mark the shared preview invalid")

  -- Applying the build turns the preview off, and the ring keeps one preview.
  social.observeBuilderEvent(socialGui, "streetBuilder", "builder.apply", { result = {} })
  poll()
  published = assert(readOut(), "the preview was not republished after builder.apply")
  local previewCount = 0
  for _, item in ipairs(published.items) do
    if item.channel == "preview" then previewCount = previewCount + 1 end
  end
  assert(previewCount == 1, "the outgoing ring kept more than the newest preview item")
  assert(lastItem(published, "preview").body.kind == "off",
    "builder.apply did not turn the shared preview off")

  -- Chat and pings leave through the same ring.
  inputField.text = "watch this junction\007"
  sendButton.callback()
  local restoreGameUi = api.gui.util.getGameUI
  api.gui.util.getGameUI = function()
    return object({ getMainRendererComponent = function()
      return object({ getTerrainPos = function() return { x = 512.5, y = -256.25, z = 40 } end })
    end })
  end
  pingRow:getItem(2).callback()
  api.gui.util.getGameUI = restoreGameUi
  pingRow:getItem(0).callback()
  poll()
  published = assert(readOut(), "chat and pings did not reach social_out.json")
  local chatItem = assert(lastItem(published, "chat"), "the Send button published no chat item")
  assert(chatItem.body.text == "watch this junction",
    "outgoing chat was not stripped of control characters")
  assert(inputField.text == "", "the chat field was not cleared after sending")
  local pingItem = assert(lastItem(published, "ping"), "no ping item was published")
  assert(pingItem.body.kind == "wait" and pingItem.body.x == nil,
    "the Wait ping was published with a position or with the wrong kind")
  local lookItem
  for _, item in ipairs(published.items) do
    if item.channel == "ping" and item.body.kind == "look" then lookItem = item end
  end
  assert(lookItem and lookItem.body.x == 512.5 and lookItem.body.y == -256.25,
    "the Look here ping did not carry the ground cursor position")
  assert(socialGui.socialChat.text:find("Player 1: watch this junction", 1, true)
      and socialGui.socialChat.text:find("Player 1: look here", 1, true),
    "locally sent chat and pings were not echoed into the transcript")

  -- (2) A hand-written social_in.json draws the remote preview and the chat.
  writeIn({
    schemaVersion = 1, session = "gui-social-test", peer = "player2", seq = 4,
    items = {
      { id = 11, peer = "player2", channel = "chat", at = os.time(),
        body = { text = "give me the north bank" } },
      { id = 12, peer = "player2", channel = "ping", at = os.time(),
        body = { kind = "look", x = 640, y = 128 } },
      { id = 13, peer = "player2", channel = "preview", at = os.time(),
        body = { kind = "road", invalid = false, curves = {
          { 0, 0, 120, 40, 120, 0, 120, 40 },
          { 120, 40, 260, 40, 140, 0, 140, 0 },
        } } },
      { id = 14, peer = "player1", channel = "chat", at = os.time(),
        body = { text = "this peer's own item must never be echoed back" } },
      { id = 15, peer = "player2", channel = "preview", at = os.time(),
        body = { kind = "road", curves = { { 0, 0, 1 } } } },
    },
  })
  poll()
  assert(socialGui.socialChat.text:find("Player 2: give me the north bank", 1, true),
    "a received chat line did not reach the transcript")
  assert(not socialGui.socialChat.text:find("never be echoed back", 1, true),
    "an item claiming this peer as its origin was accepted")
  assert(socialGui.notices and socialGui.notices.items
      and #socialGui.notices.items >= 2,
    "received chat and pings did not reach the notice feed")
  for index = 1, 2 do
    local zone = zoneState["tpf2mp_preview_player2_" .. index]
    assert(zone and zone.draw == true and type(zone.polygon) == "table"
        and #zone.polygon >= 18 and #zone.drawColor == 4 and zone.drawColor[4] == 0.8,
      "remote road curve " .. index .. " was not drawn as a tinted ground ribbon")
  end
  assert(zoneState["tpf2mp_preview_player2_3"] == nil,
    "a malformed later preview replaced the valid one with extra zones")
  local marker = zoneState["tpf2mp_marker_player2"]
  assert(marker and type(marker.polygon) == "table" and #marker.polygon == 50,
    "a received look ping did not draw a ground marker ring")

  -- The remote preview is cleared once it goes stale.
  poll(5)
  assert(zoneState["tpf2mp_preview_player2_1"] == nil
      and zoneState["tpf2mp_preview_player2_2"] == nil,
    "a stale remote preview was not cleared from the ground")

  -- (2b) A preview carrying the 3D detail set goes to the hook's renderer, so
  -- the game draws the other player's ghost instead of a flat ribbon.
  local nextSocialId = 20
  local function writeRail(file, invalid)
    nextSocialId = nextSocialId + 1
    writeIn({
      schemaVersion = 1, session = "gui-social-test", peer = "player2", seq = nextSocialId,
      items = { { id = nextSocialId, peer = "player2", channel = "preview", at = os.time(),
        body = { kind = "rail", invalid = invalid,
          curves = { { 0, 0, 200, 0, 200, 0, 200, 0 } },
          details = { { 0, 6, 0, 3, 0, file, 0, 0, 1, "" } } } } },
    })
  end
  writeRail("high_speed.lua", false)
  local buildsBefore, commandsBefore = #nativePreview.builds, #issuedCanonicalCommands
  poll()
  assert(#nativePreview.builds == buildsBefore + 1,
    "a remote 3D preview never reached api.cmd.make.buildProposal for conversion")
  assert(#issuedCanonicalCommands == commandsBefore,
    "the native preview conversion leaked a command into api.cmd.sendCommand")
  local converted = nativePreview.builds[#nativePreview.builds]
  assert(converted.context == nil and converted.ignoreErrors == false,
    "the preview conversion was not a plain, non-submitting buildProposal call")
  local previewNode = converted.proposal.streetProposal.nodesToAdd[1]
  local previewEdge = converted.proposal.streetProposal.edgesToAdd[1]
  assert(previewNode and previewNode.entity == -1 and previewNode.comp.position.z == 0,
    "the preview proposal did not carry a temporary negative node id")
  assert(previewEdge and previewEdge.entity < 0
      and previewEdge.comp.node0 == -1 and previewEdge.comp.node1 == -2,
    "the preview proposal edge did not reference its own temporary nodes")
  assert(previewEdge.type == 1 and previewEdge.trackEdge.trackType == 6
      and previewEdge.trackEdge.catenary == true,
    "the rail preview edge did not resolve its track type name locally")
  assert(previewEdge.streetEdge.streetType == 9,
    "the rail preview edge lost the dummy street type its street component needs")
  assert(previewEdge.comp.tangent1.z == 3 and previewEdge.comp.type == 0
      and previewEdge.comp.typeIndex == -1,
    "the preview edge lost its 3D tangent, terrain class or structure slot")
  assert(nativeModes("player2") == "drawok",
    "a valid remote preview was not offered with the drawok mode")
  assert(zoneState["tpf2mp_preview_player2_1"] == nil,
    "a natively drawn preview was also painted as a ground ribbon")

  -- An unchanged preview is refreshed once a second, never rebuilt per frame,
  -- and is taken down with one clear when it goes off.
  local afterDraw = #nativePreview.builds
  poll(0.25)
  assert(nativeModes("player2") == "drawok" and #nativePreview.builds == afterDraw,
    "an unchanged native preview was touched before its keepalive was due")
  poll(1)
  assert(nativeModes("player2") == "drawok,keep" and #nativePreview.builds == afterDraw,
    "an unchanged native preview was rebuilt instead of kept alive")
  nextSocialId = nextSocialId + 1
  writeIn({
    schemaVersion = 1, session = "gui-social-test", peer = "player2", seq = nextSocialId,
    items = { { id = nextSocialId, peer = "player2", channel = "preview", at = os.time(),
      body = { kind = "off" } } },
  })
  poll()
  assert(nativeModes("player2") == "drawok,keep,clear",
    "a preview turned off did not clear the native renderer exactly once")

  -- Without the renderer the same preview falls back to ground ribbons.
  nativePreview.available = false
  writeRail("high_speed.lua", false)
  poll()
  local fallbackRibbon = zoneState["tpf2mp_preview_player2_1"]
  assert(fallbackRibbon and fallbackRibbon.draw == true,
    "an unavailable native renderer did not fall back to a ground ribbon")
  assert(nativeModes("player2") == "drawok,keep,clear",
    "an unavailable native renderer was still asked to draw")

  -- A renderer that refuses the preview falls back too, and the refusal is
  -- remembered so the proposal is not rebuilt on every later frame.
  nativePreview.available, nativePreview.result = true, "error"
  poll(5.5)
  writeRail("high_speed.lua", true)
  local beforeRefusal = #nativePreview.builds
  poll()
  assert(#nativePreview.builds == beforeRefusal + 1,
    "the native renderer was never offered the invalid preview")
  assert(nativeModes("player2"):sub(-7) == "drawbad",
    "an invalid remote preview was not offered with the drawbad mode")
  local refusedRibbon = zoneState["tpf2mp_preview_player2_1"]
  assert(refusedRibbon and refusedRibbon.draw == true
      and refusedRibbon.drawColor[1] == 0.88,
    "a refused native preview did not fall back to a tinted ground ribbon")
  local afterRefusal = #nativePreview.builds
  for _ = 1, 4 do poll(0.25) end
  assert(#nativePreview.builds == afterRefusal,
    "a refused native preview was retried before its five-second backoff expired")

  -- A renderer that refuses to arm is never handed a conversion at all.
  nativePreview.result, nativePreview.accept = "ok", false
  poll(5.5)
  writeRail("standard.lua", false)
  local beforeRefusedBegin = #nativePreview.builds
  poll()
  assert(#nativePreview.builds == beforeRefusedBegin,
    "a begin the renderer refused still converted a preview proposal")
  local refusedBeginRibbon = zoneState["tpf2mp_preview_player2_1"]
  assert(refusedBeginRibbon and refusedBeginRibbon.draw == true,
    "a renderer that refused to arm did not fall back to a ground ribbon")
  nativePreview.accept = true

  -- (2c) A construction preview carries its parameter set as a typed string.
  local sampleParams = { seed = 7, module = "platform", flags = { true, false }, [3] = -1.5 }
  local encodedParams = assert(socialParams.encode(sampleParams),
    "a construction parameter set did not encode")
  assert(not encodedParams:find("[^\32-\126]"),
    "the encoded parameter set is not printable ASCII")
  assert(socialCodec.validParams(encodedParams) == encodedParams,
    "the wire codec rejected its own parameter encoding")
  local roundTripped = assert(socialParams.decode(encodedParams),
    "an encoded parameter set did not decode")
  assert(roundTripped.seed == 7 and roundTripped.module == "platform"
      and roundTripped.flags[1] == true and roundTripped.flags[2] == false
      and roundTripped[3] == -1.5,
    "the construction parameter set did not round-trip through the codec")
  assert(socialParams.decode(encodedParams .. "n1:") == nil,
    "a parameter string with trailing bytes was accepted")
  assert(socialCodec.validParams("m1:s4:6e616d65n1:" .. string.char(7)) == nil,
    "a parameter string carrying a control character was accepted")

  nativePreview.result = "ok"
  poll(5.5)
  nextSocialId = nextSocialId + 1
  writeIn({
    schemaVersion = 1, session = "gui-social-test", peer = "player2", seq = nextSocialId,
    items = { { id = nextSocialId, peer = "player2", channel = "preview", at = os.time(),
      body = { kind = "construction", invalid = false,
        file = "station/rail/mock_station.con", x = 100, y = 200, z = 5,
        transf = { 1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1, 0, 100, 200, 5, 1 },
        params = encodedParams } } },
  })
  local beforeConstruction = #nativePreview.builds
  poll()
  assert(#nativePreview.builds == beforeConstruction + 1,
    "a remote construction preview never reached the native renderer")
  local placed = nativePreview.builds[#nativePreview.builds].proposal.constructionsToAdd[1]
  assert(placed and placed.fileName == "station/rail/mock_station.con"
      and placed.name == "Multiplayer preview" and placed.playerEntity == 100,
    "the native construction preview lost its file name, owner or label")
  assert(placed.params.seed == 7 and placed.params.module == "platform",
    "the native construction preview did not decode its parameter set")
  assert(placed.transf[4].x == 100 and placed.transf[4].y == 200 and placed.transf[4].w == 1,
    "the construction preview transform did not reach api.type.Mat4f")
  assert(zoneState["tpf2mp_preview_player2_1"] == nil,
    "a natively drawn construction preview was also painted as a ground quad")

  -- (2d) The wire codec pairs each detail row with the curve of the same
  -- index, so a set of the wrong length rejects the whole item.
  local twoCurves = {
    { 0, 0, 10, 0, 10, 0, 10, 0 }, { 10, 0, 20, 0, 10, 0, 10, 0 },
  }
  local groundDetail = { 0, 0, 0, 0, 0, "standard/country_new.lua", 1, 2, 0, "" }
  assert(socialCodec.validBody("preview", { kind = "road", invalid = false,
      curves = twoCurves, details = { groundDetail } }) == nil,
    "a detail set shorter than the curve list was accepted")
  local matched = assert(socialCodec.validBody("preview", { kind = "road", invalid = false,
      curves = { twoCurves[1] }, details = { groundDetail } }),
    "a detail set matching the curve list was rejected")
  assert(matched.details[1][6] == "standard/country_new.lua" and matched.details[1][8] == 2,
    "a valid detail row lost its resource name or tram kind")
  assert(socialCodec.validBody("preview", { kind = "road", invalid = false,
      curves = { twoCurves[1] },
      details = { { 0, 0, 0, 0, 0, "bad name.lua", 0, 0, 0, "" } } }) == nil,
    "a detail row naming an out-of-charset resource was accepted")
  assert(socialCodec.validBody("preview", { kind = "road", invalid = false,
      curves = { twoCurves[1] },
      details = { { 0, 0, 0, 0, 0, "standard/country_new.lua", 0, 0, 0, "rock.lua" } } }) == nil,
    "a ground detail row carrying a structure name was accepted")

  -- (3) Without a bridge root the module is inert: nothing is written, and
  -- any zone it still owned is taken down.
  assert(os.remove(outPath), "the social output file could not be removed")
  game.config.tpf2mp = {
    protocolVersion = 1, peerId = "player1", sessionId = "gui-social-test",
    bridgeDir = ".", startNetwork = false,
  }
  socialGui.snapshot = { networkMode = "standalone", peerId = "player1" }
  for _ = 1, 4 do poll() end
  social.observeBuilderEvent(socialGui, "streetBuilder", "builder.proposalCreate", roadParam)
  for _ = 1, 4 do poll() end
  assert(io.open(outPath, "rb") == nil,
    "the social channel wrote social_out.json without an active network bridge root")
  assert(zoneState["tpf2mp_marker_player2"] == nil,
    "going inert left a social zone painted on the ground")
  assert(#zoneCalls > 0, "the social channel never reached game.interface.setZone")
  assert(nativeModes("player2"):sub(-5) == "clear",
    "going inert left a preview in the native renderer")

  for key in pairs(socialRepNames) do api.res[key] = nil end
  api.type.Vec3f, api.type.Vec4f, api.type.Mat4f = restoreVec3f, nil, nil
  api.type.NodeAndEntity, api.type.SegmentAndEntity = nil, nil
  api.type.BaseEdgeStreet, api.type.BaseEdgeTrack, api.type.SimpleProposal = nil, nil, nil
  api.engine.util = nil
  api.cmd.make.buildProposal = restoreSocialBuildFactory
  tpf2mp_native_preview_status = nil
  tpf2mp_native_preview_begin = nil
  tpf2mp_native_preview_result = nil
  game.config.tpf2mp = restoreConfig
  os.execute('rmdir /s /q "' .. root:gsub("/", "\\") .. '" 2>nul')
end)()

print("PASS social channel chat, canned pings, and shared build previews")
