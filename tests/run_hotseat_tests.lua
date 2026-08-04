local project = assert(arg[1], "project root argument required"):gsub("\\", "/")
local bridgeRoot = assert(arg[2], "bridge root argument required"):gsub("\\", "/")
package.path = project .. "/tpf2_mp_1/res/scripts/?.lua;" .. package.path

local canonical = require "tpf2_mp/canonical"
local proposalCodec = require "tpf2_mp/proposal_codec"
local canonicalProbe = canonical.newState()
assert(canonical.bind(canonicalProbe, "edge:test", "edge", 11, { owner = "company:1" }))
assert(canonical.rebindLocal(canonicalProbe, "edge:test", 12, { nativeOwner = 101 }))
assert(canonical.resolveCanonical(canonicalProbe, "edge", 11) == nil,
  "canonical rebind retained the retired local edge ID")
assert(canonical.resolveCanonical(canonicalProbe, "edge", 12) == "edge:test",
  "canonical rebind did not install the replacement local edge ID")
assert(canonical.resolveLocal(canonicalProbe, "edge:test") == 12,
  "canonical rebind did not update the forward binding")
assert(canonicalProbe.byCanonical["edge:test"].metadata.owner == "company:1"
  and canonicalProbe.byCanonical["edge:test"].metadata.nativeOwner == 101,
  "canonical rebind lost or failed to patch metadata")
assert(canonical.bind(canonicalProbe, "edge:occupied", "edge", 13, {}))
local occupiedOk = canonical.rebindLocal(canonicalProbe, "edge:test", 13)
assert(occupiedOk == false and canonical.resolveLocal(canonicalProbe, "edge:test") == 12,
  "canonical rebind overwrote an occupied replacement ID")

local players = {
  [100] = { id = 100, type = "PLAYER", name = "Native", balance = 10000000, loan = 30000000 },
}
local nextPlayer = 100
local names = {}
local maximumLoans = {}
local ownershipCascades = {}
local components = {
  PLAYER_OWNED = {
    [201] = { player = 100 },
    [202] = { player = 100 },
  },
  TRANSPORT_VEHICLE = {
    [201] = { line = -1, depot = -1 },
  },
  BASE_EDGE = {
    [202] = {},
  },
  BASE_NODE = {},
  BASE_EDGE_TRACK = {},
  BASE_EDGE_STREET = {},
  VEHICLE_DEPOT = {},
  CONSTRUCTION = {},
  STATION = {},
  STATION_GROUP = {},
  TOWN = { [500] = { developmentActive = false } },
}

local function entityExists(id)
  if players[id] then return true end
  for _, values in pairs(components) do if values[id] then return true end end
  return false
end

local function entity(id)
  if players[id] then return players[id] end
  if not entityExists(id) then return nil end
  return {
    id = id,
    type = components.TRANSPORT_VEHICLE[id] and "VEHICLE" or "ENTITY",
    name = names[id] or "Entity " .. tostring(id),
    position = { id, id },
  }
end

