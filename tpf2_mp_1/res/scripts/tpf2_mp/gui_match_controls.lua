local matchInitialisePolicy = require "tpf2_mp/match_initialise_policy"

local M = {}

function M.add(rootLayout, addRow, cfg)
  local actions = {
    { "Finish Match", function() return { type = "match.finish", reason = "manual-ui" } end },
    { "Cycle Company", function() return { type = "company.cycle" } end },
    { "Reconcile Turn", function() return { type = "company.reconcile" } end },
  }
  if matchInitialisePolicy.showManualControl(cfg) then
    table.insert(actions, 1,
      { "Initialise Match", function() return { type = "match.initialise" } end })
  else
    rootLayout:addItem(api.gui.comp.TextView.new(
      "Match setup is automatic once both multiplayer peers are connected."))
  end
  addRow(rootLayout, actions)
end

return M
