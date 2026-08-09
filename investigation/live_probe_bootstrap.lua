-- Minimal disposable-world bootstrap for supported command/API probes.  It
-- does not load the multiplayer runtime.  A named test event may perform a
-- tightly-scoped mutation in this unsaved world and print its full result.
local json
for _, moduleName in ipairs({ "tpf2_mp_probe/json", "tpf2_mp/json" }) do
  local ok, value = pcall(require, moduleName)
  if ok then json = value; break end
end
if not json then error("TPF2MP disposable probe JSON module is unavailable") end
-- proposal_codec keeps its production module names. Alias only the isolated
-- probe copies so this disposable base-resource harness executes the exact
-- shipped codec without creating a second production-named script tree.
package.preload["tpf2_mp/util"] = function() return require "tpf2_mp_probe/util" end
package.preload["tpf2_mp/json"] = function() return require "tpf2_mp_probe/json" end
package.preload["tpf2_mp/hash"] = function() return require "tpf2_mp_probe/hash" end
package.preload["tpf2_mp/canonical"] = function() return require "tpf2_mp_probe/canonical" end
local proposalCodec = require "tpf2_mp_probe/proposal_codec"
local operationCodec = require "tpf2_mp_probe/operation_codec"
local operationVehiclePostcondition = require "tpf2_mp_probe/operation_vehicle_postcondition"
local tick = 0
local emitted = false
local baselineEdges = {}
local guiSignalProposalCount = 0
local guiLastSignalProposal = nil

local function isEngineThread()
  return game and game.gui == nil
end

local function emitReady()
  if emitted or not isEngineThread() then return end
  baselineEdges = {}
  if api and api.engine and api.engine.forEachEntityWithComponent
    and api.type and api.type.ComponentType.BASE_EDGE then
    pcall(function()
      api.engine.forEachEntityWithComponent(function(entity)
        baselineEdges[tonumber(entity)] = true
      end, api.type.ComponentType.BASE_EDGE)
    end)
  end
  emitted = true
  local function nested(root, first, second)
    local ok, value = pcall(function()
      local outer = root and root[first]
      return second and outer and outer[second] or outer
    end)
    return ok and value or nil
  end
  local payload = {
    event = "world-ready",
    source = "minimal-bootstrap",
    luaState = "engine",
    edgeObjectType = type(nested(api and api.type, "EdgeObject")),
    edgeObjectNew = type(nested(nested(api and api.type, "EdgeObject"), "new")),
    streetProposalEdgeObjectType = type(nested(api and api.type, "StreetProposal", "EdgeObject")),
    simpleStreetProposalEdgeObjectType = type(nested(api and api.type, "SimpleStreetProposal", "EdgeObject")),
    simpleProposalType = type(nested(api and api.type, "SimpleProposal")),
    sendCommandType = type(nested(api and api.cmd, "sendCommand")),
    buildProposalType = type(nested(api and api.cmd and api.cmd.make, "buildProposal")),
    mirroredBuildProposalType = type(rawget(_G, "tpf2mp_native_binding_buildProposal")),
  }
  local encodedOk, encoded = pcall(json.encode, payload)
  print("[TPF2MP-CONSOLE-PROBE] " .. (encodedOk and encoded or '{"event":"world-ready"}'))
end

local function marker(event, values)
  local payload = { event = event }
  for key, value in pairs(values or {}) do payload[key] = value end
  local ok, encoded = pcall(json.encode, payload)
  print("[TPF2MP-CONSOLE-PROBE] " .. (ok and encoded or tostring(event)))
end

local function safeField(value, key)
  local valueType = type(value)
  if valueType ~= "table" and valueType ~= "userdata" then return nil end
  local ok, result = pcall(function() return value[key] end)
  return ok and result or nil
end

