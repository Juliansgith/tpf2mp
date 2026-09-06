-- Invoked with the native-callable reader fix after the pinned running batch.
return function()
  local read = require("tpf2_mp/live_ui_terrain_observer").read
  local function callable(fn)
    local proxy = newproxy(true)
    getmetatable(proxy).__call = function(_, ...) return fn(...) end
    return proxy
  end
  local fake = { type = { Vec2f = { new = callable(function(x, y) return { x = x, y = y } end) } },
    engine = { terrain = { getHeightAt = callable(function(v) return v.x + v.y end) } } }
  local good = { bounds = { 0, 0, 10, 20 }, grid = 2 }
  assert(read(good, fake).heights[4] == 30, "native callable wrappers must be accepted")
end
