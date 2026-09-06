local root = assert(arg[1]):gsub("\\", "/")
package.path = root .. "/tpf2_mp_1/res/scripts/?.lua;" .. package.path
local json, util = require "tpf2_mp/json", require "tpf2_mp/util"
local codec = require "tpf2_mp/proposal_codec"
local refs = require "tpf2_mp/edge_object_reference"
local stream = assert(io.open(root .. "/tests/fixtures/live-ui/bus-stop-right-side.json", "rb"))
local captured = assert(json.decode(stream:read("*a"))); stream:close()
assert(captured.edgeObjectsToAdd[1].category == 0 and captured.edgeObjectsToAdd[1].left == false)
assert(captured.edgesToAdd[1].comp.objects["1"]["2"] == 1)
-- Isolate enum/identity validation. Existing node positions are not part of
-- this capture, so use an explicit parameter only in this unit test copy.
-- The unchanged raw fixture and physical UI rerun exercise live projection.
local fixture = util.deepCopy(captured)
fixture.edgeObjectsToAdd[1].param = 0.5
local options = { resourceName = function(kind)
  return kind == "model" and "station/bus/small_mid.mdl" or "country_small.lua"
end, resolveCanonical = function(kind, id) return kind .. ":pre:test" .. tostring(id) end }
local result, err = codec.normalise(fixture, "company:1", options)
assert(result, err)
assert(result.edgeObjects.add[1].category == 1 and result.edgeObjects.add[1].left == false)
for _, category in ipairs({ 0, 1 }) do
  assert(refs.matches(0, category, true) and refs.matches(1, category, false))
  assert(not refs.matches(0, category, false) and not refs.matches(1, category, true))
end
assert(not refs.matches(1, 2, false) and not refs.matches(2, 0, false))
assert(refs.matches(2, 2, false) and refs.matches(2, 2, true))
for _, edit in ipairs({
  function(f) f.edgeObjectsToAdd[1].left = true end,
  function(f) f.edgeObjectsToAdd[1].category = 2 end,
  function(f) f.edgeObjectsToAdd[1].segmentEntity = -99 end,
}) do
  local changed = util.deepCopy(fixture); edit(changed)
  assert(not codec.normalise(changed, "company:1", options), "inconsistent reference accepted")
end
print("PASS real opposite-side bus stop capture: distinct category/type enums and side/carrier guards")
