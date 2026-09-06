local root = assert(arg[1]):gsub("\\", "/")
package.path = root .. "/tpf2_mp_1/res/scripts/?.lua;" .. package.path
local json = require "tpf2_mp/json"
local util = require "tpf2_mp/util"
local subject = require "tpf2_mp/gui_processed_transport_topology"
local stream = assert(io.open(root .. "/tests/fixtures/live-ui/short-road-crossing.json", "rb"))
local fixture = assert(json.decode(stream:read("*a")))
stream:close()
local function values(value)
  if value == "<userdata>" or value == nil then return {} end
  if type(value) ~= "table" then return nil end
  local indexed, maximum = {}, 0
  for key, child in pairs(value) do
    local index = tonumber(key)
    if index and index >= 1 and index == math.floor(index) then
      if index > 16384 or indexed[index] then return nil end
      indexed[index], maximum = child, math.max(maximum, index)
    end
  end
  local out = {}
  for index = 1, maximum do if indexed[index] == nil then return nil end; out[index] = indexed[index] end
  return out
end
local rawBefore, streetBefore = json.encode(fixture.raw), json.encode(fixture.street)
local processed = assert(subject.select(fixture.raw, fixture.street, values))
assert(#processed.nodesToAdd == 5 and #processed.edgesToAdd == 6)
assert(#processed.nodesToRemove == 1 and #processed.edgesToRemove == 2)
assert(processed.source == "correlated-processed-transport")
for _, node in ipairs(processed.nodesToAdd) do assert(node.entity ~= -2, "raw node -2 was removed by cleanup") end
assert(json.encode(fixture.raw) == rawBefore and json.encode(fixture.street) == streetBefore, "selection mutated captured evidence")
local function rejects(edit, message)
  local raw, street = util.deepCopy(fixture.raw), util.deepCopy(fixture.street)
  edit(raw, street)
  local result, err = subject.select(raw, street, values)
  assert(not result and tostring(err):find(message, 1, true), tostring(err))
end
rejects(function(_, s) s.addedNodes["1"].comp.position.x = 42 end, "rail endpoint")
rejects(function(_, s) s.removedSegments["2"] = nil end, "undeclared removal")
rejects(function(_, s) s.removedSegments["2"].comp.node0 = 123; s.removedSegments["2"].comp.node1 = 456 end, "unrelated removal")
rejects(function(_, s) s.new2oldSegments["-14"] = nil end, "no removal lineage")
rejects(function(_, s) s.addedSegments["1"].entity = 123 end, "addition identity")
rejects(function(_, s) s.removedSegments["1"].entity = 123 end, "omitted a native removal")
rejects(function(_, s) s.addedNodes = false end, "unavailable")
local noProcessed = assert(subject.select(fixture.raw, {}, values))
assert(noProcessed == fixture.raw, "absence of processed evidence must retain native input")
local objectRaw = util.deepCopy(fixture.raw)
objectRaw.edgeObjectsToAdd = { { entity = -50 } }
assert(subject.select(objectRaw, fixture.street, values) == objectRaw, "edge-object replay must stay on its existing codec")
print("PASS processed transport: real short-road crossing fixture, lineage, endpoints, immutability, fail-closed guards")
