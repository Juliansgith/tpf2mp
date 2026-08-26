local util = require "tpf2_mp/util"

local M = {}

local function readField(proposal, field)
  local ok, value = pcall(function() return proposal[field] end)
  return ok and value or nil
end

function M.read(proposal)
  for _, field in ipairs({ "constructionsToRemove", "toRemove" }) do
    local value = readField(proposal, field)
    if value ~= nil then return field, value end
  end
  return nil, nil
end

local function verify(removals, expected)
  if removals == nil then return nil, "construction removal vector is unavailable" end
  local lengthOk, length = pcall(function() return #removals end)
  if not lengthOk or tonumber(length) ~= #expected then
    return nil, "construction removal vector length did not round-trip"
  end
  for index, entity in ipairs(expected) do
    local readOk, observed = pcall(function() return removals[index] end)
    if not readOk or tonumber(observed) ~= entity then
      return nil, "construction removal entity did not round-trip at index " .. tostring(index)
    end
  end
  return true
end

function M.assign(proposal, field, initial, expected)
  -- Generated C++ vectors can accept an indexed write without invoking their
  -- Lua table converter. Prefer the whole-vector setter and verify native data.
  local wholeOk = pcall(function() proposal[field] = util.deepCopy(expected) end)
  if wholeOk then
    local current = readField(proposal, field)
    if verify(current, expected) then return current, "whole-vector" end
  end
  local removals = readField(proposal, field) or initial
  for index, entity in ipairs(expected) do
    local assigned, assignError = pcall(function() removals[index] = entity end)
    if not assigned then
      return nil, "construction removal assignment failed: " .. tostring(assignError)
    end
  end
  local verified, verifyError = verify(removals, expected)
  if not verified then return nil, verifyError end
  return removals, "indexed-vector"
end

return M
