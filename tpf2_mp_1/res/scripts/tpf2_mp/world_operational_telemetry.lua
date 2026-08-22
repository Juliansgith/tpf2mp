local util = require "tpf2_mp/util"
local hash = require "tpf2_mp/hash"

local M = {}

local function readGameTimeSeconds(interface)
  local observed = interface.getGameTime()
  return tonumber(observed and observed.time)
end

function M.new(deps)
  assert(type(deps) == "table", "world telemetry dependencies are required")
  local safeField = assert(deps.safeField, "safeField dependency is required")

  local function primitive(value)
    local valueType = type(value)
    if valueType == "nil" or valueType == "boolean" or valueType == "string" then
      return value
    end
    if valueType == "number" then return tonumber(value) end
    return nil
  end

  local function autonomySnapshot(registry, worldState)
    local towns, industries = {}, {}
    local townActive, townFrozen = 0, 0
    for _, townId in ipairs(deps.listTowns()) do
      local town = deps.component(townId, api.type.ComponentType.TOWN)
      local active = primitive(safeField(town, "developmentActive"))
      if active == true then townActive = townActive + 1
      elseif active == false then townFrozen = townFrozen + 1 end
      towns[#towns + 1] = {
        cid = deps.bindExisting(registry, townId, "town", { name = deps.nameOf(townId) }),
        developmentActive = active,
      }
    end
    table.sort(towns, function(a, b) return tostring(a.cid) < tostring(b.cid) end)

    local manualTrue, manualFalse, manualUnknown = 0, 0, 0
    local industryFields = {
      "manualDevelopment", "closureTimeStamp", "level", "productionLevel",
      "production", "active", "enabled",
    }
    for _, industryId in ipairs(deps.listIndustries()) do
      local simBuilding = deps.component(industryId, api.type.ComponentType.SIM_BUILDING)
      local fields = {}
      for _, field in ipairs(industryFields) do
        local value = primitive(safeField(simBuilding, field))
        if value ~= nil then fields[field] = value end
      end
      local manual = fields.manualDevelopment
      if manual == true then manualTrue = manualTrue + 1
      elseif manual == false then manualFalse = manualFalse + 1
      else manualUnknown = manualUnknown + 1 end
      industries[#industries + 1] = {
        fingerprint = deps.fingerprint(industryId, "industry"),
        fields = fields,
      }
    end
    table.sort(industries, function(a, b)
      if a.fingerprint == b.fingerprint then
        return hash.value(a.fields) < hash.value(b.fields)
      end
      return tostring(a.fingerprint) < tostring(b.fingerprint)
    end)

    local view = {
      requestedFrozen = worldState and worldState.autonomyFrozen == true or false,
      towns = towns,
      industries = industries,
      totals = {
        towns = #towns,
        townDevelopmentActive = townActive,
        townDevelopmentFrozen = townFrozen,
        industries = #industries,
        industryManualTrue = manualTrue,
        industryManualFalse = manualFalse,
        industryManualUnknown = manualUnknown,
      },
      lastFreezeResult = util.deepCopy(worldState and worldState.lastFreezeResult or nil),
    }
    view.digest = hash.value({
      requestedFrozen = view.requestedFrozen,
      towns = towns,
      industries = industries,
      totals = view.totals,
    })
    return view
  end

  local function clockSnapshot()
    local interface = game and game.interface or {}
    local result = {
      gameSpeedAvailable = util.isCallable(interface.getGameSpeed),
      gameTimeAvailable = util.isCallable(interface.getGameTime),
    }
    if result.gameSpeedAvailable then
      local ok, value = pcall(interface.getGameSpeed)
      if ok then result.gameSpeed = tonumber(value)
      else result.gameSpeedError = tostring(value) end
    end
    if result.gameTimeAvailable then
      local ok, value = pcall(interface.getGameTime)
      if ok and (type(value) == "table" or type(value) == "userdata") then
        result.time = tonumber(safeField(value, "time"))
        local date = safeField(value, "date")
        if type(date) == "table" or type(date) == "userdata" then
          result.date = {
            year = tonumber(safeField(date, "year")),
            month = tonumber(safeField(date, "month")),
            day = tonumber(safeField(date, "day")),
          }
        end
      else result.gameTimeError = tostring(value) end
    end
    result.paused = result.gameSpeed == 0
    return result
  end

  -- The host economy scheduler needs only this scalar on every running
  -- update.  Building the full clock/date diagnostic snapshot there used to
  -- query both native clocks and allocate a date table five times per second.
  local function gameTimeSeconds()
    local interface = game and game.interface or {}
    if not util.isCallable(interface.getGameTime) then return nil end
    local ok, value = pcall(readGameTimeSeconds, interface)
    return ok and value or nil
  end

  local function journalScalars(value, path, output, budget, depth, seen)
    if budget.remaining <= 0 or depth > 6 then return end
    local valueType = type(value)
    if valueType == "number" then
      output[path ~= "" and path or "value"] = tonumber(value)
      budget.remaining = budget.remaining - 1
      return
    end
    if valueType ~= "table" or seen[value] then return end
    seen[value] = true
    for _, key in ipairs(util.sortedKeys(value)) do
      if budget.remaining <= 0 then break end
      local keyType = type(key)
      if keyType == "string" or keyType == "number" then
        local child = path == "" and tostring(key) or (path .. "." .. tostring(key))
        journalScalars(value[key], child, output, budget, depth + 1, seen)
      end
    end
    seen[value] = nil
  end

  local function journalSnapshot(previousTimeMs)
    local interface = game and game.interface or {}
    local result = {
      available = util.isCallable(interface.getPlayerJournal)
        and util.isCallable(interface.getGameTime),
      previousTimeMs = tonumber(previousTimeMs),
    }
    if not result.available then return result end
    local timeOk, gameTime = pcall(interface.getGameTime)
    local seconds = timeOk and tonumber(safeField(gameTime, "time")) or nil
    if not seconds then
      result.error = "game time unavailable: " .. tostring(gameTime)
      return result
    end
    result.toTimeMs = math.floor(seconds * 1000)
    result.fromTimeMs = result.previousTimeMs and (result.previousTimeMs + 1)
      or math.max(0, result.toTimeMs - 60000)
    if result.toTimeMs < result.fromTimeMs then
      result.unchanged = true
      result.scalars = {}
      result.digest = hash.value(result.scalars)
      return result
    end
    local ok, journal = pcall(
      interface.getPlayerJournal, result.fromTimeMs, result.toTimeMs, false)
    if not ok or type(journal) ~= "table" then
      result.error = "journal read failed: " .. tostring(journal)
      return result
    end
    result.scalars = {}
    local budget = { remaining = 192 }
    journalScalars(journal, "", result.scalars, budget, 0, {})
    result.truncated = budget.remaining <= 0
    result.digest = hash.value(result.scalars)
    if util.isCallable(interface.getPlayer) then
      local playerOk, player = pcall(interface.getPlayer)
      if playerOk then result.activePlayerId = tonumber(player) end
    end
    return result
  end

  local function operationalSnapshot(registry, worldState, companies, previousJournalTimeMs)
    return {
      schemaVersion = 1,
      clock = clockSnapshot(),
      structural = deps.structuralSnapshot(registry, worldState, companies),
      mobility = deps.mobilitySnapshot(registry),
      autonomy = autonomySnapshot(registry, worldState),
      industryResources = deps.industryResourceProbe and deps.industryResourceProbe() or nil,
      journal = journalSnapshot(previousJournalTimeMs),
    }
  end

  return {
    autonomySnapshot = autonomySnapshot,
    clockSnapshot = clockSnapshot,
    gameTimeSeconds = gameTimeSeconds,
    journalSnapshot = journalSnapshot,
    operationalSnapshot = operationalSnapshot,
  }
end

return M
