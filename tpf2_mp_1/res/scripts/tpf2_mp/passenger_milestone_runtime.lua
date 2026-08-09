local aboardMilestoneRuntime = require "tpf2_mp/aboard_milestone_runtime"

local function isLocalFeeder(state, _, line)
  local service = state.economy and state.economy.services
    and state.economy.services[line.lineCid] or nil
  local metadata = service and service.metadata or {}
  local carrier = tostring(metadata.carrier or ""):upper()
  local scope = tostring(metadata.marketScope or ""):lower()
  local stations = metadata.stationGroupCids or {}
  local towns = metadata.endpointTownCids or {}
  if service == nil or service.enabled == false or scope ~= "local"
    or (carrier ~= "ROAD" and carrier ~= "TRAM")
    or type(stations) ~= "table" or #stations < 2
    or type(towns) ~= "table" or #towns ~= 2 or towns[1] ~= towns[2] then
    return false
  end
  local distinct = {}
  for _, stationCid in ipairs(stations) do distinct[stationCid] = true end
  local first = next(distinct)
  return first ~= nil and next(distinct, first) ~= nil
end

return aboardMilestoneRuntime.new({
  actionType = "passenger.milestone",
  probeKey = "passengerMilestone",
  label = "passenger",
  ledgerOf = function(state) return state.world.passengerPresentation end,
  eligible = isLocalFeeder,
})
