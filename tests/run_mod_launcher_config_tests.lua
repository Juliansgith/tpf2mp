local project = assert(arg[1], "project root argument required"):gsub("\\", "/")

_ = function(value) return value end
getCurrentModId = function() return "!tpf2_mp" end
game = { config = {} }

assert(loadfile(project .. "/tpf2_mp_1/mod.lua"))()
local definition = assert(data())
definition.runFn({}, {
  ["!tpf2_mp"] = {
    peer = 0,
    session = 0,
    startupMode = 0,
    freeze = 0,
    neutralizer = 0,
    proxyMode = 0,
    pauseOnSwitch = 0,
    startingCash = 0,
    epochLimit = 2,
    valuationTarget = 2,
    liveValidator = 0,
  },
})

local cfg = assert(game.config.tpf2mp)
assert(cfg.peerId == "player2", "launcher peer did not override the mod dropdown; TEMP="
  .. tostring(os.getenv("TEMP")) .. " peer=" .. tostring(cfg.peerId))
assert(cfg.sessionId == "launcher-test", "launcher session did not override the mod dropdown")
assert(cfg.bridgeDir == "C:/bridge/launcher-test/player2", "launcher bridge path was not loaded")
assert(cfg.startNetwork == true and cfg.launcherManaged == true,
  "launcher did not activate launcher-managed network mode")
assert(cfg.startingCash == 50000000,
  "explicit launcher research budget did not override the mod dropdown")

print("PASS short-lived launcher profile configures peer/session/bridge/network mode")
