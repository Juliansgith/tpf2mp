-- Read-only lab evidence from physical BASE_EDGE geometry, never construction
-- preview parameters or canonical metadata. No discovery/rebinding/mutations.
local M = { MAX_EDGES = 4096 }

function M.read(registry, world)
  assert(type(registry) == "table" and type(registry.byCanonical) == "table",
    "geometry observer requires canonical bindings")
  local ids = {}
  for cid, binding in pairs(registry.byCanonical) do
    if type(binding) == "table" and binding.kind == "edge" then
      assert(type(cid) == "string" and #cid <= 1024, "invalid geometry CID")
      assert(#ids < M.MAX_EDGES, "geometry observer edge budget exceeded")
      ids[#ids + 1] = cid
    end
  end
  table.sort(ids)
  local edges = {}
  for _, cid in ipairs(ids) do
    local id = registry.byCanonical[cid].localId
    assert(type(id) == "number" and id >= 0 and id <= 2147483647 and id == math.floor(id),
      "geometry observer requires a native entity ID")
    assert(world.entityExists(id), "geometry binding no longer exists: " .. cid)
    local fingerprint, err, descriptor = world.topologyFingerprint(id, "edge",
      { registry = registry, includeNeighbours = false })
    assert(fingerprint and not err and type(descriptor) == "table"
      and descriptor.kind == "edge" and type(descriptor.endpoints) == "table"
      and #descriptor.endpoints == 2 and type(descriptor.carrier) == "table",
      "native edge geometry unavailable: " .. tostring(err or cid))
    edges[cid] = descriptor
  end
  return { schemaVersion = 1, complete = true, edges = edges, count = #ids }
end

return M
