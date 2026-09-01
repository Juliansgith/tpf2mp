local util = require "tpf2_mp/util"

local M = {}

M.SCHEMA_VERSION = 1
M.DEFAULT_MILLIS_PER_DAY = 2000
M.MIN_YEAR = 1400
M.MAX_YEAR = 9999

local function exactInteger(value)
  local number = tonumber(value)
  if not number or number ~= math.floor(number) then return nil end
  return number
end

local function leapYear(year)
  return year % 4 == 0 and (year % 100 ~= 0 or year % 400 == 0)
end

local function monthDays(year, month)
  local days = { 31, leapYear(year) and 29 or 28, 31, 30, 31, 30,
    31, 31, 30, 31, 30, 31 }
  return days[month]
end

function M.normaliseDate(value)
  if type(value) ~= "table" then return nil, "calendar date must be an object" end
  local year, month, day = exactInteger(value.year), exactInteger(value.month), exactInteger(value.day)
  if not year or year < M.MIN_YEAR or year > M.MAX_YEAR then
    return nil, "calendar year is outside the supported native range"
  end
  if not month or month < 1 or month > 12 then return nil, "calendar month is invalid" end
  local maximum = monthDays(year, month)
  if not day or day < 1 or day > maximum then return nil, "calendar day is invalid" end
  return { year = year, month = month, day = day }
end

local function daysFromCivil(date)
  local year, month, day = date.year, date.month, date.day
  if month <= 2 then year = year - 1 end
  local era = math.floor(year / 400)
  local yearOfEra = year - era * 400
  local monthPrime = month + (month > 2 and -3 or 9)
  local dayOfYear = math.floor((153 * monthPrime + 2) / 5) + day - 1
  local dayOfEra = yearOfEra * 365 + math.floor(yearOfEra / 4)
    - math.floor(yearOfEra / 100) + dayOfYear
  return era * 146097 + dayOfEra
end

local function civilFromDays(days)
  local era = math.floor(days / 146097)
  local dayOfEra = days - era * 146097
  local yearOfEra = math.floor((dayOfEra - math.floor(dayOfEra / 1460)
    + math.floor(dayOfEra / 36524) - math.floor(dayOfEra / 146096)) / 365)
  local year = yearOfEra + era * 400
  local dayOfYear = dayOfEra - (365 * yearOfEra + math.floor(yearOfEra / 4)
    - math.floor(yearOfEra / 100))
  local monthPrime = math.floor((5 * dayOfYear + 2) / 153)
  local day = dayOfYear - math.floor((153 * monthPrime + 2) / 5) + 1
  local month = monthPrime + (monthPrime < 10 and 3 or -9)
  if month <= 2 then year = year + 1 end
  return { year = year, month = month, day = day }
end

function M.addDays(date, delta)
  local valid, dateError = M.normaliseDate(date)
  if not valid then return nil, dateError end
  delta = exactInteger(delta)
  if not delta then return nil, "calendar day delta must be an integer" end
  local result = civilFromDays(daysFromCivil(valid) + delta)
  if result.year < M.MIN_YEAR or result.year > M.MAX_YEAR then
    return nil, "calendar advancement exceeds the supported native range"
  end
  return result
end

function M.newState()
  return {
    schemaVersion = M.SCHEMA_VERSION,
    managed = false,
    initialized = false,
    millisPerDay = M.DEFAULT_MILLIS_PER_DAY,
    startDate = nil,
    currentDate = nil,
    elapsedDays = 0,
    residualMillis = 0,
    lastEpoch = 0,
  }
end

function M.initialise(rules, networkMode)
  rules = type(rules) == "table" and rules or {}
  local date, dateError = M.normaliseDate(rules.calendarStartDate)
  if not date then return nil, dateError end
  local millis = exactInteger(rules.calendarMillisPerDay)
  if not millis or millis < 0 or millis > 86400000 then
    return nil, "calendar milliseconds per day are invalid"
  end
  return {
    schemaVersion = M.SCHEMA_VERSION,
    managed = networkMode == "network",
    initialized = true,
    millisPerDay = millis,
    startDate = util.deepCopy(date),
    currentDate = util.deepCopy(date),
    elapsedDays = 0,
    residualMillis = 0,
    lastEpoch = 0,
  }
end

