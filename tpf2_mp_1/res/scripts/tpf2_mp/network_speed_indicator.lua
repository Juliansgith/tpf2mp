local M = {}

local BUTTON_IDS = {
  "menu.speedButton0",
  "menu.speedButton1",
  "menu.speedButton2",
  "menu.speedButton3",
}
local INSPECTION_STRIDE_FRAMES = 30

-- Transport Fever 2 exposes three running-speed buttons.  The fastest stock
-- button is native speed 4; native speed 3 is a valid adaptive cap but shares
-- that same visual button.
local function buttonIndex(speed)
  speed = tonumber(speed)
  if not speed or speed < 0 or speed > 4 then return nil end
  if speed >= 3 then return 3 end
  return math.floor(speed)
end

function M.new(deps)
  assert(type(deps) == "table", "network speed-indicator dependencies are required")
  local getState = assert(deps.getState, "getState dependency is required")
  local getById = deps.getById or function(id)
    return api.gui.util.getById(id)
  end
  local wakeClock = deps.wakeClock or function() end
  local wallTime = deps.wallTime or function()
    return os and type(os.time) == "function" and os.time() or nil
  end
  local stats = {
    frames = 0,
    repairs = 0,
    pauseWakeups = 0,
    missingButtons = 0,
    lastEffectiveSpeed = nil,
    lastButtonIndex = nil,
    lastPauseWakeWall = nil,
    lastPauseWakeFrame = -1000,
    lastError = nil,
  }

  local function project()
    local state = getState()
    if state.networkMode ~= "network" or state.initialized ~= true then return false end
    local clock = state.world and state.world.networkClock or nil
    local wanted = buttonIndex(clock and clock.effectiveSpeed)
    if wanted == nil then return false end
    stats.frames = stats.frames + 1
    local changed = stats.lastEffectiveSpeed ~= tonumber(clock.effectiveSpeed)
    if not changed and stats.frames % INSPECTION_STRIDE_FRAMES ~= 1 then return false end
    stats.lastEffectiveSpeed = tonumber(clock.effectiveSpeed)
    stats.lastButtonIndex = wanted
    stats.lastError = nil
    local repaired, pauseWasSelected = false, false
    for index, id in ipairs(BUTTON_IDS) do
      local buttonIndexZero = index - 1
      local found, button = pcall(getById, id)
      if not found or not button then
        stats.missingButtons = stats.missingButtons + 1
      else
        local selectedOk, selected = pcall(function() return button:isSelected() end)
        if buttonIndexZero == 0 and selectedOk and selected == true then
          pauseWasSelected = true
        end
        local shouldSelect = buttonIndexZero == wanted
        if not selectedOk or selected ~= shouldSelect then
          local setOk, setError = pcall(function()
            -- Never emit a click: this is a projection of ordered authority,
            -- not a new player speed request.
            button:setSelected(shouldSelect, false)
          end)
          if setOk then
            stats.repairs = stats.repairs + 1
            repaired = true
          else
            stats.lastError = tostring(setError)
          end
        end
      end
    end
    if wanted > 0 and pauseWasSelected then
      local wall = wallTime()
      local due = wall and wall ~= stats.lastPauseWakeWall
        or not wall and stats.frames - stats.lastPauseWakeFrame >= 30
      if due then
        stats.pauseWakeups = stats.pauseWakeups + 1
        stats.lastPauseWakeWall = wall
        stats.lastPauseWakeFrame = stats.frames
        pcall(wakeClock)
      end
    end
    return repaired
  end

  return {
    project = project,
    status = function() return stats end,
    buttonIndex = buttonIndex,
  }
end

return M
