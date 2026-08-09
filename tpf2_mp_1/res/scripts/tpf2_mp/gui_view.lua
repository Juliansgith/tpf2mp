local util = require "tpf2_mp/util"

local M = {}

local function compactResult(value)
  if value == nil then return "-" end
  if type(value) ~= "table" then return tostring(value) end
  if value.mode then return "mode=" .. tostring(value.mode) end
  if value.lineCid then return tostring(value.lineCid) .. (value.fareCents and (" fare=" .. value.fareCents .. "c") or "") end
  if value.queued then return "queued seq " .. tostring(value.localSeq) end
  if value.mobilityDigest then return "mobility=" .. tostring(value.mobilityDigest) end
  if value.structuralDigest then return "world=" .. tostring(value.structuralDigest) end
  return "table"
end

local function cargoProof(snapshot)
  local cargo = snapshot.cargoPresentation or {}
  local totals = cargo.totals or {}
  local cursors = snapshot.deliveryCursors or {}
  local active, settled, revenue = 0, 0, 0
  for lineCid, line in pairs(cargo.lines or {}) do
    if type(line) == "table" and line.retired ~= true then
      active = active + 1
      local cursor = cursors[lineCid]
      if type(cursor) == "table" then
        settled = settled + math.max(0, tonumber(cursor.deliveredCargo) or 0)
        revenue = revenue + math.max(0, tonumber(cursor.earnedRevenueCents) or 0)
      end
    end
  end
  return active,
    math.max(0, tonumber(totals.waiting) or 0),
    math.max(0, tonumber(totals.aboard) or 0),
    math.max(0, tonumber(totals.capacity) or 0),
    math.max(0, tonumber(totals.delivered) or 0),
    settled, revenue
end

local function milestoneStatus(probe)
  if type(probe) ~= "table" then return "waiting for first load" end
  if probe.aboardCheckpointed == true then
    return string.format("PROVED %d on %s round %s",
      tonumber(probe.aboard) or 0, tostring(probe.lineCid or "-"),
      tostring(probe.observedRound or "legacy"))
  end
  if probe.stale == true then return "stale witness; waiting to retry" end
  return "waiting for first load"
end

-- Log-scale crowd glyphs: one large block is five hundred people, one medium
-- is one hundred, one small is twenty. Reading magnitude beats counting.
function M.crowdIcons(count)
  local remaining = math.max(0, tonumber(count) or 0)
  local text = ""
  for _, bucket in ipairs({ { 500, "█" }, { 100, "◼" }, { 20, "▪" } }) do
    while remaining >= bucket[1] and #text < 48 do
      text = text .. bucket[2]
      remaining = remaining - bucket[1]
    end
  end
  if text == "" and (tonumber(count) or 0) > 0 then text = "·" end
  return text
end

