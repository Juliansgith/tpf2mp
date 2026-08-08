-- Disposable-world console probe. This file is copied only into the temporary
-- base-resource validation route and is never installed as part of the mod.
local json
for _, moduleName in ipairs({ "tpf2_mp_probe/json", "tpf2_mp/json" }) do
  local ok, value = pcall(require, moduleName)
  if ok then json = value; break end
end
if not json then error("TPF2MP disposable probe JSON module is unavailable") end

local vehicleResourceFacts
local vehicleResourceFactsError
do
  local ok, value = pcall(require, "tpf2_mp_probe/vehicle_resource_facts")
  if ok then vehicleResourceFacts = value else vehicleResourceFactsError = tostring(value) end
end

local M = {}
local sendAction

local function marker(event, values)
  local payload = { event = event }
  for key, value in pairs(values or {}) do payload[key] = value end
  local ok, encoded = pcall(json.encode, payload)
  print("[TPF2MP-CONSOLE-PROBE] " .. (ok and encoded or tostring(event)))
end

local function available(value)
  return type(value) == "function" or type(value) == "table" or type(value) == "userdata"
end

local function commandFactory(name)
  local public = api and api.cmd and api.cmd.make and api.cmd.make[name]
  if type(public) == "function" or type(public) == "table" or type(public) == "userdata" then
    return public, "public"
  end
  local mirrored = rawget(_G, "tpf2mp_native_binding_" .. tostring(name))
  if type(mirrored) == "function" or type(mirrored) == "table" or type(mirrored) == "userdata" then
    return mirrored, "native-mirror"
  end
  return nil, "unavailable"
end

