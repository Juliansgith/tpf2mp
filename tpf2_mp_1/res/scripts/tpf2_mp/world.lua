local util = require "tpf2_mp/util"
local hash = require "tpf2_mp/hash"
local canonical = require "tpf2_mp/canonical"
local edgeOwnership = require "tpf2_mp/edge_ownership"
local nativeOwnershipProjection = require "tpf2_mp/native_ownership_projection"
local operationalTelemetryModule = require "tpf2_mp/world_operational_telemetry"
local townReadingModule = require "tpf2_mp/world_town_reading"
local stationReadingModule = require "tpf2_mp/world_station_reading"
local lineReadingModule = require "tpf2_mp/world_line_reading"
local industryReadingModule = require "tpf2_mp/world_industry_reading"
local industryResourceFacts = require "tpf2_mp/industry_resource_facts"
local identityModule = require "tpf2_mp/world_identity"

local M = {}

local function entityNumber(value)
  local number = tonumber(value)
  if number then return number end
  local valueType = type(value)
  if valueType == "table" or valueType == "userdata" then
    for _, key in ipairs({ "id", "entity", "entityId", 1, 0 }) do
      local ok, nested = pcall(function() return value[key] end)
      number = ok and tonumber(nested) or nil
      if number then return number end
    end
  end
  return nil
end

