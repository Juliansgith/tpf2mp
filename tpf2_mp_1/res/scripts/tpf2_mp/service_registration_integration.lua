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

  local function afterProposalOutcome(action)
    if type(action) ~= "table" or action.success ~= true then return false end
    local state = getState()
    local record = state.world.proposals.byId[tostring(action.proposalId or "")]
    if not record or not world.proposalMayChangePassengerAccess(record.transaction) then
      return false
    end
    -- Exact access is a native world fact, so derive it only after physical
    -- consensus. `existing` uses the coalesced authored follow-up FIFO.
    existing("passenger-access:" .. tostring(action.proposalId or "unknown"))
    return true
  end

  return { line = line, existing = existing,
    afterProposalOutcome = afterProposalOutcome }
end

return M
