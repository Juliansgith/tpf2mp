local topologyGuard = require "tpf2_mp/gui_native_topology_guard"

local M = {}

function M.validate(transaction, localRefs, gameApi, options)
  options = options or {}
  local references = topologyGuard.references(transaction, options)
  -- Fresh stations and other self-contained constructions use only negative
  -- transaction-local node slots.  They have no live canonical endpoint to
  -- inspect, and GUI states are not required to expose the engine component
  -- reader merely to materialise those slots.
  if #references == 0 then return true end
  for _, reference in ipairs(references) do
    local valid, referenceError = topologyGuard.validateReference(
      reference, localRefs, gameApi, options)
    if not valid then return nil, referenceError end
  end
  return true
end

return M
