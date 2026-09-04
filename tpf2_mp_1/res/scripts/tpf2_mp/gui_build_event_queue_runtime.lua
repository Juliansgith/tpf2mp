local M = {}

-- Correlates the native factory/Add/visitor queues with the GUI semantic
-- envelope. The counter-only compatibility path remains in the parent build
-- runtime; supported hook releases must take this identity-bearing path.
function M.new(deps)
  local gui = assert(deps.gui, "GUI state is required")
  local correlation = assert(deps.correlation, "build correlation runtime is required")
  local earlyCapture = deps.earlyCapture
  local drainEvents = assert(deps.drainEvents, "suppressed-build drain is required")
  local captureFailure = assert(deps.captureFailure, "build failure callback is required")
  local finish = assert(deps.finish, "build completion callback is required")

  local function process(current, gateSample, snapshotState)
    local eventQueueReady = gateSample and (gateSample.sampleVersion == 2
      or gateSample.sampleVersion == 3
      or gateSample.correlationQueueAvailable == true)
    local factoryCaptureRequired = gateSample
      and gateSample.factoryCaptureAvailable == true
    local factoryDropped = tonumber(gateSample and gateSample.factoryDropped) or 0
    if factoryCaptureRequired and factoryDropped > 0 then
      return true, captureFailure(
        "native pre-mutation BuildProposal capture queue previously overflowed; restart the multiplayer session",
        { dropped = factoryDropped })
    end
    if earlyCapture then
      local _, earlyError = earlyCapture.drain(16)
      if earlyError and earlyError ~= "unavailable" then
        gui.nativeBuildCapture.lastEarlyCaptureError = tostring(earlyError)
        if factoryCaptureRequired then
          return true, captureFailure(
            "cannot read the pre-mutation native BuildProposal capture",
            { error = tostring(earlyError) })
        end
        gui.nativeBuildCapture.earlyCaptureFallbacks =
          (gui.nativeBuildCapture.earlyCaptureFallbacks or 0) + 1
      end
    end

    local nativeEvents, eventError = nil, "unavailable"
    if eventQueueReady then nativeEvents, eventError = drainEvents(64) end
    if nativeEvents == nil then
      if eventError ~= "unavailable" then
        return true, captureFailure(
          "cannot read the native suppressed-build correlation queue",
          { error = tostring(eventError) })
      end
      return false
    end
    local dropped = tonumber(gateSample and gateSample.dropped) or 0
    if dropped > 0 then
      return true, captureFailure(
        "native BuildProposal correlation queue previously overflowed; restart the multiplayer session",
        { dropped = dropped })
    end

    gui.buildGateSuppressedSeen = current
    for _, event in ipairs(nativeEvents) do
      local lastGeneration = tonumber(gui.buildGateLastGenerationSeen) or 0
      if event.generation <= lastGeneration then
        return true, captureFailure(
          "native BuildProposal suppression generation was replayed or reordered",
          { generation = event.generation, previousGeneration = lastGeneration })
      end
      gui.buildGateLastGenerationSeen = event.generation
      local pending = correlation.lookup(event.correlation)
      local valid, validationError = correlation.validatePending(
        pending, event, snapshotState.activeCompanyCid)
      if not valid then
        return true, captureFailure(validationError, {
          generation = event.generation, correlationId = event.correlation,
          armedCorrelation = gateSample and gateSample.armedCorrelation or nil,
        })
      end

      local nativeFactoryCapture = earlyCapture and earlyCapture.take(event.correlation) or nil
      if nativeFactoryCapture then
        local merged, mergeError = earlyCapture.merge(
          pending.proposalSnapshot, nativeFactoryCapture)
        if merged then
          pending.proposalSnapshot = merged
          pending.nativeFactoryCapture = nativeFactoryCapture
          pending.nativeFactoryGeneration = nativeFactoryCapture.generation
          pending.nativeFactoryCallerType = nativeFactoryCapture.callerType
          gui.nativeBuildCapture.earlyCaptures =
            (gui.nativeBuildCapture.earlyCaptures or 0) + 1
        else
          pending.nativeFactoryCaptureError = tostring(mergeError)
          gui.nativeBuildCapture.lastEarlyCaptureError = tostring(mergeError)
          if factoryCaptureRequired then
            return true, captureFailure(
              "pre-mutation native BuildProposal capture disagrees with its semantic envelope", {
                error = tostring(mergeError), correlationId = event.correlation,
                generation = event.generation,
              })
          end
          gui.nativeBuildCapture.earlyCaptureFallbacks =
            (gui.nativeBuildCapture.earlyCaptureFallbacks or 0) + 1
        end
      else
        gui.nativeBuildCapture.earlyCaptureMisses =
          (gui.nativeBuildCapture.earlyCaptureMisses or 0) + 1
        if factoryCaptureRequired then
          return true, captureFailure(
            "suppressed BuildProposal has no pre-mutation native factory capture", {
              correlationId = event.correlation, generation = event.generation,
            })
        end
      end

      local waiting = gui.pendingNetworkBuildSuppression
      if waiting then
        local sameCorrelation = tonumber(waiting.correlationId) == tonumber(event.correlation)
        local constructionBatch = sameCorrelation and (waiting.suppressedCalls or 1) < 16
          and gui.proposalSnapshotHasConstructionChange(waiting.pending.proposalSnapshot)
        if not constructionBatch then
          return true, captureFailure(
            "suppressed native builds crossed correlation boundaries before settlement", {
              generation = event.generation, correlationId = event.correlation,
              waitingCorrelationId = waiting.correlationId,
            })
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
          pending = pending, detectedFrame = gui.frames, suppressed = current,
          suppressedCalls = 1, correlationId = event.correlation,
          firstGeneration = event.generation, lastGeneration = event.generation,
          nativeFactoryCapture = pending.nativeFactoryCapture,
        }
      end
      if gui.pendingNetworkBuildPreview
        and tonumber(gui.pendingNetworkBuildPreview.correlationId)
          == tonumber(event.correlation) then gui.pendingNetworkBuildPreview = nil end
      if gui.pendingNetworkBuildExact
        and tonumber(gui.pendingNetworkBuildExact.correlationId)
          == tonumber(event.correlation) then gui.pendingNetworkBuildExact = nil end
      gui.nativeBuildCapture.correlatedNativeEvents =
        (gui.nativeBuildCapture.correlatedNativeEvents or 0) + 1
    end

    local waiting = gui.pendingNetworkBuildSuppression
    if waiting then
      local upgraded = correlation.lookup(waiting.correlationId)
      if upgraded and upgraded.exact == true then
        if waiting.nativeFactoryCapture then
          local merged, mergeError = earlyCapture.merge(
            upgraded.proposalSnapshot, waiting.nativeFactoryCapture)
          if merged then upgraded.proposalSnapshot = merged
          else
            upgraded.nativeFactoryCaptureError = tostring(mergeError)
            gui.nativeBuildCapture.lastEarlyCaptureError = tostring(mergeError)
            if factoryCaptureRequired then
              return true, captureFailure(
                "exact apply payload disagrees with its pre-mutation native BuildProposal capture", {
                  error = tostring(mergeError), correlationId = waiting.correlationId,
                })
            end
            gui.nativeBuildCapture.earlyCaptureFallbacks =
              (gui.nativeBuildCapture.earlyCaptureFallbacks or 0) + 1
          end
        end
        upgraded.suppressionDetectedFrame = waiting.detectedFrame
        upgraded.suppressed = waiting.suppressed
        upgraded.suppressedCalls = waiting.suppressedCalls
        upgraded.nativeSuppressionGeneration = waiting.firstGeneration
        waiting.pending = upgraded
      end
    end
    return true, finish()
  end

  return { process = process }
end

return M
