-- Backend observation only. The lab DLL schedules generation; this script
-- never opens menus, clicks controls, loads or overwrites a personal save.
function data()
  local output = os.getenv('TPF2MP_WORLDGEN_LAB_LUA_MARKER')
  local began, last, readyAt, stopping, stoppedAt = os.time(), 0, nil, false, nil
  local saveName = os.getenv('TPF2MP_WORLDGEN_LAB_SAVE')
  local nativeOutput = os.getenv('TPF2MP_WORLDGEN_LAB_MARKER')
  local function emit(event)
    local f = assert(io.open(output, 'a'))
    f:write(event .. '\n'); f:close()
  end
  return { update = function()
    local now = os.time()
    if now == last then return end
    last = now
    if not readyAt and game and game.interface and
        type(game.interface.getGameTime) == 'function' then
      local ok, value = pcall(game.interface.getGameTime)
      if ok and value then
        readyAt = now
        emit('world-ready')
        emit('native-time=' .. tostring(value.time))
        local cfg = game.config and game.config.tpf2mp
        if cfg then
          emit('runtime-agentMode=' .. tostring(cfg.agentMode))
          emit('runtime-economyDifficulty=' .. tostring(cfg.economyDifficulty))
          emit('runtime-townDevelopment=' .. tostring(cfg.townDevelopment))
        end
        if game.interface.setGameSpeed then game.interface.setGameSpeed(0) end
      end
    end
    local saved = not saveName or saveName == ''
    if not saved and readyAt then
      local f = io.open(nativeOutput, 'r')
      if f then local text = f:read('*a'); f:close(); saved = text:find('native%-save%-idle') ~= nil end
    end
    if readyAt and now - readyAt > 5 and not stopping and
        saved then
      stopping = true; stoppedAt = now; emit('stop-request'); app.stopGame(); return
    end
    if stopping and now - stoppedAt > 5 then emit('quit-request'); app.quit() end
    if now - began > 600 then emit('timeout'); app.quit() end
  end, handleEvent = function(_, name)
    emit('native-event=' .. tostring(name))
  end }
end
