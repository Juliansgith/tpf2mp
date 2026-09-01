local M = {}

local function environment(readEnvironment, name)
  local ok, value = pcall(readEnvironment, name)
  return ok and value or nil
end

-- A base-game overlay is an implementation detail of an exact launcher run,
-- not a second installation mechanism. Keep activation small, immutable and
-- independently testable so the 3,000-line game-script entry point cannot run
-- merely because a prior process crashed before cleaning its copied files.
function M.explicit(options)
  options = type(options) == "table" and options or {}
  local configured = options.config
  if configured == nil then
    configured = game and game.config and game.config.tpf2mp
  end
  if type(configured) == "table"
      and (configured.protocolVersion ~= nil or configured.minorVersion ~= nil) then
    return true, "selected-mod"
  end

  local readEnvironment = options.environment
    or (os and os.getenv)
  if type(readEnvironment) ~= "function" then return false, "no-environment" end
  local peer = environment(readEnvironment, "TPF2MP_PEER_ID")
  local session = environment(readEnvironment, "TPF2MP_SESSION_ID")
  local bridgeRoot = environment(readEnvironment, "TPF2MP_BRIDGE_DIR")
  if (peer == "player1" or peer == "player2")
      and type(session) == "string" and session:match("^[%w][%w_.%-]*$")
      and #session <= 64
      and type(bridgeRoot) == "string" and bridgeRoot ~= "" then
    return true, "launcher-environment"
  end

  local open = options.open or (io and io.open)
  local temp = environment(readEnvironment, "TEMP")
  if type(open) == "function" and type(temp) == "string" and temp ~= "" then
    local marker = open(temp .. "/tpf2mp_bridge/auto-live/enable", "rb")
    if marker then marker:close(); return true, "validator-marker" end
  end
  return false, "not-requested"
end

return M
