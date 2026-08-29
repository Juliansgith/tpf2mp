local util = require "tpf2_mp/util"

local M = {}

function M.normalise(action)
  if type(action) ~= "table" then return nil, "recovery action must be a table" end
  if action.type == "recovery.prepare" then
    for key in pairs(action) do
      if key ~= "type" and key ~= "automatic" then
        return nil, "recovery.prepare has an unknown field: " .. tostring(key)
      end
    end
    if action.automatic ~= nil and action.automatic ~= true then
      return nil, "recovery.prepare automatic marker is invalid"
    end
    return { type = "recovery.prepare", automatic = action.automatic == true or nil }
  end
  if action.type == "recovery.cancel" then
    local preparationSeq = util.integer(action.preparationSeq, 0)
    local errorCode = tostring(action.errorCode or "")
    if preparationSeq < 1 or errorCode == "" or #errorCode > 512 then
      return nil, "recovery.cancel is malformed"
    end
    for key in pairs(action) do
      if key ~= "type" and key ~= "preparationSeq" and key ~= "errorCode" then
        return nil, "recovery.cancel has an unknown field: " .. tostring(key)
      end
    end
    return {
      type = "recovery.cancel", preparationSeq = preparationSeq, errorCode = errorCode,
    }
  end
  return nil, "unsupported recovery action"
end

return M
