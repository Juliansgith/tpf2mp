-- Read-only bounded height sampling, reachable only through the opted-in UI lab.
local M = {}
local util = require("tpf2_mp/util")
local function finite(value)
  return type(value) == "number" and value == value and math.abs(value) < math.huge
end
function M.read(spec, native)
  assert(type(spec) == "table", "terrain grid required")
  for key in pairs(spec) do assert(key == "bounds" or key == "grid", "unknown terrain field") end
  local bounds, grid = spec.bounds, spec.grid
  assert(type(bounds) == "table" and #bounds == 4, "terrain bounds must have four coordinates")
  for key, value in pairs(bounds) do
    assert(type(key) == "number" and key >= 1 and key <= 4 and key == math.floor(key)
      and finite(value) and math.abs(value) <= 99999, "invalid terrain coordinate")
  end
  assert(bounds[1] < bounds[3] and bounds[2] < bounds[4], "empty terrain bounds")
  assert(finite(grid) and grid == math.floor(grid) and grid >= 2 and grid <= 9,
    "terrain grid must be 2..9")
  assert(native and native.engine and native.engine.terrain
    and util.isCallable(native.engine.terrain.getHeightAt)
    and native.type and native.type.Vec2f and util.isCallable(native.type.Vec2f.new),
    "native terrain API unavailable")
  local result = { bounds = { bounds[1], bounds[2], bounds[3], bounds[4] }, grid = grid, heights = {} }
  for row = 0, grid - 1 do
    for col = 0, grid - 1 do
      local x = bounds[1] + (bounds[3] - bounds[1]) * col / (grid - 1)
      local y = bounds[2] + (bounds[4] - bounds[2]) * row / (grid - 1)
      local height = native.engine.terrain.getHeightAt(native.type.Vec2f.new(x, y))
      assert(finite(height), "native terrain sample unavailable")
      result.heights[#result.heights + 1] = height
    end
  end
  return result
end
return M
