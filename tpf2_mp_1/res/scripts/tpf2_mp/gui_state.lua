local M = {}

function M.new()
  return {
  window = nil,
  passengerHud = nil,
  economyHud = nil,
  stockPresentation = nil,
  status = nil,
  details = nil,
  queue = {},
  selectedLineId = nil,
  selectedVehicleId = nil,
  selectedDepotId = nil,
  routeDraft = {},
  selectedEntityId = nil,
  selectedEntityKind = nil,
  snapshot = nil,
  frames = 0,
  nextCaptureId = 1,
  pendingVehicleCaptures = {},
  proposalIssued = {},
  proposalResults = {},
  pendingProposalCaptures = {},
  -- A delayed canonical BuildProposal can replace the edge underneath the
  -- origin's still-open road/track/signal ghost.  While its native callback
  -- and wallet samples settle, GUI builder userdata may refer to the removed
  -- edge and must not be traversed (Build 35924 raises an internal error).
  proposalReplayQuarantine = nil,
  operationIssued = {},
  operationResults = {},
  pendingOperationCaptures = {},
  builderContext = nil,
  pendingNetworkBuildPreview = nil,
  pendingNetworkBuildExact = nil,
  pendingNetworkBuildSuppression = nil,
  buildGateSuppressedSeen = nil,
  observerSuppressionCredits = 0,
  networkAuthorityBootstrap = nil,
  awaitingManualHandoff = false,
  manualHandoffReady = false,
  nativeBuildCapture = {
    captured = 0,
    duplicates = 0,
    orphaned = 0,
    counterResets = 0,
    exactCaptures = 0,
    previewFallbacks = 0,
    constructionPreviewsProjected = 0,
    constructionPreviewsSkipped = 0,
    constructionPreviewsArmed = 0,
    coalescedConstructionSuppressions = 0,
    replayPreviewsQuarantined = 0,
    replayAppliesRejected = 0,
  },
  nativeClockCapture = {
    captured = 0,
    invalid = 0,
    duplicates = 0,
    lastRequestedSpeed = nil,
  },
  nativeLineKnownIds = nil,
  -- A stock Line Manager callback can publish its new LINE entity one GUI
  -- update before the native visitor capture becomes readable.  Keep only
  -- those post-baseline additions for a short, machine-local correlation
  -- window so that ordering cannot make an otherwise valid New Line vanish.
  nativeLineRecentAdded = {},
  pendingNativeLinePassThroughCaptures = {},
  nativeLineCapture = {
    captured = 0,
    invalid = 0,
    creates = 0,
    deletes = 0,
    updates = 0,
    names = 0,
    colors = 0,
    lastTag = nil,
    lastTarget = nil,
    lastStopCount = 0,
  },
  -- BuyVehicle is rejected at the exact native visitor, so neither half of a
  -- capture can mutate the world alone. The stock GUI supplies the consist;
  -- the pinned visitor supplies the actual player/depot scalar identities.
  pendingNativeVehicleGuiCaptures = {},
  pendingNativeVehicleCommands = {},
  nativeVehicleCapture = {
    captured = 0,
    invalid = 0,
    dropped = 0,
    buys = 0,
    assignments = 0,
    lastTag = nil,
    lastTarget = nil,
    lastSecondary = nil,
  },
  lastNetworkProposalDigest = nil,
  lastNetworkProposalFrame = -1000,
  lastProposalProbeFrame = -1000,
  lastConstructionPreviewDecision = nil,
  lastConstructionPreviewSnapshot = nil,
  lastConstructionPreviewPlacement = nil,
  lastConstructionPreviewSignature = nil,
  lastConstructionPreviewModuleSentinels = nil,
  lastAccessDenialProbeFrame = -1000,
  lastEntityAccessDenialProbeFrame = -1000,
  lastOperationalGuiDigest = nil,
  lastOperationalGuiFrame = -1000,
  lastError = nil,
  }
end

return M
