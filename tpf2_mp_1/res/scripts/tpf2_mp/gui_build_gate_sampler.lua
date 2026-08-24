local M = {}

local function nonNegativeInteger(value)
  local number = tonumber(value)
  if not number or number < 0 or number ~= math.floor(number) then return nil end
  return number
end

function M.new(fullStatus)
  assert(type(fullStatus) == "function", "full native-status fallback is required")
  local fastFunction, takeFunction
  local stats = {
    fastSamples = 0, fallbackSamples = 0, invalidSamples = 0,
    eventReads = 0, events = 0, legacySamples = 0,
  }

  local function fastSample()
    if type(fastFunction) ~= "function" then
      fastFunction = rawget(_G, "tpf2mp_native_build_gate_sample")
    end
    if type(fastFunction) ~= "function" then return nil, "unavailable" end
    local called, raw = pcall(fastFunction)
    if not called then
      stats.invalidSamples = stats.invalidSamples + 1
      return false, tostring(raw)
    end
    local version, enabled, suppressed, mismatches, generation, queued, dropped, armed
    if type(raw) == "string" then
      enabled, suppressed, mismatches, generation, queued, dropped, armed =
        raw:match("^B2|([01])|(%d+)|(%d+)|(%d+)|(%d+)|(%d+)|(%d+)$")
      if enabled then version = 2 else
        enabled, suppressed, mismatches = raw:match("^B1|([01])|(%d+)|(%d+)$")
        if enabled then version = 1; stats.legacySamples = stats.legacySamples + 1 end
      end
    end
    suppressed, mismatches = nonNegativeInteger(suppressed), nonNegativeInteger(mismatches)
    if not enabled or suppressed == nil or mismatches == nil then
      stats.invalidSamples = stats.invalidSamples + 1
      return false, "native build-gate sample is invalid"
    end
    stats.fastSamples = stats.fastSamples + 1
    return {
      enabled = enabled == "1",
      suppressed = suppressed,
      tagMismatches = mismatches,
      sampleVersion = version,
      lastGeneration = nonNegativeInteger(generation),
      queued = nonNegativeInteger(queued),
      dropped = nonNegativeInteger(dropped),
      armedCorrelation = nonNegativeInteger(armed),
      source = "native-fast-sample",
    }
  end

  local function sample()
    local gate, errorMessage = fastSample()
    if gate == false then return nil, errorMessage end
    if gate == nil then
      stats.fallbackSamples = stats.fallbackSamples + 1
      local hook = fullStatus()
      if hook.available ~= true then return nil, "native hook status is unavailable" end
      gate = hook.gates and hook.gates.buildProposal or {}
      if type(gate.suppressedQueue) == "table" then
        gate.correlationQueueAvailable = true
        gate.dropped = gate.dropped or gate.suppressedQueue.dropped
      end
    end
    if gate.enabled ~= true then return nil, "native BuildProposal gate is disabled" end
    if (tonumber(gate.tagMismatches) or 0) > 0 then
      return nil, "native BuildProposal visitor reported an ABI tag mismatch"
    end
    return math.max(0, tonumber(gate.suppressed) or 0), nil, gate
  end

  local function drain(maximum)
    if type(takeFunction) ~= "function" then
      takeFunction = rawget(_G, "tpf2mp_native_take_suppressed_build")
    end
    if type(takeFunction) ~= "function" then return nil, "unavailable" end
    local result = {}
    for _ = 1, math.max(1, tonumber(maximum) or 64) do
      stats.eventReads = stats.eventReads + 1
      local called, raw = pcall(takeFunction)
      if not called then
        stats.invalidSamples = stats.invalidSamples + 1
        return nil, tostring(raw)
      end
      if raw == nil then return result end
      if type(raw) ~= "string" then
        stats.invalidSamples = stats.invalidSamples + 1
        return nil, "native suppressed-build event is not a string"
      end
      local fault, dropped = raw:match("^F1|([^|]+)|(%d+)$")
      if fault then
        stats.invalidSamples = stats.invalidSamples + 1
        return nil, fault .. " (dropped " .. tostring(dropped) .. ")"
      end
      local generation, correlation, tag = raw:match("^S1|(%d+)|(%d+)|(-?%d+)$")
      generation, correlation, tag = nonNegativeInteger(generation),
        nonNegativeInteger(correlation), tonumber(tag)
      if generation == nil or correlation == nil or tag == nil or tag ~= math.floor(tag) then
        stats.invalidSamples = stats.invalidSamples + 1
        return nil, "native suppressed-build event is invalid"
      end
      result[#result + 1] = {
        generation = generation, correlation = correlation, tag = tag,
      }
      stats.events = stats.events + 1
    end
    return nil, "native suppressed-build event batch exceeded its bounded drain"
  end

  return { sample = sample, drain = drain, status = function() return stats end }
end

return M
