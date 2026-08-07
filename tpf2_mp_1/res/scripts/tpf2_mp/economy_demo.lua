local util = require "tpf2_mp/util"

local M = {}

-- Developer-only synthetic market. Production services are registered from
-- native lines; keeping this fixture out of the entry point makes that policy
-- obvious and prevents test data from obscuring the multiplayer dispatcher.
function M.seed(state, economy)
  local first, second = state.companyOrder[1], state.companyOrder[2]
  if not first or not second then return false, "initialise the match first" end
  economy.upsertMarket(state.economy, {
    cid = "market:prototype-corridor", name = "Prototype intercity corridor",
    demand = 1000, votCentsPerHour = 450, gcOutsideCents = 2500, thetaCents = 250,
  })
  economy.upsertService(state.economy, {
    lineCid = "line:prototype-company-1", marketCid = "market:prototype-corridor",
    companyCid = first, name = state.companies[first].name .. " service",
    headwaySeconds = 900, journeySeconds = 2400, fareCents = 1000,
    capacity = 600, quality = 100, transfers = 0,
  })
  economy.upsertService(state.economy, {
    lineCid = "line:prototype-company-2", marketCid = "market:prototype-corridor",
    companyCid = second, name = state.companies[second].name .. " service",
    headwaySeconds = 1100, journeySeconds = 2200, fareCents = 900,
    capacity = 600, quality = 100, transfers = 0,
  })
  economy.upsertMarket(state.economy, {
    cid = "market:prototype-freight", name = "Prototype freight corridor",
    kind = "cargo", demand = 800,
  })
  economy.upsertService(state.economy, {
    lineCid = "line:prototype-freight-1", marketCid = "market:prototype-freight",
    companyCid = first, name = state.companies[first].name .. " freight",
    headwaySeconds = 3600, journeySeconds = 5400, fareCents = 700,
    capacity = 400, quality = 100, transfers = 0,
  })
  economy.upsertService(state.economy, {
    lineCid = "line:prototype-freight-2", marketCid = "market:prototype-freight",
    companyCid = second, name = state.companies[second].name .. " freight",
    headwaySeconds = 2700, journeySeconds = 4800, fareCents = 800,
    capacity = 400, quality = 100, transfers = 0,
  })
  local previewState = util.deepCopy(state.economy)
  local preview = economy.evaluateAll(previewState)
  preview.epoch = state.economy.epoch
  preview.preview = true
  state.economy.lastResults = util.deepCopy(preview)
  return true, preview
end

return M
