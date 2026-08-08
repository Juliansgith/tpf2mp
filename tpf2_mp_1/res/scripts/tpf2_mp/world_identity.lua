local canonical = require "tpf2_mp/canonical"
local util = require "tpf2_mp/util"

local M = {}

local function anchoredNodeParts(cid)
  if type(cid) ~= "string" then return nil end
  local fingerprint, edgeCid = cid:match(
    "^node:pre:([0-9a-f]+):anchor:(edge:.+)$")
  if not fingerprint or edgeCid == "" then return nil end
  return fingerprint, edgeCid
end

function M.new(deps)
  local kindOf = assert(deps.kindOf, "kindOf dependency is required")
  local fingerprint = assert(deps.fingerprint, "fingerprint dependency is required")
  local listKind = assert(deps.listKind, "listKind dependency is required")
  local baseEdge = assert(deps.baseEdge, "baseEdge dependency is required")

  local findPreExistingLocal, identifyExisting

  local function occupiedByOther(registry, kind, localId, cid)
    local occupied = canonical.resolveCanonical(registry, kind, localId)
    if occupied and occupied ~= cid then
      return "matching local " .. kind .. " is already bound to " .. occupied
    end
    return nil
  end

  local function findAnchoredNode(registry, cid, nodeFingerprint, edgeCid)
    local edgeId = canonical.resolveLocal(registry, edgeCid)
    local edgeError
    local edgeBinding = registry.byCanonical[edgeCid]
    if edgeBinding and edgeBinding.kind ~= "edge" then
      return nil, "node anchor canonical identity is not an edge: " .. tostring(edgeCid)
    end
    if edgeId == nil then
      edgeId, edgeError = findPreExistingLocal(registry, edgeCid, "edge")
    end
    if edgeId == nil then
      return nil, "node anchor edge is not locally discoverable: "
        .. tostring(edgeCid) .. " (" .. tostring(edgeError) .. ")"
    end
    local edge = baseEdge(edgeId)
    if not edge then return nil, "node anchor has no local base-edge component" end
    local matches, seen = {}, {}
    for _, endpoint in ipairs({ tonumber(edge.node0), tonumber(edge.node1) }) do
      if endpoint and not seen[endpoint]
        and fingerprint(endpoint, "node") == nodeFingerprint then
        seen[endpoint] = true
        matches[#matches + 1] = endpoint
      end
    end
    if #matches == 0 then
      return nil, "node anchor edge has no endpoint matching fingerprint " .. nodeFingerprint
    end
    if #matches > 1 then
      return nil, "node anchor edge has multiple endpoints matching fingerprint " .. nodeFingerprint
    end
    local occupiedError = occupiedByOther(registry, "node", matches[1], cid)
    if occupiedError then return nil, occupiedError end
    return matches[1]
  end

  findPreExistingLocal = function(registry, cid, expectedKind)
    if type(cid) ~= "string" or cid == "" then
      return nil, "canonical identity is missing"
    end
    local existing = canonical.resolveLocal(registry, cid)
    if existing ~= nil then
      local binding = registry.byCanonical[cid]
      if expectedKind and binding and binding.kind ~= expectedKind then
        return nil, "canonical identity kind differs from expected " .. tostring(expectedKind)
      end
      return existing
    end

    local nodeFingerprint, anchorEdgeCid = anchoredNodeParts(cid)
    if nodeFingerprint then
      if expectedKind and expectedKind ~= "node" then
        return nil, "canonical identity kind differs from expected " .. tostring(expectedKind)
      end
      return findAnchoredNode(registry, cid, nodeFingerprint, anchorEdgeCid)
    end

    local kind, ordinaryFingerprint, suffix = cid:match(
      "^([%w_]+):pre:([0-9a-f]+)(.*)$")
    if not kind or suffix ~= "" then
      return nil, "canonical identity is not a uniquely discoverable pre-existing object: " .. cid
    end
    if expectedKind and kind ~= expectedKind then
      return nil, "canonical identity kind differs from expected " .. tostring(expectedKind)
    end
    local ids = listKind(kind)
    if not ids then return nil, "pre-existing " .. kind .. " enumeration is unavailable" end
    local matches = {}
    for _, localId in ipairs(ids) do
      if fingerprint(localId, kind) == ordinaryFingerprint then
        matches[#matches + 1] = localId
      end
    end
    if #matches == 0 then
      return nil, "no local " .. kind .. " matches canonical fingerprint " .. ordinaryFingerprint
    end
    if #matches > 1 then
      return nil, "canonical " .. kind .. " fingerprint " .. ordinaryFingerprint
        .. " is ambiguous across " .. tostring(#matches) .. " local objects"
    end
    local occupiedError = occupiedByOther(registry, kind, matches[1], cid)
    if occupiedError then return nil, occupiedError end
    return matches[1]
  end

  local function anchoredNodeIdentity(registry, id, nodeFingerprint)
    local candidates, seen = {}, {}
    for _, edgeId in ipairs(listKind("edge") or {}) do
      local edge = baseEdge(edgeId)
      if edge and (tonumber(edge.node0) == id or tonumber(edge.node1) == id) then
        local edgeCid = identifyExisting(registry, edgeId, "edge")
        if edgeCid and not seen[edgeCid] then
          seen[edgeCid] = true
          candidates[#candidates + 1] = edgeCid
        end
      end
    end
    table.sort(candidates)
    local lastError
    for _, edgeCid in ipairs(candidates) do
      local cid = "node:pre:" .. nodeFingerprint .. ":anchor:" .. edgeCid
      local resolved, resolveError = findPreExistingLocal(registry, cid, "node")
      if tonumber(resolved) == id then return cid end
      lastError = resolveError
    end
    return nil, lastError or "ambiguous node has no unique incident edge anchor"
  end

  identifyExisting = function(registry, id, kind)
    id = tonumber(id)
    if id == nil or id < 0 or id ~= math.floor(id) then
      return nil, "existing entity id is invalid"
    end
    kind = kind or kindOf(id)
    if type(kind) ~= "string" or kind == "unknown" or kind == "entity" then
      return nil, "existing entity kind is not canonically identifiable"
    end
    local existing = canonical.resolveCanonical(registry, kind, id)
    if existing then return existing end

    local objectFingerprint = fingerprint(id, kind)
    local cid = canonical.preExistingId(kind, objectFingerprint)
    local resolved, resolveError = findPreExistingLocal(registry, cid, kind)
    if resolved == nil and kind == "node" then
      local anchored, anchorError = anchoredNodeIdentity(registry, id, objectFingerprint)
      if anchored then return anchored end
      return nil, tostring(resolveError) .. "; " .. tostring(anchorError)
    end
    if resolved == nil then return nil, resolveError end
    if tonumber(resolved) ~= id then
      return nil, "canonical identity resolves to a different local " .. tostring(kind)
    end
    return cid
  end

  local function resolvePreExisting(registry, cid, expectedKind, metadata)
    local localId, findError = findPreExistingLocal(registry, cid, expectedKind)
    if localId == nil then return nil, findError end
    if canonical.resolveLocal(registry, cid) ~= nil then return localId end
    local bindingMetadata = util.deepCopy(metadata or {})
    local nodeFingerprint, anchorEdgeCid = anchoredNodeParts(cid)
    bindingMetadata.fingerprint = cid:match(":pre:([0-9a-f]+)$") or nodeFingerprint
    if anchorEdgeCid then bindingMetadata.anchorEdgeCid = anchorEdgeCid end
    bindingMetadata.lazyResolved = true
    local ok, bindError = canonical.bind(
      registry, cid, expectedKind, localId, bindingMetadata)
    if not ok then return nil, bindError end
    return localId
  end

  return {
    findPreExistingLocal = findPreExistingLocal,
    identifyExisting = identifyExisting,
    resolvePreExisting = resolvePreExisting,
  }
end

return M
