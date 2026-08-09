local util = require "tpf2_mp/util"
local registrySidecar = require "tpf2_mp/industry_registry_sidecar"

local M = {}

function M.new(deps)
  deps = deps or {}
  local getApi = assert(deps.getApi, "getApi dependency required")
  local getGame = assert(deps.getGame, "getGame dependency required")
  local entityNumber = assert(deps.entityNumber, "entityNumber dependency required")
  local resourceFacts = assert(deps.resourceFacts, "resourceFacts dependency required")
  local listIndustries = deps.listIndustries
  local resolveCanonical = deps.resolveCanonical
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

  local function portableFacts(registry)
    if type(listIndustries) ~= "function" or type(resolveCanonical) ~= "function" then
      return nil, "portable industry enumeration is unavailable"
    end
    local result, seen = {}, {}
    for _, localId in ipairs(listIndustries() or {}) do
      local cid = resolveCanonical(registry, localId)
      if type(cid) ~= "string" or not cid:match("^industry:") then
        return nil, "live industry lacks an agreed canonical binding"
      end
      if seen[cid] then return nil, "live industry canonical binding is duplicated" end
      seen[cid] = true
      local facts, factsError = recipeForIndustry(localId)
      if not facts then return nil, tostring(factsError) end
      local recipe = facts.recipe
      result[#result + 1] = {
        cid = cid,
        resource = facts.resource,
        params = util.deepCopy(recipe.params),
        recipeDigest = recipe.digest,
        capacity = recipe.capacity,
        stocks = util.deepCopy(recipe.stocks),
        inputs = util.deepCopy(recipe.inputs),
        outputs = util.deepCopy(recipe.outputs),
      }
    end
    table.sort(result, function(a, b) return a.cid < b.cid end)
    return result
  end

  return {
    registry = registryReader.registry,
    registryProbe = registryReader.probe,
    constructionRoot = constructionRoot,
    recipeForIndustry = recipeForIndustry,
    portableFacts = portableFacts,
  }
end

return M