function M.render(gui, snapshot, options)
  if not gui.status then return end
  options = options or {}
  snapshot = snapshot or gui.snapshot or {}
  local companion = snapshot.bridge and snapshot.bridge.companion or {}
  local linkStatus = snapshot.networkMode ~= "network" and "local"
    or (companion.connected == true and "connected" or tostring(companion.status or "offline"))
  local status = string.format(
    "Mode: %s | Peer: %s | Link: %s | Active: %s | Proxy: %s | Selected: %s (%s) | Markets: %d | Services: %d | Epoch: %d",
    tostring(snapshot.networkMode or "?"),
    tostring(snapshot.peerId or "?"),
    linkStatus,
    tostring(snapshot.activeCompanyName or "not initialised"),
    tostring(snapshot.proxyMode == true),
    tostring(gui.selectedEntityId or "none"),
    tostring(gui.selectedEntityKind or "-"),
    tonumber(snapshot.marketCount) or 0,
    tonumber(snapshot.serviceCount) or 0,
    tonumber(snapshot.epoch) or 0
  )
  gui.status:setText(status)
  local lines = {
    "Session: " .. tostring(snapshot.sessionId or "?") .. " | digest " .. tostring(snapshot.digest or "?"),
    string.format("Match: %s | economy %s %.0f%% | epoch limit %s | value target %.2f | winner %s",
      tostring(snapshot.match and snapshot.match.status or "setup"),
      tostring(snapshot.match and snapshot.match.rules
        and snapshot.match.rules.economyDifficulty or "normal"),
      (snapshot.match and snapshot.match.rules
        and snapshot.match.rules.revenueMultiplierPpm or 1000000) / 10000,
      tostring(snapshot.match and snapshot.match.rules and snapshot.match.rules.maxEpochs or "-"),
      (snapshot.match and snapshot.match.rules and snapshot.match.rules.valuationTargetCents or 0) / 100,
      tostring(snapshot.match and snapshot.match.winnerCid or "-")),
    string.format("Starting cash: target %.0f | setup grants %.0f | repairs %d%s",
      snapshot.startingCash and snapshot.startingCash.target or 0,
      snapshot.startingCash and snapshot.startingCash.totalGranted or 0,
      snapshot.startingCash and snapshot.startingCash.repairs or 0,
      snapshot.startingCash and snapshot.startingCash.lastError and (" | ERROR " .. tostring(snapshot.startingCash.lastError)) or ""),
    "Canonical objects: " .. tostring(snapshot.canonicalCount or 0) .. " | autonomy frozen: " .. tostring(snapshot.autonomyFrozen == true),
    "World manifest: " .. tostring(snapshot.probes and snapshot.probes.worldManifestDigest or "-")
      .. " | ambiguous operational fingerprints "
      .. tostring(snapshot.probes and snapshot.probes.worldManifest
        and snapshot.probes.worldManifest.ambiguousCount or 0)
      .. " | deferred scenery "
      .. tostring(snapshot.probes and snapshot.probes.worldManifest
        and snapshot.probes.worldManifest.deferredUnique or 0),
    "Bridge out/in: " .. tostring(snapshot.bridge and snapshot.bridge.emitted or 0) .. "/" .. tostring(snapshot.bridge and snapshot.bridge.received or 0),
    "Last result: " .. compactResult(snapshot.lastResult),
    "Route draft: " .. tostring(#(gui.routeDraft or {}))
      .. " stops | retained line " .. tostring(gui.selectedLineId or "-")
      .. " | vehicle " .. tostring(gui.selectedVehicleId or "-")
      .. " | depot " .. tostring(gui.selectedDepotId or "-"),
  }
  if snapshot.networkMode == "network" then
    local endpoint = companion.role == "host"
      and (tostring(companion.bind or "?") .. ":" .. tostring(companion.port or "?"))
      or (tostring(companion.host or "?") .. ":" .. tostring(companion.port or "?"))
    local peers = type(companion.connectedPeers) == "table"
      and table.concat(companion.connectedPeers, ",") or "-"
    lines[#lines + 1] = string.format(
      "Companion: %s/%s | endpoint %s | TCP %s | remote peers %s",
      tostring(companion.role or "missing"),
      tostring(companion.status or "not-running"),
      endpoint,
      companion.connected == true and "connected" or "waiting",
      peers
    )
    local content = snapshot.industryContent or {}
    local localContent = snapshot.probes and snapshot.probes.industryContent or {}
    lines[#lines + 1] = string.format(
      "Freight content: %s | digest %s | %d resources / %d variants | local %s%s",
      content.ready == true and "READY" or (content.fault and "FAULTED" or "waiting"),
      tostring(content.digest or localContent.localDigest or "-"),
      tonumber(content.resourceCount or localContent.resourceCount) or 0,
      tonumber(content.variantCount or localContent.variantCount) or 0,
      tostring(localContent.status or "waiting-for-sidecar"),
      content.fault and (" | " .. tostring(content.fault.errorCode or "content-fault")) or "")
    local freight = snapshot.freightIndustry or {}
    local localFreight = snapshot.probes and snapshot.probes.freightIndustry or {}
    lines[#lines + 1] = string.format(
      "Freight model: %s | %d industries | epoch %d | %d input / %d output units | local %s",
      freight.ready == true and "READY" or "waiting",
      tonumber(freight.industryCount or localFreight.industryCount) or 0,
      tonumber(freight.productionEpoch) or 0,
      tonumber(freight.inputUnits) or 0,
      tonumber(freight.outputUnits) or 0,
      tostring(localFreight.status or "waiting-for-content"))
    local cargoLines, waitingCargo, aboardCargo, cargoCapacity,
      deliveredCargo, settledCargo, settledCargoRevenue = cargoProof(snapshot)
    lines[#lines + 1] = string.format(
      "Cargo proof: %d active lines | %d waiting | %d/%d aboard | %d delivered | %d settled / $%.2f",
      cargoLines, waitingCargo, aboardCargo, cargoCapacity, deliveredCargo,
      settledCargo, settledCargoRevenue / 100)
    local capture = gui.nativeBuildCapture or {}
    lines[#lines + 1] = string.format(
      "Vanilla build bridge: %s | captured %d (%d exact/%d fallback) | duplicate %d | unmatched %d | construction previews %d/%d projected/skipped | replay quarantine %d/%d preview/apply",
      gui.proposalReplayQuarantine and "replay settling"
        or (gui.pendingNetworkBuildSuppression and "settling click"
        or (gui.pendingNetworkBuildExact and "exact click latched"
          or (gui.pendingNetworkBuildPreview and "preview armed" or "idle"))),
      tonumber(capture.captured) or 0,
      tonumber(capture.exactCaptures) or 0,
      tonumber(capture.previewFallbacks) or 0,
      tonumber(capture.duplicates) or 0,
      tonumber(capture.orphaned) or 0,
      tonumber(capture.constructionPreviewsProjected) or 0,
      tonumber(capture.constructionPreviewsSkipped) or 0,
      tonumber(capture.replayPreviewsQuarantined) or 0,
      tonumber(capture.replayAppliesRejected) or 0
    )
    local clock = snapshot.networkClock or {}
    lines[#lines + 1] = string.format(
      "Shared clock: requested %s | effective %s | generation %s | %s",
      tostring(clock.requestedSpeed or 0),
      tostring(clock.effectiveSpeed or 0),
      tostring(clock.generation or 0),
      tostring(clock.reason or "waiting for host"))
    local hostClock = companion.clock or {}
    local rendezvous = hostClock.rendezvous or clock.rendezvous
    lines[#lines + 1] = string.format(
      -- A player should never have to reason about quiescence: either the
      -- companion says the automatic native save is safe now, or it says
      -- exactly what is in the way.
      "Restore points: %s | preparation: %s | native save: %s%s",
      (function()
        local points = companion.restorePoints
        if type(points) ~= "table" or #points == 0 then return "none yet" end
        return "boundary " .. tostring(points[#points]) .. " (" .. tostring(#points) .. " total)"
      end)(),
      tostring(companion.anchorPreparationStatus or "idle"),
      (function()
        local nativeSave = snapshot.recovery and snapshot.recovery.nativeSave or {}
        if nativeSave.status and nativeSave.status ~= "idle" then
          return tostring(nativeSave.status) .. (nativeSave.saveName
            and " (" .. tostring(nativeSave.saveName) .. ")" or "")
        end
        return companion.anchorReady == true and "READY - automatic save pending"
          or (companion.anchorBoundarySeq and "not yet" or "waiting for a checkpoint")
      end)(),
      (function()
        local reasons = companion.anchorReasons
        if companion.anchorReady == true or type(reasons) ~= "table" or #reasons == 0 then
          return ""
        end
        return " | " .. tostring(reasons[1])
      end)())
    lines[#lines + 1] = string.format(
      "Clock convergence: skew %s | rendezvous %s | target %s",
      hostClock.gameTimeSkew and string.format("%.3f", hostClock.gameTimeSkew) or "-",
      rendezvous and tostring(rendezvous.status or "armed") or "idle",
      rendezvous and tostring(rendezvous.targetGameTime or "-") or "-")
    local hostVehicleSync = companion.vehicleSync or {}
    local localVehicleSync = snapshot.probes and snapshot.probes.vehicleSync or {}
    lines[#lines + 1] = string.format(
      "Train station sync: managed %d | local holds/releases/faults %d/%d/%d | host pending/releases/faults %d/%d/%d",
      tonumber(localVehicleSync.managed) or 0,
      tonumber(localVehicleSync.held) or 0,
      tonumber(localVehicleSync.released) or 0,
      tonumber(localVehicleSync.faults) or 0,
      tonumber(hostVehicleSync.pendingRounds) or 0,
      tonumber(hostVehicleSync.releases) or 0,
      tonumber(hostVehicleSync.faults) or 0)
    local passenger = snapshot.passengerPresentation or {}
    local passengerTotals = passenger.totals or {}
    local cosmetics = snapshot.probes and snapshot.probes.passengerCosmetics or {}
    lines[#lines + 1] = string.format(
      "Passenger presentation: %d aboard / %d seats | %d waiting | native scenery %d aboard, %d waiting | target writes %s",
      tonumber(passengerTotals.aboard) or 0,
      tonumber(passengerTotals.capacity) or 0,
      tonumber(passengerTotals.waiting) or 0,
      tonumber(cosmetics.nativeAboard) or 0,
      tonumber(cosmetics.nativeWaiting) or 0,
      cosmetics.targetWritesEnabled == true and "enabled" or "fail-closed")
    local probes = snapshot.probes or {}
    lines[#lines + 1] = string.format(
      "Automatic load receipts: freight %s | local passenger %s",
      milestoneStatus(probes.freightMilestone),
      milestoneStatus(probes.passengerMilestone))
    local clockCapture = gui.nativeClockCapture or {}
    local indicator = clockCapture.indicator or {}
    lines[#lines + 1] = string.format(
      "Vanilla clock bridge: captured %d | duplicate %d | invalid %d | last %s | indicator %s repairs %d",
      tonumber(clockCapture.captured) or 0,
      tonumber(clockCapture.duplicates) or 0,
      tonumber(clockCapture.invalid) or 0,
      tostring(clockCapture.lastRequestedSpeed or "-"),
      tostring(indicator.lastButtonIndex or "-"),
      tonumber(indicator.repairs) or 0)
  end
  if snapshot.validation and snapshot.validation.enabled then
    lines[#lines + 1] = string.format(
      "Unattended validation: %s | stage %s | checks %d",
      tostring(snapshot.validation.status or "?"),
      tostring(snapshot.validation.stage or "?"),
      #(snapshot.validation.checks or {})
    )
  end
  if snapshot.turn and snapshot.turn.lastFailure then
    local failure = snapshot.turn.lastFailure
    local migration = failure.failure and failure.failure.migration or nil
    local failedAssets = failure.failed or (migration and migration.failed) or {}
    local recoveryFailures = failure.recoveryFailed or (migration and migration.recoveryFailed) or {}
    lines[#lines + 1] = string.format(
      "TURN FAILURE: stage %s at tick %s | failed assets %d | recovery failures %d",
      tostring(failure.stage or "unknown"),
      tostring(failure.tick or "?"),
      #failedAssets,
      #recoveryFailures
    )
  end
  local errorText = gui.lastError or snapshot.lastError or (snapshot.bridge and snapshot.bridge.lastError)
  if errorText then lines[#lines + 1] = "ERROR: " .. tostring(errorText) end
  local results = snapshot.lastResults or {}
  local economyClock = snapshot.economyScheduler or {}
  if economyClock.nextBoundaryGameTimeSeconds then
    lines[#lines + 1] = string.format(
      "Authored economy: automatic 5-minute accounting | last %s | next game-time %s | latest gross $%.2f - upkeep $%.2f = net $%.2f",
      tostring(economyClock.lastBoundaryGameTimeSeconds or "start"),
      tostring(economyClock.nextBoundaryGameTimeSeconds),
      (results.totalGrossRevenueCents or results.totalRevenueCents or 0) / 100,
      (results.totalOperatingCostCents or 0) / 100,
      (results.totalNetRevenueCents or results.totalRevenueCents or 0) / 100)
  end
  local scoreboard = snapshot.scoreboard or {}
  for _, companyCid in ipairs(snapshot.companyOrder or {}) do
    local company = snapshot.companies and snapshot.companies[companyCid] or {}
    local score = results.companies and results.companies[companyCid] or {}
    local total = scoreboard[companyCid] or {}
    lines[#lines + 1] = string.format(
      "%s: balance %.0f, loan %.0f | assets %d | tick deliveries %d | gross $%.2f - vehicle $%.2f - infrastructure $%.2f = net $%.2f | value %.2f, reach %d, wins %d",
      company.name or companyCid,
      company.effectiveBalance or company.balance or 0,
      company.loan or 0,
      company.assets and company.assets.total or 0,
      score.demand or 0,
      (score.grossRevenueCents or score.revenueCents or 0) / 100,
      (score.vehicleUpkeepCents or 0) / 100,
      (score.infrastructureUpkeepCents or 0) / 100,
      (score.netRevenueCents or score.revenueCents or 0) / 100,
      (total.modelValueCents or 0) / 100,
      total.marketsReached or 0,
      total.marketWins or 0
    )
  end
  local shownMarkets = 0
  local marketOrder = util.sortedKeys(results.markets or {})
  if #marketOrder > 0 then
    lines[#lines + 1] = "-- CONTESTED MARKETS (this is the contest; people on"
      .. " platforms are scenery) --"
  end
  for _, marketCid in ipairs(marketOrder) do
    if shownMarkets >= 8 then break end
    shownMarkets = shownMarkets + 1
    local market = results.markets[marketCid]
    local travelling = (market.demand or 0) - (market.outside or 0)
    local travellingPct = (market.demand or 0) > 0
      and math.floor(travelling * 100 / market.demand) or 0
    lines[#lines + 1] = string.format(
      "%s%s: %d of %d travelling (%d%%), %d stayed home",
      market.name or marketCid,
      market.kind == "cargo" and " [freight]" or "",
      travelling, market.demand or 0, travellingPct, market.outside or 0)
    for _, lineCid in ipairs(util.sortedKeys(market.services or {})) do
      local service = market.services[lineCid]
      local factors = service.factors or {}
      -- Share is a stock chasing an equilibrium, so an arrow beats two
      -- numbers: it answers "am I winning this corridor right now?"
      local share = service.sharePpm or 0
      local target = service.equilibriumPpm or 0
      local trend = "holding"
      if target > share + 2000 then trend = "GAINING"
      elseif target + 2000 < share then trend = "LOSING" end
      lines[#lines + 1] = string.format(
        "  %s: %d carried, %d.%d%% share -> %d.%d%% %s | gross $%.2f - train $%.2f = line net $%.2f",
        service.name or lineCid,
        service.allocated or 0,
        math.floor(share / 10000), math.floor(share % 10000 / 1000),
        math.floor(target / 10000), math.floor(target % 10000 / 1000),
        trend,
        (service.grossRevenueCents or service.revenueCents or 0) / 100,
        (service.vehicleUpkeepCents or 0) / 100,
        (service.netRevenueCents or service.revenueCents or 0) / 100)
      lines[#lines + 1] = string.format(
        "      costs the passenger $%.2f = fare %.2f + time %.2f + wait %.2f"
          .. " + transfers %.2f + crowding %.2f - comfort %.2f - feeder %.2f",
        (factors.gcCents or 0) / 100,
        (factors.fareCents or service.fareCents or 0) / 100,
        (factors.timeCostCents or 0) / 100,
        (factors.waitCostCents or 0) / 100,
        (factors.transferCostCents or 0) / 100,
        (factors.crowdCostCents or 0) / 100,
        (factors.baseComfortCents or factors.comfortCents or 0) / 100,
        (factors.feederAccessCents or 0) / 100)
    end
  end
  local boards = snapshot.stationBoards or {}
  local boardOrder = {}
  for groupCid in pairs(boards) do boardOrder[#boardOrder + 1] = groupCid end
  table.sort(boardOrder, function(left, right)
    local a, b = boards[left], boards[right]
    if a.waiting ~= b.waiting then return a.waiting > b.waiting end
    return left < right
  end)
  local shownBoards = 0
  for _, groupCid in ipairs(boardOrder) do
    if shownBoards >= 8 then break end
    shownBoards = shownBoards + 1
    local board = boards[groupCid]
    lines[#lines + 1] = string.format("Station %s: waiting %d %s | %d pax/5m over %d line(s)",
      board.name or groupCid,
      board.waiting or 0,
      M.crowdIcons(board.waiting or 0),
      board.throughput or 0,
      #(board.lines or {}))
  end
  local capture = snapshot.probes and snapshot.probes.capture or {}
  lines[#lines + 1] = string.format(
    "Observed proposals GUI/native/commits: %d/%d/%d | vehicle accepts/resolved: %d/%d | claimed: %d",
    capture.preCommitCount or 0,
    capture.nativePreCommitCount or 0,
    capture.postCommitCount or 0,
    capture.vehicleIntentCount or 0,
    capture.vehicleResolvedCount or 0,
    capture.claimedCount or 0
  )
  local operational = snapshot.probes and snapshot.probes.operational or {}
  if operational.enabled then
    local sample = operational.lastSample or {}
    lines[#lines + 1] = string.format(
      "OPERATIONAL CAPTURE ONLY (not synchronized): samples %d | speed %s | lines %d | vehicles %d | native commands %d | GUI actions %d",
      operational.sampleCount or 0,
      tostring(sample.gameSpeed or "-"),
      sample.lineCount or 0,
      sample.vehicleCount or 0,
      capture.nativeCommandCount or 0,
      capture.operationalGuiCount or 0
    )
    if operational.autoInit and operational.autoInit.success ~= true then
      lines[#lines + 1] = "CAPTURE AUTO-INIT ERROR: " .. tostring(operational.autoInit.error or "unknown")
    end
  end
  lines[#lines + 1] = string.format(
    "Edge replacements observed/rebound/failures/recoveries: %d/%d/%d/%d",
    capture.replacementObservedCount or 0,
    capture.replacementReboundCount or 0,
    capture.replacementFailureCount or 0,
    capture.replacementRecoveryCount or 0
  )
  lines[#lines + 1] = string.format(
    "Rival edits blocked before commit: proposals %d | entity actions %d",
    capture.accessDeniedCount or 0,
    capture.entityAccessDeniedCount or 0
  )
  local proposals = snapshot.proposals or {}
  lines[#lines + 1] = string.format(
    "Canonical proposals queued/applied/failed/retained: %d/%d/%d/%d",
    proposals.queued or 0, proposals.applied or 0, proposals.failed or 0, proposals.retained or 0
  )
  local operations = snapshot.operations or {}
  lines[#lines + 1] = string.format(
    "Canonical line/vehicle operations queued/applied/failed/retained: %d/%d/%d/%d",
    operations.queued or 0, operations.applied or 0,
    operations.failed or 0, operations.retained or 0)
  local consensus = snapshot.proposalConsensus or {}
  lines[#lines + 1] = string.format(
    "Physical consensus pending/complete/rejected/faulted: %d/%d/%d/%d | session %s",
    consensus.pending or 0,
    consensus.completed or 0,
    consensus.rejected or 0,
    consensus.failed or 0,
    consensus.sessionFault and "FAULTED" or "healthy"
  )
  local operationConsensus = snapshot.operationConsensus or {}
  lines[#lines + 1] = string.format(
    "Operation consensus pending/complete/faulted: %d/%d/%d | session %s",
    operationConsensus.pending or 0,
    operationConsensus.completed or 0,
    operationConsensus.failed or 0,
    operationConsensus.sessionFault and "FAULTED" or "healthy")
  local checkpoints = snapshot.checkpointConsensus or {}
  lines[#lines + 1] = string.format(
    "Checkpoint barriers pending/complete/faulted: %d/%d/%d | last agreed %s",
    checkpoints.pending or 0,
    checkpoints.completed or 0,
    checkpoints.failed or 0,
    checkpoints.lastAgreed and tostring(checkpoints.lastAgreed.boundarySeq or "yes") or "-"
  )
  local deferred = snapshot.deferredNetworkIntent
  if deferred then
    lines[#lines + 1] = string.format(
      "Queued multiplayer physical actions: %d/%d | oldest tick %s | %s",
      deferred.queueDepth or 1,
      deferred.capacity or (options.maxDeferredNetworkIntents or 32),
      tostring(deferred.queuedTick or "-"),
      tostring(deferred.reason or "waiting for authority"))
  end
  local deferredQueue = snapshot.deferredNetworkQueue or {}
  if deferredQueue.awaitingOrder then
    lines[#lines + 1] = string.format(
      "Outbound intent %s awaiting host order | %s",
      tostring(deferredQueue.awaitingOrder.localSeq or "-"),
      tostring(deferredQueue.awaitingOrder.type or "action"))
  end
  local registrations = snapshot.probes and snapshot.probes.serviceRegistration or {}
  local unsupportedCount = util.tableCount(registrations.current or {})
  if unsupportedCount > 0 then
    local last = registrations.last or {}
    lines[#lines + 1] = string.format(
      "Unsupported service registrations: %d | last %s | %s",
      unsupportedCount,
      tostring(last.lineCid or "-"),
      tostring(last.error or "route facts unavailable"))
  end
  local mobility = snapshot.probes and snapshot.probes.mobility or nil
  if mobility then
    -- Diagnostics, deliberately below the contest and deliberately labelled:
    -- these are the game's own wandering agents, which the competitive model
    -- neither reads nor scores. Reading them as market truth is the single
    -- most likely way to misinterpret this panel.
    lines[#lines + 1] = string.format(
      "Native agents (scenery, not scored): people %s | line uses pax %s cargo %s"
        .. " | vehicles %s | digest %s",
      tostring(mobility.totalPersons or "-"),
      tostring(mobility.totals and mobility.totals.passengerLineUses or "-"),
      tostring(mobility.totals and mobility.totals.cargoLineUses or "-"),
      tostring(mobility.totals and mobility.totals.vehicles or "-"),
      tostring(snapshot.probes.mobilityDigest or "-")
    )
  end
  local native = snapshot.probes and snapshot.probes.nativeHook or {}
  lines[#lines + 1] = string.format(
    "Native hook: %s | stage %s | active %s",
    native.available == true and "loaded" or "not loaded",
    tostring(native.stage or "-"),
    tostring(native.active == true)
  )
  lines[#lines + 1] = string.format(
    "Native pre-issue observer states: %d | sendCommand calls: %d",
    tonumber(native.commandObserverStateCount) or 0,
    tonumber(native.commandCalls) or 0
  )
  local buildGate = native.gates and native.gates.buildProposal or {}
  lines[#lines + 1] = string.format(
    "Build gate: %s | calls %d | pending auth %d | passed %d | suppressed %d | ABI mismatches %d",
    tostring(buildGate.enabled == true),
    tonumber(buildGate.calls) or 0,
    tonumber(buildGate.authorizations) or 0,
    tonumber(buildGate.allowed) or 0,
    tonumber(buildGate.suppressed) or 0,
    tonumber(buildGate.tagMismatches) or 0
  )
  local commandGate = native.gates and native.gates.commandVisitors or {}
  lines[#lines + 1] = string.format(
    "Command gates: %s | visitors %d | passed %d | suppressed %d | mismatches %d",
    tostring(commandGate.enabled == true),
    tonumber(commandGate.hooked) or 0,
    tonumber(commandGate.allowedTotal) or 0,
    tonumber(commandGate.suppressedTotal) or 0,
    tonumber(commandGate.tagMismatches) or 0
  )
  local nativeLines = gui.nativeLineCapture or {}
  lines[#lines + 1] = string.format(
    "Vanilla line manager captured create/delete/update/name/color: %d/%d/%d/%d/%d | invalid %d | last stops %d",
    tonumber(nativeLines.creates) or 0,
    tonumber(nativeLines.deletes) or 0,
    tonumber(nativeLines.updates) or 0,
    tonumber(nativeLines.names) or 0,
    tonumber(nativeLines.colors) or 0,
    tonumber(nativeLines.invalid) or 0,
    tonumber(nativeLines.lastStopCount) or 0)
  local authority = snapshot.probes and snapshot.probes.networkAuthority or {}
  if snapshot.networkMode == "network" then
    lines[#lines + 1] = "Network authority: "
      .. (authority.ready == true and "ready" or "FAULTED - " .. tostring(authority.error or "unknown"))
    local calendar = snapshot.probes and snapshot.probes.networkCalendar or {}
    lines[#lines + 1] = "Network calendar: "
      .. (calendar.frozen == true and "frozen (native recurring finance disabled)"
        or "FAULTED - " .. tostring(calendar.error or "freeze unavailable"))
    local sessionFault = (snapshot.proposalConsensus and snapshot.proposalConsensus.sessionFault)
      or (snapshot.operationConsensus and snapshot.operationConsensus.sessionFault)
    local ready = authority.ready == true and companion.connected == true and not sessionFault
    lines[#lines + 1] = "Multiplayer readiness: " .. (ready and "READY"
      or "WAITING - start the matching host/client companion and use the same session/manifest")
    local networkAccounts = snapshot.networkAccounts or {}
    local reconciliation = networkAccounts.reconciliation or {}
    lines[#lines + 1] = string.format(
      "Canonical finance: %s (authoritative; native trip income is quarantined) | entries %d | native reconciliations %d/%d failed",
      networkAccounts.initialized == true and "active" or "NOT READY",
      #(networkAccounts.entries or {}),
      tonumber(reconciliation.attempts) or 0,
      tonumber(reconciliation.failures) or 0
    )
  end
  if snapshot.proxyMode then
    local turn = snapshot.turn or {}
    lines[#lines + 1] = string.format("Turn desk: %s | leased assets %d | started tick %s | build pause %s",
      tostring(turn.companyCid or "inactive"), turn.leasedAssets or 0, tostring(turn.startedTick or "-"), tostring(turn.paused == true))
    local pinned = snapshot.ownership and snapshot.ownership.pinned or {}
    lines[#lines + 1] = string.format(
      "Tracked edge custody: %d | native holder desk/rightful company; rival edits blocked before commit",
      tonumber(pinned.total) or 0)
    lines[#lines + 1] = "Native borrow/repay is locked on the turn desk; authored credit applies only to network matches."
  end
  local codecFailure = capture.lastProposalCodecFailure
  if codecFailure then
    local diagnostic = codecFailure.diagnostic or {}
    local counts = diagnostic.counts or {}
    local sample = diagnostic.constructionSamples and diagnostic.constructionSamples[1] or nil
    lines[#lines + 1] = string.format(
      "Last unsupported build: %s | construction add/remove %d/%d%s",
      tostring(codecFailure.error or "unknown"),
      tonumber(counts.constructionsToAdd) or 0,
      tonumber(counts.constructionsToRemove) or 0,
      sample and (" | " .. tostring(sample.fileName or sample.kindHint or "construction")) or ""
    )
  end
  lines[#lines + 1] = "Implemented multiplayer slice: canonical roads/tracks/signals, portable depot/construction/asset build and removal, modular station placement/edit/removal, plus host-ordered line and portable vehicle operations. Unsupported opaque mod callbacks fail closed; non-rail carriers and host-owned autonomous simulation remain live-proof gates."
  gui.details:setText(table.concat(lines, "\n"))
end


return M
