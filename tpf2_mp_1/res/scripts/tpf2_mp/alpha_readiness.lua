local M = {}

M.PROFILE_VERSION = 1
M.PROFILE = "trusted-lan-two-player-alpha"

local CAPABILITIES = {
  "Two canonical companies with isolated wallets and private asset custody",
  "Bidirectional named road/track/construction replay with all-peer consensus",
  "Vanilla line creation/edit/delete and portable vehicle purchase/lifecycle replay",
  "Shared adaptive clock and per-station vehicle rendezvous",
  "Five-minute passenger/cargo economy with model-town growth",
  "Passenger connections and conserved cargo transfers over up to four lines",
  "Receipt-bound paired saves, exact restore plans, and first-fault evidence",
}

local LIMITATIONS = {
  "Trusted LAN/VPN only; there is no hostile-client security or encryption",
  "Exact Transport Fever 2 Build 35924 and identical content/save bytes are required",
  "Native people, cargo glyphs, income popups, and mid-leg coordinates are cosmetic",
  "Executable mod callbacks and arbitrary script commands need explicit adapters",
  "A reconnect pauses the match; resume manually after both peers report synchronized",
  "Host migration and in-place repair of divergent native geometry are not supported",
}

local function add(items, code, text)
  items[#items + 1] = { code = code, text = text }
end

local function sessionFault(snapshot)
  local proposal = snapshot.proposalConsensus or {}
  local operation = snapshot.operationConsensus or {}
  local companion = snapshot.bridge and snapshot.bridge.companion or {}
  return proposal.sessionFault or operation.sessionFault or companion.sessionFault
end

function M.evaluate(snapshot)
  snapshot = type(snapshot) == "table" and snapshot or {}
  local blockers, warnings = {}, {}
  local companion = snapshot.bridge and snapshot.bridge.companion or {}
  local authority = snapshot.probes and snapshot.probes.networkAuthority or {}
  local deferred = snapshot.deferredNetworkQueue or {}
  local proposals = snapshot.proposalConsensus or {}
  local operations = snapshot.operationConsensus or {}
  local checkpoints = snapshot.checkpointConsensus or {}
  local reconnect = companion.reconnect or {}
  local fault = sessionFault(snapshot)

  if snapshot.networkMode ~= "network" then
    add(blockers, "network-mode-required", "Start through Host or Join for the network alpha")
  end
  if snapshot.initialized ~= true then
    add(blockers, "match-not-initialized", "The ordered match bootstrap has not completed")
  end
  if snapshot.networkMode == "network" and companion.connected ~= true then
    add(blockers, "peer-not-synchronized",
      companion.socketConnected == true and "The peer socket is replaying its ordered backlog"
        or "The required peer companion is not connected")
  end
  if snapshot.networkMode == "network" and authority.ready ~= true then
    add(blockers, "native-authority-not-ready",
      tostring(authority.error or "Exact-build native authority is not ready"))
  end
  if companion.auditFaulted == true then
    add(blockers, "audit-persistence-fault", "The durable host journal is unavailable")
  end
  if fault then
    local faultText = type(fault) == "table" and fault.errorCode or fault
    add(blockers, "session-fault", tostring(faultText or "unknown session fault"))
  end
  if tonumber(proposals.pending) and tonumber(proposals.pending) > 0 then
    add(blockers, "proposal-pending", "A physical construction is awaiting consensus")
  end
  if tonumber(operations.pending) and tonumber(operations.pending) > 0 then
    add(blockers, "operation-pending", "A line or vehicle operation is awaiting consensus")
  end
  if tonumber(checkpoints.pending) and tonumber(checkpoints.pending) > 0 then
    add(blockers, "checkpoint-pending", "A deterministic checkpoint is awaiting both peers")
  end
  if tonumber(deferred.count) and tonumber(deferred.count) > 0 then
    add(blockers, "ordered-work-queued", "Local actions remain queued behind the authority lane")
  end
  if reconnect.active == true or next(reconnect.synchronizingPeers or {}) ~= nil then
    add(blockers, "reconnect-in-progress", "A peer is inside the bounded reconnect fence")
  end
  if snapshot.initialized == true and not checkpoints.lastAgreed then
    add(blockers, "no-agreed-checkpoint", "The initial all-peer checkpoint has not converged")
  end

  if snapshot.autonomyFrozen ~= true then
    add(warnings, "native-autonomy-visible",
      "Native autonomous development is not reported frozen; authored economy remains authoritative")
  end
  local network = snapshot.transportNetwork or {}
  if tonumber(network.unresolvedCargoCount) and tonumber(network.unresolvedCargoCount) > 0 then
    add(warnings, "cargo-path-unresolved",
      tostring(network.unresolvedCargoCount) .. " cargo line(s) have no compatible complete path")
  end
  local compatibility = snapshot.probes and snapshot.probes.resourceCompatibility or {}
  if tonumber(compatibility.rejectedProposals) and tonumber(compatibility.rejectedProposals) > 0 then
    add(warnings, "unsupported-resource-attempt",
      tostring(compatibility.rejectedProposals) .. " proposal(s) were rejected by portable replay")
  end
  if tonumber(snapshot.serviceCount) == 0 then
    add(warnings, "no-services", "No authoritative service is registered yet")
  end
  if snapshot.lastError then
    add(warnings, "last-game-error", tostring(snapshot.lastError))
  elseif snapshot.bridge and snapshot.bridge.lastError then
    add(warnings, "last-bridge-error", tostring(snapshot.bridge.lastError))
  end

  local state = #blockers == 0 and "READY" or "WAITING"
  for _, item in ipairs(blockers) do
    if item.code == "session-fault" or item.code == "audit-persistence-fault" then
      state = "FAULTED"
      break
    end
  end
  return {
    schemaVersion = M.PROFILE_VERSION,
    profile = M.PROFILE,
    state = state,
    ready = state == "READY",
    blockers = blockers,
    warnings = warnings,
    capabilities = CAPABILITIES,
    limitations = LIMITATIONS,
  }
end

return M
