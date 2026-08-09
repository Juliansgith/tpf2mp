local util = require "tpf2_mp/util"
local registrySidecar = require "tpf2_mp/industry_registry_sidecar"

local M = {}

function M.new(deps)
  deps = deps or {}
  local getApi = assert(deps.getApi, "getApi dependency required")
  local getGame = assert(deps.getGame, "getGame dependency required")
  local entityNumber = assert(deps.entityNumber, "entityNumber dependency required")
  local resourceFacts = assert(deps.resourceFacts, "resourceFacts dependency required")
  local registryReader = registrySidecar.new({
    getApi = getApi, getGame = getGame,
    getRuntimeIdentity = deps.getRuntimeIdentity,
    resourceFacts = resourceFacts,
  })

  local function constructionRoot(simBuildingId)
    simBuildingId = entityNumber(simBuildingId)
    if not simBuildingId then return nil, "industry entity id is invalid" end
    local currentApi = getApi()
    local systems = currentApi and currentApi.engine and currentApi.engine.system or {}
    local connector = systems.streetConnectorSystem
    local lookup = connector and connector.getConstructionEntityForSimBuilding
    if util.isCallable(lookup) then
      local ok, value = pcall(lookup, simBuildingId)
      local root = ok and entityNumber(value) or nil
      if root then return root, "streetConnectorSystem" end
    end
    local types = currentApi and currentApi.type and currentApi.type.ComponentType or {}
    local getComponent = currentApi and currentApi.engine and currentApi.engine.getComponent
    if util.isCallable(getComponent) and types.SIM_BUILDING then
      local ok, component = pcall(getComponent, simBuildingId, types.SIM_BUILDING)
      if ok and component ~= nil then
        local fieldOk, value = pcall(function() return component.stockList end)
        local root = fieldOk and entityNumber(value) or nil
        if root then return root, "SIM_BUILDING.stockList" end
      end
    end
    return nil, "industry construction root is unavailable"
  end

  local function recipeForIndustry(simBuildingId)
    local value, registryError = registryReader.registry()
    if not value then return nil, registryError end
    local root, rootSource = constructionRoot(simBuildingId)
    if not root then return nil, rootSource end
    local currentGame = getGame()
    local getEntity = currentGame and currentGame.interface and currentGame.interface.getEntity
    if not util.isCallable(getEntity) then return nil, "game.interface.getEntity is unavailable" end
    local ok, construction = pcall(getEntity, root)
    if not ok or type(construction) ~= "table" then
      return nil, ok and "construction entity is not a table" or tostring(construction)
    end
    local fileName = construction.fileName
    if type(fileName) ~= "string" or fileName == "" then
      return nil, "construction has no portable resource name"
    end
    local recipe, lookupError = resourceFacts.lookup(value, fileName, construction.params or {})
    if not recipe then return nil, lookupError end
    return {
      constructionId = root, rootSource = rootSource, resource = fileName,
      params = util.deepCopy(recipe.params), recipe = recipe, recipeDigest = recipe.digest,
    }
  end

  return {
    registry = registryReader.registry,
    registryProbe = registryReader.probe,
    constructionRoot = constructionRoot,
    recipeForIndustry = recipeForIndustry,
  }
end

return M
