-- Standalone regression: run with faithful Lua 5.1 and repository root arg.
local root = assert(arg[1]):gsub("\\", "/")
package.path = root .. "/tpf2_mp_1/res/scripts/?.lua;" .. package.path
local performance = require "tpf2_mp/performance_runtime"
local state = { tick = 0, probes = {} }
local runtime = performance.new({ getState = function() return state end })
local previousClock = rawget(_G, "tpf2mp_native_monotonic_us")
local clock, reading, sample = 0, false, 0
local history = {}
tpf2mp_native_monotonic_us = function()
  reading = not reading
  if reading then return clock end
  sample = sample + 1
  local elapsed = (sample * 71) % 997
  clock = clock + elapsed
  history[#history + 1] = elapsed
  if #history > 128 then table.remove(history, 1) end
  return clock
end
local originalSort, sortCount = table.sort, 0
table.sort = function(values, compare)
  sortCount = sortCount + 1
  return originalSort(values, compare)
end
local checks, expectedSorts = 0, 0
for pass = 1, 2 do
  for call = 1, 4096 do
    local ok, a, b, c = runtime.run("window", function() return 1, nil, 3 end)
    assert(ok and a == 1 and b == nil and c == 3)
    local task = state.probes.performance.tasks.window
    local measured = call <= 4 or call % 8 == 0
    if measured and (task.measuredCalls <= 4 or task.measuredCalls % 16 == 0) then
      local ordered = {}
      for i, value in ipairs(history) do ordered[i] = value end
      originalSort(ordered)
      assert(task.p50Us == ordered[math.ceil(#ordered / 2)])
      assert(task.p95Us == ordered[math.ceil(#ordered * 95 / 100)])
      assert(task.sampleCount == #ordered)
      expectedSorts = expectedSorts + 1
      checks = checks + 1
    end
  end
  runtime.reset()
  history, sample = {}, 0
end
-- Loading persisted counters must not create holes in a fresh local window.
local persisted = { tick = 0, probes = { performance = { tasks = { window = {
  calls = 31, measuredCalls = 15, failures = 0, totalUs = 0, maxUs = 0,
} } } } }
local resumed = performance.new({ getState = function() return persisted end })
assert(resumed.run("window", function() end))
local resumedTask = persisted.probes.performance.tasks.window
assert(resumedTask.sampleCount == 1 and resumedTask.p50Us == 71)
expectedSorts = expectedSorts + 1
table.sort = originalSort
tpf2mp_native_monotonic_us = previousClock
assert(sortCount == expectedSorts, "percentile refresh must sort only once")
print("PASS rolling-window equivalence, reset, nil return forwarding: " .. checks .. " refreshes")
