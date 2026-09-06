local root = assert(arg[1]):gsub("\\", "/")
package.path = root .. "/tpf2_mp_1/res/scripts/?.lua;" .. package.path
local codec, util = require "tpf2_mp/proposal_codec", require "tpf2_mp/util"
local fixture = { __observedCost = 100, __constructionAdditions = {
  { fileName = "station/air/airfield.con", name = "Coleford Airport",
    transf = {1,0,0,0, 0,1,0,0, 0,0,1,0, 10,20,0,1}, params = { year = 1940 } },
}, __constructionRemovals = {}, streetProposal = {} }
local tx = assert(codec.normalise(fixture, "company:1", {}))
assert(tx.schemaVersion == 9 and tx.constructions[1].name == "Coleford Airport")
if arg[2] == "--json" then print(require("tpf2_mp/json").encode(tx)); return end
local spec = assert(codec.materialiseConstruction(tx))
assert(spec.name == "Coleford Airport")
local missing = util.deepCopy(tx); missing.constructions[1].name = nil
assert(not codec.validate(missing), "named schema must not silently drop NAME")
local renamed = util.deepCopy(tx); renamed.constructions[1].name = "Different Airport"
assert(codec.digest(renamed) ~= codec.digest(tx), "name must be digest-bound")
for _, invalid in ipairs({ true, 100, string.rep("x", 241), "bad\nname", "bad\0name" }) do
  fixture.__constructionAdditions[1].name = invalid
  local result, err = codec.normalise(fixture, "company:1", {})
  assert(not result and err:find("construction name", 1, true))
end
fixture.__constructionAdditions[1].name = nil
local old = assert(codec.normalise(fixture, "company:1", {}))
assert(old.schemaVersion == 8 and old.constructions[1].name == nil and codec.validate(old))
-- Materializer must populate the native input before expansion creates hangars.
local proposal = { constructionsToAdd = {}, constructionsToRemove = {} }
local fakeApi = { type = { SimpleProposal = { ConstructionEntity = { new = function() return {} end } },
  Vec4f = { new = function(...) return {...} end }, Mat4f = { new = function(...) return {...} end } } }
assert(require("tpf2_mp/construction_proposal_materializer").apply(proposal, spec,
  { api = fakeApi, nativePlayerId = 10 }))
assert(proposal.constructionsToAdd[1].name == "Coleford Airport")
print("PASS construction name capture, schema, digest and native materialisation")
