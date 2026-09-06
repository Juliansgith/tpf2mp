-- Read-only terrain cursor evidence for physical mouse targeting. No input,
-- camera, entity or proposal mutation; called only by the gated test observer.
local util = require "tpf2_mp/util"
local M = {}
local function invoke(object, name, ...)
  local ok, method = pcall(function() return object and object[name] end)
  if not ok or not util.isCallable(method) then return nil end
  local success, value = pcall(method, object, ...)
  return success and value or nil
end
local function finite(value)
  return type(value) == "number" and value == value and math.abs(value) < 1000000
end
function M.read(apiValue, frame)
  local helpers = apiValue and apiValue.gui and apiValue.gui.util
  assert(helpers and util.isCallable(helpers.getGameUI), "native GameUI getter unavailable")
  local gameUi = helpers.getGameUI()
  local renderer = assert(invoke(gameUi, "getMainRendererComponent"), "main renderer unavailable")
  local position = assert(invoke(renderer, "getTerrainPos"), "terrain cursor unavailable")
  local result = {}
  for index, key in ipairs({"x", "y", "z"}) do
    local ok, value = pcall(function() return position[key] end)
    if not ok or value == nil then
      ok, value = pcall(function() return position[index] end)
    end
    assert(ok and finite(value), "nonfinite or incomplete terrain cursor")
    result[index] = value
  end
  assert(type(frame) == "number" and frame >= 0 and frame < 9007199254740992
    and frame == math.floor(frame), "GUI frame unavailable")
  return { world = result, frame = frame }
end
return M