local function sortedNumbers(values)
  local result, seen = {}, {}
  local rawValues = {}
  if type(values) == "table" then
    for _, raw in pairs(values) do rawValues[#rawValues + 1] = raw end
  elseif type(values) == "userdata" then
    local lengthOk, length = pcall(function() return #values end)
    length = lengthOk and tonumber(length) or nil
    if length and length >= 0 and length == math.floor(length) then
      -- Engine containers are not consistent about exposing zero- or
      -- one-based indexing. Probe both bounded ranges and deduplicate below.
      for _, base in ipairs({ 0, 1 }) do
        for offset = 0, math.min(length, 100000) - 1 do
          local index = base + offset
          local itemOk, raw = pcall(function() return values[index] end)
          if itemOk and raw ~= nil then rawValues[#rawValues + 1] = raw end
        end
      end
    end
    -- Some Build 35924 wrappers expose numeric indexing but no useful length
    -- operator. A bounded contiguous probe is safe for engine entity lists.
    if not length or length == 0 then
      local misses, found = 0, false
      for index = 0, 1023 do
        local itemOk, raw = pcall(function() return values[index] end)
        if itemOk and raw ~= nil then
          rawValues[#rawValues + 1] = raw
          misses, found = 0, true
        else
          misses = misses + 1
          if found and misses >= 8 then break end
        end
      end
    end
  end
  for _, raw in ipairs(rawValues) do
    local value = entityNumber(raw)
    if value and not seen[value] then seen[value] = true; result[#result + 1] = value end
  end
  table.sort(result)
  return result
end

local function safeEntity(id)
  local ok, entity = pcall(game.interface.getEntity, id)
  return ok and entity or nil
end

local function component(id, componentType)
  if not componentType then return nil end
  local ok, value = pcall(api.engine.getComponent, id, componentType)
  return ok and value or nil
end

local industryReading = industryReadingModule.new({
  getApi = function() return api end,
  getGame = function() return game end,
  entityNumber = entityNumber,
  resourceFacts = industryResourceFacts,
  listIndustries = function() return M.listIndustries and M.listIndustries() or {} end,
  resolveCanonical = function(registry, localId)
    return canonical.resolveCanonical(registry, "industry", localId)
  end,
})
M.industryResourceProbe = industryReading.registryProbe
M.industryRecipe = industryReading.recipeForIndustry
M.industryBootstrapFacts = industryReading.portableFacts

function M.entityExists(id)
  id = tonumber(id)
  if not id or id < 0 then return false end
  if api.engine.entityExists then
    local ok, exists = pcall(api.engine.entityExists, id)
    if ok then return exists == true end
  end
  return safeEntity(id) ~= nil
end

function M.ownerOf(id)
  local ownedType = api.type.ComponentType.PLAYER_OWNED
  local owned = ownedType and component(id, ownedType) or nil
  if not owned then return nil end
  return tonumber(owned.player or owned.playerEntity)
end

function M.listAllPlayerOwned()
  local result = {}
  local ownedType = api.type.ComponentType.PLAYER_OWNED
  if not (api.engine.forEachEntityWithComponent and ownedType) then
    return result, "PLAYER_OWNED enumeration is unavailable"
  end
  local ok, err = pcall(function()
    api.engine.forEachEntityWithComponent(function(entity)
      result[#result + 1] = tonumber(entity)
    end, ownedType)
  end)
  if not ok then return {}, tostring(err) end
  return sortedNumbers(result), nil
end

function M.listPlayerOwned(playerId)
  local result = {}
  local all, enumerationError = M.listAllPlayerOwned()
  if enumerationError then return result, enumerationError end
  for _, entity in ipairs(all) do
    if tonumber(M.ownerOf(entity)) == tonumber(playerId) then result[#result + 1] = entity end
  end
  return result, nil
end

-- A network session starts every peer from the exact same save triplet, but
-- each peer deliberately maps the save's currently controlled native player
-- to a different canonical company.  Native ownership therefore cannot be
-- used to infer canonical ownership after the peer-local company mapping has
-- been created: doing so makes the same pre-existing railway belong to
-- Company 1 on player1 and Company 2 on player2.
--
-- Capture the starting save's ownership before addPlayer changes the native
-- company set. A prior TPF2MP save can name its real company players while an
-- old hot-seat turn desk still physically holds some objects. Those persisted
-- hints take precedence, so the desk is a legacy holder rather than an invented
-- third company. For an ordinary save without hints, the selected asset owner
-- is Company 1 and additional owners follow deterministically.
-- This rule is peer-independent because network launch pins and verifies the
-- same save on every machine.  Machine-local native IDs never enter a digest.
function M.seedInitialNetworkOwnership(worldState, desiredCount, sourcePlayerId)
  desiredCount = math.max(1, util.integer(desiredCount, 2))
  sourcePlayerId = tonumber(sourcePlayerId)
  worldState.logicalOwners = worldState.logicalOwners or {}

  local entities, enumerationError = M.listAllPlayerOwned()
  if enumerationError then return false, enumerationError end
  local byOwner, otherOwners, entitySet = {}, {}, {}
  for _, entity in ipairs(entities) do
    entitySet[entity] = true
    local owner = M.ownerOf(entity)
    if owner and owner >= 0 then
      if not byOwner[owner] then
        byOwner[owner] = {}
        if tonumber(owner) ~= sourcePlayerId then otherOwners[#otherOwners + 1] = owner end
      end
      byOwner[owner][#byOwner[owner] + 1] = entity
    end
  end
  table.sort(otherOwners)

  local ownerOrder, seedSource = {}, "native-owner-enumeration"
  local sourceOwnsAssets = sourcePlayerId ~= nil and byOwner[sourcePlayerId] ~= nil
  local hints = type(worldState.startingOwnershipHints) == "table"
    and worldState.startingOwnershipHints or nil
  local hintedPlayers = hints and hints.companyPlayerIds or nil
  local hintedValid, hintedSeen = type(hintedPlayers) == "table"
    and #hintedPlayers == desiredCount, {}
  if hintedValid then
    for index = 1, desiredCount do
      local playerId = tonumber(hintedPlayers[index])
      if not playerId or playerId < 0 or playerId ~= math.floor(playerId)
        or hintedSeen[playerId] then
        hintedValid = false
        break
      end
      hintedSeen[playerId] = true
      ownerOrder[index] = playerId
    end
  end
  if hintedValid then
    seedSource = "saved-company-hints"
  else
    ownerOrder = {}
    if sourceOwnsAssets then ownerOrder[#ownerOrder + 1] = sourcePlayerId end
    for _, owner in ipairs(otherOwners) do ownerOrder[#ownerOrder + 1] = owner end
  end
  if #ownerOrder > desiredCount then
    return false, string.format(
      "starting save has %d native asset owners but this match supports %d companies",
      #ownerOrder, desiredCount)
  end

  local summary = {
    schemaVersion = 1,
    sourceOwnerCount = #ownerOrder,
    selectedPlayerOwnsAssets = sourceOwnsAssets,
    seedSource = seedSource,
    unmappedSourceOwnerCount = 0,
    mappedLegacyEntities = 0,
    trackedEntities = 0,
    trackedNodes = 0,
    contestedNodes = 0,
    companies = {},
  }
  local selectedOwners, assignments, nodeClaims = {}, {}, {}
  for index, owner in ipairs(ownerOrder) do
    local companyCid = "company:" .. tostring(index)
    local owned = byOwner[owner] or {}
    selectedOwners[owner] = true
    summary.companies[companyCid] = { total = 0 }
    for _, entity in ipairs(owned) do
      assignments[entity] = companyCid
    end
  end
  for owner in pairs(byOwner) do
    if not selectedOwners[owner] then
      summary.unmappedSourceOwnerCount = summary.unmappedSourceOwnerCount + 1
    end
  end
  if hintedValid and type(hints.logicalOwners) == "table" then
    for rawEntity, companyCid in pairs(hints.logicalOwners) do
      local entity = tonumber(rawEntity)
      local companyIndex = type(companyCid) == "string"
        and tonumber(companyCid:match("^company:(%d+)$")) or nil
      if entity and entity >= 0 and entity == math.floor(entity) and entitySet[entity]
        and companyIndex and companyIndex >= 1 and companyIndex <= desiredCount then
        local nativeOwner = M.ownerOf(entity)
        if nativeOwner ~= nil and not selectedOwners[nativeOwner] then
          summary.mappedLegacyEntities = summary.mappedLegacyEntities + 1
        end
        assignments[entity] = companyCid
      end
    end
  end
  for _, entity in ipairs(entities) do
    local companyCid = assignments[entity]
    if companyCid then
      worldState.logicalOwners[tostring(entity)] = companyCid
      summary.trackedEntities = summary.trackedEntities + 1
      summary.companies[companyCid].total = summary.companies[companyCid].total + 1
      -- BASE_NODE itself has no PLAYER_OWNED component. Derive terminal-node
      -- custody from private starting edges so expanding a rival pre-existing
      -- railway is guarded just like expanding a player-created one.
      local baseEdgeType = api and api.type and api.type.ComponentType.BASE_EDGE
      local baseEdge = baseEdgeType and component(entity, baseEdgeType) or nil
      if baseEdge then
        for _, rawNodeId in ipairs({ baseEdge.node0, baseEdge.node1 }) do
          local nodeId = tonumber(rawNodeId)
          if nodeId and nodeId >= 0 then
            local claims = nodeClaims[nodeId] or {}
            claims[companyCid] = true
            nodeClaims[nodeId] = claims
          end
        end
      end
    end
  end
  for nodeId, claims in pairs(nodeClaims) do
    local ownerCid, ownerCount = nil, 0
    for companyCid in pairs(claims) do ownerCid, ownerCount = companyCid, ownerCount + 1 end
    if ownerCount == 1 then
      worldState.logicalOwners[tostring(nodeId)] = ownerCid
      summary.trackedNodes = summary.trackedNodes + 1
    else
      -- A junction already shared by multiple starting companies is not
      -- assigned exclusively. Its adjoining private edges remain protected.
      summary.contestedNodes = summary.contestedNodes + 1
    end
  end
  worldState.logicalOwnershipAuthoritative = true
  worldState.initialNetworkOwnership = summary
  return true, util.deepCopy(summary)
end

local function nameOf(id)
  local nameComponent = component(id, api.type.ComponentType.NAME)
  if nameComponent and nameComponent.name then return tostring(nameComponent.name) end
  local entity = safeEntity(id)
  return entity and tostring(entity.name or (entity.type or "entity") .. " " .. tostring(id)) or tostring(id)
end

local function stableNameOf(id)
  local nameComponent = component(id, api.type.ComponentType.NAME)
  if nameComponent and nameComponent.name then return tostring(nameComponent.name) end
  local entity = safeEntity(id)
  return entity and entity.name and tostring(entity.name) or ""
end

-- Returns nil when no source resolves, so callers that must not fabricate
-- geometry can tell "unknown" from a legitimate position at the origin.
local function resolvedPositionOfEntity(entity)
  local e = safeEntity(entity)
  if e and e.position then
    return { util.integer((e.position[1] or e.position.x or 0) * 10), util.integer((e.position[2] or e.position.y or 0) * 10) }
  end
  local construction = component(entity, api.type.ComponentType.CONSTRUCTION)
  if construction and construction.transf and construction.transf.cols then
    local ok, pos = pcall(function() return construction.transf:cols(3) end)
    if ok and pos then return { util.integer((pos.x or 0) * 10), util.integer((pos.y or 0) * 10) } end
  end
  local node = component(entity, api.type.ComponentType.BASE_NODE)
  local nodePosition = node and (node.position or node.pos)
  if nodePosition then
    return {
      util.integer((nodePosition[1] or nodePosition.x or 0) * 10),
      util.integer((nodePosition[2] or nodePosition.y or 0) * 10),
      util.integer((nodePosition[3] or nodePosition.z or 0) * 10),
    }
  end
  return nil
end

local function positionOfEntity(entity)
  return resolvedPositionOfEntity(entity) or { 0, 0 }
end

-- Town structural reading -- building enumeration, development positions, and
-- the policy-independent building count the economy uses as town size -- lives
-- in its own module so the native town->building walk has exactly one home.
local townReading = townReadingModule.new({
  resolvedPositionOfEntity = resolvedPositionOfEntity,
  safeEntity = safeEntity,
  sortedNumbers = sortedNumbers,
  entityNumber = entityNumber,
})
local developmentPositionOfEntity = townReading.developmentPositionOfEntity
local townBuildingCount = townReading.townBuildingCount
local developmentPositionsOfTown = townReading.developmentPositionsOfTown

local function boundedComponentValues(values, maximum)
  local result = {}
  maximum = maximum or 1024
  if values == nil then return result end
  if type(values) == "table" then
    for _, value in pairs(values) do
      if #result >= maximum then break end
      result[#result + 1] = value
    end
  elseif type(values) == "userdata" then
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

-- Construction and ASSET_GROUP ids can survive an in-place edit. Their
-- rendered models are therefore part of the stable fingerprint as well as a
-- local postcondition for canonical upgrades. Model repository names are
-- portable across peers; numeric repository ids are deliberately excluded.
local function renderedModelNames(entity)
  local types = api and api.type and api.type.ComponentType or {}
  local instances = component(entity, types.MODEL_INSTANCE_LIST)
  local repository = api and api.res and api.res.modelRep
  if not instances or not repository or repository.getName == nil then return {} end
  local result, counts = {}, {}
  for _, field in ipairs({ "thinInstances", "fatInstances" }) do
    local fieldOk, values = pcall(function() return instances[field] end)
    for _, instance in ipairs(fieldOk and boundedComponentValues(values) or {}) do
      local idOk, modelId = pcall(function() return instance.modelId end)
      modelId = idOk and tonumber(modelId) or nil
      if modelId then
        local nameOk, name = pcall(repository.getName, modelId)
        name = nameOk and name ~= nil and tostring(name) or nil
        if name and name ~= "" then counts[name] = (counts[name] or 0) + 1 end
      end
    end
  end
  for name, count in pairs(counts) do result[#result + 1] = { name = name, count = count } end
  table.sort(result, function(left, right) return left.name < right.name end)
  return result
end

function M.listTowns()
  if game.interface.getTowns then return sortedNumbers(game.interface.getTowns()) end
  return {}
end

function M.listLines()
  if api.engine.system and api.engine.system.lineSystem and api.engine.system.lineSystem.getLines then
    local ok, lines = pcall(api.engine.system.lineSystem.getLines)
    if ok then return sortedNumbers(lines) end
  end
  if game.interface.getLines then return sortedNumbers(game.interface.getLines()) end
  return {}
end

function M.listVehicles()
  if game.interface.getVehicles then return sortedNumbers(game.interface.getVehicles()) end
  return {}
end

function M.listDepots()
  if game.interface.getDepots then return sortedNumbers(game.interface.getDepots()) end
  return {}
end

function M.stationGroupFor(entityId)
  entityId = tonumber(entityId)
  if not entityId then return nil, "station selection has no entity id" end
  local types = api.type.ComponentType
  if component(entityId, types.STATION_GROUP) then return entityId end
  local entity = safeEntity(entityId)
  for _, field in ipairs({ "stationGroup", "stationGroupId", "group", "groupId" }) do
    local value = entity and tonumber(entity[field]) or nil
    if value and value >= 0 and component(value, types.STATION_GROUP) then return value end
  end
  local stationId = component(entityId, types.STATION) and entityId or nil
  if stationId and api.engine.forEachEntityWithComponent and types.STATION_GROUP then
    local matches = {}
    pcall(function()
      api.engine.forEachEntityWithComponent(function(groupId)
        local group = component(groupId, types.STATION_GROUP)
        for _, nested in pairs(group and (group.stations or group.stationEntities) or {}) do
          local candidate = type(nested) == "table" and (nested.entity or nested.id or nested[1]) or nested
          if tonumber(candidate) == stationId then matches[#matches + 1] = tonumber(groupId) end
        end
      end, types.STATION_GROUP)
    end)
    table.sort(matches)
    if #matches == 1 then return matches[1] end
    if #matches > 1 then return nil, "station belongs to multiple station groups" end
  end
  return nil, "select a station-group icon (not a platform/construction sub-entity)"
end

function M.listIndustries()
  local result = {}
  if api.engine.forEachEntityWithComponent and api.type.ComponentType.SIM_BUILDING then
    pcall(function()
      api.engine.forEachEntityWithComponent(function(entity)
        result[#result + 1] = tonumber(entity)
      end, api.type.ComponentType.SIM_BUILDING)
    end)
  end
  return sortedNumbers(result)
end

local function listWithComponent(componentType)
  local result = {}
  if componentType and api.engine.forEachEntityWithComponent then
    pcall(function()
      api.engine.forEachEntityWithComponent(function(entity)
        result[#result + 1] = tonumber(entity)
      end, componentType)
    end)
  end
  return sortedNumbers(result)
end

function M.listStationGroups()
  return listWithComponent(api.type.ComponentType.STATION_GROUP)
end

function M.listStations()
  return listWithComponent(api.type.ComponentType.STATION)
end

function M.listEdges()
  return listWithComponent(api.type.ComponentType.BASE_EDGE)
end

function M.listNodes()
  return listWithComponent(api.type.ComponentType.BASE_NODE)
end

function M.listEdgeObjects()
  -- SIGNAL_LIST is the public ownership-bearing component used by ordinary
  -- rail/road signals. Waypoint-style edge objects are bound at creation time;
  -- their STATION component alone is not sufficient to distinguish them from
  -- full station entities during a pre-existing-world scan.
  return listWithComponent(api.type.ComponentType.SIGNAL_LIST)
end

function M.listAssets()
  local types = api and api.type and api.type.ComponentType or {}
  return types.ASSET_GROUP and listWithComponent(types.ASSET_GROUP) or {}
end

function M.listConstructions()
  local types = api and api.type and api.type.ComponentType or {}
  return types.CONSTRUCTION and listWithComponent(types.CONSTRUCTION) or {}
end

local function listKind(kind)
  local sources = {
    town = M.listTowns,
    industry = M.listIndustries,
    station_group = M.listStationGroups,
    station = M.listStations,
    depot = M.listDepots,
    line = M.listLines,
    vehicle = M.listVehicles,
    edge = M.listEdges,
    node = M.listNodes,
    edge_object = M.listEdgeObjects,
    asset = M.listAssets,
    construction = M.listConstructions,
  }
  local source = sources[kind]
  return source and source() or nil
end

function M.kindOf(id)
  local types = api.type.ComponentType
  local candidates = {
    { "line", types.LINE },
    { "vehicle", types.TRANSPORT_VEHICLE },
    { "depot", types.VEHICLE_DEPOT },
    { "edge_object", types.SIGNAL_LIST },
    { "asset", types.ASSET_GROUP },
    { "construction", types.CONSTRUCTION },
    { "station_group", types.STATION_GROUP },
    { "station", types.STATION },
    { "edge", types.BASE_EDGE },
    { "node", types.BASE_NODE },
    { "industry", types.SIM_BUILDING },
    { "town", types.TOWN },
    { "company", types.PLAYER },
  }
  for _, candidate in ipairs(candidates) do
    if candidate[2] and component(id, candidate[2]) then return candidate[1] end
  end
  local entity = safeEntity(id)
  return entity and string.lower(tostring(entity.type or "entity")) or "entity"
end

local function lineStopGroups(lineId)
  local line = component(lineId, api.type.ComponentType.LINE)
  local groups = {}
  if line and line.stops then
    for _, stop in ipairs(line.stops) do
      local group = stop.stationGroup or stop.group or stop.station or stop.entity
      if group then groups[#groups + 1] = tonumber(group) or group end
    end
  end
  return groups
end

function M.fingerprint(id, kind)
  kind = kind or M.kindOf(id)
  -- BASE_NODE and BASE_EDGE do not have stable human names. game.interface's
  -- fallback representation commonly includes the engine-local entity id,
  -- which made an otherwise identical public road junction acquire a
  -- different canonical identity after creation order diverged. Topology is
  -- therefore identified only by quantised geometry. Exact-position node
  -- collisions use a portable incident-edge anchor when one exists; remaining
  -- topology ambiguity is rejected by the lazy resolver below.
  local value = { kind = kind }
  if kind == "node" then
    value.position = positionOfEntity(id)
  elseif kind == "edge" then
    local edge = component(id, api.type.ComponentType.BASE_EDGE)
    if edge then
      local endpoints = {
        positionOfEntity(edge.node0),
        positionOfEntity(edge.node1),
      }
      table.sort(endpoints, function(a, b)
        return hash.value(a) < hash.value(b)
      end)
      value.endpoints = endpoints
    else
      value.position = positionOfEntity(id)
    end
  else
    -- Never let an engine-local entity id enter a cross-peer fingerprint. Some
    -- internal station/depot/asset entities have no NAME component at all.
    value.name = stableNameOf(id)
    value.position = positionOfEntity(id)
  end
  if kind == "line" then
    value.stops = {}
    for _, group in ipairs(lineStopGroups(id)) do
      value.stops[#value.stops + 1] = { name = stableNameOf(group), position = positionOfEntity(group) }
    end
  elseif kind == "construction" then
    local construction = component(id, api.type.ComponentType.CONSTRUCTION)
    value.fileName = construction and construction.fileName or ""
    -- Construction.params is documented as a table. Preserve it as a nested
    -- digest when it is plain/serialisable; omit opaque generated values
    -- instead of allowing an engine binding to poison the world manifest.
    if construction then
      local ok, digest = pcall(hash.value, construction.params)
      if ok then value.paramsDigest = digest end
    end
    value.models = renderedModelNames(id)
  elseif kind == "asset" then
    local asset = component(id, api.type.ComponentType.ASSET_GROUP)
    -- fileName is not present on Build 35924 ASSET_GROUP components, but keep
    -- a stable fallback for compatible/mod-provided component bindings.
    local fileOk, fileName = pcall(function() return asset and asset.fileName end)
    value.fileName = fileOk and tostring(fileName or "") or ""
    value.models = renderedModelNames(id)
  elseif kind == "vehicle" then
    -- Vehicles move; their live position cannot be identity material.
    value.position = nil
    value.models = {}
    local entity = safeEntity(id) or {}
    for _, vehicle in ipairs(entity.vehicles or {}) do
      value.models[#value.models + 1] = tostring(vehicle.fileName or vehicle.modelId or "unknown")
    end
    local transportVehicle = component(id, api.type.ComponentType.TRANSPORT_VEHICLE)
    value.carrier = transportVehicle and tostring(transportVehicle.carrier or "") or ""
  end
  return hash.value(value)
end

-- Lazy canonical identity, including co-located topology nodes anchored to a
-- stable incident edge, lives behind a small boundary to keep world.lua from
-- becoming the protocol implementation as well as the native-world adapter.
local identity = identityModule.new({
  kindOf = M.kindOf,
  fingerprint = M.fingerprint,
  listKind = listKind,
  baseEdge = function(id) return component(id, api.type.ComponentType.BASE_EDGE) end,
})
M.findPreExistingLocal = identity.findPreExistingLocal
M.identifyExisting = identity.identifyExisting
M.resolvePreExisting = identity.resolvePreExisting

function M.bindExisting(registry, id, kind, metadata)
  kind = kind or M.kindOf(id)
  local existing = canonical.resolveCanonical(registry, kind, id)
  if existing then return existing end
  local fingerprint = M.fingerprint(id, kind)
  local baseCid = canonical.preExistingId(kind, fingerprint)
  local cid, ordinal = baseCid, 1
  while registry.byCanonical[cid] and tostring(registry.byCanonical[cid].localId) ~= tostring(id) do
    ordinal = ordinal + 1
    cid = baseCid .. ":dup:" .. tostring(ordinal)
  end
  local bindingMetadata = util.deepCopy(metadata or { name = nameOf(id) })
  bindingMetadata.fingerprint = fingerprint
  bindingMetadata.duplicateOrdinal = ordinal
  local ok, err = canonical.bind(registry, cid, kind, id, bindingMetadata)
  if not ok then return nil, err end
  return cid
end

-- Canonical pre-existing-world handshake material. The manifest contains no
-- engine IDs and is stable even if component enumeration order differs. Unique
-- operational objects are bound eagerly; genuinely indistinguishable objects
-- are reported as ambiguous and must not be targeted until a player-created
-- event gives them an event-derived identity.
function M.canonicalManifest(registry, worldState)
  local sources = {
    { kind = "town", ids = M.listTowns() },
    { kind = "industry", ids = M.listIndustries() },
    { kind = "station_group", ids = M.listStationGroups() },
    { kind = "station", ids = M.listStations() },
    { kind = "depot", ids = M.listDepots() },
    { kind = "line", ids = M.listLines() },
    { kind = "vehicle", ids = M.listVehicles() },
    { kind = "edge_object", ids = M.listEdgeObjects() },
    { kind = "asset", ids = M.listAssets() },
    { kind = "construction", ids = M.listConstructions() },
  }
  -- Player-built topology already present in the shared starting save is
  -- operational, unlike autonomous town roads. Its logical ownership was
  -- captured before peer-local company remapping, so include exactly those
  -- edges/nodes in the cross-peer manifest. This lets a unique private
  -- starting railway receive manifestBound on every peer without enumerating
  -- the map's entire road graph.
  if worldState and type(worldState.logicalOwners) == "table" then
    local topology = { edge = {}, node = {} }
    for rawId in pairs(worldState.logicalOwners) do
      local localId = tonumber(rawId)
      if localId and M.entityExists(localId) then
        local kind = M.kindOf(localId)
        if topology[kind] then topology[kind][#topology[kind] + 1] = localId end
      end
    end
    sources[#sources + 1] = { kind = "edge", ids = sortedNumbers(topology.edge) }
    sources[#sources + 1] = { kind = "node", ids = sortedNumbers(topology.node) }
  end
  local groups = {}
  for _, source in ipairs(sources) do
    for _, localId in ipairs(source.ids) do
      local fingerprint = M.fingerprint(localId, source.kind)
      local key = source.kind .. ":" .. fingerprint
      local group = groups[key]
      if not group then
        group = { kind = source.kind, fingerprint = fingerprint, localIds = {} }
        groups[key] = group
      end
      group.localIds[#group.localIds + 1] = localId
    end
  end
  local rows, ambiguous, bound, deferredUnique = {}, {}, 0, 0
  for _, key in ipairs(util.sortedKeys(groups)) do
    local group = groups[key]
    table.sort(group.localIds)
    local row = {
      kind = group.kind,
      fingerprint = group.fingerprint,
      count = #group.localIds,
      canonicalBase = canonical.preExistingId(group.kind, group.fingerprint),
      ambiguous = #group.localIds > 1,
    }
    rows[#rows + 1] = row
    if row.ambiguous then
      ambiguous[#ambiguous + 1] = {
        kind = row.kind,
        fingerprint = row.fingerprint,
        count = row.count,
      }
    elseif group.kind == "asset" or group.kind == "construction" then
      -- A generated map contains hundreds of decorative ASSET_GROUP and
      -- CONSTRUCTION roots.  They belong in the shared-world fingerprint,
      -- but eagerly persisting every unique decoration in the operational
      -- canonical registry makes Build 35924 copy an enormous script state at
      -- the next native BuildProposal boundary.  A player-selected root is
      -- bound on demand through proposalResolveCanonical/world.bindExisting,
      -- preserving exactly the same stable pre-existing identity without
      -- making unrelated autonomous scenery live multiplayer state.
      deferredUnique = deferredUnique + 1
    else
      local cid = M.bindExisting(registry, group.localIds[1], group.kind, {
        fingerprint = group.fingerprint,
        manifestBound = true,
      })
      if cid then bound = bound + 1 end
    end
  end
  local view = { schemaVersion = 1, rows = rows }
  return {
    schemaVersion = 1,
    rows = rows,
    total = (function()
      local count = 0
      for _, row in ipairs(rows) do count = count + row.count end
      return count
    end)(),
    uniqueBound = bound,
    deferredUnique = deferredUnique,
    ambiguous = ambiguous,
    ambiguousCount = #ambiguous,
    digest = hash.value(view),
  }
end

function M.matchEdgeReplacements(beforeSnapshot, appliedSnapshot)
  return edgeOwnership.matchBuilderReplacements(beforeSnapshot, appliedSnapshot)
end

function M.checkProposalAccess(worldState, proposalSnapshot, activeCompanyCid)
  return edgeOwnership.checkProposalAccess(worldState, proposalSnapshot, activeCompanyCid)
end

function M.rebindEdgeReplacements(worldState, registry, observation, nativePlayerId)
  return edgeOwnership.rebindObserved(worldState, registry, observation, nativePlayerId)
end

function M.validatePinnedEdgeCustody(worldState, nativePlayerId, companies)
  return edgeOwnership.validatePinnedCustody(worldState, nativePlayerId, companies)
end

function M.initialiseCompanies(worldState, registry, desiredCount, options)
  desiredCount = desiredCount or 2
  options = options or {}
  worldState.playerIds = worldState.playerIds or {}
  local current = game.interface.getPlayer()
  local proxyMode = options.proxyMode == true
  local localCompanyIndex = util.clamp(util.integer(options.localCompanyIndex, 1), 1, desiredCount)
  worldState.controlPlayerId = proxyMode and current or nil
  worldState.proxyMode = proxyMode
  worldState.logicalOwners = worldState.logicalOwners or {}

  local initialNetworkOwnership
  if not proxyMode and options.canonicalNetworkOwnership == true then
    worldState.logicalOwnershipAuthoritative = true
    if #worldState.playerIds == 0 then
      local seeded, result = M.seedInitialNetworkOwnership(worldState, desiredCount, current)
      if not seeded then return false, result end
      initialNetworkOwnership = result
    else
      initialNetworkOwnership = util.deepCopy(worldState.initialNetworkOwnership)
    end
  end

  if not proxyMode and #worldState.playerIds == 0 then
    -- Every network peer's native UI remains attached to its original player.
    -- Map that local player to the peer's canonical company, not always to
    -- Company 1. Other companies are local representations and may therefore
    -- use different native player IDs/order on different machines.
    local usedPlayers = { [tonumber(current)] = true }
    local hintedPlayers = worldState.startingOwnershipHints
      and worldState.startingOwnershipHints.companyPlayerIds or {}
    for index = 1, desiredCount do
      if index == localCompanyIndex then
        worldState.playerIds[index] = current
      else
        local hintedPlayerId = tonumber(hintedPlayers[index])
        local hintedEntity = hintedPlayerId and safeEntity(hintedPlayerId) or nil
        local hintedIsPlayer = hintedPlayerId and not usedPlayers[hintedPlayerId]
          and ((api.type.ComponentType.PLAYER
              and component(hintedPlayerId, api.type.ComponentType.PLAYER) ~= nil)
            or (hintedEntity and tostring(hintedEntity.type or ""):upper() == "PLAYER"))
        local playerId
        if hintedIsPlayer then
          playerId = hintedPlayerId
        else
          if not game.interface.addPlayer then return false, "game.interface.addPlayer unavailable" end
          local added
          added, playerId = pcall(game.interface.addPlayer)
          if not added or not playerId then return false, "addPlayer failed: " .. tostring(playerId) end
        end
        worldState.playerIds[index] = playerId
        usedPlayers[tonumber(playerId)] = true
      end
    end
  elseif not proxyMode and options.localCompanyIndex ~= nil then
    if tonumber(worldState.playerIds[localCompanyIndex]) ~= tonumber(current) then
      return false, "saved native company mapping does not match this network peer; initialise a fresh match"
    end
  end
  if proxyMode then
    for _, playerId in ipairs(worldState.playerIds) do
      if tonumber(playerId) == tonumber(current) then
        return false, "cannot enable native turn proxy over legacy company bindings; initialise a fresh match"
      end
    end
  end
  while #worldState.playerIds < desiredCount do
    if not game.interface.addPlayer then return false, "game.interface.addPlayer unavailable" end
    local ok, playerId = pcall(game.interface.addPlayer)
    if not ok or not playerId then return false, "addPlayer failed: " .. tostring(playerId) end
    worldState.playerIds[#worldState.playerIds + 1] = playerId
  end
  for index, playerId in ipairs(worldState.playerIds) do
    local cid = "company:" .. tostring(index)
    local ok, err = canonical.bind(registry, cid, "company", playerId, { name = "Company " .. index })
    if not ok then return false, err end
    if game.interface.setName then pcall(game.interface.setName, playerId, "Company " .. index) end
  end
  local ownershipProjection
  if not proxyMode and options.canonicalNetworkOwnership == true then
    local projected, result = nativeOwnershipProjection.apply(worldState, worldState.playerIds, {
      listOwned = M.listAllPlayerOwned,
      ownerOf = M.ownerOf,
      kindOf = M.kindOf,
      setPlayer = function(entityId, playerId)
        if type(game.interface.setPlayer) ~= "function" then
          error("game.interface.setPlayer unavailable")
        end
        return game.interface.setPlayer(entityId, playerId)
      end,
    })
    if not projected then
      if type(result) == "table" and type(result.failures) == "table" then
        local details = {}
        for _, failure in ipairs(result.failures) do
          details[#details + 1] = tostring(failure.kind) .. ":" .. tostring(failure.error)
        end
        result.error = "native company projection failed: " .. table.concat(details, ",")
      end
      return false, result
    end
    ownershipProjection = result
    worldState.nativeOwnershipProjection = {
      schemaVersion = 1,
      required = result.required,
      retainedEdges = result.retainedEdges,
      unsupported = result.unsupported,
      byCompany = (function()
        local value = {}
        for companyCid, company in pairs(result.byCompany or {}) do
          value[companyCid] = {
            required = company.required,
            retainedEdges = company.retainedEdges,
          }
        end
        return value
      end)(),
    }
  end
  if proxyMode and game.interface.setName then pcall(game.interface.setName, current, "TPF2MP Turn Desk") end
  local result = util.deepCopy(worldState.playerIds)
  result.companyPlayerIds = util.deepCopy(worldState.playerIds)
  result.controlPlayerId = worldState.controlPlayerId
  result.proxyMode = proxyMode
  if not proxyMode then result.localCompanyIndex = localCompanyIndex end
  result.initialNetworkOwnership = initialNetworkOwnership
  result.nativeOwnershipProjection = ownershipProjection
  return true, result
end

local function noteLogicalOwner(registry, worldState, id, kind, ownerCid, bindExisting)
  local cid = canonical.resolveCanonical(registry, kind, id)
  if not cid then
    if bindExisting then cid = M.bindExisting(registry, id, kind, { name = nameOf(id), owner = ownerCid }) end
  end
  local binding = cid and registry.byCanonical[cid] or nil
  if binding then
    binding.metadata = binding.metadata or {}
    binding.metadata.owner = ownerCid
    if not binding.metadata.fingerprint then binding.metadata.fingerprint = M.fingerprint(id, kind) end
  end
  if worldState and ownerCid then
    worldState.logicalOwners = worldState.logicalOwners or {}
    worldState.logicalOwners[tostring(id)] = ownerCid
  end
  return cid
end

local function ensureEntityBinding(registry, id, kind, eventId, slot, ownerCid, bindExisting)
  local existingCid = canonical.resolveCanonical(registry, kind, id)
  if existingCid then return existingCid, true end
  if bindExisting then
    local cid, err = M.bindExisting(registry, id, kind, { name = nameOf(id), owner = ownerCid })
    return cid, false, err
  end
  local cid = canonical.createdId(kind, eventId, slot)
  local bound, err = canonical.bind(registry, cid, kind, id, {
    name = nameOf(id),
    fingerprint = M.fingerprint(id, kind),
    owner = ownerCid,
  })
  return bound and cid or nil, false, err
end

function M.claimEntities(registry, ids, playerId, eventId, options)
  options = options or {}
  local results = { claimed = {}, failed = {}, skipped = {}, pinned = {}, unchanged = {} }
  local ownerCid = options.logicalOwnerCid or canonical.resolveCanonical(registry, "company", playerId)
  for slot, id in ipairs(sortedNumbers(ids)) do
    local kind = M.kindOf(id)
    local originalOwner = M.ownerOf(id)
    if not M.entityExists(id) then
      results.skipped[#results.skipped + 1] = { localId = id, error = "entity does not exist" }
    elseif originalOwner == nil then
      results.skipped[#results.skipped + 1] = { localId = id, kind = kind, error = "entity is not player-owned" }
    elseif kind == "edge" then
      -- Build 35924's legacy game.interface.setPlayer asserts for BASE_EDGE
      -- entities even though the UI ownership tool can update them through a
      -- BuildProposal.  Never call that invalid legacy path.  Keep the native
      -- edge outside the legacy setter and preserve its company as explicit
      -- logical/pinned custody. Most edges remain on the turn desk, but
      -- Build 35924 may cascade a depot/station construction transfer onto an
      -- attached edge. Such an edge can therefore be held by the desk or its
      -- rightful logical company's native player. Builder replacement IDs
      -- are migrated by the preview/apply batch path before this ordinary
      -- claim pass runs.
      local worldState = options.worldState
      local rememberedOwner = worldState and worldState.logicalOwners
        and worldState.logicalOwners[tostring(id)] or nil
      local pinnedOwnerCid = rememberedOwner or ownerCid
      local cid, existing, bindError = ensureEntityBinding(
        registry, id, kind, eventId, slot, pinnedOwnerCid, options.bindExisting)
      if not (worldState and pinnedOwnerCid and cid) then
        results.failed[#results.failed + 1] = {
          localId = id,
          kind = kind,
          error = bindError or "BASE_EDGE requires pinned logical custody but no world/company binding was supplied",
          originalOwner = originalOwner,
          requestedOwner = playerId,
        }
      else
        noteLogicalOwner(registry, worldState, id, kind, pinnedOwnerCid, options.bindExisting)
        worldState.pinnedCustody = worldState.pinnedCustody or {}
        worldState.pinnedCustody[tostring(id)] = {
          cid = cid,
          kind = kind,
          logicalOwnerCid = pinnedOwnerCid,
          nativePlayerId = originalOwner,
          requestedPlayerId = playerId,
          reason = "build35924-base-edge-setPlayer-asserts",
        }
        results.pinned[#results.pinned + 1] = {
          cid = cid,
          kind = kind,
          localId = id,
          existing = existing,
          logicalOwnerCid = pinnedOwnerCid,
          nativePlayerId = originalOwner,
          requestedPlayerId = playerId,
        }
      end
    elseif tonumber(originalOwner) == tonumber(playerId) then
      local cid, existing, bindError = ensureEntityBinding(
        registry, id, kind, eventId, slot, ownerCid, options.bindExisting)
      if not cid then
        results.failed[#results.failed + 1] = {
          localId = id,
          kind = kind,
          error = tostring(bindError or "canonical binding failed"),
          originalOwner = originalOwner,
        }
      else
        noteLogicalOwner(registry, options.worldState, id, kind, ownerCid, options.bindExisting)
        results.unchanged[#results.unchanged + 1] = {
          cid = cid,
          kind = kind,
          localId = id,
          existing = existing,
          owner = originalOwner,
        }
      end
    else
      local ok, setResult = pcall(game.interface.setPlayer, id, playerId)
      if ok and setResult ~= false then
        local observedOwner = M.ownerOf(id)
        if tonumber(observedOwner) ~= tonumber(playerId) then
          local rollbackCall, rollbackResult = pcall(game.interface.setPlayer, id, originalOwner)
          local rollbackObservedOwner = M.ownerOf(id)
          results.failed[#results.failed + 1] = {
            localId = id,
            kind = kind,
            error = "ownership postcondition failed",
            expectedOwner = playerId,
            observedOwner = observedOwner,
            originalOwner = originalOwner,
            rollbackOk = rollbackCall and rollbackResult ~= false
              and tonumber(rollbackObservedOwner) == tonumber(originalOwner),
            rollbackObservedOwner = rollbackObservedOwner,
          }
        else
          local cid, existing, bindError = ensureEntityBinding(
            registry, id, kind, eventId, slot, ownerCid, options.bindExisting)
          if cid then
            noteLogicalOwner(registry, options.worldState, id, kind, ownerCid, options.bindExisting)
            results.claimed[#results.claimed + 1] = {
              cid = cid,
              kind = kind,
              localId = id,
              existing = existing,
              originalOwner = originalOwner,
              owner = playerId,
            }
          else
            local rollbackCall, rollbackResult = pcall(game.interface.setPlayer, id, originalOwner)
            local rollbackOk = rollbackCall and rollbackResult ~= false
              and tonumber(M.ownerOf(id)) == tonumber(originalOwner)
            results.failed[#results.failed + 1] = {
              localId = id,
              error = tostring(bindError or "canonical binding failed"),
              rollbackOk = rollbackOk,
            }
          end
        end
      else
        local observedOwner = M.ownerOf(id)
        local rollbackOk = tonumber(observedOwner) == tonumber(originalOwner)
        if not rollbackOk then
          local rollbackCall, rollbackResult = pcall(game.interface.setPlayer, id, originalOwner)
          rollbackOk = rollbackCall and rollbackResult ~= false
            and tonumber(M.ownerOf(id)) == tonumber(originalOwner)
        end
        results.failed[#results.failed + 1] = {
          localId = id,
          kind = kind,
          error = tostring(setResult),
          originalOwner = originalOwner,
          observedOwner = observedOwner,
          rollbackOk = rollbackOk,
        }
      end
    end
  end
  return results
end

-- A Build 35924 builder transaction can replace one tracked edge with a
-- split/join set whose local IDs have no one-to-one topology match.  That is
-- not enough information to preserve canonical lineage, but in standalone
-- proxy mode the turn desk is an exclusive custody boundary: every untracked
-- desk asset belongs to the active company, while already pinned rival edges
-- retain their remembered owner.  Rebuild that local custody inventory before
-- settlement instead of leaving an otherwise healthy turn permanently
-- blocked by a stale replacement diagnostic.
function M.recoverProxyEdgeCustody(worldState, registry, failure, controlPlayerId,
    companyPlayerId, companyCid, eventId, companies)
  local result = {
    scope = "standalone-proxy-inventory-recovery",
    canonicalLineagePreserved = false,
    retired = {},
    targetChecks = {},
    unsafe = {},
    inventories = {},
  }
  if not (worldState and worldState.proxyMode == true) then
    result.error = "edge custody recovery is only valid in standalone proxy mode"
    return false, result
  end
  if not (registry and registry.byCanonical and registry.byLocal) then
    result.error = "canonical registry is unavailable"
    return false, result
  end
  if type(companyCid) ~= "string" or companyCid == "" then
    result.error = "active company is unavailable"
    return false, result
  end
  failure = type(failure) == "table" and failure or {}
  if failure.companyCid and failure.companyCid ~= companyCid then
    result.error = "replacement failure belongs to a different company"
    return false, result
  end

  local migration = type(failure.migration) == "table" and failure.migration or {}
  local allowedOwners = {}
  if tonumber(controlPlayerId) then allowedOwners[tonumber(controlPlayerId)] = true end
  if tonumber(companyPlayerId) then allowedOwners[tonumber(companyPlayerId)] = true end

  -- Never recover an observation that actually concerns a rival company's
  -- tracked edge.  That remains a hard ownership failure.
  for _, failed in ipairs(migration.failed or {}) do
    if failed.logicalOwnerCid and failed.logicalOwnerCid ~= companyCid then
      result.unsafe[#result.unsafe + 1] = {
        oldLocalId = failed.oldLocalId,
        canonicalId = failed.canonicalId,
        logicalOwnerCid = failed.logicalOwnerCid,
        error = "replacement failure concerns rival-owned infrastructure",
      }
    end
  end

  local targetIds = {}
  for _, target in ipairs(migration.unmatchedTargets or {}) do
    targetIds[#targetIds + 1] = target.entity or target.newLocalId
  end
  for _, failed in ipairs(migration.failed or {}) do
    if failed.newLocalId ~= nil then targetIds[#targetIds + 1] = failed.newLocalId end
  end
  for _, localId in ipairs(sortedNumbers(targetIds)) do
    if M.entityExists(localId) then
      local observedOwner = M.ownerOf(localId)
      local check = { localId = localId, observedNativeOwner = observedOwner }
      if observedOwner == nil then
        check.error = "replacement target is not observably player-owned"
        result.unsafe[#result.unsafe + 1] = util.deepCopy(check)
      elseif not allowedOwners[tonumber(observedOwner)] then
        check.error = "replacement target is held outside the active proxy company"
        result.unsafe[#result.unsafe + 1] = util.deepCopy(check)
      else
        check.allowed = true
      end
      result.targetChecks[#result.targetChecks + 1] = check
    else
      result.targetChecks[#result.targetChecks + 1] = {
        localId = localId,
        retired = true,
        note = "intermediate replacement target no longer exists",
      }
    end
  end
  if #result.unsafe > 0 then
    result.error = "replacement custody cannot be recovered safely"
    return false, result
  end

  worldState.logicalOwners = worldState.logicalOwners or {}
  worldState.pinnedCustody = worldState.pinnedCustody or {}
  local retiredLocalIds = {}
  local function retire(localId, canonicalId, reason)
    localId = tonumber(localId)
    if not localId or retiredLocalIds[localId] then return end
    retiredLocalIds[localId] = true
    if canonicalId and registry.byCanonical[canonicalId]
      and tonumber(registry.byCanonical[canonicalId].localId) == localId then
      canonical.unbindCanonical(registry, canonicalId)
    end
    worldState.logicalOwners[tostring(localId)] = nil
    worldState.pinnedCustody[tostring(localId)] = nil
    result.retired[#result.retired + 1] = {
      localId = localId,
      canonicalId = canonicalId,
      reason = reason,
    }
  end

  -- Retire every stale edge binding for the active company, not only the last
  -- failed observation.  The failure latch stores the newest incident while
  -- a complex station/track build may have produced several earlier deletes.
  for _, canonicalId in ipairs(util.sortedKeys(registry.byCanonical)) do
    local binding = registry.byCanonical[canonicalId]
    if binding and binding.kind == "edge" then
      local localId = tonumber(binding.localId)
      local custody = localId and worldState.pinnedCustody[tostring(localId)] or nil
      local logicalOwner = localId and worldState.logicalOwners[tostring(localId)] or nil
      logicalOwner = logicalOwner or (custody and custody.logicalOwnerCid)
        or (binding.metadata and binding.metadata.owner)
      local liveEdge = localId and M.entityExists(localId)
        and component(localId, api.type.ComponentType.BASE_EDGE) ~= nil
      if logicalOwner == companyCid and not liveEdge then
        retire(localId, canonicalId, "retired edge from replacement inventory")
      end
    end
  end
  for _, source in ipairs(migration.unmatchedSources or {}) do
    local localId = tonumber(source.entity or source.oldLocalId)
    if localId and not M.entityExists(localId) then
      retire(localId, canonical.resolveCanonical(registry, "edge", localId),
        "unmatched replacement source no longer exists")
    end
  end

  -- Re-adopt both permitted native inventories.  claimEntities preserves an
  -- existing remembered rival owner, but gives newly observed desk assets to
  -- the active company and pins BASE_EDGE custody without calling setPlayer.
  local participants, seenParticipants = {
    { role = "turn-desk", playerId = tonumber(controlPlayerId) },
    { role = "company", playerId = tonumber(companyPlayerId) },
  }, {}
  for _, participant in ipairs(participants) do
    local playerId = participant.playerId
    if playerId and not seenParticipants[playerId] then
      seenParticipants[playerId] = true
      local ids, enumerationError = M.listPlayerOwned(playerId)
      if enumerationError then
        result.error = tostring(enumerationError)
        result.enumerationRole = participant.role
        return false, result
      end
      local adoption = M.claimEntities(registry, ids, playerId,
        tostring(eventId or "edge-recovery") .. ":" .. participant.role, {
          bindExisting = true,
          logicalOwnerCid = companyCid,
          worldState = worldState,
        })
      result.inventories[#result.inventories + 1] = {
        role = participant.role,
        playerId = playerId,
        count = #ids,
        adoption = adoption,
      }
      if #(adoption.failed or {}) > 0 then
        result.error = "active proxy inventory could not be rebound"
        return false, result
      end
    end
  end

  result.validation = M.validatePinnedEdgeCustody(worldState, controlPlayerId, companies)
  if #(result.validation.failed or {}) > 0 then
    result.error = "recovered edge custody failed its native-owner postcondition"
    return false, result
  end
  result.ok = true
  return true, result
end

function M.transferOwnedByPlayer(worldState, registry, sourcePlayerId, targetPlayerId, logicalOwnerCid, eventId)
  local ids, enumerationError = M.listPlayerOwned(sourcePlayerId)
  if enumerationError then
    return {
      claimed = {},
      failed = { { kind = "enumeration", error = enumerationError } },
      skipped = {},
      pinned = {},
      unchanged = {},
      rollback = { claimed = {}, failed = {}, skipped = {}, pinned = {}, unchanged = {} },
      sourcePlayerId = sourcePlayerId,
      targetPlayerId = targetPlayerId,
    }
  end
  local result = M.claimEntities(registry, ids, targetPlayerId, eventId, {
    bindExisting = true,
    logicalOwnerCid = logicalOwnerCid,
    worldState = worldState,
  })
  result.sourcePlayerId = sourcePlayerId
  result.targetPlayerId = targetPlayerId
  if #result.failed > 0 and #result.claimed > 0 then
    local ids = {}
    for _, claimed in ipairs(result.claimed) do ids[#ids + 1] = claimed.localId end
    result.rollback = M.claimEntities(registry, ids, sourcePlayerId, eventId .. ":rollback", {
      bindExisting = true,
      logicalOwnerCid = logicalOwnerCid,
      worldState = worldState,
    })
  else
    result.rollback = { claimed = {}, failed = {}, skipped = {}, pinned = {}, unchanged = {} }
  end
  return result
end

function M.rollbackTransfer(worldState, registry, transfer, logicalOwnerCid, eventId)
  local ids = {}
  for _, claimed in ipairs(type(transfer) == "table" and transfer.claimed or {}) do
    ids[#ids + 1] = claimed.localId
  end
  if #ids == 0 then return { claimed = {}, failed = {}, skipped = {}, pinned = {}, unchanged = {} } end
  return M.claimEntities(registry, ids, transfer.sourcePlayerId, eventId, {
    bindExisting = true,
    logicalOwnerCid = logicalOwnerCid,
    worldState = worldState,
  })
end

function M.logicalOwnerOf(worldState, companies, id)
  local playerId = M.ownerOf(id)
  local remembered = worldState and worldState.logicalOwners and worldState.logicalOwners[tostring(id)]
  if remembered and companies and companies[remembered] then
    -- Network peers use different native representatives for the same
    -- canonical company.  Once an entity has been admitted to the canonical
    -- ownership map, that map is authoritative; native ownership is only a
    -- machine-local execution detail.
    if worldState.logicalOwnershipAuthoritative == true then return remembered end
    if tonumber(companies[remembered].playerId) == tonumber(playerId) then return remembered end
    local pinned = worldState and worldState.pinnedCustody and worldState.pinnedCustody[tostring(id)]
    if pinned and tonumber(worldState.controlPlayerId) == tonumber(playerId) then return remembered end
    local rememberedTurn = worldState and worldState.turn
    if rememberedTurn and rememberedTurn.active and rememberedTurn.companyCid == remembered
      and tonumber(worldState.controlPlayerId) == tonumber(playerId) then
      return remembered
    end
  end
  for companyCid, company in pairs(companies or {}) do
    if tonumber(company.playerId) == tonumber(playerId) then return companyCid end
  end
  local turn = worldState and worldState.turn
  if turn and turn.active and tonumber(worldState.controlPlayerId) == tonumber(playerId) then return turn.companyCid end
  return nil
end

function M.ownershipSummary(worldState, companies)
  local result = {
    companies = {},
    unassigned = { total = 0, byKind = {} },
    pinned = { total = 0, byKind = {}, companies = {} },
    total = 0,
    errors = {},
  }
  for companyCid, _ in pairs(companies or {}) do
    result.companies[companyCid] = { total = 0, byKind = {} }
    result.pinned.companies[companyCid] = { total = 0, byKind = {} }
  end
  local ownedType = api.type.ComponentType.PLAYER_OWNED
  if not (api.engine.forEachEntityWithComponent and ownedType) then return result end
  local ok, err = pcall(function()
    api.engine.forEachEntityWithComponent(function(entity)
      local id = tonumber(entity)
      local kind = M.kindOf(id)
      local companyCid = M.logicalOwnerOf(worldState, companies, id)
      local bucket = companyCid and result.companies[companyCid] or result.unassigned
      bucket.total = bucket.total + 1
      bucket.byKind[kind] = (bucket.byKind[kind] or 0) + 1
      result.total = result.total + 1
      local pinned = worldState and worldState.pinnedCustody and worldState.pinnedCustody[tostring(id)]
      if pinned then
        local pinnedCompany = pinned.logicalOwnerCid and result.pinned.companies[pinned.logicalOwnerCid]
          or { total = 0, byKind = {} }
        if pinned.logicalOwnerCid and not result.pinned.companies[pinned.logicalOwnerCid] then
          result.pinned.companies[pinned.logicalOwnerCid] = pinnedCompany
        end
        result.pinned.total = result.pinned.total + 1
        result.pinned.byKind[kind] = (result.pinned.byKind[kind] or 0) + 1
        pinnedCompany.total = pinnedCompany.total + 1
        pinnedCompany.byKind[kind] = (pinnedCompany.byKind[kind] or 0) + 1
      end
    end, ownedType)
  end)
  if not ok then result.errors[#result.errors + 1] = tostring(err) end
  return result
end

local stationReading = stationReadingModule.new({
  getApi = function() return api end,
  entityNumber = entityNumber,
})
local stationGroupTown = stationReading.stationGroupTown
M.stationGroupTown = stationGroupTown
local lineReading = lineReadingModule.new({
  getApi = function() return api end,
  entityNumber = entityNumber,
})
local lineServiceKind = lineReading.lineServiceKind
M.lineServiceKind = lineServiceKind

-- Raw native land-use capacity. The crowd policy scales this at load, so it is
-- telemetry and readback-probe input only and must never reach the economy;
-- `townBuildingCount` is the policy-independent town size the model consumes.
-- The third return reports whether the reading is real: the fallback keeps
-- callers alive, but it makes every town identical, which would otherwise read
-- as a uniformly flat world instead of a failed read.
local function townCapacity(townId)
  local system = api.engine.system.townBuildingSystem
  if system and system.getLandUsePersonCapacities then
    local ok, capacities = pcall(system.getLandUsePersonCapacities, townId)
    if ok and capacities then
      return util.integer((capacities[1] or 0) + (capacities[2] or 0) + (capacities[3] or 0), 0),
        capacities, true
    end
  end
  return 300, { 100, 100, 100 }, false
end

local function lineVehicleCount(lineId)
  local system = api.engine.system.transportVehicleSystem
  if system and system.getLineVehicles then
    local ok, vehicles = pcall(system.getLineVehicles, lineId)
    if ok and vehicles then return #sortedNumbers(vehicles) end
  end
  return 0
end

local function lineVehicleIds(lineId)
  local system = api.engine.system.transportVehicleSystem
  if system and system.getLineVehicles then
    local ok, vehicles = pcall(system.getLineVehicles, lineId)
    if ok and vehicles then return sortedNumbers(vehicles) end
  end
  return {}
end

local corridorBindingModule = require "tpf2_mp/corridor_binding"
M.SERVICE_FACTS = corridorBindingModule.SERVICE_FACTS
M.TOWN_GROWTH = corridorBindingModule.TOWN_GROWTH
M.consistTransportFacts = corridorBindingModule.consistTransportFacts
M.gravityDemand = corridorBindingModule.gravityDemand
M.carriedByTown = corridorBindingModule.carriedByTown
M.townGrowthTargets = corridorBindingModule.townGrowthTargets
M.departureSchedule = corridorBindingModule.departureSchedule
M.synchronizationSchedule = corridorBindingModule.synchronizationSchedule
M.departureSlots = corridorBindingModule.departureSlots
M.stationBoards = corridorBindingModule.stationBoards
local corridorBinding = corridorBindingModule.new({
  bindExisting = function(...) return M.bindExisting(...) end,
  lineStopGroups = lineStopGroups,
  lineServiceKind = lineServiceKind,
  stationGroupTown = stationGroupTown,
  townCapacity = townCapacity,
  townBuildingCount = townBuildingCount,
  lineVehicleIds = lineVehicleIds,
  nameOf = nameOf,
  safeEntity = safeEntity,
  positionOfEntity = resolvedPositionOfEntity,
  developmentPositionOfEntity = developmentPositionOfEntity,
  developmentPositionsOfTown = developmentPositionsOfTown,
  resolveLocal = function(registry, cid) return canonical.resolveLocal(registry, cid) end,
  resolveCanonical = function(registry, kind, localId)
    return canonical.resolveCanonical(registry, kind, localId)
  end,
})
M.computedServiceFacts = corridorBinding.computedServiceFacts
M.makeLineService = corridorBinding.makeLineService
M.applyTownGrowth = corridorBinding.applyTownGrowth
M.applyTownDevelopment = corridorBinding.applyTownDevelopment
M.runOrderedDevelopment = corridorBinding.runOrderedDevelopment
M.settleDevelopment = corridorBinding.settleDevelopment
M.autoRegisterLine = corridorBinding.autoRegisterLine
M.autoRegisterExistingServices = corridorBinding.autoRegisterExistingServices
M.accumulateDevelopment = corridorBindingModule.accumulateDevelopment
M.TOWN_DEVELOPMENT = corridorBindingModule.TOWN_DEVELOPMENT

M.townCapacity = townCapacity

function M.freezeAutonomy(worldState, freeze)
  local result = { freeze = freeze and true or false, towns = 0, industries = 0, errors = {} }
  for _, townId in ipairs(M.listTowns()) do
    local ok, err = pcall(game.interface.setTownDevelopmentActive, townId, not freeze)
    if ok then result.towns = result.towns + 1 else result.errors[#result.errors + 1] = tostring(err) end
  end
  local setManualDevelopment = util.commandFactory("setSimBuildingManualDevelopment")
  if setManualDevelopment and api.cmd and type(api.cmd.sendCommand) == "function" then
    for _, industryId in ipairs(M.listIndustries()) do
      local commandOk, commandOrError = pcall(
        setManualDevelopment, industryId, freeze and true or false)
      local ok, err = false, commandOrError
      if commandOk then
        ok, err = util.sendCommand(
          commandOrError, nil, "mod.world.set-industry-manual-development")
      end
      if ok then result.industries = result.industries + 1 else result.errors[#result.errors + 1] = tostring(err) end
    end
  end
  worldState.autonomyFrozen = freeze and true or false
  worldState.lastFreezeResult = result
  return result
end

function M.structuralSnapshot(registry, worldState, companies)
  local towns, lines, vehicles, depots, objects = {}, {}, {}, {}, {}
  for _, townId in ipairs(M.listTowns()) do
    local cid = M.bindExisting(registry, townId, "town", { name = nameOf(townId) })
    local total, capacities = townCapacity(townId)
    local townComponent = component(townId, api.type.ComponentType.TOWN)
    local developmentActive
    if townComponent then developmentActive = townComponent.developmentActive end
    towns[#towns + 1] = {
      cid = cid,
      name = nameOf(townId),
      capacities = { util.integer(capacities[1]), util.integer(capacities[2]), util.integer(capacities[3]) },
      totalCapacity = total,
      developmentActive = developmentActive,
    }
  end
  for _, lineId in ipairs(M.listLines()) do
    local cid = M.bindExisting(registry, lineId, "line", { name = nameOf(lineId) })
    local stops = {}
    for _, groupId in ipairs(lineStopGroups(lineId)) do
      stops[#stops + 1] = M.bindExisting(registry, groupId, "station_group", { name = nameOf(groupId) })
    end
    lines[#lines + 1] = {
      cid = cid,
      name = nameOf(lineId),
      stops = stops,
      vehicles = lineVehicleCount(lineId),
      owner = M.logicalOwnerOf(worldState, companies or {}, lineId),
    }
  end
  for _, vehicleId in ipairs(M.listVehicles()) do
    local cid = M.bindExisting(registry, vehicleId, "vehicle", { name = nameOf(vehicleId) })
    local transportVehicle = component(vehicleId, api.type.ComponentType.TRANSPORT_VEHICLE)
    local lineId = transportVehicle and tonumber(transportVehicle.line) or nil
    local lineCid
    if lineId and lineId >= 0 and M.entityExists(lineId) then lineCid = M.bindExisting(registry, lineId, "line", { name = nameOf(lineId) }) end
    vehicles[#vehicles + 1] = {
      cid = cid,
      name = nameOf(vehicleId),
      lineCid = lineCid,
      owner = M.logicalOwnerOf(worldState, companies or {}, vehicleId),
    }
  end
  for _, depotId in ipairs(M.listDepots()) do
    depots[#depots + 1] = {
      cid = M.bindExisting(registry, depotId, "depot", { name = nameOf(depotId) }),
      name = nameOf(depotId),
      owner = M.logicalOwnerOf(worldState, companies or {}, depotId),
    }
  end
  -- A probe is deliberately exhaustive: bind every ownership-bearing object so
  -- tracks, station sub-entities, signals, and edge objects cannot hide outside
  -- the canonical snapshot merely because a GUI event omitted them.
  for _, entityId in ipairs(M.listAllPlayerOwned()) do
    M.bindExisting(registry, entityId, M.kindOf(entityId), { name = nameOf(entityId) })
  end
  table.sort(towns, function(a, b) return tostring(a.cid) < tostring(b.cid) end)
  table.sort(lines, function(a, b) return tostring(a.cid) < tostring(b.cid) end)
  table.sort(vehicles, function(a, b) return tostring(a.cid) < tostring(b.cid) end)
  table.sort(depots, function(a, b) return tostring(a.cid) < tostring(b.cid) end)
  for _, cid in ipairs(util.sortedKeys(registry.byCanonical)) do
    local binding = registry.byCanonical[cid]
    local exists = true
    if api.engine.entityExists then
      local ok, result = pcall(api.engine.entityExists, binding.localId)
      exists = ok and result == true
    else
      exists = safeEntity(binding.localId) ~= nil or component(binding.localId, api.type.ComponentType[binding.kind and string.upper(binding.kind) or ""]) ~= nil
    end
    local owner
    if exists and api.type.ComponentType.PLAYER_OWNED then
      local owned = component(binding.localId, api.type.ComponentType.PLAYER_OWNED)
      local playerId = owned and (owned.player or owned.playerEntity)
      owner = M.logicalOwnerOf(worldState, companies or {}, binding.localId)
        or (playerId and canonical.resolveCanonical(registry, "company", playerId) or nil)
    end
    objects[#objects + 1] = {
      cid = cid,
      kind = binding.kind,
      exists = exists,
      fingerprint = exists and M.fingerprint(binding.localId, binding.kind) or nil,
      owner = owner,
    }
  end
  local snapshot = {
    towns = towns,
    lines = lines,
    vehicles = vehicles,
    depots = depots,
    objects = objects,
    industryCount = #M.listIndustries(),
    vehicleCount = #vehicles,
    depotCount = #depots,
    constructionCount = 0,
  }
  if api.engine.forEachEntityWithComponent then
    pcall(function()
      api.engine.forEachEntityWithComponent(function() snapshot.constructionCount = snapshot.constructionCount + 1 end, api.type.ComponentType.CONSTRUCTION)
    end)
  end
  snapshot.digest = hash.value(snapshot)
  return snapshot
end

local function systemListCount(system, functionName, entity, errors)
  local fn = system and system[functionName]
  -- Generated engine bindings are callable tables on Build 35924. Treating
  -- only native Lua functions as available silently disabled the official
  -- sim-person and sim-cargo readbacks in the real game.
  if not util.isCallable(fn) then return nil, false end
  local ok, values = pcall(fn, entity)
  if not ok then
    errors[#errors + 1] = functionName .. ": " .. tostring(values)
    return nil, true
  end
  return #sortedNumbers(values or {}), true
end

local function safeComponentField(value, key)
  if type(value) ~= "table" and type(value) ~= "userdata" then return nil end
  local ok, nested = pcall(function() return value[key] end)
  if not ok then return nil end
  return nested
end

local function vehicleConsistNames(transportVehicle)
  local config = safeComponentField(transportVehicle, "transportVehicleConfig")
  local values = safeComponentField(config, "vehicles")
  local repository = api and api.res and api.res.modelRep
  local getName = repository and repository.getName
  local wrappers = {}
  if type(values) == "table" then
    for index, value in ipairs(values) do
      if index > 128 then break end
      wrappers[#wrappers + 1] = value
    end
  elseif type(values) == "userdata" then
    local lengthOk, length = pcall(function() return #values end)
    if lengthOk and tonumber(length) then
      for index = 1, math.min(128, math.max(0, math.floor(tonumber(length)))) do
        local itemOk, value = pcall(function() return values[index] end)
        if itemOk then wrappers[#wrappers + 1] = value end
      end
    end
  end
  local names, known = {}, util.isCallable(getName) and config ~= nil
  for _, wrapper in ipairs(wrappers) do
    local part = safeComponentField(wrapper, "part") or wrapper
    local modelId = tonumber(safeComponentField(part, "modelId"))
    local name
    if known and modelId then
      local nameOk, value = pcall(getName, modelId)
      if nameOk and value ~= nil and tostring(value) ~= "" then name = tostring(value) end
    end
    if not name then known = false end
    names[#names + 1] = name or "<unavailable>"
  end
  return names, known, #wrappers
end

local function enumerateComponent(componentType, label, errors, visitor)
  if not (componentType and api and api.engine
      and util.isCallable(api.engine.forEachEntityWithComponent)) then
    return 0, false
  end
  local count = 0
  local ok, err = pcall(function()
    api.engine.forEachEntityWithComponent(function(entity)
      count = count + 1
      if visitor then visitor(tonumber(entity) or entity) end
    end, componentType)
  end)
  if not ok then
    errors[#errors + 1] = tostring(label) .. ": " .. tostring(err)
    return 0, true
  end
  return count, true
end

-- Read-only native-simulation telemetry. Entity IDs deliberately never leave
-- this function: counts and vehicle state are keyed by canonical identity. A
-- person, cargo item, line, or vehicle changing local entity ID therefore
-- cannot by itself create a false network mismatch.
function M.mobilitySnapshot(registry, worldState)
  local systems = api and api.engine and api.engine.system or {}
  local types = api and api.type and api.type.ComponentType or {}
  local personSystem = systems.simPersonSystem
  local cargoSystem = systems.simCargoSystem
  local terminalSystem = systems.simPersonAtTerminalSystem
  local errors = {}
  local availability = {
    totalPersons = util.isCallable(personSystem and personSystem.getCount),
    linePassengers = util.isCallable(personSystem and personSystem.getSimPersonsForLine),
    lineCargo = util.isCallable(cargoSystem and cargoSystem.getSimCargosForLine),
    terminalInfo = util.isCallable(terminalSystem and terminalSystem.getEdgeInfoMap),
    terminalFreePlaces = util.isCallable(terminalSystem and terminalSystem.getNumFreePlaces),
    directPersonEntities = types.SIM_PERSON ~= nil
      and util.isCallable(api and api.engine and api.engine.forEachEntityWithComponent) or false,
    directCargoEntities = types.SIM_CARGO ~= nil
      and util.isCallable(api and api.engine and api.engine.forEachEntityWithComponent) or false,
    directEntitiesAtVehicle = types.SIM_ENTITY_AT_VEHICLE ~= nil
      and util.isCallable(api and api.engine and api.engine.forEachEntityWithComponent) or false,
    directEntitiesAtTerminal = types.SIM_ENTITY_AT_TERMINAL ~= nil
      and util.isCallable(api and api.engine and api.engine.forEachEntityWithComponent) or false,
    vehicleLifecycle = types.TRANSPORT_VEHICLE ~= nil,
  }
  local totalPersons
  if availability.totalPersons then
    local ok, value = pcall(personSystem.getCount)
    if ok then totalPersons = util.integer(value, 0) else errors[#errors + 1] = "getCount: " .. tostring(value) end
  end


  -- The convenience systems above are absent in several real game Lua states.
  -- Their backing ECS components are nevertheless public and enumerable. Read
  -- those directly as a second path. Only aggregate counts leave this function;
  -- volatile person/cargo/vehicle entity IDs never do.
  local direct = {
    persons = nil,
    cargoEntities = nil,
    atVehicle = { persons = 0, cargo = 0, unknown = 0 },
    atTerminal = { persons = 0, cargo = 0, unknown = 0 },
    line = {},
  }
  local function directLine(lineId)
    lineId = tonumber(lineId)
    if not lineId or lineId < 0 then return nil end
    local current = direct.line[lineId]
    if not current then
      current = {
        passengersOnVehicle = 0,
        cargoOnVehicle = 0,
        unknownOnVehicle = 0,
        passengersWaiting = 0,
        cargoWaiting = 0,
        unknownWaiting = 0,
      }
      direct.line[lineId] = current
    end
    return current
  end
  local personCount, personEnumerated = enumerateComponent(
    types.SIM_PERSON, "enumerate SIM_PERSON", errors)
  if personEnumerated then direct.persons = personCount end
  local cargoCount, cargoEnumerated = enumerateComponent(
    types.SIM_CARGO, "enumerate SIM_CARGO", errors)
  if cargoEnumerated then direct.cargoEntities = cargoCount end

  enumerateComponent(types.SIM_ENTITY_AT_VEHICLE, "enumerate SIM_ENTITY_AT_VEHICLE", errors,
    function(entity)
      local relation = component(entity, types.SIM_ENTITY_AT_VEHICLE)
      local line = directLine(safeComponentField(relation, "line"))
      local isPerson = component(entity, types.SIM_PERSON) ~= nil
        or component(entity, types.SIM_PERSON_AT_VEHICLE) ~= nil
      local isCargo = component(entity, types.SIM_CARGO) ~= nil
      if isPerson then
        direct.atVehicle.persons = direct.atVehicle.persons + 1
        if line then line.passengersOnVehicle = line.passengersOnVehicle + 1 end
      elseif isCargo then
        direct.atVehicle.cargo = direct.atVehicle.cargo + 1
        if line then line.cargoOnVehicle = line.cargoOnVehicle + 1 end
      else
        direct.atVehicle.unknown = direct.atVehicle.unknown + 1
        if line then line.unknownOnVehicle = line.unknownOnVehicle + 1 end
      end
    end)
  enumerateComponent(types.SIM_ENTITY_AT_TERMINAL, "enumerate SIM_ENTITY_AT_TERMINAL", errors,
    function(entity)
      local relation = component(entity, types.SIM_ENTITY_AT_TERMINAL)
      local line = directLine(safeComponentField(relation, "line"))
      local isPerson = component(entity, types.SIM_PERSON) ~= nil
        or component(entity, types.SIM_PERSON_AT_TERMINAL) ~= nil
      local isCargo = component(entity, types.SIM_CARGO) ~= nil
        or component(entity, types.SIM_CARGO_AT_TERMINAL) ~= nil
      if isPerson then
        direct.atTerminal.persons = direct.atTerminal.persons + 1
        if line then line.passengersWaiting = line.passengersWaiting + 1 end
      elseif isCargo then
        direct.atTerminal.cargo = direct.atTerminal.cargo + 1
        if line then line.cargoWaiting = line.cargoWaiting + 1 end
      else
        direct.atTerminal.unknown = direct.atTerminal.unknown + 1
        if line then line.unknownWaiting = line.unknownWaiting + 1 end
      end
    end)
  if totalPersons == nil then totalPersons = direct.persons end

  local lines = {}
  local passengerLineUses, cargoLineUses, vehicleCount = 0, 0, 0
  for _, lineId in ipairs(M.listLines()) do
    local lineCid = M.bindExisting(registry, lineId, "line", { name = nameOf(lineId) })
    local passengers = systemListCount(personSystem, "getSimPersonsForLine", lineId, errors)
    local cargo = systemListCount(cargoSystem, "getSimCargosForLine", lineId, errors)
    local directCounts = direct.line[tonumber(lineId)] or {
      passengersOnVehicle = 0, cargoOnVehicle = 0, unknownOnVehicle = 0,
      passengersWaiting = 0, cargoWaiting = 0, unknownWaiting = 0,
    }
    local directPassengers = directCounts.passengersOnVehicle + directCounts.passengersWaiting
    local directCargo = directCounts.cargoOnVehicle + directCounts.cargoWaiting
    if passengers == nil and (availability.directEntitiesAtVehicle
        or availability.directEntitiesAtTerminal) then
      passengers = directPassengers
    end
    if cargo == nil and (availability.directEntitiesAtVehicle
        or availability.directEntitiesAtTerminal) then
      cargo = directCargo
    end
    local vehicles = lineVehicleCount(lineId)
    passengerLineUses = passengerLineUses + (passengers or 0)
    cargoLineUses = cargoLineUses + (cargo or 0)
    vehicleCount = vehicleCount + vehicles
    lines[#lines + 1] = {
      lineCid = lineCid,
      passengerCount = passengers,
      cargoCount = cargo,
      vehicleCount = vehicles,
      direct = directCounts,
    }
  end
  table.sort(lines, function(a, b) return tostring(a.lineCid) < tostring(b.lineCid) end)

  -- Separate authored/lifecycle state from route phase. The former must agree
  -- after every canonical operation; the latter can differ for a few frames
  -- while independently simulated peers execute the same ordered command.
  --
  -- Native userStopped is deliberately not lifecycle authority. The network
  -- station barrier temporarily changes that bit on each peer at different
  -- wall-clock instants. Manual stop intent is already canonical binding
  -- metadata written by the ordered vehicle.stop operation, so digest that
  -- intent and expose the native actuator bit only as non-digested diagnostics.
  -- stopIndex is still important: a persistent mismatch means the trains are
  -- serving different stations, not merely rendering at different metres.
  local vehicleLifecycle, vehiclePhases, vehicleStopDiagnostics = {}, {}, {}
  for _, vehicleId in ipairs(M.listVehicles()) do
    local vehicleCid = M.bindExisting(registry, vehicleId, "vehicle", { name = nameOf(vehicleId) })
    local transportVehicle = component(vehicleId, types.TRANSPORT_VEHICLE)
    local lineId = tonumber(safeComponentField(transportVehicle, "line"))
    local lineCid
    if lineId and lineId >= 0 and M.entityExists(lineId) then
      lineCid = M.bindExisting(registry, lineId, "line", { name = nameOf(lineId) })
    end
    local models, consistKnown, vehicleParts = vehicleConsistNames(transportVehicle)
    local binding = registry.byCanonical and registry.byCanonical[vehicleCid] or nil
    local metadata = binding and binding.metadata or {}
    local nativeUserStopped = safeComponentField(transportVehicle, "userStopped") == true
    vehicleLifecycle[#vehicleLifecycle + 1] = {
      vehicleCid = vehicleCid,
      ownerCid = metadata.owner,
      lineCid = lineCid,
      requestedStopped = metadata.userStopped == true,
      sellOnArrival = safeComponentField(transportVehicle, "sellOnArrival") == true,
      vehicleParts = vehicleParts,
      consistKnown = consistKnown,
      consistModels = models,
    }
    local syncEntry = worldState and worldState.vehicleSync
      and worldState.vehicleSync.vehicles and worldState.vehicleSync.vehicles[vehicleCid] or nil
    vehicleStopDiagnostics[#vehicleStopDiagnostics + 1] = {
      vehicleCid = vehicleCid,
      requestedStopped = metadata.userStopped == true,
      nativeUserStopped = nativeUserStopped,
      barrierManaged = syncEntry ~= nil,
    }
    local stopIndex = tonumber(safeComponentField(transportVehicle, "stopIndex"))
    vehiclePhases[#vehiclePhases + 1] = {
      vehicleCid = vehicleCid,
      lineCid = lineCid,
      stopIndex = stopIndex and math.floor(stopIndex) or nil,
    }
  end
  table.sort(vehicleLifecycle,
    function(a, b) return tostring(a.vehicleCid) < tostring(b.vehicleCid) end)
  table.sort(vehiclePhases,
    function(a, b) return tostring(a.vehicleCid) < tostring(b.vehicleCid) end)
  table.sort(vehicleStopDiagnostics,
    function(a, b) return tostring(a.vehicleCid) < tostring(b.vehicleCid) end)
  local vehicleLifecycleView = { schemaVersion = 2, vehicles = vehicleLifecycle }
  local vehiclePhaseView = { schemaVersion = 1, vehicles = vehiclePhases }

  -- TerminalInfo is intentionally opaque in the published API. We count its
  -- entries and use the documented getNumFreePlaces accessor, without relying
  -- on undocumented userdata layout or transmitting EdgeIds.
  local terminalEdges, terminalFreePlaces
  if availability.terminalInfo then
    local ok, edgeInfo = pcall(terminalSystem.getEdgeInfoMap)
    if ok and type(edgeInfo) == "table" then
      terminalEdges, terminalFreePlaces = 0, 0
      for edgeId, _ in pairs(edgeInfo) do
        terminalEdges = terminalEdges + 1
        if availability.terminalFreePlaces then
          local freeOk, free = pcall(terminalSystem.getNumFreePlaces, edgeId)
          if freeOk then
            terminalFreePlaces = terminalFreePlaces + math.max(0, util.integer(free, 0))
          else
            errors[#errors + 1] = "getNumFreePlaces: " .. tostring(free)
          end
        end
      end
    else
      errors[#errors + 1] = "getEdgeInfoMap: " .. tostring(edgeInfo)
    end
  end

  local digestView = {
    schemaVersion = 4,
    availability = availability,
    totalPersons = totalPersons,
    terminalEdges = terminalEdges,
    terminalFreePlaces = terminalFreePlaces,
    lines = lines,
    vehicleLifecycle = vehicleLifecycle,
    vehiclePhases = vehiclePhases,
    totals = {
      passengerLineUses = passengerLineUses,
      cargoLineUses = cargoLineUses,
      vehicles = vehicleCount,
      directPersons = direct.persons,
      directCargoEntities = direct.cargoEntities,
      passengersOnVehicle = direct.atVehicle.persons,
      cargoOnVehicle = direct.atVehicle.cargo,
      unknownOnVehicle = direct.atVehicle.unknown,
      passengersWaiting = direct.atTerminal.persons,
      cargoWaiting = direct.atTerminal.cargo,
      unknownWaiting = direct.atTerminal.unknown,
    },
  }
  local snapshot = util.deepCopy(digestView)
  snapshot.scope = "native-read-only-aggregate"
  snapshot.errors = errors
  snapshot.vehicleStopDiagnostics = vehicleStopDiagnostics
  snapshot.vehicleLifecycleDigest = hash.value(vehicleLifecycleView)
  snapshot.vehiclePhaseDigest = hash.value(vehiclePhaseView)
  snapshot.digest = hash.value(digestView)
  return snapshot
end

-- Inject only the private native queries required by read-only telemetry.
local operationalTelemetry = operationalTelemetryModule.new({
  component = component, safeField = safeComponentField,
  listTowns = M.listTowns, listIndustries = M.listIndustries,
  bindExisting = M.bindExisting, nameOf = nameOf, fingerprint = M.fingerprint,
  structuralSnapshot = M.structuralSnapshot, mobilitySnapshot = M.mobilitySnapshot,
  industryResourceProbe = M.industryResourceProbe,
})
M.autonomySnapshot, M.clockSnapshot = operationalTelemetry.autonomySnapshot,
  operationalTelemetry.clockSnapshot
M.journalSnapshot, M.operationalSnapshot = operationalTelemetry.journalSnapshot,
  operationalTelemetry.operationalSnapshot

function M.capabilityProbe()
  local interface = game and game.interface or {}
  local components = api and api.type and api.type.ComponentType or {}
  local function hasFactory(name)
    return util.commandFactory(name) ~= nil
  end
  local function hasType(path)
    local value = api and api.type
    for part in tostring(path):gmatch("[^.]+") do
      if value == nil then return false end
      local ok, nested = pcall(function() return value[part] end)
      if not ok then return false end
      value = nested
    end
    return value ~= nil and util.isCallable(value.new)
  end
  local buildVersion
  if api and api.util and type(api.util.getBuildVersion) == "function" then
    local ok, value = pcall(api.util.getBuildVersion)
    if ok then buildVersion = tostring(value) end
  end
  local industryResources = industryReading.registryProbe()
  return {
    buildVersion = buildVersion,
    industryResourceRegistry = industryResources.available == true,
    industryResourceDigest = industryResources.digest,
    industryResourceCount = industryResources.resourceCount or 0,
    industryResourceVariants = industryResources.variantCount or 0,
    industryResourceAmbiguous = industryResources.ambiguousCount or 0,
    industryResourceFailures = industryResources.failureCount or 0,
    industryResourceStandardMisses = industryResources.standardMissCount or 0,
    industryResourceModifierCalls = industryResources.loadConstructionCount or 0,
    industryResourceIndustryCalls = industryResources.industryConstructionCount or 0,
    industryResourceError = industryResources.error,
    addPlayer = type(interface.addPlayer) == "function",
    setPlayer = type(interface.setPlayer) == "function",
    setGameSpeed = type(interface.setGameSpeed) == "function",
    getGameSpeed = type(interface.getGameSpeed) == "function",
    setBuildInPauseModeAllowed = type(interface.setBuildInPauseModeAllowed) == "function",
    setMinimumLoan = type(interface.setMinimumLoan) == "function",
    setMaximumLoan = type(interface.setMaximumLoan) == "function",
    getPlayerJournal = type(interface.getPlayerJournal) == "function",
    setTownCapacities = type(interface.setTownCapacities) == "function",
    setTownDevelopmentActive = type(interface.setTownDevelopmentActive) == "function",
    bookJournalEntry = hasFactory("bookJournalEntry"),
    buildProposal = hasFactory("buildProposal"),
    proposalEdgeOwnershipPrimitive = edgeOwnership.supported(),
    buyVehicle = hasFactory("buyVehicle"),
    replaceVehicle = hasFactory("replaceVehicle"),
    createLine = hasFactory("createLine"),
    updateLine = hasFactory("updateLine"),
    deleteLine = hasFactory("deleteLine"),
    saveGame = hasFactory("saveGame"),
    lineType = hasType("Line"),
    lineStopType = hasType("Line.Stop"),
    transportVehicleConfigType = hasType("TransportVehicleConfig"),
    transportVehiclePartType = hasType("TransportVehiclePart"),
    vehiclePartType = hasType("VehiclePart"),
    modelRepFind = api and api.res and api.res.modelRep
      and util.isCallable(api.res.modelRep.find) or false,
    modelRepGetName = api and api.res and api.res.modelRep
      and util.isCallable(api.res.modelRep.getName) or false,
    developTown = hasFactory("developTown"),
    industryManualDevelopment = hasFactory("setSimBuildingManualDevelopment"),
    sendScriptEvent = hasFactory("sendScriptEvent"),
    nativeMirroredBuildProposal = rawget(_G, "tpf2mp_native_binding_buildProposal") ~= nil,
    nativeMirroredSendScriptEvent = rawget(_G, "tpf2mp_native_binding_sendScriptEvent") ~= nil,
    nativeBuildGate = type(rawget(_G, "tpf2mp_native_enable_build_gate")) == "function"
      and type(rawget(_G, "tpf2mp_native_disable_build_gate")) == "function" or false,
    nativeBuildAuthorize = type(rawget(_G, "tpf2mp_native_authorize_build")) == "function",
    interfaceSendScriptEvent = type(interface.sendScriptEvent) == "function",
    simPersonCount = util.isCallable(api and api.engine and api.engine.system
      and api.engine.system.simPersonSystem and api.engine.system.simPersonSystem.getCount),
    simPersonsForLine = util.isCallable(api and api.engine and api.engine.system
      and api.engine.system.simPersonSystem and api.engine.system.simPersonSystem.getSimPersonsForLine),
    simCargosForLine = util.isCallable(api and api.engine and api.engine.system
      and api.engine.system.simCargoSystem and api.engine.system.simCargoSystem.getSimCargosForLine),
    simPersonTerminalInfo = util.isCallable(api and api.engine and api.engine.system
      and api.engine.system.simPersonAtTerminalSystem
      and api.engine.system.simPersonAtTerminalSystem.getEdgeInfoMap),
    directSimPersons = components.SIM_PERSON ~= nil
      and util.isCallable(api and api.engine and api.engine.forEachEntityWithComponent) or false,
    directSimCargo = components.SIM_CARGO ~= nil
      and util.isCallable(api and api.engine and api.engine.forEachEntityWithComponent) or false,
    directSimEntityAtVehicle = components.SIM_ENTITY_AT_VEHICLE ~= nil
      and util.isCallable(api and api.engine and api.engine.forEachEntityWithComponent) or false,
    directSimEntityAtTerminal = components.SIM_ENTITY_AT_TERMINAL ~= nil
      and util.isCallable(api and api.engine and api.engine.forEachEntityWithComponent) or false,
    enumerateEntities = api and api.engine and util.isCallable(api.engine.forEachEntityWithComponent),
    playerOwnedComponent = components.PLAYER_OWNED ~= nil,
    transportVehicleComponent = components.TRANSPORT_VEHICLE ~= nil,
    vehicleDepotComponent = components.VEHICLE_DEPOT ~= nil,
    ioOpen = io and type(io.open) == "function" or false,
  }
end

function M.researchSnapshot(worldState, registry, companies)
  local structural = M.structuralSnapshot(registry, worldState, companies)
  return {
    schemaVersion = 1,
    capabilities = M.capabilityProbe(),
    structural = structural,
    ownership = M.ownershipSummary(worldState, companies),
    proxy = {
      enabled = worldState and worldState.proxyMode == true,
      turn = util.deepCopy(worldState and worldState.turn or nil),
      lastTransition = util.deepCopy(worldState and worldState.lastTransition or nil),
    },
  }
end

return M
