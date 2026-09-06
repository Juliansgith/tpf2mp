local sampleCodec = require "tpf2_mp/gui_build_gate_sample_codec"

local M = {}

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
    local decoded, decodeError, legacy = sampleCodec.decode(raw)
    if not decoded then
      stats.invalidSamples = stats.invalidSamples + 1
      return false, decodeError
    end
    if legacy then stats.legacySamples = stats.legacySamples + 1 end
    stats.fastSamples = stats.fastSamples + 1
    return decoded
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
      if type(gate.factoryCapture) == "table" then
        gate.factoryCaptureAvailable = true
        gate.factoryReady = gate.factoryCapture.ready
        gate.factoryDropped = gate.factoryCapture.dropped
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
    local limit = math.max(1, tonumber(maximum) or 64)
    for index = 1, limit + 1 do
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
      if index > limit then
        stats.invalidSamples = stats.invalidSamples + 1
        return nil, "native suppressed-build event batch exceeded its bounded drain"
      end
      local generation, correlation, tag = raw:match("^S1|(%d+)|(%d+)|(-?%d+)$")
      generation, correlation, tag = tonumber(generation), tonumber(correlation), tonumber(tag)
      if generation == nil or correlation == nil or tag == nil or tag ~= math.floor(tag) then
        stats.invalidSamples = stats.invalidSamples + 1
        return nil, "native suppressed-build event is invalid"
      end
      result[#result + 1] = {
        generation = generation, correlation = correlation, tag = tag,
      }
      stats.events = stats.events + 1
    end
    return result
  end

  return { sample = sample, drain = drain, status = function() return stats end }
end

return M
