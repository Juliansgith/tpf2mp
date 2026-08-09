local util = require "tpf2_mp/util"
local serviceRegistrationRuntime = require "tpf2_mp/service_registration_runtime"
local freightMilestoneFollowup = require "tpf2_mp/freight_milestone_followup"
local M = {}

function M.new(deps)
  local getState = assert(deps.getState, "getState dependency is required")
  local diagnosticLog = assert(deps.diagnosticLog, "diagnosticLog dependency is required")
  local registrations = serviceRegistrationRuntime.new(getState, diagnosticLog)
  local maximum = math.max(1, tonumber(deps.maximum) or 512)
  local items = {}
  local function count() return #items end
  local function cancelLineRegistration(lineCid)
    if type(lineCid) ~= "string" or lineCid == "" then return 0 end
    local state = getState()
    local removed = 0
    for index = #items, 1, -1 do
      local action = items[index].action
      if action and action.type == "line.register" and action.lineCid == lineCid then
        table.remove(items, index)
        removed = removed + 1
      end
    end
    if removed > 0 then
      diagnosticLog("network-followup-cancelled", {
        type = "line.register", lineCid = lineCid, removed = removed,
        queueDepth = count(), tick = state.tick,
      })
    end
    return removed
  end

  local function schedule(action)
    local state = getState()
    if type(action) ~= "table" then return false, "follow-up action must be a table" end
    if state.networkMode ~= "network" then
      return false, "ordered follow-ups exist only in network mode"
    end
    local actionType = tostring(action.type or "")
    if actionType ~= "line.register" and actionType ~= "town.develop"
      and actionType ~= "freight.milestone" then
      return false, "unsupported ordered follow-up: " .. actionType
    end
    local proposalFault = state.world.proposalConsensus
      and state.world.proposalConsensus.sessionFault
    local operationFault = state.world.operationConsensus
      and state.world.operationConsensus.sessionFault
    if proposalFault or operationFault then return false, "network session is faulted" end

    if actionType == "line.register" then
      local lineCid = action.lineCid
      if type(lineCid) ~= "string" or lineCid == "" then
        return false, "line registration follow-up requires a canonical line id"
      end
      for index, pending in ipairs(items) do
        if pending.action and pending.action.type == actionType
          and pending.action.lineCid == lineCid then
          pending.action = util.deepCopy(action)
          pending.updatedTick = state.tick
          pending.coalesced = (pending.coalesced or 0) + 1
          diagnosticLog("network-followup-coalesced", {
            type = actionType, lineCid = lineCid, queuePosition = index,
            coalesced = pending.coalesced, tick = state.tick,
          })
          return true, {
            queued = true, deferred = true, coalesced = true,
            queuePosition = index, queueDepth = count(),
          }
        end
      end
    elseif actionType == "town.develop" then
      if type(action.batch) ~= "table" or next(action.batch) == nil then
        return false, "town development follow-up requires a non-empty batch"
      end
      for townCid, calls in pairs(action.batch) do
        if type(townCid) ~= "string" or type(calls) ~= "number"
          or calls ~= math.floor(calls) or calls < 1 then
          return false, "town development follow-up is malformed"
        end
      end
      for _, pending in ipairs(items) do
        if pending.action and pending.action.type == actionType then
          pending.action.batch = pending.action.batch or {}
          for townCid, calls in pairs(action.batch) do
            pending.action.batch[townCid] =
              (tonumber(pending.action.batch[townCid]) or 0) + calls
          end
          pending.updatedTick = state.tick
          pending.coalesced = (pending.coalesced or 0) + 1
          diagnosticLog("network-followup-coalesced", {
            type = actionType, coalesced = pending.coalesced, tick = state.tick,
          })
          return true, {
            queued = true, deferred = true, coalesced = true, queueDepth = count(),
          }
        end
      end
    elseif actionType == "freight.milestone" then
      local handled, result = freightMilestoneFollowup.coalesce(items, action, state, diagnosticLog, count)
      if handled ~= nil then return handled, result end
    end

    if count() >= maximum then
      return false, "ordered follow-up queue is full (" .. tostring(maximum) .. ")"
    end
    items[#items + 1] = {
      action = util.deepCopy(action), queuedTick = state.tick, coalesced = 0,
    }
    diagnosticLog("network-followup-deferred", {
      type = actionType, queueDepth = count(), tick = state.tick,
    })
    return true, {
      queued = true, deferred = true, queuePosition = count(),
      queueDepth = count(), queueCapacity = maximum,
    }
  end

  local function emissionAction(pending)
    local action = pending and pending.action or nil
    if not action or action.type ~= "town.develop" then
      return action and util.deepCopy(action) or nil
    end
    local batch, townCount = {}, 0
    for _, townCid in ipairs(util.sortedKeys(action.batch or {})) do
      if townCount >= 512 then break end
      local calls = math.max(0, math.floor(tonumber(action.batch[townCid]) or 0))
      if calls > 0 then
        batch[townCid] = math.min(8, calls)
        townCount = townCount + 1
      end
    end
    if next(batch) == nil then return nil end
    return { type = "town.develop", batch = batch }
  end

  local function consume(pending, emittedAction)
    if pending.action.type ~= "town.develop" then
      if pending.action.type == "line.register" then registrations.submitted(emittedAction) end
      table.remove(items, 1)
      return false
    end
    for townCid, calls in pairs(emittedAction.batch or {}) do
      local remaining = (tonumber(pending.action.batch[townCid]) or 0) - calls
      pending.action.batch[townCid] = remaining > 0 and remaining or nil
    end
    if next(pending.action.batch or {}) == nil then
      table.remove(items, 1)
      return false
    end
    return true
  end

  local function handleFailure(pending, emittedAction, phase, message)
    if not registrations.permanentFailure(emittedAction, phase) then return false end
    -- Facts derivation cannot change while the same line action sits in the
    -- queue. Drop and diagnose it; a fresh edit/assignment schedules a fresh
    -- registration. Bridge failures remain on the ordinary retry path.
    table.remove(items, 1)
    registrations.quarantine(emittedAction, message)
    return true
  end

  return {
    schedule = schedule,
    count = count,
    head = function() return items[1] end,
    copy = function() return util.deepCopy(items) end,
    clear = function() items = {} end,
    cancelLineRegistration = cancelLineRegistration,
    dropHead = function() table.remove(items, 1) end,
    emissionAction = emissionAction,
    consume = consume,
    handleFailure = handleFailure,
  }
end

return M
