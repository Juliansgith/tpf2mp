-- Native 3D half of the social channel (see docs/SOCIAL_CHANNEL.md). The hook
-- DLL registers three Lua globals that let the GUI state hand a remote peer's
-- planned route to the game's own builder renderer, so the other player's road,
-- rail or building appears exactly as the vanilla ghost does, terrain
-- deformation included, instead of as a flat ground ribbon.
--
-- Every global may be absent (an older hook, a hook that failed to load, or the
-- game running without it), so each one is looked up by name and called through
-- pcall. When anything is missing or refuses, this module reports that it drew
-- nothing and the runtime paints its ribbons instead.
--
-- The handshake is deliberately narrow:
--   tpf2mp_native_preview_status()          -> { available, reason, session, .. }
--   tpf2mp_native_preview_begin(peer, mode) -> bool
--   tpf2mp_native_preview_result()          -> "ok"|"error"|"pending"|"idle"
-- "keep" and "clear" execute inside begin. A "draw", "drawok" or "drawbad"
-- begin arms a one-shot request that the next scripting::Convert on the GUI
-- thread consumes, so the SimpleProposal built here is passed to
-- api.cmd.make.buildProposal purely to trigger that conversion. The resulting
-- command is discarded on the spot and is NEVER given to api.cmd.sendCommand:
-- nothing in this module may reach the authoritative match.
local preview = require "tpf2_mp/gui_social_preview"
local params = require "tpf2_mp/gui_social_params"

local M = {}

-- An unchanged preview is refreshed once a second; a refused one is not retried
-- for five seconds, so a hook without the renderer costs one status call per
-- five seconds instead of a proposal rebuild every frame.
M.KEEPALIVE_SECONDS = 1
M.RETRY_SECONDS = 5
-- The conversion runs on this thread, so a terminal result is expected on the
-- first read; the small budget only covers a hook that reports it one call late.
M.RESULT_POLLS = 8
-- A rail edge still needs a street type on its shared BaseEdgeStreet component.
M.DUMMY_STREET = "standard/town_small_new.lua"
M.PREVIEW_NAME = "Multiplayer preview"

local STRUCTURE_REP = { [1] = "bridgeTypeRep", [2] = "tunnelTypeRep" }

local drawn, failures = {}, {}
local sessionId, statusRetryAt

local function globalCall(name, ...)
  local entry = rawget(_G, name)
  if type(entry) ~= "function" then return false end
  local ok, result = pcall(entry, ...)
  if not ok then return false end
  return true, result
end

-- The hook restarts its renderer with a new session id; anything it drew for
-- the previous one is gone, so the bookkeeping starts again with it.
local function session(now)
  if statusRetryAt and now < statusRetryAt then return nil end
  local ok, report = globalCall("tpf2mp_native_preview_status")
  local id
  if ok and type(report) == "table" and report.available == true then
    id = preview.whole(report.session, 1e15)
  end
  if not id then
    statusRetryAt = now + M.RETRY_SECONDS
    drawn, failures, sessionId = {}, {}, nil
    return nil
  end
  statusRetryAt = nil
  if sessionId ~= id then drawn, failures, sessionId = {}, {}, id end
  return id
end

local function begin(peer, mode)
  local ok, accepted = globalCall("tpf2mp_native_preview_begin", peer, mode)
  return ok and accepted == true
end

-- A terminal result is reported once. Anything that is not "ok" counts as a
-- refusal, including a request the hook never consumed ("idle") and one still
-- pending after the budget: the peer falls back to ribbons and is not retried
-- until the backoff expires.
local function outcome()
  for _ = 1, M.RESULT_POLLS do
    local ok, value = globalCall("tpf2mp_native_preview_result")
    if not ok then return "error" end
    if value ~= "pending" then return value end
  end
  return "pending"
end

-- Resolve a resource NAME to this client's own index and read the name back,
-- so a stale or out-of-range index becomes a refusal, never a wrong resource.
-- Returns false when the resource is unknown here.
function M.resource(repName, name)
  if not preview.resourceName(name) then return false end
  local find = preview.repFunction(repName, "find")
  local getName = preview.repFunction(repName, "getName")
  if not find or not getName then return false end
  local okFind, index = pcall(find, name)
  if not okFind then return false end
  index = preview.whole(index, 1000000)
  if not index then return false end
  local okName, resolved = pcall(getName, index)
  if not okName or resolved ~= name then return false end
  return index
