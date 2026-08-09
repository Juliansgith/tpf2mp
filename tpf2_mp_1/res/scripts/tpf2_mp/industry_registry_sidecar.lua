local util = require "tpf2_mp/util"
local json = require "tpf2_mp/json"

local M = {}

function M.new(deps)
  local resourceFacts = assert(deps.resourceFacts, "resourceFacts dependency required")
  local cachedRegistry, cachedCaptureCount, cachedProbe
  local cachedArtifactText, cachedArtifactRegistry, cachedArtifactError

  local function runtimeConfig()
    local currentApi = deps.getApi()
    local getBaseConfig = currentApi and currentApi.res and currentApi.res.getBaseConfig
    if util.isCallable(getBaseConfig) then
      local ok, baseConfig = pcall(getBaseConfig)
      if ok and type(baseConfig) == "table" and type(baseConfig.tpf2mp) == "table" then
        return baseConfig.tpf2mp
      end
    end
    local currentGame = deps.getGame()
    return currentGame and currentGame.config and currentGame.config.tpf2mp
  end

  local function environment(name)
    if not (os and os.getenv) then return nil end
    local ok, value = pcall(os.getenv, name)
    return ok and value and value ~= "" and value or nil
  end

  local function registry()
    local cfg = runtimeConfig()
    local identity = deps.getRuntimeIdentity and deps.getRuntimeIdentity() or {}
    local root = tostring(identity.root or environment("TPF2MP_BRIDGE_DIR")
      or (cfg and cfg.bridgeDir) or "")
    local peer = tostring(identity.peerId or environment("TPF2MP_PEER_ID")
      or (cfg and cfg.peerId) or "")
    local session = tostring(identity.sessionId or environment("TPF2MP_SESSION_ID")
      or (cfg and cfg.sessionId) or "")
    if root ~= "" and io and io.open then
      local path = root:gsub("\\", "/"):gsub("/+$", "")
        .. "/companion_state/industry_registry.json"
      local file = io.open(path, "rb")
      if file then
        local raw = file:read("*a")
        file:close()
        if raw ~= cachedArtifactText then
          cachedArtifactText = raw
          cachedArtifactRegistry, cachedArtifactError = nil, nil
          local decoded, document = pcall(json.decode, raw)
          if not decoded or type(document) ~= "table" then
            cachedArtifactError = decoded and "industry registry document is not an object"
              or tostring(document)
          elseif tonumber(document.schemaVersion) ~= resourceFacts.SCHEMA_VERSION
              or tostring(document.peer or "") ~= peer
              or tostring(document.session or "") ~= session
              or type(document.digest) ~= "string" or type(document.view) ~= "table" then
            cachedArtifactError = "industry registry document identity or schema is invalid"
          else
            local rebuilt, rebuildError = resourceFacts.fromDigestView(document.view)
            if not rebuilt then
              cachedArtifactError = tostring(rebuildError)
            else
              local digest = resourceFacts.digest(rebuilt)
              local resources, variants, ambiguous = 0, 0, 0
              for _, resource in pairs(rebuilt.resources or {}) do
                resources = resources + 1
                for _, variant in pairs(resource.variants or {}) do
                  variants = variants + 1
                  if resource.declarationAmbiguous or variant.ambiguous then
                    ambiguous = ambiguous + 1
                  end
                end
              end
              if digest ~= document.digest
                  or resources ~= tonumber(document.resourceCount)
                  or variants ~= tonumber(document.variantCount)
                  or ambiguous ~= tonumber(document.ambiguousCount) then
                cachedArtifactError = "industry registry document counts or digest are invalid"
              else
                cachedArtifactRegistry = rebuilt
              end
            end
          end
        end
        if cachedArtifactRegistry then return cachedArtifactRegistry, nil, "companion-sidecar" end
        return nil, cachedArtifactError or "industry registry document is invalid"
      end
    end
    local value = cfg and cfg.industryResourceFacts or nil
    if type(value) ~= "table" then
      return nil, cfg and tostring(cfg.industryResourceFactsError
        or "industry resource registry is unavailable")
        or "mod runFn did not publish industry resource facts"
    end
    return value, nil, "game-config"
  end

  local function probe()
    local value, registryError, registrySource = registry()
    if not value then return {
      available = false, error = registryError,
      schemaVersion = resourceFacts.SCHEMA_VERSION,
    } end
    local diagnostics = value.diagnostics
    local captureCount = type(diagnostics) == "table"
      and tonumber(diagnostics.captureCount) or 0
    if cachedRegistry == value and cachedCaptureCount == captureCount and cachedProbe then
      return util.deepCopy(cachedProbe)
    end
    local resources, variants, ambiguous = 0, 0, 0
    for _, resource in pairs(value.resources or {}) do
      resources = resources + 1
      for _, variant in pairs(resource.variants or {}) do
        variants = variants + 1
        if variant.ambiguous == true then ambiguous = ambiguous + 1 end
      end
    end
    local failures, misses = 0, 0
    for _ in pairs(type(diagnostics) == "table" and diagnostics.failures or {}) do
      failures = failures + 1
    end
    for _ in pairs(type(diagnostics) == "table" and diagnostics.standardMisses or {}) do
      misses = misses + 1
    end
    local digestOk, digestOrError = pcall(resourceFacts.digest, value)
    cachedRegistry, cachedCaptureCount = value, captureCount
    cachedProbe = {
      available = digestOk and value.overflow ~= true,
      schemaVersion = tonumber(value.schemaVersion),
      digest = digestOk and digestOrError or nil,
      resourceCount = resources, variantCount = variants, ambiguousCount = ambiguous,
      failureCount = failures, standardMissCount = misses,
      overflow = value.overflow == true,
      error = not digestOk and tostring(digestOrError) or nil,
      source = registrySource,
      loadConstructionCount = type(diagnostics) == "table"
        and tonumber(diagnostics.loadConstructionCount) or 0,
      industryConstructionCount = type(diagnostics) == "table"
        and tonumber(diagnostics.industryConstructionCount) or 0,
      typeCounts = util.deepCopy(type(diagnostics) == "table"
        and diagnostics.typeCounts or {}),
    }
    return util.deepCopy(cachedProbe)
  end

  return { registry = registry, probe = probe }
end

return M
