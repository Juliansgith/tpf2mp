local M = {}

local function mainView()
  local getter = api and api.gui and api.gui.util and api.gui.util.getById
  if type(getter) ~= "function" then return nil end
  local ok, view = pcall(getter, "mainView")
  return ok and view or nil
end

local function setEnabled(enabled)
  local view, modernError = mainView(), nil
  if view and type(view.setEnabled) == "function" then
    local ok, err = pcall(view.setEnabled, view, enabled)
    if ok then return true end
    modernError = err
  end
  if game and game.gui and type(game.gui.setEnabled) == "function" then
    local ok, err = pcall(game.gui.setEnabled, "mainView", enabled)
    if ok then return true end
    return nil, err
  end
  return nil, modernError or "main-view interaction API is unavailable"
end

function M.suspend(value)
  local view, priorEnabled = mainView(), true
  if view and type(view.isEnabled) == "function" then
    local ok, enabled = pcall(view.isEnabled, view)
    if ok then priorEnabled = enabled == true end
  end
  local suspended, err = setEnabled(false)
  if not suspended then return nil, err end
  value.selectorSuspended, value.selectorWasEnabled = true, priorEnabled
  return true
end

function M.release(value)
  if not (value and value.selectorSuspended) then return false end
  local restored, err = setEnabled(value.selectorWasEnabled ~= false)
  if not restored then return nil, err end
  value.selectorSuspended = false
  return true
end

function M.update(value, frame)
  if value and value.selectorReleaseFrame
    and (tonumber(frame) or 0) >= value.selectorReleaseFrame then return M.release(value) end
  return false
end

return M
