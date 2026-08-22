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
  local resetReplayWork = deps.resetReplayWork or function() end
  local wallTime = deps.wallTime or function()
    local native = rawget(_G, "tpf2mp_native_monotonic_us")
    if type(native) == "function" then
      local ok, value = pcall(native)
      if ok and tonumber(value) then return tonumber(value) / 1000000 end
    end
    return os and type(os.time) == "function" and os.time() or nil
  end

  local function load(saved)
    local engineThread = isEngineThread()
    -- Engine state owns migration. The GUI receives that current schema on
    -- every state transfer, so remigrating retained proposal graphs there is
    -- both unnecessary and increasingly expensive in a developed world.
    local needsMigration = engineThread
      or type(saved) ~= "table" or saved.version ~= stateVersion
    local nextState = needsMigration and migrate(saved) or saved
    setState(nextState)
    resetReplayWork()
    if engineThread then resetTransientRuntime(); return nextState end
    if config().networkAutoValidate then return nextState end

    local frame = tonumber(gui.frames) or 0
    local wall = wallTime()
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
    local lastWall = tonumber(gui.lastSnapshotProjectionWall)
    local periodicDue = wall and (lastWall == nil or wall < lastWall or wall - lastWall >= 3)
      or not wall and frame - (gui.lastSnapshotProjectionFrame or -1000) >= 180
    if priorityChange or periodicDue then
      gui.snapshot = publicSnapshot({ allowNativeAccounts = false })
      gui.lastSnapshotProjectionFrame = frame
      gui.lastSnapshotProjectionWall = wall
      gui.snapshotProjections = (gui.snapshotProjections or 0) + 1
      if gui.status then renderGui() end
    end
    return getState()
  end

  return { load = load }
end

return M
