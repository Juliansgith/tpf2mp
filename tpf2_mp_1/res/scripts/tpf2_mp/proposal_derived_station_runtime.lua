local canonical = require "tpf2_mp/canonical"
local deltaAttestation = require "tpf2_mp/construction_delta_attestation"
local outputOrder = require "tpf2_mp/construction_output_order"
local world = require "tpf2_mp/world"

local M = {}

local function transitCategory(value)
  value = tonumber(value)
  return value == 0 or value == 1
end

function M.requiresCapture(transaction, registry)
  local edgeObjects = type(transaction) == "table" and transaction.edgeObjects or {}
  for _, object in ipairs(type(edgeObjects) == "table" and edgeObjects.add or {}) do
    if transitCategory(object.category) then return true end
  end
  for _, cid in ipairs(type(edgeObjects) == "table" and edgeObjects.remove or {}) do
    local binding = registry and registry.byCanonical and registry.byCanonical[cid]
    if binding and binding.metadata and transitCategory(binding.metadata.category) then return true end
  end
  return false
end

function M.delta(payload, maximum)
  return deltaAttestation.normalise(
    type(payload) == "table" and payload.constructionDelta or nil, maximum)
end

local function empty(values)
  return type(values) == "table" and #values == 0
end

function M.bind(state, record, bound, delta)
  if type(delta) ~= "table" then return nil, "transit-stop entity delta is unavailable" end
  for _, kind in ipairs({ "construction", "depot", "asset" }) do
    if not empty(delta.added[kind]) or not empty(delta.removed[kind]) then
      return nil, "edge transit stop unexpectedly changed " .. kind .. " entities"
    end
  end
  for _, kind in ipairs({ "station", "station_group" }) do
    for _, localId in ipairs(delta.removed[kind] or {}) do
      local cid = canonical.resolveCanonical(state.canonical, kind, localId)
      if cid then canonical.unbindCanonical(state.canonical, cid) end
      state.world.logicalOwners[tostring(localId)] = nil
      state.world.pinnedCustody[tostring(localId)] = nil
    end
    local rows, orderError = outputOrder.rows(kind, delta.added[kind] or {}, {
      exact = #(delta.added[kind] or {}) <= 1,
      proposalDigest = record.transaction.digest,
      fingerprint = world.fingerprint,
    })
    if not rows then return nil, orderError end
    for index, row in ipairs(rows) do
      local cid = canonical.createdId(kind, record.eventId, index)
      local company = state.companies and state.companies[record.companyCid]
      if not company then return nil, "transit-stop company binding is unavailable" end
      local ok, bindError = canonical.bind(state.canonical, cid, kind, row.localId, {
        owner = record.companyCid, private = true,
        proposalDigest = record.transaction.digest,
        outputSlot = kind .. ":" .. tostring(index), fingerprint = row.fingerprint,
      })
      if not ok then return nil, bindError end
      state.world.logicalOwners[tostring(row.localId)] = record.companyCid
      state.world.pinnedCustody[tostring(row.localId)] = {
        cid = cid, kind = kind, logicalOwnerCid = record.companyCid,
        nativePlayerId = (function()
          local ok, value = pcall(world.ownerOf, row.localId)
          return ok and value or record.nativeOwnerPlayerId
        end)(),
        requestedPlayerId = company.playerId,
        reason = "canonical-transit-stop-replay",
      }
      bound[#bound + 1] = {
        kind = kind, cid = cid, localId = row.localId,
        slot = kind .. ":" .. tostring(index),
      }
    end
  end
  return bound
end

function M.applyIfNeeded(state, record, bound, payload, maximum)
  if not bound or not M.requiresCapture(record.transaction, state.canonical) then return bound end
  local delta, deltaError = M.delta(payload, maximum)
  if not delta then return nil, deltaError end
  return M.bind(state, record, bound, delta)
end

return M
