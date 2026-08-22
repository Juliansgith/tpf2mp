local M = {}

function M.needsUpdate(state, pending)
  local scheduler = state.economy and state.economy.scheduler or {}
  if state.initialized ~= true or not state.match
    or state.match.status ~= "running" or scheduler.automatic ~= true then
    return false
  end
  if state.networkMode == "network" and state.bridge.peerId ~= "player1" then
    return false
  end
  if state.networkMode == "network"
    and (not state.bridge.companion or state.bridge.companion.connected ~= true) then
    return pending ~= nil
  end
  return true
end

return M
