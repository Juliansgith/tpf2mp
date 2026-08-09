local M = {}

function M.apply(saved)
  if type(saved) ~= "table" then return 0 end
  local changed = 0
  local function clear(container, key)
    if type(container) == "table" and container[key] ~= nil then
      container[key] = nil
      changed = changed + 1
    end
  end
  local world = type(saved.world) == "table" and saved.world or {}
  for _, consensus in ipairs({
    world.proposalConsensus, world.operationConsensus,
  }) do
    if type(consensus) == "table" then
      for _, record in pairs(consensus.byId or {}) do
        if type(record) == "table" and record.success == true then
          clear(record, "errorCode")
        end
      end
      if type(consensus.lastOutcome) == "table"
        and consensus.lastOutcome.success == true then
        clear(consensus.lastOutcome, "errorCode")
      end
    end
  end
  local checkpoints = world.checkpointConsensus
  if type(checkpoints) == "table" then
    for _, record in pairs(checkpoints.byBoundary or {}) do
      if type(record) == "table" then
        if record.success == true then clear(record, "errorCode") end
        if record.exported == true and record.localSeq ~= nil then
          clear(record, "lastError")
        end
      end
    end
    if type(checkpoints.lastOutcome) == "table"
      and checkpoints.lastOutcome.success == true then
      clear(checkpoints.lastOutcome, "errorCode")
    end
  end

  local recovery = type(saved.recovery) == "table" and saved.recovery or {}
  if type(recovery.anchorPreparation) == "table"
    and recovery.anchorPreparation.status == "ready" then
    clear(recovery.anchorPreparation, "errorCode")
  end
  local probes = type(saved.probes) == "table" and saved.probes or {}
  if type(probes.networkAuthority) == "table"
    and probes.networkAuthority.ready == true then
    clear(probes.networkAuthority, "error")
  end
  if type(probes.mobility) == "table" and probes.mobility.emitted == true then
    clear(probes.mobility, "bridgeError")
  end

  local finance = type(saved.finance) == "table" and saved.finance or {}
  local startingCash = type(finance.startingCash) == "table"
    and finance.startingCash or {}
  for _, record in pairs(startingCash.grants or {}) do
    if type(record) == "table" and record.ok == true then clear(record, "error") end
  end
  for _, record in pairs(finance.lastPayouts or {}) do
    if type(record) == "table" and record.ok == true then clear(record, "error") end
  end
  local ledger = type(finance.networkAccounts) == "table"
    and finance.networkAccounts or {}
  local reconciliation = type(ledger.reconciliation) == "table"
    and ledger.reconciliation or {}
  for _, run in ipairs(reconciliation.items or {}) do
    if type(run) == "table" then
      if run.ok == true then clear(run, "error") end
      for _, record in pairs(run.accounts or {}) do
        if type(record) == "table" and record.ok == true then clear(record, "error") end
      end
    end
  end
  if type(saved.checkpoint) == "table"
    and type(saved.checkpoint.lastError) == "string"
    and saved.checkpoint.lastError:match("^table: ")
    and saved.checkpoint.lastLocalSeq ~= nil then
    clear(saved.checkpoint, "lastError")
  end
  return changed
end

return M
