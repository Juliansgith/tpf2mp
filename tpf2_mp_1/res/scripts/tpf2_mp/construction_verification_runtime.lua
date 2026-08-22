local util = require "tpf2_mp/util"

local M = {}

local COMPONENT_KINDS = {
  "construction", "station", "station_group", "depot",
  "asset", "edge_object", "node", "edge",
}

local function monotonicMicroseconds()
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

function M.new(deps)
  assert(type(deps) == "table", "construction verification dependencies are required")
  local getState = assert(deps.getState, "construction verification state is required")
  local componentEntitySet = assert(deps.componentEntitySet,
    "construction component enumerator is required")
  local componentEntityExists = deps.componentEntityExists or function(entity, componentType)
    entity = tonumber(entity)
    if not entity or entity < 0 or not componentType then return false end
    if not (api and api.engine and api.engine.getComponent) then
      return nil, "component lookup is unavailable"
    end
    local ok, value = pcall(api.engine.getComponent, entity, componentType)
    if not ok then return nil, tostring(value) end
    return value ~= nil
  end

  local function recordTiming(name, started)
    local finished = started and monotonicMicroseconds() or nil
    if not finished or finished < started then return end
    local state = getState()
    state.probes = type(state.probes) == "table" and state.probes or {}
    local replay = type(state.probes.constructionReplay) == "table"
      and state.probes.constructionReplay or { schemaVersion = 1, tasks = {} }
    state.probes.constructionReplay = replay
    replay.schemaVersion = 1
    replay.tasks = type(replay.tasks) == "table" and replay.tasks or {}
    local task = replay.tasks[name] or {
      calls = 0, totalUs = 0, lastUs = 0, maxUs = 0, averageUs = 0,
    }
    replay.tasks[name] = task
    local elapsed = math.max(0, math.floor(finished - started + 0.5))
    task.calls, task.totalUs, task.lastUs = task.calls + 1, task.totalUs + elapsed, elapsed
    task.maxUs = math.max(task.maxUs, elapsed)
    task.averageUs = math.floor(task.totalUs / task.calls + 0.5)
    task.lastTick = math.max(0, util.integer(state.tick, 0))
  end

  local function descriptors()
    local types = api and api.type and api.type.ComponentType or {}
    return {
      { kind = "construction", componentType = types.CONSTRUCTION, required = true },
      { kind = "station", componentType = types.STATION, required = true },
      { kind = "station_group", componentType = types.STATION_GROUP, required = true },
      { kind = "depot", componentType = types.VEHICLE_DEPOT, required = true },
      { kind = "asset", componentType = types.ASSET_GROUP, required = false },
      { kind = "edge_object", componentType = types.SIGNAL_LIST, required = false },
      { kind = "node", componentType = types.BASE_NODE, required = true },
      { kind = "edge", componentType = types.BASE_EDGE, required = true },
    }
  end

  local runtime = { componentKinds = COMPONENT_KINDS }

  function runtime.recordTiming(name, started)
    recordTiming(name, started)
  end

  function runtime.started()
    return monotonicMicroseconds()
  end

  function runtime.snapshot()
    local started, result = monotonicMicroseconds(), {}
    for _, descriptor in ipairs(descriptors()) do
      if not descriptor.componentType then
        if descriptor.required then
          recordTiming("component-snapshot", started)
          return nil, "construction component type is unavailable: " .. descriptor.kind
        end
        result[descriptor.kind] = {}
      else
        local set, setError = componentEntitySet(descriptor.componentType)
        if not set then
          recordTiming("component-snapshot", started)
          return nil, setError
        end
        result[descriptor.kind] = set
      end
    end
    recordTiming("component-snapshot", started)
    return result
  end

  function runtime.present(kind, localId)
    for _, descriptor in ipairs(descriptors()) do
      if descriptor.kind == kind then
        if not descriptor.componentType then return false end
        local started = monotonicMicroseconds()
        local present, presentError = componentEntityExists(localId, descriptor.componentType)
        recordTiming("targeted-component-lookup", started)
        if present == nil then return nil, presentError end
        return present == true
      end
    end
    return false
  end

  function runtime.inputsPending(localInputs)
    local counts, total = {}, 0
    for _, input in ipairs(localInputs or {}) do
      local kind, localId = tostring(input.kind or ""), tonumber(input.localId)
      if localId then
        local present, presentError = runtime.present(kind, localId)
        if present == nil then return nil, nil, presentError end
        if present then
          counts[kind], total = (counts[kind] or 0) + 1, total + 1
        end
      end
    end
    return total, counts
  end

  function runtime.delta(after, before)
    local result = {}
    for _, kind in ipairs(COMPONENT_KINDS) do
      result[kind] = util.setDifference(after and after[kind], before and before[kind])
    end
    return result
  end

  function runtime.counts(delta)
    local result = {}
    for _, kind in ipairs(COMPONENT_KINDS) do result[kind] = #(delta and delta[kind] or {}) end
    return result
  end

  function runtime.signature(added, removed)
    local parts = {}
    for _, kind in ipairs(COMPONENT_KINDS) do
      parts[#parts + 1] = kind .. "+" .. table.concat(added[kind] or {}, ",")
        .. "-" .. table.concat(removed[kind] or {}, ",")
    end
    return table.concat(parts, ":")
  end

  function runtime.captureUpgradeFingerprints(before, spec, fingerprint)
    local started, result = monotonicMicroseconds(), {}
    local rootKind = spec.kind == "asset" and "asset" or "construction"
    local needed = {
      [rootKind] = true, station = true, station_group = true,
      depot = true, asset = true,
    }
    for kind in pairs(needed) do
      result[kind] = {}
      for localId in pairs(before[kind] or {}) do
        local ok, value = pcall(fingerprint, localId, kind)
        if ok then result[kind][localId] = value end
      end
    end
    recordTiming("upgrade-fingerprint-capture", started)
    return result
  end

  return runtime
end

return M
