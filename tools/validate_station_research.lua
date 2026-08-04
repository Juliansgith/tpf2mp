local project = assert(arg[1], "project root argument required"):gsub("\\", "/")
local researchPath = assert(arg[2], "research JSON path required")
package.path = project .. "/tpf2_mp_1/res/scripts/?.lua;" .. package.path

local json = require "tpf2_mp/json"
local proposalCodec = require "tpf2_mp/proposal_codec"

local handle = assert(io.open(researchPath, "rb"))
local document = assert(json.decode(handle:read("*a")))
handle:close()

local payload = assert(document.payload, "research payload is missing")
local capture = assert(payload.capture, "research capture is missing")
local snapshotRecord = assert(capture.lastProposalSnapshot, "last proposal snapshot is missing")
local snapshot = assert(snapshotRecord.snapshot, "proposal snapshot body is missing")
local companyCid = capture.lastProposalCodecFailure
  and capture.lastProposalCodecFailure.companyCid or "company:1"
local transaction, codecError = proposalCodec.normalise(snapshot, companyCid)
assert(transaction, codecError)
assert(transaction.schemaVersion == proposalCodec.CONSTRUCTION_SCHEMA_VERSION,
  "latest proposal is not a supported construction transaction")
local spec, materialiseError = proposalCodec.materialiseConstruction(transaction)
assert(spec, materialiseError)
print(string.format(
  "station codec accepted digest=%s nodes=%d edges=%d modules=%d file=%s",
  transaction.digest, #transaction.nodes, #transaction.edges,
  #transaction.constructions[1].modules, spec.fileName
))