game = {
  config = {
    tpf2mp = {
      protocolVersion = 1,
      peerId = "player1",
      sessionId = "hotseat-test",
      bridgeDir = bridgeRoot,
      updateStride = 1,
      maxEvents = 64,
      startNetwork = false,
      startingCash = 5000000,
      localProxyEnabled = true,
      pauseOnSwitch = true,
      operationalCapture = true,
      operationalSampleTicks = 30,
    },
  },
  interface = {
    addPlayer = function()
      nextPlayer = nextPlayer + 1
      players[nextPlayer] = {
        id = nextPlayer,
        type = "PLAYER",
        name = "Player " .. nextPlayer,
        balance = 0,
        loan = 0,
      }
      return nextPlayer
    end,
    getPlayer = function() return 100 end,
    getEntity = entity,
    setName = function(id, name) names[id] = name; if players[id] then players[id].name = name end end,
    setPlayer = function(id, playerId)
      assert(components.PLAYER_OWNED[id], "attempt to transfer non-player-owned entity " .. tostring(id))
      assert(not components.BASE_EDGE[id], "BASE_EDGE was sent through unsupported legacy setPlayer")
      components.PLAYER_OWNED[id].player = playerId
      for _, linkedId in ipairs(ownershipCascades[id] or {}) do
        assert(components.PLAYER_OWNED[linkedId], "missing cascaded edge " .. tostring(linkedId))
        components.PLAYER_OWNED[linkedId].player = playerId
      end
    end,
    getTowns = function() return { 500 } end,
    getLines = function() return {} end,
    getVehicles = function()
      local result = {}
      for id in pairs(components.TRANSPORT_VEHICLE) do result[#result + 1] = id end
      table.sort(result)
      return result
    end,
    getDepots = function() return {} end,
    setTownCapacities = function() end,
    setTownDevelopmentActive = function(id, active)
      components.TOWN[id].developmentActive = active
    end,
    setBuildInPauseModeAllowed = function() end,
    setGameSpeed = function() end,
    getGameSpeed = function() return 1 end,
    setMaximumLoan = function(playerId, amount) maximumLoans[playerId] = amount end,
    getGameTime = function() return { time = 100 } end,
    getPlayerJournal = function() return { income = { _sum = 0 } } end,
  },
}

api = {
  util = { getBuildVersion = function() return "hotseat-test-build" end },
  type = {
    ComponentType = {
      NAME = "NAME", LINE = "LINE", TRANSPORT_VEHICLE = "TRANSPORT_VEHICLE",
      VEHICLE_DEPOT = "VEHICLE_DEPOT", CONSTRUCTION = "CONSTRUCTION",
      STATION_GROUP = "STATION_GROUP", STATION = "STATION", BASE_EDGE = "BASE_EDGE",
      BASE_EDGE_TRACK = "BASE_EDGE_TRACK", BASE_EDGE_STREET = "BASE_EDGE_STREET",
      BASE_NODE = "BASE_NODE", SIM_BUILDING = "SIM_BUILDING", TOWN = "TOWN",
      PLAYER = "PLAYER", PLAYER_OWNED = "PLAYER_OWNED",
    },
    JournalEntryCategory = { new = function() return {} end },
    JournalEntry = { new = function() return {} end },
  },
  engine = {
    entityExists = entityExists,
    getComponent = function(id, kind) return components[kind] and components[kind][id] or nil end,
    forEachEntityWithComponent = function(callback, kind)
      for id in pairs(components[kind] or {}) do callback(id) end
    end,
    system = {
      lineSystem = { getLines = function() return {} end },
      transportVehicleSystem = { getLineVehicles = function() return {} end },
      townBuildingSystem = { getLandUsePersonCapacities = function() return { 100, 100, 100 } end },
      stationSystem = { getStation2TownMap = function() return {} end },
      stationGroupSystem = { getStationGroup = function() return nil end },
      simPersonSystem = {
        getCount = function() return 42 end,
        getSimPersonsForLine = function() return {} end,
      },
      simCargoSystem = { getSimCargosForLine = function() return {} end },
      simPersonAtTerminalSystem = {
        getEdgeInfoMap = function() return {} end,
        getNumFreePlaces = function() return 0 end,
      },
    },
  },
  cmd = {
    make = {
      sendScriptEvent = function(file, id, name, param) return { kind = "script", file = file, id = id, name = name, param = param } end,
      bookJournalEntry = function(player, journal) return { kind = "book", player = player, journal = journal } end,
      buildProposal = function() return {} end,
      buyVehicle = function() return {} end,
      createLine = function() return {} end,
      developTown = function() return {} end,
      setSimBuildingManualDevelopment = function() return {} end,
    },
    sendCommand = function(command)
      if command.kind == "book" then players[command.player].balance = players[command.player].balance + command.journal.amount end
    end,
  },
}

assert(loadfile(project .. "/tpf2_mp_1/res/config/game_script/tpf2_mp.lua"))()
local script = assert(data())
script.init()
script.handleEvent("test", "tpf2mp", "intent", { type = "match.initialise" })

local initialized = script.save()
assert(initialized.initialized, "standalone match did not initialise")
assert(initialized.world.proxyMode, "native turn proxy was not enabled")
assert(initialized.world.controlPlayerId == 100, "native player was not retained as control proxy")
assert(initialized.companies["company:1"].playerId == 101, "company 1 must have its own native player")
assert(initialized.companies["company:2"].playerId == 102, "company 2 must have its own native player")
assert(players[101].balance == 5000000 and players[102].balance == 5000000,
  "new zero-balance native companies were not provisioned with starting cash")
assert(players[101].loan == 0 and players[102].loan == 0 and players[100].loan == 30000000,
  "starting-cash provisioning unexpectedly changed native loan principal")
assert(initialized.finance.startingCash.target == 5000000, "starting-cash target was not persisted")
assert(initialized.finance.startingCash.totalGranted == 10000000, "setup grants were not audited separately")
assert(components.PLAYER_OWNED[201].player == 100, "company 1 vehicle was not leased into the turn proxy")
assert(components.PLAYER_OWNED[202].player == 100, "base edge should remain in pinned turn-desk custody")
assert(initialized.world.pinnedCustody["202"].logicalOwnerCid == "company:1",
  "base edge did not receive stable logical company ownership")
assert(players[100].balance == 5000000, "turn desk did not mirror company 1's spending balance")
assert(maximumLoans[100] == 0, "turn desk borrowing was not disabled")

-- Reproduce the live v0.4 failure in an already-initialised save and prove the
-- repair closes/reopens the proxy turn around an idempotent company top-up.
players[101].balance = 0
script.handleEvent("test", "tpf2mp", "intent", { type = "finance.repair_starting_cash", localOnly = true })
local repaired = script.save()
assert(repaired.lastError == nil, "starting-cash repair failed")
assert(players[101].balance == 5000000 and players[102].balance == 5000000,
  "starting-cash repair did not top up both company wallets")
assert(players[100].balance == 5000000, "repaired active company wallet was not remirrored to the turn desk")
assert(repaired.world.turn and repaired.world.turn.active and repaired.world.turn.companyCid == "company:1",
  "starting-cash repair did not reopen the active proxy turn")
assert(repaired.finance.startingCash.repairs == 1, "successful starting-cash repair was not audited")
assert(repaired.finance.startingCash.totalGranted == 15000000,
  "repair grant was not added to the setup-funding audit")
script.handleEvent("test", "tpf2mp", "intent", { type = "finance.repair_starting_cash", localOnly = true })
local repairedAgain = script.save()
assert(repairedAgain.lastError == nil and players[100].balance == 5000000,
  "idempotent starting-cash repair disturbed the active turn")
assert(repairedAgain.finance.startingCash.totalGranted == 15000000,
  "a second starting-cash repair created duplicate capital")

-- A live player-owned road exposed a split transaction in v0.5: ownership
-- return failed but finance still restored the 30M desk baseline. Prove that
-- any custody postcondition failure now leaves every wallet and the transfer
-- ledger untouched, while retaining enough failure detail for diagnosis.
components.PLAYER_OWNED[205] = { player = 100 }
components.TRANSPORT_VEHICLE[205] = { line = -1, depot = -1 }
local synchronousSetPlayer = game.interface.setPlayer
game.interface.setPlayer = function(id, playerId)
  if id ~= 205 then synchronousSetPlayer(id, playerId) end
end
local transferCountBeforeFailure = #repairedAgain.finance.transfers.items
script.handleEvent("test", "tpf2mp", "intent", { type = "company.reconcile" })
local custodyFailure = script.save()
assert(custodyFailure.lastError == "asset return failed before financial settlement; no money was moved",
  "custody failure did not fail closed before finance")
assert(players[100].balance == 5000000 and players[101].balance == 5000000,
  "custody failure partially committed the proxy balance settlement")
assert(#custodyFailure.finance.transfers.items == transferCountBeforeFailure,
  "custody failure wrote a financial transfer record")
assert(components.PLAYER_OWNED[201].player == 100
  and components.PLAYER_OWNED[202].player == 100
  and components.PLAYER_OWNED[205].player == 100,
  "custody failure did not roll already-moved assets back by exact ID")
assert(custodyFailure.world.turn and custodyFailure.world.turn.active
  and custodyFailure.world.turn.lastFailure.stage == "asset-return",
  "custody failure was not retained for snapshot diagnosis")
game.interface.setPlayer = synchronousSetPlayer
script.handleEvent("test", "tpf2mp", "intent", { type = "company.reconcile" })
assert(script.save().lastError == nil and players[100].balance == 5000000,
  "proxy turn did not recover after the ownership obstruction was removed")
components.PLAYER_OWNED[205] = nil
components.TRANSPORT_VEHICLE[205] = nil

script.handleEvent("test", "tpf2mp", "intent", {
  type = "native.observed",
  observation = "builder.proposalCreate",
  sourceId = "streetBuilder",
  ids = {},
  proposalSnapshot = { proposal = { edgesToAdd = { ["1"] = { entity = -1 } } } },
  localOnly = true,
})
local capturedProposal = script.save()
assert(capturedProposal.probes.capture.lastProposalSnapshot.snapshot.proposal.edgesToAdd["1"].entity == -1,
  "bounded proposal snapshot was not retained for research")
assert(#capturedProposal.probes.capture.proposalSnapshots == 1
  and capturedProposal.probes.capture.proposalSnapshots[1].observation == "builder.proposalCreate",
  "bounded proposal snapshot ring did not retain its observation context")
local captureEvent = capturedProposal.eventLog.items[#capturedProposal.eventLog.items]
assert(captureEvent.action.proposalSnapshot == nil, "proposal RE snapshot leaked into the persistent event/audit tail")
script.handleEvent("test", "tpf2mp", "intent", {
  type = "native.observed",
  observation = "builder.proposalDenied",
  companyCid = "company:1",
  sourceId = "trackBuilder",
  ids = {},
  accessDecision = {
    allowed = false,
    activeCompanyCid = "company:1",
    sourceIds = { 202 },
    blocked = { { localId = 202, logicalOwnerCid = "company:2" } },
  },
  localOnly = true,
})
local deniedProposal = script.save()
local denialEvent = deniedProposal.eventLog.items[#deniedProposal.eventLog.items]
assert(deniedProposal.probes.capture.accessDeniedCount == 1
  and deniedProposal.probes.capture.lastAccessDenial.decision.blocked[1].localId == 202,
  "proposal denial evidence was not retained in the bounded capture state")
assert(denialEvent.action.accessDecision == nil,
  "machine-local proposal access IDs leaked into the persistent event/audit tail")
script.handleEvent("test", "tpf2mp", "intent", {
  type = "native.observed",
  observation = "gui.operationalAction",
  companyCid = "company:1",
  sourceId = "lineManager",
  eventName = "update",
  observedEntityIds = { 201, 202 },
  eventShape = { lineEntity = 201, vehicleEntity = 202 },
  commandDigest = "gui-envelope-test",
  ids = {},
  localOnly = true,
})
local guiCapture = script.save()
assert(guiCapture.probes.capture.operationalGuiCount == 1
  and #guiCapture.probes.capture.operationalGuiHistory == 1
  and guiCapture.probes.capture.operationalGuiHistory[1].entityIds[1] == 201
  and guiCapture.probes.capture.operationalGuiHistory[1].envelope.vehicleEntity == 202,
  "operational GUI envelope was not retained in the bounded capture ring")
local guiCaptureEvent = guiCapture.eventLog.items[#guiCapture.eventLog.items]
assert(guiCaptureEvent.action.observedEntityIds == nil
  and guiCaptureEvent.action.eventShape == nil,
  "machine-local operational GUI IDs leaked into the persistent event/audit tail")
maximumLoans[100] = 123
script.update()
assert(maximumLoans[100] == 0, "base-game loan-limit refresh was not countered")
local operational = script.save().probes.operational
assert(operational.enabled and operational.autoInit and operational.autoInit.success,
  "operational capture did not recognize the already initialized hot-seat match")
assert(operational.sampleCount == 1 and operational.emittedCount == 1,
  "operational capture did not publish its first bounded sample")
assert(operational.lastSample.gameSpeed == 1
  and operational.lastSample.mobilityAvailability.totalPersons == true
  and operational.lastSample.mobilityAvailability.linePassengers == true
  and operational.lastSample.mobilityAvailability.lineCargo == true,
  "operational capture did not exercise the populated-world mobility/speed readers")
assert(operational.lastSample.autonomyTotals.townDevelopmentFrozen == 1
  and operational.lastSample.autonomyTotals.townDevelopmentActive == 0,
  "operational capture lost a false town-development readback")
assert(operational.lastSample.digests.model and operational.lastSample.digests.core
  and operational.lastSample.digests.structural and operational.lastSample.digests.mobility,
  "operational capture omitted an independent digest domain")

components.PLAYER_OWNED[203] = { player = 100 }
components.TRANSPORT_VEHICLE[203] = { line = -1, depot = -1 }
players[100].balance = players[100].balance - 500
script.handleEvent("test", "tpf2mp", "intent", { type = "company.cycle" })

local company2Turn = script.save()
assert(company2Turn.activeCompanyIndex == 2, "company cycle failed")
assert(components.PLAYER_OWNED[201].player == 101, "company 1 vehicle was not returned")
assert(components.PLAYER_OWNED[202].player == 100, "company 1 edge left pinned turn-desk custody")
assert(company2Turn.world.logicalOwners["202"] == "company:1",
  "company 1 edge lost its logical owner while company 2 became active")
assert(components.PLAYER_OWNED[203].player == 101, "new rolling stock was not attributed to company 1")
assert(players[100].balance == 5000000, "turn desk did not restore then mirror company 2's balance")
assert(players[101].balance == 4999500, "company 1 did not receive its net turn delta")

-- Reproduce the live rail-depot failure and the equivalent station ownership
-- shape. Returning either construction can cascade its attached BASE_EDGE to
-- the rightful native company. That must remain valid custody while the rival
-- company is active; a later lease must bring the complete facility back to
-- the desk without using legacy setPlayer on the edge itself.
components.PLAYER_OWNED[210] = { player = 100 }
components.VEHICLE_DEPOT[210] = {}
components.CONSTRUCTION[210] = { fileName = "depot/train_depot_era_a.con" }
components.PLAYER_OWNED[211] = { player = 100 }
components.BASE_EDGE[211] = {}
components.BASE_EDGE_TRACK[211] = { trackType = 0 }
ownershipCascades[210] = { 211 }

components.PLAYER_OWNED[212] = { player = 100 }
components.CONSTRUCTION[212] = { fileName = "station/train/passenger_era_a.con" }
components.PLAYER_OWNED[213] = { player = 100 }
components.BASE_EDGE[213] = {}
components.BASE_EDGE_TRACK[213] = { trackType = 0 }
components.PLAYER_OWNED[216] = { player = 100 }
components.BASE_EDGE[216] = {}
components.BASE_EDGE_TRACK[216] = { trackType = 0 }
components.PLAYER_OWNED[214] = { player = 100 }
components.STATION[214] = {}
components.PLAYER_OWNED[215] = { player = 100 }
components.STATION_GROUP[215] = {}
ownershipCascades[212] = { 213, 216 }

-- Reproduce the live cross-company track-upgrade lifecycle: the inactive
-- company's pinned edge disappears and a new local ID is committed under the
-- shared desk. The builder observation must migrate canonical/logical custody
-- before Company 2 reconciliation can mistake it for a newly built edge.
components.PLAYER_OWNED[202] = nil
components.BASE_EDGE[202] = nil
components.PLAYER_OWNED[206] = { player = 100 }
components.BASE_EDGE[206] = {}
script.handleEvent("test", "tpf2mp", "intent", {
  type = "native.observed",
  observation = "builder.apply",
  companyCid = "company:2",
  ids = {},
  edgeReplacementObservation = {
    sourceCount = 1,
    targetCount = 1,
    pairs = { { oldLocalId = 202, newLocalId = 206, carrier = 1, node0 = 1, node1 = 2 } },
    unmatchedSources = {},
    unmatchedTargets = {},
    ambiguous = {},
  },
  localOnly = true,
})
local reboundDuringRivalTurn = script.save()
assert(reboundDuringRivalTurn.lastError == nil,
  "tracked edge replacement raised an unexpected engine error")
assert(reboundDuringRivalTurn.world.logicalOwners["202"] == nil
  and reboundDuringRivalTurn.world.logicalOwners["206"] == "company:1",
  "cross-company replacement stole the inactive company's logical edge")
assert(reboundDuringRivalTurn.world.pinnedCustody["202"] == nil
  and reboundDuringRivalTurn.world.pinnedCustody["206"].logicalOwnerCid == "company:1",
  "cross-company replacement did not migrate pinned custody")
assert(reboundDuringRivalTurn.probes.capture.replacementObservedCount == 1
  and reboundDuringRivalTurn.probes.capture.replacementReboundCount == 1
  and reboundDuringRivalTurn.probes.capture.replacementFailureCount == 0,
  "replacement migration counters are incorrect")

components.PLAYER_OWNED[204] = { player = 100 }
components.BASE_EDGE[204] = {}
players[100].balance = players[100].balance - 300
script.handleEvent("test", "tpf2mp", "intent", { type = "company.cycle" })

local company1Again = script.save()
assert(company1Again.activeCompanyIndex == 1, "second company cycle failed")
assert(company1Again.lastError == nil, "successful company cycle left a false error")
assert(components.PLAYER_OWNED[204].player == 100, "company 2 edge left pinned turn-desk custody")
assert(company1Again.world.logicalOwners["204"] == "company:2",
  "company 2 edge did not retain stable logical ownership")
assert(players[102].balance == 4999700, "company 2 did not receive its net turn delta")
assert(players[100].balance == 4999500, "turn desk did not mirror company 1 on return")
assert(components.PLAYER_OWNED[203].player == 100, "company 1 rolling stock was not leased back for management")
assert(company1Again.finance.transfers.totalAbsolute == 800, "financial transfer ledger is incomplete")
assert(company1Again.probes.ownership.companies["company:1"].byKind.vehicle == 2, "logical vehicle ownership count is wrong")
assert(company1Again.probes.ownership.pinned.total == 5
  and company1Again.probes.ownership.pinned.companies["company:1"].byKind.edge == 1
  and company1Again.probes.ownership.pinned.companies["company:2"].byKind.edge == 4,
  "pinned edge custody was not disclosed per logical company")
assert(components.PLAYER_OWNED[210].player == 102
  and components.PLAYER_OWNED[211].player == 102
  and components.PLAYER_OWNED[212].player == 102
  and components.PLAYER_OWNED[213].player == 102
  and components.PLAYER_OWNED[216].player == 102
  and components.PLAYER_OWNED[214].player == 102
  and components.PLAYER_OWNED[215].player == 102,
  "depot/station return did not keep each facility with Company 2")

script.handleEvent("test", "tpf2mp", "intent", { type = "company.cycle" })
local company2WithFacilities = script.save()
assert(company2WithFacilities.lastError == nil and company2WithFacilities.activeCompanyIndex == 2,
  "rightful depot/station edge custody blocked the next Company 2 turn")
assert(components.PLAYER_OWNED[210].player == 100
  and components.PLAYER_OWNED[211].player == 100
  and components.PLAYER_OWNED[212].player == 100
  and components.PLAYER_OWNED[213].player == 100
  and components.PLAYER_OWNED[216].player == 100
  and components.PLAYER_OWNED[214].player == 100
  and components.PLAYER_OWNED[215].player == 100,
  "Company 2 depot/station facility was not leased back to the turn desk")

script.handleEvent("test", "tpf2mp", "intent", { type = "company.cycle" })
company1Again = script.save()
assert(company1Again.lastError == nil and company1Again.activeCompanyIndex == 1,
  "depot/station facility could not return cleanly before the rival turn")
assert(components.PLAYER_OWNED[211].player == 102
  and components.PLAYER_OWNED[213].player == 102
  and components.PLAYER_OWNED[216].player == 102,
  "construction-linked edges did not follow their rightful Company 2 facilities")

local json = require "tpf2_mp/json"
local persisted = json.decode(json.encode(company1Again))
script.load(persisted)
script.handleEvent("test", "tpf2mp", "intent", { type = "company.reconcile" })
local reloaded = script.save()
assert(reloaded.lastError == nil, "active proxy turn did not reconcile after serialized reload")
assert(reloaded.world.turn and reloaded.world.turn.active, "reconcile after reload did not reopen the company turn")
assert(components.PLAYER_OWNED[203].player == 100, "reload/reconcile stranded active rolling stock")
assert(players[100].balance == players[101].balance, "reload/reconcile did not remirror the company wallet")

-- A complex live track/station build can retire one tracked edge and emit a
-- split set with no unique old->new topology match.  The observation must
-- still fail closed immediately, but standalone proxy reconciliation can
-- safely rebuild custody from the exclusive turn-desk inventory.  This keeps
-- the audit failure while preventing a visually healthy turn from becoming
-- permanently un-settleable.
local recoveryCompanyBalance = players[101].balance
components.PLAYER_OWNED[206] = nil
components.BASE_EDGE[206] = nil
components.PLAYER_OWNED[207] = { player = 100 }
components.BASE_EDGE[207] = {}
components.BASE_EDGE_TRACK[207] = { trackType = 0 }
components.PLAYER_OWNED[208] = { player = 100 }
components.BASE_EDGE[208] = {}
components.BASE_EDGE_TRACK[208] = { trackType = 0 }
players[100].balance = players[100].balance - 250
script.handleEvent("test", "tpf2mp", "intent", {
  type = "native.observed",
  observation = "builder.apply",
  sourceId = "trackBuilder",
  companyCid = "company:1",
  ids = { 207, 208 },
  edgeReplacementObservation = {
    sourceCount = 1,
    targetCount = 2,
    pairs = {},
    unmatchedSources = {
      { entity = 206, carrier = 1, node0 = 1, node1 = 2, nativePlayerId = 100 },
    },
    unmatchedTargets = {
      { entity = 207, carrier = 1, node0 = 1, node1 = 3, nativePlayerId = 100 },
      { entity = 208, carrier = 1, node0 = 3, node1 = 2, nativePlayerId = 100 },
    },
    ambiguous = {},
  },
  localOnly = true,
})
local replacementFailedClosed = script.save()
assert(replacementFailedClosed.world.edgeReplacementFailure ~= nil
  and replacementFailedClosed.probes.capture.replacementFailureCount == 1,
  "ambiguous replacement did not latch its fail-closed audit")
script.handleEvent("test", "tpf2mp", "intent", { type = "company.reconcile" })
local replacementRecovered = script.save()
assert(replacementRecovered.lastError == nil
  and replacementRecovered.world.edgeReplacementFailure == nil,
  "standalone inventory recovery did not reopen the healthy proxy turn")
assert(replacementRecovered.probes.capture.replacementRecoveryCount == 1
  and replacementRecovered.probes.capture.lastReplacementRecovery.ok == true,
  "replacement recovery was not retained in the capture audit")
assert(canonical.resolveCanonical(replacementRecovered.canonical, "edge", 206) == nil
  and replacementRecovered.world.logicalOwners["206"] == nil
  and replacementRecovered.world.pinnedCustody["206"] == nil,
  "replacement recovery retained the retired edge identity")
assert(replacementRecovered.world.logicalOwners["207"] == "company:1"
  and replacementRecovered.world.logicalOwners["208"] == "company:1"
  and replacementRecovered.world.pinnedCustody["207"].logicalOwnerCid == "company:1"
  and replacementRecovered.world.pinnedCustody["208"].logicalOwnerCid == "company:1",
  "replacement recovery did not adopt and pin the split edges")
assert(players[101].balance == recoveryCompanyBalance - 250
  and players[100].balance == players[101].balance,
  "replacement recovery did not settle and remirror the exact turn delta")

script.handleEvent("test", "tpf2mp", "intent", { type = "finance.toggle_neutralizer", enabled = true })
assert(script.save().finance.neutralizer.enabled == false, "proxy mode allowed the incompatible native-income neutralizer")

local auditTransaction = {
  schemaVersion = proposalCodec.SCHEMA_VERSION,
  companyCid = "company:1",
  cost = 0,
  nodes = {
    { slot = "node:1", position = { x = 0, y = 0, z = 0 } },
    { slot = "node:2", position = { x = 20, y = 0, z = 0 } },
  },
  edges = {
    {
      slot = "edge:1", carrier = "track",
      node0 = { slot = "node:1" }, node1 = { slot = "node:2" },
      tangent0 = { x = 20, y = 0, z = 0 }, tangent1 = { x = 20, y = 0, z = 0 },
      type = 0, typeIndex = 0, resource = { index = 0 }, catenary = false,
      private = false, logicalOwnerCid = "company:1",
    },
  },
  edgeObjects = { add = {}, retain = {}, remove = {} },
  remove = { edges = {}, nodes = {} },
}
auditTransaction.digest = proposalCodec.digest(auditTransaction)
auditTransaction.transactionId = "proposal:" .. auditTransaction.digest
local canonicalBefore = require("tpf2_mp/util").tableCount(script.save().canonical.byCanonical)
script.handleEvent("test", "tpf2mp", "intent", { type = "proposal.build", transaction = auditTransaction })
local auditQueued = script.save()
local auditQueuedPostDigest = auditQueued.eventLog.items[#auditQueued.eventLog.items].postDigest
local auditProposalId
for proposalId, record in pairs(auditQueued.world.proposals.byId) do
  if record.transactionId == auditTransaction.transactionId and record.status == "queued" then
    auditProposalId = proposalId
  end
end
assert(auditProposalId, "canonical proposal did not enter the asynchronous queue")
components.BASE_NODE[301] = { position = { x = 0, y = 0, z = 0 } }
components.BASE_NODE[302] = { position = { x = 20, y = 0, z = 0 } }
components.BASE_EDGE[303] = { node0 = 301, node1 = 302 }
components.BASE_EDGE_TRACK = components.BASE_EDGE_TRACK or {}
components.BASE_EDGE_TRACK[303] = { trackType = 0, catenary = false }
script.handleEvent("test", "tpf2mp", "proposal.result", {
  proposalId = auditProposalId,
  success = true,
  createdNodeIds = { 301, 302 },
  createdEdgeIds = { 303 },
})
local auditFinal = script.save()
local finalEvent = auditFinal.eventLog.items[#auditFinal.eventLog.items]
assert(auditFinal.world.proposals.byId[auditProposalId].status == "applied",
  "asynchronous canonical proposal did not finalise")
assert(require("tpf2_mp/util").tableCount(auditFinal.canonical.byCanonical) == canonicalBefore + 3,
  "proposal finalisation did not bind all canonical outputs")
assert(finalEvent.action.type == "proposal.finalise"
  and finalEvent.action.proposalId == auditProposalId
  and finalEvent.action.createdNodeIds == nil and finalEvent.action.createdEdgeIds == nil,
  "machine-local proposal result IDs leaked into the persistent event action")
assert(finalEvent.preDigest == auditQueuedPostDigest,
  "asynchronous proposal finalisation broke the core hash-chain boundary")

-- The GUI performs an early raw-entity endpoint check, but ordered replay is
-- also an authority boundary. A forged/stale proposal must not attach to a
-- canonical node owned by another company even if it reaches the queue.
local guardedState = script.save()
local guardedNodeCid = assert(canonical.resolveCanonical(guardedState.canonical, "node", 301))
guardedState.world.logicalOwners["301"] = "company:1"
guardedState.canonical.byCanonical[guardedNodeCid].metadata.owner = "company:1"
script.load(guardedState)
local guardedProposalCount = require("tpf2_mp/util").tableCount(script.save().world.proposals.byId)
local rivalAttach = {
  schemaVersion = proposalCodec.SCHEMA_VERSION,
  companyCid = "company:2",
  cost = 0,
  nodes = {
    { slot = "node:1", position = { x = -20, y = 0, z = 0 } },
  },
  edges = {
    {
      slot = "edge:1", carrier = "track",
      node0 = { cid = guardedNodeCid }, node1 = { slot = "node:1" },
      tangent0 = { x = -20, y = 0, z = 0 }, tangent1 = { x = -20, y = 0, z = 0 },
      type = 0, typeIndex = 0, resource = { index = 0 }, catenary = false,
      private = true, logicalOwnerCid = "company:2",
    },
  },
  edgeObjects = { add = {}, retain = {}, remove = {} },
  remove = { edges = {}, nodes = {} },
}
rivalAttach.digest = proposalCodec.digest(rivalAttach)
rivalAttach.transactionId = "proposal:" .. rivalAttach.digest
script.handleEvent("test", "tpf2mp", "intent", { type = "proposal.build", transaction = rivalAttach })
local rivalRejected = script.save()
assert(tostring(rivalRejected.lastError or ""):find("cannot attach to rival private node", 1, true),
  "authoritative proposal queue accepted a rival endpoint attachment")
assert(require("tpf2_mp/util").tableCount(rivalRejected.world.proposals.byId) == guardedProposalCount,
  "rejected rival endpoint proposal entered the physical replay queue")

-- A match must not stop accepting builds after 32 completed transactions.
-- Populate a serialized state exactly at the retention cap, then prove the
-- next canonical proposal deterministically prunes old completed diagnostics
-- while retaining the new in-flight transaction.
local retentionState = script.save()
retentionState.world.proposals.byId = {}
for index = 1, 32 do
  retentionState.world.proposals.byId[string.format("completed:%02d", index)] = {
    proposalId = string.format("completed:%02d", index),
    status = index % 2 == 0 and "applied" or "failed",
    queuedTick = index,
    completedTick = index,
  }
end
script.load(retentionState)
local transaction = {
  schemaVersion = proposalCodec.SCHEMA_VERSION,
  companyCid = "company:1",
  cost = 0,
  nodes = {
    { slot = "node:1", position = { x = 0, y = 0, z = 0 } },
    { slot = "node:2", position = { x = 20, y = 0, z = 0 } },
  },
  edges = {
    {
      slot = "edge:1", carrier = "track",
      node0 = { slot = "node:1" }, node1 = { slot = "node:2" },
      tangent0 = { x = 20, y = 0, z = 0 }, tangent1 = { x = 20, y = 0, z = 0 },
      type = 0, typeIndex = 0, resource = { index = 0 }, catenary = false,
      private = true, logicalOwnerCid = "company:1",
    },
  },
  edgeObjects = { add = {}, retain = {}, remove = {} },
  remove = { edges = {}, nodes = {} },
}
transaction.digest = proposalCodec.digest(transaction)
transaction.transactionId = "proposal:" .. transaction.digest
script.handleEvent("test", "tpf2mp", "intent", { type = "proposal.build", transaction = transaction })
local pruned = script.save()
assert(pruned.lastError == nil, "completed proposal retention blocked a new transaction")
assert(pruned.world.proposals.byId["completed:01"] == nil
  and pruned.world.proposals.byId["completed:16"] == nil
  and pruned.world.proposals.byId["completed:17"] ~= nil,
  "proposal retention did not prune the oldest completed records deterministically")
assert(pruned.world.proposals.queued >= 1 and #pruned.eventLog.items > 0,
  "new proposal was not queued after retention pruning")
assert(require("tpf2_mp/util").tableCount(pruned.world.proposals.byId) == 17,
  "proposal retention did not preserve the intended 16 completed plus one in-flight records")

script.handleEvent("test", "tpf2mp", "intent", { type = "match.finish", reason = "hotseat-manual" })
local manuallyFinished = script.save()
assert(manuallyFinished.match.status == "finished", "standalone manual finish did not close the match")
assert(manuallyFinished.match.finishReason == "hotseat-manual", "standalone manual finish lost its reason")
assert(manuallyFinished.match.winnerCid == "company:1", "zero-score manual finish did not use stable company-ID tie-breaking")

local world = require "tpf2_mp/world"
local canonical = require "tpf2_mp/canonical"
components.PLAYER_OWNED[299] = { player = 100 }
components.TRANSPORT_VEHICLE[299] = { line = -1, depot = -1 }
local workingSetPlayer = game.interface.setPlayer
game.interface.setPlayer = function(id, playerId)
  if id ~= 299 then workingSetPlayer(id, playerId) end
end
local failedClaim = world.claimEntities(canonical.newState(), { 299 }, 101, "postcondition-test", {})
assert(#failedClaim.failed == 1, "ownership postcondition failure was not reported")
assert(components.PLAYER_OWNED[299].player == 100, "failed ownership change corrupted the original owner")
game.interface.setPlayer = workingSetPlayer

print("PASS standalone proxy companies/assets/rolling-stock/financial reconciliation")
