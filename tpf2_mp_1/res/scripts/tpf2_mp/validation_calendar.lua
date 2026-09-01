local util = require "tpf2_mp/util"
local hash = require "tpf2_mp/hash"
local world = require "tpf2_mp/world"
local calendarModel = require "tpf2_mp/calendar_model"

local M = {}

local function sameDate(left, right)
  return type(left) == "table" and type(right) == "table"
    and left.year == right.year and left.month == right.month and left.day == right.day
end

-- Exercises the actual ordered settlement path, not only the calendar helper.
-- It belongs after construction validation so the resulting checkpoint also
-- proves that an authored date survives the same consensus boundary as the
-- economy state.  The initial values are captured during match bootstrap so a
-- faster peer cannot accidentally target a second epoch while catching up.
function M.new(deps)
  assert(type(deps) == "table", "calendar validation dependencies are required")
  local getState = assert(deps.getState, "getState dependency is required")
  local transition = assert(deps.transition, "transition dependency is required")
  local check = assert(deps.check, "check dependency is required")
  local submit = assert(deps.submit, "submit dependency is required")
  local checkpoint = assert(deps.checkpoint, "checkpoint dependency is required")
  local finish = assert(deps.finish, "finish dependency is required")

  local runtime = {}

  function runtime.begin(boundarySeq)
    local state = getState()
    local values = state.validation.values
    local before = calendarModel.migrate(values.initialCalendar)
    local targetEpoch = (tonumber(values.initialEconomyEpoch) or 0) + 1
    local seconds = state.economy.scheduler and state.economy.scheduler.epochSeconds or 300
    local expected, payload, expectedError = calendarModel.prepareSettlement(
      before, targetEpoch, true, seconds)
    check("calendar-settlement-candidate-valid", expected ~= nil, {
      error = expectedError, before = before, targetEpoch = targetEpoch,
    })
    values.calendarValidationPreviousBoundary = boundarySeq
    values.calendarValidationTargetEpoch = targetEpoch
    values.calendarValidationExpected = util.deepCopy(expected)
    values.calendarValidationPayloadDigest = hash.value(payload)
    if state.bridge.peerId == "player1" and state.economy.epoch < targetEpoch then
      local result = submit({ type = "economy.settle", scheduled = true },
        "calendar-economy-settlement-queued")
      values.calendarSettlementLocalSeq = result and result.local_seq
    end
    transition("wait-for-calendar-settlement")
  end

  function runtime.maintain(stage)
    if stage ~= "wait-for-calendar-settlement"
      and stage ~= "wait-for-calendar-checkpoint" then return false end
    local state = getState()
    local values = state.validation.values
    local targetEpoch = tonumber(values.calendarValidationTargetEpoch) or -1
    if stage == "wait-for-calendar-settlement" then
      local current = calendarModel.migrate(state.world.calendar)
      if state.economy.epoch < targetEpoch or current.lastEpoch < targetEpoch then return true end
      local expected = values.calendarValidationExpected
      check("ordered-calendar-settlement-applied",
        hash.value(calendarModel.digestView(current))
          == hash.value(calendarModel.digestView(expected)), {
          expected = expected, current = current,
        })
      check("ordered-calendar-advanced",
        current.elapsedDays > (values.initialCalendar.elapsedDays or 0), {
          initial = values.initialCalendar, current = current,
        })
      local observed = world.clockSnapshot()
      check("native-calendar-matches-authored-date",
        sameDate(observed.date, current.currentDate), {
          observed = observed, authored = current.currentDate,
        })
      transition("wait-for-calendar-checkpoint")
      return true
    end

    local previousBoundary = tonumber(values.calendarValidationPreviousBoundary) or 0
    local agreed = checkpoint(function(record)
      return record.reason == "economy-settlement"
        and tonumber(record.boundarySeq or 0) > previousBoundary
    end)
    if not agreed then return true end
    check("calendar-checkpoint-consensus", agreed.success == true, agreed)
    values.calendarValidationBoundary = agreed.boundarySeq
    finish(agreed.boundarySeq)
    return true
  end

  return runtime
end

return M
