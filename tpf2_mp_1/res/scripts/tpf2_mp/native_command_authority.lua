local util = require "tpf2_mp/util"

local M = {}

local function revoke(tag, armed)
  if not armed then return end
  local fn = rawget(_G, "tpf2mp_native_revoke_command")
  if type(fn) == "function" then pcall(fn, tostring(tag)) end
end

-- Issue one mod-authored native command through its exact visitor token. In
-- standalone or an unhooked test environment the API is absent and the stock
-- command remains usable. Network bootstrap independently requires the API,
-- so absence cannot silently weaken an active network match.
function M.send(tag, command, callback, label)
  local authorize = rawget(_G, "tpf2mp_native_authorize_command")
  local armed = false
  if type(authorize) == "function" then
    local called, accepted, err = pcall(authorize, tostring(tag))
    if not called or accepted == false then
      return false, "native command authorization failed: " .. tostring(err or accepted)
    end
    armed = true
  end
  local sent, result = util.sendCommand(command, callback, label)
  if not sent then revoke(tag, armed) end
  return sent, result
end

return M
