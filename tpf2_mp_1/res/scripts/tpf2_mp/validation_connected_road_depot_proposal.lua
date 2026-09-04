local geometry = require "tpf2_mp/validation_connected_depot_geometry"
local proposalCodec = require "tpf2_mp/proposal_codec"

local M = {}

-- Build 35924 connected STREET_DEPOT fixture captured from relay session
-- mp-87164966f1cca6a9. Callers may rotate/translate it onto a route endpoint
-- and select either the stock road or tram depot resource.
function M.transaction(companyCid, options)
  options = type(options) == "table" and options or {}
  local layout, layoutError = geometry.resolve(options)
  if not layout then return nil, layoutError end
  local params = { paramX = 0, paramY = 0, seed = 1, year = 1940 }
  for key, value in pairs(type(options.params) == "table" and options.params or {}) do
    params[key] = value
  end
  local transaction = {
    schemaVersion = proposalCodec.CONSTRUCTION_SCHEMA_VERSION,
    companyCid = companyCid, cost = 12726,
    nodes = {{ slot = "node:1", position = layout.internal }},
    edges = {{
      slot = "edge:1", carrier = "street",
      node0 = { slot = "node:1" }, node1 = { cid = layout.connectNodeCid },
      tangent0 = layout.entrance, tangent1 = layout.endpoint,
      type = 0, typeIndex = tonumber(options.typeIndex) or -1,
      bus = options.bus == true, tramTrackType = tonumber(options.tramTrackType) or 0,
      resource = { index = tonumber(options.connectionResourceIndex) or 29,
        name = options.connectionResourceName or "street_depot/entrance_old.lua" },
      logicalOwnerCid = companyCid, private = true,
    }},
    edgeObjects = { add = {}, retain = {}, remove = {} },
    remove = { edges = {}, nodes = {} },
    constructions = {{
      slot = "construction:1", mode = "build", sourceCid = "",
      kind = "depot", adapter = "portable-construction",
      fileName = options.fileName or "depot/road_depot_era_a.con",
      transform = {
        layout.xAxis.x, layout.xAxis.y, 0, 0,
        layout.yAxis.x, layout.yAxis.y, 0, 0,
        0, 0, 1, 0,
        layout.origin.x, layout.origin.y, layout.origin.z, 1,
      },
      params = params, modules = {}, collateral = {},
    }},
  }
  transaction.digest = proposalCodec.digest(transaction)
  transaction.transactionId = "proposal:" .. transaction.digest
  local valid, validationError = proposalCodec.validate(transaction)
  if not valid then return nil, validationError end
  return transaction
end

return M
