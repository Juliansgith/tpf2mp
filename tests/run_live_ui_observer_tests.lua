local project = assert(arg[1]):gsub("\\", "/")
assert(loadfile(project .. "/tpf2_mp_1/res/config/game_script/tpf2_mp.lua"))
package.path = project .. "/tpf2_mp_1/res/scripts/?.lua;" .. package.path
local json = require "tpf2_mp/json"
assert(loadfile(project .. "/tests/live_ui_geometry_cases.lua"))()(project)
assert(loadfile(project .. "/tests/live_ui_ground_cursor_cases.lua"))()
assert(loadfile(project .. "/tests/live_ui_terrain_cases.lua"))()()
assert(loadfile(project .. "/tests/live_ui_terrain_callable_cases.lua"))()()
local oldGetenv, oldOpen, oldTime, oldRemove, oldRename = os.getenv, io.open, os.time, os.remove, os.rename
local env, files, now, opens = {}, {}, 100, 0
os.getenv = function(key) return env[key] end
os.time = function() return now end
io.open = function(path, mode)
  opens = opens + 1
  if mode == "rb" then
    if not files[path] then return nil end
    return { read = function(_, n) return files[path]:sub(1, n) end, close = function() end }
  end
  return { write = function(_, body) files[path] = body end, close = function() end }
end
os.remove, os.rename = nil, nil -- Actual game's sandbox, not desktop Lua.
local function loadObserver()
  package.loaded["tpf2_mp/live_ui_observer"] = nil
  return require "tpf2_mp/live_ui_observer"
end
loadObserver().engine({}, function() error("disabled must not read state") end, {})
assert(opens == 0, "ordinary games must do zero test IO")
env = { TPF2MP_LIVE_UI_TOKEN = string.rep("a", 32), TPF2MP_BRIDGE_DIR = "bridge",
  TPF2MP_PEER_ID = "player1", TPF2MP_SESSION_ID = "real-player-session" }
loadObserver().engine({}, function() error("not a disposable lab") end, {})
assert(opens == 0, "non-test sessions must remain disabled")
env.TPF2MP_SESSION_ID = "localhost-ui-test"
local observer = loadObserver()
local prefix = "bridge/launcher/ui-test-world"
local request = { id = "test1", token = env.TPF2MP_LIVE_UI_TOKEN,
  session = env.TPF2MP_SESSION_ID, action = "observe" }
local public = { initialized = true, deferredNetworkQueue = { count = 0 },
  proposalConsensus = { pending = 0 }, operationConsensus = { pending = 0 }, checkpointConsensus = { pending = 0 } }
local sampled = 0
local state = { canonical = { byCanonical = {} }, world = {}, companies = {} }
local world = { nativeFingerprint = function(_, _, _, options)
  assert(options.fullInventory); sampled = sampled + 1; return { inventoryComplete = true }
end, structuralSnapshot = function(registry, stateCopy)
  registry.observerDiscovered = true; stateCopy.observerDiscovered = true
  return { digest = "physical" }
end }
local function send()
  now = now + 1; files[prefix .. ".request.json"] = json.encode(request)
  observer.engine(state, function() return public end, world)
  return files[prefix .. ".response.json"] and json.decode(files[prefix .. ".response.json"])
end
request.token = "wrong"; assert(send() == nil and sampled == 0)
request.token = env.TPF2MP_LIVE_UI_TOKEN
local response = send(); assert(response.success and response.value.structure.digest == "physical" and sampled == 1)
assert(state.canonical.observerDiscovered == nil and state.world.observerDiscovered == nil,
  "structural discovery must never mutate the real world or canonical registry")
send(); assert(sampled == 1, "duplicate request must not resample")
state.probes = { capture = { proposalSnapshots = { { tick = 9, snapshot = {
  __nativeFactoryCapture = { ignoreErrors = false, optionFieldsKnown = true,
    generation = 7, addedEdgeCount = 5, constructionsToAdd = { "do-not-export" } } } } } } }
request.id = "capture-options"
response = send()
assert(response.value.nativeBuildCaptures[1].ignoreErrors == false
  and response.value.nativeBuildCaptures[1].addedEdgeCount == 5
  and response.value.nativeBuildCaptures[1].constructionsToAdd == nil,
  "factory option diagnostics must retain false and exclude full proposal vectors")