end

local function resolver()
  local cache = {}
  return function(repName, name)
    local byName = cache[repName]
    if not byName then
      byName = {}
      cache[repName] = byName
    end
    if byName[name] == nil then byName[name] = M.resource(repName, name) end
    if byName[name] == false then return nil end
    return byName[name]
  end
end

-- Ported from the prior art's previewNativeProposal: temporary negative ids,
-- nodes deduplicated by rounded position, and an abort on any unresolved
-- resource or degenerate segment. The proposal describes only the remote
-- peer's planned geometry; it is never submitted.
local function streetProposal(body)
  local rail = (body.kind == "rail")
  local proposal = api.type.SimpleProposal.new()
  local resolve = resolver()
  local keys, nodeCount = {}, 0
  local function node(x, y, z)
    local key = string.format("%.3f,%.3f,%.3f", x, y, z)
    if keys[key] then return keys[key] end
    nodeCount = nodeCount + 1
    local entry = api.type.NodeAndEntity.new()
    entry.entity = -nodeCount
    entry.comp.position = api.type.Vec3f.new(x, y, z)
    proposal.streetProposal.nodesToAdd[nodeCount] = entry
    keys[key] = entry.entity
    return entry.entity
  end
  local typeRepName = "streetTypeRep"
  if rail then typeRepName = "trackTypeRep" end
  local dummyStreet
  if rail then
    dummyStreet = resolve("streetTypeRep", M.DUMMY_STREET)
    if not dummyStreet then return nil end
  end
  for index, curve in ipairs(body.curves) do
    local detail = body.details[index]
    local dx, dy, dz = curve[3] - curve[1], curve[4] - curve[2], detail[2] - detail[1]
    local span = dx * dx + dy * dy + dz * dz
    if span < 0.0001 or span > 100000000 then return nil end
    if curve[5] ^ 2 + curve[6] ^ 2 + detail[3] ^ 2 < 0.0001 then return nil end
    if curve[7] ^ 2 + curve[8] ^ 2 + detail[4] ^ 2 < 0.0001 then return nil end
    local resourceIndex = resolve(typeRepName, detail[6])
    if not resourceIndex then return nil end
    local structure = -1
    if detail[5] > 0 then
      structure = resolve(STRUCTURE_REP[detail[5]], detail[10])
      if not structure then return nil end
    end
    local segment = api.type.SegmentAndEntity.new()
    segment.entity = -100 - index
    segment.comp.node0 = node(curve[1], curve[2], detail[1])
    segment.comp.node1 = node(curve[3], curve[4], detail[2])
    segment.comp.tangent0 = api.type.Vec3f.new(curve[5], curve[6], detail[3])
    segment.comp.tangent1 = api.type.Vec3f.new(curve[7], curve[8], detail[4])
    segment.comp.type, segment.comp.typeIndex = detail[5], structure
    segment.type = 0
    segment.streetEdge = api.type.BaseEdgeStreet.new()
    if rail then
      segment.type = 1
      segment.streetEdge.streetType = dummyStreet
      segment.trackEdge = api.type.BaseEdgeTrack.new()
      segment.trackEdge.trackType = resourceIndex
      segment.trackEdge.catenary = detail[9] == 1
    else
      segment.streetEdge.streetType = resourceIndex
      segment.streetEdge.hasBus = detail[7] == 1
      segment.streetEdge.tramTrackType = detail[8]
    end
    proposal.streetProposal.edgesToAdd[index] = segment
  end
  return proposal
end

