local script = assert(arg[1], 'benchmark script required')
local previous = { getenv = os.getenv, time = os.time, print = print, app = app, api = api, game = game, data = data }
local clock, atMenu, inGame = 0, true, false
local calls = { load = 0, stop = 0, quit = 0, speed = 0 }
local messages = {}
os.getenv = function(name)
  if name == 'TPF2MP_BENCH_SAVE_STEM' then return 'fixture' end
  if name == 'TPF2MP_BENCH_SECONDS' then return '5' end
  if name == 'TPF2MP_BENCH_RUN_TOKEN' then return 'unit-test' end
end
os.time = function() return clock end
print = function(message) messages[#messages + 1] = message end
api = { gui = { util = { getById = function(id)
  if id == 'menuUI' then return { isVisible = function() return atMenu end } end
  if id == 'ingameMenu' and inGame then return {} end
end } }, cmd = {
  make = { setGameSpeed = setmetatable({}, { __call = function(_, speed)
    assert(speed == 1); return 'speed-command'
  end }) },
  sendCommand = function(command) assert(command == 'speed-command'); calls.speed = calls.speed + 1 end,
} }
game = { interface = { getGameSpeed = function() return 1 end, getGameTime = function() return { time = clock } end } }
app = {
  loadGame = function(stem) assert(stem == 'fixture'); calls.load = calls.load + 1; return true end,
  stopGame = function() calls.stop = calls.stop + 1; atMenu = true; inGame = false end,
  quit = function() calls.quit = calls.quit + 1 end,
}
dofile(script)
local probe = data()
for i = 0, 9 do clock = i; probe.update() end
assert(calls.load == 0)
clock = 10; probe.update(); probe.update()
assert(calls.load == 1)
local pendingInterface = game.interface
game.interface = nil
clock, atMenu, inGame = 11, false, true
probe.update()
assert(calls.speed == 0, 'GUI readiness alone must not consume the speed request')
game.interface = pendingInterface
clock = 12; probe.update()
assert(calls.speed == 1)
for i = 13, 17 do clock = i; probe.update() end
assert(calls.stop == 1)
clock = 18; probe.update(); clock = 19; probe.update()
assert(calls.quit == 1 and calls.load == 1 and calls.speed == 1)
assert(messages[#messages]:find('token=unit%-test'))
-- The console scripting context may expose only the interface setter.
game.interface.setGameSpeed = function(speed) assert(speed == 1); calls.speed = calls.speed + 1 end
api.cmd = nil
clock, atMenu, inGame = 30, true, false
probe = data()
clock = 40; probe.update()
clock, atMenu, inGame = 41, false, true; probe.update()
assert(calls.speed == 2, 'native interface speed setter must work without api.cmd')
clock = 46; probe.update(); clock = 47; probe.update()
assert(calls.stop == 2 and calls.quit == 2)
-- A rejected save must never be retried by subsequent update callbacks.
app.loadGame = function() calls.load = calls.load + 1; return false end
clock, atMenu, inGame = 50, true, false
probe = data(); clock = 60; probe.update(); clock = 61; probe.update()
assert(calls.load == 3 and calls.quit == 3 and calls.stop == 2)
os.getenv = function() return nil end
probe = data(); clock = 100; probe.update()
assert(calls.load == 3, 'unconfigured script must be inert')
-- Six-phase script exercises paused/normal/fast readback and camera workload.
local phaseSpeeds, cameraCalls = {}, 0
os.getenv = function(name)
  if name == 'TPF2MP_BENCH_SAVE_STEM' then return 'fixture' end
  if name == 'TPF2MP_BENCH_SECONDS' then return '120' end
  if name == 'TPF2MP_BENCH_WORKLOAD' then return 'scaling' end
end
game.interface.setGameSpeed = function(value) phaseSpeeds[#phaseSpeeds+1] = value end
local oldGet = api.gui.util.getById
api.gui.util.getById = function(id)
  if id == 'mainView' then return { getCameraController = function() return {
    setCameraData = function() cameraCalls = cameraCalls + 1 end } end } end
  return oldGet(id)
end
api.type = { Vec2f = { new = function(x,y) return {x=x,y=y} end } }
app.loadGame = function() return true end
clock, atMenu, inGame = 200, true, false
probe = data(); clock = 210; probe.update()
atMenu, inGame = false, true
for i = 211, 331 do clock = i; probe.update() end
assert(table.concat(phaseSpeeds, ',') == '1,0,1,4,0,0,1')
assert(cameraCalls == 20)
os.getenv, os.time, print = previous.getenv, previous.time, previous.print
app, api, game, data = previous.app, previous.api, previous.game, previous.data
print('PASS native benchmark: stem-only load, startup delay, once-only commands, speed, cleanup, inert default')
