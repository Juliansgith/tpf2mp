local util = require "tpf2_mp/util"
local edgeOwnership = require "tpf2_mp/edge_ownership"

local M = {}

function M.ensure(localId, expectedOwner, options)
  options = type(options) == "table" and options or {}
  local observedOwner = options.ownerOf(localId)
  if tonumber(observedOwner) == tonumber(expectedOwner) then return localId end
  if observedOwner ~= nil and tonumber(observedOwner) ~= -1 then
    return nil, {
      error = "private proposal edge was created under an unexpected rival owner",
      observedOwner = observedOwner, expectedOwner = expectedOwner,
    }
  end
  local beforeEdges, captureError = edgeOwnership.captureBaseEdges()
  if not beforeEdges then return nil, tostring(captureError) end
  local proposal, proposalError = edgeOwnership.makeProposal(localId, expectedOwner)
  if not proposal then return nil, tostring(proposalError) end
  local factory = util.commandFactory("buildProposal")
  local apiValue = options.api
  if not (factory and apiValue and apiValue.cmd
    and type(apiValue.cmd.sendCommand) == "function") then
    return nil, "ownership replacement BuildProposal API is unavailable"
  end
  if options.networkMode == "network" then
    local authorize = rawget(_G, "tpf2mp_native_authorize_build")
    if type(authorize) ~= "function" then
      return nil, "ownership replacement requires native authorization"
    end
    local called, authorized, authorizeError = pcall(authorize)
    if not called or authorized == false then
      return nil, tostring(authorizeError or authorized)
    end
  end
  local commandOk, commandOrError = pcall(factory, proposal, nil, false)
  if not commandOk then return nil, tostring(commandOrError) end
  local callbackCalled, replacementSuccess, replacementResult = false, false, nil
  local sent, sendError = util.sendCommand(commandOrError, function(result, success)
    callbackCalled, replacementSuccess, replacementResult = true, success == true, result
  end, "mod.proposal.rebind-edge-owner")
  if not sent then return nil, tostring(sendError) end
  if not callbackCalled then return nil, "ownership replacement callback was not synchronous" end
  if not replacementSuccess then return nil, "ownership replacement BuildProposal was rejected" end
  local replacementId, candidates, replacementError = edgeOwnership.findReplacement(
    beforeEdges, localId, replacementResult, expectedOwner)
  if not replacementId then
    return nil, { error = tostring(replacementError), candidates = candidates }
  end
  return replacementId
end

return M