-- Ported from the prior art's previewNativeConstruction. The parameter set is
-- rebuilt from the wire string by the typed codec, so nothing the other peer
-- sent is ever executed as Lua.
local function constructionProposal(body)
  local decoded = params.decode(body.params)
  if type(decoded) ~= "table" then return nil end
  if M.resource("constructionRep", body.file) == false then return nil end
  local proposal = api.type.SimpleProposal.new()
  local entity = api.type.SimpleProposal.ConstructionEntity.new()
  local transf = body.transf
  entity.fileName, entity.params = body.file, decoded
  entity.transf = api.type.Mat4f.new(
    api.type.Vec4f.new(transf[1], transf[2], transf[3], transf[4]),
    api.type.Vec4f.new(transf[5], transf[6], transf[7], transf[8]),
    api.type.Vec4f.new(transf[9], transf[10], transf[11], transf[12]),
    api.type.Vec4f.new(transf[13], transf[14], transf[15], transf[16]))
  entity.playerEntity = api.engine.util.getPlayer()
  entity.name = M.PREVIEW_NAME
  proposal.constructionsToAdd[1] = entity
  return proposal
end

function M.proposal(body)
  if type(body) ~= "table" then return nil end
  if body.kind == "construction" then return constructionProposal(body) end
  if body.kind ~= "road" and body.kind ~= "rail" then return nil end
  return streetProposal(body)
end

-- Only a preview carrying the optional 3D contract can be rendered natively.
function M.renderable(body)
  if type(body) ~= "table" then return false end
  if body.kind == "road" or body.kind == "rail" then
    return type(body.details) == "table" and type(body.curves) == "table"
      and #body.details == #body.curves
  end
  if body.kind == "construction" then return type(body.params) == "string" end
  return false
end

local function draw(peer, body)
  local ok, proposal = pcall(M.proposal, body)
  if not ok or proposal == nil then return false end
  local make = api and api.cmd and api.cmd.make
  -- api.cmd.make and its factories are bound as callable userdata in the game
  -- and as plain tables/functions in the test fakes; accept both.
  local makeType = type(make)
  if makeType ~= "table" and makeType ~= "userdata" then return false end
  local factoryType = type(make.buildProposal)
  if factoryType ~= "function" and factoryType ~= "userdata" and factoryType ~= "table" then
    return false
  end
  local mode = "draw"
  if body.invalid == true then
    mode = "drawbad"
  elseif body.invalid == false then
    mode = "drawok"
  end
  -- Arm last, immediately before the conversion that consumes the request, so
  -- an unbuildable proposal never leaves a request waiting for someone else's
  -- conversion. Conversion only: the command is dropped, never sent.
  if not begin(peer, mode) then return false end
  if not pcall(make.buildProposal, proposal, nil, false) then return false end
  return outcome() == "ok"
end

-- Hands every renderable remote preview to the native renderer and returns the
-- set of peers it is currently drawing; the runtime draws ribbons for the rest.
-- `remote` is the runtime's live table of peer -> { body, signature, at }.
function M.sync(remote, now)
  local live = {}
  if type(remote) ~= "table" then return live end
  -- An idle channel costs nothing at all: without a live preview and without
  -- anything left on screen there is no reason to even ask for the status.
  if next(remote) == nil and next(drawn) == nil then return live end
  if not session(now) then return live end
  local previous = drawn
  drawn = {}
  for peer, entry in pairs(remote) do
    local body = entry.body
    if M.renderable(body) then
      local old = previous[peer]
      if old and old.signature == entry.signature then
        local at, kept = old.at, true
        if now - at >= M.KEEPALIVE_SECONDS then
          kept, at = begin(peer, "keep"), now
        end
        if kept then
          drawn[peer], live[peer] = { signature = entry.signature, at = at }, true
        else
          failures[peer] = now
        end
      elseif not failures[peer] or now - failures[peer] >= M.RETRY_SECONDS then
        if draw(peer, body) then
          drawn[peer], live[peer] = { signature = entry.signature, at = now }, true
          failures[peer] = nil
        else
          failures[peer] = now
        end
      end
    end
  end
  for peer in pairs(previous) do
    if not drawn[peer] then begin(peer, "clear") end
  end
  return live
end

-- Takes down everything the renderer still holds for this state: the channel
-- going inert, the bridge root changing, or the panel shutting down.
function M.clearAll()
  for peer in pairs(drawn) do begin(peer, "clear") end
  drawn, failures = {}, {}
  sessionId, statusRetryAt = nil, nil
end

return M
