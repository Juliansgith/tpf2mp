-- Full-inventory enumeration, deliberately separate from bootstrap kind
-- discovery. Bus/truck stops and waypoints are attached edge objects too, but
-- enumerating every STATION as an edge object would also capture full stations.
local M = { MAX_OBJECTS_PER_EDGE = 4096 }

function M.collect(edgeIds, signalIds, deps)
  local ids, seen = {}, {}
  local function add(id)
    if type(id) ~= "number" or id < 0 or id ~= math.floor(id)
      or id == math.huge or not deps.entityExists(id) then
      error("invalid or missing attached edge object")
    end
    if not seen[id] then seen[id], ids[#ids + 1] = true, id end
  end
  local ok, err = pcall(function()
    for _, id in ipairs(signalIds) do add(id) end
    for _, edgeId in ipairs(edgeIds) do
      local edge = assert(deps.edgeComponent(edgeId), "BASE_EDGE unavailable")
      local objects = assert(edge.objects, "BASE_EDGE.objects unavailable")
      local count = #objects
      assert(count >= 0 and count == math.floor(count)
        and count <= M.MAX_OBJECTS_PER_EDGE, "edge object inventory exceeds bound")
      -- Build 35924's vector<pair<Entity, EdgeObjectType>> is one-based.
      -- Read the actual entity, never the category or a guessed zero-based slot.
      for index = 1, count do add(objects[index][1]) end
    end
  end)
  if not ok then return nil, tostring(err) end
  table.sort(ids)
  return ids
end

function M.forWorld(world, component)
  return function(edgeIds)
    return M.collect(edgeIds, world.listEdgeObjects(), {
      entityExists = world.entityExists,
      edgeComponent = function(id) return component(id, api.type.ComponentType.BASE_EDGE) end,
    })
  end
end

return M
