local util = require "tpf2_mp/util"
local canonical = require "tpf2_mp/canonical"
local world = require "tpf2_mp/world"

local M = {}

local function localKey(kind, localId)
  return tostring(kind) .. ":" .. tostring(localId)
end

local function remember(slots, map, key)
  if key == nil or slots[key] ~= nil then return end
  slots[key] = {
    present = map and map[key] ~= nil or false,
    value = map and util.deepCopy(map[key]) or nil,
  }
end

local function restoreSlots(map, slots)
  if type(map) ~= "table" then return end
  for key, snapshot in pairs(slots or {}) do
    map[key] = snapshot.present and util.deepCopy(snapshot.value) or nil
  end
end

local function restoreSnapshot(state, snapshot)
  if type(snapshot) ~= "table" then return false end
  -- A successful rebind can have created a reverse-map entry which did not
  -- exist when the transaction began. Clear every current target first, then
  -- restore the exact recorded slots. This also covers a resolver returning a
  -- different candidate than its immediately preceding read-only inspection.
  for cid in pairs(snapshot.bindings or {}) do
    local current = state.canonical.byCanonical[cid]
    if current then state.canonical.byLocal[localKey(current.kind, current.localId)] = nil end
  end
  for cid, binding in pairs(snapshot.bindings or {}) do
    state.canonical.byCanonical[cid] = binding.present
      and util.deepCopy(binding.value) or nil
  end
  restoreSlots(state.canonical.byLocal, snapshot.locals)
  restoreSlots(state.world.logicalOwners, snapshot.logicalOwners)
  restoreSlots(state.world.pinnedCustody, snapshot.pinnedCustody)
  state.canonical.revisions = util.integer(snapshot.revision, 0)
  return true
end

function M.bind(state, inspected, eventId)
  local localInputs = {}
  local newlyBoundCids = {}
  local canonicalRevisionBefore = util.integer(state.canonical.revisions, 0)
  local bindingRollback = {
    revision = canonicalRevisionBefore,
    bindings = {}, locals = {}, logicalOwners = {}, pinnedCustody = {},
  }
  local function rememberBinding(cid, kind, candidateLocalId)
    if bindingRollback.bindings[cid] ~= nil then return end
    local binding = state.canonical.byCanonical[cid]
    bindingRollback.bindings[cid] = {
      present = binding ~= nil, value = util.deepCopy(binding),
    }
    local localIds = {}
    if binding and binding.localId ~= nil then localIds[#localIds + 1] = binding.localId end
    if candidateLocalId ~= nil then localIds[#localIds + 1] = candidateLocalId end
    for _, localId in ipairs(localIds) do
      if localId ~= nil then
        remember(bindingRollback.locals, state.canonical.byLocal, localKey(kind, localId))
        local key = tostring(localId)
        remember(bindingRollback.logicalOwners, state.world.logicalOwners, key)
        remember(bindingRollback.pinnedCustody, state.world.pinnedCustody, key)
      end
    end
  end
  local function rollback(errorValue)
    restoreSnapshot(state, bindingRollback)
    return nil, nil, errorValue
  end
  for _, cid in ipairs(util.sortedKeys(inspected.localRefs)) do
    local localId = inspected.localRefs[cid]
    local kind = inspected.referenceKinds[cid]
    local previousBinding = state.canonical.byCanonical[cid]
    rememberBinding(cid, kind, localId)
    local ownerCid = state.world.logicalOwners
      and (state.world.logicalOwners[tostring(localId)]
        or (previousBinding and state.world.logicalOwners[
          tostring(previousBinding.localId)])) or nil
    ownerCid = ownerCid or (previousBinding and previousBinding.metadata
      and previousBinding.metadata.owner)
    -- Revalidate and perform the actual bind/rebind only now, inside the
    -- rollback journal. PREPARE's discovery is intentionally read-only.
    local resolved, resolveError = world.resolvePreExisting(state.canonical, cid, kind, {
      owner = ownerCid,
      resolvedForProposal = eventId,
      worldState = state.world,
    })
    if resolved == nil then return rollback(resolveError) end
    if tonumber(resolved) ~= tonumber(localId) then
      return rollback("portable identity changed between proposal inspection and binding")
    end
    if previousBinding == nil then
      newlyBoundCids[#newlyBoundCids + 1] = cid
    end
    localId = resolved
    inspected.localRefs[cid] = localId
    if inspected.removal[cid] then
      local binding = state.canonical.byCanonical[cid]
      local capitalCostCents = binding and binding.metadata
        and math.max(0, util.integer(binding.metadata.capitalCostCents, 0)) or 0
      localInputs[#localInputs + 1] = {
        kind = kind, cid = cid, localId = localId,
        capitalCostCents = capitalCostCents,
      }
    end
  end
  return inspected.localRefs, localInputs, nil, newlyBoundCids,
    canonicalRevisionBefore, bindingRollback
end

function M.rollback(state, record)
  if restoreSnapshot(state, record.bindingRollback) then
    record.bindingRollback = nil
    record.newlyBoundCids = nil
    record.canonicalRevisionBefore = nil
    return
  end
  local bindings = type(record.newlyBoundCids) == "table" and record.newlyBoundCids or {}
  for index = #bindings, 1, -1 do
    canonical.unbindCanonical(state.canonical, bindings[index])
  end
  if record.canonicalRevisionBefore ~= nil then
    state.canonical.revisions = util.integer(record.canonicalRevisionBefore, 0)
  end
  record.newlyBoundCids = nil
  record.canonicalRevisionBefore = nil
  record.bindingRollback = nil
end

return M
