local project = assert(arg[1], "project root argument required"):gsub("\\", "/")
package.path = project .. "/tpf2_mp_1/res/scripts/?.lua;" .. package.path

local sentEvents = {}
local enabled = {}
local textViews = {}
local nativeCommandObserver = nil
local nativeBuildGate = { enabled = true, authorizations = 0, allowed = 0, suppressed = 0 }
local nativeSpeedRequests = {}
local nativeLineCommands = {}
local authorizedCommandTags = {}
local issuedCanonicalCommands = {}
local lineEntities = {}

tpf2mp_native_status = function()
  return {
    schemaVersion = 1,
    hookVersion = "test",
    active = true,
    validation = { valid = true, signatures = {} },
    hooks = {
      enabled = true,
      buildProposalVisitor = true,
      authorityCommandVisitors = 23,
      sendCommandWrapping = true,
    },
    gates = {
      buildProposal = nativeBuildGate,
      commandVisitors = { enabled = true, hooked = 23, tagMismatches = 0 },
    },
  }
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

tpf2mp_native_authorize_command = function(tag)
  authorizedCommandTags[#authorizedCommandTags + 1] = tonumber(tag)
  return true
end

local function object(methods)
  methods = methods or {}
  return setmetatable(methods, { __index = function() return function() end end })
end

local TextView = {
  new = function(text)
    local view = object({ text = text or "" })
    function view:setText(value) self.text = tostring(value) end
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
    local value = object({ id = id })
    function value:setLayout(layout) self.layout = layout end
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
    return value
  end,
}

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
  gui = {
    comp = { TextView = TextView, Button = Button, Component = Component, Window = Window },
    layout = { BoxLayout = BoxLayout },
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
      if componentType == "PLAYER_OWNED" then
        if id == 700 or id == 799 then return { player = 100 } end
        if id == 701 or id == 702 then return { player = 101 } end
      end
      return nil
    end,
    forEachEntityWithComponent = function(callback, componentType)
      if componentType == "LINE" then
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

-- Reproduce the live stock-widget race: LINE can become enumerable one GUI
-- update before the post-visitor native capture is readable. The correlation
-- ledger must retain that exact owned result instead of losing the command.
lineEntities[799] = true
script.guiUpdate()
nativeLineCommands[#nativeLineCommands + 1] =
  "L1|3|-1|100|950|250|100|4c696e652031|0|"
nativeLineCommands[#nativeLineCommands + 1] =
  "L1|5|700|-1|0|0|0||2|901,1,2;902,3,4"
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
  and vanillaUpdate.param.capture.stops[2].stationGroupLocalId == 902
  and vanillaUpdate.param.capture.stops[2].station == 3
  and vanillaUpdate.param.capture.stops[2].terminal == 4,
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

game.config.tpf2mp.operationalCapture = true
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
game.config.tpf2mp.operationalCapture = false

local function proposalCaptureEvents()
  local result = {}
  for _, event in ipairs(sentEvents) do
    if event.name == "intent" and event.param and event.param.type == "proposal.capture" then
      result[#result + 1] = event
    end
  end
  return result
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
assert(script.guiHandleEvent("trackBuilder", "builder.proposalCreate", networkPreview) == nil,
  "network track preview was unexpectedly vetoed")
for _ = 1, 3 do script.guiUpdate() end
assert(#proposalCaptureEvents() == captureCount,
  "a mouse-move proposal preview was replicated before native commit evidence")
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
assert(script.guiHandleEvent("trackBuilder", "builder.proposalCreate", exactPreview) == nil)
for _ = 1, 2 do script.guiUpdate() end
-- Move the same station template. The lightweight path must retain only its
-- latest placement and rebase the cached full graph once at builder.apply.
exactPreview.proposal.constructionsToAdd[1].transf[13] = 333
exactPreview.proposal.streetProposal.nodesToAdd[1].comp.position.x = 333
exactPreview.proposal.streetProposal.nodesToAdd[2].comp.position.x = 393
assert(script.guiHandleEvent("trackBuilder", "builder.proposalCreate", exactPreview) == nil,
  "lightweight construction preview update was unexpectedly vetoed")
-- Live Build 35924 ordering is apply -> next ghost preview -> delayed native
-- status counter. Its apply proposal is empty after native suppression, so the
-- exact click must come from the latest rebased pre-apply ghost and survive the
-- construction tool's subsequent preview.
script.guiHandleEvent("trackBuilder", "builder.apply", {
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
assert(script.guiHandleEvent("trackBuilder", "builder.proposalCreate", exactPreview) == nil,
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
assert(exactCapture.__observedCost == 7654
  and exactCapture.__builderData.trackType == 8
  and exactCapture.__builderData.catenary == false,
  "exact apply capture lost the preview's authoritative quote or carrier fallback: cost="
    .. tostring(exactCapture.__observedCost) .. " track="
    .. tostring(exactCapture.__builderData and exactCapture.__builderData.trackType)
    .. " catenary="
    .. tostring(exactCapture.__builderData and exactCapture.__builderData.catenary))

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
assert(#captures == captureCount + 3, "large station click was not captured")
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
assert(#proposalCaptureEvents() == captureCount + 3,
  "Lua issuing-path observation bypassed native suppression confirmation")
nativeBuildGate.suppressed = nativeBuildGate.suppressed + 1
for _ = 1, 65 do script.guiUpdate() end
assert(#proposalCaptureEvents() == captureCount + 4,
  "Lua issuing-path build was not correlated with its native suppression: got "
    .. tostring(#proposalCaptureEvents()) .. " expected " .. tostring(captureCount + 4))

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
assert(#proposalCaptureEvents() == captureCount + 5,
  "four native station-editor suppressions were not coalesced into one logical capture")

assert(script.guiHandleEvent("trackBuilder", "builder.proposalCreate", networkPreview) == nil)
nativeBuildGate.suppressed = nativeBuildGate.suppressed + 2
for _ = 1, 4 do script.guiUpdate() end
assert(#proposalCaptureEvents() == captureCount + 5,
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

assert(enabled["finances.borrow"] == false and enabled["finances.repay"] == false, "finance controls were not disabled")

print("PASS GUI/native commit bridge, strict rival proposal/entity veto, shared-state refresh, and proxy finance locks")
