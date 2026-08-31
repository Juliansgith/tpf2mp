local proposalCodec = require "tpf2_mp/proposal_codec"

local M = {}

-- Exact Build 35924 transaction captured from relay session
-- mp-87164966f1cca6a9. This is deliberately a connected STREET_DEPOT: the
-- construction helper can place its shell but cannot carry the explicit
-- existing-road endpoint, which left that live proposal pending forever. The
-- fixture may select the graph-compatible road or tram construction resource.
function M.transaction(companyCid, options)
  options = type(options) == "table" and options or {}
  local params = { paramX = 0, paramY = 0, seed = 1, year = 1940 }
  for key, value in pairs(type(options.params) == "table" and options.params or {}) do
    params[key] = value
  end
  local transaction = {
    schemaVersion = proposalCodec.CONSTRUCTION_SCHEMA_VERSION,
    companyCid = companyCid,
    cost = 12726,
    nodes = {{
      slot = "node:1",
      position = { x = -1082.250244140625, y = -1047.3646240234375,
        z = 8.6015548706054688 },
    }},
    edges = {{
      slot = "edge:1", carrier = "street",
      node0 = { slot = "node:1" }, node1 = { cid = "node:pre:410b0cf7" },
      tangent0 = { x = -1.8242249488830566, y = 12.063109397888184, z = 0 },
      tangent1 = { x = -1.82421875, y = 12.0631103515625, z = 0 },
      type = 0, typeIndex = -1,
      resource = { index = 29, name = "street_depot/entrance_old.lua" },
      logicalOwnerCid = companyCid, private = true,
    }},
    edgeObjects = { add = {}, retain = {}, remove = {} },
    remove = { edges = {}, nodes = {} },
    constructions = {{
      slot = "construction:1", mode = "build", sourceCid = "",
      kind = "depot", adapter = "portable-construction",
      fileName = options.fileName or "depot/road_depot_era_a.con",
      transform = {
        -0.98875820636749268, -0.14952342212200165, 0, 0,
        0.14952342212200165, -0.98875820636749268, 0, 0,
        0, 0, 1, 0,
        -1079.1402587890625, -1067.9305419921875, 8.6015548706054688, 1,
      },
      params = params,
      modules = {}, collateral = {},
    }},
  }
  transaction.digest = proposalCodec.digest(transaction)
  transaction.transactionId = "proposal:" .. transaction.digest
  local valid, validationError = proposalCodec.validate(transaction)
  if not valid then return nil, validationError end
  return transaction
end

return M
