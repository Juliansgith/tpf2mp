-- Disposable live-test helper for creating a previously captured canonical
-- construction in a manual two-process session.
--
-- This does not bypass multiplayer ordering: it submits proposal.build through
-- the same GUI -> engine script-event path as the mod's controls.  It exists so
-- a focused stock-UI test (for example Line Manager stop editing) can establish
-- a physical station fixture without asking a human to repeat unrelated setup.
--
-- Console usage:
--   TPF2MP_FIXTURE_PATH = "C:/.../000000000026.json"
--   TPF2MP_FIXTURE_COMPANY = "company:1"
--   dofile("C:/Users/Sepgi/Downloads/tf2mod/tools/replay_proposal_fixture.lua")

local json = require "tpf2_mp/json"
local proposalCodec = require "tpf2_mp/proposal_codec"
local util = require "tpf2_mp/util"

local sourcePath = assert(rawget(_G, "TPF2MP_FIXTURE_PATH"),
  "TPF2MP_FIXTURE_PATH is required")
local companyCid = tostring(rawget(_G, "TPF2MP_FIXTURE_COMPANY") or "company:1")
assert(companyCid:match("^company:%d+$"), "fixture company is invalid")

local file = assert(io.open(sourcePath, "rb"))
local source = file:read("*a")
file:close()

local envelope = assert(json.decode(source))
local transaction = assert(envelope.payload and envelope.payload.action
  and envelope.payload.action.transaction, "capture has no proposal transaction")

transaction.companyCid = companyCid
for _, edge in ipairs(transaction.edges or {}) do
  edge.logicalOwnerCid = companyCid
end
for _, edgeObject in ipairs(transaction.edgeObjects and transaction.edgeObjects.add or {}) do
  edgeObject.logicalOwnerCid = companyCid
end
transaction.digest = nil
transaction.transactionId = nil
transaction.digest = proposalCodec.digest(transaction)
transaction.transactionId = "proposal:" .. transaction.digest

local valid, validationError = proposalCodec.validate(transaction)
assert(valid, validationError)
local action = {
  -- The host companion alone is allowed to promote an agreed prepare into the
  -- physical proposal.build commit.
  type = "proposal.prepare",
  transaction = transaction,
}
if game and game.interface and type(game.interface.sendScriptEvent) == "function" then
  game.interface.sendScriptEvent("tpf2mp", "intent", action)
else
  local factory = assert(util.commandFactory("sendScriptEvent"))
  local command = factory("tpf2_mp.lua", "tpf2mp", "intent", action)
  local sent, sendError = util.sendCommand(command, nil, "mod.gui.script-event:intent")
  assert(sent, sendError)
end

print("TPF2MP fixture submitted", transaction.transactionId, companyCid)
