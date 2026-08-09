local aboardMilestoneRuntime = require "tpf2_mp/aboard_milestone_runtime"

return aboardMilestoneRuntime.new({
  actionType = "freight.milestone",
  probeKey = "freightMilestone",
  label = "freight",
  ledgerOf = function(state) return state.world.cargoPresentation end,
  eligible = function(_, _, line) return line.retired ~= true end,
})
