-- Native --script entry point; follows the game's shipped autotest/test.lua.
-- Diagnostic only: no multiplayer bootstrap, physical input or save writes.
function data()
  local stem = os.getenv('TPF2MP_BENCH_SAVE_STEM')
  local duration = tonumber(os.getenv('TPF2MP_BENCH_SECONDS')) or 60
  local token = os.getenv('TPF2MP_BENCH_RUN_TOKEN') or 'manual'
  local workload = os.getenv('TPF2MP_BENCH_WORKLOAD') or 'steady'
  local markerPath = os.getenv('TPF2MP_BENCH_MARKER_PATH')
  local phaseName, phaseIndex = 'steady', 0
  local phases = { { 'paused', 0 }, { 'speed1', 1 }, { 'speed4', 4 },
    { 'paused-repeat', 0 }, { 'camera', 0 }, { 'speed1-repeat', 1 } }
  if not stem or not stem:match('^[%w_-]+$') or duration < 5 or duration > 300 then
    return { update = function() end }
  end
  local began, frames, last, readyAt = os.time(), 0, -1, nil
  local requested, loaded, stopped, quitting = false, false, false, false
  local function emit(event)
    local speed, time = 'unavailable', 'unavailable'
    if game and game.interface then
      if type(game.interface.getGameSpeed) == 'function' then
        local ok, value = pcall(game.interface.getGameSpeed)
        if ok then speed = tostring(value) end
      end
      if type(game.interface.getGameTime) == 'function' then
        local ok, value = pcall(game.interface.getGameTime)
        if ok and value then time = tostring(value.time) end
      end
    end
    local message = '[NATIVE-BENCH] event=' .. event .. ' elapsed=' .. (os.time()-began)
      .. ' callbacks=' .. frames .. ' speed=' .. speed .. ' gameTime=' .. time
      .. ' atEpoch=' .. os.time() .. ' token=' .. token
    print(message)
    if markerPath then
      local file = assert(io.open(markerPath, 'a'), 'cannot retain benchmark markers')
      file:write(message .. '\n'); file:close()
    end
  end
  local function speed(value)
    if game.interface.setGameSpeed then return game.interface.setGameSpeed(value) end
    return api.cmd.sendCommand(api.cmd.make.setGameSpeed(value))
  end
  return {
    update = function()
      frames = frames + 1
      local now = os.time()
      if now == last then return end
      last = now
      local menu = api.gui.util.getById('menuUI')
      local atMenu = menu ~= nil and menu:isVisible()
      if atMenu and not requested and now - began >= 10 then
        requested = true -- Set before call to fence callback re-entry.
        emit('load-request')
        -- This API takes a save identifier WITHOUT the .sav extension.
        loaded = app.loadGame(stem) == true
        emit(loaded and 'load-accepted' or 'load-rejected')
        if not loaded then app.quit() end
        return
      end
      -- The in-game GUI exists one callback before the script interface is ready.
      -- Do not consume the one-shot speed request in that intermediate state.
      local interfaceReady = game and game.interface
        and type(game.interface.getGameSpeed) == 'function'
      if loaded and not atMenu and api.gui.util.getById('ingameMenu')
          and interfaceReady and not readyAt then
        readyAt = now
        -- Pin the benchmark copy, not the saved world, to normal simulation speed.
        if game and game.interface and type(game.interface.setGameSpeed) == 'function' then
          local ok, err = pcall(game.interface.setGameSpeed, 1)
          emit(ok and 'speed-requested' or 'speed-request-failed-' .. tostring(err))
        elseif api.cmd and api.cmd.make and api.cmd.make.setGameSpeed ~= nil then
          -- Native factories can be callable tables/userdata, not just functions.
          local ok, err = pcall(function()
            api.cmd.sendCommand(api.cmd.make.setGameSpeed(1))
          end)
          emit(ok and 'speed-requested' or 'speed-request-failed-' .. tostring(err))
        else
          emit('speed-control-unavailable')
        end
        emit('world-ready')
      end
      if readyAt and not stopped then
        if workload == 'scaling' then
          local index = math.min(#phases, math.floor((now - readyAt) / (duration / #phases)) + 1)
          if index ~= phaseIndex then
            phaseIndex, phaseName = index, phases[index][1]
            local ok = pcall(speed, phases[index][2])
            emit(ok and ('phase-' .. phaseName) or ('phase-failed-' .. phaseName))
          end
          if phaseName == 'camera' then
            -- Engine camera API, not OS mouse/keyboard input. One deterministic
            -- view change per second; this is not a smooth-motion FPS benchmark.
            local ok = pcall(function()
              api.gui.util.getById('mainView'):getCameraController():setCameraData(
                api.type.Vec2f.new(-1800 + ((now-readyAt) % 10) * 100, -1000), 650, 0, 0.82)
            end)
            if not ok then emit('camera-failed') end
          end
        end
        emit('phase-sample-' .. phaseName)
        emit('sample')
        if now - readyAt >= duration then
          stopped = true
          emit('stop-request')
          app.stopGame()
        end
      elseif stopped and atMenu and not quitting then
        quitting = true
        emit('quit-request')
        app.quit()
      end
    end,
    handleEvent = function(id, name)
      if name == 'ready' then emit('native-ready-event') end
    end,
  }
end
