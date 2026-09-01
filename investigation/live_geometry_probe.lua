-- Disposable-world native construction geometry stress probe.
--
-- This module is copied into the temporary base-resource validation overlay;
-- it is not shipped with the playable mod.  The ordinary codec/replay suite
-- proves deterministic wire handling.  This probe asks Build 35924 itself to
-- accept and retire practical geometry: long/curved/graded rail, structures,
-- a public-road crossing, collateral demolition, a station on uneven terrain,
-- and a rejected command followed by a valid command.
local json = require "tpf2_mp/json"
local removalVector = require "tpf2_mp/construction_removal_vector"

local M = {}

local function callable(value)
  local kind = type(value)
  return kind == "function" or kind == "table" or kind == "userdata"
end

local function marker(event, values)
  local payload = { event = event }
  for key, value in pairs(values or {}) do payload[key] = value end
  local ok, encoded = pcall(json.encode, payload)
  print("[TPF2MP-CONSOLE-PROBE] " .. (ok and encoded or tostring(event)))
end

local function micros()
  local native = rawget(_G, "tpf2mp_native_monotonic_us")
  if callable(native) then
    local ok, value = pcall(native)
    if ok and tonumber(value) then return tonumber(value) end
  end
  return os and os.clock and os.clock() * 1000000 or 0
end

local function commandFactory(name)
  local public = api and api.cmd and api.cmd.make and api.cmd.make[name]
  if callable(public) then return public, "public" end
  local mirrored = rawget(_G, "tpf2mp_native_binding_" .. tostring(name))
  if callable(mirrored) then return mirrored, "native-mirror" end
  return nil, "unavailable"
end

local function terrainHeight(x, y)
  local position = api and api.type and api.type.Vec2f and api.type.Vec2f.new(x, y)
  if position and api.engine and api.engine.terrain
    and callable(api.engine.terrain.getHeightAt) then
    local ok, value = pcall(api.engine.terrain.getHeightAt, position)
    if ok and tonumber(value) then return tonumber(value) end
  end
  if game and game.interface and callable(game.interface.getHeight) then
    for _, candidate in ipairs({ { x = x, y = y }, { x, y } }) do
      local ok, value = pcall(game.interface.getHeight, candidate)
      if ok and tonumber(value) then return tonumber(value) end
    end
  end
  return nil
end

local function validCoordinate(x, y)
  local terrain = api and api.engine and api.engine.terrain
  if not (terrain and callable(terrain.isValidCoordinate)
    and api.type and api.type.Vec2f) then return terrainHeight(x, y) ~= nil end
  local ok, value = pcall(terrain.isValidCoordinate, api.type.Vec2f.new(x, y))
  return ok and value == true
end

local componentNames = {
  track = "BASE_EDGE_TRACK",
  street = "BASE_EDGE_STREET",
  node = "BASE_NODE",
  construction = "CONSTRUCTION",
  station = "STATION",
  stationGroup = "STATION_GROUP",
}

local function componentSet(componentName)
  local componentType = api and api.type and api.type.ComponentType
  local resolved = componentType and componentType[componentName]
  if not resolved or not (api.engine and callable(api.engine.forEachEntityWithComponent)) then
    return nil, "component is unavailable: " .. tostring(componentName)
  end
  local result = {}
  local ok, err = pcall(api.engine.forEachEntityWithComponent, function(entity)
    entity = tonumber(entity)
    if entity and entity >= 0 then result[entity] = true end
  end, resolved)
  if not ok then return nil, tostring(err) end
  return result
end

local function snapshot()
  local result = {}
  for name, componentName in pairs(componentNames) do
    local values, err = componentSet(componentName)
    if not values then return nil, err end
    result[name] = values
  end
  return result
end

