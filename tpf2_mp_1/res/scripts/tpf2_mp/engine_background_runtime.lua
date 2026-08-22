local M = {}

function M.new(deps)
  local getState = assert(deps.getState, "engine background state provider is required")

  local function run()
    local state = getState()
    if state.networkMode ~= "network" then
      if deps.networkClock.needsUpdate() then
        local ok, err = xpcall(deps.networkClock.update, debug.traceback)
        if not ok then state.world.networkClock.lastError = tostring(err) end
      end
      if deps.economyClock.needsUpdate() then
        local ok, err = xpcall(deps.economyClock.update, debug.traceback)
        if not ok then state.probes.lastError = tostring(err) end
      end
      -- vehicleSync.update is network-only and therefore intentionally absent
      -- here; entering its protected boundary in standalone was pure overhead.
    end

    if deps.proposals.hasConstructionWork() then
      local invoked, result, detail = xpcall(
        deps.proposals.processConstructions, debug.traceback)
      if not invoked then
        state.lastError = "canonical construction processing failed: " .. tostring(result)
      elseif result ~= true then
        state.lastError = tostring(type(detail) == "table"
          and detail.error or detail or "canonical construction failed")
      end
    end
    if deps.proposals.hasFinanceWork() then
      local ok, err = xpcall(deps.proposals.processFinances, debug.traceback)
      if not ok then state.lastError = tostring(err) end
    end
    if deps.proposals.financeHousekeepingDue() then
      local invoked, ok, err = xpcall(
        deps.proposals.financeHousekeeping, debug.traceback)
      if not invoked or ok ~= true then
        state.probes.lastError = tostring(err or ok)
      end
    end
  end

  return { run = run }
end

return M
