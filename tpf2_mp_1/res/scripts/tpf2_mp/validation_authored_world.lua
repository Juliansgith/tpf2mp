local util = require "tpf2_mp/util"
local calendarValidationModule = require "tpf2_mp/validation_calendar"
local townValidationModule = require "tpf2_mp/validation_town_development"

local M = {}

-- Selects the mutually exclusive authored-world experiment used by the live
-- validator. Town-development runs deliberately own their native settle time;
-- ordinary runs use the ordered economy/calendar proof instead.
function M.new(deps)
  assert(type(deps) == "table", "authored-world validation dependencies are required")
  local getState = assert(deps.getState, "getState dependency is required")
  local config = assert(deps.config, "config dependency is required")
  local town = townValidationModule.new(deps)
  local calendar = calendarValidationModule.new({
    getState = getState, transition = deps.transition, check = deps.check,
    submit = deps.submit, checkpoint = deps.checkpoint, finish = deps.beginSoak,
  })
  local runtime = {}

  function runtime.captureInitial()
    local state = getState()
    state.validation.values.initialEconomyEpoch = state.economy.epoch
    state.validation.values.initialCalendar = util.deepCopy(state.world.calendar)
  end

  function runtime.begin(boundarySeq)
    if config().townDevelopment then town.begin(boundarySeq)
    else calendar.begin(boundarySeq) end
  end

  function runtime.maintain(stage)
    return calendar.maintain(stage) or town.maintain(stage)
  end

  return runtime
end

return M
