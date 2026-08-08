local M = {}

local function modelRepository()
  local repository = api and api.res and api.res.modelRep or nil
  if repository and repository.get ~= nil and repository.find ~= nil then return repository end
  return nil
end

local function cargoKind(entry)
  local raw = entry and (entry.type or entry.cargoType) or nil
  if raw == nil then return "unknown" end
  local name = string.upper(tostring(raw))
  if name == "PASSENGERS" or name == "PASSENGER" then return "passenger" end
  return "cargo"
end

local function compartmentCapacity(compartment)
  local best = { passenger = 0, cargo = 0, unknown = 0 }
  local configs = compartment and (compartment.loadConfigs or compartment) or {}
  local iterated = pcall(function()
    for _, config in pairs(configs) do
      local totals = { passenger = 0, cargo = 0, unknown = 0 }
      for _, entry in pairs((config and config.cargoEntries) or {}) do
        local capacity = math.max(0, tonumber(entry and entry.capacity) or 0)
        local kind = cargoKind(entry)
        totals[kind] = totals[kind] + capacity
      end
      for kind, total in pairs(totals) do
        if total > best[kind] then best[kind] = total end
      end
    end
  end)
  return iterated and best or nil
end

local function transportKind(passenger, cargo, unknown)
  if unknown > 0 then return "unknown" end
  if passenger > 0 and cargo > 0 then return "mixed" end
  if passenger > 0 then return "passenger" end
  if cargo > 0 then return "cargo" end
  return "empty"
end

-- Resolve one complete consist through portable model resource names. Only an
-- explicit PASSENGERS cargo entry proves seats; all other named cargo is
-- freight and an omitted type remains unknown rather than being guessed.
function M.consist(modelNames)
  local repository = modelRepository()
  if not repository or type(modelNames) ~= "table" or #modelNames == 0 then return nil end
  local passenger, cargo, unknown, speedLimit = 0, 0, 0, nil
  for _, name in ipairs(modelNames) do
    local found, index = pcall(repository.find, name)
    if not found or tonumber(index) == nil or tonumber(index) < 0 then return nil end
    local ok, record = pcall(repository.get, tonumber(index))
    if not ok or record == nil then return nil end
    local metadata = record.metadata or record
    local transport = metadata and metadata.transportVehicle or nil
    if not transport then return nil end
    local part = { passenger = 0, cargo = 0, unknown = 0 }
    local scanned = pcall(function()
      for _, compartment in pairs(transport.compartmentsList or transport.compartments or {}) do
        local capacity = compartmentCapacity(compartment)
        if capacity == nil then error("unreadable compartment") end
        for kind, value in pairs(capacity) do part[kind] = part[kind] + value end
      end
    end)
    if not scanned then return nil end
    passenger, cargo, unknown = passenger + part.passenger,
      cargo + part.cargo, unknown + part.unknown
    local speed = tonumber(transport.topSpeed)
    if speed and speed > 0 and (speedLimit == nil or speed < speedLimit) then
      speedLimit = speed
    end
  end
  return {
    seats = passenger > 0 and passenger or unknown,
    passengerCapacity = passenger, cargoCapacity = cargo,
    unknownCapacity = unknown, kind = transportKind(passenger, cargo, unknown),
    limitSpeedMs = speedLimit,
  }
end

-- Combine every consist assigned to a line. Service capacity uses the integer
-- fleet-average seats because the headway already represents fleet-wide
-- departures; classification and speed remain conservative across all trains.
function M.combine(consists)
  if type(consists) ~= "table" then return nil end
  local passenger, cargo, unknown, speedLimit, count = 0, 0, 0, nil, 0
  for _, facts in ipairs(consists) do
    if type(facts) ~= "table" then return nil end
    count = count + 1
    passenger = passenger + math.max(0, tonumber(facts.passengerCapacity) or 0)
    cargo = cargo + math.max(0, tonumber(facts.cargoCapacity) or 0)
    unknown = unknown + math.max(0, tonumber(facts.unknownCapacity) or 0)
    local speed = tonumber(facts.limitSpeedMs)
    if speed and speed > 0 and (speedLimit == nil or speed < speedLimit) then
      speedLimit = speed
    end
  end
  return {
    seats = count > 0 and math.floor(passenger / count) or 0,
    passengerCapacity = passenger, cargoCapacity = cargo,
    unknownCapacity = unknown, kind = transportKind(passenger, cargo, unknown),
    limitSpeedMs = speedLimit, consistCount = count,
  }
end

return M
