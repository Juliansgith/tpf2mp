local M = {}

function M.append(lines, snapshot)
  local companion = snapshot.bridge and snapshot.bridge.companion or {}
  local recovery = companion.faultRecovery or {}
  local localRecovery = snapshot.recovery and snapshot.recovery.faultRecovery or {}
  local proposalFault = snapshot.proposalConsensus and snapshot.proposalConsensus.sessionFault
  local operationFault = snapshot.operationConsensus and snapshot.operationConsensus.sessionFault
  local status = tostring(recovery.status or localRecovery.status
    or ((proposalFault or operationFault) and "waiting-evidence" or "healthy"))
  if status == "healthy" then return end
  local label = status == "ready" and "READY - press Recover / Resync Session"
    or status == "probing" and "VERIFYING - fresh two-peer checkpoint"
    or status == "recovered" and "RECOVERED - safely paused; choose a speed to continue"
    or status == "rollback-required" and "RESTORE REQUIRED - use Load Latest Restore"
    or "WAITING - " .. tostring(recovery.detail or "late peer evidence")
  lines[#lines + 1] = "Session recovery: " .. label
    .. (recovery.faultCode and (" | " .. tostring(recovery.faultCode)) or "")
end

return M
