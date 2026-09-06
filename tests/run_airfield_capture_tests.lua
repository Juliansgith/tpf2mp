local root = assert(arg[1]):gsub("\\", "/")
package.path = root .. "/tpf2_mp_1/res/scripts/?.lua;" .. package.path
local json, util = require "tpf2_mp/json", require "tpf2_mp/util"
local codec = require "tpf2_mp/proposal_codec"
local stream = assert(io.open(root .. "/tests/fixtures/live-ui/airfield-edge-objects.json", "rb"))
local captured = assert(json.decode(stream:read("*a"))); stream:close()
local options = { resourceName = function(kind, id)
  return kind == "model" and "test/terminal.mdl" or ("test/" .. kind .. tostring(id) .. ".lua")
end }
-- Exact real UI capture: preserve its raw transforms. They independently expose
-- the preview-rebase bug; explicit test parameters isolate object identity here.
local fixture = util.deepCopy(captured)
fixture.__observedCost = 4122239
for _, object in ipairs(fixture.edgeObjectsToAdd) do object.param = 0.5 end
local result = assert(codec.normalise(fixture, "company:1", options))
assert(#result.edgeObjects.add == 11)
assert(result.edgeObjects.add[1].edge.slot == "edge:8")
assert(result.edgeObjects.add[2].edge.slot == "edge:7")
for index, object in ipairs(result.edgeObjects.add) do
  assert(object.category == 2 and object.param == 0.5)
  assert(fixture.edgesToAdd[tonumber(object.edge.slot:match("%d+"))].entity
    == fixture.edgeObjectsToAdd[index].segmentEntity)
end
local function rejected(edit, message)
  local value = util.deepCopy(fixture); edit(value)
  local normalized, err = codec.normalise(value, "company:1", options)
  assert(not normalized and tostring(err):find(message, 1, true), tostring(err))
end
rejected(function(f) f.edgeObjectsToAdd[1].segmentEntity = -32 end, "carrier edge reference")
rejected(function(f) f.edgeObjectsToAdd[1].category = 3 end, "category reference")
rejected(function(f) f.edgesToAdd[7].comp.objects["1"]["1"] = -1 end, "duplicate temporary")
rejected(function(f) f.edgeObjectsToAdd[1].entity = -999 end, "matching temporary reference")
local explicit = util.deepCopy(fixture)
for index, object in ipairs(explicit.edgeObjectsToAdd) do object.entity = -index end
explicit.edgeObjectsToAdd[1], explicit.edgeObjectsToAdd[2] = explicit.edgeObjectsToAdd[2], explicit.edgeObjectsToAdd[1]
assert(codec.normalise(explicit, "company:1", options), "explicit identities must allow reordered object additions")

local gui = {}
require("tpf2_mp/gui_capture").install(gui, { proposalCost = function() return 0 end })
local old = { 0, 1, 0, 0, -1, 0, 0, 0, 0, 0, 1, 0, 100, 200, 3, 1 }
local new = { 1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1, 0, -3000, -1500, 17, 1 }
local function model(stringKeys)
  local matrix = { 0, 1, 0, 0, -1, 0, 0, 0, 0, 0, 1, 0, 95, 210, 5, 1 }
  if stringKeys then local converted = {}; for i, v in ipairs(matrix) do converted[tostring(i)] = v end; matrix = converted end
  return { modelInstance = { transf = matrix } }
end
local snapshot = {
  __constructionAdditions = { { transf = old } },
  proposal = { edgeObjectsToAdd = { model(false), model(true) } },
}
local before = json.encode(snapshot)
local rebased = assert(gui.rebaseConstructionPreviewSnapshot(snapshot, { transform = new }))
assert(json.encode(snapshot) == before, "rebase must not mutate cached preview")
for _, object in ipairs(rebased.proposal.edgeObjectsToAdd) do
  local matrix = assert(gui.previewMatrix(object.modelInstance.transf))
  assert(matrix[1] == 1 and matrix[2] == 0 and matrix[5] == 0 and matrix[6] == 1)
  assert(matrix[13] == -2990 and matrix[14] == -1495 and matrix[15] == 19,
    "object must follow rotation, translation and elevation together")
end
snapshot.proposal.edgeObjectsToAdd[1].modelInstance.transf[14] = nil
local broken, err = gui.rebaseConstructionPreviewSnapshot(snapshot, { transform = new })
assert(not broken and err:find("incomplete", 1, true))
-- Strict processed userdata: a Simple-only field write must fail this test,
-- instead of being silently accepted as it would by an ordinary Lua table.
local exactObject = require "tpf2_mp/construction_exact_edge_object"
local function field(value, name)
  local ok, found = pcall(function() return value[name] end)
  if ok then return found end
end
local function assign(value, name, replacement)
  local ok, err = pcall(function() value[name] = replacement end)
  return ok or nil, err
end
local backing = { segmentEntity = -9, category = 2, left = false, oneWay = false,
  modelInstance = { modelId = 2177, transf = { 1,0,0,0, 0,1,0,0, 0,0,1,0, 50,0,0,1 } } }
local processed = newproxy(true)
getmetatable(processed).__index = function(_, name) return backing[name] end
getmetatable(processed).__newindex = function(_, name, value)
  assert(name == "playerEntity" or name == "name", "illegal processed object write: " .. name)
  backing[name] = value
end
local expected = { edgeEntity = -1, playerEntity = 100, name = "Airport", param = 0.5 }
local facts = { modelIndex = 2177, category = 2, left = false, oneWay = false, param = 0.5 }
local nodes = { [-10] = { x = 0, y = 0, z = 0 }, [-11] = { x = 100, y = 0, z = 0 } }
local edges = { [-9] = { comp = { node0 = -10, node1 = -11,
  tangent0 = { x = 100, y = 0, z = 0 }, tangent1 = { x = 100, y = 0, z = 0 } } } }
local function rewrite()
  return exactObject.rewrite(processed, expected, { ["-1"] = -9 }, facts, nodes, edges, field, assign)
end
assert(rewrite()); assert(backing.playerEntity == 100 and backing.name == "Airport")
backing.modelInstance.modelId = 123; assert(not rewrite()); backing.modelInstance.modelId = 2177
backing.modelInstance.transf[13] = 75; assert(not rewrite()); backing.modelInstance.transf[13] = 50
backing.segmentEntity = -8; assert(not rewrite()); backing.segmentEntity = -9
backing.category = 0; assert(not rewrite()); backing.category = 2
backing.oneWay = true; assert(not rewrite()); backing.oneWay = false
assert(rewrite())
-- The same processed-object adapter must support right-side transit stops,
-- where the edge reference type is 1 but the passenger model category is 0.
facts.category, backing.category = 1, 0
assert(rewrite(), "right-side processed stop was compared as the same enum")
backing.left = true; assert(not rewrite()); backing.left = false
backing.modelInstance.modelId = 123; assert(not rewrite())
dofile(root .. "/tests/run_curb_stop_capture_tests.lua")
print("PASS airfield capture: real 11-object identity fixture, reordered additions, carrier/category guards, preview object rebasing")
