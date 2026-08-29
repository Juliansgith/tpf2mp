local proposalCodec = require "tpf2_mp/proposal_codec"

local M = {}

-- Exact Build 35924 graph captured from relay session
-- mp-ab70273a64a19ffa. The stock construction owns the first entrance edge;
-- the player's click also splits one town road into the final two edges and
-- removes two buildings. Keeping this fixture in the live validator prevents
-- a generated-only construction replay from masquerading as a connected one.
function M.transaction(companyCid)
  local transaction = {
    schemaVersion = proposalCodec.CONSTRUCTION_SCHEMA_VERSION,
    companyCid = companyCid,
    cost = 90020,
    nodes = {
      { slot = "node:1", position = {
        x = -819.15057122627763, y = -1015.9491817663397, z = 12.49703311920166,
      } },
      { slot = "node:2", position = {
        x = -811.72722787661849, y = -1035.5933926154967, z = 12.49703311920166,
      } },
    },
    edges = {
      {
        slot = "edge:1", carrier = "street",
        node0 = { slot = "node:1" }, node1 = { slot = "node:2" },
        tangent0 = { x = 7.4233748338335115, y = -19.644199440667141, z = 0 },
        tangent1 = { x = 7.4233438243387289, y = -19.644212757043594, z = 0 },
        type = 0, typeIndex = -1,
        resource = { index = 30, name = "street_station/entrance_new.lua" },
        logicalOwnerCid = companyCid, private = true,
      },
      {
        slot = "edge:2", carrier = "street",
        node0 = { cid = "node:pre:41440cf4" }, node1 = { slot = "node:2" },
        tangent0 = { x = 30.002463177653059, y = 11.160681427713422, z = 0 },
        tangent1 = { x = 29.941567826211692, y = 11.314680103465156,
          z = 0.40140631794929504 },
        type = 0, typeIndex = -1,
        resource = { index = 22, name = "standard/town_medium_new.lua" },
        logicalOwnerCid = companyCid, private = false,
      },
      {
        slot = "edge:3", carrier = "street",
        node0 = { slot = "node:2" }, node1 = { cid = "node:pre:41620cf4" },
        tangent0 = { x = 52.376802537398056, y = 19.792778336932233,
          z = 0.70218032598495483 },
        tangent1 = { x = 52.196757769386352, y = 20.266231688001007,
          z = 0.66369301080703735 },
        type = 0, typeIndex = -1,
        resource = { index = 22, name = "standard/town_medium_new.lua" },
        logicalOwnerCid = companyCid, private = false,
      },
    },
    edgeObjects = { add = {}, retain = {}, remove = {} },
    remove = { edges = { "edge:pre:72fc11f4" }, nodes = {} },
    constructions = {{
      slot = "construction:1", mode = "build", sourceCid = "",
      kind = "station", adapter = "portable-construction",
      fileName = "station/street/modular_terminal.con",
      transform = {
        0.9354369044303894, 0.35349363088607788, 0, 0,
        -0.35349363088607788, 0.9354369044303894, 0, 0,
        0, 0, 1, 0,
        -824.4530029296875, -1001.9176025390625, 12.49703311920166, 1,
      },
      params = {
        year = 1940, seed = 3, platL = 1, platR = 1,
        length = 0, tramTrack = 0, paramX = 0, paramY = 0,
      },
      modules = {
        { slot = 20009900, name = "station/street/passenger_platform.module",
          variant = 0, metadata = { passenger = true } },
        { slot = 20010000, name = "station/street/passenger_platform.module",
          variant = 0, metadata = { passenger = true } },
        { slot = 20015503, name = "station/street/entrance_exit.module",
          variant = 0, metadata = {} },
      },
      collateral = {
        { kind = "construction", cid = "construction:pre:adee28b9" },
        { kind = "construction", cid = "construction:pre:aff228b9" },
      },
    }},
  }
  transaction.digest = proposalCodec.digest(transaction)
  transaction.transactionId = "proposal:" .. transaction.digest
  local valid, validationError = proposalCodec.validate(transaction)
  if not valid then return nil, validationError end
  return transaction
end

return M
