local M = {}

function M.new(getState)
  return {
    bridge = function(message) getState().bridge.lastError = message end,
    clock = function(message) getState().world.networkClock.lastError = message end,
    probe = function(message) getState().probes.lastError = message end,
    vehicle = function(message) getState().probes.vehicleSync.lastError = message end,
    deferred = function(message)
      getState().lastError = "deferred multiplayer physical-action processing failed: "
        .. message
    end,
    industry = function(message) getState().probes.industryContent.lastError = message end,
    freight = function(message) getState().probes.freightIndustry.lastError = message end,
  }
end

return M
