local util = require "tpf2_mp/util"

local M = {}

M.SCHEMA_VERSION = 1
M.MAX_SAMPLED_PERSONS = 4096
M.MAX_COSMETIC_ACTORS_PER_VEHICLE = 8
M.MAX_COSMETIC_ACTORS_PER_STATION = 16

local function component(entity, componentType)
  if not (entity and componentType and api and api.engine and api.engine.getComponent) then
    return nil
  end
  local ok, value = pcall(api.engine.getComponent, entity, componentType)
  return ok and value or nil
end

local function enumerate(componentType, callback)
  local each = api and api.engine and api.engine.forEachEntityWithComponent
  if not componentType or not util.isCallable(each) then return false, 0 end
  local count = 0
  local ok = pcall(function()
    each(function(entity)
      local accepted = callback and callback(tonumber(entity))
      if callback == nil or accepted ~= false then count = count + 1 end
    end, componentType)
  end)
  return ok, ok and count or 0
end

local function factory()
  return util.commandFactory("debugSetSimPersonState")
end

function M.newProbe()
  return {
    schemaVersion = M.SCHEMA_VERSION,
    mode = "bounded-native-scenery",
    targetWritesEnabled = false,
    targetAddressable = false,
    debugFactoryAvailable = false,
    debugFactoryEntityBooleanShape = false,
    sampledPersons = 0,
    nativeAboard = 0,
    nativeWaiting = 0,
    maximumActorsPerVehicle = M.MAX_COSMETIC_ACTORS_PER_VEHICLE,
    maximumActorsPerStation = M.MAX_COSMETIC_ACTORS_PER_STATION,
    lastError = nil,
  }
end

-- The exact-build command is intentionally only constructed, never sent.
-- Static disassembly proves an eight-byte {entity, 0|1} payload: it can reset
-- one native person's simulation state, but names no vehicle, terminal, line,
-- or canonical target. Treating it as an attachment command would move a
-- random local actor differently on each peer. The adapter becomes writable
-- only if a later pinned profile supplies a typed target-bearing operation.
local function probeFactoryShape(personId)
  local make = factory()
  if not make or not personId then return make ~= nil, false end
  local first = pcall(make, personId, false)
  local second = pcall(make, personId, true)
  return true, first and second
end

function M.sample(existing)
  local result = type(existing) == "table" and existing or M.newProbe()
  for key, value in pairs(M.newProbe()) do
    if result[key] == nil then result[key] = value end
  end
  local types = api and api.type and api.type.ComponentType or {}
  local firstPerson
  local personsOk, personCount = enumerate(types.SIM_PERSON, function(entity)
    if not firstPerson then firstPerson = entity end
    return true
  end)
  local aboardOk, aboard = enumerate(types.SIM_ENTITY_AT_VEHICLE, function(entity)
    local person = component(entity, types.SIM_PERSON) ~= nil
      or component(entity, types.SIM_PERSON_AT_VEHICLE) ~= nil
    if firstPerson == nil and person then firstPerson = entity end
    return person
  end)
  local waitingOk, waiting = enumerate(types.SIM_ENTITY_AT_TERMINAL, function(entity)
    local person = component(entity, types.SIM_PERSON) ~= nil
      or component(entity, types.SIM_PERSON_AT_TERMINAL) ~= nil
    if firstPerson == nil and person then firstPerson = entity end
    return person
  end)
  local available, shape = probeFactoryShape(firstPerson)
  result.schemaVersion = M.SCHEMA_VERSION
  result.mode = "bounded-native-scenery"
  result.targetWritesEnabled = false
  result.targetAddressable = false
  result.debugFactoryAvailable = available
  result.debugFactoryEntityBooleanShape = shape
  result.sampledPersons = personsOk and math.min(M.MAX_SAMPLED_PERSONS, personCount) or 0
  result.nativeAboard = aboardOk and aboard or 0
  result.nativeWaiting = waitingOk and waiting or 0
  result.maximumActorsPerVehicle = M.MAX_COSMETIC_ACTORS_PER_VEHICLE
  result.maximumActorsPerStation = M.MAX_COSMETIC_ACTORS_PER_STATION
  result.lastError = not (personsOk and aboardOk and waitingOk)
    and "one or more direct native passenger component readers are unavailable" or nil
  result.note = "native people remain bounded scenery; authoritative counts are rendered by TPF2MP"
  return result
end

function M.applyDesiredCounts(existing, presentationView, options)
  options = type(options) == "table" and options or {}
  local result = options.sampleNative == false
    and (type(existing) == "table" and existing or M.newProbe()) or M.sample(existing)
  result.requestedAboard = presentationView and presentationView.totals
    and math.max(0, util.integer(presentationView.totals.aboard, 0)) or 0
  result.requestedWaiting = presentationView and presentationView.totals
    and math.max(0, util.integer(presentationView.totals.waiting, 0)) or 0
  result.appliedWrites = 0
  result.coverageMode = "native-scenery-plus-authoritative-ui"
  -- Fail closed. Debug_SetSimPersonState has no target in its pinned payload;
  -- issuing it cannot prove that an actor joined the intended train/platform.
  return true, result
end

return M