local function probeVector(value, limit)
  local result = { valueType = type(value), length = nil, entries = {} }
  if type(value) ~= "table" and type(value) ~= "userdata" then return result end
  local lengthOk, length = pcall(function() return #value end)
  if lengthOk and type(length) == "number" then result.length = length end
  for index = 1, math.min(tonumber(result.length) or 0, limit or 8) do
    local readOk, entry = pcall(function() return value[index] end)
    result.entries[index] = readOk and {
      valueType = type(entry),
      scalar = (type(entry) == "string" or type(entry) == "number"
        or type(entry) == "boolean") and entry or nil,
    } or { error = tostring(entry) }
  end
  return result
end

local function probeVehicleModel(name)
  local result = { name = name }
  local repository = api and api.res and api.res.modelRep
  if not repository or not available(repository.find) or not available(repository.get) then
    result.error = "model repository unavailable"
    return result
  end
  local idOk, id = pcall(repository.find, name)
  result.modelId = idOk and tonumber(id) or nil
  if not result.modelId or result.modelId < 0 then
    result.error = idOk and "model not found" or tostring(id)
    return result
  end
  local modelOk, model = pcall(repository.get, result.modelId)
  if not modelOk or model == nil then
    result.error = tostring(model)
    return result
  end
  local function field(value, key)
    local ok, nested = pcall(function() return value and value[key] end)
    return ok and nested or nil
  end
  local metadata = field(model, "metadata")
  local transportVehicle = field(metadata, "transportVehicle")
  result.modelType = type(model)
  result.metadataType = type(metadata)
  result.transportVehicleType = type(transportVehicle)
  for _, key in ipairs({ "compartments", "compartmentsList" }) do
    local compartments = field(transportVehicle, key)
    result[key] = probeVector(compartments, 4)
    local first = field(compartments, 1)
    if first ~= nil then
      result[key].firstType = type(first)
      result[key].firstLoadConfigs = probeVector(field(first, "loadConfigs"), 4)
    end
  end
  return result
end

-- Exercise the exact production classifier against live repository userdata.
-- The surrounding capability probe copies this module without modification;
-- keeping the result compact makes it safe to persist in stdout/run-status.
local function probeProductionConsist(modelNames)
  if not (vehicleResourceFacts and type(vehicleResourceFacts.consist) == "function") then
    return { success = false, error = vehicleResourceFactsError or "classifier unavailable" }
  end
  local ok, facts = pcall(vehicleResourceFacts.consist, modelNames)
  if not ok then return { success = false, error = tostring(facts) } end
  if type(facts) ~= "table" then
    return { success = false, error = "classifier returned no facts" }
  end
  return {
    success = true,
    kind = facts.kind,
    seats = tonumber(facts.seats),
    passengerCapacity = tonumber(facts.passengerCapacity),
    cargoCapacity = tonumber(facts.cargoCapacity),
    unknownCapacity = tonumber(facts.unknownCapacity),
    limitSpeedMs = tonumber(facts.limitSpeedMs),
  }
end

local function probeVehicleTypeDefaults()
  local result = {}
  for _, name in ipairs({ "VehiclePart", "TransportVehiclePart", "TransportVehicleConfig" }) do
    local constructor = api and api.type and api.type[name] and api.type[name].new
    local ok, value = available(constructor) and pcall(constructor) or false, nil
    if available(constructor) then ok, value = pcall(constructor) end
    result[name] = { constructed = ok == true, valueType = type(value) }
    if ok and value ~= nil then
      for _, field in ipairs({ "loadConfig", "autoLoadConfig", "vehicles", "vehicleGroups" }) do
        local readOk, nested = pcall(function() return value[field] end)
        if readOk and nested ~= nil then result[name][field] = probeVector(nested, 4) end
      end
    elseif value ~= nil then
      result[name].error = tostring(value)
    end
  end
  return result
end

local function edgeObjectFactories()
  local candidates = {}
  local function add(label, factory)
    if factory and factory.new ~= nil then candidates[#candidates + 1] = { label = label, factory = factory } end
  end
  pcall(function() add("EdgeObject", api.type.EdgeObject) end)
  pcall(function() add("SimpleStreetProposal.EdgeObject", api.type.SimpleStreetProposal.EdgeObject) end)
  pcall(function() add("StreetProposal.EdgeObject", api.type.StreetProposal.EdgeObject) end)
  return candidates
end

local function constructCompatibleEdgeObject()
  local errors = {}
  for _, candidate in ipairs(edgeObjectFactories()) do
    local objectOk, object = pcall(candidate.factory.new)
    if objectOk and object ~= nil then
      local vectorOk, vectorError = pcall(function()
        local proposal = api.type.SimpleProposal.new()
        proposal.streetProposal.edgeObjectsToAdd[1] = object
        assert(proposal.streetProposal.edgeObjectsToAdd[1] ~= nil)
      end)
      if vectorOk then
        local freshOk, fresh = pcall(candidate.factory.new)
        if freshOk and fresh ~= nil then return fresh, candidate.label end
      else
        errors[#errors + 1] = candidate.label .. ": " .. tostring(vectorError)
      end
    else
      errors[#errors + 1] = candidate.label .. ": " .. tostring(object)
    end
  end
  return nil, table.concat(errors, "; ")
end

-- The Build 35924 bindings expose two generated nested EdgeObject userdata
-- types even though the documented top-level input type is absent.  Keep this
-- probe side-effect free: every attempted field write uses a fresh userdata
-- instance and is protected so a rejected generated-binding field becomes
-- evidence rather than aborting the disposable world.
local function probeEdgeObjectFactories()
  local fieldSamples = {
    entity = -2,
    id = -2,
    edgeObjectEntity = -2,
    edgeEntity = -1,
    param = 0.5,
    oneWay = true,
    left = false,
    model = "railroad/signal_path_a.mdl",
    modelId = 0,
    playerEntity = -1,
    name = "",
    category = 2,
    type = 2,
  }
  local result = {}
  for _, candidate in ipairs(edgeObjectFactories()) do
    local entry = { construct = false, fields = {} }
    local objectOk, object = pcall(candidate.factory.new)
    entry.construct = objectOk and object ~= nil
    entry.constructError = not entry.construct and tostring(object) or nil
    if entry.construct then
      local pairsOk, pairKeys = pcall(function()
        local keys = {}
        for key in pairs(object) do keys[#keys + 1] = tostring(key) end
        table.sort(keys)
        return keys
      end)
      entry.pairsSupported = pairsOk
      entry.pairKeys = pairsOk and pairKeys or nil
      for field, sample in pairs(fieldSamples) do
        local fieldEvidence = {}
        local readOk, original = pcall(function() return object[field] end)
        fieldEvidence.readable = readOk
        fieldEvidence.originalType = readOk and type(original) or nil
        if readOk and (type(original) == "string" or type(original) == "number"
          or type(original) == "boolean" or original == nil) then
          fieldEvidence.original = original
        end
        if not readOk then fieldEvidence.readError = tostring(original) end

        local freshOk, fresh = pcall(candidate.factory.new)
        local writeOk, writeError = false, "constructor failed"
        if freshOk and fresh ~= nil then
          writeOk, writeError = pcall(function() fresh[field] = sample end)
        end
        fieldEvidence.writable = writeOk
        if writeOk then
          local roundTripOk, roundTrip = pcall(function() return fresh[field] end)
          fieldEvidence.roundTripReadable = roundTripOk
          fieldEvidence.roundTripType = roundTripOk and type(roundTrip) or nil
          if roundTripOk and (type(roundTrip) == "string" or type(roundTrip) == "number"
            or type(roundTrip) == "boolean" or roundTrip == nil) then
            fieldEvidence.roundTrip = roundTrip
          end
        else
          fieldEvidence.writeError = tostring(writeError)
        end
        entry.fields[field] = fieldEvidence
      end
    end
    result[candidate.label] = entry
  end
  return result
end

function M.capabilities()
  -- A first print lets the optional native observer register its tiny status
  -- API in this exact Lua state. The second marker then proves whether that
  -- registration is callable without making the probe depend on the DLL.
  marker("native-warmup")
  local nativeStatusApi = type(tpf2mp_native_status) == "function"
  local nativeStatusOk = false
  if nativeStatusApi then
    nativeStatusOk = pcall(tpf2mp_native_status)
    if type(tpf2mp_native_mark_context) == "function" then
      pcall(tpf2mp_native_mark_context, "console-probe")
    end
  end
  local sendCommandNilRejected = false
  if nativeStatusApi and api and api.cmd and available(api.cmd.sendCommand) then
    -- This is intentionally not a valid command and cannot mutate the world.
    -- Its protected rejection proves the native wrapper called the original
    -- binding and propagated the Lua error back through the same pcall.
    sendCommandNilRejected = not pcall(api.cmd.sendCommand, nil)
  end
  local buildProposalFactory, buildProposalSource = commandFactory("buildProposal")
  local sendScriptEventFactory, sendScriptEventSource = commandFactory("sendScriptEvent")
  local setGameSpeedFactory, setGameSpeedSource = commandFactory("setGameSpeed")
  local saveGameFactory, saveGameSource = commandFactory("saveGame")
  local buildProposalCallable = false
  if buildProposalFactory and api and api.type and api.type.SimpleProposal then
    local proposalOk, proposal = pcall(api.type.SimpleProposal.new)
    if proposalOk then buildProposalCallable = pcall(buildProposalFactory, proposal, nil, false) end
  end
  local sendScriptEventCallable = sendScriptEventFactory
    and pcall(sendScriptEventFactory, "tpf2_mp.lua", "tpf2mp-probe", "noop", {}) or false
  -- Constructing a command is side-effect free; only sendCommand can apply it.
  -- Probe the likely public shape without creating a save in this disposable
  -- capability run.
  local saveGameCallable = false
  local saveGameCommandType = "unavailable"
  local saveGameError = nil
  if saveGameFactory then
    local saveOk, saveCommand = pcall(saveGameFactory, "tpf2mp_capability_probe")
    saveGameCallable = saveOk and saveCommand ~= nil
    saveGameCommandType = saveOk and type(saveCommand) or "error"
    if not saveOk then saveGameError = tostring(saveCommand) end
  end
  local mirroredBuildProposal = rawget(_G, "tpf2mp_native_binding_buildProposal")
  local mirroredSendScriptEvent = rawget(_G, "tpf2mp_native_binding_sendScriptEvent")
  local edgeObjectAvailable = api and api.type and available(api.type.EdgeObject) or false
  local edgeObjectNewType = edgeObjectAvailable and type(api.type.EdgeObject.new) or "unavailable"
  local edgeObjectConstructed, edgeObjectFieldsWritable = false, false
  if edgeObjectAvailable and api.type.EdgeObject.new ~= nil then
    local objectOk, object = pcall(api.type.EdgeObject.new)
    edgeObjectConstructed = objectOk and object ~= nil
    if edgeObjectConstructed then
      edgeObjectFieldsWritable = pcall(function()
        object.edgeEntity = -1
        object.param = 0.5
        object.oneWay = false
        object.left = false
        object.model = 0
        object.playerEntity = -1
        object.name = ""
      end)
    end
  end
  local edgeObjectPlainVectorWritable = false
  if api and api.type and api.type.SimpleProposal and api.type.SimpleProposal.new then
    edgeObjectPlainVectorWritable = pcall(function()
      local proposal = api.type.SimpleProposal.new()
      proposal.streetProposal.edgeObjectsToAdd[1] = {
        edgeEntity = -1, param = 0.5, oneWay = false, left = false,
        model = 0, playerEntity = -1, name = "",
      }
      local value = proposal.streetProposal.edgeObjectsToAdd[1]
      assert(value ~= nil)
    end)
  end
  local compatibleEdgeObject, compatibleEdgeObjectFactory = constructCompatibleEdgeObject()
  local function nestedType(first, second)
    local ok, value = pcall(function()
      local outer = api and api.type and api.type[first]
      return second and outer and outer[second] or outer
    end)
    return ok and type(value) or "error"
  end
  local apiTypeEdgeKeys = {}
  pcall(function()
    for key in pairs(api.type) do
      local name = tostring(key)
      if string.lower(name):find("edge", 1, true) then apiTypeEdgeKeys[#apiTypeEdgeKeys + 1] = name end
    end
    table.sort(apiTypeEdgeKeys)
    while #apiTypeEdgeKeys > 64 do table.remove(apiTypeEdgeKeys) end
  end)
  marker("capabilities", {
    buildVersion = api and api.util and api.util.getBuildVersion and tostring(api.util.getBuildVersion()) or "unknown",
    buildProposal = buildProposalFactory ~= nil,
    buildProposalCallable = buildProposalCallable,
    buildProposalSource = buildProposalSource,
    buildProposalType = type(buildProposalFactory),
    publicBuildProposal = api and api.cmd and api.cmd.make and available(api.cmd.make.buildProposal) or false,
    nativeMirroredBuildProposal = mirroredBuildProposal ~= nil,
    nativeMirroredBuildProposalType = type(mirroredBuildProposal),
    sendCommand = api and api.cmd and available(api.cmd.sendCommand) or false,
    sendScriptEvent = sendScriptEventFactory ~= nil,
    sendScriptEventCallable = sendScriptEventCallable,
    sendScriptEventSource = sendScriptEventSource,
    publicSendScriptEvent = api and api.cmd and api.cmd.make and available(api.cmd.make.sendScriptEvent) or false,
    nativeMirroredSendScriptEvent = mirroredSendScriptEvent ~= nil,
    nativeMirroredSendScriptEventType = type(mirroredSendScriptEvent),
    simpleProposal = api and api.type and available(api.type.SimpleProposal) or false,
    segmentAndEntity = api and api.type and available(api.type.SegmentAndEntity) or false,
    nodeAndEntity = api and api.type and available(api.type.NodeAndEntity) or false,
    constructionEntity = api and api.type and available(api.type.ConstructionEntity) or false,
    edgeObject = edgeObjectAvailable,
    edgeObjectNewType = edgeObjectNewType,
    edgeObjectConstructed = edgeObjectConstructed,
    edgeObjectFieldsWritable = edgeObjectFieldsWritable,
    edgeObjectPlainVectorWritable = edgeObjectPlainVectorWritable,
    compatibleEdgeObjectFactory = compatibleEdgeObject and compatibleEdgeObjectFactory or "unavailable",
    edgeObjectNestedTypes = {
      StreetProposal = nestedType("StreetProposal", "EdgeObject"),
      SimpleStreetProposal = nestedType("SimpleStreetProposal", "EdgeObject"),
    },
    edgeObjectFactoryProbe = probeEdgeObjectFactories(),
    apiTypeEdgeKeys = apiTypeEdgeKeys,
    mat4f = api and api.type and available(api.type.Mat4f) or false,
    vec4f = api and api.type and available(api.type.Vec4f) or false,
    terrainHeight = api and api.engine and api.engine.terrain and type(api.engine.terrain.getHeightAt) == "function" or false,
    interfaceHeight = game and game.interface and type(game.interface.getHeight) == "function" or false,
    nativeStatusApi = nativeStatusApi,
    nativeStatusOk = nativeStatusOk,
    nativeCommandObserverApi = type(tpf2mp_native_set_command_observer) == "function",
    nativeGameSpeedCaptureApi = type(tpf2mp_native_take_suppressed_game_speed) == "function",
    nativeCommandGateApi = type(tpf2mp_native_enable_command_gate) == "function"
      and type(tpf2mp_native_disable_command_gate) == "function"
      and type(tpf2mp_native_authorize_command) == "function" or false,
    setGameSpeed = setGameSpeedFactory ~= nil,
    setGameSpeedSource = setGameSpeedSource,
    saveGame = saveGameFactory ~= nil,
    saveGameCallable = saveGameCallable,
    saveGameCommandType = saveGameCommandType,
    saveGameSource = saveGameSource,
    saveGameError = saveGameError,
    sendCommandNilRejected = sendCommandNilRejected,
    vehicleConfigProbe = {
      typeDefaults = probeVehicleTypeDefaults(),
      nohab = probeVehicleModel("vehicle/train/nohab_m1_v2.mdl"),
      bc4 = probeVehicleModel("vehicle/waggon/bc4_v2.mdl"),
      open1910 = probeVehicleModel("vehicle/waggon/open_1910.mdl"),
    },
    productionTransportFacts = {
      locomotive = probeProductionConsist({ "vehicle/train/nohab_m1_v2.mdl" }),
      passenger = probeProductionConsist({
        "vehicle/train/nohab_m1_v2.mdl",
        "vehicle/waggon/bc4_v2.mdl",
        "vehicle/waggon/bc4_v2.mdl",
      }),
      freight = probeProductionConsist({
        "vehicle/train/nohab_m1_v2.mdl",
        "vehicle/waggon/open_1910.mdl",
      }),
      mixed = probeProductionConsist({
        "vehicle/train/nohab_m1_v2.mdl",
        "vehicle/waggon/bc4_v2.mdl",
        "vehicle/waggon/open_1910.mdl",
      }),
    },
  })
end

function M.runPopulatedProbe()
  M.capabilities()
  local actions = {
    { type = "probe.run", localOnly = true },
    { type = "probe.mobility", localOnly = true },
    { type = "probe.export_research", localOnly = true },
    { type = "snapshot.export", localOnly = true },
    { type = "checkpoint.export", reason = "populated-live-probe", localOnly = true },
  }
  local sent = 0
  for _, action in ipairs(actions) do
    if sendAction(action) then sent = sent + 1 end
  end
  marker("populated-probe-dispatched", { success = sent == #actions, sent = sent, expected = #actions })
  return sent == #actions
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
        local id = tonumber(value)
        if not id and (type(value) == "table" or type(value) == "userdata") then
          local entityOk, entity = pcall(function() return value.entity or value.id or value.entityId end)
          if entityOk then id = tonumber(entity) end
        end
        if id and id >= 0 and not seen[id] then
          seen[id] = true
          ids[#ids + 1] = id
        end
      end
    end
  end
  table.sort(ids)
  return ids
end

local function entitiesWith(componentType)
  local result = {}
  if not (api and api.engine and available(api.engine.forEachEntityWithComponent) and componentType) then
    return result, "entity enumeration unavailable"
  end
  local ok, err = pcall(function()
    api.engine.forEachEntityWithComponent(function(entity) result[tonumber(entity)] = true end, componentType)
  end)
  if not ok then return {}, tostring(err) end
  return result, nil
end

local function ownerOf(entity)
  if not (api and api.engine and api.engine.getComponent and api.type and api.type.ComponentType.PLAYER_OWNED) then return nil end
  local ok, owned = pcall(api.engine.getComponent, entity, api.type.ComponentType.PLAYER_OWNED)
  return ok and owned and tonumber(owned.player or owned.playerEntity) or nil
end

sendAction = function(action)
  local sendScriptEvent = commandFactory("sendScriptEvent")
  if not (sendScriptEvent and api.cmd.sendCommand) then return false end
  local command = sendScriptEvent("tpf2_mp.lua", "tpf2mp", "intent", action)
  api.cmd.sendCommand(command)
  return true
end

local function sendActionAsync(action, callback)
  local sendScriptEvent = commandFactory("sendScriptEvent")
  if not (sendScriptEvent and api.cmd.sendCommand) then
    if callback then callback(false, nil, "sendScriptEvent unavailable") end
    return false
  end
  local commandOk, commandOrError = pcall(
    sendScriptEvent, "tpf2_mp.lua", "tpf2mp", "intent", action)
  if not commandOk then
    if callback then callback(false, nil, tostring(commandOrError)) end
    return false
  end
  api.cmd.sendCommand(commandOrError, function(result, success)
    if callback then
      local commandError = nil
      if success ~= true then commandError = "script event command failed" end
      callback(success == true, result, commandError)
    end
  end)
  return true
end

local candidates = {
  { -1400, -1400 }, { 1400, -1400 }, { -1400, 1400 }, { 1400, 1400 },
  { -1000, -1200 }, { 1000, -1200 }, { -1000, 1200 }, { 1000, 1200 },
  { -600, -1400 }, { 600, -1400 }, { -600, 1400 }, { 600, 1400 },
  { -1600, 0 }, { 1600, 0 }, { 0, -1600 }, { 0, 1600 },
  { -800, -800 }, { 800, -800 }, { -800, 800 }, { 800, 800 },
}

local function terrainHeight(position, x, y)
  if api and api.engine and api.engine.terrain and type(api.engine.terrain.getHeightAt) == "function" then
    local ok, value = pcall(api.engine.terrain.getHeightAt, position)
    if ok and tonumber(value) then return tonumber(value) end
  end
  if game and game.interface and type(game.interface.getHeight) == "function" then
    for _, protocolPosition in ipairs({ { x = x, y = y }, { x, y } }) do
      local ok, value = pcall(game.interface.getHeight, protocolPosition)
      if ok and tonumber(value) then return tonumber(value) end
    end
  end
  return nil
end

local function terrainHeightAvailable()
  return api and api.engine and api.engine.terrain and type(api.engine.terrain.getHeightAt) == "function"
    or game and game.interface and type(game.interface.getHeight) == "function"
    or false
end

local function makeStreetProposal(x, y)
  local length = 80
  local first2 = api.type.Vec2f.new(x, y)
  local second2 = api.type.Vec2f.new(x + length, y)
  if api.engine.terrain.isValidCoordinate
    and (not api.engine.terrain.isValidCoordinate(first2) or not api.engine.terrain.isValidCoordinate(second2)) then
    return nil, "coordinate-outside-map"
  end
  local firstZ = terrainHeight(first2, x, y)
  local secondZ = terrainHeight(second2, x + length, y)
  if firstZ == nil or secondZ == nil then return nil, "terrain-height-unavailable" end
  local proposal = api.type.SimpleProposal.new()
  local edge = api.type.SegmentAndEntity.new()
  edge.entity = -1
  edge.comp.node0 = -2
  edge.comp.node1 = -3
  edge.comp.tangent0 = api.type.Vec3f.new(length, 0, secondZ - firstZ)
  edge.comp.tangent1 = api.type.Vec3f.new(length, 0, secondZ - firstZ)
  edge.comp.type = 0
  edge.comp.typeIndex = 0
  edge.type = 0
  edge.streetEdge = api.type.BaseEdgeStreet.new()
  edge.streetEdge.streetType = api.res.streetTypeRep.find("standard/country_small_new.lua")

  local node0 = api.type.NodeAndEntity.new()
  node0.entity = -2
  node0.comp.position = api.type.Vec3f.new(x, y, firstZ)
  local node1 = api.type.NodeAndEntity.new()
  node1.entity = -3
  node1.comp.position = api.type.Vec3f.new(x + length, y, secondZ)
  proposal.streetProposal.edgesToAdd[1] = edge
  proposal.streetProposal.nodesToAdd[1] = node0
  proposal.streetProposal.nodesToAdd[2] = node1
  return proposal
end

local function makeTrackProposal(x, y, catenary)
  local length = 80
  local first2 = api.type.Vec2f.new(x, y)
  local second2 = api.type.Vec2f.new(x + length, y)
  if api.engine.terrain.isValidCoordinate
    and (not api.engine.terrain.isValidCoordinate(first2) or not api.engine.terrain.isValidCoordinate(second2)) then
    return nil, "coordinate-outside-map"
  end
  local firstZ = terrainHeight(first2, x, y)
  local secondZ = terrainHeight(second2, x + length, y)
  if firstZ == nil or secondZ == nil then return nil, "terrain-height-unavailable" end

  local proposal = api.type.SimpleProposal.new()
  local edge = api.type.SegmentAndEntity.new()
  edge.entity = -1
  edge.comp.node0 = -2
  edge.comp.node1 = -3
  edge.comp.tangent0 = api.type.Vec3f.new(length, 0, secondZ - firstZ)
  edge.comp.tangent1 = api.type.Vec3f.new(length, 0, secondZ - firstZ)
  edge.comp.type = 0
  edge.comp.typeIndex = -1
  edge.type = 1
  edge.trackEdge = api.type.BaseEdgeTrack.new()
  edge.trackEdge.trackType = api.res.trackTypeRep.find("standard.lua")
  edge.trackEdge.catenary = catenary == true
  local playerOwned = api.type.PlayerOwned.new()
  playerOwned.player = game.interface.getPlayer()
  edge.playerOwned = playerOwned

  local node0 = api.type.NodeAndEntity.new()
  node0.entity = -2
  node0.comp.position = api.type.Vec3f.new(x, y, firstZ)
  local node1 = api.type.NodeAndEntity.new()
  node1.entity = -3
  node1.comp.position = api.type.Vec3f.new(x + length, y, secondZ)
  proposal.streetProposal.edgesToAdd[1] = edge
  proposal.streetProposal.nodesToAdd[1] = node0
  proposal.streetProposal.nodesToAdd[2] = node1
  return proposal
end

local function positiveSetDifference(after, before)
  local result = {}
  for entity in pairs(after or {}) do
    if type(entity) == "number" and entity >= 0 and not (before or {})[entity] then
      result[#result + 1] = entity
    end
  end
  table.sort(result)
  return result
end

local function trackDetails(ids)
  local result = {}
  local componentType = api and api.type and api.type.ComponentType
  for _, entity in ipairs(ids or {}) do
    local ok, component = pcall(api.engine.getComponent, entity, componentType.BASE_EDGE_TRACK)
    if ok and component then
      local trackTypeOk, trackType = pcall(function() return component.trackType end)
      local catenaryOk, catenary = pcall(function() return component.catenary end)
      result[#result + 1] = {
        entity = entity,
        trackType = trackTypeOk and tonumber(trackType) or nil,
        catenary = catenaryOk and catenary == true or false,
        owner = ownerOf(entity),
      }
    end
  end
  return result
end

local function tryTrackCandidate(index, catenary, completed)
  if index > #candidates then
    completed(false, { error = "no candidate track proposal succeeded", catenary = catenary == true })
    return
  end
  local x, y = candidates[index][1], candidates[index][2]
  local before, beforeError = entitiesWith(api.type.ComponentType.BASE_EDGE_TRACK)
  if beforeError then
    completed(false, { error = beforeError, catenary = catenary == true })
    return
  end
  local ok, proposalOrError, proposalError = pcall(makeTrackProposal, x, y, catenary)
  if not ok or not proposalOrError then
    marker("track-candidate-skipped", {
      index = index, x = x, y = y, catenary = catenary == true,
      error = tostring(ok and proposalError or proposalOrError),
    })
    tryTrackCandidate(index + 1, catenary, completed)
    return
  end
  local buildProposal = commandFactory("buildProposal")
  local commandOk, commandOrError = pcall(buildProposal, proposalOrError, nil, false)
  if not commandOk then
    marker("track-candidate-command-error", {
      index = index, x = x, y = y, catenary = catenary == true, error = tostring(commandOrError),
    })
    tryTrackCandidate(index + 1, catenary, completed)
    return
  end
  api.cmd.sendCommand(commandOrError, function(result, success)
    if success ~= true then
      marker("track-candidate-result", { index = index, catenary = catenary == true, success = false })
      tryTrackCandidate(index + 1, catenary, completed)
      return
    end
    local after, afterError = entitiesWith(api.type.ComponentType.BASE_EDGE_TRACK)
    local created = positiveSetDifference(after, before)
    local details = trackDetails(created)
    local currentPlayer = game.interface.getPlayer()
    local ownershipVerified = #details == #created
    for _, detail in ipairs(details) do
      if tonumber(detail.owner) ~= tonumber(currentPlayer) then ownershipVerified = false end
    end
    local verified = not afterError and #created > 0 and #details == #created and ownershipVerified
    marker("track-candidate-result", {
      index = index,
      x = x,
      y = y,
      catenary = catenary == true,
      success = verified,
      resultIds = resultIds(result),
      createdTrackIds = created,
      tracks = details,
      expectedOwner = currentPlayer,
      ownershipVerified = ownershipVerified,
      error = afterError,
    })
    if verified then
      completed(true, {
        index = index,
        catenary = catenary == true,
        resultIds = resultIds(result),
        createdTrackIds = created,
        tracks = details,
      })
    else
      tryTrackCandidate(index + 1, catenary, completed)
    end
  end)
end

function M.runTrackTest()
  M.capabilities()
  local componentType = api and api.type and api.type.ComponentType
  if not (commandFactory("buildProposal") ~= nil
    and api and api.cmd and available(api.cmd.sendCommand)
    and api.engine and api.engine.getComponent and api.engine.forEachEntityWithComponent
    and api.type and api.type.SimpleProposal and api.type.SegmentAndEntity and api.type.NodeAndEntity
    and api.type.BaseEdgeTrack and componentType and componentType.BASE_EDGE_TRACK
    and api.res and api.res.trackTypeRep and api.res.trackTypeRep.find
    and terrainHeightAvailable()) then
    marker("track-build-complete", { success = false, error = "required supported track proposal API is unavailable" })
    return false
  end

  tryTrackCandidate(1, false, function(normalOk, normal)
    if not normalOk then
      marker("track-build-complete", { success = false, stage = "normal", normal = normal })
      return
    end
    tryTrackCandidate((normal.index or 1) + 1, true, function(electricOk, electric)
      marker("track-build-complete", {
        success = electricOk == true,
        normal = normal,
        electrified = electric,
      })
    end)
  end)
  return true
end

local function makeSignalReplacement(edgeEntity, signalEntity, addSignal)
  local componentType = api.type.ComponentType
  local baseOk, baseEdge = pcall(api.engine.getComponent, edgeEntity, componentType.BASE_EDGE)
  local trackOk, trackEdge = pcall(api.engine.getComponent, edgeEntity, componentType.BASE_EDGE_TRACK)
  if not baseOk or not baseEdge or not trackOk or not trackEdge then
    return nil, "signal source track components are unavailable"
  end
  local proposal = api.type.SimpleProposal.new()
  local segment = api.type.SegmentAndEntity.new()
  segment.entity = -1
  segment.type = 1
  -- Reconstruct a detached SegmentAndEntity exactly like the canonical
  -- runtime materialiser. Assigning the live BASE_EDGE userdata wholesale
  -- aliases its object vector; mutating that alias leaves the native builder
  -- without a consistently typed temporary edge object.
  local function vector3(value)
    local ok, x, y, z = pcall(function()
      return value.x or value[1], value.y or value[2], value.z or value[3]
    end)
    if not ok or tonumber(x) == nil or tonumber(y) == nil or tonumber(z) == nil then return nil end
    return api.type.Vec3f.new(tonumber(x), tonumber(y), tonumber(z))
  end
  local tangent0, tangent1 = vector3(baseEdge.tangent0), vector3(baseEdge.tangent1)
  if not tangent0 or not tangent1 then return nil, "source track tangents are unavailable" end
  segment.comp.node0 = baseEdge.node0
  segment.comp.node1 = baseEdge.node1
  segment.comp.tangent0 = tangent0
  segment.comp.tangent1 = tangent1
  segment.comp.type = baseEdge.type
  segment.comp.typeIndex = baseEdge.typeIndex
  segment.trackEdge = api.type.BaseEdgeTrack.new()
  segment.trackEdge.trackType = trackEdge.trackType
  segment.trackEdge.catenary = trackEdge.catenary
  local playerOwned = api.type.PlayerOwned.new()
  playerOwned.player = game.interface.getPlayer()
  segment.playerOwned = playerOwned
  local objectReferences = {}
  local sourceObjects = baseEdge.objects
  local lengthOk, length = pcall(function() return #sourceObjects end)
  if lengthOk then
    for index = 1, tonumber(length) or 0 do
      local pairOk, objectId, category = pcall(function()
        return sourceObjects[index][1], sourceObjects[index][2]
      end)
      if pairOk and tonumber(objectId) ~= tonumber(signalEntity) then
        objectReferences[#objectReferences + 1] = { tonumber(objectId), tonumber(category) }
      end
    end
  end
  if addSignal then
    local signalType = api.type.enum and api.type.enum.EdgeObjectType
      and api.type.enum.EdgeObjectType.SIGNAL or 2
    -- Edge-object additions have their own negative vector index space.  The
    -- first object is -1 regardless of the replacement edge's temporary ID.
    -- Assign the complete pair vector, matching the supported Urban Games
    -- example. The generated BaseEdge binding's whole-vector setter performs
    -- stricter pair conversion than mutating its proxy one element at a time.
    objectReferences[#objectReferences + 1] = { -1, signalType }
    -- The disposable profile starts in the modern era; use the in-era stock
    -- signal so the probe also exercises the same resource the GUI exposes.
    local modelName = "railroad/signal_path_c.mdl"
    local modelId = api.res.modelRep.find(modelName)
    if tonumber(modelId) == nil or tonumber(modelId) < 0 then
      return nil, "stock signal model is unavailable"
    end
    -- Build 35924 exports this generated type under the proposal namespaces,
    -- not as api.type.EdgeObject in every Lua state. Select only a constructor
    -- whose userdata is accepted by SimpleProposal.edgeObjectsToAdd.
    local object, objectFactory = constructCompatibleEdgeObject()
    if not object then return nil, "compatible EdgeObject constructor is unavailable: " .. tostring(objectFactory) end
    object.edgeEntity = -1
    object.param = 0.5
    object.oneWay = false
    object.left = true
    -- The generated SimpleStreetProposal.EdgeObject binding takes the stable
    -- model filename. (The separately documented top-level EdgeObject, absent
    -- in this Lua state, uses a numeric model ID.)
    object.model = modelName
    object.playerEntity = game.interface.getPlayer()
    object.name = "TPF2MP disposable signal"
    proposal.streetProposal.edgeObjectsToAdd[1] = object
  elseif signalEntity then
    proposal.streetProposal.edgeObjectsToRemove[1] = signalEntity
  end
  segment.comp.objects = objectReferences
  proposal.streetProposal.edgesToRemove[1] = edgeEntity
  proposal.streetProposal.edgesToAdd[1] = segment
  return proposal
end

local function edgeContainingObject(objectEntity)
  local result = nil
  local ok = pcall(function()
    api.engine.forEachEntityWithComponent(function(edgeEntity)
      if result then return end
      local component = api.engine.getComponent(edgeEntity, api.type.ComponentType.BASE_EDGE)
      if component and component.objects then
        for _, pair in pairs(component.objects) do
          local readOk, localId = pcall(function() return pair[1] end)
          if readOk and tonumber(localId) == tonumber(objectEntity) then result = tonumber(edgeEntity) end
        end
      end
    end, api.type.ComponentType.BASE_EDGE_TRACK)
  end)
  return ok and result or nil
end

local function issueSignalRemoval(edgeEntity, signalEntity, addedEvidence)
  local beforeSignals, beforeError = entitiesWith(api.type.ComponentType.SIGNAL_LIST)
  if beforeError then
    marker("signal-build-complete", { success = false, stage = "remove-snapshot", error = beforeError })
    return
  end
  local proposal, proposalError = makeSignalReplacement(edgeEntity, signalEntity, false)
  if not proposal then
    marker("signal-build-complete", { success = false, stage = "remove-materialise", error = proposalError })
    return
  end
  local factory = commandFactory("buildProposal")
  local commandOk, commandOrError = pcall(factory, proposal, nil, false)
  if not commandOk then
    marker("signal-build-complete", { success = false, stage = "remove-command", error = tostring(commandOrError) })
    return
  end
  api.cmd.sendCommand(commandOrError, function(result, success)
    local afterSignals, afterError = entitiesWith(api.type.ComponentType.SIGNAL_LIST)
    local removed = beforeSignals and beforeSignals[signalEntity] == true
      and afterSignals and afterSignals[signalEntity] ~= true
    marker("signal-build-complete", {
      success = success == true and not afterError and removed == true,
      stage = "complete",
      added = addedEvidence,
      removedSignal = signalEntity,
      removalObserved = removed == true,
      resultIds = resultIds(result),
      error = afterError,
    })
  end)
end

local function issueSignalAddition(trackEntity, trackEvidence)
  local beforeSignals, beforeError = entitiesWith(api.type.ComponentType.SIGNAL_LIST)
  if beforeError then
    marker("signal-build-complete", { success = false, stage = "add-snapshot", error = beforeError })
    return
  end
  local proposal, proposalError = makeSignalReplacement(trackEntity, nil, true)
  if not proposal then
    marker("signal-build-complete", { success = false, stage = "add-materialise", error = proposalError })
    return
  end
  local factory = commandFactory("buildProposal")
  local commandOk, commandOrError = pcall(factory, proposal, nil, false)
  if not commandOk then
    marker("signal-build-complete", { success = false, stage = "add-command", error = tostring(commandOrError) })
    return
  end
  api.cmd.sendCommand(commandOrError, function(result, success)
    if success ~= true then
      marker("signal-build-complete", { success = false, stage = "add-native", resultIds = resultIds(result) })
      return
    end
    local afterSignals, afterError = entitiesWith(api.type.ComponentType.SIGNAL_LIST)
    local created = afterSignals and positiveSetDifference(afterSignals, beforeSignals) or {}
    local signalEntity = created[1]
    local carrierEdge = signalEntity and edgeContainingObject(signalEntity) or nil
    local expectedOwner = game.interface.getPlayer()
    local signalOwner = signalEntity and ownerOf(signalEntity) or nil
    local edgeOwner = carrierEdge and ownerOf(carrierEdge) or nil
    local verified = not afterError and #created == 1 and carrierEdge ~= nil
      and tonumber(signalOwner) == tonumber(expectedOwner)
      and tonumber(edgeOwner) == tonumber(expectedOwner)
    local evidence = {
      track = trackEvidence,
      createdSignalIds = created,
      signalEntity = signalEntity,
      carrierEdge = carrierEdge,
      signalOwner = signalOwner,
      edgeOwner = edgeOwner,
      expectedOwner = expectedOwner,
      resultIds = resultIds(result),
    }
    marker("signal-add-result", {
      success = verified, evidence = evidence, error = afterError,
    })
    if not verified then
      marker("signal-build-complete", {
        success = false, stage = "add-postcondition", added = evidence, error = afterError,
      })
      return
    end
    issueSignalRemoval(carrierEdge, signalEntity, evidence)
  end)
end

function M.runSignalTest()
  M.capabilities()
  local types = api and api.type and api.type.ComponentType or {}
  if not (commandFactory("buildProposal") ~= nil
    and api and api.cmd and available(api.cmd.sendCommand)
    and api.engine and api.engine.getComponent and api.engine.forEachEntityWithComponent
    and api.type and api.type.SimpleProposal and api.type.SegmentAndEntity
    and api.type.NodeAndEntity and api.type.PlayerOwned and api.type.Vec3f
    and api.type.BaseEdgeTrack
    and types.BASE_EDGE and types.BASE_EDGE_TRACK and types.SIGNAL_LIST
    and api.res and api.res.trackTypeRep and api.res.modelRep
    and api.res.trackTypeRep.find and api.res.modelRep.find
    and terrainHeightAvailable()) then
    marker("signal-build-complete", {
      success = false, stage = "capabilities",
      error = "required signal BuildProposal surface is unavailable",
    })
    return false
  end
  tryTrackCandidate(1, false, function(trackOk, track)
    if not trackOk or #(track.createdTrackIds or {}) ~= 1 then
      marker("signal-build-complete", { success = false, stage = "source-track", track = track })
      return
    end
    issueSignalAddition(track.createdTrackIds[1], track)
  end)
  return true
end

local function guiMethod(control, name)
  local ok, value = pcall(function() return control[name] end)
  return ok and type(value) == "function" and value or nil, ok and type(value) or "error"
end

local function guiRect(control)
  local getContentRect = guiMethod(control, "getContentRect")
  if not getContentRect then return nil end
  local ok, rect = pcall(getContentRect, control)
  if not ok or rect == nil then return nil end
  local result = {}
  for _, field in ipairs({ "x", "y", "w", "h", "width", "height", "left", "top", "right", "bottom" }) do
    local readOk, value = pcall(function() return rect[field] end)
    if readOk and type(value) == "number" then result[field] = value end
  end
  return next(result) and result or { valueType = type(rect), string = tostring(rect) }
end

local function guiMethodTypes(control)
  local result = {}
  for _, name in ipairs({
    "click", "toggle", "setSelected", "isSelected", "getParent",
    "getContentRect", "getPosition", "getMinimumSize", "getNumChildren",
    "getChild", "getChildren", "getId",
  }) do
    local _, methodType = guiMethod(control, name)
    result[name] = methodType
  end
  return result
end

local function guiRelatives(control)
  local result = { parents = {}, children = {} }
  local current = control
  for depth = 1, 12 do
    local getParent = guiMethod(current, "getParent")
    if not getParent then break end
    local ok, parent = pcall(getParent, current)
    if not ok or parent == nil then break end
    local entry = { depth = depth, methods = guiMethodTypes(parent), rect = guiRect(parent) }
    local getId = guiMethod(parent, "getId")
    if getId then
      local idOk, id = pcall(getId, parent)
      if idOk and type(id) == "string" then entry.id = id end
    end
    result.parents[#result.parents + 1] = entry
    current = parent
  end
  local getNumChildren = guiMethod(control, "getNumChildren")
  local getChild = guiMethod(control, "getChild")
  if getNumChildren and getChild then
    local countOk, count = pcall(getNumChildren, control)
    if countOk and type(count) == "number" then
      for index = 0, math.min(count - 1, 8) do
        local childOk, child = pcall(getChild, control, index)
        if childOk and child ~= nil then
          result.children[#result.children + 1] = {
            index = index,
            methods = guiMethodTypes(child),
            rect = guiRect(child),
          }
        end
      end
    end
  end
  return result
end

local function guiLogicalClick(controlInfo)
  local target = controlInfo and controlInfo.rect
  if not target or type(target.x) ~= "number" or type(target.y) ~= "number"
    or type(target.w) ~= "number" or type(target.h) ~= "number"
    or target.w <= 0 or target.h <= 0 then return nil end
  local root = target
  local rootArea = (tonumber(root.w) or 0) * (tonumber(root.h) or 0)
  for _, parent in ipairs(controlInfo.relatives and controlInfo.relatives.parents or {}) do
    local rect = parent.rect
    local area = rect and (tonumber(rect.w) or 0) * (tonumber(rect.h) or 0) or 0
    if area > rootArea then root, rootArea = rect, area end
  end
  if type(root.w) ~= "number" or type(root.h) ~= "number"
    or root.w <= 0 or root.h <= 0 then return nil end
  return {
    x = target.x + target.w * 0.5,
    y = target.y + target.h * 0.5,
    width = root.w,
    height = root.h,
  }
end

local function guiControlInfo(id, activate)
  local result = { id = id, exists = false, activated = false }
  if not (api and api.gui and api.gui.util and api.gui.util.getById) then
    result.error = "api.gui.util.getById unavailable"
    return result
  end
  local findOk, control = pcall(api.gui.util.getById, id)
  result.exists = findOk and control ~= nil
  if not result.exists then
    result.error = findOk and "control not found" or tostring(control)
    return result
  end
  local click, clickType = guiMethod(control, "click")
  local toggle, toggleType = guiMethod(control, "toggle")
  local setSelected, setSelectedType = guiMethod(control, "setSelected")
  local isSelected, isSelectedType = guiMethod(control, "isSelected")
  result.clickType = clickType
  result.toggleType = toggleType
  result.setSelectedType = setSelectedType
  result.isSelectedType = isSelectedType
  result.rect = guiRect(control)
  result.relatives = guiRelatives(control)
  if isSelected then
    local selectedOk, selected = pcall(isSelected, control)
    if selectedOk and type(selected) == "boolean" then result.selectedBefore = selected end
  end
  if activate then
    local activationOk, activationError
    if click then
      result.activationMethod = "click"
      activationOk, activationError = pcall(click, control)
    elseif toggle then
      result.activationMethod = "toggle"
      activationOk, activationError = pcall(toggle, control)
    elseif setSelected then
      result.activationMethod = "setSelected"
      -- Generated ToggleButton bindings in build 35924 accept the selected
      -- state as their only required argument.  Their native callback makes
      -- the construction toolbar advance just like a physical selection.
      activationOk, activationError = pcall(setSelected, control, true)
    else
      activationOk, activationError = false, "no activation method exposed"
    end
    result.activated = activationOk == true
    -- Keep the historical key in evidence so older analysis scripts remain
    -- able to consume captures made by this newer probe.
    result.clicked = result.activated
    if not activationOk then result.error = tostring(activationError) end
    if isSelected then
      local selectedOk, selected = pcall(isSelected, control)
      if selectedOk and type(selected) == "boolean" then result.selectedAfter = selected end
    end
  end
  for _, descriptor in ipairs({
    { "visible", "isVisible" }, { "enabled", "isEnabled" },
  }) do
    local readOk, value = pcall(function()
      local getter = control[descriptor[2]]
      return type(getter) == "function" and getter(control) or nil
    end)
    if readOk and type(value) == "boolean" then result[descriptor[1]] = value end
  end
  return result
end

-- Prepares a genuine GUI signal placement on a disposable track. The runner
-- performs the final physical map click; live_probe_bootstrap captures the
-- game's own proposal before it commits, giving us an exact reference payload
-- without guessing generated binding details.
function M.runSignalGuiSetup()
  M.capabilities()
  if not (api and api.gui and api.gui.util and api.gui.util.getById
    and game and game.gui and type(game.gui.setCamera) == "function") then
    marker("signal-gui-rail-ready", {
      success = false, error = "GUI control or camera API unavailable in console state",
      apiGui = api and api.gui ~= nil or false,
      gameGui = game and game.gui ~= nil or false,
    })
    return false
  end
  tryTrackCandidate(1, false, function(trackOk, track)
    if not trackOk or #(track.createdTrackIds or {}) ~= 1 then
      marker("signal-gui-rail-ready", { success = false, stage = "source-track", track = track })
      return
    end
    local trackEntity = track.createdTrackIds[1]
    local cameraOk, cameraError = pcall(game.gui.setCamera, trackEntity)
    local control = guiControlInfo("menu.construction.rail", true)
    marker("signal-gui-rail-ready", {
      success = cameraOk and control.activated == true,
      stage = control.activated and "rail-menu-open" or "select-rail-menu",
      trackEntity = trackEntity,
      cameraFocused = cameraOk,
      cameraError = not cameraOk and tostring(cameraError) or nil,
      control = control,
    })
  end)
  return true
end

-- These two stages deliberately run in later console invocations.  The game
-- instantiates and lays out the category and item widgets on subsequent UI
-- frames; querying all three controls synchronously yields zero-sized generic
-- components even though the first toolbar toggle succeeded.
function M.selectSignalGuiCategory()
  local control = guiControlInfo("menu.construction.rail.signals", true)
  marker("signal-gui-category-ready", {
    success = control.activated == true or guiLogicalClick(control) ~= nil,
    stage = control.activated and "signal-category-open" or "physical-category-click-required",
    control = control,
    physicalClickRequired = control.activated ~= true,
    logicalClick = guiLogicalClick(control),
  })
  return control.activated == true or guiLogicalClick(control) ~= nil
end

function M.selectSignalGuiItem()
  local control = guiControlInfo(
    "menu.construction.rail.signals.item.railroad/signal_path_c.mdl", true)
  marker("signal-gui-ready", {
    success = control.activated == true or guiLogicalClick(control) ~= nil,
    stage = control.activated and "await-map-click" or "physical-item-click-required",
    control = control,
    physicalClickRequired = control.activated ~= true,
    logicalClick = guiLogicalClick(control),
    mapClick = { x = 960, y = 500, width = 1920, height = 1080 },
  })
  return control.activated == true or guiLogicalClick(control) ~= nil
end

local facilityComponents = {
  construction = "CONSTRUCTION",
  asset = "ASSET_GROUP",
  depot = "VEHICLE_DEPOT",
  station = "STATION",
  stationGroup = "STATION_GROUP",
  track = "BASE_EDGE_TRACK",
}

local function facilitySnapshot()
  local result = {}
  local componentType = api and api.type and api.type.ComponentType or {}
  for name, componentName in pairs(facilityComponents) do
    local resolved = componentType[componentName]
    if resolved then
      local ids, err = entitiesWith(resolved)
      if err then return nil, err end
      result[name] = ids
    else
      -- ASSET_GROUP is optional in the public type table. A portable asset is
      -- still live-verifiable through its required CONSTRUCTION root.
      result[name] = {}
    end
  end
  return result
end

local function facilityDelta(after, before)
  local result = {}
  for name in pairs(facilityComponents) do
    result[name] = positiveSetDifference(after[name], before[name])
  end
  return result
end

local function facilityIds(delta)
  local ids, seen = {}, {}
  for _, name in ipairs({ "construction", "asset", "depot", "station", "stationGroup", "track" }) do
    for _, entity in ipairs(delta[name] or {}) do
      if not seen[entity] then seen[entity] = true; ids[#ids + 1] = entity end
    end
  end
  table.sort(ids)
  return ids
end

local function facilityContains(snapshot, entity)
  entity = tonumber(entity)
  if not entity then return false end
  for name in pairs(facilityComponents) do
    if snapshot and snapshot[name] and snapshot[name][entity] then return true end
  end
  return false
end

local function constructionDetails(ids)
  local result = {}
  local componentType = api and api.type and api.type.ComponentType
  for _, entity in ipairs(ids or {}) do
    local ok, component = pcall(api.engine.getComponent, entity, componentType.CONSTRUCTION)
    if ok and component then
      local fileOk, fileName = pcall(function() return component.fileName end)
      result[#result + 1] = {
        entity = entity,
        fileName = fileOk and tostring(fileName or "") or "",
        owner = ownerOf(entity),
      }
    end
  end
  return result
end

local function interfaceEntityDetails(ids)
  local result = {}
  for _, entity in ipairs(ids or {}) do
    local ok, value = pcall(game.interface.getEntity, entity)
    if ok and value then
      local fileOk, fileName = pcall(function() return value.fileName end)
      local typeOk, entityType = pcall(function() return value.type end)
      result[#result + 1] = {
        entity = entity,
        fileName = fileOk and tostring(fileName or "") or "",
        entityType = typeOk and tostring(entityType or "") or "",
        owner = ownerOf(entity),
      }
    end
  end
  return result
end

-- ASSET_DEFAULT constructions are represented by an ASSET_GROUP root rather
-- than a CONSTRUCTION component.  game.interface.getEntity exposes the root
-- type but not the source .con filename, so prove an asset mutation through
-- the rendered-model component instead.  This is part of the documented ECS
-- surface: MODEL_INSTANCE_LIST contains thinInstances/fatInstances and every
-- instance exposes its modelId.
local function boundedValues(values, maximum)
  local result = {}
  if values == nil then return result end
  maximum = maximum or 256
  if type(values) == "table" then
    local keys = {}
    for key in pairs(values) do keys[#keys + 1] = key end
    table.sort(keys, function(left, right)
      if type(left) == type(right) then return left < right end
      return tostring(left) < tostring(right)
    end)
    for _, key in ipairs(keys) do
      if #result >= maximum then break end
      result[#result + 1] = values[key]
    end
    return result
  end
  if type(values) == "userdata" then
    local lengthOk, length = pcall(function() return #values end)
    if lengthOk and tonumber(length) then
      for index = 1, math.min(maximum, math.max(0, math.floor(tonumber(length)))) do
        local itemOk, item = pcall(function() return values[index] end)
        if itemOk then result[#result + 1] = item end
      end
    end
  end
  return result
end

local function assetModelDetails(ids)
  local result = {}
  local componentType = api and api.type and api.type.ComponentType
  local modelType = componentType and componentType.MODEL_INSTANCE_LIST
  local modelRep = api and api.res and api.res.modelRep
  for _, entity in ipairs(ids or {}) do
    local entry = { entity = entity, thin = {}, fat = {}, modelIds = {}, modelNames = {} }
    local componentOk, component = false, nil
    if modelType and api and api.engine and api.engine.getComponent then
      componentOk, component = pcall(api.engine.getComponent, entity, modelType)
    end
    entry.componentReadable = componentOk and component ~= nil
    if componentOk and component then
      local seenIds, seenNames = {}, {}
      for _, field in ipairs({ "thinInstances", "fatInstances" }) do
        local fieldOk, instances = pcall(function() return component[field] end)
        entry[field == "thinInstances" and "thinReadable" or "fatReadable"] = fieldOk
        for _, instance in ipairs(fieldOk and boundedValues(instances, 512) or {}) do
          local modelOk, modelId = pcall(function() return instance.modelId end)
          modelId = modelOk and tonumber(modelId) or nil
          local modelName = nil
          if modelId and modelRep and available(modelRep.getName) then
            local nameOk, name = pcall(modelRep.getName, modelId)
            if nameOk and name ~= nil then modelName = tostring(name) end
          end
          local details = { modelId = modelId, modelName = modelName }
          entry[field == "thinInstances" and "thin" or "fat"][#entry[field == "thinInstances" and "thin" or "fat"] + 1] = details
          if modelId and not seenIds[modelId] then
            seenIds[modelId] = true
            entry.modelIds[#entry.modelIds + 1] = modelId
          end
          if modelName and modelName ~= "" and not seenNames[modelName] then
            seenNames[modelName] = true
            entry.modelNames[#entry.modelNames + 1] = modelName
          end
        end
      end
      table.sort(entry.modelIds)
      table.sort(entry.modelNames)
    end
    result[#result + 1] = entry
  end
  return result
end

local function modelDetailsContain(details, modelName)
  for _, root in ipairs(details or {}) do
    for _, observed in ipairs(root.modelNames or {}) do
      if observed == modelName then return true end
    end
  end
  return false
end

local function ownerDetails(ids)
  local result = {}
  for _, entity in ipairs(ids or {}) do
    local owner = ownerOf(entity)
    if owner ~= nil then result[#result + 1] = { entity = entity, owner = owner } end
  end
  return result
end

local function tryFacilityCandidate(spec, index, completed)
  if index > #candidates then
    completed(false, { kind = spec.kind, error = "no construction candidate succeeded" })
    return
  end
  local x, y = candidates[index][1], candidates[index][2]
  local before, beforeError = facilitySnapshot()
  if not before then completed(false, { kind = spec.kind, error = beforeError }); return end
  sendActionAsync({
    type = "probe.build_construction",
    kind = spec.kind,
    x = x,
    y = y,
    localOnly = true,
  }, function(commandSuccess, result, commandError)
    if not commandSuccess then
      marker("facility-candidate-result", {
        kind = spec.kind, index = index, x = x, y = y,
        success = false, commandSuccess = false, error = commandError,
      })
      tryFacilityCandidate(spec, index + 1, completed)
      return
    end
    local after, afterError = facilitySnapshot()
    local delta = after and facilityDelta(after, before) or {}
    local ids = facilityIds(delta)
    local owners = ownerDetails(ids)
    local expectedOwner = game.interface.getPlayer()
    local rootKind = spec.kind == "asset" and "asset" or "construction"
    local rootValues = delta[rootKind] or {}
    local constructionId = #rootValues == 1 and rootValues[1] or nil
    local rootOwner = constructionId and ownerOf(constructionId) or nil
    local ownerOk = constructionId ~= nil and tonumber(rootOwner) == tonumber(expectedOwner)
    for _, detail in ipairs(owners) do
      if tonumber(detail.owner) ~= tonumber(expectedOwner) then ownerOk = false end
    end
    local shapeOk = constructionId ~= nil
      and (spec.kind == "asset" or #(delta.track or {}) > 0)
      and (spec.kind ~= "depot" or #(delta.depot or {}) > 0)
      and (spec.kind ~= "station" or (#(delta.station or {}) > 0 and #(delta.stationGroup or {}) > 0))
    local verified = not afterError and shapeOk and ownerOk
    marker("facility-candidate-result", {
      kind = spec.kind, index = index, x = x, y = y,
      success = verified, commandSuccess = true, resultIds = resultIds(result),
      delta = delta, owners = owners, expectedOwner = expectedOwner,
      constructionId = constructionId, constructionOwner = rootOwner,
      construction = constructionDetails(delta.construction),
      rootKind = rootKind, root = interfaceEntityDetails(rootValues),
      shapeVerified = shapeOk, ownershipVerified = ownerOk, error = afterError,
    })
    if verified then
      completed(true, {
        kind = spec.kind, index = index, delta = delta,
        ids = ids, owners = owners, expectedOwner = expectedOwner,
        constructionId = constructionId, rootKind = rootKind,
      })
    else
      -- A partial native delta is not retried: doing so would leave additional
      -- facilities in the world and make custody attribution ambiguous. A
      -- zero delta is also final because script-event command success cannot
      -- distinguish placement rejection from an engine-side parameter fault.
      completed(false, {
        kind = spec.kind, index = index, error = "construction shape/ownership verification failed",
        delta = delta, owners = owners, expectedOwner = expectedOwner,
      })
    end
  end)
end

local function verifyOwners(ids, expectedOwner, expectDesk)
  local details = ownerDetails(ids)
  if #details == 0 then return false, details, "no player-owned facility entities remain observable" end
  local firstOwner = tonumber(details[1].owner)
  for _, detail in ipairs(details) do
    local owner = tonumber(detail.owner)
    if expectDesk then
      if owner ~= tonumber(expectedOwner) then return false, details, "facility was not fully leased to the desk" end
    elseif owner == tonumber(expectedOwner) or owner ~= firstOwner then
      return false, details, "facility did not return atomically to one non-desk company"
    end
  end
  return true, details, nil
end

local function runFacilityCycles(facilities, completed)
  local allIds, seen = {}, {}
  for _, facility in ipairs(facilities) do
    for _, entity in ipairs(facility.ids or {}) do
      if not seen[entity] then seen[entity] = true; allIds[#allIds + 1] = entity end
    end
  end
  table.sort(allIds)
  local desk = game.interface.getPlayer()
  sendActionAsync({ type = "company.cycle", localOnly = true }, function(firstOk, _, firstError)
    local returnedOk, returnedOwners, returnedError = verifyOwners(allIds, desk, false)
    if not firstOk or not returnedOk then
      completed(false, {
        success = false, stage = "first-return", error = firstError or returnedError,
        facilities = facilities, owners = returnedOwners,
      })
      return
    end
    sendActionAsync({ type = "company.cycle", localOnly = true }, function(secondOk, _, secondError)
      local leasedOk, leasedOwners, leasedError = verifyOwners(allIds, desk, true)
      if not secondOk or not leasedOk then
        completed(false, {
          success = false, stage = "rightful-edge-precondition", error = secondError or leasedError,
          facilities = facilities, returnedOwners = returnedOwners, owners = leasedOwners,
        })
        return
      end
      sendActionAsync({ type = "company.cycle", localOnly = true }, function(thirdOk, _, thirdError)
        local returnedAgainOk, returnedAgainOwners, returnedAgainError = verifyOwners(allIds, desk, false)
        if not thirdOk or not returnedAgainOk then
          completed(false, {
            success = false, stage = "second-return", error = thirdError or returnedAgainError,
            facilities = facilities, owners = returnedAgainOwners,
          })
          return
        end
        sendActionAsync({ type = "company.cycle", localOnly = true }, function(fourthOk, _, fourthError)
          local leasedAgainOk, leasedAgainOwners, leasedAgainError = verifyOwners(allIds, desk, true)
          completed(fourthOk and leasedAgainOk, {
            success = fourthOk and leasedAgainOk,
            stage = fourthOk and leasedAgainOk and "complete" or "second-rightful-edge-precondition",
            error = fourthError or leasedAgainError,
            facilities = facilities,
            firstReturnOwners = returnedOwners,
            firstLeaseOwners = leasedOwners,
            secondReturnOwners = returnedAgainOwners,
            secondLeaseOwners = leasedAgainOwners,
            cycles = 4,
          })
        end)
      end)
    end)
  end)
end

local function refreshFacilityAfterMutation(facility, after, added)
  local current = {
    kind = facility.kind,
    index = facility.index,
    expectedOwner = facility.expectedOwner,
    rootKind = facility.rootKind or (facility.kind == "asset" and "asset" or "construction"),
    delta = {},
  }
  for name in pairs(facilityComponents) do
    local values, seen = {}, {}
    for _, entity in ipairs((facility.delta and facility.delta[name]) or {}) do
      if after[name] and after[name][entity] and not seen[entity] then
        seen[entity] = true
        values[#values + 1] = entity
      end
    end
    for _, entity in ipairs((added and added[name]) or {}) do
      if after[name] and after[name][entity] and not seen[entity] then
        seen[entity] = true
        values[#values + 1] = entity
      end
    end
    table.sort(values)
    current.delta[name] = values
  end
  current.ids = facilityIds(current.delta)
  local roots = current.delta[current.rootKind] or {}
  current.constructionId = #roots == 1 and roots[1] or nil
  current.owners = ownerDetails(current.ids)
  return current
end

local function verifyMutatedFacilityOwners(facility, expectedOwner)
  if not facility.constructionId
    or tonumber(ownerOf(facility.constructionId)) ~= tonumber(expectedOwner) then
    return false
  end
  for _, detail in ipairs(facility.owners or {}) do
    if tonumber(detail.owner) ~= tonumber(expectedOwner) then return false end
  end
  return true
end

local function upgradeFacility(facility, completed)
  local before, beforeError = facilitySnapshot()
  if not before then completed(false, nil, { error = beforeError }); return end
  local beforeTracks = trackDetails(facility.delta and facility.delta.track or {})
  local beforeAssetModels = facility.kind == "asset"
    and assetModelDetails(facility.delta and facility.delta.asset or {}) or nil
  sendActionAsync({
    type = "probe.mutate_construction",
    kind = facility.kind,
    mode = "upgrade",
    localEntityId = facility.constructionId,
    codecReplay = facility.kind == "station",
    localOnly = true,
  }, function(commandSuccess, result, commandError)
    local after, afterError = facilitySnapshot()
    local added = after and facilityDelta(after, before) or {}
    local removed = after and facilityDelta(before, after) or {}
    local current = after and refreshFacilityAfterMutation(facility, after, added) or nil
    local expectedOwner = game.interface.getPlayer()
    local ownerOk = current and verifyMutatedFacilityOwners(current, expectedOwner) or false
    local shapeOk, mutationOk, details = false, false, {}
    if current and facility.kind == "station" then
      details.tracks = trackDetails(current.delta.track)
      local allCatenary = #details.tracks > 0
      for _, track in ipairs(details.tracks) do
        if track.catenary ~= true then allCatenary = false end
      end
      local originallyUnpowered = #beforeTracks > 0
      for _, track in ipairs(beforeTracks) do
        if track.catenary == true then originallyUnpowered = false end
      end
      shapeOk = current.constructionId ~= nil
        and #(current.delta.station or {}) > 0
        and #(current.delta.stationGroup or {}) > 0
        and #(current.delta.track or {}) > 0
      mutationOk = originallyUnpowered and allCatenary
    elseif current and facility.kind == "asset" then
      details.root = interfaceEntityDetails(current.delta.asset)
      details.beforeModels = beforeAssetModels
      details.afterModels = assetModelDetails(current.delta.asset)
      shapeOk = current.constructionId ~= nil
        and #details.root == 1
        and #details.afterModels == 1
        and details.afterModels[1].componentReadable == true
      local oldModel = "asset/bench_old.mdl"
      local newModel = "asset/bench_new.mdl"
      mutationOk = modelDetailsContain(details.beforeModels, oldModel)
        and not modelDetailsContain(details.beforeModels, newModel)
        and modelDetailsContain(details.afterModels, newModel)
        and not modelDetailsContain(details.afterModels, oldModel)
    end
    local verified = commandSuccess and not afterError and shapeOk and mutationOk and ownerOk
    marker("facility-mutation-result", {
      kind = facility.kind,
      mode = "upgrade",
      success = verified,
      commandSuccess = commandSuccess,
      resultIds = resultIds(result),
      sourceConstructionId = facility.constructionId,
      constructionId = current and current.constructionId or nil,
      added = added,
      removed = removed,
      details = details,
      shapeVerified = shapeOk,
      mutationVerified = mutationOk,
      ownershipVerified = ownerOk,
      error = commandError or afterError,
    })
    completed(verified, current, {
      kind = facility.kind,
      mode = "upgrade",
      sourceConstructionId = facility.constructionId,
      constructionId = current and current.constructionId or nil,
      added = added,
      removed = removed,
      details = details,
      shapeVerified = shapeOk,
      mutationVerified = mutationOk,
      ownershipVerified = ownerOk,
      error = commandError or afterError,
    })
  end)
end

local function removeFacility(facility, completed)
  local before, beforeError = facilitySnapshot()
  if not before then completed(false, { error = beforeError }); return end
  sendActionAsync({
    type = "probe.mutate_construction",
    kind = facility.kind,
    mode = "remove",
    localEntityId = facility.constructionId,
    localOnly = true,
  }, function(commandSuccess, result, commandError)
    local after, afterError = facilitySnapshot()
    local removed = after and facilityDelta(before, after) or {}
    local remaining, transientStationGroups = {}, {}
    if after then
      for _, entity in ipairs(facility.ids or {}) do
        if facilityContains(after, entity) then remaining[#remaining + 1] = entity end
      end
    end
    if after and facility.kind == "station" then
      local stationGroupType = api and api.type and api.type.ComponentType.STATION_GROUP
      local transientSet = {}
      for _, groupId in ipairs(facility.delta and facility.delta.stationGroup or {}) do
        if after.stationGroup and after.stationGroup[groupId] then
          local groupOk, group = pcall(api.engine.getComponent, groupId, stationGroupType)
          local stationsOk, stations = false, nil
          if groupOk and group then
            stationsOk, stations = pcall(function() return group.stations or group.stationEntities end)
          end
          local liveStations = {}
          for _, nested in ipairs(stationsOk and boundedValues(stations, 256) or {}) do
            local nestedId = tonumber(nested)
            if not nestedId and (type(nested) == "table" or type(nested) == "userdata") then
              local nestedOk, value = pcall(function()
                return nested.entity or nested.id or nested[1]
              end)
              if nestedOk then nestedId = tonumber(value) end
            end
            if nestedId and after.station and after.station[nestedId] then
              liveStations[#liveStations + 1] = nestedId
            end
          end
          table.sort(liveStations)
          if #liveStations == 0 then
            transientSet[groupId] = true
            transientStationGroups[#transientStationGroups + 1] = {
              entity = groupId,
              empty = true,
              owner = ownerOf(groupId),
            }
          end
        end
      end
      if next(transientSet) then
        local blocking = {}
        for _, entity in ipairs(remaining) do
          if not transientSet[entity] then blocking[#blocking + 1] = entity end
        end
        remaining = blocking
      end
    end
    local rootKind = facility.rootKind or (facility.kind == "asset" and "asset" or "construction")
    local rootGone = after and not after[rootKind][facility.constructionId] or false
    local shapeOk = rootGone and #remaining == 0 and #(removed[rootKind] or {}) >= 1
    if facility.kind == "depot" then
      shapeOk = shapeOk and #(removed.depot or {}) >= 1 and #(removed.track or {}) >= 1
    elseif facility.kind == "station" then
      shapeOk = shapeOk and #(removed.station or {}) >= 1
        and (#(removed.stationGroup or {}) >= 1 or #transientStationGroups >= 1)
        and #(removed.track or {}) >= 1
    end
    local verified = commandSuccess and not afterError and shapeOk
    marker("facility-mutation-result", {
      kind = facility.kind,
      mode = "remove",
      success = verified,
      commandSuccess = commandSuccess,
      resultIds = resultIds(result),
      sourceConstructionId = facility.constructionId,
      removed = removed,
      remaining = remaining,
      transientStationGroups = transientStationGroups,
      rootGone = rootGone,
      shapeVerified = shapeOk,
      error = commandError or afterError,
    })
    completed(verified, {
      kind = facility.kind,
      mode = "remove",
      sourceConstructionId = facility.constructionId,
      removed = removed,
      remaining = remaining,
      transientStationGroups = transientStationGroups,
      rootGone = rootGone,
      shapeVerified = shapeOk,
      error = commandError or afterError,
    })
  end)
end

local function runFacilityMutations(depot, station, completed)
  local evidence = {}
  upgradeFacility(station, function(stationEditOk, editedStation, stationEdit)
    evidence.stationEdit = stationEdit
    if not stationEditOk then completed(false, "edit-station", evidence); return end
    tryFacilityCandidate({ kind = "asset" }, (station.index or 1) + 1, function(assetOk, asset)
      evidence.assetBuild = asset
      if not assetOk then completed(false, "build-asset", evidence); return end
      removeFacility(asset, function(assetRemoveOk, assetRemove)
        evidence.assetRemove = assetRemove
        if not assetRemoveOk then completed(false, "remove-asset", evidence); return end
        removeFacility(depot, function(depotRemoveOk, depotRemove)
          evidence.depotRemove = depotRemove
          if not depotRemoveOk then completed(false, "remove-depot", evidence); return end
          removeFacility(editedStation, function(stationRemoveOk, stationRemove)
            evidence.stationRemove = stationRemove
            completed(stationRemoveOk, stationRemoveOk and "complete" or "remove-station", evidence)
          end)
        end)
      end)
    end)
  end)
end

function M.runFacilityCustodyTest()
  M.capabilities()
  local componentType = api and api.type and api.type.ComponentType
  if not (commandFactory("sendScriptEvent") ~= nil
    and api and api.cmd and available(api.cmd.sendCommand)
    and api.engine and api.engine.getComponent and api.engine.forEachEntityWithComponent
    and componentType and componentType.CONSTRUCTION and componentType.VEHICLE_DEPOT
    and componentType.STATION and componentType.STATION_GROUP and componentType.BASE_EDGE_TRACK) then
    marker("facility-custody-complete", {
      success = false, stage = "capabilities", error = "required construction/custody API is unavailable",
    })
    return false
  end

  local depot = {
    kind = "depot",
  }
  local station = {
    kind = "station",
  }
  tryFacilityCandidate(depot, 1, function(depotOk, depotResult)
    if not depotOk then
      marker("facility-custody-complete", { success = false, stage = "build-depot", depot = depotResult })
      return
    end
    tryFacilityCandidate(station, (depotResult.index or 1) + 1, function(stationOk, stationResult)
      if not stationOk then
        marker("facility-custody-complete", {
          success = false, stage = "build-station", depot = depotResult, station = stationResult,
        })
        return
      end
      runFacilityCycles({ depotResult, stationResult }, function(cyclesOk, cycles)
        if not cyclesOk then
          marker("facility-custody-complete", cycles)
          return
        end
        runFacilityMutations(depotResult, stationResult, function(mutationsOk, stage, mutations)
          marker("facility-custody-complete", {
            success = mutationsOk,
            stage = stage,
            facilities = { depotResult, stationResult },
            custody = cycles,
            mutations = mutations,
            cycles = 4,
          })
        end)
      end)
    end)
  end)
  return true
end

local function tryCandidate(index, followup)
  if index > #candidates then
    marker("build-complete", { success = false, error = "no candidate road proposal succeeded" })
    return
  end
  local x, y = candidates[index][1], candidates[index][2]
  local ok, proposalOrError, proposalError = pcall(makeStreetProposal, x, y)
  if not ok or not proposalOrError then
    marker("candidate-skipped", { index = index, x = x, y = y, error = tostring(ok and proposalError or proposalOrError) })
    tryCandidate(index + 1, followup)
    return
  end
  local buildProposal = commandFactory("buildProposal")
  local commandOk, commandOrError = pcall(buildProposal, proposalOrError, nil, false)
  if not commandOk then
    marker("candidate-command-error", { index = index, x = x, y = y, error = tostring(commandOrError) })
    tryCandidate(index + 1, followup)
    return
  end
  api.cmd.sendCommand(commandOrError, function(result, success)
    local ids = resultIds(result)
    marker("candidate-result", { index = index, x = x, y = y, success = success == true, resultIds = ids })
    if success == true then
      local followupQueued = false
      if followup ~= false then
        sendAction({
          type = "native.observed",
          observation = "console.buildProposal",
          ids = ids,
          localOnly = true,
        })
        sendAction({ type = "company.reconcile", localOnly = true })
        sendAction({ type = "probe.run", localOnly = true })
        sendAction({ type = "probe.export_research", localOnly = true })
        followupQueued = true
      end
      marker("build-complete", { success = true, index = index, resultIds = ids, followupQueued = followupQueued })
    else
      tryCandidate(index + 1, followup)
    end
  end)
end

local function tryOwnershipCandidate(index, proposalMode)
  local completeEvent = proposalMode and "proposal-ownership-test-complete" or "ownership-test-complete"
  local dispatchEvent = proposalMode and "proposal-ownership-test" or "ownership-test"
  if index > #candidates then
    marker(completeEvent, { success = false, error = "no candidate road proposal succeeded" })
    return
  end
  local x, y = candidates[index][1], candidates[index][2]
  local ok, proposalOrError, proposalError = pcall(makeStreetProposal, x, y)
  if not ok or not proposalOrError then
    marker("candidate-skipped", { index = index, x = x, y = y, error = tostring(ok and proposalError or proposalOrError) })
    tryOwnershipCandidate(index + 1, proposalMode)
    return
  end
  local buildProposal = commandFactory("buildProposal")
  local commandOk, commandOrError = pcall(buildProposal, proposalOrError, nil, false)
  if not commandOk then
    marker("candidate-command-error", { index = index, x = x, y = y, error = tostring(commandOrError) })
    tryOwnershipCandidate(index + 1, proposalMode)
    return
  end
  api.cmd.sendCommand(commandOrError, function(result, success)
    if success ~= true then tryOwnershipCandidate(index + 1, proposalMode); return end
    local resultEntityIds = resultIds(result)
    local sendScriptEvent = commandFactory("sendScriptEvent")
    if not sendScriptEvent then
      marker(completeEvent, { success = false, error = "sendScriptEvent unavailable", stage = "dispatch" })
      return
    end
    local eventOk, eventOrError = pcall(
      sendScriptEvent,
      "tpf2_mp_probe.lua",
      "tpf2mp-probe",
      dispatchEvent,
      { resultIds = resultEntityIds, candidate = index, x = x, y = y }
    )
    if not eventOk then
      marker(completeEvent, {
        success = false,
        error = tostring(eventOrError),
        stage = "dispatch-command",
      })
      return
    end
    api.cmd.sendCommand(eventOrError)
    marker(proposalMode and "proposal-ownership-test-dispatched" or "ownership-test-dispatched", {
      buildSuccess = true,
      candidate = index,
      resultIds = resultEntityIds,
    })
  end)
end

function M.runOwnershipTest()
  M.capabilities()
  if not (commandFactory("buildProposal") ~= nil and commandFactory("sendScriptEvent") ~= nil
    and api and api.cmd and available(api.cmd.sendCommand)
    and api.type and api.type.SimpleProposal and api.type.SegmentAndEntity and api.type.NodeAndEntity
    and terrainHeightAvailable()) then
    marker("ownership-test-complete", { success = false, error = "supported GUI dispatch API unavailable" })
    return false
  end
  tryOwnershipCandidate(1, false)
  return true
end

function M.runProposalOwnershipTest()
  M.capabilities()
  local sendScriptEvent = commandFactory("sendScriptEvent")
  if not (sendScriptEvent and api and api.cmd and available(api.cmd.sendCommand)) then
    marker("proposal-ownership-test-complete", {
      success = false,
      error = "supported proposal ownership dispatch API unavailable",
    })
    return false
  end
  local commandOk, commandOrError = pcall(
    sendScriptEvent,
    "tpf2_mp_probe.lua",
    "tpf2mp-probe",
    "proposal-ownership-test",
    { resultIds = {} }
  )
  if not commandOk then
    marker("proposal-ownership-test-complete", {
      success = false,
      error = tostring(commandOrError),
      stage = "dispatch-command",
    })
    return false
  end
  api.cmd.sendCommand(commandOrError)
  marker("proposal-ownership-test-dispatched", { directExistingRoad = true })
  return true
end

function M.runStationUpgradeCodecTest()
  M.capabilities()
  local sendScriptEvent = commandFactory("sendScriptEvent")
  if not (sendScriptEvent and api and api.cmd and available(api.cmd.sendCommand)) then
    marker("station-upgrade-codec-complete", {
      success = false,
      stage = "dispatch-capabilities",
      error = "supported script-event dispatch API unavailable",
    })
    return false
  end
  local commandOk, commandOrError = pcall(
    sendScriptEvent,
    "tpf2_mp_probe.lua",
    "tpf2mp-probe",
    "station-upgrade-codec-test",
    {}
  )
  if not commandOk then
    marker("station-upgrade-codec-complete", {
      success = false, stage = "dispatch-command", error = tostring(commandOrError),
    })
    return false
  end
  api.cmd.sendCommand(commandOrError, function(_, success)
    if success ~= true then
      marker("station-upgrade-codec-complete", {
        success = false, stage = "dispatch-apply", error = "script-event command failed",
      })
    end
  end)
  return true
end

function M.runVehiclePurchaseTest()
  M.capabilities()
  local sendScriptEvent = commandFactory("sendScriptEvent")
  if not (sendScriptEvent and api and api.cmd and available(api.cmd.sendCommand)) then
    marker("vehicle-purchase-codec-complete", {
      success = false,
      stage = "dispatch-capabilities",
      error = "supported script-event dispatch API unavailable",
    })
    return false
  end
  local commandOk, commandOrError = pcall(
    sendScriptEvent,
    "tpf2_mp_probe.lua",
    "tpf2mp-probe",
    "vehicle-purchase-codec-test",
    {}
  )
  if not commandOk then
    marker("vehicle-purchase-codec-complete", {
      success = false, stage = "dispatch-command", error = tostring(commandOrError),
    })
    return false
  end
  api.cmd.sendCommand(commandOrError, function(_, success)
    if success ~= true then
      marker("vehicle-purchase-codec-complete", {
        success = false, stage = "dispatch-apply", error = "script-event command failed",
      })
    end
  end)
  return true
end

local function makeCommandAt(index)
  if index > #candidates then return nil, "candidate-range" end
  local x, y = candidates[index][1], candidates[index][2]
  local ok, proposal, proposalError = pcall(makeStreetProposal, x, y)
  if not ok or not proposal then return nil, tostring(ok and proposalError or proposal) end
  local buildProposal = commandFactory("buildProposal")
  local commandOk, command = pcall(buildProposal, proposal, nil, false)
  if not commandOk then return nil, tostring(command) end
  return command
end

function M.runGateTest()
  M.capabilities()
  local enable = rawget(_G, "tpf2mp_native_enable_build_gate")
  local disable = rawget(_G, "tpf2mp_native_disable_build_gate")
  local authorize = rawget(_G, "tpf2mp_native_authorize_build")
  if type(enable) ~= "function" or type(disable) ~= "function" or type(authorize) ~= "function" then
    marker("gate-test-complete", { success = false, error = "native build-gate API unavailable" })
    return false
  end
  local blockedCommand, blockedError = makeCommandAt(1)
  if not blockedCommand then
    marker("gate-test-complete", { success = false, error = blockedError })
    return false
  end

  enable()
  api.cmd.sendCommand(blockedCommand, function(_, blockedSuccess)
    marker("gate-block-result", { success = blockedSuccess == true })
    if blockedSuccess == true then
      disable()
      marker("gate-test-complete", { success = false, error = "gated proposal unexpectedly succeeded" })
      return
    end

    local function tryAuthorized(index)
      if index > #candidates then
        disable()
        marker("gate-test-complete", { success = false, error = "no authorized proposal succeeded" })
        return
      end
      local command, commandError = makeCommandAt(index)
      if not command then
        marker("gate-candidate-skipped", { index = index, error = commandError })
        tryAuthorized(index + 1)
        return
      end
      authorize()
      api.cmd.sendCommand(command, function(result, success)
        marker("gate-authorized-result", {
          index = index,
          success = success == true,
          resultIds = resultIds(result),
        })
        if success == true then
          disable()
          marker("gate-test-complete", {
            success = true,
            blocked = true,
            authorized = true,
            index = index,
          })
        else
          tryAuthorized(index + 1)
        end
      end)
    end

    tryAuthorized(1)
  end)
  return true
end

function M.runCommandGateTest()
  M.capabilities()
  local enable = rawget(_G, "tpf2mp_native_enable_command_gate")
  local disable = rawget(_G, "tpf2mp_native_disable_command_gate")
  local authorize = rawget(_G, "tpf2mp_native_authorize_command")
  local setGameSpeed = commandFactory("setGameSpeed")
  if type(enable) ~= "function" or type(disable) ~= "function"
    or type(authorize) ~= "function" or not setGameSpeed then
    marker("command-gate-test-complete", {
      success = false,
      error = "native command-gate API or SetGameSpeed factory unavailable",
    })
    return false
  end
  local blockedOk, blockedCommand = pcall(setGameSpeed, 0.5)
  if not blockedOk then
    marker("command-gate-test-complete", { success = false, error = tostring(blockedCommand) })
    return false
  end
  enable()
  api.cmd.sendCommand(blockedCommand, function(_, blockedSuccess)
    marker("command-gate-block-result", { tag = 0, success = blockedSuccess == true })
    if blockedSuccess == true then
      disable()
      marker("command-gate-test-complete", {
        success = false,
        error = "gated SetGameSpeed unexpectedly succeeded",
      })
      return
    end
    local commandOk, command = pcall(setGameSpeed, 1.0)
    if not commandOk then
      disable()
      marker("command-gate-test-complete", { success = false, error = tostring(command) })
      return
    end
    authorize(0)
    api.cmd.sendCommand(command, function(_, authorizedSuccess)
      disable()
      marker("command-gate-authorized-result", {
        tag = 0,
        success = authorizedSuccess == true,
      })
      marker("command-gate-test-complete", {
        success = authorizedSuccess == true,
        blocked = true,
        authorized = authorizedSuccess == true,
        tag = 0,
      })
    end)
  end)
  return true
end

function M.run(options)
  options = options or {}
  M.capabilities()
  if not (commandFactory("buildProposal") ~= nil
    and api.type and api.type.SimpleProposal and api.type.SegmentAndEntity and api.type.NodeAndEntity
    and terrainHeightAvailable()) then
    marker("build-complete", { success = false, error = "required supported console API is unavailable" })
    return false
  end
  tryCandidate(1, options.followup)
  return true
end

return M
