local util = require "tpf2_mp/util"
local safety = require "tpf2_mp/native_command_safety_registry"

local M = {}

local function revoke(tag, armed)
  if not armed then return end
  local fn = rawget(_G, "tpf2mp_native_revoke_command")
  if type(fn) == "function" then pcall(fn, tostring(tag)) end
end

function M.policy(tag) return safety.forTag(tag) end

function M.authorize(tag, required)
  local policy = safety.forTag(tag)
  if not policy or policy.visitorHook ~= true then
    return false, "native command tag " .. tostring(tag)
      .. " has no registered visitor authorization policy"
  end
  local authorize = rawget(_G, "tpf2mp_native_authorize_command")
  if type(authorize) ~= "function" then
    if required then return false, "native command authorization is unavailable" end
    return true, false
  end
  local called, accepted, err = pcall(authorize, tostring(tag))
  if not called or accepted == false then
    return false, "native command authorization failed: " .. tostring(err or accepted)
  end
  return true, true
end

function M.revoke(tag, armed) revoke(tag, armed) end

-- Issue one mod-authored native command through its exact visitor token. In
-- standalone or an unhooked test environment the API is absent and the stock
-- command remains usable. Network bootstrap independently requires the API,
-- so absence cannot silently weaken an active network match.
function M.send(tag, command, callback, label)
  local authorized, armed = M.authorize(tag)
  if not authorized then return false, armed end
  local sent, result = util.sendCommand(command, callback, label)
  if not sent then revoke(tag, armed) end
  return sent, result
end

return M
