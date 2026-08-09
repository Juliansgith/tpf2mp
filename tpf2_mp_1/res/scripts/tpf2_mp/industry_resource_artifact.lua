local hash = require "tpf2_mp/hash"
local json = require "tpf2_mp/json"
local util = require "tpf2_mp/util"

local M = {}

function M.resourceView(facts, fileName, resource)
  local projected = {
    fileName = facts.canonicalResourceName(fileName),
    parameters = util.deepCopy(resource.parameters or {}),
    declarationAmbiguous = resource.declarationAmbiguous == true,
    variants = {},
  }
  for _, parameterKey in ipairs(util.sortedKeys(resource.variants or {})) do
    local variant = resource.variants[parameterKey]
    projected.variants[#projected.variants + 1] = {
      params = util.deepCopy(variant.params or {}),
      recipe = util.deepCopy(variant.recipe or {}),
      recipeDigests = util.deepCopy(variant.recipeDigests or {}),
      ambiguous = variant.ambiguous == true,
    }
  end
  return projected
end

function M.resourceArtifact(facts, registry, fileName)
  if type(registry) ~= "table" or tonumber(registry.schemaVersion) ~= facts.SCHEMA_VERSION
      or type(registry.resources) ~= "table" then
    return nil, "industry registry is invalid"
  end
  fileName = facts.canonicalResourceName(fileName)
  local resource = registry.resources[fileName]
  if not resource then return nil, "industry resource was not captured" end
  local content = {
    schemaVersion = facts.SCHEMA_VERSION,
    resource = M.resourceView(facts, fileName, resource),
  }
  content.digest = hash.value(content)
  return content
end

function M.write(facts, registry, fileName, bridgeDirectory)
  if not (io and io.open) then return false, "industry artifact file I/O is unavailable" end
  local artifact, artifactError = M.resourceArtifact(facts, registry, fileName)
  if not artifact then return false, artifactError end
  local root = tostring(bridgeDirectory or ""):gsub("\\", "/"):gsub("/+$", "")
  if root == "" then return false, "industry artifact bridge directory is unavailable" end
  local target = root .. "/content/industry/" .. hash.text(artifact.resource.fileName)
    .. "-" .. artifact.digest .. ".json"
  local encoded = json.encode(artifact) .. "\n"
  local existing = io.open(target, "rb")
  local existingText = existing and existing:read("*a") or nil
  if existing then existing:close() end
  if existingText == encoded then return true, target end
  local handle, openError = io.open(target, "wb")
  if not handle then return false, tostring(openError) end
  local writeOk, writeError = pcall(function()
    handle:write(encoded); handle:flush(); handle:close()
  end)
  if not writeOk then
    pcall(function() handle:close() end)
    return false, tostring(writeError)
  end
  return true, target
end

return M
