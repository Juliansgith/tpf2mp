local util = require "tpf2_mp/util"

local M = {}

function M.new(getState, diagnosticLog)
  assert(type(getState) == "function", "service registration state provider is required")
  assert(type(diagnosticLog) == "function", "service registration logger is required")

  local function probe()
    local state = getState()
    state.probes = state.probes or {}
    state.probes.serviceRegistration = state.probes.serviceRegistration or {
      submitted = 0, quarantined = 0, recovered = 0,
      current = {}, history = {}, last = nil,
    }
    local value = state.probes.serviceRegistration
    value.current = type(value.current) == "table" and value.current or {}
    value.history = type(value.history) == "table" and value.history or {}
    return value
  end

  local function quarantine(action, message)
    local state, value = getState(), probe()
    local lineCid = tostring(action and action.lineCid or "")
    local record = {
      lineCid = lineCid,
      companyCid = action and action.companyCid or nil,
      error = tostring(message or "line registration could not be normalised"),
      tick = state.tick,
    }
    value.quarantined = (tonumber(value.quarantined) or 0) + 1
    value.current[lineCid] = util.deepCopy(record)
    value.last = util.deepCopy(record)
    value.history[#value.history + 1] = util.deepCopy(record)
    while #value.history > 16 do table.remove(value.history, 1) end
    diagnosticLog("line-registration-quarantined", record)
  end

  local function submitted(action)
    local value = probe()
    local lineCid = tostring(action and action.lineCid or "")
    value.submitted = (tonumber(value.submitted) or 0) + 1
    local reason = action and action.service and action.service.metadata
      and action.service.metadata.registrationQuarantine or nil
    if reason then
      quarantine(action, reason)
      return
    end
    if value.current[lineCid] then
      value.current[lineCid] = nil
      value.recovered = (tonumber(value.recovered) or 0) + 1
    end
  end

  return {
    quarantine = quarantine,
    submitted = submitted,
    permanentFailure = function(action, phase)
      return phase == "normalise" and action and action.type == "line.register"
    end,
  }
end

return M
