local canonical = require "tpf2_mp/canonical"
local util = require "tpf2_mp/util"
local descriptorModule = require "tpf2_mp/world_topology_descriptor"
local rebindModule = require "tpf2_mp/topology_fingerprint_rebind"

local M = {}

function M.new(deps)
  local descriptor = descriptorModule.new({
    component = deps.component, getApi = deps.getApi,
    positionOf = deps.positionOf, stableName = deps.stableName,
    ownerCid = function(id, _, options)
      options = options or {}
      if options.ownerPinned == true then return options.ownerCid end
      if options.ownerCid ~= nil then return options.ownerCid end
      local logical = options.worldState and options.worldState.logicalOwners
        and options.worldState.logicalOwners[tostring(id)] or nil
      if logical then return logical end
      local nativeOwner = deps.ownerOf(id)
      return options.registry and nativeOwner
        and canonical.resolveCanonical(options.registry, "company", nativeOwner) or nil
    end,
  })

  local function fingerprint(id, kind, options)
    return descriptor.fingerprint(id, kind, options or {}) end
  local function neighbourFingerprint(id, kind, options)
    return descriptor.neighbourFingerprint(id, kind, options or {}) end
  local rebind = rebindModule.new({
    listKind = deps.listKind, fingerprint = deps.fingerprint,
    topologyFingerprint = fingerprint, neighbourFingerprint = neighbourFingerprint,
    entityExists = deps.entityExists, kindOf = deps.kindOf,
  })

  local function find(registry, cid, expectedKind, options)
    options = options or {}
    options.registry = registry
    -- Discovery is used by PREPARE as well as COMMIT.  It must never mutate
    -- canonical identity or custody; resolveExisting performs the eventual
    -- transactional bind/rebind after the ordered commit is accepted.
    options.mutate = false
    local localId, rebindError, details = rebind.resolve(
      registry, cid, expectedKind, options)
    if localId ~= nil then return localId, nil, details end
    if details and details.attempted then return nil, rebindError, details end
    return deps.findIdentityLocal(registry, cid, expectedKind)
  end

  local function decorate(metadata, id, kind, registry, ownerCid)
    metadata.topologyFingerprint = metadata.topologyFingerprint
      or fingerprint(id, kind, { registry = registry, ownerCid = ownerCid })
    metadata.topologyFingerprintVersion = metadata.topologyFingerprint
      and descriptorModule.SCHEMA_VERSION or nil
    metadata.topologyNeighbourFingerprint = metadata.topologyNeighbourFingerprint
      or neighbourFingerprint(id, kind, { registry = registry, ownerCid = ownerCid })
    return metadata
  end

  local function resolveExisting(registry, cid, expectedKind, metadata)
    local suppliedMetadata = metadata or {}
    local worldState = suppliedMetadata.worldState
    metadata = util.deepCopy(suppliedMetadata)
    metadata.worldState = nil
    local localId, findError, details = rebind.resolve(registry, cid, expectedKind, {
      registry = registry, ownerCid = metadata.owner,
      worldState = worldState, mutate = true,
    })
    if localId == nil and not (details and details.attempted) then
      localId, findError = deps.findIdentityLocal(registry, cid, expectedKind)
    end
    if localId == nil then return nil, findError end
    if canonical.resolveLocal(registry, cid) ~= nil then return localId, nil, details end
    local nodeFingerprint, anchorEdgeCid
    if type(cid) == "string" then
      nodeFingerprint, anchorEdgeCid = cid:match(
        "^node:pre:([0-9a-f]+):anchor:(edge:.+)$")
    end
    metadata.fingerprint = metadata.fingerprint
      or (type(cid) == "string" and cid:match(":pre:([0-9a-f]+)$"))
      or nodeFingerprint
    if anchorEdgeCid then metadata.anchorEdgeCid = anchorEdgeCid end
    metadata.lazyResolved = true
    decorate(metadata, localId, expectedKind, registry, metadata.owner)
    local bound, bindError = canonical.bind(
      registry, cid, expectedKind, localId, metadata)
    if not bound then return nil, bindError end
    return localId, nil, details
  end

  return {
    fingerprint = fingerprint, neighbourFingerprint = neighbourFingerprint,
    find = find, resolve = resolveExisting, decorate = decorate,
    expectedConstructionFingerprint = descriptor.expectedConstructionFingerprint,
    schemaVersion = descriptorModule.SCHEMA_VERSION,
  }
end

return M
