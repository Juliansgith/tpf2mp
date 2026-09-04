local canonical = require "tpf2_mp/canonical"
local util = require "tpf2_mp/util"

local M = { SCHEMA_VERSION = 1 }

function M.new(deps)
  local listKind = assert(deps.listKind, "listKind dependency is required")
  local fingerprint = assert(deps.fingerprint, "fingerprint dependency is required")
  local topologyFingerprint = assert(deps.topologyFingerprint,
    "topologyFingerprint dependency is required")
  local neighbourFingerprint = deps.neighbourFingerprint
  local entityExists = assert(deps.entityExists, "entityExists dependency is required")
  local kindOf = assert(deps.kindOf, "kindOf dependency is required")

  local function available(id, kind)
    return id ~= nil and entityExists(id) and kindOf(id, { componentOnly = true }) == kind
  end

  local function expectedIdentity(registry, cid, kind)
    local binding = registry.byCanonical and registry.byCanonical[cid] or nil
    local metadata = binding and binding.metadata or {}
    local topology = type(metadata.topologyFingerprint) == "string"
      and metadata.topologyFingerprint or nil
    local ordinary = type(metadata.fingerprint) == "string" and metadata.fingerprint or nil
    if not ordinary and type(cid) == "string" then
      ordinary = cid:match("^" .. tostring(kind) .. ":pre:([0-9a-f]+)$")
    end
    local neighbours = type(metadata.topologyNeighbourFingerprint) == "string"
      and metadata.topologyNeighbourFingerprint or nil
    return binding, topology, ordinary, neighbours
  end

  local function candidateOwnerAvailable(registry, kind, localId, cid)
    local occupied = canonical.resolveCanonical(registry, kind, localId)
    return not occupied or occupied == cid, occupied
  end

  local function resolve(registry, cid, kind, options)
    options = options or {}
    local binding, expectedTopology, expectedOrdinary, expectedNeighbours =
      expectedIdentity(registry, cid, kind)
    local current = binding and tonumber(binding.localId) or nil
    if current and available(current, kind) then
      if expectedTopology then
        local observed = topologyFingerprint(current, kind, options)
        if observed == expectedTopology then
          return current, nil, { source = "primary-attested" }
        end
      elseif expectedOrdinary then
        if fingerprint(current, kind) == expectedOrdinary then
          return current, nil, { source = "primary-attested-legacy" }
        end
      else
        return current, nil, { source = "primary" }
      end
    end
    if not expectedTopology and not expectedOrdinary then
      return nil, "canonical identity has no portable fallback fingerprint", { attempted = false }
    end

    local ids = listKind(kind)
    if type(ids) ~= "table" then
      return nil, "fallback enumeration is unavailable for " .. tostring(kind), { attempted = true }
    end
    local matches = {}
    for _, localId in ipairs(ids) do
      if available(localId, kind) then
        local free = candidateOwnerAvailable(registry, kind, localId, cid)
        if free then
          local matched
          if expectedTopology then
            matched = topologyFingerprint(localId, kind, options) == expectedTopology
          else
            matched = fingerprint(localId, kind) == expectedOrdinary
          end
          if matched then matches[#matches + 1] = tonumber(localId) or localId end
        end
      end
    end
    if #matches > 1 and expectedNeighbours and neighbourFingerprint then
      local narrowed = {}
      for _, localId in ipairs(matches) do
        if neighbourFingerprint(localId, kind, options) == expectedNeighbours then
          narrowed[#narrowed + 1] = localId
        end
      end
      if #narrowed > 0 then matches = narrowed end
    end
    if #matches == 0 then
      return nil, "no local " .. tostring(kind) .. " matches the stored topology fingerprint",
        { attempted = true, matches = 0 }
    end
    if #matches ~= 1 then
      return nil, "stored " .. tostring(kind) .. " topology fingerprint is ambiguous across "
        .. tostring(#matches) .. " local objects", { attempted = true, matches = #matches }
    end

    local matched = matches[1]
    local oldLocalId = binding and binding.localId or nil
    local rebindNeeded = binding ~= nil
      and tonumber(binding.localId) ~= tonumber(matched)
    if rebindNeeded and options.mutate ~= false then
      local rebound, result = canonical.rebindLocal(registry, cid, matched, {
        topologyRebound = true,
        topologyRebindVersion = M.SCHEMA_VERSION,
      })
      if not rebound then return nil, result, { attempted = true, matches = 1 } end
      local worldState = options.worldState
      if worldState then
        local oldKey, newKey = tostring(oldLocalId), tostring(matched)
        if worldState.logicalOwners and worldState.logicalOwners[oldKey] ~= nil then
          worldState.logicalOwners[newKey] = worldState.logicalOwners[oldKey]
          worldState.logicalOwners[oldKey] = nil
        end
        if worldState.pinnedCustody and worldState.pinnedCustody[oldKey] ~= nil then
          local custody = util.deepCopy(worldState.pinnedCustody[oldKey])
          custody.nativeReboundFrom = oldLocalId
          worldState.pinnedCustody[newKey] = custody
          worldState.pinnedCustody[oldKey] = nil
        end
      end
    end
    return matched, nil, {
      source = expectedTopology and "topology-fallback" or "legacy-fingerprint-fallback",
      attempted = true, matches = 1,
      oldLocalId = oldLocalId,
      matchedLocalId = matched,
      rebindNeeded = rebindNeeded,
      mutated = rebindNeeded and options.mutate ~= false,
    }
  end

  return { resolve = resolve }
end

return M
