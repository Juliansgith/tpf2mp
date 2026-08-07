local util = require "tpf2_mp/util"

local M = {}

local function componentById(id)
  local getById = api and api.gui and api.gui.util and api.gui.util.getById
  if not id or not util.isCallable(getById) then return nil end
  local ok, value = pcall(getById, id)
  if ok then return value end
  return nil
end

local function directLayout(id)
  local value = componentById(id)
  if value and util.isCallable(value.addItem) then return value end
  return nil
end

local function parentLayout(anchorId)
  local anchor = componentById(anchorId)
  if not anchor or not util.isCallable(anchor.getParent) then return nil end
  local parentOk, parent = pcall(anchor.getParent, anchor)
  if not parentOk or not parent or not util.isCallable(parent.getLayout) then return nil end
  local layoutOk, layout = pcall(parent.getLayout, parent)
  if layoutOk and layout and util.isCallable(layout.addItem) then return layout end
  return nil
end

local function addEntry(options, showWindow)
  if componentById(options.componentId) then return true end
  local layout = directLayout(options.layoutId) or parentLayout(options.anchorId)
  if not layout then return false end
  local guiComp = api and api.gui and api.gui.comp
  if not (guiComp and guiComp.Button and guiComp.TextView
      and util.isCallable(guiComp.Button.new) and util.isCallable(guiComp.TextView.new)) then
    return false
  end
  local created, button = pcall(
    guiComp.Button.new, guiComp.TextView.new(options.label), true)
  if not created or not button or not util.isCallable(button.setId)
      or not util.isCallable(button.onClick) then return false end
  local identified = pcall(button.setId, button, options.componentId)
  if not identified then return false end
  button:onClick(showWindow)
  return pcall(layout.addItem, layout, button)
end

function M.install(guiState, showWindow)
  assert(type(guiState) == "table", "GUI state is required")
  assert(type(showWindow) == "function", "show-window callback is required")
  if guiState.entryPointsInstalled then return true end
  local hud = addEntry({
    layoutId = "gameInfo.layout", componentId = "tpf2mp.hudEntry", label = "MULTIPLAYER",
  }, showWindow)
  local pause = addEntry({
    anchorId = "ingameMenu.quitButton", componentId = "tpf2mp.pauseEntry", label = "Multiplayer",
  }, showWindow)
  guiState.entryPointStatus = { hud = hud, pause = pause }
  -- Keep retrying until both surfaces exist. The pause menu is constructed
  -- lazily on some UI layouts; component-id checks make retries idempotent.
  guiState.entryPointsInstalled = hud and pause
  return hud or pause
end

return M
