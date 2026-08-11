local util = require "tpf2_mp/util"
local hash = require "tpf2_mp/hash"

local M = {}

M.EVENT_LIMIT = 64
M.CAPTURE_LIMITS = {
  eventShapes = 4,
  proposalSnapshots = 2,
  nativeCommandHistory = 8,
  operationalGuiHistory = 8,
  replacementHistory = 4,
  replacementRecoveryHistory = 4,
  proposalCodecFailures = 8,
}

local PORTABLE_SCALARS = {
  type = true, kind = true, status = true, success = true, localOnly = true,
  observation = true, reason = true, error = true, errorCode = true,
  proposalId = true, operationId = true, transactionId = true,
  companyCid = true, lineCid = true, vehicleCid = true, marketCid = true,
  proposalDigest = true, operationDigest = true, resultDigest = true,
  coreDigest = true, modelDigest = true, canonicalDigest = true,
  financialDigest = true, structuralDigest = true,
  worldManifestDigest = true, convergenceKey = true,
  boundarySeq = true, preparationSeq = true, commitSeq = true,
  generation = true, round = true, stopIndex = true,
  requestedSpeed = true, effectiveSpeed = true, scheduled = true,
  queued = true, prepared = true, changed = true, applied = true,
  tick = true, peer = true, name = true,
}

local function boundedScalar(value)
  local kind = type(value)
  if kind == "string" then return value:sub(1, 2048) end
  if kind == "number" or kind == "boolean" then return value end
  return nil
end

local function scalarProjection(value)
  if type(value) ~= "table" then return boundedScalar(value) end
  local result = {}
  for key in pairs(PORTABLE_SCALARS) do
    local retained = boundedScalar(value[key])
    if retained ~= nil then result[key] = retained end
  end
  return result
end

local function retainTail(items, limit)
  if type(items) ~= "table" then return {} end
  local first = math.max(1, #items - limit + 1)
  local result = {}
  for index = first, #items do result[#result + 1] = items[index] end
  return result
end

function M.compactEvent(event)
  if type(event) ~= "table" or event.retentionVersion == 1 then return event end
  return {
    retentionVersion = 1,
    seq = event.seq,
    commitSeq = event.commitSeq,
    eventId = event.eventId,
    tick = event.tick,
    actor = event.actor,
    action = scalarProjection(event.action),
    actionDigest = hash.value(event.action or {}),
    preDigest = event.preDigest,
    postDigest = event.postDigest,
    preModelDigest = event.preModelDigest,
    postModelDigest = event.postModelDigest,
    success = event.success == true,
    result = scalarProjection(event.result),
    resultDigest = hash.value(event.result),
  }
end

function M.compact(state, configuredEventLimit)
  if type(state) ~= "table" then return state end
  state.eventLog = type(state.eventLog) == "table" and state.eventLog
    or { nextSeq = 1, items = {} }
  local requested = math.max(1, util.integer(configuredEventLimit, M.EVENT_LIMIT))
  local events = retainTail(state.eventLog.items, math.min(M.EVENT_LIMIT, requested))
  for index, event in ipairs(events) do events[index] = M.compactEvent(event) end
  state.eventLog.items = events

  local probes = type(state.probes) == "table" and state.probes or {}
  state.probes = probes
  local capture = type(probes.capture) == "table" and probes.capture or {}
  probes.capture = capture
  for field, limit in pairs(M.CAPTURE_LIMITS) do
    capture[field] = retainTail(capture[field], limit)
  end
  return state
end

return M
