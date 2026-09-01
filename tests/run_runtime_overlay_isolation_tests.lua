local project = assert(arg[1], "project root is required")

local originalGetenv = os.getenv
local originalOpen = io.open
local originalGame = game
local originalData = data

local ok, errorValue = pcall(function()
  local activation = assert(loadfile(project
    .. "/tpf2_mp_1/res/scripts/tpf2_mp/runtime_activation.lua"))()
  assert(activation.explicit({ config = {}, environment = function() return nil end,
    open = function() return nil end }) == false,
    "empty activation inputs were accepted")
  assert(activation.explicit({ config = { protocolVersion = 1 } }) == true,
    "selected-mod configuration was not accepted")
  local launcherEnvironment = {
    TPF2MP_PEER_ID = "player2", TPF2MP_SESSION_ID = "match-test",
    TPF2MP_BRIDGE_DIR = "bridge/player2",
  }
  assert(activation.explicit({ config = {}, environment = function(name)
    return launcherEnvironment[name]
  end }) == true, "complete launcher identity was not accepted")
  launcherEnvironment.TPF2MP_BRIDGE_DIR = nil
  assert(activation.explicit({ config = {}, environment = function(name)
    return launcherEnvironment[name]
  end, open = function() return nil end }) == false,
    "incomplete launcher identity was accepted")

  os.getenv = function() return nil end
  io.open = function() return nil end
  game = { config = {} }

  -- This is the exact orphan state: the base game discovers the copied game
  -- script, but mod.lua was not selected and no launcher owns the process.
  assert(loadfile(project .. "/tpf2_mp_1/res/config/game_script/tpf2_mp.lua"))()
  local script = assert(data(), "inert game script returned nil")
  assert(next(script) == nil,
    "orphan game-script overlay activated without a selected mod or launcher")

  dofile(project .. "/tools/multiplayer_menu_bootstrap.lua")
  local menu = assert(data(), "inert menu bootstrap returned nil")
  assert(type(menu.update) == "function", "inert menu bootstrap has no no-op update")
  menu.update()

  dofile(project .. "/tools/localhost_bootstrap.lua")
  local localhost = assert(data(), "inert localhost bootstrap returned nil")
  assert(type(localhost.update) == "function", "inert localhost bootstrap has no no-op update")
  localhost.update()
end)

os.getenv = originalGetenv
io.open = originalOpen
game = originalGame
data = originalData

if not ok then error(errorValue, 0) end
print("PASS orphan base-game overlays are inert without explicit activation")
