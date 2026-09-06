-- Opt-in, local test observer. It cannot submit/replay gameplay commands.
-- Requests live only under the launcher's bridge, are size bounded, and must
-- carry the capability inherited by these two disposable game processes.
local json = require "tpf2_mp/json"
local util = require "tpf2_mp/util"
local M = {}
local token = os.getenv("TPF2MP_LIVE_UI_TOKEN") or ""
local root = os.getenv("TPF2MP_BRIDGE_DIR") or ""
local session = os.getenv("TPF2MP_SESSION_ID") or ""
local peer = os.getenv("TPF2MP_PEER_ID") or ""
local enabled = token:match("^[a-f0-9]+$") and #token == 32
  and session:match("^localhost%-ui%-%w[%w_.%-]*$")
  and (peer == "player1" or peer == "player2") and root ~= ""
local seen, polled = {}, {}

local function serve(channel, reader)
  if not enabled then return end
  -- No tree/world scans in ordinary play; even test file polling is <= 1 Hz.
  local now = os.time()
  if polled[channel] == now then return end
  polled[channel] = now
  local prefix = root:gsub("\\", "/") .. "/launcher/ui-test-" .. channel
  local file = io.open(prefix .. ".request.json", "rb")
  if not file then return end
  local bytes = file:read(16385); file:close()
  if not bytes or #bytes > 16384 then return end
  local ok, request = pcall(json.decode, bytes)
  if not ok or type(request) ~= "table" or request.token ~= token
      or request.session ~= session or type(request.id) ~= "string"
      or not request.id:match("^[%w%-]+$") or #request.id > 80
      or seen[channel] == request.id then return end
  seen[channel] = request.id
  local success, value = pcall(reader, request)
  local receipt = { schemaVersion = 1, id = request.id, session = session,
    peer = peer, observedAt = now, success = success,
    value = success and value or nil, error = not success and tostring(value) or nil }
  local encoded, body = pcall(json.encode, receipt)
  if not encoded then return end
  -- The game's sandbox omits os.rename/remove. A direct response write is
  -- safe here: the reader retries partial JSON and requires this unique ID.
  file = io.open(prefix .. ".response.json", "wb")
  if not file then return end
  file:write(body); file:close()
end

function M.engine(state, snapshot, world)
  pcall(serve, "world", function(request)
    assert(request.action == "observe", "observer accepts only observe")
    local public = snapshot({ allowNativeAccounts = false })
    local mutationBusy = not public.initialized or (public.deferredNetworkQueue.count or 0) > 0
      or public.deferredNetworkQueue.awaitingOrder ~= nil
    for _, key in ipairs({ "proposalConsensus", "operationConsensus" }) do
      mutationBusy = mutationBusy or (public[key].pending or 0) > 0
    end
    local busy = mutationBusy or (public.checkpointConsensus.pending or 0) > 0
    local value = { snapshot = public, busy = busy, nativeBuildCaptures = {} }
    -- Retain the already-copied click evidence without invoking any native
    -- getters or serialising the entire proposal on every observation.
    local captures = state.probes and state.probes.capture
      and state.probes.capture.proposalSnapshots or {}
    for index = math.max(1, #captures - 1), #captures do
      local captured = captures[index]
      local source = type(captured) == "table" and captured.snapshot or nil
      if type(source) == "table" and type(source.__nativeFactoryCapture) == "table" then
        local details = source.__nativeFactoryCapture
        local row = { tick = captured.tick, sourceId = captured.sourceId }
        for _, key in ipairs({ "generation", "correlation", "captureSource", "callerType",
          "factoryCallerRva", "addCallerRva", "optionFieldsKnown", "withCost", "ignoreErrors",
          "optionSource", "addedNodeCount", "addedEdgeCount", "removedNodeCount", "removedEdgeCount" }) do
          row[key] = details[key]
        end
        value.nativeBuildCaptures[#value.nativeBuildCaptures + 1] = row
      end
    end
    if not busy then
      value.native = world.nativeFingerprint(state.canonical, state.world,
        state.companies, { fullInventory = true })
      if request.terrain ~= nil then
        value.terrain = require("tpf2_mp/live_ui_terrain_observer").read(request.terrain, api)
      end
      if request.geometry ~= nil then
        assert(request.geometry == true, "geometry request must be true")
        value.geometry = require("tpf2_mp/live_ui_geometry_observer").read(state.canonical, world)
      end
    end
    -- Checkpoint-only waits do not mutate topology or vehicle membership.
    -- Preserve short native arrivals during those waits, but do not claim an
    -- agreed inventory until the checkpoint finishes. Pending gameplay still
    -- fences ALL native reads, including the private structural projection.
    if not mutationBusy then
      -- The existing structural probe discovers/binds unregistered entities.
      -- Run it on private copies: observing must never repair the tested world.
      value.structure = world.structuralSnapshot(util.deepCopy(state.canonical),
        util.deepCopy(state.world), util.deepCopy(state.companies))
      if api and api.engine and api.engine.entityExists then
        value.vehicleTelemetry, value.townPositions, value.depotUi =
          require("tpf2_mp/live_ui_vehicle_observer").read(state.canonical, api, game and game.interface)
      end
    end
    if not busy then
      -- Positive assertions must see the native object, not just its output CID.
      value.bindings = {}
      for cid, binding in pairs(state.canonical.byCanonical or {}) do
        value.bindings[cid] = { kind = binding.kind,
          exists = world.entityExists(binding.localId), metadata = binding.metadata }
      end
    end
    return value
  end)
end

function M.gui(gui)
  pcall(serve, "gui", function(request)
    return require("tpf2_mp/live_ui_tree").observe(request, gui)
  end)
end

return M
