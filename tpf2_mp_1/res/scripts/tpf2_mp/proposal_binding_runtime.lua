local util = require "tpf2_mp/util"
local canonical = require "tpf2_mp/canonical"
local world = require "tpf2_mp/world"

local M = {}

function M.bind(state, inspected, eventId)
  local localInputs = {}
  local newlyBoundCids = {}
  local canonicalRevisionBefore = util.integer(state.canonical.revisions, 0)
  local function rollback(errorValue)
    for index = #newlyBoundCids, 1, -1 do
      canonical.unbindCanonical(state.canonical, newlyBoundCids[index])
    end
    state.canonical.revisions = canonicalRevisionBefore
    return nil, nil, errorValue
  end
  for _, cid in ipairs(util.sortedKeys(inspected.localRefs)) do
    local localId = inspected.localRefs[cid]
    local kind = inspected.referenceKinds[cid]
    if canonical.resolveLocal(state.canonical, cid) == nil then
      local ownerCid = state.world.logicalOwners
        and state.world.logicalOwners[tostring(localId)] or nil
      local resolved, resolveError = world.resolvePreExisting(state.canonical, cid, kind, {
        owner = ownerCid,
        resolvedForProposal = eventId,
      })
      if resolved == nil then return rollback(resolveError) end
      newlyBoundCids[#newlyBoundCids + 1] = cid
      localId = resolved
      inspected.localRefs[cid] = localId
    end
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
  return inspected.localRefs, localInputs, nil, newlyBoundCids, canonicalRevisionBefore
end

function M.rollback(state, record)
  local bindings = type(record.newlyBoundCids) == "table" and record.newlyBoundCids or {}
  for index = #bindings, 1, -1 do
    canonical.unbindCanonical(state.canonical, bindings[index])
  end
  if record.canonicalRevisionBefore ~= nil then
    state.canonical.revisions = util.integer(record.canonicalRevisionBefore, 0)
  end
  record.newlyBoundCids = nil
  record.canonicalRevisionBefore = nil
end

return M
