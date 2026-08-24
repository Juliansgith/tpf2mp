local bootstrapPath = assert(arg[1], "bootstrap path is required")

local files = {
  ["bridge/launcher/start-clicked"] = "clicked",
  ["bridge/launcher/network-pump-generation"] = "wake-test",
  ["bridge/launcher/manual-bootstrap-ready"] = "ready",
  ["bridge/companion_state/companion_status.json"] =
    '{"pausedHeartbeatRequired":true}',
}
local wall = 100
local registrationPrints = 0
local pumpCalls = 0

local originalOpen = io.open
local originalGetenv = os.getenv
local originalTime = os.time
local originalPrint = print

io.open = function(path, mode)
  path = tostring(path)
  mode = tostring(mode or "r")
  if mode:find("r", 1, true) then
    local value = files[path]
    if value == nil then return nil end
    return {
      read = function() return value end,
      close = function() end,
    }
  end
  local chunks = {}
  return {
    write = function(_, ...)
      for i = 1, select("#", ...) do
        chunks[#chunks + 1] = tostring(select(i, ...))
      end
    end,
    close = function()
      files[path] = table.concat(chunks)
    end,
  }
end

os.getenv = function(name)
  local values = {
    TPF2MP_PEER_ID = "player1",
    TPF2MP_SESSION_ID = "menu-pump-test",
    TPF2MP_BRIDGE_DIR = "bridge",
    TPF2MP_STAGED_SAVE_NAME = "starting-world",
    TPF2MP_REQUIRE_MENU_ENTRY = "1",
  }
  return values[name]
end
os.time = function() return wall end
print = function(message)
  if tostring(message):find("registering native launcher bootstrap API", 1, true) then
    registrationPrints = registrationPrints + 1
    _G.tpf2mp_native_launcher_bootstrap_ready = function() return "ready" end
    _G.tpf2mp_native_launcher_pump = function()
      pumpCalls = pumpCalls + 1
      return "A1|script-event"
    end
  end
end

local ok, errorValue = pcall(function()
  dofile(bootstrapPath)
  local runtime = assert(data(), "bootstrap data() returned nil")

  -- The first wall-clock sample intentionally occurs at frame 1, not at a
  -- magic frame multiple.  It must still print once so the injected luaB_print
  -- hook can register its native API into this long-lived Console state.
  runtime.update()
  assert(registrationPrints == 1,
    "native launcher registration was still coupled to a frame modulus")
  assert(pumpCalls == 1, "first paused-network pump was not dispatched")
  assert((files["bridge/launcher/paused-network-pump"] or ""):find(
    '"generation":"wake-test"', 1, true), "generation receipt was not written")

  -- Same-second render updates must remain cheap and must not print or pump.
  for _ = 1, 10 do runtime.update() end
  assert(registrationPrints == 1, "same-second updates repeated native registration")
  assert(pumpCalls == 1, "same-second updates bypassed wall-clock throttling")

  wall = wall + 1
  runtime.update()
  assert(registrationPrints == 1, "registered native API was needlessly reinstalled")
  assert(pumpCalls == 2, "persistent paused-network heartbeat did not resume next second")
end)

io.open = originalOpen
os.getenv = originalGetenv
os.time = originalTime
print = originalPrint
_G.tpf2mp_native_launcher_bootstrap_ready = nil
_G.tpf2mp_native_launcher_pump = nil

if not ok then error(errorValue, 0) end
print("PASS multiplayer menu bootstrap registers native API under throttling")
