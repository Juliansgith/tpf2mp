local M = {}
local constructionDeltaAttestation = require "tpf2_mp/construction_delta_attestation"
local topologyGuard = require "tpf2_mp/gui_native_topology_guard"

function M.new(deps)
  local componentEntitySet = assert(deps.componentEntitySet, "component-set reader is required")
  local balanceOf = assert(deps.balanceOf, "balance reader is required")
  local getApi = deps.getApi or function() return rawget(_G, "api") end
  local diagnosticLog = deps.diagnosticLog or function() end

  local function sameEntitySet(first, second)
    for entity in pairs(first or {}) do
      if not (second or {})[entity] then return false end
    end
    for entity in pairs(second or {}) do
      if not (first or {})[entity] then return false end
    end
    return true
  end

  local function capture(types, issuerPlayerId, nativeOwnerPlayerId, expanded,
      transaction, localRefs, topologyOptions)
    local sets = {}
    for _, descriptor in ipairs(
        constructionDeltaAttestation.captureDescriptors(types, expanded)) do
      if descriptor.component ~= nil then
        local values, captureError = componentEntitySet(descriptor.component)
        if not values then return nil, captureError end
        sets[descriptor.name] = values
      elseif descriptor.required then
        return nil, descriptor.name .. " component type is unavailable"
      else
        sets[descriptor.name] = {}
      end
    end
    local topology
    if transaction ~= nil then
      local topologyError
      topology, topologyError = topologyGuard.capture(
        transaction, localRefs, getApi(), topologyOptions)
      if not topology then return nil, topologyError end
    end
    return {
      sets = sets,
      issuerBalance = balanceOf(issuerPlayerId),
      nativeOwnerBalance = balanceOf(nativeOwnerPlayerId), expanded = expanded == true,
      topology = topology,
    }
  end

  local function unchanged(before, types, issuerPlayerId, nativeOwnerPlayerId)
    local after = capture(types, issuerPlayerId, nativeOwnerPlayerId, before.expanded)
    if not after or before.issuerBalance ~= after.issuerBalance
      or before.nativeOwnerBalance ~= after.nativeOwnerBalance then
      return false, "native rejection changed a player balance or world capture failed"
    end
    for name in pairs(before.sets or {}) do
      if not sameEntitySet(before.sets[name], after.sets[name]) then
        return false, "native rejection changed the " .. tostring(name) .. " entity set"
      end
    end
    if before.topology then
      local topologyAfter, topologyError = topologyGuard.recapture(before.topology, getApi())
      if not topologyAfter then
        diagnosticLog("native-rejection-topology-attestation-failed", {
          error = tostring(topologyError), beforeDigest = before.topology.digest,
        })
        return false, tostring(topologyError)
      end
      local same, compareError = topologyGuard.compare(before.topology, topologyAfter)
      if not same then
        diagnosticLog("native-rejection-topology-mutated", {
          error = tostring(compareError), beforeDigest = before.topology.digest,
          afterDigest = topologyAfter.digest,
        })
        return false, compareError
      end
    end
    return true
  end

  local function rejection(before, types, issuerPlayerId, nativeOwnerPlayerId, baseError)
    local same, mutationError = unchanged(
      before, types, issuerPlayerId, nativeOwnerPlayerId)
    local errorText = tostring(baseError)
    if mutationError then errorText = errorText .. "; " .. tostring(mutationError) end
    return errorText, same
  end

  return { capture = capture, unchanged = unchanged, rejection = rejection }
end

return M
