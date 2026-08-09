local M = {}

function M.new(deps)
  local getState = assert(deps.getState, "state provider is required")
  local getController = assert(deps.getController, "network controller provider is required")
  local world = assert(deps.world, "world dependency is required")
  local activeCompany = assert(deps.activeCompany, "active company dependency is required")
  local submitIntent = assert(deps.submitIntent, "intent submitter is required")
  local log = assert(deps.log, "diagnostic logger is required")

  local function line(transaction, outputCid)
    local state = getState()
    return world.autoRegisterLine(state, transaction, outputCid, {
      activeCompany = activeCompany,
      submit = function(action)
        local controller = getController()
        if state.networkMode == "network" and controller then
          return controller.scheduleFollowup(action)
        end
        return submitIntent(action)
      end,
      log = log,
    })
  end

  local function existing(reason)
    local state, controller = getState(), getController()
    if state.networkMode ~= "network" or not controller then return 0 end
    return world.autoRegisterExistingServices(state, {
      activeCompany = activeCompany,
      submit = controller.scheduleFollowup,
      log = log,
      reason = reason,
    })
  end

  return { line = line, existing = existing }
end

return M
