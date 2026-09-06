-- Read-only physical vehicle evidence. Called only by the opt-in lab observer.
-- MOVE_PATH.dyn.speed / MOVE_PATH_AIRCRAFT.speed are public native fields:
-- https://wiki.transportfever2.com/api/modules/api.type.html#MovePath
local M = {}
local function field(value, key)
  if value == nil then return nil end
  local ok, result = pcall(function() return value[key] end)
  if ok then return result end
end
function M.read(registry, gameApi, interface)
  local result, towns, depots = {}, {}, { missingName = 0, entries = {} }
  local types = gameApi.type.ComponentType
  local function component(id, name)
    if not types[name] then return nil end
    return gameApi.engine.getComponent(id, types[name])
  end
  for cid, binding in pairs(registry.byCanonical or {}) do
    local id = tonumber(binding.localId)
    if id and id >= 0 and (binding.kind == "vehicle" or binding.kind == "town" or binding.kind == "depot")
      and gameApi.engine.entityExists(id) then
      if binding.kind == "vehicle" then
        local vehicle = component(id, "TRANSPORT_VEHICLE")
        if vehicle then
          local movement = component(id, "MOVE_PATH")
          local aircraft = component(id, "MOVE_PATH_AIRCRAFT")
          local lineId = tonumber(field(vehicle, "line"))
          local config = require("tpf2_mp/operation_vehicle_postcondition").project(vehicle, gameApi)
          local models
          if config.vehicleConfigKnown then
            models = {}
            for _, part in ipairs(config.vehicleConfig.vehicles) do models[#models + 1] = part.model end
          end
          result[cid] = { owner = binding.metadata and binding.metadata.owner,
            models = models,
            lineCid = lineId and registry.byLocal["line:" .. tostring(lineId)],
            state = tonumber(field(vehicle, "state")),
            stopIndex = tonumber(field(vehicle, "stopIndex")),
            carrier = tonumber(field(vehicle, "carrier")),
            userStopped = field(vehicle, "userStopped"),
            speed = tonumber(field(field(movement, "dyn"), "speed"))
              or tonumber(field(aircraft, "speed")),
            blocked = tonumber(field(movement, "blocked")),
          }
        end
      elseif binding.kind == "depot" then
        local name = component(id, "NAME")
        local depot = component(id, "VEHICLE_DEPOT")
        depots.entries[cid] = { localId = id, hasName = name ~= nil,
          name = field(name, "name"), carrier = tonumber(field(depot, "carrier")) }
        if name == nil then depots.missingName = depots.missingName + 1 end
      else
        local position = field(component(id, "TOWN"), "pos")
        if position == nil and interface and interface.getEntity then
          local ok, town = pcall(interface.getEntity, id)
          if ok then position = field(town, "position") end
        end
        local x = tonumber(field(position, "x")) or tonumber(field(position, 1))
        local y = tonumber(field(position, "y")) or tonumber(field(position, 2))
        if x and y then
          towns[cid] = { x = x, y = y,
            z = tonumber(field(position, "z")) or tonumber(field(position, 3)) or 0 }
        end
      end
    end
  end
  return result, towns, depots
end
return M
