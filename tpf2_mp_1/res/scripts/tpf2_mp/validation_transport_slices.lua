local lifecycleModule = require "tpf2_mp/validation_transport_lifecycle"

local M = {}

function M.new(deps)
  local air = lifecycleModule.new(deps, {
    carrier = "AIR", prefix = "air-route",
    facilities = {
      -- The pinned qualification save starts in 1940. Use the stock passenger
      -- airfield so the native repository considers the facility available;
      -- the modern airport has separate standalone coverage in a 1990 world.
      { kind = "airfield", x = -1400, y = -1400, year = 1940 },
      { kind = "airfield", x = 1400, y = -1400, year = 1940 },
    },
    models = {
      "vehicle/plane/junkers_f_13_v2.mdl",
      "vehicle/plane/douglas_dc3_v2.mdl",
      "vehicle/plane/airbus_a320_v2.mdl",
    },
  })
  local tram = lifecycleModule.new(deps, {
    carrier = "TRAM", prefix = "tram-route",
    facilities = {
      { kind = "tram_terminal", x = -1300, y = -900, year = 1990 },
      { kind = "tram_terminal", x = -1550, y = -900, year = 1990 },
    },
    -- The operational road branches from the live-proven connected tram depot.
    -- The two terminals remain independent construction coverage: joining
    -- independently generated terminal graphs crashes Build 35924.
    tramApproachCid = "node:pre:410b0cf7",
    tramDepotEntrancePosition = {
      x = -1082.250244140625, y = -1047.3646240234375,
      z = 8.6015548706054688,
    },
    -- The clockwise/east branch crosses occupied town geometry in the pinned
    -- qualification save. Branch west into the clear field and keep the
    -- fixture compact so its purpose remains transport lifecycle coverage.
    tramBranchSide = -1,
    tramRouteSpacing = 56,
    tramConnectorGap = 32,
    models = {
      "vehicle/tram/typ1_v2.mdl", "vehicle/tram/schst_v2.mdl",
      "vehicle/tram/atm_4000_v2.mdl", "vehicle/tram/duewag_gt8.mdl",
    },
  })
  return {
    begin = function(name)
      if name == "air-route" then air.begin(); return true end
      if name == "tram-route" then tram.begin(); return true end
      return false
    end,
    maintain = function(stage)
      return air.maintain(stage) or tram.maintain(stage)
    end,
  }
end

return M
