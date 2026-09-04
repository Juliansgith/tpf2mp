local M = {}

local function nonNegativeInteger(value)
  local number = tonumber(value)
  if not number or number < 0 or number ~= math.floor(number) then return nil end
  return number
end

function M.decode(raw)
  if type(raw) ~= "string" then return nil, "native build-gate sample is invalid" end
  local version, enabled, suppressed, mismatches, generation, queued, dropped, armed
  local factoryReady, factoryDropped
  enabled, suppressed, mismatches, generation, queued, dropped, armed,
    factoryReady, factoryDropped =
    raw:match("^B3|([01])|(%d+)|(%d+)|(%d+)|(%d+)|(%d+)|(%d+)|(%d+)|(%d+)$")
  if enabled then version = 3 else
    enabled, suppressed, mismatches, generation, queued, dropped, armed =
      raw:match("^B2|([01])|(%d+)|(%d+)|(%d+)|(%d+)|(%d+)|(%d+)$")
    if enabled then version = 2 else
      enabled, suppressed, mismatches = raw:match("^B1|([01])|(%d+)|(%d+)$")
      if enabled then version = 1 end
    end
  end
  suppressed, mismatches = nonNegativeInteger(suppressed), nonNegativeInteger(mismatches)
  if not enabled or suppressed == nil or mismatches == nil then
    return nil, "native build-gate sample is invalid"
  end
  return {
    enabled = enabled == "1", suppressed = suppressed, tagMismatches = mismatches,
    sampleVersion = version, lastGeneration = nonNegativeInteger(generation),
    queued = nonNegativeInteger(queued), dropped = nonNegativeInteger(dropped),
    armedCorrelation = nonNegativeInteger(armed),
    factoryCaptureAvailable = version == 3,
    factoryReady = nonNegativeInteger(factoryReady),
    factoryDropped = nonNegativeInteger(factoryDropped),
    source = "native-fast-sample",
  }, nil, version == 1
end

return M