assert(sampled == 2)
request.id = "busy"; public.proposalConsensus.pending = 1
response = send(); assert(response.success and response.value.busy and sampled == 2)
request.id = "inject"; request.action = "build"
response = send(); assert(not response.success and sampled == 2, "no mutation API allowed")
request.action = "observe"; request.id = "checkpoint-only"
public.proposalConsensus.pending = 0; public.checkpointConsensus.pending = 1
response = send()
assert(response.success and response.value.busy and response.value.structure.digest == "physical"
  and response.value.native == nil and response.value.bindings == nil and sampled == 2,
  "checkpoint-only wait retains route evidence, never a ready inventory")
for _, key in ipairs({ "proposalConsensus", "operationConsensus" }) do
  request.id = "mutation-" .. key; public[key].pending = 1
  response = send()
  assert(response.success and response.value.structure == nil and sampled == 2,
    "pending gameplay must fence structural and vehicle reads")
  public[key].pending = 0
end
request.id = "awaiting-order"; public.deferredNetworkQueue.awaitingOrder = 1
response = send()
assert(response.value.structure == nil and sampled == 2, "unknown ordered mutation must fence reads")
public.deferredNetworkQueue.awaitingOrder = nil
request.geometry, request.id = true, "geometry-checkpoint-fence"
response = send()
assert(response.success and response.value.geometry == nil,
  "checkpoint waits must fence optional physical geometry reads")
public.checkpointConsensus.pending = 0
request.id = "geometry-ready"
response = send()
assert(response.success and response.value.geometry.complete and response.value.geometry.count == 0)
request.geometry, request.id = false, "geometry-invalid-request"
assert(not send().success, "geometry observation accepts no alternate operation")
request.geometry = nil
local function diagnostic()
  package.loaded["tpf2_mp/live_ui_build_diagnostics"] = nil
  return require "tpf2_mp/live_ui_build_diagnostics"
end
local testGui = { frames = 100 }
env.TPF2MP_SESSION_ID = "normal-session"
diagnostic().capture(testGui, {})
diagnostic().replay(testGui, "proposal", {}, function() error("disabled getter") end)
assert(testGui.liveUiLastBuildCapture == nil and testGui.liveUiLastBuildReplay == nil)
env.TPF2MP_SESSION_ID = "localhost-ui-test"
local copied = { __nativeFactoryCapture = { optionFieldsKnown = true, ignoreErrors = false } }
diagnostic().capture(testGui, { exact = true, sourceId = "trackBuilder", proposalSnapshot = copied })
assert(testGui.liveUiLastBuildCapture.snapshot == copied
  and testGui.liveUiLastBuildCapture.snapshot.__nativeFactoryCapture.ignoreErrors == false)
diagnostic().replay(testGui, "p:1", {}, function(_, _, _, budget, options)
  assert(budget.remaining == 8192 and options.maxEntries == 256 and options.maxDepth == 12)
  return { ignoreErrors = false }
end)
assert(testGui.liveUiLastBuildReplay.command.ignoreErrors == false)
os.getenv, io.open, os.time, os.remove, os.rename = oldGetenv, oldOpen, oldTime, oldRemove, oldRename
local button = { getId = function() return "menu.construction.rail" end,
  getText = function() return "Rail" end, isSelected = function() return true end,
  getContentRect = function() return { x = 30, y = 40, w = 50, h = 60 } end,
  click = function() error("observer must never click native controls") end }
local root = { getContentRect = function() return { x = 0, y = 0, w = 1920, h = 1040 } end,
  getNumChildren = function() return 1 end,
  getChild = function(_, index) assert(index == 0); return button end }
api = { gui = { util = { getById = function(id)
  if id == "mainView" then return root end
  if id == "menu.construction.rail" then return button end
end } } }
local tree = require("tpf2_mp/live_ui_tree").observe({ action = "observe" }, { frames = 42 })
assert(#tree.nodes == 2 and tree.nodes[2].id == "menu.construction.rail"
  and tree.nodes[2].selected == true and tree.viewport.w == 1920)
