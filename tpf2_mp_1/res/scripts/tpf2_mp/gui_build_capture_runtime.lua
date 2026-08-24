local M = {}

function M.new(deps)
  local gui = assert(deps.gui, "GUI state is required")
  local sampler = assert(deps.sampler, "build-gate sampler is required")
  local correlation = assert(deps.correlation, "build correlation runtime is required")
  local queueCapture = assert(deps.queueCapture, "build queue callback is required")
  local captureFailure = assert(deps.captureFailure, "build failure callback is required")
  local renderGui = assert(deps.renderGui, "render callback is required")
  local currentBuildGateSuppressed = sampler.sample
  local drainSuppressedBuildEvents = sampler.drain

  local function finishSuppressedNativeBuildCapture()
    local waiting = gui.pendingNetworkBuildSuppression
    if not waiting then return false end
    local pending = waiting.pending
    if not pending then
      return captureFailure(
        "a suppressed native build lost its correlated proposal snapshot; no command was replicated",
        { suppressed = waiting.suppressed }
      )
    end
    if pending.exact ~= true
      and gui.frames - (waiting.detectedFrame or gui.frames) < gui.nativeBuildApplySettleFrames then
      return false
    end
    gui.pendingNetworkBuildSuppression = nil
    return queueCapture(pending)
  end
  gui.finishSuppressedNativeBuildCapture = finishSuppressedNativeBuildCapture

  local function process(force)
    local snapshotState = gui.snapshot or {}
    if snapshotState.networkMode ~= "network" then
      gui.invalidateBuildCorrelation("network-build-capture-disabled", {
        clearConstruction = true,
      })
      gui.buildGateSuppressedSeen = nil
      gui.buildGateLastGenerationSeen = nil
      return false
    end
    if finishSuppressedNativeBuildCapture() then return true end
    if not force and not gui.pendingNetworkBuildPreview and not gui.pendingNetworkBuildExact
      and not gui.pendingNetworkBuildSuppression then return false end
    if not force and gui.frames - (gui.lastBuildGatePollFrame or -1000) < 2 then return false end
    gui.lastBuildGatePollFrame = gui.frames
    local current, statusError, gateSample = currentBuildGateSuppressed()
    if current == nil then
      if gui.pendingNetworkBuildPreview then
        gui.lastError = "cannot correlate vanilla build: " .. tostring(statusError)
        renderGui()
      end
      return false
    end
    -- Merely exporting the take function is not proof that this sample carries
    -- generation events: hook 0.18 compatibility fixtures expose B1 counters.
    -- Switch paths only when the native sample/status explicitly advertises
    -- the correlation queue, otherwise a valid legacy counter delta would be
    -- swallowed by an empty event read.
    local eventQueueReady = gateSample and (gateSample.sampleVersion == 2
      or gateSample.correlationQueueAvailable == true)
    local nativeEvents, eventError = nil, "unavailable"
    if eventQueueReady then
      nativeEvents, eventError = drainSuppressedBuildEvents(64)
    end
    if nativeEvents ~= nil then
      local dropped = tonumber(gateSample and gateSample.dropped) or 0
      if dropped > 0 then
        return captureFailure(
          "native BuildProposal correlation queue previously overflowed; restart the multiplayer session",
          { dropped = dropped }
        )
      end
      gui.buildGateSuppressedSeen = current
      for _, event in ipairs(nativeEvents) do
        local lastGeneration = tonumber(gui.buildGateLastGenerationSeen) or 0
        if event.generation <= lastGeneration then
          return captureFailure(
            "native BuildProposal suppression generation was replayed or reordered",
            { generation = event.generation, previousGeneration = lastGeneration }
          )
        end
        gui.buildGateLastGenerationSeen = event.generation
        local pending = correlation.lookup(event.correlation)
        local valid, validationError = correlation.validatePending(
          pending, event, snapshotState.activeCompanyCid
        )
        if not valid then
          return captureFailure(validationError, {
            generation = event.generation,
            correlationId = event.correlation,
            armedCorrelation = gateSample and gateSample.armedCorrelation or nil,
          })
        end
        local waiting = gui.pendingNetworkBuildSuppression
        if waiting then
          local sameCorrelation = tonumber(waiting.correlationId) == tonumber(event.correlation)
          local constructionBatch = sameCorrelation and (waiting.suppressedCalls or 1) < 16
            and gui.proposalSnapshotHasConstructionChange(waiting.pending.proposalSnapshot)
          if not constructionBatch then
            return captureFailure(
              "suppressed native builds crossed correlation boundaries before settlement",
              {
                generation = event.generation,
                correlationId = event.correlation,
                waitingCorrelationId = waiting.correlationId,
              }
            )
          end
          waiting.suppressedCalls = (waiting.suppressedCalls or 1) + 1
          waiting.pending.suppressedCalls = waiting.suppressedCalls
          waiting.lastGeneration = event.generation
          gui.nativeBuildCapture.coalescedConstructionSuppressions =
            (gui.nativeBuildCapture.coalescedConstructionSuppressions or 0) + 1
        else
          pending.suppressionDetectedFrame = gui.frames
          pending.suppressed = current
          pending.suppressedCalls = 1
          pending.nativeSuppressionGeneration = event.generation
          gui.pendingNetworkBuildSuppression = {
            pending = pending,
            detectedFrame = gui.frames,
            suppressed = current,
            suppressedCalls = 1,
            correlationId = event.correlation,
            firstGeneration = event.generation,
            lastGeneration = event.generation,
          }
        end
        if gui.pendingNetworkBuildPreview
          and tonumber(gui.pendingNetworkBuildPreview.correlationId) == tonumber(event.correlation) then
          gui.pendingNetworkBuildPreview = nil
        end
        if gui.pendingNetworkBuildExact
          and tonumber(gui.pendingNetworkBuildExact.correlationId) == tonumber(event.correlation) then
          gui.pendingNetworkBuildExact = nil
        end
        gui.nativeBuildCapture.correlatedNativeEvents =
          (gui.nativeBuildCapture.correlatedNativeEvents or 0) + 1
      end
      local waiting = gui.pendingNetworkBuildSuppression
      if waiting then
        local upgraded = correlation.lookup(waiting.correlationId)
        if upgraded and upgraded.exact == true then
          upgraded.suppressionDetectedFrame = waiting.detectedFrame
          upgraded.suppressed = waiting.suppressed
          upgraded.suppressedCalls = waiting.suppressedCalls
          upgraded.nativeSuppressionGeneration = waiting.firstGeneration
          waiting.pending = upgraded
        end
      end
      return finishSuppressedNativeBuildCapture()
    elseif eventError ~= "unavailable" then
      return captureFailure(
        "cannot read the native suppressed-build correlation queue",
        { error = tostring(eventError) }
      )
    end

    -- Compatibility path for hook 0.18 and the pure-Lua harness. A counter
    -- cannot disambiguate reordered previews; supported releases use S1 above.
    if gui.buildGateSuppressedSeen == nil then
      gui.buildGateSuppressedSeen = current
      return false
    end
    if current < gui.buildGateSuppressedSeen then
      gui.nativeBuildCapture.counterResets = (gui.nativeBuildCapture.counterResets or 0) + 1
      gui.buildGateSuppressedSeen = current
      gui.pendingNetworkBuildPreview = nil
      gui.pendingNetworkBuildExact = nil
      gui.lastError = "native BuildProposal suppression counter reset; discarded the pending preview"
      renderGui()
      return false
    end
    local delta = current - gui.buildGateSuppressedSeen
    if delta == 0 then return finishSuppressedNativeBuildCapture() end
    gui.buildGateSuppressedSeen = current
    local exact = gui.pendingNetworkBuildExact
    if exact and gui.frames - (exact.frame or gui.frames) > gui.nativeBuildExactLatchFrames then
      exact = nil
      gui.pendingNetworkBuildExact = nil
    end
    local pending = exact or gui.pendingNetworkBuildPreview
    local waiting = gui.pendingNetworkBuildSuppression
    if waiting and not pending then
      local constructionBatch = delta <= 16 and waiting.pending
        and gui.proposalSnapshotHasConstructionChange(waiting.pending.proposalSnapshot)
      if not constructionBatch then
        return captureFailure(
          "another native build was suppressed before the prior click acquired its apply payload",
          { suppressed = current, suppressedDelta = delta }
        )
      end
      waiting.pending.suppressedCalls = (waiting.pending.suppressedCalls or 1) + delta
      waiting.suppressed = current
      gui.nativeBuildCapture.coalescedConstructionSuppressions =
        (gui.nativeBuildCapture.coalescedConstructionSuppressions or 0) + delta
      return finishSuppressedNativeBuildCapture()
    end
    if delta ~= 1 then
      local constructionBatch = delta <= 16 and pending
        and gui.proposalSnapshotHasConstructionChange(pending.proposalSnapshot)
      if not constructionBatch then
        return captureFailure(
          "multiple native builds were suppressed before they could be correlated; no command was replicated",
          { suppressedDelta = delta }
        )
      end
      pending.suppressedCalls = delta
      gui.nativeBuildCapture.coalescedConstructionSuppressions =
        (gui.nativeBuildCapture.coalescedConstructionSuppressions or 0) + delta - 1
    end
    if not pending then
      return captureFailure(
        "a native build was suppressed without a matching pre-commit proposal; no command was replicated",
        { suppressed = current }
      )
    end
    gui.pendingNetworkBuildPreview = nil
    gui.pendingNetworkBuildExact = nil
    gui.pendingNetworkBuildSuppression = {
      pending = pending,
      detectedFrame = gui.frames,
      suppressed = current,
      suppressedCalls = pending.suppressedCalls or delta,
      correlationId = pending.correlationId,
    }
    pending.suppressionDetectedFrame = gui.frames
    pending.suppressed = current
    return finishSuppressedNativeBuildCapture()
  end

  local function arm(snapshot, companyCid, sourceId, exact, alreadySettled, metadata)
    local snapshotState = gui.snapshot or {}
    if snapshotState.networkMode ~= "network" or not gui.proposalSnapshotHasChange(snapshot) then
      return false
    end
    if alreadySettled ~= true then process(true) end
    if gui.buildGateSuppressedSeen == nil then
      local suppressed, statusError = currentBuildGateSuppressed()
      if suppressed == nil then
        gui.lastError = "cannot arm vanilla build capture: " .. tostring(statusError)
        renderGui()
        return false
      end
      gui.buildGateSuppressedSeen = suppressed
    end
    metadata = metadata or correlation.begin(snapshot, companyCid, sourceId, nil)
    local pending = {
      companyCid = companyCid,
      sourceId = tostring(sourceId or "builder"),
      frame = gui.frames,
      proposalSnapshot = snapshot,
      exact = exact == true,
    }
    for _, key in ipairs({
      "correlationId", "toolGeneration", "family", "templateSignature",
      "nativeArmed", "nativeArmError",
    }) do
      if metadata and metadata[key] ~= nil then pending[key] = metadata[key] end
    end
    local registered, registerError = correlation.register(pending)
    if not registered then
      return captureFailure("cannot register vanilla build correlation", {
        error = tostring(registerError), sourceId = sourceId,
      })
    end
    if pending.exact and gui.pendingNetworkBuildSuppression
      and tonumber(gui.pendingNetworkBuildSuppression.correlationId)
        == tonumber(pending.correlationId) then
      pending.suppressionDetectedFrame = gui.pendingNetworkBuildSuppression.detectedFrame
      pending.suppressed = gui.pendingNetworkBuildSuppression.suppressed
      gui.pendingNetworkBuildSuppression.pending = pending
      gui.pendingNetworkBuildPreview = nil
      gui.pendingNetworkBuildExact = nil
      return finishSuppressedNativeBuildCapture()
    end
    if pending.exact then
      gui.pendingNetworkBuildExact = pending
      process(true)
    else
      gui.pendingNetworkBuildPreview = pending
    end
    return true
  end

  local function armLightweight(snapshot, placement, companyCid, sourceId, metadata)
    local snapshotState = gui.snapshot or {}
    if snapshotState.networkMode ~= "network" or type(placement) ~= "table"
      or not gui.proposalSnapshotHasConstructionChange(snapshot) then return false end
    if gui.buildGateSuppressedSeen == nil then
      local suppressed, statusError = currentBuildGateSuppressed()
      if suppressed == nil then
        gui.lastError = "cannot arm vanilla construction capture: " .. tostring(statusError)
        renderGui()
        return false
      end
      gui.buildGateSuppressedSeen = suppressed
    end
    metadata = metadata or correlation.begin(
      snapshot, companyCid, sourceId, placement.templateSignature)
    gui.pendingNetworkBuildPreview = gui.lightweightConstructionPending(
      snapshot, placement, companyCid, sourceId, metadata)
    local registered, registerError = correlation.register(gui.pendingNetworkBuildPreview)
    if not registered then
      return captureFailure("cannot register construction preview correlation", {
        error = tostring(registerError), sourceId = sourceId,
      })
    end
    gui.nativeBuildCapture.constructionPreviewsArmed =
      (gui.nativeBuildCapture.constructionPreviewsArmed or 0) + 1
    return true
  end

  return {
    process = process,
    arm = arm,
    armLightweight = armLightweight,
    finish = finishSuppressedNativeBuildCapture,
  }
end

return M
