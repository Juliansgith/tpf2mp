local deltaAttestation = require "tpf2_mp/construction_delta_attestation"
local stationBinding = require "tpf2_mp/proposal_derived_station_binding"

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
  -- The binder preflights both entity kinds against a copied registry and
  -- commits them together, so a late conflict cannot leave partial residue.
  return stationBinding.apply(state, record, bound, delta)
end

function M.applyIfNeeded(state, record, bound, payload, maximum)
  if not bound or not M.requiresCapture(record.transaction, state.canonical) then return bound end
  local delta, deltaError = M.delta(payload, maximum)
  if not delta then return nil, deltaError end
  return M.bind(state, record, bound, delta)
end

return M
