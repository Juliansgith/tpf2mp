local proposalCodec = require "tpf2_mp/proposal_codec"

local M = {}

local function finite(value)
  value = tonumber(value)
  return value and value == value and value ~= math.huge and value ~= -math.huge
end

function M.transaction(x, y, companyCid, deps)
  deps = deps or {}
  x, y = tonumber(x), tonumber(y)
  if not finite(x) or not finite(y) then return nil, "station coordinates are invalid" end
  local height = deps.height or function(px, py)
    local ok, value = pcall(game.interface.getHeight, { px, py })
    return ok and tonumber(value) or nil
  end
  local z = height(x, y)
  if not finite(z) then return nil, "station terrain height is unavailable" end
  local trackType = deps.trackType
  if trackType == nil and api and api.res and api.res.trackTypeRep then
    local ok, value = pcall(api.res.trackTypeRep.find, "standard.lua")
    if ok then trackType = tonumber(value) end
  end
  if not finite(trackType) or trackType < 0 then
    return nil, "standard station track resource is unavailable"
  end
  local nativePlayerId = tonumber(deps.nativePlayerId)
    or (game and game.interface and tonumber(game.interface.getPlayer()))
  if not nativePlayerId or nativePlayerId < 0 then
    return nil, "station native player is unavailable"
  end
  local nodes, edges = {}, {}
  local offsets = { -18, -20, -2, 0, 2, 18, 20, 22, 38, 40, 42, 58, 60 }
  for index, offset in ipairs(offsets) do
    nodes[index] = {
      entity = -index,
      comp = { position = { x = x + 5, y = y + offset, z = z } },
    }
  end
  local paths = {
    { 1, 2, -2 }, { 3, 1, -16 }, { 4, 3, -2 },
    { 4, 5, 2 }, { 5, 6, 16 }, { 6, 7, 2 },
    { 8, 7, -2 }, { 9, 8, -16 }, { 10, 9, -2 },
    { 10, 11, 2 }, { 11, 12, 16 }, { 12, 13, 2 },
  }
  for index, path in ipairs(paths) do
    edges[index] = {
      entity = -(13 + index), type = 1,
      comp = {
        node0 = nodes[path[1]].entity, node1 = nodes[path[2]].entity,
        tangent0 = { x = 0, y = path[3], z = 0 },
        tangent1 = { x = 0, y = path[3], z = 0 },
        type = 0, typeIndex = -1,
      },
      trackEdge = { trackType = trackType, catenary = false },
      playerOwned = { player = nativePlayerId },
    }
  end
  local prefix = "station/rail/modular_station/"
  local raw = {
    __observedCost = 121073,
    proposal = {
      addedNodes = nodes, addedSegments = edges,
      edgesToRemove = {}, nodesToRemove = {}, edgeObjectsToAdd = {}, edgeObjectsToRemove = {},
    },
    __constructionAdditions = {{
      fileName = prefix .. "modular_station.con",
      transf = { 1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1, 0, x, y, z, 1 },
      params = {
        year = 1990, seed = 2, trackType = 0, catenary = 0,
        length = 0, tracks = 0, paramX = 0, paramY = 0,
        modules = {
          [3700000] = { name = prefix .. "main_building_1_era_c.module", variant = 0 },
          [7400000] = { name = prefix .. "platform_passenger_era_c.module", variant = 0 },
          [7400010] = { name = prefix .. "platform_passenger_era_c.module", variant = 0 },
          [8401000] = { name = prefix .. "platform_track.module", variant = 0 },
          [8401010] = { name = prefix .. "platform_track.module", variant = 0 },
          [10400000] = { name = prefix .. "platform_passenger_roof_era_c.module", variant = 0 },
          [10400010] = { name = prefix .. "platform_passenger_roof_era_c.module", variant = 0 },
          [10800000] = { name = prefix .. "addon_platform_passenger_stairs_era_c.module", variant = 0 },
        },
      },
    }},
    __constructionRemovals = {},
  }
  return proposalCodec.normalise(raw, companyCid, {
    resourceName = deps.resourceName,
  })
end

function M.new(deps)
  local getState = assert(deps.getState, "station validation state is required")
  local transition = assert(deps.transition, "station validation transition is required")
  local check = assert(deps.check, "station validation check is required")
  local submit = assert(deps.submit, "station validation submit is required")
  local checkpoint = assert(deps.checkpoint, "station validation checkpoint is required")
  local finish = assert(deps.finish, "station validation finish is required")

  local function begin()
    local state = getState()
    if state.bridge.peerId == "player1" then
      local transaction, transactionError = M.transaction(-1400, -1400, "company:1", {
        resourceName = deps.resourceName,
      })
      check("network-station-transaction-normalised", transaction ~= nil, {
        error = transactionError, digest = transaction and transaction.digest or nil,
      })
      local result = submit({ type = "proposal.prepare", transaction = transaction },
        "host-origin-exact-station-queued")
      state.validation.values.stationProposalLocalSeq = result and result.local_seq
    end
    transition("wait-for-station-proposal-consensus")
  end

  local function maintain(stage)
    local state = getState()
    if stage == "wait-for-station-proposal-consensus" then
      local consensus = state.world.proposalConsensus
      if (consensus.completed or 0) < 3 then return true end
      local outcome = consensus.lastOutcome
      local record = outcome and state.world.proposals.byId[outcome.proposalId] or nil
      local result = record and record.result or nil
      check("exact-station-physical-consensus", outcome and outcome.success == true, outcome)
      check("exact-station-used-gui-build-proposal", result
        and result.constructionReplayPath == "gui-build-proposal", result)
      check("exact-station-bound-complete-graph", result and #(result.outputs or {}) == 28, result)
      state.validation.values.stationProposalId = outcome and outcome.proposalId or nil
      transition("wait-for-station-proposal-checkpoint")
      return true
    end
    if stage == "wait-for-station-proposal-checkpoint" then
      local wantedProposalId = state.validation.values.stationProposalId
      local agreed = checkpoint(function(record)
        return wantedProposalId ~= nil
          and tostring(record.proposalId or "") == tostring(wantedProposalId)
      end)
      if not agreed then return true end
      check("exact-station-post-proposal-checkpoint-consensus", agreed.success == true, agreed)
      finish(agreed.boundarySeq)
      return true
    end
    return false
  end

  return { begin = begin, maintain = maintain }
end

return M
