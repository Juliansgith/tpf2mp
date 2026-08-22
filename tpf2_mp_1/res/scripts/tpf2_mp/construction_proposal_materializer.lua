local util = require "tpf2_mp/util"

local M = {}

local function constructionFactory(gameApi)
  local candidates = {}
  local function add(label, factory)
    if factory and factory.new ~= nil then
      candidates[#candidates + 1] = { label = label, factory = factory }
    end
  end
  pcall(function()
    add("SimpleProposal.ConstructionEntity", gameApi.type.SimpleProposal.ConstructionEntity)
  end)
  pcall(function() add("ConstructionEntity", gameApi.type.ConstructionEntity) end)
  for _, candidate in ipairs(candidates) do
    local ok, value = pcall(candidate.factory.new)
    if ok and value ~= nil then return value, candidate end
  end
  return nil, nil
end

local function matrix(gameApi, values)
  if type(values) ~= "table" or #values ~= 16
    or not (gameApi.type.Mat4f and gameApi.type.Vec4f) then
    return nil, "construction transform API is unavailable"
  end
  local columns = {}
  for column = 0, 3 do
    local offset = column * 4
    local ok, value = pcall(gameApi.type.Vec4f.new,
      values[offset + 1], values[offset + 2], values[offset + 3], values[offset + 4])
    if not ok or value == nil then return nil, "construction transform column is unavailable" end
    columns[#columns + 1] = value
  end
  local ok, value = pcall(gameApi.type.Mat4f.new, columns[1], columns[2], columns[3], columns[4])
  if not ok or value == nil then return nil, "construction transform could not be materialised" end
  return value
end

local function localId(cid, options)
  if type(options.resolveLocal) ~= "function" then return nil, "no canonical local resolver" end
  local ok, rawValue, resolveError = pcall(options.resolveLocal, cid)
  local value = ok and tonumber(rawValue) or nil
  if not value or value < 0 then
    return nil, tostring(ok and (resolveError or ("canonical identity is not mapped: " .. tostring(cid)))
      or rawValue)
  end
  return math.floor(value)
end

local function assignRemoval(removals, index, entity)
  local ok, assignError = pcall(function() removals[index] = entity end)
  if not ok then return nil, "construction removal assignment failed: " .. tostring(assignError) end
  return true
end

function M.apply(proposal, spec, options)
  options = options or {}
  local gameApi = options.api or api
  if not (proposal and type(spec) == "table" and gameApi and gameApi.type
    and gameApi.type.SimpleProposal) then
    return nil, "construction proposal materialisation API is unavailable"
  end
  local additions = proposal.constructionsToAdd or proposal.toAdd
  local removals = proposal.constructionsToRemove or proposal.toRemove
  if removals == nil or (spec.mode ~= "remove" and additions == nil) then
    return nil, "construction proposal vectors are unavailable"
  end

  local removed, sourceLocalId = {}, nil
  local function remove(cid)
    local entity, resolveError = localId(cid, options)
    if not entity then return nil, resolveError end
    if not removed[entity] then
      local assigned, assignError = assignRemoval(removals, util.tableCount(removed) + 1, entity)
      if not assigned then return nil, assignError end
      removed[entity] = true
    end
    return entity
  end
  if spec.mode ~= "build" then
    local resolveError
    sourceLocalId, resolveError = remove(spec.sourceCid)
    if not sourceLocalId then return nil, resolveError end
  end
  for _, collateral in ipairs(spec.collateral or {}) do
    local _, resolveError = remove(collateral.cid)
    if resolveError then return nil, resolveError end
  end

  local factoryLabel
  if spec.mode ~= "remove" then
    local construction, factory = constructionFactory(gameApi)
    if not construction then return nil, "ConstructionEntity materialisation API is unavailable" end
    local transform, transformError = matrix(gameApi, spec.transform)
    if not transform then return nil, transformError end
    local nativePlayerId = tonumber(options.nativePlayerId)
    if not nativePlayerId or nativePlayerId < 0 then
      return nil, "construction requires a local native player"
    end
    local assigned, assignError = pcall(function()
      construction.fileName = spec.fileName
      construction.params = util.deepCopy(spec.params)
      construction.transf = transform
      construction.name = ""
      construction.playerEntity = math.floor(nativePlayerId)
      construction.headquarters = false
      additions[1] = construction
    end)
    if not assigned then
      return nil, "construction addition assignment failed: " .. tostring(assignError)
    end
    local roundTripOk, fileName, playerEntity, length = pcall(function()
      return additions[1].fileName, additions[1].playerEntity, #additions
    end)
    if not roundTripOk or fileName ~= spec.fileName
      or tonumber(playerEntity) ~= math.floor(nativePlayerId) or tonumber(length) ~= 1 then
      return nil, "construction addition did not round-trip through SimpleProposal"
    end
    factoryLabel = factory.label
  end

  if spec.mode == "upgrade" then
    local mapped, mapError = pcall(function() proposal.old2new[sourceLocalId] = 0 end)
    if not mapped then return nil, "construction replacement mapping failed: " .. tostring(mapError) end
  end
  return {
    factory = factoryLabel,
    removalCount = util.tableCount(removed),
    sourceLocalId = sourceLocalId,
  }
end

return M
