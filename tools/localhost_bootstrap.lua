-- Console-state bootstrap used only by the disposable two-process localhost
-- harness. The launcher copies this into base res/scripts for the duration of
-- a run and uses it to prove each menu process received its peer-specific
-- environment. Starting a game from this update callback is unsafe because it
-- re-enters Build 35924's UI renderer, so the launcher issues app.startGame()
-- through the ordinary game console after both native hooks are installed.
-- No game is saved by this script.
function data()
  local peer = os.getenv("TPF2MP_PEER_ID") or "unknown"
  local session = os.getenv("TPF2MP_SESSION_ID") or "unknown"
  local root = (os.getenv("TPF2MP_BRIDGE_DIR") or "."):gsub("\\", "/"):gsub("/+$", "")
  local frames = 0
  local started = false
  local stopping = false
  local quitRequested = false
  local lastStage = nil

  local function exists(path)
    local file = io.open(path, "rb")
    if not file then return false end
    file:close()
    return true
  end

  local function menuVisible()
    local ok, menu = pcall(api.gui.util.getById, "menuUI")
    if not ok or not menu then return false end
    local visibleOk, visible = pcall(function() return menu:isVisible() end)
    return visibleOk and visible == true
  end

  local function publish(stage)
    if stage == lastStage and frames % 120 ~= 0 then return end
    lastStage = stage
    local file = io.open(root .. "/launcher/game_bootstrap.json", "wb")
    if not file then return end
    file:write(string.format(
      '{"schemaVersion":1,"peer":"%s","session":"%s","stage":"%s","frames":%d}\n',
      peer, session, stage, frames
    ))
    file:close()
  end

  return {
    update = function()
      frames = frames + 1
      local atMenu = menuVisible()
      if exists(root .. "/launcher/stop") then stopping = true end

      if stopping then
        if atMenu then
          if not quitRequested then
            quitRequested = true
            publish("quit-application")
            app.quit()
          end
        else
          publish("stop-game")
          app.stopGame()
        end
        return
      end

      if not started then
        publish("waiting-for-launcher")
        if exists(root .. "/launcher/start") then
          started = true
          publish("launcher-released")
        end
        return
      end

      publish(atMenu and "ready-for-console-start" or "in-game")
    end,

    handleEvent = function(id, name, param)
      publish("event-" .. tostring(name or id or "unknown"))
    end,
  }
end
