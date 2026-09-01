local project = assert(arg[1], "project root argument required"):gsub("\\", "/")
package.path = project .. "/tpf2_mp_1/res/scripts/?.lua;" .. package.path
local util = require "tpf2_mp/util"

local sentEvents = {}
local enabled = {}
local textViews = {}
local guiById = {}
local nativeCommandObserver = nil
local nativeBuildGate = {
  enabled = true, authorizations = 0, allowed = 0, suppressed = 0,
  suppressedQueue = { queued = 0, captured = 0, consumed = 0, dropped = 0 },
}
local nativeBuildFastVersion = 1
local nativeBuildGeneration = 0
local nativeBuildDropped = 0
local nativeBuildArmedCorrelation = 0
local nativeBuildEvents = {}
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
    hookVersion = "0.19.0",
    active = true,
    validation = { valid = true, signatures = {} },
    hooks = {
      enabled = true,
      buildProposalVisitor = true,
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
        { type = 0, streetEdge = { streetType = 0 } },
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
-- flight. The engine queue keeps one latest construction lane, so the click is
-- neither silently discarded nor retained as an unbounded ghost backlog.
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
    and busyCaptures[#busyCaptures].param.queuePolicy == "coalesce-latest-construction",
  "busy construction click was discarded or missed its latest-only queue policy")
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
nativeBuildDropped = 1
assert(script.guiHandleEvent("trackBuilder", "builder.proposalCreate", networkPreview) == nil)
for _ = 1, 4 do script.guiUpdate() end
assert(#proposalCaptureEvents() == overflowCaptureCount
    and observedEvents("native.buildProposal.captureError") > overflowErrors,
  "a historically overflowed native correlation queue resumed accepting builds")
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
assert(referenceGuard.validate(stagedFreshStation, {}, nil),
  "slot-local station after collateral demolition incorrectly required a canonical-node API")
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
assert(issueQueuedReplay() == true
    and replayGui.proposalReplayQuarantine
    and replayGui.proposalReplayQuarantine.proposalId == "gui-staged-connected-terminal"
    and replayMaterialiseCalls[#replayMaterialiseCalls].options.omitConstructionCollateral == true
    and replayBuildCalls[#replayBuildCalls].ignoreErrors == true,
  "post-collateral terminal did not use pointer-free exact GUI replay")
replayQuarantineModule.reset(replayGui)

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

print("PASS GUI/native commit bridge, strict rival proposal/entity veto, shared-state refresh, and proxy finance locks")
