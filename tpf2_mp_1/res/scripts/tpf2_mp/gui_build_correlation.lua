local M = {}

local WRAPPERS = {
  "proposal", "streetProposal", "simpleProposal", "resultProposal",
  "proposalData", "resultProposalData", "data", "context",
}

local function nonEmpty(value)
  if type(value) ~= "table" then return false end
  for key, nested in pairs(value) do
    if key ~= "__type" and key ~= "__truncated" and nested ~= nil then return true end
  end
  return false
end

local function containers(root)
  local result, seen = {}, {}
  local function add(value)
    if type(value) ~= "table" or seen[value] or #result >= 24 then return end
    seen[value] = true
    result[#result + 1] = value
  end
  add(root)
  local index = 1
  while index <= #result do
    for _, field in ipairs(WRAPPERS) do add(result[index][field]) end
    index = index + 1
  end
  return result
end

local function values(value, maximum)
  local result = {}
  if type(value) ~= "table" then return result end
  for key, nested in pairs(value) do
    if key ~= "__type" and key ~= "__truncated" and nested ~= nil then
      result[#result + 1] = nested
      if #result >= (maximum or 16) then break end
    end
  end
  return result
end

function M.family(snapshot)
  if type(snapshot) ~= "table" then return "none" end
  local known = containers(snapshot)
  local constructionAdd, constructionRemove = false, false
  local edgeObject, removal = false, false
  local track, street, anyChange = false, false, false
  for _, value in ipairs(known) do
    for _, field in ipairs({
      "constructionsToAdd", "toAdd", "__constructionAdditions",
    }) do
      if nonEmpty(value[field]) then constructionAdd, anyChange = true, true end
    end
    for _, field in ipairs({
      "constructionsToRemove", "toRemove", "__constructionRemovals",
    }) do
      if nonEmpty(value[field]) then constructionRemove, anyChange = true, true end
    end
    for _, field in ipairs({ "edgeObjectsToAdd", "edgeObjectsToRemove" }) do
      if nonEmpty(value[field]) then edgeObject, anyChange = true, true end
    end
    for _, field in ipairs({ "edgesToRemove", "removedSegments", "nodesToRemove", "removedNodes" }) do
      if nonEmpty(value[field]) then removal, anyChange = true, true end
    end
    for _, field in ipairs({ "edgesToAdd", "addedSegments" }) do
      if nonEmpty(value[field]) then
        anyChange = true
        for _, edge in ipairs(values(value[field], 16)) do
          if type(edge) == "table" then
            local edgeType = tonumber(edge.type or (edge.comp and edge.comp.type))
            if edge.trackEdge ~= nil or edgeType == 1 then track = true end
            if edge.streetEdge ~= nil or edgeType == 0 then street = true end
          end
        end
      end
    end
    for _, field in ipairs({ "nodesToAdd", "addedNodes" }) do
      if nonEmpty(value[field]) then anyChange = true end
    end
  end
  -- A road or track proposal may remove buildings as collateral.  The native
  -- preview still belongs to streetBuilder/trackBuilder in that case; treating
  -- any construction removal as the primary family rejects every hover sample
  -- over a house as a stale-tool mismatch.  A construction addition remains
  -- primary (stations and depots also contain transport edges), while a
  -- removal-only proposal remains a construction/bulldozer action.
  if constructionAdd then return "construction" end
  if track and street then return "mixed-transport" end
  if track then return "track" end
  if street then return "street" end
  if constructionRemove then return "construction" end
  if edgeObject then return "edge-object" end
  if removal then return "removal" end
  if anyChange then return "unknown-change" end
  return "none"
end

function M.compatible(expected, observed)
  if observed == "none" then return true end
  return expected == observed
end

function M.sourceAllows(sourceId, family)
  local source = tostring(sourceId or ""):lower()
  if family == "none" then return true end
  if source:find("sendcommand", 1, true) then return true end
  if source:find("bulldoz", 1, true) or source:find("demol", 1, true) then
    return family == "removal" or family == "construction"
      or family == "track" or family == "street" or family == "mixed-transport"
  end
  local terminalBuilder = source:find("terminal", 1, true) ~= nil
  if source:find("construction", 1, true) or source:find("station", 1, true)
    or terminalBuilder or source:find("depot", 1, true)
    or source:find("asset", 1, true) then
    -- Build 35924 routes signals and waypoints through
    -- `streetTerminalBuilder`, despite their proposal being an edge-object
    -- edit rather than a construction. Keep ordinary station/depot builders
    -- construction-only while admitting that one live-proven dual-use name.
    return family == "construction" or (terminalBuilder and family == "edge-object")
  end
  if source:find("track", 1, true) or source:find("rail", 1, true) then
    return family == "track" or family == "edge-object" or family == "removal"
      or family == "mixed-transport"
  end
  if source:find("street", 1, true) or source:find("road", 1, true) then
    return family == "street" or family == "edge-object" or family == "removal"
      or family == "mixed-transport"
  end
  -- Modded builders often have opaque IDs. Their preview/apply family must
  -- still agree, but an unknown UI name is not itself evidence of corruption.
  return true
end

function M.new(gui, options)
  options = options or {}
  local maximumHistory = math.max(8, tonumber(options.maximumHistory) or 64)
  local maximumAge = math.max(30, tonumber(options.maximumAgeFrames) or 600)
  local clearConstructionCache = options.clearConstructionCache or function() end
  local runtime = gui.buildCorrelation or {
    nextCorrelation = 1,
    toolGeneration = 0,
    activeToolKey = nil,
    activeCorrelation = nil,
    previews = {},
    order = {},
    invalidations = 0,
    semanticRejects = 0,
    ambiguousRejects = 0,
    lastInvalidationReason = nil,
  }
  gui.buildCorrelation = runtime

  local function nativeArm(value)
    local arm = rawget(_G, "tpf2mp_native_arm_build_correlation")
    if type(arm) ~= "function" then return false, "native correlation arming is unavailable" end
    local ok, err = pcall(arm, tostring(value or 0))
    if not ok then return false, tostring(err) end
    return true
  end

  local function remove(correlationId)
    runtime.previews[tostring(correlationId)] = nil
  end

  local function prune()
    local minimumFrame = (gui.frames or 0) - maximumAge
    local retained = {}
    for _, correlationId in ipairs(runtime.order) do
      local pending = runtime.previews[tostring(correlationId)]
      if pending and (tonumber(pending.frame) or 0) >= minimumFrame then
        retained[#retained + 1] = correlationId
      else
        remove(correlationId)
      end
    end
    while #retained > maximumHistory do
      remove(table.remove(retained, 1))
    end
    runtime.order = retained
  end

  local function invalidate(reason, flags)
    flags = flags or {}
    runtime.invalidations = runtime.invalidations + 1
    runtime.lastInvalidationReason = tostring(reason or "unspecified")
    runtime.activeCorrelation = nil
    runtime.activeToolKey = nil
    runtime.previews = {}
    runtime.order = {}
    gui.builderContext = nil
    gui.pendingNetworkBuildPreview = nil
    gui.pendingNetworkBuildExact = nil
    if flags.preserveWaiting ~= true then gui.pendingNetworkBuildSuppression = nil end
    if flags.clearConstruction ~= false then clearConstructionCache() end
    nativeArm(0)
  end

  local function begin(snapshot, companyCid, sourceId, templateSignature)
    local family = M.family(snapshot)
    local source = tostring(sourceId or "builder")
    local company = tostring(companyCid or "")
    local toolKey = company .. "|" .. source .. "|" .. family
    if runtime.activeToolKey and runtime.activeToolKey ~= toolKey then
      invalidate("tool-or-family-change", { preserveWaiting = true, clearConstruction = true })
    end
    if runtime.activeToolKey ~= toolKey then runtime.toolGeneration = runtime.toolGeneration + 1 end
    runtime.activeToolKey = toolKey
    local correlationId = runtime.nextCorrelation
    if correlationId > 9007199254740000 then
      invalidate("correlation-sequence-exhausted", { clearConstruction = true })
      correlationId = 1
    end
    runtime.nextCorrelation = correlationId + 1
    runtime.activeCorrelation = correlationId
    local metadata = {
      correlationId = correlationId,
      toolGeneration = runtime.toolGeneration,
      companyCid = companyCid,
      sourceId = source,
      family = family,
      templateSignature = templateSignature,
      frame = gui.frames or 0,
    }
    local armed, armError = nativeArm(correlationId)
    metadata.nativeArmed = armed
    metadata.nativeArmError = armError
    return metadata
  end

  local function register(pending)
    if type(pending) ~= "table" or tonumber(pending.correlationId) == nil then
      return false, "proposal correlation metadata is missing"
    end
    prune()
    local key = tostring(pending.correlationId)
    if runtime.previews[key] == nil then runtime.order[#runtime.order + 1] = pending.correlationId end
    runtime.previews[key] = pending
    return true
  end

  local function lookup(correlationId)
    prune()
    return runtime.previews[tostring(correlationId)]
  end

  local function validatePending(pending, event, currentCompanyCid)
    if type(pending) ~= "table" then
      runtime.ambiguousRejects = runtime.ambiguousRejects + 1
      return false, "suppressed build has no preview with its native correlation token"
    end
    if tonumber(event and event.correlation) ~= tonumber(pending.correlationId) then
      runtime.ambiguousRejects = runtime.ambiguousRejects + 1
      return false, "suppressed build correlation token does not match its preview"
    end
    if tonumber(event and event.tag) ~= 15 then
      runtime.semanticRejects = runtime.semanticRejects + 1
      return false, "suppressed build event has the wrong native command tag"
    end
    if tostring(currentCompanyCid or "") ~= tostring(pending.companyCid or "") then
      runtime.semanticRejects = runtime.semanticRejects + 1
      return false, "suppressed build belongs to a different active company"
    end
    if (gui.frames or 0) - (tonumber(pending.frame) or 0) > maximumAge then
      runtime.ambiguousRejects = runtime.ambiguousRejects + 1
      return false, "suppressed build preview correlation expired"
    end
    local observedFamily = M.family(pending.proposalSnapshot)
    if not M.compatible(pending.family, observedFamily)
      or not M.sourceAllows(pending.sourceId, observedFamily) then
      runtime.semanticRejects = runtime.semanticRejects + 1
      return false, "suppressed build payload does not match its builder action family"
    end
    return true
  end

  local function validateApply(context, sourceId, appliedSnapshot, currentCompanyCid)
    if type(context) ~= "table" or tonumber(context.correlationId) == nil then
      runtime.ambiguousRejects = runtime.ambiguousRejects + 1
      return false, "builder.apply has no generation-bound preview"
    end
    if tostring(context.sourceId or "") ~= tostring(sourceId or "") then
      runtime.semanticRejects = runtime.semanticRejects + 1
      return false, "builder.apply source differs from its preview source"
    end
    if tostring(context.companyCid or "") ~= tostring(currentCompanyCid or "") then
      runtime.semanticRejects = runtime.semanticRejects + 1
      return false, "builder.apply company differs from its preview company"
    end
    if (gui.frames or 0) - (tonumber(context.frame) or 0) > maximumAge then
      runtime.ambiguousRejects = runtime.ambiguousRejects + 1
      return false, "builder.apply preview correlation expired"
    end
    local appliedFamily = M.family(appliedSnapshot)
    if not M.compatible(context.family, appliedFamily)
      or not M.sourceAllows(context.sourceId, context.family) then
      runtime.semanticRejects = runtime.semanticRejects + 1
      return false, "builder.apply payload does not match its preview action family"
    end
    return true
  end

  local function invalidationEvent(id, name)
    local source = tostring(id or ""):lower()
    local event = tostring(name or ""):lower()
    local combined = source .. "." .. event
    if event:find("builder.cancel", 1, true) or event:find("builder.abort", 1, true)
      or event:find("builder.destroy", 1, true) or event:find("builder.close", 1, true) then
      return true, "builder-cancel-or-close"
    end
    if (event == "close" or event == "window.close" or event == "visibility.hide")
      and (source:find("builder", 1, true) or source:find("construction", 1, true)) then
      return true, "builder-panel-close"
    end
    if event == "button.click" then
      for _, token in ipairs({
        "bulldoz", "construction", "station", "terminal", "depot", "asset",
        "track", "rail", "street", "road",
      }) do
        if combined:find(token, 1, true) then return true, "build-tool-control" end
      end
    end
    return false
  end

  return {
    begin = begin,
    register = register,
    lookup = lookup,
    consume = remove,
    invalidate = invalidate,
    validatePending = validatePending,
    validateApply = validateApply,
    invalidationEvent = invalidationEvent,
    armNative = nativeArm,
    family = M.family,
    sourceAllows = M.sourceAllows,
    status = function() prune(); return runtime end,
  }
end

return M