local function difference(after, before)
  local result = {}
  for name in pairs(componentNames) do
    result[name] = {}
    for entity in pairs(after[name] or {}) do
      if not (before[name] or {})[entity] then result[name][#result[name] + 1] = entity end
    end
    table.sort(result[name])
  end
  return result
end

local function contains(set, entity)
  return type(set) == "table" and set[tonumber(entity)] == true
end

local function ownerOf(entity)
  local componentType = api.type.ComponentType
  if not componentType.PLAYER_OWNED then return nil end
  local ok, value = pcall(api.engine.getComponent, entity, componentType.PLAYER_OWNED)
  if not ok or not value then return nil end
  local playerOk, player = pcall(function() return value.player or value.playerEntity end)
  return playerOk and tonumber(player) or nil
end

local function component(entity, name)
  local resolved = api.type.ComponentType[name]
  if not resolved then return nil end
  local ok, value = pcall(api.engine.getComponent, entity, resolved)
  return ok and value or nil
end

local function vector(value)
  if value == nil then return nil end
  local ok, x, y, z = pcall(function()
    return tonumber(value.x or value[1]), tonumber(value.y or value[2]),
      tonumber(value.z or value[3])
  end)
  if not ok or x == nil or y == nil then return nil end
  return { x = x, y = y, z = z or 0 }
end

local function nodePosition(entity)
  local value = component(entity, "BASE_NODE")
  if not value then return nil end
  local ok, position = pcall(function() return value.position end)
  return ok and vector(position) or nil
end

local function baseEdgeDetails(ids)
  local result = {}
  for _, entity in ipairs(ids or {}) do
    local base = component(entity, "BASE_EDGE")
    if base then
      local ok, node0, node1, edgeType, typeIndex = pcall(function()
        return tonumber(base.node0), tonumber(base.node1), tonumber(base.type),
          tonumber(base.typeIndex)
      end)
      result[#result + 1] = {
        entity = entity,
        node0 = ok and node0 or nil,
        node1 = ok and node1 or nil,
        type = ok and edgeType or nil,
        typeIndex = ok and typeIndex or nil,
        owner = ownerOf(entity),
      }
    end
  end
  return result
end

local function resultIds(result)
  local ids = {}
  if type(result) ~= "table" and type(result) ~= "userdata" then return ids end
  local ok, values = pcall(function() return result.resultEntities or result.entities end)
  if not ok or values == nil then return ids end
  local lengthOk, length = pcall(function() return #values end)
  if not lengthOk then return ids end
  for index = 1, tonumber(length) or 0 do
    local itemOk, value = pcall(function() return values[index] end)
    if itemOk and tonumber(value) then ids[#ids + 1] = tonumber(value) end
  end
  return ids
end

local function sendProposal(proposal, ignoreErrors, callback)
  local factory, source = commandFactory("buildProposal")
  if not factory or not (api and api.cmd and callable(api.cmd.sendCommand)) then
    callback(false, nil, "BuildProposal command API is unavailable", source)
    return
  end
  local commandOk, command = pcall(factory, proposal, nil, ignoreErrors == true)
  if not commandOk then callback(false, nil, tostring(command), source); return end
  local sentOk, sentError = pcall(api.cmd.sendCommand, command, function(result, success)
    local commandError
    if success ~= true then commandError = "native BuildProposal rejected" end
    callback(success == true, result, commandError, source)
  end)
  if not sentOk then callback(false, nil, tostring(sentError), source) end
end

local function sendAction(action, callback)
  local factory, source = commandFactory("sendScriptEvent")
  if not factory or not (api and api.cmd and callable(api.cmd.sendCommand)) then
    callback(false, nil, "sendScriptEvent command API is unavailable", source)
    return
  end
  local commandOk, command = pcall(factory, "tpf2_mp.lua", "tpf2mp", "intent", action)
  if not commandOk then callback(false, nil, tostring(command), source); return end
  local sentOk, sentError = pcall(api.cmd.sendCommand, command, function(result, success)
    local commandError
    if success ~= true then commandError = "script event command failed" end
    callback(success == true, result, commandError, source)
  end)
  if not sentOk then callback(false, nil, tostring(sentError), source) end
end

local function resource(repository, name)
  if not (repository and callable(repository.find)) then return nil end
  local ok, value = pcall(repository.find, name)
  value = ok and tonumber(value) or nil
  return value and value >= 0 and value or nil
end

local function point(x, y, z)
  z = z == nil and terrainHeight(x, y) or z
  if z == nil or not validCoordinate(x, y) then return nil end
  return { x = x, y = y, z = z }
end

local function chord(left, right)
  return { x = right.x - left.x, y = right.y - left.y, z = right.z - left.z }
end

local function tangentAt(points, index, chordLength)
  local direction
  if index == 1 then direction = chord(points[1], points[2])
  elseif index == #points then direction = chord(points[#points - 1], points[#points])
  else direction = chord(points[index - 1], points[index + 1]) end
  local horizontal = math.sqrt(direction.x * direction.x + direction.y * direction.y)
  if horizontal <= 0.0001 then return { x = chordLength, y = 0, z = 0 } end
  local scale = chordLength / horizontal
  return { x = direction.x * scale, y = direction.y * scale, z = direction.z * scale }
end

local function makeTrackProposal(points, options)
  options = options or {}
  if type(points) ~= "table" or #points < 2 then return nil, "track requires at least two points" end
  local trackType = resource(api.res and api.res.trackTypeRep, options.trackType or "standard.lua")
  if trackType == nil then return nil, "track resource is unavailable" end
  local proposal = api.type.SimpleProposal.new()
  local player = tonumber(game.interface.getPlayer())
  for index, value in ipairs(points) do
    local node = api.type.NodeAndEntity.new()
    node.entity = -(#points + index + 16)
    node.comp.position = api.type.Vec3f.new(value.x, value.y, value.z)
    proposal.streetProposal.nodesToAdd[index] = node
  end
  for index = 1, #points - 1 do
    local left, right = points[index], points[index + 1]
    local delta = chord(left, right)
    local length = math.sqrt(delta.x * delta.x + delta.y * delta.y)
    local edge = api.type.SegmentAndEntity.new()
    edge.entity = -index
    edge.comp.node0 = -(#points + index + 16)
    edge.comp.node1 = -(#points + index + 17)
    local tangent0 = options.curved and tangentAt(points, index, length) or delta
    local tangent1 = options.curved and tangentAt(points, index + 1, length) or delta
    edge.comp.tangent0 = api.type.Vec3f.new(tangent0.x, tangent0.y, tangent0.z)
    edge.comp.tangent1 = api.type.Vec3f.new(tangent1.x, tangent1.y, tangent1.z)
    edge.comp.type = type(options.edgeTypes) == "table" and options.edgeTypes[index]
      or tonumber(options.edgeType) or 0
    edge.comp.typeIndex = type(options.typeIndices) == "table" and options.typeIndices[index]
      or tonumber(options.typeIndex) or -1
    edge.type = 1
    edge.trackEdge = api.type.BaseEdgeTrack.new()
    edge.trackEdge.trackType = trackType
    edge.trackEdge.catenary = options.catenary == true
    edge.playerOwned = api.type.PlayerOwned.new()
    edge.playerOwned.player = player
    proposal.streetProposal.edgesToAdd[index] = edge
  end
  return proposal
end

local function makeStreetProposal(first, second)
  local streetType = resource(api.res and api.res.streetTypeRep, "standard/country_small_new.lua")
  if streetType == nil then return nil, "street resource is unavailable" end
  local proposal = api.type.SimpleProposal.new()
  local edge = api.type.SegmentAndEntity.new()
  edge.entity = -1
  edge.comp.node0, edge.comp.node1 = -2, -3
  local delta = chord(first, second)
  edge.comp.tangent0 = api.type.Vec3f.new(delta.x, delta.y, delta.z)
  edge.comp.tangent1 = api.type.Vec3f.new(delta.x, delta.y, delta.z)
  edge.comp.type, edge.comp.typeIndex, edge.type = 0, -1, 0
  edge.streetEdge = api.type.BaseEdgeStreet.new()
  edge.streetEdge.streetType = streetType
  local node0, node1 = api.type.NodeAndEntity.new(), api.type.NodeAndEntity.new()
  node0.entity, node1.entity = -2, -3
  node0.comp.position = api.type.Vec3f.new(first.x, first.y, first.z)
  node1.comp.position = api.type.Vec3f.new(second.x, second.y, second.z)
  proposal.streetProposal.edgesToAdd[1] = edge
  proposal.streetProposal.nodesToAdd[1] = node0
  proposal.streetProposal.nodesToAdd[2] = node1
  return proposal
end

local function removalProposal(edges, nodes, constructions)
  local proposal = api.type.SimpleProposal.new()
  for index, entity in ipairs(edges or {}) do proposal.streetProposal.edgesToRemove[index] = entity end
  for index, entity in ipairs(nodes or {}) do proposal.streetProposal.nodesToRemove[index] = entity end
  if constructions and #constructions > 0 then
    local field, values = removalVector.read(proposal)
    local assigned, err = removalVector.assign(proposal, field, values, constructions)
    if not assigned then return nil, err end
  end
  return proposal
end

local function cleanupDelta(baseline, callback)
  local current, currentError = snapshot()
  if not current then callback(false, currentError); return end
  local delta = difference(current, baseline)
  local roots = delta.construction or {}
  if #roots > 0 then
    -- Construction bulldoze is the safest retirement route for a compound
    -- station. The caller handles those explicitly; topology cases must not
    -- leak a construction root into this generic cleanup.
    callback(false, "generic topology cleanup encountered a construction root")
    return
  end
  local edges = {}
  for _, entity in ipairs(delta.track or {}) do edges[#edges + 1] = entity end
  for _, entity in ipairs(delta.street or {}) do edges[#edges + 1] = entity end
  table.sort(edges)
  local proposal, proposalError = removalProposal(edges, delta.node or {})
  if not proposal then callback(false, proposalError); return end
  if #edges == 0 and #(delta.node or {}) == 0 then callback(true, nil); return end
  sendProposal(proposal, true, function(_, _, commandError)
    local after, afterError = snapshot()
    if not after then callback(false, afterError or commandError); return end
    local remaining = difference(after, baseline)
    local clean = #(remaining.track or {}) == 0 and #(remaining.street or {}) == 0
      and #(remaining.node or {}) == 0
    if clean then callback(true, nil)
    else callback(false, commandError or "topology cleanup was incomplete") end
  end)
end

local corridorBases = {
  { -1700, -1550 }, { -1700, 1450 }, { -1550, -1150 }, { -1550, 950 },
  { -1300, -1500 }, { -1300, 1250 }, { -1050, -1350 }, { -1050, 1050 },
  { -800, -1500 }, { -800, 1350 }, { 400, -1550 }, { 400, 1350 },
}

local function pointsFor(spec, base)
  local points = {}
  local count, spacing = spec.nodes or 9, spec.spacing or 110
  local sampled = {}
  for index = 1, count do
    local x = base[1] + (index - 1) * spacing
    local y = base[2]
    if spec.curve then y = y + math.sin((index - 1) / (count - 1) * math.pi) * 180 end
    local z = terrainHeight(x, y)
    if z == nil or not validCoordinate(x, y) then return nil, "coordinate outside map" end
    sampled[index] = { x = x, y = y, terrain = z }
  end
  for index, value in ipairs(sampled) do
    local z = value.terrain
    if spec.transition and spec.structure then
      local fraction = (index - 1) / (count - 1)
      local ramp = math.min(1, fraction * 2, (1 - fraction) * 2)
      local firstTerrain = sampled[1].terrain
      local lastTerrain = sampled[#sampled].terrain
      local groundLine = firstTerrain + (lastTerrain - firstTerrain) * fraction
      local structureLevel
      if spec.structure == "bridge" then
        structureLevel = -math.huge
        for _, sample in ipairs(sampled) do
          structureLevel = math.max(structureLevel, sample.terrain)
        end
        structureLevel = structureLevel + (spec.structureClearance or 12)
      else
        structureLevel = math.huge
        for _, sample in ipairs(sampled) do
          structureLevel = math.min(structureLevel, sample.terrain)
        end
        structureLevel = structureLevel - (spec.structureClearance or 12)
      end
      z = groundLine + (structureLevel - groundLine) * ramp
    end
    points[index] = { x = value.x, y = value.y, z = z }
  end
  return points
end

local function pointMetrics(points)
  local total, minZ, maxZ, maxGrade = 0, math.huge, -math.huge, 0
  for index, value in ipairs(points or {}) do
    minZ, maxZ = math.min(minZ, value.z), math.max(maxZ, value.z)
    if index > 1 then
      local delta = chord(points[index - 1], value)
      local horizontal = math.sqrt(delta.x * delta.x + delta.y * delta.y)
      total = total + horizontal
      if horizontal > 0 then maxGrade = math.max(maxGrade, math.abs(delta.z) / horizontal) end
    end
  end
  return { length = total, minZ = minZ, maxZ = maxZ, zSpan = maxZ - minZ, maxGrade = maxGrade }
end

local function verifyTrackDelta(spec, points, delta)
  local details = baseEdgeDetails(delta.track)
  local player = tonumber(game.interface.getPlayer())
  local expectedEdges = #points - 1
  local ownerOk, allConsoleUnowned = #details == expectedEdges, #details == expectedEdges
  local typeOk = #details == expectedEdges
  for index, detail in ipairs(details) do
    if tonumber(detail.owner) ~= player then ownerOk = false end
    if tonumber(detail.owner) ~= -1 then allConsoleUnowned = false end
    local expectedType = spec.edgeTypes and spec.edgeTypes[index] or spec.edgeType or 0
    local expectedIndex = spec.typeIndices and spec.typeIndices[index] or spec.typeIndex or -1
    if detail.type ~= expectedType or detail.typeIndex ~= expectedIndex then typeOk = false end
  end
  local shapeOk = #(delta.track or {}) == expectedEdges and #(delta.node or {}) == #points
    and #(delta.street or {}) == 0
  local ownershipAcceptable = ownerOk or allConsoleUnowned
  return shapeOk and ownershipAcceptable and typeOk, {
    expectedEdges = expectedEdges,
    createdTracks = delta.track,
    createdNodes = delta.node,
    details = details,
    shapeVerified = shapeOk,
    ownershipVerified = ownerOk,
    ownershipObserved = not allConsoleUnowned,
    ownershipAcceptable = ownershipAcceptable,
    ownershipLimit = allConsoleUnowned
      and "direct console-origin BuildProposal edges are native-unowned; GUI ownership is covered by pinned capture evidence"
      or nil,
    structureVerified = typeOk,
    metrics = pointMetrics(points),
  }
end

local function runTrackCase(spec, candidateIndex, results, completed)
  if candidateIndex > #corridorBases then
    results[#results + 1] = { kind = spec.kind, success = false,
      error = "no clear geometry candidate succeeded" }
    completed(false)
    return
  end
  local points, pointError = pointsFor(spec, corridorBases[candidateIndex])
  if not points then runTrackCase(spec, candidateIndex + 1, results, completed); return end
  local candidateMetrics = pointMetrics(points)
  if (spec.minimumZSpan and candidateMetrics.zSpan < spec.minimumZSpan)
    or (spec.maximumGrade and candidateMetrics.maxGrade > spec.maximumGrade) then
    marker("geometry-stress-attempt", {
      kind = spec.kind, candidate = candidateIndex, skipped = true,
      error = spec.minimumZSpan and candidateMetrics.zSpan < spec.minimumZSpan
        and "terrain is too flat for the grade case" or "terrain exceeds the grade case limit",
      metrics = candidateMetrics,
    })
    runTrackCase(spec, candidateIndex + 1, results, completed)
    return
  end
  local baseline, baselineError = snapshot()
  if not baseline then
    results[#results + 1] = { kind = spec.kind, success = false, error = baselineError }
    completed(false); return
  end
  local proposal, proposalError = makeTrackProposal(points, spec)
  if not proposal then
    results[#results + 1] = { kind = spec.kind, success = false, error = proposalError or pointError }
    completed(false); return
  end
  local started = micros()
  sendProposal(proposal, false, function(commandSuccess, commandResult, commandError, source)
    local after, afterError = snapshot()
    local delta = after and difference(after, baseline) or {}
    local verified, details = false, {}
    if after then verified, details = verifyTrackDelta(spec, points, delta) end
    if after and not verified and (#(delta.track or {}) > 0 or #(delta.node or {}) > 0) then
      cleanupDelta(baseline, function(cleaned, cleanupError)
        local entry = { kind = spec.kind, success = false, candidate = candidateIndex,
          commandSuccess = commandSuccess, elapsedUs = math.max(0, micros() - started),
          commandSource = source, resultIds = resultIds(commandResult), delta = delta,
          cleanupVerified = cleaned, error = afterError or commandError or cleanupError,
          details = details }
        results[#results + 1] = entry
        marker("geometry-stress-result", entry)
        completed(false)
      end)
      return
    end
    if not (commandSuccess and after and verified) then
      marker("geometry-stress-attempt", { kind = spec.kind, candidate = candidateIndex,
        commandSuccess = commandSuccess, elapsedUs = math.max(0, micros() - started),
        delta = delta, error = afterError or commandError, details = details })
      runTrackCase(spec, candidateIndex + 1, results, completed)
      return
    end
    cleanupDelta(baseline, function(cleaned, cleanupError)
      local entry = { kind = spec.kind, success = cleaned == true,
        candidate = candidateIndex, commandSuccess = true,
        elapsedUs = math.max(0, micros() - started), commandSource = source,
        resultIds = resultIds(commandResult), delta = delta, details = details,
        cleanupVerified = cleaned == true, error = cleanupError }
      results[#results + 1] = entry
      marker("geometry-stress-result", entry)
      completed(entry.success)
    end)
  end)
end

local function makeCrossingProposal(roadEntity, constructions)
  local base = component(roadEntity, "BASE_EDGE")
  local street = component(roadEntity, "BASE_EDGE_STREET")
  if not base or not street then return nil, "source road components are unavailable" end
  local ok, firstId, secondId, streetType = pcall(function()
    return tonumber(base.node0), tonumber(base.node1), tonumber(street.streetType)
  end)
  if not ok or not firstId or not secondId or not streetType then
    return nil, "source road fields are unavailable"
  end
  local first, second = nodePosition(firstId), nodePosition(secondId)
  if not first or not second then return nil, "source road nodes are unreadable" end
  local center = { x = (first.x + second.x) / 2, y = (first.y + second.y) / 2,
    z = (first.z + second.z) / 2 }
  local left = point(center.x - 130, center.y, center.z)
  local right = point(center.x + 130, center.y, center.z)
  if not left or not right then return nil, "crossing rail endpoints are invalid" end
  left.z, right.z = center.z, center.z
  local proposal = api.type.SimpleProposal.new()
  local nodes = { center, left, right }
  for index, value in ipairs(nodes) do
    local node = api.type.NodeAndEntity.new()
    node.entity = -(index + 4)
    node.comp.position = api.type.Vec3f.new(value.x, value.y, value.z)
    proposal.streetProposal.nodesToAdd[index] = node
  end
  local function addEdge(index, node0, node1, p0, p1, carrier)
    local edge = api.type.SegmentAndEntity.new()
    edge.entity = -index
    edge.comp.node0, edge.comp.node1 = node0, node1
    local delta = chord(p0, p1)
    edge.comp.tangent0 = api.type.Vec3f.new(delta.x, delta.y, delta.z)
    edge.comp.tangent1 = api.type.Vec3f.new(delta.x, delta.y, delta.z)
    edge.comp.type, edge.comp.typeIndex = 0, -1
    if carrier == "street" then
      edge.type = 0
      edge.streetEdge = api.type.BaseEdgeStreet.new()
      edge.streetEdge.streetType = streetType
    else
      edge.type = 1
      edge.trackEdge = api.type.BaseEdgeTrack.new()
      edge.trackEdge.trackType = resource(api.res.trackTypeRep, "standard.lua")
      edge.trackEdge.catenary = false
      edge.playerOwned = api.type.PlayerOwned.new()
      edge.playerOwned.player = game.interface.getPlayer()
    end
    proposal.streetProposal.edgesToAdd[index] = edge
  end
  addEdge(1, firstId, -5, first, center, "street")
  addEdge(2, -5, secondId, center, second, "street")
  addEdge(3, -6, -5, left, center, "track")
  addEdge(4, -5, -7, center, right, "track")
  proposal.streetProposal.edgesToRemove[1] = roadEntity
  if constructions and #constructions > 0 then
    local field, values = removalVector.read(proposal)
    local assigned, assignError = removalVector.assign(
      proposal, field, values, constructions)
    if not assigned then return nil, assignError end
  end
  return proposal
end

local function runCrossingCase(candidateIndex, results, completed)
  local base = corridorBases[candidateIndex]
  if not base then
    local entry = { kind = "track-crosses-public-road", success = false,
      error = "no clear crossing candidate succeeded" }
    results[#results + 1] = entry; marker("geometry-stress-result", entry); completed(false); return
  end
  local first = point(base[1] + 480, base[2] - 150)
  local second = point(base[1] + 480, base[2] + 150)
  if not first or not second then runCrossingCase(candidateIndex + 1, results, completed); return end
  local baseline, baselineError = snapshot()
  if not baseline then completed(false); return end
  local roadProposal = makeStreetProposal(first, second)
  local started = micros()
  sendProposal(roadProposal, false, function(roadSuccess, _, roadError)
    local roadWorld = snapshot()
    local roadDelta = roadWorld and difference(roadWorld, baseline) or {}
    if not roadSuccess or not roadWorld or #(roadDelta.street or {}) ~= 1 then
      if roadWorld then
        cleanupDelta(baseline, function() runCrossingCase(candidateIndex + 1, results, completed) end)
      else runCrossingCase(candidateIndex + 1, results, completed) end
      return
    end
    local roadEntity = roadDelta.street[1]
    local crossing, crossingError = makeCrossingProposal(roadEntity)
    if not crossing then
      cleanupDelta(baseline, function()
        local entry = { kind = "track-crosses-public-road", success = false,
          error = crossingError }
        results[#results + 1] = entry; marker("geometry-stress-result", entry); completed(false)
      end)
      return
    end
    sendProposal(crossing, false, function(crossingSuccess, commandResult, commandError)
      local after, afterError = snapshot()
      local afterRoad = after and difference(after, roadWorld) or {}
      local totalDelta = after and difference(after, baseline) or {}
      local trackDetails = baseEdgeDetails(afterRoad.track or {})
      local streetDetails = baseEdgeDetails(afterRoad.street or {})
      local trackOwnersOk, tracksConsoleUnowned = #trackDetails == 2, #trackDetails == 2
      for _, detail in ipairs(trackDetails) do
        if tonumber(detail.owner) ~= tonumber(game.interface.getPlayer()) then trackOwnersOk = false end
        if tonumber(detail.owner) ~= -1 then tracksConsoleUnowned = false end
      end
      local publicRoadOk = #streetDetails == 2
      for _, detail in ipairs(streetDetails) do
        if detail.owner ~= nil and detail.owner >= 0 then publicRoadOk = false end
      end
      local trackOwnershipAcceptable = trackOwnersOk or tracksConsoleUnowned
      local shapeOk = crossingSuccess and after and not contains(after.street, roadEntity)
        and #(afterRoad.track or {}) == 2 and #(afterRoad.street or {}) == 2
        and #(afterRoad.node or {}) == 3 and trackOwnershipAcceptable and publicRoadOk
      cleanupDelta(baseline, function(cleaned, cleanupError)
        local entry = { kind = "track-crosses-public-road",
          success = shapeOk and cleaned == true, candidate = candidateIndex,
          commandSuccess = crossingSuccess, elapsedUs = math.max(0, micros() - started),
          sourceRoad = roadEntity, sourceRoadRemoved = after and not contains(after.street, roadEntity),
          delta = totalDelta, crossingDelta = afterRoad, trackOwnershipVerified = trackOwnersOk,
          trackOwnershipObserved = not tracksConsoleUnowned,
          trackOwnershipAcceptable = trackOwnershipAcceptable,
          ownershipLimit = tracksConsoleUnowned
            and "direct console-origin crossing track is native-unowned; GUI ownership is covered by pinned capture evidence"
            or nil,
          publicRoadVerified = publicRoadOk, trackDetails = trackDetails,
          streetDetails = streetDetails, cleanupVerified = cleaned == true,
          resultIds = resultIds(commandResult),
          error = afterError or commandError or roadError or cleanupError }
        results[#results + 1] = entry; marker("geometry-stress-result", entry)
        if entry.success then completed(true)
        else completed(false) end
      end)
    end)
  end)
end

local function runCombinedCrossingCollateral(candidateIndex, results, completed)
  local base = corridorBases[candidateIndex]
  if not base then
    local entry = { kind = "track-crosses-road-with-construction-collateral",
      success = false, error = "no clear combined crossing candidate succeeded" }
    results[#results + 1] = entry; marker("geometry-stress-result", entry)
    completed(false); return
  end
  local first = point(base[1] + 480, base[2] - 150)
  local second = point(base[1] + 480, base[2] + 150)
  if not first or not second then
    runCombinedCrossingCollateral(candidateIndex + 1, results, completed); return
  end
  local baseline, baselineError = snapshot()
  if not baseline then completed(false); return end

  local function cleanupPrepared(root, callback)
    local current = snapshot()
    if root and current and contains(current.construction, root) then
      sendAction({ type = "probe.mutate_construction", kind = "field_decoration",
          mode = "remove", localEntityId = root, localOnly = true }, function()
        cleanupDelta(baseline, callback)
      end)
    else cleanupDelta(baseline, callback) end
  end

  sendProposal(makeStreetProposal(first, second), false, function(roadSuccess, _, roadError)
    local roadWorld = snapshot()
    local roadDelta = roadWorld and difference(roadWorld, baseline) or {}
    if not roadSuccess or not roadWorld or #(roadDelta.street or {}) ~= 1 then
      if roadWorld then cleanupDelta(baseline, function()
        runCombinedCrossingCollateral(candidateIndex + 1, results, completed)
      end)
      else runCombinedCrossingCollateral(candidateIndex + 1, results, completed) end
      return
    end
    local roadEntity = roadDelta.street[1]
    sendAction({ type = "probe.build_construction", kind = "field_decoration",
        x = base[1] + 480, y = base[2] + 82, localOnly = true },
      function(buildSuccess, _, buildError)
        local preparedWorld = snapshot()
        local preparedDelta = preparedWorld and difference(preparedWorld, roadWorld) or {}
        local root = preparedDelta.construction and preparedDelta.construction[1] or nil
        if not buildSuccess or not preparedWorld or #(preparedDelta.construction or {}) ~= 1 then
          cleanupPrepared(root, function()
            runCombinedCrossingCollateral(candidateIndex + 1, results, completed)
          end)
          return
        end
        local crossing, crossingError = makeCrossingProposal(roadEntity, { root })
        if not crossing then
          cleanupPrepared(root, function()
            local entry = { kind = "track-crosses-road-with-construction-collateral",
              success = false, error = crossingError }
            results[#results + 1] = entry; marker("geometry-stress-result", entry)
            completed(false)
          end)
          return
        end
        local started = micros()
        sendProposal(crossing, true, function(commandSuccess, commandResult, commandError)
          local after, afterError = snapshot()
          local crossingDelta = after and difference(after, preparedWorld) or {}
          local totalDelta = after and difference(after, baseline) or {}
          local rootRemoved = after and not contains(after.construction, root)
          local sourceRoadRemoved = after and not contains(after.street, roadEntity)
          local shapeOk = commandSuccess and rootRemoved and sourceRoadRemoved
            and #(crossingDelta.track or {}) == 2
            and #(crossingDelta.street or {}) == 2
            and #(crossingDelta.node or {}) == 3
          cleanupPrepared(root, function(cleaned, cleanupError)
            local entry = {
              kind = "track-crosses-road-with-construction-collateral",
              success = shapeOk and cleaned == true,
              candidate = candidateIndex, commandSuccess = commandSuccess,
              ignoreSoftErrors = true, sourceRoad = roadEntity,
              sourceRoadRemoved = sourceRoadRemoved == true,
              collateralConstruction = root,
              collateralRemoved = rootRemoved == true,
              crossingDelta = crossingDelta, delta = totalDelta,
              cleanupVerified = cleaned == true,
              elapsedUs = math.max(0, micros() - started),
              resultIds = resultIds(commandResult),
              error = afterError or commandError or roadError or buildError or cleanupError,
            }
            results[#results + 1] = entry; marker("geometry-stress-result", entry)
            completed(entry.success)
          end)
        end)
      end)
  end)
end

local function runCollateralCase(candidateIndex, results, completed)
  local base = corridorBases[candidateIndex]
  if not base then
    local entry = { kind = "track-with-construction-collateral", success = false,
      error = "no collateral candidate succeeded" }
    results[#results + 1] = entry; marker("geometry-stress-result", entry); completed(false); return
  end
  local x, y = base[1] + 420, base[2]
  local baseline, baselineError = snapshot()
  if not baseline then completed(false); return end
  sendAction({ type = "probe.build_construction", kind = "field_decoration",
      x = x, y = y, localOnly = true }, function(buildSuccess, _, buildError)
    local withConstruction = snapshot()
    local built = withConstruction and difference(withConstruction, baseline) or {}
    if not buildSuccess or not withConstruction or #(built.construction or {}) ~= 1 then
      runCollateralCase(candidateIndex + 1, results, completed); return
    end
    local root = built.construction[1]
    local points = { point(x - 150, y), point(x, y), point(x + 150, y) }
    if not points[1] or not points[2] or not points[3] then completed(false); return end
    local proposal, proposalError = makeTrackProposal(points, {})
    if proposal then
      local field, values = removalVector.read(proposal)
      local assigned, assignmentError = removalVector.assign(proposal, field, values, { root })
      if not assigned then proposal, proposalError = nil, assignmentError end
    end
    if not proposal then
      local entry = { kind = "track-with-construction-collateral", success = false,
        error = proposalError }
      results[#results + 1] = entry; marker("geometry-stress-result", entry); completed(false); return
    end
    local started = micros()
    sendProposal(proposal, true, function(commandSuccess, commandResult, commandError)
      local after, afterError = snapshot()
      local delta = after and difference(after, withConstruction) or {}
      local shapeOk = commandSuccess and after and not contains(after.construction, root)
        and #(delta.track or {}) == 2 and #(delta.node or {}) == 3
      -- Use the post-collateral world as the cleanup baseline: its construction
      -- root is intentionally absent, while the newly-created rail must retire.
      local cleanupBaseline = withConstruction
      cleanupBaseline.construction = baseline.construction
      cleanupDelta(cleanupBaseline, function(cleaned, cleanupError)
        local entry = { kind = "track-with-construction-collateral",
          success = shapeOk and cleaned == true, candidate = candidateIndex,
          commandSuccess = commandSuccess, elapsedUs = math.max(0, micros() - started),
          collateralConstruction = root,
          collateralRemoved = after and not contains(after.construction, root),
          delta = delta, cleanupVerified = cleaned == true,
          resultIds = resultIds(commandResult),
          error = afterError or commandError or buildError or cleanupError }
        results[#results + 1] = entry; marker("geometry-stress-result", entry); completed(entry.success)
      end)
    end)
  end)
end

local function slopeCandidates()
  local result = {}
  for x = -1500, 1500, 300 do
    for y = -1500, 1500, 300 do
      local heights, valid = {}, true
      for _, offset in ipairs({ { 0, 0 }, { -55, -100 }, { 55, -100 },
          { -55, 100 }, { 55, 100 } }) do
        local z = terrainHeight(x + offset[1], y + offset[2])
        if z == nil or not validCoordinate(x + offset[1], y + offset[2]) then valid = false; break end
        heights[#heights + 1] = z
      end
      if valid then
        local minZ, maxZ = math.huge, -math.huge
        for _, z in ipairs(heights) do minZ, maxZ = math.min(minZ, z), math.max(maxZ, z) end
        result[#result + 1] = { x = x, y = y, z = heights[1], span = maxZ - minZ }
      end
    end
  end
  table.sort(result, function(left, right)
    if left.span ~= right.span then return left.span > right.span end
    if left.x ~= right.x then return left.x < right.x end
    return left.y < right.y
  end)
  return result
end

local function runSlopeStationCase(candidates, index, results, completed)
  local candidate = candidates[index]
  if not candidate then
    local entry = { kind = "rail-station-on-slope", success = false,
      error = "no uneven-terrain station candidate succeeded" }
    results[#results + 1] = entry; marker("geometry-stress-result", entry); completed(false); return
  end
  local baseline, baselineError = snapshot()
  if not baseline then completed(false); return end
  local started = micros()
  sendAction({ type = "probe.build_construction", kind = "station",
      x = candidate.x, y = candidate.y, localOnly = true }, function(commandSuccess, commandResult, commandError)
    local after, afterError = snapshot()
    local delta = after and difference(after, baseline) or {}
    if commandSuccess and after and #(delta.construction or {}) == 0
      and #(delta.station or {}) == 0 then
      runSlopeStationCase(candidates, index + 1, results, completed); return
    end
    local root = #(delta.construction or {}) == 1 and delta.construction[1] or nil
    local zMin, zMax = math.huge, -math.huge
    for _, entity in ipairs(delta.node or {}) do
      local position = nodePosition(entity)
      if position then zMin, zMax = math.min(zMin, position.z), math.max(zMax, position.z) end
    end
    local zSpan = zMax >= zMin and zMax - zMin or nil
    local ownerOk = root and tonumber(ownerOf(root)) == tonumber(game.interface.getPlayer())
    local shapeOk = commandSuccess and root ~= nil and #(delta.station or {}) >= 1
      and #(delta.stationGroup or {}) >= 1 and #(delta.track or {}) >= 1
      and candidate.span >= 1 and zSpan ~= nil and zSpan <= 0.05 and ownerOk
    if not root then
      local entry = { kind = "rail-station-on-slope", success = false,
        commandSuccess = commandSuccess, terrainSpanBefore = candidate.span,
        delta = delta, error = afterError or commandError or baselineError }
      results[#results + 1] = entry; marker("geometry-stress-result", entry); completed(false); return
    end
    sendAction({ type = "probe.mutate_construction", kind = "station", mode = "remove",
        localEntityId = root, localOnly = true }, function(removeSuccess, _, removeError)
      local retired = snapshot()
      local rootGone = retired and not contains(retired.construction, root)
      local entry = { kind = "rail-station-on-slope",
        success = shapeOk and removeSuccess and rootGone == true,
        candidate = index, x = candidate.x, y = candidate.y,
        commandSuccess = commandSuccess, elapsedUs = math.max(0, micros() - started),
        terrainSpanBefore = candidate.span, stationNodeZSpan = zSpan,
        construction = root, delta = delta, shapeVerified = shapeOk,
        ownershipVerified = ownerOk, removalVerified = removeSuccess and rootGone == true,
        resultIds = resultIds(commandResult),
        error = afterError or commandError or removeError }
      results[#results + 1] = entry; marker("geometry-stress-result", entry); completed(entry.success)
    end)
  end)
end

local function runSequentialBuildRecovery(results, completed)
  local baseline, baselineError = snapshot()
  if not baseline then completed(false); return end
  -- Do not deliberately submit collision-invalid native proposals here. Build
  -- 35924 can assert after reporting "Construction not possible" for an exact
  -- duplicate. Two independent build/cleanup rounds prove that a complex
  -- proposal leaves no stale topology or command state without risking the
  -- disposable process on an engine assertion.
  local blockerSpec = { nodes = 3, spacing = 80 }
  local blockerPoints = pointsFor(blockerSpec, corridorBases[2])
  local blockerProposal, proposalError = blockerPoints
    and makeTrackProposal(blockerPoints, blockerSpec) or nil
  if not blockerProposal then
    local entry = { kind = "sequential-build-recovery", success = false, error = proposalError }
    results[#results + 1] = entry; completed(false); return
  end
  sendProposal(blockerProposal, false, function(blockerSuccess, blockerResult, blockerError)
    local withBlocker, blockerSnapshotError = snapshot()
    local blockerDelta = withBlocker and difference(withBlocker, baseline) or {}
    local blockerShape = blockerSuccess and withBlocker and #(blockerDelta.track or {}) == 2
      and #(blockerDelta.node or {}) == 3
    if not blockerShape then
      local entry = { kind = "sequential-build-recovery", success = false,
        blockerCommandSuccess = blockerSuccess, blockerDelta = blockerDelta,
        error = blockerSnapshotError or blockerError or "first recovery build did not materialise" }
      results[#results + 1] = entry; marker("geometry-stress-result", entry); completed(false); return
    end
    cleanupDelta(baseline, function(blockerCleaned, blockerCleanupError)
        if not blockerCleaned then
          local entry = { kind = "sequential-build-recovery", success = false,
            firstCommandSuccess = blockerSuccess, firstDelta = blockerDelta,
            error = blockerCleanupError }
          results[#results + 1] = entry; marker("geometry-stress-result", entry); completed(false); return
        end
        local validSpec = { kind = "sequential-build-recovery", nodes = 3, spacing = 80 }
        local validPoints = pointsFor(validSpec, corridorBases[2])
        local validProposal = validPoints and makeTrackProposal(validPoints, validSpec) or nil
        if not validProposal then completed(false); return end
        local started = micros()
        sendProposal(validProposal, false, function(validSuccess, validResult, validError)
          local afterValid, afterValidError = snapshot()
          local validDelta = afterValid and difference(afterValid, baseline) or {}
          local validShape = validSuccess and afterValid and #(validDelta.track or {}) == 2
            and #(validDelta.node or {}) == 3
          cleanupDelta(baseline, function(cleaned, cleanupError)
            local entry = { kind = "sequential-build-recovery",
              success = validShape and cleaned == true,
              firstCommandSuccess = blockerSuccess,
              firstResultIds = resultIds(blockerResult), firstDelta = blockerDelta,
              firstCleanupVerified = blockerCleaned,
              secondCommandSuccess = validSuccess,
              secondResultIds = resultIds(validResult), secondDelta = validDelta,
              secondElapsedUs = math.max(0, micros() - started),
              cleanupVerified = cleaned == true,
              error = afterValidError or validError or cleanupError }
            results[#results + 1] = entry
            marker("geometry-stress-result", entry)
            completed(entry.success)
          end)
        end)
      end)
  end)
end

local function runSequence(steps, index, results)
  local step = steps[index]
  if not step then
    local success = true
    for _, entry in ipairs(results) do if entry.success ~= true then success = false end end
    marker("geometry-stress-complete", {
      success = success,
      expectedCases = #steps,
      completedCases = #results,
      cases = results,
      exactGuiEvidence = {
        crossing = { session = "crossing-ui-20260809-0330", sequence = 20,
          digest = "ae34d9d9", lengthMetres = 74, publicRoadSplit = true },
        bridges = { session = "station-collateralfix-20260807-111035",
          digests = { "5e25400a", "5f1fa1fe" }, bridgeTypeIndex = 4,
          bridgeEdges = { 9, 9 }, approximateLengthsMetres = { 840, 891 } },
        cityStationCollateral = { session = "station-collateralfix-20260807-111035",
          sequences = { 4, 8, 12 }, maxCollateralBuildings = 7,
          digests = { "190d9104", "0bd6ec9b", "6e5fed2e" } },
      },
    })
    return
  end
  step(function()
    runSequence(steps, index + 1, results)
  end, results)
end

function M.run()
  local required = api and api.type and api.type.SimpleProposal and api.type.SegmentAndEntity
    and api.type.NodeAndEntity and api.type.Vec2f and api.type.Vec3f
    and api.type.BaseEdgeTrack and api.type.BaseEdgeStreet and api.type.PlayerOwned
    and api.type.ComponentType and api.type.ComponentType.BASE_EDGE
    and api.type.ComponentType.BASE_NODE and api.type.ComponentType.BASE_EDGE_TRACK
    and api.type.ComponentType.BASE_EDGE_STREET and api.type.ComponentType.CONSTRUCTION
    and api.engine and callable(api.engine.getComponent)
    and callable(api.engine.forEachEntityWithComponent)
    and game and game.interface and callable(game.interface.getPlayer)
    and commandFactory("buildProposal") and commandFactory("sendScriptEvent")
  if not required then
    marker("geometry-stress-complete", {
      success = false, error = "required native geometry APIs are unavailable",
    })
    return false
  end

  local tunnelIndex = resource(api.res and api.res.tunnelTypeRep, "railroad_old.lua")
  if tunnelIndex == nil then
    marker("geometry-stress-complete", {
      success = false, error = "tunnel resource repository is unavailable",
      tunnelIndex = tunnelIndex,
    })
    return false
  end

  local results = {}
  local trackSpecs = {
    { kind = "long-straight-track", nodes = 10, spacing = 110 },
    { kind = "long-curved-track", nodes = 10, spacing = 105, curve = true, curved = true },
    { kind = "terrain-following-grade", nodes = 8, spacing = 95,
      minimumZSpan = 2, maximumGrade = 0.08 },
    { kind = "tunnel-transition", nodes = 11, spacing = 90, structure = "tunnel",
      maximumGrade = 0.08,
      transition = true, edgeTypes = { 2, 2, 2, 2, 2, 2, 2, 2, 2, 2 },
      typeIndices = { tunnelIndex, tunnelIndex, tunnelIndex, tunnelIndex, tunnelIndex,
        tunnelIndex, tunnelIndex, tunnelIndex, tunnelIndex, tunnelIndex } },
  }
  local steps = {}
  for _, spec in ipairs(trackSpecs) do
    local captured = spec
    steps[#steps + 1] = function(done, entries)
      runTrackCase(captured, 1, entries, function() done() end)
    end
  end
  steps[#steps + 1] = function(done, entries)
    runCrossingCase(1, entries, function() done() end)
  end
  steps[#steps + 1] = function(done, entries)
    runCombinedCrossingCollateral(3, entries, function() done() end)
  end
  steps[#steps + 1] = function(done, entries)
    runCollateralCase(1, entries, function() done() end)
  end
  steps[#steps + 1] = function(done, entries)
    runSlopeStationCase(slopeCandidates(), 1, entries, function() done() end)
  end
  steps[#steps + 1] = function(done, entries)
    runSequentialBuildRecovery(entries, function() done() end)
  end
  runSequence(steps, 1, results)
  return true
end

return M
