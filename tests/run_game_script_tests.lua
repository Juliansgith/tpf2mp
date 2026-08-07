local project = assert(arg[1], "project root argument required"):gsub("\\", "/")
local bridgeRoot = assert(arg[2], "bridge root argument required"):gsub("\\", "/")
package.path = project .. "/tpf2_mp_1/res/scripts/?.lua;" .. package.path

local json = require "tpf2_mp/json"
local hash = require "tpf2_mp/hash"
local util = require "tpf2_mp/util"
local economy = require "tpf2_mp/economy"
local bridgeModule = require "tpf2_mp/bridge"

local nextPlayer = 100
local commands = {}
local nativeGameSpeed = 1
local buildGateEnables, commandGateEnables = 0, 0
local buildGateEnabled, commandGateEnabled = false, false
local authorizedCommandTags = {}
tpf2mp_native_enable_build_gate = function()
  buildGateEnables, buildGateEnabled = buildGateEnables + 1, true
end
tpf2mp_native_disable_build_gate = function() buildGateEnabled = false end
tpf2mp_native_enable_command_gate = function()
  commandGateEnables, commandGateEnabled = commandGateEnables + 1, true
end
tpf2mp_native_disable_command_gate = function() commandGateEnabled = false end
tpf2mp_native_authorize_command = function(tag) authorizedCommandTags[#authorizedCommandTags + 1] = tostring(tag) end
tpf2mp_native_status = function()
  return {
    active = true,
    validation = { valid = true, signatures = {} },
    hooks = {
      enabled = true,
      buildProposalVisitor = true,
      authorityCommandVisitors = 23,
    },
    gates = {
      buildProposal = { enabled = buildGateEnabled },
      commandVisitors = {
        enabled = commandGateEnabled,
        hooked = 23,
        tagMismatches = 0,
      },
    },
  }
end

game = {
  config = {
    tpf2mp = {
      protocolVersion = 1,
      peerId = "player1",
      sessionId = "engine-test",
      bridgeDir = bridgeRoot,
      updateStride = 1,
      maxEvents = 64,
      startNetwork = true,
      startingCash = 5000000,
      maxEpochs = 2,
      valuationTargetCents = 0,
    },
  },
  interface = {
    addPlayer = function() nextPlayer = nextPlayer + 1; return nextPlayer end,
    getPlayer = function() return 100 end,
    getEntity = function(id) return { id = id, type = "PLAYER", name = "Entity " .. tostring(id), balance = 5000000, loan = 0 } end,
    setName = function() end,
    setPlayer = function() end,
    getTowns = function() return {} end,
    getLines = function() return {} end,
    getVehicles = function() return {} end,
    setTownCapacities = function() end,
    setTownDevelopmentActive = function() end,
    getGameSpeed = function() return nativeGameSpeed end,
    getGameTime = function() return { time = 100 } end,
    getPlayerJournal = function() return { income = { _sum = 0 } } end,
  },
}

api = {
  type = {
    ComponentType = {
      NAME = "NAME", LINE = "LINE", TRANSPORT_VEHICLE = "TRANSPORT_VEHICLE",
      CONSTRUCTION = "CONSTRUCTION", STATION_GROUP = "STATION_GROUP", STATION = "STATION",
      BASE_EDGE = "BASE_EDGE", BASE_NODE = "BASE_NODE", SIM_BUILDING = "SIM_BUILDING",
      TOWN = "TOWN", PLAYER = "PLAYER", PLAYER_OWNED = "PLAYER_OWNED",
    },
    JournalEntryCategory = { new = function() return {} end },
    JournalEntry = { new = function() return {} end },
  },
  engine = {
    getComponent = function() return nil end,
    forEachEntityWithComponent = function() end,
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
      sendScriptEvent = function(file, id, name, param) return { kind = "script", file = file, id = id, name = name, param = param } end,
      bookJournalEntry = function(player, journal) return { kind = "book", player = player, journal = journal } end,
      buildProposal = function() return {} end,
      developTown = function() return {} end,
      setSimBuildingManualDevelopment = function() return {} end,
      setCalendarSpeed = function(speed) return { kind = "calendar", speed = speed } end,
      setGameSpeed = function(speed) return { kind = "speed", speed = speed } end,
    },
    sendCommand = function(command, callback)
      commands[#commands + 1] = command
      if command.kind == "speed" then nativeGameSpeed = command.speed end
      if callback then callback(command, true) end
    end,
  },
}

assert(loadfile(project .. "/tpf2_mp_1/res/config/game_script/tpf2_mp.lua"))()
local script = assert(data())
script.init()
assert(buildGateEnables == 1 and commandGateEnables == 1,
  "network startup did not enable both native authority gates")
assert(#authorizedCommandTags == 0 and #commands == 0,
  "engine init issued a native clock command before ScriptSave equality")
local startupState = script.save().world.networkClock.startupPause
assert(startupState.requested == false and startupState.confirmed == false,
  "engine init issued a native game-speed command before ScriptSave equality")
script.update()
startupState = script.save().world.networkClock.startupPause
assert(authorizedCommandTags[1] == "0" and commands[1].kind == "speed"
    and commands[1].speed == 0 and authorizedCommandTags[2] == "1"
    and commands[2].kind == "calendar" and commands[2].speed == 0
    and startupState.requested == true,
  "post-init network update did not rearm both native clocks")
script.update()
assert(script.save().world.networkClock.startupPause.confirmed == true,
  "second post-init network update did not confirm the native startup pause")

script.handleEvent("test", "tpf2mp", "intent", { type = "match.initialise" })
local queued = script.save()
assert(queued.initialized == false, "network intent must wait for a host commit")
assert(queued.bridge.nextOutSeq == 2, "intent was not emitted to the bridge")

local commit = {
  protocol = 1,
  session = "engine-test",
  seq = 1,
  kind = "commit",
  origin_peer = "player1",
  origin_local_seq = 1,
  tick = 1,
  payload = { action = { type = "match.initialise", rules = { maxEpochs = 2, valuationTargetCents = 0 } } },
}
commit.checksum = hash.value(commit)
local inbound = assert(io.open(bridgeRoot .. "/game_inbox/000000000001.json", "wb"))
inbound:write(json.encode(commit) .. "\n")
inbound:close()
-- A paused world has no simulation update tick.  The periodic GUI snapshot
-- request must still consume ordered ingress, otherwise the initial match
-- commit (and later pause-time controls) deadlock in the inbox.
script.handleEvent("test", "tpf2mp", "snapshot.request", { launcherReady = true })

local initialized = script.save()
assert(initialized.initialized == true, "paused snapshot pump did not apply the committed match")
assert(#initialized.companyOrder == 2, "two companies were not created")
assert(initialized.eventLog.items[1].commitSeq == 1, "commit sequence was not retained")
assert(initialized.bridge.nextInSeq == 2, "commit cursor did not advance")
assert(initialized.version == 23,
  "state schema was not migrated to the coordinated recovery/town-development version")
assert(initialized.checkpoint.exports == 1, "match initialisation did not export a baseline checkpoint")

local checkpointMessage
for localSeq = 1, initialized.bridge.nextOutSeq - 1 do
  local checkpointFile = assert(io.open(string.format(
    "%s/game_outbox/%012d.json", bridgeRoot, localSeq), "rb"))
  local message = json.decode(checkpointFile:read("*a"))
  checkpointFile:close()
  if message.kind == "checkpoint" then checkpointMessage = message; break end
end
assert(checkpointMessage, "baseline checkpoint was not emitted")
assert(bridgeModule.verify(checkpointMessage), "baseline checkpoint envelope failed verification")
assert(checkpointMessage.kind == "checkpoint", "baseline checkpoint used the wrong message kind")
local checkpoint = checkpointMessage.payload
assert(checkpoint.checkpointVersion == 3, "checkpoint format version is wrong")
assert(checkpoint.financialDigest == hash.value(checkpoint.financial), "checkpoint financial digest is invalid")
assert(checkpoint.financial.companies["company:1"].balance == 5000000,
  "checkpoint did not capture canonical company finances")
assert(checkpoint.modelDigest == hash.value(checkpoint.model), "checkpoint model digest is invalid")
assert(checkpoint.canonicalDigest == hash.value(checkpoint.canonical), "checkpoint canonical digest is invalid")
local checkpointCore = util.deepCopy(checkpoint.model)
checkpointCore.canonical = util.deepCopy(checkpoint.canonical)
checkpointCore.vehicleSynchronization = util.deepCopy(checkpoint.vehicleSynchronization)
assert(checkpoint.coreDigest == hash.value(checkpointCore), "checkpoint core digest is invalid")
local checkpointCopy = util.deepCopy(checkpoint)
local expectedCheckpointDigest = checkpointCopy.checkpointDigest
checkpointCopy.checkpointDigest = nil
assert(expectedCheckpointDigest == hash.value(checkpointCopy), "checkpoint payload digest is invalid")
assert(checkpoint.eventCursor.lastEventSeq == 1, "baseline checkpoint did not anchor the initialisation event")

local demoCommit = {
  protocol = 1,
  session = "engine-test",
  seq = 2,
  kind = "commit",
  origin_peer = "player2",
  origin_local_seq = 1,
  tick = 2,
  payload = { action = { type = "economy.seed_demo" } },
}
demoCommit.checksum = hash.value(demoCommit)
local second = assert(io.open(bridgeRoot .. "/game_inbox/000000000002.json", "wb"))
second:write(json.encode(demoCommit) .. "\n")
second:close()
script.update()

local demo = script.save()
assert(demo.economy.lastResults.totalDemand == 1800,
  "demo passenger and freight markets were not both evaluated")
assert(demo.economy.markets["market:prototype-freight"]
  and demo.economy.markets["market:prototype-freight"].kind == "cargo",
  "demo freight market lost its cargo kind")
assert(demo.economy.lastResults.preview == true, "demo result was not marked as a preview")
assert(demo.economy.epoch == 0, "seeding a demo must not consume an authoritative epoch")
assert(demo.eventLog.items[2].seq == 2 and demo.eventLog.items[2].commitSeq == 2, "event ordering is wrong")
assert(demo.bridge.nextOutSeq >= 4, "digest acknowledgements were not emitted")

local authoritativeResults = economy.evaluateAll(util.deepCopy(demo.economy))
assert(authoritativeResults.epoch == 1, "first authoritative settlement should use epoch 1")
local settleCommit = {
  protocol = 1,
  session = "engine-test",
  seq = 3,
  kind = "commit",
  origin_peer = "player1",
  origin_local_seq = 2,
  tick = 3,
  payload = { action = { type = "economy.settle", results = authoritativeResults } },
}
settleCommit.checksum = hash.value(settleCommit)
local third = assert(io.open(bridgeRoot .. "/game_inbox/000000000003.json", "wb"))
third:write(json.encode(settleCommit) .. "\n")
third:close()
script.update()

local settled = script.save()
assert(settled.lastError == nil, "successful committed action left a false error")
assert(settled.economy.ledger.settlementCount == 1, "settlement ledger did not advance")
assert(settled.economy.epoch == 1, "settlement committed the wrong epoch")
assert(settled.finance.totalPaid > 0, "native payout commands were not booked")
assert(settled.eventLog.items[3].postDigest ~= settled.eventLog.items[3].preDigest, "settlement did not change canonical model state")
assert(settled.eventLog.items[3].postModelDigest ~= settled.eventLog.items[3].preModelDigest,
  "settlement did not change the independently replayable model digest")
assert(settled.match.status == "running", "match ended before its configured epoch limit")

local secondResults = economy.evaluateAll(util.deepCopy(settled.economy))
local secondSettleCommit = {
  protocol = 1,
  session = "engine-test",
  seq = 4,
  kind = "commit",
  origin_peer = "player1",
  origin_local_seq = 3,
  tick = 4,
  payload = { action = { type = "economy.settle", results = secondResults } },
}
secondSettleCommit.checksum = hash.value(secondSettleCommit)
local fourth = assert(io.open(bridgeRoot .. "/game_inbox/000000000004.json", "wb"))
fourth:write(json.encode(secondSettleCommit) .. "\n")
fourth:close()
script.update()
local automaticallyFinished = script.save()
assert(automaticallyFinished.economy.epoch == 2, "second authoritative settlement was not applied")
assert(automaticallyFinished.match.status == "finished", "epoch limit did not finish the match")
assert(automaticallyFinished.match.finishReason == "epoch-limit", "automatic match finish used the wrong reason")
assert(automaticallyFinished.match.winnerCid == "company:1" or automaticallyFinished.match.winnerCid == "company:2",
  "automatic match finish did not select a canonical winner")

script.handleEvent("test", "tpf2mp", "intent", { type = "checkpoint.export", reason = "integration-test" })
local manualMessage
for localSeq = 1, script.save().bridge.nextOutSeq - 1 do
  local manualFile = assert(io.open(string.format(
    "%s/game_outbox/%012d.json", bridgeRoot, localSeq), "rb"))
  local message = json.decode(manualFile:read("*a"))
  manualFile:close()
  if message.kind == "checkpoint" and message.payload.reason == "integration-test" then
    manualMessage = message
    break
  end
end
assert(manualMessage, "manual checkpoint was not emitted")
assert(bridgeModule.verify(manualMessage), "manual checkpoint envelope failed verification")
assert(manualMessage.kind == "checkpoint", "manual checkpoint used the wrong message kind")
assert(manualMessage.payload.reason == "integration-test", "manual checkpoint reason was not preserved")
assert(manualMessage.payload.eventCursor.lastEventSeq == 4, "manual checkpoint cursor is wrong")

-- Game speed is a host-ordered control rather than an unsynchronised local UI
-- mutation.  The exact native visitor remains gated; a committed generation
-- receives the one-shot tag-0 authorization before SetGameSpeed is issued.
local clockCommit = {
  protocol = 1,
  session = "engine-test",
  seq = 5,
  kind = "commit",
  origin_peer = "player1",
  origin_local_seq = 4,
  tick = 5,
  payload = { action = {
    type = "clock.set", requestedSpeed = 4, effectiveSpeed = 3,
    generation = 1, reason = "integration-slowest-peer-cap",
  } },
}
clockCommit.checksum = hash.value(clockCommit)
local fifth = assert(io.open(bridgeRoot .. "/game_inbox/000000000005.json", "wb"))
fifth:write(json.encode(clockCommit) .. "\n")
fifth:close()
script.update()
local clocked = script.save()
assert(clocked.world.networkClock.requestedSpeed == 4
  and clocked.world.networkClock.effectiveSpeed == 3
  and clocked.world.networkClock.generation == 1,
  "ordered shared-clock state was not retained")
assert(authorizedCommandTags[#authorizedCommandTags] == "0"
  and commands[#commands].kind == "speed" and commands[#commands].speed == 3,
  "shared clock did not authorize and issue the effective native game speed")

local savedCommandGate = tpf2mp_native_enable_command_gate
tpf2mp_native_enable_command_gate = nil
script.load(nil)
script.init()
local authorityFault = script.save()
assert(authorityFault.probes.networkAuthority.ready == false,
  "network startup did not fault closed when the command gate was missing")
script.handleEvent("test", "tpf2mp", "intent", { type = "match.initialise" })
authorityFault = script.save()
assert(authorityFault.initialized == false and authorityFault.bridge.nextOutSeq == 1,
  "authority-faulted network mode emitted a gameplay intent")
assert(tostring(authorityFault.lastError):find("network authority is not ready", 1, true),
  "authority startup fault was not surfaced")
tpf2mp_native_enable_command_gate = savedCommandGate
local savedNativeStatus = tpf2mp_native_status
tpf2mp_native_status = function()
  return {
    active = false,
    validation = { valid = true },
    hooks = { enabled = true, buildProposalVisitor = true, authorityCommandVisitors = 23 },
    gates = {
      buildProposal = { enabled = true },
      commandVisitors = { enabled = true, hooked = 23, tagMismatches = 0 },
    },
  }
end
script.load(nil)
script.init()
authorityFault = script.save()
assert(authorityFault.probes.networkAuthority.ready == false,
  "network startup trusted authority functions from an inactive native hook")
tpf2mp_native_status = savedNativeStatus

-- A populated save from an older network session contributes only its native
-- world to a newly identified match. Canonical barriers, accounts, companies,
-- and validation progress must not leak across session IDs.
local priorNetworkSave = util.deepCopy(automaticallyFinished)
priorNetworkSave.bridge.sessionId = "older-network-session"
game.config.tpf2mp.sessionId = "engine-test-new-session"
script.load(priorNetworkSave)
local freshSession = script.save()
assert(freshSession.initialized == false and freshSession.match.status == "setup",
  "new network session retained the prior match lifecycle")
assert(#freshSession.companyOrder == 0
  and next(freshSession.world.checkpointConsensus.byBoundary) == nil,
  "new network session retained prior companies or checkpoint barriers")
assert(freshSession.bridge.sessionId == "engine-test-new-session"
  and freshSession.recovery.freshNetworkBootstrap
  and freshSession.recovery.freshNetworkBootstrap.reason
    == "launcher-new-network-session-over-prior-network-save"
  and freshSession.world.networkClock.startupPause.requested == false,
  "new network session did not record its physical-world-only bootstrap")
game.config.tpf2mp.sessionId = "engine-test"
print("PASS game-script intent/commit/persistence integration")
