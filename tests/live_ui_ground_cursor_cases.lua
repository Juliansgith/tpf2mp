local project = assert(arg[1]):gsub("\\", "/")
package.path = project .. "/tpf2_mp_1/res/scripts/?.lua;" .. package.path
local observer = require "tpf2_mp/live_ui_ground_cursor"
local function callable(f) return setmetatable({}, {__call = function(_, ...) return f(...) end}) end
local position = {12, -34, 5}
local renderer = {getTerrainPos = callable(function() return position end)}
local gameUi = {getMainRendererComponent = callable(function() return renderer end)}
local apiValue = {gui = {util = {getGameUI = callable(function() return gameUi end)}}}
local result = observer.read(apiValue, 17)
assert(result.world[1] == 12 and result.world[2] == -34 and result.frame == 17)
position = {x=9, y=8, z=7}
assert(observer.read(apiValue, 18).world[3] == 7)
assert(observer.read(apiValue, 2000000).frame == 2000000, "long high-FPS tests need large frame numbers")
for _, bad in ipairs({-1, 1.5, math.huge, 0/0}) do
  assert(not pcall(observer.read, apiValue, bad), "invalid frame passed")
end
for _, bad in ipairs({{}, {1, 2}, {1, 2, 0/0}, {1, 2, math.huge}}) do
  position = bad
  assert(not pcall(observer.read, apiValue, 19), "invalid cursor passed")
end
assert(not pcall(observer.read, {}, 20), "missing getter passed")
renderer.getTerrainPos = function() error("native not ready") end
assert(not pcall(observer.read, apiValue, 21), "failed native getter passed")
print("read-only ground cursor checks passed")
