return function()
  local read = require("tpf2_mp/live_ui_terrain_observer").read
  local count = 0
  local fake = { type = { Vec2f = { new = function(x, y) return { x = x, y = y } end } },
    engine = { terrain = { getHeightAt = function(v)
      count = count + 1; return v.x + v.y
    end } } }
  local good = { bounds = { 0, 0, 10, 20 }, grid = 2 }
  local result = read(good, fake)
  assert(count == 4 and result.grid == 2 and #result.heights == 4)
  assert(result.heights[1] == 0 and result.heights[2] == 10
    and result.heights[3] == 20 and result.heights[4] == 30)
  result.bounds[1] = 999
  assert(good.bounds[1] == 0, "readback must not mutate request")
  assert(not pcall(read, { bounds = { 0, 0, 10, 20 }, grid = 10 }, fake))
  assert(not pcall(read, { bounds = { 0, 0, 10, 20 }, grid = 2, inject = true }, fake))
  assert(not pcall(read, { bounds = { 0, 0, 0, 20 }, grid = 2 }, fake))
  assert(not pcall(read, { bounds = { 0, 0, 0/0, 20 }, grid = 2 }, fake))
  assert(not pcall(read, { bounds = { 0, 0, 10, 20, 30 }, grid = 2 }, fake))
  assert(count == 4, "invalid requests must never call native getters")
  for _, broken in ipairs({ function() return nil end, function() return 0/0 end,
      function() error("native read failed") end, function() return true end }) do
    fake.engine.terrain.getHeightAt = broken
    assert(not pcall(read, good, fake), "partial terrain cannot claim success")
  end
  assert(not pcall(read, good, {}), "unavailable native API is not flat terrain")
end
