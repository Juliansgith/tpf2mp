local proposalCodec = require "tpf2_mp/proposal_codec"

local M = {}

-- Captured from the populated localhost construction lab on 2026-09-05. This
-- splits a public town road, demolishes an attached house, and adds the depot
-- entrance in one native proposal—the important shape the one-edge fixture
-- cannot exercise.
function M.transaction(companyCid, options)
  options = type(options) == "table" and options or {}
  local transaction = {
    schemaVersion = proposalCodec.CONSTRUCTION_SCHEMA_VERSION,
    companyCid = companyCid, cost = 37483,
    nodes = {
      { slot = "node:1", position = {
        x = -1107.21851, y = -962.907349, z = 7.55953884,
      } },
      { slot = "node:2", position = {
        x = -1095.14856, y = -961.128601, z = 7.55953884,
      } },
    },
    edges = {
      {
        slot = "edge:1", carrier = "street",
        node0 = { slot = "node:1" }, node1 = { slot = "node:2" },
        tangent0 = { x = 12.0699387, y = 1.77879798, z = 0 },
        tangent1 = { x = 12.0699463, y = 1.77874768, z = 0 },
        type = 0, typeIndex = -1, bus = false, tramTrackType = 0,
        resource = { index = 29, name = "street_depot/entrance_old.lua" },
        logicalOwnerCid = companyCid, private = true,
      },
      {
        slot = "edge:2", carrier = "street",
        node0 = { cid = "node:pre:352d0cd3" }, node1 = { slot = "node:2" },
        tangent0 = { x = 1.88689697, y = -12.8619471, z = 0.144908771 },
        tangent1 = { x = 1.89530396, y = -12.8604937, z = 0.161572695 },
        type = 0, typeIndex = -1, bus = false, tramTrackType = 0,
        resource = { index = 22, name = "standard/town_medium_new.lua" },
        logicalOwnerCid = companyCid, private = false,
      },
      {
        slot = "edge:3", carrier = "street",
        node0 = { slot = "node:2" }, node1 = { cid = "node:pre:410b0cf7" },
        tangent0 = { x = 10.9344397, y = -74.1951141, z = 0.932149589 },
        tangent1 = { x = 11.2135868, y = -74.1524048, z = 1.01898098 },
        type = 0, typeIndex = -1, bus = false, tramTrackType = 0,
        resource = { index = 22, name = "standard/town_medium_new.lua" },
        logicalOwnerCid = companyCid, private = false,
      },
    },
    edgeObjects = { add = {}, retain = {}, remove = {} },
    remove = { edges = { "edge:pre:65d911d6" }, nodes = {} },
    constructions = {{
      slot = "construction:1", mode = "build", sourceCid = "",
      kind = "depot", adapter = "portable-construction",
      fileName = options.fileName or "depot/road_depot_era_a.con",
      transform = {
        -0.145799428, 0.989314198, 0, 0,
        -0.989314198, -0.145799428, 0, 0,
        0, 0, 1, 0,
        -1127.79602, -965.939941, 7.55953884, 1,
      },
      params = { paramX = 0, paramY = 0, seed = 0, year = 1940 },
      modules = {}, collateral = {{
        kind = "construction", cid = "construction:pre:87462897",
      }},
    }},
  }
  transaction.digest = proposalCodec.digest(transaction)
  transaction.transactionId = "proposal:" .. transaction.digest
  local valid, validationError = proposalCodec.validate(transaction)
  if not valid then return nil, validationError end
  return transaction
end

return M