tree = require("tpf2_mp/live_ui_tree").observe({ action = "observe", rootId = "menu.construction.rail" }, {})
assert(#tree.nodes == 1 and tree.nodes[1].selected and tree.viewport.w == 1920)
tree = require("tpf2_mp/live_ui_tree").observe({ action = "observe", rootId = "missing" }, {})
assert(#tree.nodes == 0 and tree.viewport.w == 1920)
assert(not pcall(require("tpf2_mp/live_ui_tree").observe, { action = "click" }, {}),
  "observation protocol must not implement UI callback invocation")
root.getNumChildren = function() return 513 end
root.getChild = function() return button end
tree = require("tpf2_mp/live_ui_tree").observe({ action = "observe" }, {})
assert(tree.truncated == true, "per-parent child limit must report incomplete evidence")
root.getNumChildren = function() return 0 end
local deep = root
for _ = 1, 43 do
  local child = {}
  deep.getContent = function() return child end
  deep = child
end
tree = require("tpf2_mp/live_ui_tree").observe({ action = "observe" }, {})
assert(tree.truncated == true, "depth limit must report incomplete evidence")
local vehicleRegistry = { byLocal = { ["line:30"] = "line:1" }, byCanonical = {
  ["vehicle:1"] = { kind = "vehicle", localId = 20, metadata = { owner = "company:1" } },
  ["vehicle:gone"] = { kind = "vehicle", localId = 21 },
  ["town:1"] = { kind = "town", localId = 40 },
  ["depot:1"] = { kind = "depot", localId = 60 },
  ["depot:2"] = { kind = "depot", localId = 61 },
  ["construction:unsafe"] = { kind = "construction", localId = 50 },
} }
local components = { [20] = {
  vehicle = { line = 30, state = 1, stopIndex = 0, carrier = 1, userStopped = false },
  movement = { dyn = { speed = 4.25 }, blocked = 0 },
}, [40] = { town = { pos = { x = 123, y = -456 } } },
  [60] = { depot = { carrier = 2 }, name = { name = "Airport" } },
  [61] = { depot = { carrier = 2 } } }
local telemetryApi = { type = { ComponentType = { TRANSPORT_VEHICLE = "vehicle",
  MOVE_PATH = "movement", MOVE_PATH_AIRCRAFT = "aircraft", TOWN = "town",
  VEHICLE_DEPOT = "depot", NAME = "name" } }, engine = {
  entityExists = function(id) assert(id ~= 50, "must not probe unrequested construction"); return components[id] ~= nil end,
  getComponent = function(id, kind) assert(components[id], "must not read a deleted entity"); return components[id][kind] end,
} }
local vehicles, towns, depots = require("tpf2_mp/live_ui_vehicle_observer").read(vehicleRegistry, telemetryApi)
assert(depots.missingName == 1 and depots.entries["depot:1"].name == "Airport"
  and depots.entries["depot:1"].carrier == 2 and not depots.entries["depot:2"].hasName)
assert(vehicles["vehicle:1"].speed == 4.25 and vehicles["vehicle:1"].lineCid == "line:1"
  and vehicles["vehicle:1"].userStopped == false and vehicles["vehicle:gone"] == nil)
assert(towns["town:1"].x == 123 and towns["town:1"].y == -456)
components[40].town.pos = nil
vehicles, towns = require("tpf2_mp/live_ui_vehicle_observer").read(vehicleRegistry, telemetryApi, {
  getEntity = function(id) assert(id == 40); return { position = { 123, -456, 7 } } end,
})
assert(towns["town:1"].x == 123 and towns["town:1"].y == -456 and towns["town:1"].z == 7)
components[20].movement = nil
components[20].aircraft = { speed = 80 }
vehicles = require("tpf2_mp/live_ui_vehicle_observer").read(vehicleRegistry, telemetryApi)
assert(vehicles["vehicle:1"].speed == 80, "aircraft native speed fallback")
assert(vehicles["vehicle:1"].models == nil, "missing native config is not model proof")
components[20].vehicle.transportVehicleConfig = { vehicles = {
  { part = { modelId = 5, loadConfig = { 0 }, reversed = false } }
} }
telemetryApi.res = { modelRep = { getName = function(id)
  assert(id == 5); return "vehicle/ship/schaffhausen.mdl"
end } }
vehicles = require("tpf2_mp/live_ui_vehicle_observer").read(vehicleRegistry, telemetryApi)
assert(#vehicles["vehicle:1"].models == 1 and vehicles["vehicle:1"].models[1] == "vehicle/ship/schaffhausen.mdl")
assert(vehicleRegistry.byCanonical["vehicle:1"].speed == nil, "observation cannot modify registry")
print("PASS live UI observer: opt-in isolation, nonce, fresh physical sampling, busy fence, no gameplay dispatch")