function M.prepareSettlement(current, economyEpoch, scheduled, epochSeconds)
  current = M.migrate(current)
  if current.initialized ~= true then return nil, nil, "authored calendar is not initialised" end
  local epoch = exactInteger(economyEpoch)
  if not epoch or epoch ~= current.lastEpoch + 1 then
    return nil, nil, "calendar settlement is not the next economy epoch"
  end
  local seconds = exactInteger(epochSeconds)
  if not seconds or seconds < 1 or seconds > 86400 then
    return nil, nil, "calendar settlement duration is invalid"
  end
  local candidate = util.deepCopy(current)
  local advancedDays = 0
  if candidate.managed and scheduled == true and candidate.millisPerDay > 0 then
    local accumulated = candidate.residualMillis + seconds * 1000
    advancedDays = math.floor(accumulated / candidate.millisPerDay)
    candidate.residualMillis = accumulated % candidate.millisPerDay
    if advancedDays > 0 then
      local advanced, dateError = M.addDays(candidate.currentDate, advancedDays)
      if not advanced then return nil, nil, dateError end
      candidate.currentDate = advanced
      candidate.elapsedDays = candidate.elapsedDays + advancedDays
    end
  end
  candidate.lastEpoch = epoch
  local payload = {
    schemaVersion = M.SCHEMA_VERSION,
    economyEpoch = epoch,
    advanced = candidate.managed and scheduled == true,
    advancedDays = advancedDays,
    elapsedDays = candidate.elapsedDays,
    residualMillis = candidate.residualMillis,
    date = util.deepCopy(candidate.currentDate),
  }
  return candidate, payload
end

local function sameDate(left, right)
  return type(left) == "table" and type(right) == "table"
    and left.year == right.year and left.month == right.month and left.day == right.day
end

function M.verifySettlement(current, action, epochSeconds)
  if type(action) ~= "table" or type(action.calendar) ~= "table"
      or type(action.results) ~= "table" then
    return nil, "economy settlement requires an authored calendar payload"
  end
  local candidate, expected, prepareError = M.prepareSettlement(
    current, action.results.epoch, action.scheduled == true, epochSeconds)
  if not candidate then return nil, prepareError end
  local received = action.calendar
  local date, dateError = M.normaliseDate(received.date)
  if not date then return nil, dateError end
  if exactInteger(received.schemaVersion) ~= M.SCHEMA_VERSION
    or exactInteger(received.economyEpoch) ~= expected.economyEpoch
    or type(received.advanced) ~= "boolean" or received.advanced ~= expected.advanced
    or exactInteger(received.advancedDays) ~= expected.advancedDays
    or exactInteger(received.elapsedDays) ~= expected.elapsedDays
    or exactInteger(received.residualMillis) ~= expected.residualMillis
    or not sameDate(date, expected.date) then
    return nil, "economy settlement calendar payload diverges from deterministic replay"
  end
  return candidate, expected
end

function M.migrate(value, fallbackDate, fallbackEpoch, fallbackMillis)
  local result = M.newState()
  if type(value) == "table" then
    result.managed = value.managed == true
    result.initialized = value.initialized == true
    result.millisPerDay = util.clamp(util.integer(
      value.millisPerDay, M.DEFAULT_MILLIS_PER_DAY), 0, 86400000)
    result.elapsedDays = math.max(0, util.integer(value.elapsedDays, 0))
    result.residualMillis = math.max(0, util.integer(value.residualMillis, 0))
    if result.millisPerDay > 0 then result.residualMillis = result.residualMillis % result.millisPerDay
    else result.residualMillis = 0 end
    result.lastEpoch = math.max(0, util.integer(value.lastEpoch, 0))
    result.startDate = M.normaliseDate(value.startDate)
    result.currentDate = M.normaliseDate(value.currentDate)
    if not result.startDate then result.startDate = util.deepCopy(result.currentDate) end
    if result.initialized and not result.currentDate then result.initialized = false end
  end
  if not result.initialized then
    local observed = M.normaliseDate(fallbackDate)
    if observed then
      result.initialized = true
      result.managed = true
      result.millisPerDay = util.clamp(util.integer(
        fallbackMillis, M.DEFAULT_MILLIS_PER_DAY), 0, 86400000)
      result.startDate = util.deepCopy(observed)
      result.currentDate = util.deepCopy(observed)
      result.elapsedDays = 0
      result.residualMillis = 0
      result.lastEpoch = math.max(0, util.integer(fallbackEpoch, 0))
    end
  end
  result.schemaVersion = M.SCHEMA_VERSION
  return result
end

function M.digestView(value)
  local current = M.migrate(value)
  return {
    schemaVersion = M.SCHEMA_VERSION,
    managed = current.managed,
    initialized = current.initialized,
    millisPerDay = current.millisPerDay,
    startDate = util.deepCopy(current.startDate),
    currentDate = util.deepCopy(current.currentDate),
    elapsedDays = current.elapsedDays,
    residualMillis = current.residualMillis,
    lastEpoch = current.lastEpoch,
  }
end

return M
