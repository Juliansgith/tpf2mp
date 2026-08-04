local project = assert(arg[1], "project root argument required"):gsub("\\", "/")
local bridgeRoot = assert(arg[2], "bridge root argument required"):gsub("\\", "/")
package.path = project .. "/tpf2_mp_1/res/scripts/?.lua;" .. package.path

local consolePrint = print
print = function(...)
  local first = tostring(select(1, ...))
  if not first:match("^%[TPF2MP%]") then consolePrint(...) end
end

local players = {
  [100] = { id = 100, balance = 10000000, loan = 0, name = "Player" },
}
local nextPlayer = 100

game = {
  config = {
    tpf2mp = {
      protocolVersion = 1,
      peerId = "player1",
      sessionId = "replay-trace",
      bridgeDir = bridgeRoot,
      updateStride = 1,
      maxEvents = 256,
      startNetwork = false,
      localProxyEnabled = false,
      maxEpochs = 0,
      valuationTargetCents = 0,
    },
  },
  interface = {
    addPlayer = function()
      nextPlayer = nextPlayer + 1
      players[nextPlayer] = { id = nextPlayer, balance = 10000000, loan = 0, name = "Player" }
      return nextPlayer
    end,
    getPlayer = function() return 100 end,
    getEntity = function(id) return players[id] end,
    setName = function(id, name) if players[id] then players[id].name = name end end,
    setPlayer = function() return true end,
    getTowns = function() return {} end,
    getLines = function() return {} end,
    getVehicles = function() return {} end,
    setTownCapacities = function() end,
    setTownDevelopmentActive = function() end,
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
      sendScriptEvent = function(file, id, name, param)
        return { kind = "script", file = file, id = id, name = name, param = param }
      end,
      bookJournalEntry = function(player, journal)
        return { kind = "book", player = player, amount = journal.amount }
      end,
      developTown = function() return {} end,
      setSimBuildingManualDevelopment = function() return {} end,
    },
    sendCommand = function(command)
      if command.kind == "book" then players[command.player].balance = players[command.player].balance + command.amount end
    end,
  },
}

assert(loadfile(project .. "/tpf2_mp_1/res/config/game_script/tpf2_mp.lua"))()
local script = assert(data())
script.init()
script.handleEvent("trace", "tpf2mp", "intent", { type = "match.initialise" })
script.handleEvent("trace", "tpf2mp", "intent", { type = "economy.seed_demo" })

for epoch = 1, 96 do
  if epoch > 1 and (epoch - 1) % 12 == 0 then
    script.handleEvent("trace", "tpf2mp", "intent", { type = "economy.seed_demo" })
  end
  script.handleEvent("trace", "tpf2mp", "intent", { type = "economy.settle" })
end

local saved = script.save()
assert(saved.economy.epoch == 96, "long replay trace stopped at the wrong epoch")
assert(saved.economy.ledger.settlementCount == 96, "long replay trace lost a settlement")
assert(saved.match.status == "running", "disabled match limits unexpectedly finished the trace")
assert(saved.eventLog.nextSeq == 106, "long replay trace recorded the wrong event count")
assert(saved.checkpoint.exports == 1, "long replay trace lost its automatic baseline checkpoint")
print("PASS 104-event post-checkpoint deterministic replay trace generated")
