local inventory = require "tpf2_mp/world_edge_object_inventory"
local edges = { [10] = { objects = { { 31, 0 }, { 32, 1 } } },
  [11] = { objects = { { 33, 2 }, { 31, 0 } } }, [12] = { objects = {} } }
local exists = { [31] = true, [32] = true, [33] = true, [34] = true }
local deps = { edgeComponent = function(id) return edges[id] end,
  entityExists = function(id) return exists[id] == true end }
local ids = assert(inventory.collect({ 10, 11, 12 }, { 32, 34 }, deps))
assert(table.concat(ids, ",") == "31,32,33,34", "stop/waypoint omitted or signal double counted")
assert(not inventory.collect({ 99 }, {}, deps), "missing edge accepted as empty")
edges[12].objects = nil
assert(not inventory.collect({ 12 }, {}, deps), "unreadable objects accepted as empty")
edges[12].objects = { { -1, 0 } }
assert(not inventory.collect({ 12 }, {}, deps), "temporary entity counted")
edges[12].objects = { { 99, 0 } }
assert(not inventory.collect({ 12 }, {}, deps), "missing entity counted")
edges[12].objects = { { 31.5, 0 } }
assert(not inventory.collect({ 12 }, {}, deps), "fractional entity counted")
edges[12].objects = { { math.huge, 0 } }
assert(not inventory.collect({ 12 }, {}, deps), "infinite entity counted")
-- Native one-based C++ vector and pair proxies, including throwing reads.
local vector = newproxy(true)
local mt = getmetatable(vector)
mt.__len = function() return 2 end
mt.__index = function(_, index)
  assert(index == 1 or index == 2, "out-of-bounds vector read")
  local pair = newproxy(true)
  getmetatable(pair).__index = function(_, field)
    assert(field == 1, "category is not an entity")
    return 30 + index
  end
  return pair
end
edges[12].objects = vector
ids = assert(inventory.collect({ 12 }, {}, deps))
assert(table.concat(ids, ",") == "31,32", "native vector/pair proxies lost")
mt.__index = function() error("unreadable") end
assert(not inventory.collect({ 12 }, {}, deps), "partial read reported complete")
mt.__len = function() return inventory.MAX_OBJECTS_PER_EDGE + 1 end
assert(not inventory.collect({ 12 }, {}, deps), "oversized inventory silently truncated")
print("PASS attached native edge-object inventory cases")
