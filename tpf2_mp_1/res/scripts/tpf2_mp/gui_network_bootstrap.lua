local M = {}

function M.new(deps)
  assert(type(deps) == "table", "GUI network bootstrap dependencies are required")
  local installObserver = assert(deps.installObserver, "installObserver dependency is required")
  local markNativeContext = assert(deps.markNativeContext, "markNativeContext dependency is required")
  local configureAuthority = assert(deps.configureAuthority, "configureAuthority dependency is required")
  local freezeGame = assert(deps.freezeGame, "freezeGame dependency is required")
  local freezeCalendar = assert(deps.freezeCalendar, "freezeCalendar dependency is required")

  return function()
    installObserver()
    markNativeContext("gui")
    local authorityReady, authorityError = configureAuthority("network")
    local gameReady, gameError, calendarReady, calendarError = false, nil, false, nil
    if authorityReady then
      gameReady, gameError = freezeGame()
      calendarReady, calendarError = freezeCalendar()
    end
    return {
      authorityReady = authorityReady == true,
      gameReady = gameReady == true,
      calendarReady = calendarReady == true,
      error = authorityError or gameError or calendarError,
    }
  end
end

return M
