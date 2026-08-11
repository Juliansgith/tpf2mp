local M = {}

function M.new(deps)
  assert(type(deps) == "table", "GUI load dependencies are required")
  local gui = assert(deps.gui, "GUI state is required")
  local stateVersion = assert(deps.stateVersion, "state version is required")
  local migrate = assert(deps.migrate, "state migrator is required")
  local setState = assert(deps.setState, "state setter is required")
  local getState = assert(deps.getState, "state provider is required")
  local isEngineThread = assert(deps.isEngineThread, "thread detector is required")
  local resetTransientRuntime = assert(deps.resetTransientRuntime, "runtime reset is required")
  local config = assert(deps.config, "config provider is required")
  local activeCompany = assert(deps.activeCompany, "active company provider is required")
  local publicSnapshot = assert(deps.publicSnapshot, "snapshot projector is required")
  local renderGui = assert(deps.renderGui, "GUI renderer is required")

  local function load(saved)
    local engineThread = isEngineThread()
    -- Engine state owns migration. The GUI receives that current schema on
    -- every state transfer, so remigrating retained proposal graphs there is
    -- both unnecessary and increasingly expensive in a developed world.
    local needsMigration = engineThread
      or type(saved) ~= "table" or saved.version ~= stateVersion
    local nextState = needsMigration and migrate(saved) or saved
    setState(nextState)
    if engineThread then resetTransientRuntime(); return nextState end
    if config().networkAutoValidate then return nextState end

    local frame = tonumber(gui.frames) or 0
    local activeCid = select(1, activeCompany())
    local current = gui.snapshot
    local priorityChange = current == nil
      or current.initialized ~= (nextState.initialized == true)
      or current.activeCompanyCid ~= activeCid
      or current.networkMode ~= nextState.networkMode
      or current.sessionId ~= nextState.bridge.sessionId
      or current.lastError ~= nextState.lastError
    -- Public projection walks the authored economy and presentation maps.
    -- Rebuilding it twice per second also rerendered a hidden Multiplayer
    -- window while a stock vehicle window was animating. Priority state still
    -- projects immediately; ordinary presentation data is three-second UI.
    if priorityChange
      or frame - (gui.lastSnapshotProjectionFrame or -1000) >= 180 then
      gui.snapshot = publicSnapshot({ allowNativeAccounts = false })
      gui.lastSnapshotProjectionFrame = frame
      gui.snapshotProjections = (gui.snapshotProjections or 0) + 1
      if gui.status then renderGui() end
    end
    return getState()
  end

  return { load = load }
end

return M
