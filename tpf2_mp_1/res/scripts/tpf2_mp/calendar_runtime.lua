local util = require "tpf2_mp/util"
local calendarModel = require "tpf2_mp/calendar_model"

local M = {}

function M.new(deps)
  assert(type(deps) == "table", "calendar runtime dependencies are required")
  local getState = assert(deps.getState, "calendar state provider is required")
  local clockSnapshot = assert(deps.clockSnapshot, "calendar clock snapshot is required")
  local commandFactory = deps.commandFactory or util.commandFactory
  local sendCommand = deps.sendCommand or util.sendCommand
  local authorizeCommand = deps.authorizeCommand or function(tag)
    local authorize = rawget(_G, "tpf2mp_native_authorize_command")
    if type(authorize) ~= "function" then return false, "native command authorization is unavailable" end
    local called, accepted, err = pcall(authorize, tostring(tag))
    if not called or accepted == false then return false, tostring(err or accepted) end
    return true
  end
  local dateFactory = deps.dateFactory or function(date)
    local constructor = api and api.type and api.type.Date and api.type.Date.new
    if not util.isCallable(constructor) then return nil, "api.type.Date.new is unavailable" end
    local ok, value = pcall(constructor, date.year, date.month, date.day)
    if not ok then return nil, tostring(value) end
    return value
  end
  local verified = false
  local runtime = {}

  local function sameDate(left, right)
    return type(left) == "table" and type(right) == "table"
      and tonumber(left.year) == right.year and tonumber(left.month) == right.month
      and tonumber(left.day) == right.day
  end

  local function issueDate(date, origin)
    local observed = clockSnapshot() or {}
    if sameDate(observed.date, date) then verified = true; return true, { unchanged = true } end
    local factory = commandFactory("setDate")
    if not factory then return false, "network calendar requires the SetDate factory" end
    local nativeDate, dateError = dateFactory(date)
    if not nativeDate then return false, "could not construct native Date: " .. tostring(dateError) end
    local made, commandOrError = pcall(factory, nativeDate)
    if not made then return false, "could not create SetDate: " .. tostring(commandOrError) end
    local state = getState()
    if state.networkMode == "network" then
      local authorized, authorizeError = authorizeCommand(26)
      if not authorized then return false, "could not authorize SetDate: " .. tostring(authorizeError) end
    end
    local callbackSuccess, callbackSeen = nil, false
    local sent, sendError = sendCommand(commandOrError, function(_, success)
      callbackSeen, callbackSuccess = true, success == true
    end, origin or "mod.network.set-date")
    if not sent then return false, "could not issue SetDate: " .. tostring(sendError) end
    if callbackSeen and not callbackSuccess then return false, "native SetDate command was rejected" end
    local readback = clockSnapshot() or {}
    if not sameDate(readback.date, date) then
      return false, "native SetDate readback did not match the authored calendar"
    end
    verified = true
    return true, { unchanged = false, date = util.deepCopy(date) }
  end

  function runtime.applySettlement(action)
    local state = getState()
    local seconds = state.economy and state.economy.scheduler
      and state.economy.scheduler.epochSeconds or 300
    local candidate, expectedOrError = calendarModel.verifySettlement(
      state.world.calendar, action, seconds)
    if not candidate then return false, expectedOrError end
    if candidate.managed then
      local issued, issueResult = issueDate(candidate.currentDate, "mod.network.calendar-settlement")
      if not issued then return false, issueResult end
    end
    state.world.calendar = candidate
    state.probes.authoredCalendar = {
      ready = true,
      date = util.deepCopy(candidate.currentDate),
      elapsedDays = candidate.elapsedDays,
      residualMillis = candidate.residualMillis,
      lastEpoch = candidate.lastEpoch,
      nativeVerified = verified,
    }
    return true, util.deepCopy(expectedOrError)
  end

  function runtime.ensureNative()
    local state = getState()
    local current = state.world and state.world.calendar
    if state.networkMode ~= "network" or type(current) ~= "table"
      or current.initialized ~= true or not current.currentDate then return false, "inactive" end
    if verified then return false, "already-verified" end
    local ok, result = issueDate(current.currentDate, "mod.network.calendar-rearm")
    if not ok then
      state.probes.authoredCalendar = { ready = false, error = tostring(result) }
      return false, result
    end
    return true, result
  end

  function runtime.needsUpdate()
    local state = getState()
    return state.networkMode == "network" and state.world and state.world.calendar
      and state.world.calendar.initialized == true and not verified
  end

  function runtime.reset() verified = false end
  return runtime
end

return M
