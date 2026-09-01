local canonical = require "tpf2_mp/canonical"
local outputOrder = require "tpf2_mp/construction_output_order"
local util = require "tpf2_mp/util"
local world = require "tpf2_mp/world"

local M = {}

local function plansFor(state, record, delta, company)
  local plans = {}
  for _, kind in ipairs({ "station", "station_group" }) do
    local rows, orderError = outputOrder.rows(kind, delta.added[kind] or {}, {
      exact = #(delta.added[kind] or {}) <= 1,
      proposalDigest = record.transaction.digest,
      fingerprint = world.fingerprint,
    })
    if not rows then return nil, orderError end
    local plan = { kind = kind, removals = {}, additions = {} }
    for _, localId in ipairs(delta.removed[kind] or {}) do
      plan.removals[#plan.removals + 1] = {
        localId = localId,
        cid = canonical.resolveCanonical(state.canonical, kind, localId),
      }
    end
    for index, row in ipairs(rows) do
      local nativeOwner = record.nativeOwnerPlayerId
      local ownerOk, ownerValue = pcall(world.ownerOf, row.localId)
      if ownerOk then nativeOwner = ownerValue end
      plan.additions[#plan.additions + 1] = {
        kind = kind,
        cid = canonical.createdId(kind, record.eventId, index),
        localId = row.localId,
        slot = kind .. ":" .. tostring(index),
        nativeOwnerPlayerId = nativeOwner,
        requestedPlayerId = company.playerId,
        metadata = {
          owner = record.companyCid, private = true,
          proposalDigest = record.transaction.digest,
          outputSlot = kind .. ":" .. tostring(index), fingerprint = row.fingerprint,
        },
      }
    end
    plans[#plans + 1] = plan
  end
  return plans
end

local function stagedRegistry(state, plans)
  local staged = util.deepCopy(state.canonical)
  for _, plan in ipairs(plans) do
    for _, removal in ipairs(plan.removals) do
      if removal.cid then canonical.unbindCanonical(staged, removal.cid) end
    end
  end
  for _, plan in ipairs(plans) do
    for _, addition in ipairs(plan.additions) do
      local ok, bindError = canonical.bind(staged, addition.cid, addition.kind,
        addition.localId, addition.metadata)
      if not ok then return nil, bindError end
    end
  end
  return staged
end

function M.apply(state, record, bound, delta)
  if type(bound) ~= "table" then return nil, "transit-stop output binding list is unavailable" end
  local company = state.companies and state.companies[record.companyCid]
  if not company then return nil, "transit-stop company binding is unavailable" end
  local plans, planError = plansFor(state, record, delta, company)
  if not plans then return nil, planError end
  local staged, stagedError = stagedRegistry(state, plans)
  if not staged then return nil, stagedError end

  state.canonical.byCanonical = staged.byCanonical
  state.canonical.byLocal = staged.byLocal
  state.canonical.revisions = staged.revisions
  for _, plan in ipairs(plans) do
    for _, removal in ipairs(plan.removals) do
      state.world.logicalOwners[tostring(removal.localId)] = nil
      state.world.pinnedCustody[tostring(removal.localId)] = nil
    end
    for _, addition in ipairs(plan.additions) do
      state.world.logicalOwners[tostring(addition.localId)] = record.companyCid
      state.world.pinnedCustody[tostring(addition.localId)] = {
        cid = addition.cid, kind = addition.kind, logicalOwnerCid = record.companyCid,
        nativePlayerId = addition.nativeOwnerPlayerId,
        requestedPlayerId = addition.requestedPlayerId,
        reason = "canonical-transit-stop-replay",
      }
      bound[#bound + 1] = {
        kind = addition.kind, cid = addition.cid, localId = addition.localId,
        slot = addition.slot,
      }
    end
  end
  return bound
end

return M
