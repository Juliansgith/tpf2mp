local project = assert(arg[1], "project root argument required"):gsub("\\", "/")
-- The game adds a mod's res/scripts to the module path before loading
-- mod.lua; mirror that so this harness exercises the real require.
package.path = project .. "/tpf2_mp_1/res/scripts/?.lua;" .. package.path

_ = function(value) return value end
getCurrentModId = function() return "!tpf2_mp" end
game = { config = {} }
local modifiers = {}
addModifier = function(name, fn) modifiers[name] = fn end

assert(loadfile(project .. "/tpf2_mp_1/mod.lua"))()
local definition = assert(data())
local startingCashParam, economyDifficultyParam
for _, param in ipairs(definition.info.params or {}) do
  if param.key == "startingCash" then startingCashParam = param; break end
end
for _, param in ipairs(definition.info.params or {}) do
  if param.key == "economyDifficulty" then economyDifficultyParam = param; break end
end
assert(startingCashParam and startingCashParam.defaultIndex == 1
    and startingCashParam.values[1] == "25 million"
    and startingCashParam.values[2] == "50 million"
    and startingCashParam.values[3] == "100 million",
  "mod UI no longer defaults to the documented 50 million starting budget")
assert(economyDifficultyParam and economyDifficultyParam.defaultIndex == 0
    and economyDifficultyParam.values[1] == "Normal (100% revenue)"
    and economyDifficultyParam.values[2] == "Hard (60% revenue)"
    and economyDifficultyParam.values[3] == "Easy (150% revenue)"
    and economyDifficultyParam.values[4] == "Relaxed (200% revenue)",
  "world-creation UI no longer exposes the four save-owned economy modes")
definition.runFn({}, {
  ["!tpf2_mp"] = {
    peer = 0,
    session = 0,
    startupMode = 0,
    freeze = 0,
    neutralizer = 0,
    proxyMode = 0,
    pauseOnSwitch = 0,
    startingCash = 0,
    economyDifficulty = 1,
    epochLimit = 2,
    valuationTarget = 2,
    liveValidator = 0,
  },
})

local cfg = assert(game.config.tpf2mp)
assert(cfg.peerId == "player2", "launcher peer did not override the mod dropdown; TEMP="
  .. tostring(os.getenv("TEMP")) .. " peer=" .. tostring(cfg.peerId))
assert(cfg.sessionId == "launcher-test", "launcher session did not override the mod dropdown")
assert(cfg.bridgeDir == "C:/bridge/launcher-test/player2", "launcher bridge path was not loaded")
assert(cfg.startNetwork == true and cfg.launcherManaged == true,
  "launcher did not activate launcher-managed network mode")
assert(cfg.startingCash == 50000000,
  "explicit launcher research budget did not override the mod dropdown")
assert(cfg.economyDifficulty == "hard",
  "world-creation economy difficulty was not persisted into runtime config")
assert(cfg.maxEpochs == 288 and cfg.valuationTargetCents == 50000000000,
  "five-minute match length or cohort-scaled victory target was not configured")
assert(cfg.agentMode == "vanilla", "launcher agent policy did not override the mod dropdown")
assert(cfg.townDevelopment == true, "launcher town-development policy was not applied")
assert(type(modifiers.loadConstruction) == "function",
  "industry authority did not install its content-load capture")
local industry = modifiers.loadConstruction("mod/test_processor.con", {
  type = "INDUSTRY",
  updateFn = function(params)
    return {
      marker = params.marker,
      stocks = { { cargoType = "ORE" } },
      rule = { input = { { 2 } }, output = { METAL = 1 }, capacity = 120 },
    }
  end,
})
local evaluated = industry.updateFn({ productionLevel = 0, seed = 17, marker = "preserved" })
assert(evaluated.marker == "preserved", "industry capture changed the construction result")
local loaderRegistry = cfg.industryResourceFacts
-- Parallel resource loading may call runFn again after a modifier partition.
-- Model an overwritten config reference and require the next runFn pass to
-- republish the same loader-owned registry rather than replace its facts.
cfg.industryResourceFacts = { stale = true }
definition.runFn({}, { ["!tpf2_mp"] = {} })
local industryFacts = require "tpf2_mp/industry_resource_facts"
assert(cfg.industryResourceFacts == loaderRegistry,
  "repeated runFn replaced the loader-owned industry registry")
local captured = assert(industryFacts.lookup(cfg.industryResourceFacts,
  "mod/test_processor.con", { productionLevel = 0, marker = "preserved", seed = 999 }))
assert(captured.inputs[1][1].cargoType == "ORE" and captured.outputs[1].cargoType == "METAL",
  "industry capture did not retain the evaluated data-only recipe")

print("PASS short-lived launcher profile configures peer/session/bridge/network mode")