local function vectorValues(value, limit)
  local result = {}
  limit = limit or 32
  if type(value) ~= "table" and type(value) ~= "userdata" then return result end
  local lengthOk, length = pcall(function() return #value end)
  if lengthOk and type(length) == "number" then
    for index = 1, math.min(math.max(0, math.floor(length)), limit) do
      local item = safeField(value, index)
      if item ~= nil then result[#result + 1] = item end
    end
  end
  if #result == 0 and type(value) == "table" then
    local keys = {}
    for key in pairs(value) do
      if type(key) == "number" then keys[#keys + 1] = key end
    end
    table.sort(keys)
    for _, key in ipairs(keys) do
      if #result >= limit then break end
      result[#result + 1] = value[key]
    end
  end
  return result
end

local function scalar(value)
  local kind = type(value)
  if kind == "string" or kind == "number" or kind == "boolean" then return value end
  return nil
end

local function projectObject(object)
  local result = {}
  for _, field in ipairs({
    "entity", "entityId", "id", "edgeEntity", "segmentEntity", "category",
    "param", "position", "oneWay", "left", "model", "modelId", "playerEntity", "name",
    "originalEntity", "edgeObjectEntity",
  }) do
    local value = scalar(safeField(object, field))
    if value ~= nil then result[field] = value end
  end
  local modelInstance = safeField(object, "modelInstance")
  if modelInstance ~= nil then
    local projected = { valueType = type(modelInstance) }
    for _, field in ipairs({ "modelId", "model", "fileName", "entity", "id" }) do
      local value = scalar(safeField(modelInstance, field))
      if value ~= nil then projected[field] = value end
    end
    local transform = safeField(modelInstance, "transf") or safeField(modelInstance, "transform")
    if transform ~= nil then
      local matrix = {}
      for index = 1, 16 do
        local value = scalar(safeField(transform, index))
        if value ~= nil then matrix[index] = value end
      end
      if next(matrix) then projected.transform = matrix end
    end
    result.modelInstance = projected
  end
  return result
end

local function projectObjectPair(pair)
  return {
    first = scalar(safeField(pair, 1)),
    second = scalar(safeField(pair, 2)),
  }
end

local function projectSegment(segment)
  local component = safeField(segment, "comp") or segment
  local objects = {}
  for _, pair in ipairs(vectorValues(safeField(component, "objects"), 16)) do
    objects[#objects + 1] = projectObjectPair(pair)
  end
  local result = { objects = objects }
  for _, field in ipairs({ "entity", "type" }) do
    local value = scalar(safeField(segment, field))
    if value ~= nil then result[field] = value end
  end
  for _, field in ipairs({ "node0", "node1", "type", "typeIndex" }) do
    local value = scalar(safeField(component, field))
    if value ~= nil then result["comp_" .. field] = value end
  end
  local track = safeField(segment, "trackEdge")
  if track ~= nil then
    result.trackType = scalar(safeField(track, "trackType"))
    result.catenary = scalar(safeField(track, "catenary"))
  end
  return result
end

local function projectRemoved(value)
  return scalar(value) or scalar(safeField(value, "entity"))
    or scalar(safeField(value, "entityId")) or scalar(safeField(value, "id"))
end

local function signalProposalProjection(param)
  local envelope = safeField(param, "proposal")
  local street = safeField(envelope, "proposal") or safeField(envelope, "streetProposal") or envelope
  local edgeObjects = vectorValues(safeField(street, "edgeObjectsToAdd"), 16)
  if #edgeObjects == 0 then return nil end
  local result = {
    edgeObjectsToAdd = {},
    edgeObjectsToRemove = {},
    edgesToAdd = {},
    edgesToRemove = {},
    rootTypes = {
      parameter = type(param),
      envelope = type(envelope),
      proposal = type(safeField(envelope, "proposal")),
      streetProposal = type(safeField(envelope, "streetProposal")),
      data = type(safeField(param, "data")),
      proposalData = type(safeField(param, "proposalData")),
      resultProposalData = type(safeField(param, "resultProposalData")),
    },
  }
  for _, object in ipairs(edgeObjects) do
    result.edgeObjectsToAdd[#result.edgeObjectsToAdd + 1] = projectObject(object)
  end
  for _, object in ipairs(vectorValues(safeField(street, "edgeObjectsToRemove"), 16)) do
    result.edgeObjectsToRemove[#result.edgeObjectsToRemove + 1] = projectRemoved(object)
  end
  local added = safeField(street, "addedSegments") or safeField(street, "edgesToAdd")
  for _, segment in ipairs(vectorValues(added, 16)) do
    result.edgesToAdd[#result.edgesToAdd + 1] = projectSegment(segment)
  end
  local removed = safeField(street, "removedSegments") or safeField(street, "edgesToRemove")
  for _, segment in ipairs(vectorValues(removed, 16)) do
    result.edgesToRemove[#result.edgesToRemove + 1] = projectRemoved(segment)
  end
  local data = safeField(param, "data")
  if data ~= nil then
    result.builderData = {}
    for _, field in ipairs({
      "model", "modelId", "modelName", "edgeObjectModel", "edgeObjectModelId",
      "selectedModel", "selectedModelId", "edgeEntity", "segmentEntity", "param",
      "position", "left", "oneWay", "category", "type", "name", "fileName", "costs",
    }) do
      local value = scalar(safeField(data, field))
      if value ~= nil then result.builderData[field] = value end
    end
  end
  return result
end

local function sortedNumbers(values)
  local result, seen = {}, {}
  for _, value in pairs(values or {}) do
    local number = tonumber(value)
    if number and number >= 0 and not seen[number] then
      result[#result + 1] = number
      seen[number] = true
    end
  end
  table.sort(result)
  return result
end

local function baseEdges()
  local result = {}
  if not (api and api.engine and api.engine.forEachEntityWithComponent
    and api.type and api.type.ComponentType.BASE_EDGE) then
    return result, "BASE_EDGE enumeration unavailable in engine state"
  end
  local ok, err = pcall(function()
    api.engine.forEachEntityWithComponent(function(entity)
      result[tonumber(entity)] = true
    end, api.type.ComponentType.BASE_EDGE)
  end)
  if not ok then return {}, tostring(err) end
  return result, nil
end

local function ownerOf(entity)
  if not (api and api.engine and api.engine.getComponent
    and api.type and api.type.ComponentType.PLAYER_OWNED) then return nil end
  local ok, owned = pcall(api.engine.getComponent, entity, api.type.ComponentType.PLAYER_OWNED)
  return ok and owned and tonumber(owned.player or owned.playerEntity) or nil
end

local function resultIds(result)
  local ids, seen = {}, {}
  if result == nil then return ids end
  for _, field in ipairs({ "resultEntities", "entities" }) do
    local readable, values = pcall(function() return result[field] end)
    if readable and (type(values) == "table" or type(values) == "userdata") then
      local candidates = {}
      if type(values) == "table" then
        for _, value in pairs(values) do candidates[#candidates + 1] = value end
      else
        local lengthOk, length = pcall(function() return #values end)
        if lengthOk and type(length) == "number" then
          for index = 1, math.min(math.max(0, math.floor(length)), 512) do
            local itemOk, value = pcall(function() return values[index] end)
            if itemOk then candidates[#candidates + 1] = value end
          end
        end
      end
      for _, value in ipairs(candidates) do
        local entity = tonumber(value)
        if not entity and (type(value) == "table" or type(value) == "userdata") then
          local entityOk, nested = pcall(function() return value.entity or value.id or value.entityId end)
          if entityOk then entity = tonumber(nested) end
        end
        if entity and entity >= 0 and not seen[entity] then
          seen[entity] = true
          ids[#ids + 1] = entity
        end
      end
    end
  end
  table.sort(ids)
  return ids
end

local function candidateRoadEdges(param)
  local currentEdges, enumerationError = baseEdges()
  if enumerationError then return {}, enumerationError end
  local candidateSet = {}
  for _, entity in ipairs(sortedNumbers(param and param.resultIds)) do
    if currentEdges[entity] then candidateSet[entity] = true end
  end
  for entity in pairs(currentEdges) do
    if not baselineEdges[entity] then candidateSet[entity] = true end
  end
  local edgeIds = {}
  for entity in pairs(candidateSet) do edgeIds[#edgeIds + 1] = entity end
  return sortedNumbers(edgeIds), nil
end

local function replacementEdge(beforeEdges, previousEntity, result, expectedOwner)
  local afterEdges, enumerationError = baseEdges()
  if enumerationError then return nil, {}, enumerationError end
  local candidates, seen = {}, {}
  local function consider(entity)
    entity = tonumber(entity)
    if entity and afterEdges[entity] and not seen[entity] and ownerOf(entity) == expectedOwner then
      seen[entity] = true
      candidates[#candidates + 1] = entity
    end
  end
  for _, entity in ipairs(resultIds(result)) do consider(entity) end
  for entity in pairs(afterEdges) do
    if not beforeEdges[entity] then consider(entity) end
  end
  consider(previousEntity)
  table.sort(candidates)
  if #candidates == 0 then return nil, candidates, "no replacement BASE_EDGE with the expected owner" end
  return candidates[1], candidates, nil
end

local function replaceEdgeOwner(edgeEntity, playerEntity, callback)
  local componentType = api.type.ComponentType
  local baseOk, baseEdge = pcall(api.engine.getComponent, edgeEntity, componentType.BASE_EDGE)
  local streetOk, streetEdge = pcall(api.engine.getComponent, edgeEntity, componentType.BASE_EDGE_STREET)
  local trackOk, trackEdge = pcall(api.engine.getComponent, edgeEntity, componentType.BASE_EDGE_TRACK)
  if not baseOk or not baseEdge then
    callback(false, nil, "BASE_EDGE component is unavailable")
    return
  end
  if not (streetOk and streetEdge) and not (trackOk and trackEdge) then
    callback(false, nil, "edge has neither BASE_EDGE_STREET nor BASE_EDGE_TRACK")
    return
  end

  local proposalOk, proposalOrError = pcall(function()
    local proposal = api.type.SimpleProposal.new()
    local segment = api.type.SegmentAndEntity.new()
    local playerOwned = api.type.PlayerOwned.new()
    playerOwned.player = playerEntity
    segment.entity = -1
    segment.comp = baseEdge
    segment.playerOwned = playerOwned
    if streetOk and streetEdge then
      segment.type = 0
      segment.streetEdge = streetEdge
    else
      segment.type = 1
      segment.trackEdge = trackEdge
    end
    proposal.streetProposal.edgesToRemove[1] = edgeEntity
    proposal.streetProposal.edgesToAdd[1] = segment
    return proposal
  end)
  if not proposalOk then
    callback(false, nil, tostring(proposalOrError))
    return
  end

  local commandOk, commandOrError = pcall(api.cmd.make.buildProposal, proposalOrError, nil, false)
  if not commandOk then
    callback(false, nil, tostring(commandOrError))
    return
  end
  local sendOk, sendError = pcall(api.cmd.sendCommand, commandOrError, function(result, success)
    local callbackError = nil
    if success ~= true then callbackError = "BuildProposal callback returned success=false" end
    callback(success == true, result, callbackError)
  end)
  if not sendOk then callback(false, nil, tostring(sendError)) end
end

local function proposalOwnershipTest(param)
  if not (isEngineThread() and game and game.interface
    and type(game.interface.getPlayer) == "function"
    and type(game.interface.addPlayer) == "function"
    and api and api.cmd and api.cmd.make and api.cmd.make.buildProposal
    and type(api.cmd.sendCommand) == "function"
    and api.engine and api.engine.getComponent
    and api.type and api.type.SimpleProposal and api.type.SegmentAndEntity and api.type.PlayerOwned) then
    marker("proposal-ownership-test-complete", {
      success = false,
      error = "proposal ownership API unavailable in engine state",
      stage = "engine-capabilities",
    })
    return
  end

  local edgeIds, enumerationError = candidateRoadEdges(param)
  if not enumerationError and #edgeIds == 0 then
    local currentEdges
    currentEdges, enumerationError = baseEdges()
    if not enumerationError then
      local publicStreetEdges = {}
      for entity in pairs(currentEdges) do
        local streetOk, streetEdge = pcall(
          api.engine.getComponent, entity, api.type.ComponentType.BASE_EDGE_STREET
        )
        if streetOk and streetEdge and ownerOf(entity) == nil then
          publicStreetEdges[#publicStreetEdges + 1] = entity
        end
      end
      edgeIds = sortedNumbers(publicStreetEdges)
    end
  end
  if enumerationError or #edgeIds == 0 then
    marker("proposal-ownership-test-complete", {
      success = false,
      error = enumerationError or "no public BASE_EDGE_STREET entity was available",
      stage = "identify-road",
      resultIds = sortedNumbers(param and param.resultIds),
    })
    return
  end

  local originalEntity = edgeIds[1]
  local originalOwner = ownerOf(originalEntity)
  local currentPlayer = tonumber(game.interface.getPlayer())
  local addedOk, addedPlayerOrError = pcall(game.interface.addPlayer)
  local addedPlayer = addedOk and tonumber(addedPlayerOrError) or nil
  if not addedPlayer then
    marker("proposal-ownership-test-complete", {
      success = false,
      error = tostring(addedPlayerOrError),
      stage = "add-player",
      currentPlayer = currentPlayer,
      roadEdgeId = originalEntity,
    })
    return
  end

  local beforeCompany, beforeError = baseEdges()
  if beforeError then
    marker("proposal-ownership-test-complete", { success = false, error = beforeError, stage = "enumerate-before-company" })
    return
  end
  replaceEdgeOwner(originalEntity, addedPlayer, function(companySuccess, companyResult, companyError)
    local companyEntity, companyCandidates, identifyCompanyError = replacementEdge(
      beforeCompany, originalEntity, companyResult, addedPlayer
    )
    if not companySuccess or not companyEntity then
      marker("proposal-ownership-test-complete", {
        success = false,
        error = companyError or identifyCompanyError,
        stage = "assign-company",
        originalEntity = originalEntity,
        originalOwner = originalOwner,
        currentPlayer = currentPlayer,
        addedPlayer = addedPlayer,
        resultIds = resultIds(companyResult),
        candidates = companyCandidates,
      })
      return
    end

    local beforeRestore, beforeRestoreError = baseEdges()
    if beforeRestoreError then
      marker("proposal-ownership-test-complete", {
        success = false,
        error = beforeRestoreError,
        stage = "enumerate-before-restore",
        companyEntity = companyEntity,
      })
      return
    end
    replaceEdgeOwner(companyEntity, currentPlayer, function(restoreSuccess, restoreResult, restoreError)
      local restoredEntity, restoreCandidates, identifyRestoreError = replacementEdge(
        beforeRestore, companyEntity, restoreResult, currentPlayer
      )
      local finalOwner = restoredEntity and ownerOf(restoredEntity) or nil
      marker("proposal-ownership-test-complete", {
        success = restoreSuccess and restoredEntity ~= nil and finalOwner == currentPlayer,
        error = restoreSuccess and identifyRestoreError or restoreError,
        stage = restoreSuccess and restoredEntity and "complete" or "restore-desk",
        originalEntity = originalEntity,
        companyEntity = companyEntity,
        restoredEntity = restoredEntity,
        originalOwner = originalOwner,
        companyOwner = ownerOf(companyEntity),
        finalOwner = finalOwner,
        currentPlayer = currentPlayer,
        addedPlayer = addedPlayer,
        companyResultIds = resultIds(companyResult),
        restoreResultIds = resultIds(restoreResult),
        companyCandidates = companyCandidates,
        restoreCandidates = restoreCandidates,
        entityChangedOnAssign = companyEntity ~= originalEntity,
        entityChangedOnRestore = restoredEntity ~= nil and restoredEntity ~= companyEntity,
      })
    end)
  end)
end

local function ownershipTest(param)
  if not (isEngineThread() and game and game.interface
    and type(game.interface.getPlayer) == "function"
    and type(game.interface.addPlayer) == "function"
    and type(game.interface.setPlayer) == "function") then
    marker("ownership-test-complete", {
      success = false,
      error = "player ownership interface unavailable in engine state",
      stage = "engine-capabilities",
    })
    return
  end

  local currentEdges, enumerationError = baseEdges()
  if enumerationError then
    marker("ownership-test-complete", { success = false, error = enumerationError, stage = "enumerate" })
    return
  end
  local candidateSet = {}
  for _, entity in ipairs(sortedNumbers(param and param.resultIds)) do
    if currentEdges[entity] then candidateSet[entity] = true end
  end
  for entity in pairs(currentEdges) do
    if not baselineEdges[entity] then candidateSet[entity] = true end
  end
  local edgeIds = {}
  for entity in pairs(candidateSet) do edgeIds[#edgeIds + 1] = entity end
  edgeIds = sortedNumbers(edgeIds)
  if #edgeIds == 0 then
    marker("ownership-test-complete", {
      success = false,
      error = "the successful proposal exposed no new BASE_EDGE entity",
      stage = "identify-road",
      resultIds = sortedNumbers(param and param.resultIds),
    })
    return
  end

  local currentPlayer = tonumber(game.interface.getPlayer())
  local addedOk, addedPlayerOrError = pcall(game.interface.addPlayer)
  local addedPlayer = addedOk and tonumber(addedPlayerOrError) or nil
  if not addedPlayer then
    marker("ownership-test-complete", {
      success = false,
      error = tostring(addedPlayerOrError),
      stage = "add-player",
      currentPlayer = currentPlayer,
      roadEdgeIds = edgeIds,
    })
    return
  end

  local observations, symmetric = {}, 0
  for _, entity in ipairs(edgeIds) do
    local beforeOwner = ownerOf(entity)
    local deskCall, deskResult = pcall(game.interface.setPlayer, entity, currentPlayer)
    local deskOwner = ownerOf(entity)
    local companyCall, companyResult = pcall(game.interface.setPlayer, entity, addedPlayer)
    local companyOwner = ownerOf(entity)
    local restoreCall, restoreResult = pcall(game.interface.setPlayer, entity, currentPlayer)
    local restoredOwner = ownerOf(entity)
    local deskOk = deskCall and deskResult ~= false
    local companyOk = companyCall and companyResult ~= false
    local restoreOk = restoreCall and restoreResult ~= false
    local symmetricTransfer = deskOk and tonumber(deskOwner) == currentPlayer
      and companyOk and tonumber(companyOwner) == addedPlayer
      and restoreOk and tonumber(restoredOwner) == currentPlayer
    if symmetricTransfer then symmetric = symmetric + 1 end
    observations[#observations + 1] = {
      entity = entity,
      beforeOwner = beforeOwner,
      deskOwner = deskOwner,
      companyOwner = companyOwner,
      restoredOwner = restoredOwner,
      deskCall = deskOk,
      deskError = not deskCall and tostring(deskResult) or nil,
      companyCall = companyOk,
      companyError = not companyCall and tostring(companyResult) or nil,
      restoreCall = restoreOk,
      restoreError = not restoreCall and tostring(restoreResult) or nil,
      symmetric = symmetricTransfer,
    }
  end
  marker("ownership-test-complete", {
    success = symmetric == #edgeIds,
    currentPlayer = currentPlayer,
    addedPlayer = addedPlayer,
    resultIds = sortedNumbers(param and param.resultIds),
    roadEdgeIds = edgeIds,
    observations = observations,
    symmetricTransfers = symmetric,
  })
end

local function stationUpgradeCodecTest()
  local interface = game and game.interface or {}
  if type(interface.buildConstruction) ~= "function"
    or type(interface.upgradeConstruction) ~= "function"
    or type(interface.bulldoze) ~= "function"
    or type(interface.getHeight) ~= "function" then
    marker("station-upgrade-codec-complete", {
      success = false,
      stage = "capabilities",
      error = "construction helper surface is unavailable",
    })
    return
  end

  local year = 1990
  local fileName = "station/rail/modular_station/modular_station.con"
  local prefix = "station/rail/modular_station/"
  local function module(name, metadata)
    return { name = prefix .. name, variant = 0, metadata = metadata }
  end
  local function modules(catenary)
    local track = catenary and "platform_track_catenary.module" or "platform_track.module"
    return {
      [3400020] = module("main_building_1_era_c.module", {
        era = 2, level = 1, span = { 1, 2 },
        moreCapacity = { cargo = 0, passenger = 30 },
        snapPoint = { 0, -1, 0, 0, 1, 0, 0, 0, 0, 0, 1, 0, -14, 0, 0, 1 },
      }),
      [7400000] = module("platform_passenger_era_c.module", {
        platform = true, passenger_platform = true,
      }),
      [7400010] = module("platform_passenger_era_c.module", {
        platform = true, passenger_platform = true,
      }),
      [8401000] = module(track, { track = true }),
      [8401010] = module(track, { track = true }),
      [10400000] = module("platform_passenger_roof_era_c.module", { platform_roof = true }),
      [10400010] = module("platform_passenger_roof_era_c.module", { platform_roof = true }),
      [10800000] = module("addon_platform_passenger_stairs_era_c.module", { underground = true }),
    }
  end
  local function params(catenary)
    return {
      templateIndex = 0, tracks = 0, length = 0, trackType = 0,
      catenary = catenary and 1 or 0, year = year, modules = modules(catenary),
    }
  end
  local baselineTracks = {}
  pcall(function()
    api.engine.forEachEntityWithComponent(function(entity)
      baselineTracks[tonumber(entity)] = true
    end, api.type.ComponentType.BASE_EDGE_TRACK)
  end)

  local candidates = {
    { -1400, -1400 }, { 1400, -1400 }, { -1400, 1400 }, { 1400, 1400 },
    { -1000, -1200 }, { 1000, -1200 }, { -1000, 1200 }, { 1000, 1200 },
  }
  local builtEntity, buildError, transform
  for _, candidate in ipairs(candidates) do
    local x, y = candidate[1], candidate[2]
    local heightOk, height = pcall(interface.getHeight, { x = x, y = y })
    if not heightOk or tonumber(height) == nil then
      heightOk, height = pcall(interface.getHeight, { x, y })
    end
    if heightOk and tonumber(height) then
      transform = { 1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1, 0, x, y, tonumber(height), 1 }
      local buildOk, value = pcall(interface.buildConstruction, fileName, params(false), transform)
      builtEntity = buildOk and tonumber(value) or nil
      if builtEntity and builtEntity >= 0 then break end
      buildError = tostring(value)
      builtEntity = nil
    end
  end
  if not builtEntity then
    marker("station-upgrade-codec-complete", {
      success = false, stage = "build", error = buildError or "no candidate succeeded",
    })
    return
  end

  local upgradeParams = params(true)
  upgradeParams.seed = 1
  upgradeParams.upgrade = true
  local transaction, canonicalError = proposalCodec.normalise({
    __observedCost = 0,
    __constructionAdditions = {{
      entity = -1, fileName = fileName, transf = transform, params = upgradeParams,
    }},
    __constructionRemovals = {{ entity = builtEntity }},
  }, "company:1", {
    resolveCanonical = function(kind, localId)
      if kind == "construction" and localId == builtEntity then
        return "construction:probe:station"
      end
    end,
    entityKind = function(localId)
      if localId == builtEntity then return "construction" end
    end,
  })
  if not transaction then
    pcall(interface.bulldoze, builtEntity)
    marker("station-upgrade-codec-complete", {
      success = false, stage = "canonicalise", error = tostring(canonicalError),
    })
    return
  end
  local spec, materialiseError = proposalCodec.materialiseConstruction(transaction)
  if not spec then
    pcall(interface.bulldoze, builtEntity)
    marker("station-upgrade-codec-complete", {
      success = false, stage = "materialise", error = tostring(materialiseError),
    })
    return
  end
  local reservedStripped = spec.params.seed == nil and spec.params.upgrade == nil
  if not reservedStripped then
    pcall(interface.bulldoze, builtEntity)
    marker("station-upgrade-codec-complete", {
      success = false, stage = "reserved-fields", reservedStripped = false,
    })
    return
  end

  local upgradeOk, upgradedOrError = pcall(
    interface.upgradeConstruction, builtEntity, spec.fileName, spec.params)
  local upgradedEntity = upgradeOk and tonumber(upgradedOrError) or nil
  if not upgradedEntity or upgradedEntity < 0 then upgradedEntity = builtEntity end
  local trackCount, poweredTracks = 0, 0
  if upgradeOk then
    pcall(function()
      api.engine.forEachEntityWithComponent(function(entity)
        entity = tonumber(entity)
        if entity and not baselineTracks[entity] then
          trackCount = trackCount + 1
          local component = api.engine.getComponent(entity, api.type.ComponentType.BASE_EDGE_TRACK)
          if component and component.catenary == true then poweredTracks = poweredTracks + 1 end
        end
      end, api.type.ComponentType.BASE_EDGE_TRACK)
    end)
  end
  local removed = pcall(interface.bulldoze, upgradedEntity)
  marker("station-upgrade-codec-complete", {
    success = upgradeOk and reservedStripped and trackCount > 0 and poweredTracks == trackCount,
    stage = upgradeOk and "complete" or "upgrade",
    error = not upgradeOk and tostring(upgradedOrError) or nil,
    transactionDigest = transaction.digest,
    builtEntity = builtEntity,
    upgradedEntity = upgradedEntity,
    reservedStripped = reservedStripped,
    trackCount = trackCount,
    poweredTracks = poweredTracks,
    cleanupIssued = removed == true,
  })
end

local vehiclePurchaseProbeStage = "idle"

local function nativeVehicleProjection(entity, types)
  if not entity then return nil end
  local componentOk, component = pcall(
    api.engine.getComponent, entity, types.TRANSPORT_VEHICLE)
  -- Build 35924 raises "Invalid entity" once SellVehicle has actually removed
  -- its target. Treat that exact absence shape as the desired nil projection;
  -- callers still distinguish it from a live component with missing fields.
  if not componentOk then return nil end
  if not component then return nil end
  local projection = {
    entity = entity,
    userStopped = safeField(component, "userStopped") == true,
    sellOnArrival = safeField(component, "sellOnArrival") == true,
    vehicles = {},
  }
  local nativeConfig = safeField(component, "transportVehicleConfig")
  for index, wrapped in ipairs(vectorValues(safeField(nativeConfig, "vehicles"), 16)) do
    local part = safeField(wrapped, "part")
    local modelId = tonumber(safeField(part, "modelId"))
    local modelName
    pcall(function() modelName = api.res.modelRep.getName(modelId) end)
    projection.vehicles[index] = {
      model = modelName,
      reversed = safeField(part, "reversed") == true,
      loadConfig = vectorValues(safeField(part, "loadConfig"), 64),
      autoLoadConfig = vectorValues(safeField(wrapped, "autoLoadConfig"), 64),
      maintenanceState = tonumber(safeField(wrapped, "maintenanceState")),
      targetMaintenanceState = tonumber(safeField(wrapped, "targetMaintenanceState")),
    }
  end
  return projection
end

local function nativeVehicleMatches(projection, names)
  if not projection or #projection.vehicles ~= #names then return false end
  for index, name in ipairs(names) do
    local part = projection.vehicles[index]
    if not part or part.model ~= name
      or #part.loadConfig ~= 1 or part.loadConfig[1] ~= 0
      or #part.autoLoadConfig ~= 1 or part.autoLoadConfig[1] ~= 1 then
      return false
    end
  end
  return true
end

local function productionVehicleObservation(entity, types)
  local componentOk, component = pcall(
    api.engine.getComponent, entity, types.TRANSPORT_VEHICLE)
  if not componentOk or not component then return nil end
  local result = operationVehiclePostcondition.project(component, api)
  result.exists = true
  result.userStopped = safeField(component, "userStopped") == true
  result.sellOnArrival = safeField(component, "sellOnArrival") == true
  return result
end

local function vehiclePurchaseCodecTest(options)
  options = options or {}
  local lifecycle = options.lifecycle == true
  local completionEvent = lifecycle
    and "vehicle-lifecycle-codec-complete" or "vehicle-purchase-codec-complete"
  vehiclePurchaseProbeStage = "capabilities"
  local interface = game and game.interface or {}
  local types = api and api.type and api.type.ComponentType or {}
  local function callable(value)
    local valueType = type(value)
    return valueType == "function" or valueType == "table" or valueType == "userdata"
  end
  if not callable(interface.buildConstruction)
    or not callable(interface.getHeight)
    or not callable(interface.getPlayer)
    or not api or not api.engine or not callable(api.engine.forEachEntityWithComponent)
    or not types.VEHICLE_DEPOT or not types.TRANSPORT_VEHICLE then
    marker(completionEvent, {
      success = false, stage = "capabilities", error = "vehicle purchase probe API is unavailable",
      buildConstructionType = type(interface.buildConstruction),
      getHeightType = type(interface.getHeight),
      getPlayerType = type(interface.getPlayer),
      forEachType = type(api and api.engine and api.engine.forEachEntityWithComponent),
      vehicleDepotComponent = types.VEHICLE_DEPOT,
      transportVehicleComponent = types.TRANSPORT_VEHICLE,
    })
    return
  end

  vehiclePurchaseProbeStage = "baseline"
  local baselineDepots, baselineVehicles = {}, {}
  pcall(function()
    api.engine.forEachEntityWithComponent(function(entity)
      baselineDepots[tonumber(entity)] = true
    end, types.VEHICLE_DEPOT)
    api.engine.forEachEntityWithComponent(function(entity)
      baselineVehicles[tonumber(entity)] = true
    end, types.TRANSPORT_VEHICLE)
  end)

  vehiclePurchaseProbeStage = "build-depot"
  local candidates = {
    { -1500, -1500 }, { 1500, -1500 }, { -1500, 1500 }, { 1500, 1500 },
    { -1100, -1300 }, { 1100, -1300 }, { -1100, 1300 }, { 1100, 1300 },
  }
  local construction, buildError
  for _, candidate in ipairs(candidates) do
    local x, y = candidate[1], candidate[2]
    local heightOk, height = pcall(interface.getHeight, { x = x, y = y })
    if not heightOk or tonumber(height) == nil then
      heightOk, height = pcall(interface.getHeight, { x, y })
    end
    if heightOk and tonumber(height) then
      local transform = {
        1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1, 0,
        x, y, tonumber(height), 1,
      }
      local buildOk, value = pcall(interface.buildConstruction,
        "depot/train_depot_era_a.con", { trackType = 0, catenary = 0 }, transform)
      construction = buildOk and tonumber(value) or nil
      if construction and construction >= 0 then break end
      buildError = tostring(value)
      construction = nil
    end
  end
  if not construction then
    marker(completionEvent, {
      success = false, stage = "build-depot", error = buildError or "no depot site succeeded",
    })
    return
  end

  vehiclePurchaseProbeStage = "bind-depot"
  local depotEntity
  api.engine.forEachEntityWithComponent(function(entity)
    entity = tonumber(entity)
    if entity and not baselineDepots[entity] and not depotEntity then depotEntity = entity end
  end, types.VEHICLE_DEPOT)
  if not depotEntity then
    marker(completionEvent, {
      success = false, stage = "bind-depot", construction = construction,
      error = "built construction exposed no new VEHICLE_DEPOT entity",
    })
    return
  end

  -- The disposable probe is about the command shape, not financing. Keep its
  -- result independent of the difficulty preset used by the fresh map.
  vehiclePurchaseProbeStage = "funding"
  local fundingGranted = callable(interface.book)
    and pcall(interface.book, 50000000) or false
  vehiclePurchaseProbeStage = "player"
  local player = tonumber(interface.getPlayer())
  if not player or player < 0 then
    marker(completionEvent, {
      success = false, stage = "player", depotEntity = depotEntity,
      error = "current native player is unavailable",
    })
    return
  end

  vehiclePurchaseProbeStage = "default-config"
  local names = {
    "vehicle/train/nohab_m1_v2.mdl",
    "vehicle/waggon/bc4_v2.mdl",
    "vehicle/waggon/bc4_v2.mdl",
  }
  local config, configError = operationCodec.defaultVehicleConfig(names, api)
  if not config then
    marker(completionEvent, {
      success = false, stage = "default-config", error = tostring(configError),
    })
    return
  end
  vehiclePurchaseProbeStage = "canonicalise"
  local transaction, transactionError = operationCodec.make("vehicle.buy", "company:1", {
    depotCid = "depot:probe:vehicle-purchase", config = config,
  })
  if not transaction then
    marker(completionEvent, {
      success = false, stage = "canonicalise", error = tostring(transactionError),
    })
    return
  end
  vehiclePurchaseProbeStage = "materialise"
  local materialised, materialiseError = operationCodec.materialise(transaction, {
    api = api,
    nativePlayerId = player,
    resolveLocal = function(cid)
      if cid == "depot:probe:vehicle-purchase" then return depotEntity end
    end,
    factory = function(name)
      return api and api.cmd and api.cmd.make and api.cmd.make[name]
    end,
  })
  if not materialised then
    marker(completionEvent, {
      success = false, stage = "materialise", error = tostring(materialiseError),
    })
    return
  end
  vehiclePurchaseProbeStage = "command"
  local commandOk, command = pcall(materialised.factory,
    materialised.args[1], materialised.args[2], materialised.args[3])
  if not commandOk then
    marker(completionEvent, {
      success = false, stage = "command", error = tostring(command),
    })
    return
  end

  vehiclePurchaseProbeStage = "send"
  api.cmd.sendCommand(command, function(result, success)
    vehiclePurchaseProbeStage = "callback"
    local vehicleEntity = tonumber(safeField(result, "resultVehicleEntity"))
    if not vehicleEntity or vehicleEntity < 0 then
      api.engine.forEachEntityWithComponent(function(entity)
        entity = tonumber(entity)
        if entity and not baselineVehicles[entity] and not vehicleEntity then vehicleEntity = entity end
      end, types.TRANSPORT_VEHICLE)
    end
    local projection = vehicleEntity and nativeVehicleProjection(vehicleEntity, types) or nil
    local exactConsist = nativeVehicleMatches(projection, names)
    local productionPurchase = vehicleEntity
      and productionVehicleObservation(vehicleEntity, types) or nil
    local productionPurchaseOk, productionPurchaseError =
      operationVehiclePostcondition.validate(transaction, productionPurchase)
    exactConsist = exactConsist and productionPurchaseOk == true
    if success ~= true or not vehicleEntity or not exactConsist or not lifecycle then
      marker(completionEvent, {
        success = success == true and vehicleEntity ~= nil and exactConsist,
        stage = success == true and "complete" or "apply",
        commandSuccess = success == true,
        transactionDigest = transaction.digest,
        player = player,
        depotEntity = depotEntity,
        construction = construction,
        vehicleEntity = vehicleEntity,
        fundingGranted = fundingGranted,
        canonicalConfig = config,
        nativeConfig = projection,
        productionPostcondition = productionPurchase,
        productionPostconditionError = productionPurchaseError,
      })
      return
    end

    local finished = false
    local lifecycleEvidence = {
      purchaseDigest = transaction.digest,
      purchase = projection,
      productionPurchase = productionPurchase,
      steps = {},
    }
    local targetCid = "vehicle:probe:lifecycle"
    local unpackValues = unpack or (table and table.unpack)
    local function finish(ok, stage, errorText)
      if finished then return end
      finished = true
      vehiclePurchaseProbeStage = stage
      local cleanupCallOk, cleanupResult = pcall(interface.bulldoze, construction)
      marker(completionEvent, {
        success = ok == true,
        stage = stage,
        error = errorText,
        player = player,
        depotEntity = depotEntity,
        construction = construction,
        vehicleEntity = vehicleEntity,
        fundingGranted = fundingGranted,
        canonicalConfig = config,
        evidence = lifecycleEvidence,
        cleanupCallOk = cleanupCallOk,
        cleanupResult = scalar(cleanupResult),
      })
    end
    local function callbackGuard(stage, appliedTransaction, callback)
      return function(commandResult, commandSuccess)
        local function traceback(err)
          local text = tostring(err)
          if debug and debug.traceback then return debug.traceback(text, 2) end
          return text
        end
        local ok, err = xpcall(function()
          if commandSuccess ~= true then
            finish(false, stage .. "-apply", "native command callback returned success=false")
            return
          end
          callback(commandResult, appliedTransaction)
        end, traceback)
        if not ok then finish(false, stage .. "-callback", tostring(err)) end
      end
    end
    local function validateProduction(transactionToValidate)
      local observed = productionVehicleObservation(vehicleEntity, types)
      local passed, postconditionError = operationVehiclePostcondition.validate(
        transactionToValidate, observed)
      lifecycleEvidence.productionChecks = lifecycleEvidence.productionChecks or {}
      lifecycleEvidence.productionChecks[#lifecycleEvidence.productionChecks + 1] = {
        kind = transactionToValidate.kind,
        passed = passed == true,
        error = postconditionError,
        observation = observed,
      }
      if passed ~= true then
        finish(false, transactionToValidate.kind .. "-production-postcondition",
          tostring(postconditionError))
        return false
      end
      return true
    end
    local function issue(kind, data, callback)
      if finished then return end
      vehiclePurchaseProbeStage = kind .. "-canonicalise"
      local nextTransaction, makeError = operationCodec.make(kind, "company:1", data)
      if not nextTransaction then
        finish(false, kind .. "-canonicalise", tostring(makeError))
        return
      end
      vehiclePurchaseProbeStage = kind .. "-materialise"
      local nextMaterialised, nextError = operationCodec.materialise(nextTransaction, {
        api = api,
        nativePlayerId = player,
        resolveLocal = function(cid)
          if cid == targetCid then return vehicleEntity end
          if cid == "depot:probe:vehicle-purchase" then return depotEntity end
        end,
        factory = function(name)
          return api and api.cmd and api.cmd.make and api.cmd.make[name]
        end,
      })
      if not nextMaterialised then
        finish(false, kind .. "-materialise", tostring(nextError))
        return
      end
      vehiclePurchaseProbeStage = kind .. "-command"
      local commandBuilt, nextCommand = pcall(
        nextMaterialised.factory, unpackValues(nextMaterialised.args, 1, #nextMaterialised.args))
      if not commandBuilt then
        finish(false, kind .. "-command", tostring(nextCommand))
        return
      end
      lifecycleEvidence.steps[#lifecycleEvidence.steps + 1] = {
        kind = kind, transactionDigest = nextTransaction.digest,
      }
      vehiclePurchaseProbeStage = kind .. "-send"
      local sent, sendError = pcall(
        api.cmd.sendCommand, nextCommand, callbackGuard(kind, nextTransaction, callback))
      if not sent then finish(false, kind .. "-send", tostring(sendError)) end
    end

    local function sellVehicle()
      issue("vehicle.sell", { targetCid = targetCid }, function()
        local afterSale = nativeVehicleProjection(vehicleEntity, types)
        lifecycleEvidence.afterSale = afterSale
        if afterSale ~= nil then
          finish(false, "vehicle.sell-readback", "sold TRANSPORT_VEHICLE component is still present")
          return
        end
        finish(true, "complete")
      end)
    end
    local function replaceVehicle()
      local replacementNames = {
        "vehicle/train/nohab_m1_v2.mdl",
        "vehicle/waggon/bc4_v2.mdl",
      }
      local replacementConfig, replacementError = operationCodec.defaultVehicleConfig(
        replacementNames, api)
      if not replacementConfig then
        finish(false, "vehicle.replace-default-config", tostring(replacementError))
        return
      end
      issue("vehicle.replace", {
        targetCid = targetCid, config = replacementConfig,
      }, function(commandResult, appliedTransaction)
        local replacementEntity = tonumber(safeField(commandResult, "resultVehicleEntity"))
        if replacementEntity and replacementEntity >= 0 then vehicleEntity = replacementEntity end
        local afterReplace = nativeVehicleProjection(vehicleEntity, types)
        lifecycleEvidence.replacementConfig = replacementConfig
        lifecycleEvidence.afterReplace = afterReplace
        if not validateProduction(appliedTransaction) then return end
        if not nativeVehicleMatches(afterReplace, replacementNames) then
          finish(false, "vehicle.replace-readback", "native consist does not match replacement config")
          return
        end
        sellVehicle()
      end)
    end
    local function setMaintenance()
      issue("vehicle.maintenance", {
        targetCid = targetCid, valueBasisPoints = 7500,
      }, function(_, appliedTransaction)
        local afterMaintenance = nativeVehicleProjection(vehicleEntity, types)
        lifecycleEvidence.afterMaintenance = afterMaintenance
        if not validateProduction(appliedTransaction) then return end
        local targetCount = 0
        local targetMatches = afterMaintenance ~= nil
        for _, part in ipairs(afterMaintenance and afterMaintenance.vehicles or {}) do
          if part.targetMaintenanceState ~= nil then
            targetCount = targetCount + 1
            targetMatches = targetMatches and math.abs(part.targetMaintenanceState - 0.75) < 0.0001
          end
        end
        if targetCount ~= #names or not targetMatches then
          finish(false, "vehicle.maintenance-readback",
            "native targetMaintenanceState does not equal 0.75 on every vehicle part")
          return
        end
        replaceVehicle()
      end)
    end
    local function reverseSecondTime()
      issue("vehicle.reverse", { targetCid = targetCid }, function(_, appliedTransaction)
        local afterReverseRoundTrip = nativeVehicleProjection(vehicleEntity, types)
        lifecycleEvidence.afterReverseRoundTrip = afterReverseRoundTrip
        if not validateProduction(appliedTransaction) then return end
        if not nativeVehicleMatches(afterReverseRoundTrip, names) then
          finish(false, "vehicle.reverse-readback",
            "two native reversals did not restore the purchased consist")
          return
        end
        setMaintenance()
      end)
    end
    local function reverseFirstTime()
      issue("vehicle.reverse", { targetCid = targetCid }, function(_, appliedTransaction)
        lifecycleEvidence.afterFirstReverse = nativeVehicleProjection(vehicleEntity, types)
        if not validateProduction(appliedTransaction) then return end
        reverseSecondTime()
      end)
    end
    local function startVehicle()
      issue("vehicle.stop", { targetCid = targetCid, stopped = false }, function(_, appliedTransaction)
        local afterStart = nativeVehicleProjection(vehicleEntity, types)
        lifecycleEvidence.afterStart = afterStart
        if not validateProduction(appliedTransaction) then return end
        if not afterStart or afterStart.userStopped then
          finish(false, "vehicle.stop-start-readback", "native userStopped did not clear")
          return
        end
        reverseFirstTime()
      end)
    end
    issue("vehicle.stop", { targetCid = targetCid, stopped = true }, function(_, appliedTransaction)
      local afterStop = nativeVehicleProjection(vehicleEntity, types)
      lifecycleEvidence.afterStop = afterStop
      if not validateProduction(appliedTransaction) then return end
      if not afterStop or not afterStop.userStopped then
        finish(false, "vehicle.stop-readback", "native userStopped did not become true")
        return
      end
      startVehicle()
    end)
  end)
end

local script = {
  init = function()
    tick = 0
    emitted = false
    baselineEdges = {}
    guiSignalProposalCount = 0
    guiLastSignalProposal = nil
  end,

  update = function()
    if not isEngineThread() then return end
    tick = tick + 1
    -- Let the freshly generated map complete a few engine updates before the
    -- external runner is told that issuing a construction command is safe.
    if tick >= 30 then emitReady() end
  end,

  save = function()
    return { tick = tick }
  end,

  load = function(saved)
    tick = type(saved) == "table" and tonumber(saved.tick) or 0
    emitted = false
    baselineEdges = {}
    guiSignalProposalCount = 0
    guiLastSignalProposal = nil
  end,

  handleEvent = function(_, id, name, param)
    if id == "tpf2mp-probe" and name == "ownership-test" then ownershipTest(param or {}) end
    if id == "tpf2mp-probe" and name == "proposal-ownership-test" then proposalOwnershipTest(param or {}) end
    if id == "tpf2mp-probe" and name == "station-upgrade-codec-test" then stationUpgradeCodecTest() end
    if id == "tpf2mp-probe" and name == "vehicle-purchase-codec-test" then
      local function traceback(err)
        local text = tostring(err)
        if debug and debug.traceback then return debug.traceback(text, 2) end
        return text
      end
      local ok, err = xpcall(vehiclePurchaseCodecTest, traceback)
      if not ok then
        marker("vehicle-purchase-codec-complete", {
          success = false,
          stage = "lua-error:" .. tostring(vehiclePurchaseProbeStage),
          error = tostring(err),
        })
      end
    end
    if id == "tpf2mp-probe" and name == "vehicle-lifecycle-codec-test" then
      local function traceback(err)
        local text = tostring(err)
        if debug and debug.traceback then return debug.traceback(text, 2) end
        return text
      end
      local ok, err = xpcall(function()
        vehiclePurchaseCodecTest({ lifecycle = true })
      end, traceback)
      if not ok then
        marker("vehicle-lifecycle-codec-complete", {
          success = false,
          stage = "lua-error:" .. tostring(vehiclePurchaseProbeStage),
          error = tostring(err),
        })
      end
    end
  end,

  guiHandleEvent = function(id, name, param)
    if id ~= "streetTerminalBuilder" then return end
    if name == "builder.proposalCreate" then
      local projection = signalProposalProjection(param)
      if projection then
        guiSignalProposalCount = guiSignalProposalCount + 1
        guiLastSignalProposal = projection
        marker("signal-gui-proposal", {
          success = true,
          count = guiSignalProposalCount,
          sourceId = id,
          eventName = name,
          proposal = projection,
        })
      end
    elseif name == "builder.apply" and guiLastSignalProposal ~= nil then
      marker("signal-gui-capture-complete", {
        success = true,
        count = guiSignalProposalCount,
        sourceId = id,
        eventName = name,
        proposal = guiLastSignalProposal,
      })
    end
  end,
}

function data()
  return script
end
