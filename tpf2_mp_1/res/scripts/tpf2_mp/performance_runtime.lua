local util = require "tpf2_mp/util"

local M = {}
local SAMPLE_LIMIT = 128

local function pack(...)
  return { n = select("#", ...), ... }
end

-- Build 35924 does not expose Lua's global unpack in every game-script state.
-- Indexing the packed Lua table ourselves also avoids the engine's
-- userdata-unsafe unpack implementation when a measured call returns native
-- values.
local function unpackValues(values, first, last)
  local index = first or 1
  local final = last or values.n or #values
  if index > final then return end
  return values[index], unpackValues(values, index + 1, final)
end

local function nowMicroseconds()
  local native = rawget(_G, "tpf2mp_native_monotonic_us")
  if type(native) == "function" then
    local called, value = pcall(native)
    value = called and tonumber(value) or nil
    if value and value >= 0 then return value end
  end
  if os and type(os.clock) == "function" then
    local called, value = pcall(os.clock)
    if called and tonumber(value) then return tonumber(value) * 1000000 end
  end
  return nil
end

local function percentile(values, numerator, denominator)
  if #values == 0 then return 0 end
  local copy = {}
  for index, value in ipairs(values) do copy[index] = value end
  table.sort(copy)
  local position = math.max(1, math.ceil(#copy * numerator / denominator))
  return copy[position]
end

function M.new(deps)
  assert(type(deps) == "table" and type(deps.getState) == "function",
    "performance runtime state provider is required")
  local getState = deps.getState
  local samples, lastTicks = {}, {}

  local function probe()
    local state = getState()
    state.probes.performance = type(state.probes.performance) == "table"
      and state.probes.performance or { schemaVersion = 1, tasks = {}, scheduler = {} }
    local result = state.probes.performance
    result.schemaVersion = 1
    result.tasks = type(result.tasks) == "table" and result.tasks or {}
    result.scheduler = type(result.scheduler) == "table" and result.scheduler or {}
    return result
  end

  local runtime = {}

  function runtime.due(name, stride, force)
    local state, interval = getState(), math.max(1, util.integer(stride, 1))
    local tick = math.max(0, util.integer(state.tick, 0))
    local previous = lastTicks[name]
    local due = force == true or previous == nil or tick < previous or tick - previous >= interval
    local scheduler = probe().scheduler
    scheduler[name] = scheduler[name] or { calls = 0, runs = 0, skipped = 0, stride = interval }
    local item = scheduler[name]
    item.calls, item.stride = item.calls + 1, interval
    if due then
      lastTicks[name] = tick
      item.runs, item.lastTick = item.runs + 1, tick
    else item.skipped = item.skipped + 1 end
    return due
  end

  function runtime.run(name, callable, ...)
    assert(type(callable) == "function", "measured task must be callable")
    local arguments, started = pack(...), nowMicroseconds()
    local outcome = pack(xpcall(function()
      return callable(unpackValues(arguments, 1, arguments.n))
    end, debug.traceback))
    local finished = nowMicroseconds()
    local task = probe().tasks[name] or {
      calls = 0, failures = 0, totalUs = 0, lastUs = 0, maxUs = 0,
      p50Us = 0, p95Us = 0,
    }
    probe().tasks[name] = task
    task.calls = task.calls + 1
    if outcome[1] ~= true then task.failures = task.failures + 1 end
    if started and finished and finished >= started then
      local elapsed = math.floor(finished - started + 0.5)
      task.lastUs = elapsed
      task.totalUs = task.totalUs + elapsed
      task.maxUs = math.max(task.maxUs, elapsed)
      task.averageUs = math.floor(task.totalUs / task.calls + 0.5)
      samples[name] = samples[name] or {}
      local values = samples[name]
      values[#values + 1] = elapsed
      if #values > SAMPLE_LIMIT then table.remove(values, 1) end
      if task.calls <= 4 or task.calls % 16 == 0 then
        task.p50Us = percentile(values, 1, 2)
        task.p95Us = percentile(values, 95, 100)
        task.sampleCount = #values
      end
    end
    return unpackValues(outcome, 1, outcome.n)
  end

  function runtime.setNativeBridge(status)
    local value = type(status) == "table" and util.deepCopy(status) or {}
    value.sampleTick = math.max(0, util.integer(getState().tick, 0))
    probe().nativeBridge = value
  end

  function runtime.reset()
    samples, lastTicks = {}, {}
    getState().probes.performance = { schemaVersion = 1, tasks = {}, scheduler = {} }
  end

  return runtime
end

return M
