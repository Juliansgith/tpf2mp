local M = {}

local EXPLICIT_SPEED_IDS = {
  ["menu.speedButton0"] = true,
  ["menu.speedButton1"] = true,
  ["menu.speedButton2"] = true,
  ["menu.speedButton3"] = true,
}

local function operationalSource(id)
  local source = string.lower(tostring(id or ""))
  return source:find("linemanager", 1, true) ~= nil
    or source:find("lineeditor", 1, true) ~= nil
    or source:find("vehiclemanager", 1, true) ~= nil
    or source:find("depot", 1, true) ~= nil
end

function M.new(gui, deps)
  assert(type(gui) == "table", "GUI clock capture policy requires GUI state")
  deps = type(deps) == "table" and deps or {}
  local pauseMenuVisible = deps.pauseMenuVisible or function()
    if not (api and api.gui and api.gui.util
      and type(api.gui.util.getById) == "function") then return false end
    local ok, component = pcall(api.gui.util.getById, "menuUI")
    if not ok or not component or type(component.isVisible) ~= "function" then return false end
    local visibleOk, visible = pcall(component.isVisible, component)
    return visibleOk and visible == true
  end
  local transitionWindow = math.max(1, tonumber(deps.transitionWindowFrames) or 12)

  local policy = {}

  function policy.observeEvent(id, name)
    local frame = math.max(0, tonumber(gui.frames) or 0)
    if EXPLICIT_SPEED_IDS[tostring(id or "")]
      and tostring(name or ""):find("click", 1, true) then
      gui.nativeClockCapture.lastExplicitSpeedFrame = frame
      return "explicit-speed"
    end
    if operationalSource(id) then
      gui.nativeClockCapture.lastOperationalModalFrame = frame
      gui.nativeClockCapture.lastOperationalModalSource = tostring(id or "")
      return "operational-modal"
    end
    return nil
  end

  function policy.observeEntitySelection(kind)
    local selected = string.lower(tostring(kind or ""))
    if selected ~= "line" and selected ~= "vehicle" and selected ~= "depot" then
      return false
    end
    gui.nativeClockCapture.lastOperationalModalFrame =
      math.max(0, tonumber(gui.frames) or 0)
    gui.nativeClockCapture.lastOperationalModalSource = "mainView:" .. selected
    return true
  end

  function policy.ignoreCapturedPause(speed)
    if tonumber(speed) ~= 0 then return false end
    local frame = math.max(0, tonumber(gui.frames) or 0)
    local explicitFrame = tonumber(gui.nativeClockCapture.lastExplicitSpeedFrame)
    if explicitFrame and frame - explicitFrame <= transitionWindow then return false end
    local visibleOk, visible = pcall(pauseMenuVisible)
    if visibleOk and visible == true then return false end
    local modalFrame = tonumber(gui.nativeClockCapture.lastOperationalModalFrame)
    if not modalFrame or frame - modalFrame < 0
      or frame - modalFrame > transitionWindow then return false end
    gui.nativeClockCapture.modalPausesIgnored =
      (gui.nativeClockCapture.modalPausesIgnored or 0) + 1
    gui.nativeClockCapture.lastIgnoredModalPauseFrame = frame
    return true, tostring(gui.nativeClockCapture.lastOperationalModalSource or "manager")
  end

  return policy
end

return M
