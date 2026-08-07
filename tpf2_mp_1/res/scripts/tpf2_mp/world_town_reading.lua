local util = require "tpf2_mp/util"

local M = {}

-- Town structural reading: where a town's buildings stand, and how many there
-- are. Extracted from `world.lua` so the native town->building enumeration has
-- exactly one home and development placement cannot drift away from market
-- sizing.
--
-- Nothing here reads native person capacity. The crowd policy scales that at
-- load, so it describes presentation rather than the town.
function M.new(deps)
  assert(type(deps) == "table", "town reading dependencies are required")
  local resolvedPositionOfEntity = assert(
    deps.resolvedPositionOfEntity, "resolvedPositionOfEntity dependency is required")
  local safeEntity = assert(deps.safeEntity, "safeEntity dependency is required")
  local sortedNumbers = assert(deps.sortedNumbers, "sortedNumbers dependency is required")
  local entityNumber = assert(deps.entityNumber, "entityNumber dependency is required")

  local reading = {}

  -- Entity positions are decimetres in the transform component, while
  -- DevelopTown takes an actual Vec2f world position, so keep that unit
  -- conversion explicit at the dependency boundary.
  local function developmentPositionOfEntity(entity)
    local position = resolvedPositionOfEntity(entity)
    if not position then return nil end
    return { position[1] / 10, position[2] / 10 }
  end

  local function developmentPositionOfTownBuilding(buildingId)
    local direct = developmentPositionOfEntity(buildingId)
    if direct then return direct, "direct" end
    local getConstructionEntity = game and game.interface
      and game.interface.getConstructionEntity or nil
    if util.isCallable(getConstructionEntity) then
      local ok, constructionId = pcall(getConstructionEntity, buildingId)
      constructionId = ok and tonumber(constructionId) or nil
      if constructionId and constructionId >= 0 then
        local position = developmentPositionOfEntity(constructionId)
        if position then return position, "construction" end
      end
    end
    local entity = safeEntity(buildingId)
    if entity then
      for _, field in ipairs({ "construction", "constructionId" }) do
        local constructionId = tonumber(entity[field])
        if constructionId and constructionId >= 0 then
          local position = developmentPositionOfEntity(constructionId)
          if position then return position, "entity-" .. field end
        end
      end
      for _, parcelId in ipairs(sortedNumbers(entity.parcels or {})) do
        local position = developmentPositionOfEntity(parcelId)
        if position then return position, "parcel" end
        if util.isCallable(getConstructionEntity) then
          local ok, constructionId = pcall(getConstructionEntity, parcelId)
          constructionId = ok and tonumber(constructionId) or nil
          position = constructionId and developmentPositionOfEntity(constructionId) or nil
          if position then return position, "parcel-construction" end
        end
      end
    end
    return nil, "unresolved"
  end

  -- Town -> sorted building ids. Shared by development placement and market
  -- sizing so both read one enumeration. Diagnostics are written into the
  -- caller's table when one is supplied.
  local function townBuildingIds(townId, diagnostics)
    diagnostics = diagnostics or {}
    local townBuildingSystem = api and api.engine and api.engine.system
      and api.engine.system.townBuildingSystem or nil
    local townMap
    if townBuildingSystem and util.isCallable(townBuildingSystem.getTown2BuildingMap) then
      local ok, value = pcall(townBuildingSystem.getTown2BuildingMap)
      if ok and (type(value) == "table" or type(value) == "userdata") then
        townMap = value
        diagnostics.mapAvailable = true
        diagnostics.mapType = type(value)
      end
    end
    local buildings
    if townMap then
      local lookupOk, value = pcall(function() return townMap[townId] end)
      if lookupOk then buildings = value end
      -- Ordinary Lua maps may have numeric entity ids serialized as strings.
      if buildings == nil and type(townMap) == "table" then
        for key, candidate in pairs(townMap) do
          if tonumber(key) == tonumber(townId) then buildings = candidate; break end
        end
      end
    end
    diagnostics.lookupType = type(buildings)
    if type(buildings) == "userdata" then
      local lengthOk, length = pcall(function() return #buildings end)
      diagnostics.lookupLengthOk = lengthOk and true or false
      diagnostics.lookupLength = lengthOk and tonumber(length) or nil
      for _, index in ipairs({ 0, 1 }) do
        local itemOk, item = pcall(function() return buildings[index] end)
        diagnostics["probe" .. tostring(index)] = {
          readable = itemOk and item ~= nil,
          valueType = itemOk and type(item) or "error",
          entityNumber = itemOk and entityNumber(item) or nil,
        }
      end
    end
    local buildingIds = sortedNumbers(buildings)
    diagnostics.buildingIds = #buildingIds
    return buildingIds
  end

  -- The model's town-size input, and deliberately not native capacity: the
  -- crowd policy scales capacity, and gravity demand goes as the product of
  -- two town sizes, so a cosmetic setting would rescale the economy by roughly
  -- the square of the policy factor. Building count is policy-independent
  -- because the capacity floor keeps every populated building at one slot or
  -- more under every policy, leaving the building set identical.
  --
  -- Returns nil when the enumeration is unavailable rather than substituting a
  -- number, so the caller decides what an unsized town means.
  local function townBuildingCount(townId)
    local buildingIds = townBuildingIds(townId)
    if #buildingIds == 0 then return nil end
    return #buildingIds
  end

  local function developmentPositionsOfTown(townId)
    local positions, seen = {}, {}
    local diagnostics = {
      mapAvailable = false, mapType = "nil", lookupType = "nil",
      buildingIds = 0, usedFallback = false,
    }
    local function addResolvedPosition(position)
      if not position then return false end
      local key = tostring(position[1]) .. ":" .. tostring(position[2])
      if seen[key] then return false end
      seen[key] = true
      positions[#positions + 1] = position
      return true
    end
    local function addPosition(entityId)
      return addResolvedPosition(developmentPositionOfEntity(entityId))
    end
    local buildingIds = townBuildingIds(townId, diagnostics)
    for _, buildingId in ipairs(buildingIds) do addPosition(buildingId) end
    -- Build 35924 returns town -> building sets as length-bearing userdata that
    -- do not expose numeric indexing. The documented TOWN_BUILDING component
    -- and vanilla getEntity().town field provide a stable read-only fallback.
    diagnostics.componentScanAvailable = false
    diagnostics.componentScanVisited = 0
    diagnostics.componentScanMatched = 0
    diagnostics.componentPositionSources = {}
    local componentType = api and api.type and api.type.ComponentType
      and api.type.ComponentType.TOWN_BUILDING or nil
    local forEach = api and api.engine and api.engine.forEachEntityWithComponent or nil
    if #positions == 0 and componentType and util.isCallable(forEach) then
      diagnostics.componentScanAvailable = true
      local scanOk, scanError = pcall(function()
        forEach(function(entityId)
          diagnostics.componentScanVisited = diagnostics.componentScanVisited + 1
          local entity = safeEntity(entityId)
          local entityTown = entity and entity.town or nil
          if tonumber(entityTown) == tonumber(townId) then
            diagnostics.componentScanMatched = diagnostics.componentScanMatched + 1
            local position, source = developmentPositionOfTownBuilding(entityId)
            diagnostics.componentPositionSources[source] =
              (diagnostics.componentPositionSources[source] or 0) + 1
            addResolvedPosition(position)
          end
        end, componentType)
      end)
      diagnostics.componentScanOk = scanOk and true or false
      if not scanOk then diagnostics.componentScanError = tostring(scanError) end
    end
    if #positions == 0 then
      local fallback = developmentPositionOfEntity(townId)
      if fallback then positions[1] = fallback; diagnostics.usedFallback = true end
    end
    table.sort(positions, function(a, b)
      if a[1] ~= b[1] then return a[1] < b[1] end
      return a[2] < b[2]
    end)
    diagnostics.positions = #positions
    return positions, diagnostics
  end

  reading.developmentPositionOfEntity = developmentPositionOfEntity
  reading.developmentPositionOfTownBuilding = developmentPositionOfTownBuilding
  reading.townBuildingIds = townBuildingIds
  reading.townBuildingCount = townBuildingCount
  reading.developmentPositionsOfTown = developmentPositionsOfTown
  return reading
end

return M
