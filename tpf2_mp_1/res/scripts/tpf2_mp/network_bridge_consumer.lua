local bridge = require "tpf2_mp/bridge"

local M = {}

function M.new(deps)
  local getState = assert(deps.getState, "getState dependency is required")
  local takeAwaiting = assert(deps.takeAwaiting, "takeAwaiting dependency is required")
  local applyCommitted = assert(deps.applyCommitted, "applyCommitted dependency is required")
  local coreDigest = assert(deps.coreDigest, "coreDigest dependency is required")
  local diagnosticLog = assert(deps.diagnosticLog, "diagnosticLog dependency is required")
  local raiseOriginResidueFault = assert(
    deps.raiseOriginResidueFault, "raiseOriginResidueFault dependency is required")
  local publishSnapshot = assert(deps.publishSnapshot, "publishSnapshot dependency is required")

  return function()
    local state = getState()
    if state.networkMode ~= "network" then return end
    local authority = state.probes.networkAuthority or {}
    if authority.ready ~= true then
      state.lastError = "network authority is not ready: "
        .. tostring(authority.error or "native gates unavailable")
      return
    end
    for _, message in ipairs(bridge.poll(state.bridge, 16)) do
      if message.kind == "commit" and message.payload and message.payload.action then
        local originPeer = message.origin_peer or message.peer
        takeAwaiting(originPeer, message.origin_local_seq)
        local ok, result, event = applyCommitted(
          message.payload.action, originPeer, message.seq)
        local acknowledgement = {
          commitSeq = message.seq,
          success = ok,
          digest = event and event.postDigest or coreDigest(),
        }
        if not ok then
          acknowledgement.error = tostring(type(result) == "table" and result.error or result)
        end
        bridge.emit(state.bridge, "ack", acknowledgement, state.tick)
        publishSnapshot()
      elseif message.kind == "control" and message.payload and message.payload.action then
        local action = message.payload.action
        if action.type == "network.intent_rejected" then
          local rejectedIntent = takeAwaiting(action.originPeer, action.originLocalSeq)
          local released = rejectedIntent ~= nil
          diagnosticLog("network-intent-rejected", {
            originPeer = action.originPeer,
            originLocalSeq = action.originLocalSeq,
            actionType = action.actionType,
            error = action.errorCode,
            released = released,
            tick = state.tick,
          })
          if released then
            if rejectedIntent.originCaptureToken then
              raiseOriginResidueFault(
                "origin-applied-intent-rejected:" .. tostring(action.errorCode or "unknown"), {
                  originLocalSeq = tonumber(action.originLocalSeq),
                  actionType = tostring(action.actionType or rejectedIntent.type or ""),
                  originCaptureToken = tostring(rejectedIntent.originCaptureToken),
                })
            else
              state.lastError = "network intent rejected: "
                .. tostring(action.errorCode or "unknown")
            end
          end
        else
          applyCommitted(action, message.origin_peer or "host", message.seq)
        end
        publishSnapshot()
      end
    end
  end
end

return M
