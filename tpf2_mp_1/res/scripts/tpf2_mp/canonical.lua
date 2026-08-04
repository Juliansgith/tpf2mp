local util = require "tpf2_mp/util"

local M = {}

function M.newState()
  return {
    byCanonical = {},
    byLocal = {},
    revisions = 0,
  }
end

local function localKey(kind, localId)
  return tostring(kind) .. ":" .. tostring(localId)
end

function M.createdId(kind, eventId, outputSlot)
  return string.format("%s:event:%s:%d", tostring(kind), tostring(eventId), tonumber(outputSlot) or 1)
end

function M.preExistingId(kind, fingerprint)
  return string.format("%s:pre:%s", tostring(kind), tostring(fingerprint))
end

function M.bind(state, canonicalId, kind, localId, metadata)
  assert(type(canonicalId) == "string" and canonicalId ~= "", "canonicalId required")
  assert(type(kind) == "string" and kind ~= "", "kind required")
  assert(localId ~= nil, "localId required")

  local key = localKey(kind, localId)
  local existingCanonical = state.byLocal[key]
  if existingCanonical and existingCanonical ~= canonicalId then
    return false, "local identity already bound to " .. existingCanonical
  end

  local existing = state.byCanonical[canonicalId]
  if existing and (existing.kind ~= kind or tostring(existing.localId) ~= tostring(localId)) then
    return false, "canonical identity already bound to another local object"
  end

  state.byCanonical[canonicalId] = {
    canonicalId = canonicalId,
    kind = kind,
    localId = localId,
    metadata = util.deepCopy(metadata or {}),
  }
  state.byLocal[key] = canonicalId
  state.revisions = (state.revisions or 0) + 1
  return true, state.byCanonical[canonicalId]
end

function M.unbindCanonical(state, canonicalId)
  local binding = state.byCanonical[canonicalId]
  if not binding then return false end
  state.byLocal[localKey(binding.kind, binding.localId)] = nil
  state.byCanonical[canonicalId] = nil
  state.revisions = (state.revisions or 0) + 1
  return true
end

function M.rebindLocal(state, canonicalId, newLocalId, metadataPatch)
  assert(type(canonicalId) == "string" and canonicalId ~= "", "canonicalId required")
  assert(newLocalId ~= nil, "newLocalId required")
  local binding = state.byCanonical[canonicalId]
  if not binding then return false, "canonical identity is not bound" end

  local newKey = localKey(binding.kind, newLocalId)
  local occupiedBy = state.byLocal[newKey]
  if occupiedBy and occupiedBy ~= canonicalId then
    return false, "replacement local identity already bound to " .. occupiedBy
  end

  local oldKey = localKey(binding.kind, binding.localId)
  state.byLocal[oldKey] = nil
  binding.localId = newLocalId
  binding.metadata = binding.metadata or {}
  for key, value in pairs(metadataPatch or {}) do
    binding.metadata[key] = util.deepCopy(value)
  end
  state.byLocal[newKey] = canonicalId
  state.revisions = (state.revisions or 0) + 1
  return true, binding
end

function M.resolveLocal(state, canonicalId)
  local binding = state.byCanonical[canonicalId]
  return binding and binding.localId or nil
end

function M.resolveCanonical(state, kind, localId)
  return state.byLocal[localKey(kind, localId)]
end

function M.snapshot(state)
  local result = {}
  for _, canonicalId in ipairs(util.sortedKeys(state.byCanonical)) do
    result[#result + 1] = util.deepCopy(state.byCanonical[canonicalId])
  end
  return result
end

function M.digestView(state)
  local result = {}
  for _, canonicalId in ipairs(util.sortedKeys(state.byCanonical)) do
    local binding = state.byCanonical[canonicalId]
    result[#result + 1] = {
      canonicalId = binding.canonicalId,
      kind = binding.kind,
      metadata = util.deepCopy(binding.metadata or {}),
    }
  end
  return result
end

return M
