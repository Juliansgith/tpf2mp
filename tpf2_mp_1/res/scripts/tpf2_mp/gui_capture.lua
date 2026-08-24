local util = require "tpf2_mp/util"

local M = {}

function M.install(gui, env)
  assert(type(gui) == "table", "GUI state is required")
  assert(type(env) == "table" and type(env.proposalCost) == "function",
    "proposal cost callback is required")

  local function collectNumeric(value, output, seen)
    output, seen = output or {}, seen or {}
    if type(value) == "number" then
      if not seen[value] then seen[value] = true; output[#output + 1] = value end
    elseif type(value) == "table" then
      for _, nested in pairs(value) do collectNumeric(nested, output, seen) end
    end
    return output
  end
  
  local PROPOSAL_USERDATA_FIELDS = {
    "proposal", "data", "context", "streetProposal", "toAdd", "toRemove", "old2new",
    "edgesToAdd", "edgesToRemove",
    "nodesToAdd", "nodesToRemove", "addedSegments", "removedSegments", "new2oldSegments",
    "addedNodes", "removedNodes", "edgeObjectsToAdd", "edgeObjectsToRemove",
    "entity", "entityId", "id", "fileName", "transf", "params", "type", "comp",
    "streetEdge", "trackEdge", "node0", "node1", "tangent0", "tangent1", "typeIndex",
    "streetType", "trackType", "catenary",
    "streetTypes", "trackTypes", "construction", "constructions", "module", "modules",
    "constructionEntity", "constructionEntities", "constructionParams", "moduleData", "metadata",
    "transform", "transformation", "templateIndex", "tracks", "length", "year", "seed",
    "stationType", "depotType", "terminal", "terminals", "trackCount", "streetConnection",
    "cargo", "passenger", "capacity", "updateScript", "updateFn", "createTemplateFn",
    "upgrade", "isUpgrade", "buildMode", "mode", "cost", "result",
    "objects", "position", "param", "left", "oneWay", "category", "segmentEntity", "edgeEntity",
    "edgeObjectEntity", "originalEntity", "model", "modelId", "modelName", "modelInstance", "name",
    "x", "y", "z", "costs", "player", "owner", "playerEntity", "playerOwned",
    "resultEntities", "resultProposalData", "proposalData", "withCostRep", "ignoreErrors",
  }
  
  local COMMAND_USERDATA_FIELDS = util.deepCopy(PROPOSAL_USERDATA_FIELDS)
  for _, field in ipairs({
    "line", "lineId", "lineEntity", "lines", "stops", "stop", "station",
    "stationId", "stationGroup", "vehicle", "vehicleId", "vehicleEntity",
    "vehicles", "depot", "depotId", "target", "targetEntity", "name", "color",
    "reverse", "userStopped", "shouldDepart", "manualDeparture", "maintenanceState",
    "vehicleConfig", "vehicleConfigs", "modelId", "modelIds", "replacement",
    "transportModes", "carrier", "amount", "journal", "time", "date", "speed",
    "gameSpeed", "calendarSpeed", "noCosts", "state", "value",
  }) do
    COMMAND_USERDATA_FIELDS[#COMMAND_USERDATA_FIELDS + 1] = field
  end
  
  local function safeField(value, key)
    local valueType = type(value)
    if valueType ~= "table" and valueType ~= "userdata" then return nil end
    local ok, nested = pcall(function() return value[key] end)
    if not ok then return nil end
    return nested
  end
  
  local function eventShape(value, depth, seen, budget, options)
    depth = depth or 0
    seen = seen or {}
    budget = budget or { remaining = 96 }
    options = options or {}
    local maxDepth = options.maxDepth or 4
    local maxEntries = options.maxEntries or 32
    local maxString = options.maxString or 160
    if budget.remaining <= 0 then return "<budget-exhausted>" end
    budget.remaining = budget.remaining - 1
    local valueType = type(value)
    if valueType == "nil" or valueType == "boolean" or valueType == "number" then return value end
    if valueType == "string" then
      if #value > maxString then return value:sub(1, math.max(0, maxString - 3)) .. "..." end
      return value
    end
    if valueType == "userdata" and options.expandUserdata then
      if seen[value] then return "<cycle>" end
      if depth >= maxDepth then return "<userdata-depth-limit>" end
      seen[value] = true
      local result, count = { __type = "userdata" }, 0
      local lengthOk, length = pcall(function() return #value end)
      if lengthOk and type(length) == "number" and length >= 0 and length == math.floor(length) then
        for index = 1, math.min(length, maxEntries) do
          local readOk, nested = pcall(function() return value[index] end)
          if readOk and nested ~= nil then
            count = count + 1
            result[tostring(index)] = eventShape(nested, depth + 1, seen, budget, options)
          end
        end
        if length > maxEntries then result.__truncated = length - maxEntries end
      end
      -- Mat4f-like proposal userdata in Build 35924 can expose numeric indices
      -- while not implementing a useful length operator. Only the dedicated
      -- construction projection enables this bounded probe.
      if options.probeNumericUserdata and count < maxEntries then
        for index = 1, math.min(16, maxEntries - count) do
          if result[tostring(index)] == nil then
            local readOk, nested = pcall(function() return value[index] end)
            if readOk and nested ~= nil then
              count = count + 1
              result[tostring(index)] = eventShape(nested, depth + 1, seen, budget, options)
            end
          end
        end
      end
      -- Some Build 35924 proposal proxies expose dynamic keys through __pairs
      -- while returning nil for fields absent from the generated public type
      -- table. Enumerate that surface defensively and boundedly: this is still a
      -- pointer-free projection, and every iterator access remains protected by
      -- pcall because not all engine userdata supports iteration.
      if options.expandUserdataPairs and count < maxEntries then
        local pairsOk, iterator, invariant, control = pcall(pairs, value)
        if pairsOk and type(iterator) == "function" then
          local dynamic, attempts = {}, 0
          while attempts < maxEntries * 2 and #dynamic < maxEntries - count do
            attempts = attempts + 1
            local readOk, key, nested = pcall(iterator, invariant, control)
            if not readOk or key == nil then break end
            control = key
            local keyType = type(key)
            if (keyType == "string" or keyType == "number" or keyType == "boolean") and nested ~= nil then
              dynamic[#dynamic + 1] = { key = tostring(key), value = nested }
            end
          end
          table.sort(dynamic, function(a, b) return a.key < b.key end)
          for _, entry in ipairs(dynamic) do
            if count >= maxEntries then result.__truncated = true; break end
            if result[entry.key] == nil then
              count = count + 1
              result[entry.key] = eventShape(entry.value, depth + 1, seen, budget, options)
            end
          end
        end
      end
      for _, field in ipairs(options.userdataFields or PROPOSAL_USERDATA_FIELDS) do
        if count >= maxEntries then result.__truncated = true; break end
        local readOk, nested = pcall(function() return value[field] end)
        if readOk and nested ~= nil and result[field] == nil then
          count = count + 1
          result[field] = eventShape(nested, depth + 1, seen, budget, options)
        end
      end
      seen[value] = nil
      if count == 0 then return "<userdata>" end
      return result
    end
    if valueType ~= "table" then return "<" .. valueType .. ">" end
    if seen[value] then return "<cycle>" end
    if depth >= maxDepth then return "<table-depth-limit>" end
    seen[value] = true
    local result, entries = { __type = "table" }, {}
    for key, nested in pairs(value) do
      local keyType = type(key)
      local keyText = (keyType == "string" or keyType == "number" or keyType == "boolean")
        and tostring(key) or ("<" .. keyType .. ">")
      entries[#entries + 1] = { key = keyText, value = nested }
    end
    table.sort(entries, function(a, b) return a.key < b.key end)
    for index, entry in ipairs(entries) do
      if index > maxEntries then result.__truncated = #entries - maxEntries; break end
      result[entry.key] = eventShape(entry.value, depth + 1, seen, budget, options)
    end
    seen[value] = nil
    return result
  end
  
  local proposalCost
  
  -- Mat4f userdata used by processed signal/waypoint records exposes numeric
  -- indices but neither a useful length nor named matrix fields. The generic
  -- bounded projector intentionally leaves such values opaque. Preserve only
  -- edge-object transforms through a dedicated 16-number projection so the
  -- canonical codec can recover the spline parameter from real GUI geometry.
  gui.projectEdgeObjectTransforms = function(snapshot, rawProposal)
    if type(snapshot) ~= "table"
      or (type(rawProposal) ~= "table" and type(rawProposal) ~= "userdata") then
      return 0
    end
    local rawSimple = safeField(rawProposal, "proposal") or rawProposal
    local rawAdds = safeField(rawSimple, "edgeObjectsToAdd")
    local projectedSimple = type(snapshot.proposal) == "table" and snapshot.proposal or snapshot
    local projectedAdds = type(projectedSimple) == "table" and projectedSimple.edgeObjectsToAdd or nil
    if (type(rawAdds) ~= "table" and type(rawAdds) ~= "userdata")
      or type(projectedAdds) ~= "table" then return 0 end
    local projected = 0
    for index = 1, 64 do
      local raw = safeField(rawAdds, index) or safeField(rawAdds, tostring(index))
      local target = projectedAdds[index] or projectedAdds[tostring(index)]
      if raw == nil then break end
      if type(target) == "table" then
        local instance = safeField(raw, "modelInstance")
        local transform = safeField(instance, "transf") or safeField(instance, "transform")
        local matrix = gui.previewMatrix and gui.previewMatrix(transform) or nil
        if matrix then
          if type(target.modelInstance) ~= "table" then target.modelInstance = {} end
          target.modelInstance.transf = matrix
          projected = projected + 1
        end
      end
    end
    return projected
  end
  
  local function proposalSnapshot(param)
    local proposal = safeField(param, "proposal")
    if type(proposal) ~= "table" and type(proposal) ~= "userdata" then return nil end
    local rawConstructionAdds = safeField(proposal, "constructionsToAdd")
      or safeField(proposal, "toAdd")
    local rawConstructionRemovals = safeField(proposal, "constructionsToRemove")
      or safeField(proposal, "toRemove")
    local isConstruction = safeField(rawConstructionAdds, 1)
      or safeField(rawConstructionAdds, "1")
      or safeField(rawConstructionRemovals, 1)
      or safeField(rawConstructionRemovals, "1")
    isConstruction = isConstruction ~= nil
    local options = {
      maxDepth = isConstruction and 12 or 8,
      maxEntries = isConstruction and 1024 or 128,
      maxString = 240,
      expandUserdata = true,
      expandUserdataPairs = true,
      userdataFields = PROPOSAL_USERDATA_FIELDS,
    }
    -- The largest stock menu station contains hundreds of nodes and edges. Its
    -- projection happens only on a template refresh/click; ordinary mouse moves
    -- use the lightweight rebase path. Give that bounded event enough room to
    -- remain complete instead of silently exhausting the generic 2K budget.
    local snapshot = eventShape(
      proposal, 0, nil, { remaining = isConstruction and 65536 or 2048 }, options
    )
    gui.projectEdgeObjectTransforms(snapshot, proposal)
    local quotedCost = proposalCost and proposalCost(param) or nil
    if quotedCost ~= nil then snapshot.__observedCost = quotedCost end
    -- builder.proposalCreate's proposal userdata has live-proven geometry but
    -- can hide carrier selections (trackType/catenary/streetType). The adjacent
    -- builder data proxy is the supported pre-commit source for those values,
    -- so retain a separate bounded projection for codec discovery/fallback.
    for _, descriptor in ipairs({
      { field = "data", output = "__builderData" },
      { field = "params", output = "__builderParams" },
      { field = "context", output = "__builderContext" },
    }) do
      local nested = safeField(param, descriptor.field)
      if type(nested) == "table" or type(nested) == "userdata" then
        snapshot[descriptor.output] = eventShape(nested, 0, nil, { remaining = 1024 }, options)
      end
    end
    -- Construction payloads are substantially deeper than a linear edge and
    -- can exhaust the general proposal projection before reaching file/params/
    -- module facts. Preserve their outer vectors with an independent budget so
    -- a fail-closed station/depot attempt still produces actionable evidence.
    for _, descriptor in ipairs({
      { field = "constructionsToAdd", fallback = "toAdd", output = "__constructionAdditions" },
      { field = "constructionsToRemove", fallback = "toRemove", output = "__constructionRemovals" },
    }) do
      local nested = safeField(proposal, descriptor.field) or safeField(proposal, descriptor.fallback)
      local first = safeField(nested, 1)
      if first ~= nil then
        local constructionOptions = util.deepCopy(options)
        constructionOptions.maxDepth = 14
        constructionOptions.maxEntries = 1024
        constructionOptions.probeNumericUserdata = true
        snapshot[descriptor.output] = eventShape(
          nested, 0, nil, { remaining = isConstruction and 32768 or 4096 }, constructionOptions
        )
      end
    end
    return snapshot
  end
  
  -- Compound construction proposals are several orders of magnitude more
  -- expensive to project than a road/track edge. Build 35924 can publish many
  -- proposalCreate callbacks for one rendered mouse position, so a full station
  -- graph is projected once per template and then transformed once at the exact
  -- builder.apply boundary below.
  -- Build 35924 can deliver builder.apply on the next simulation update while
  -- rendering many GUI frames in between (especially on an uncapped peer).  A
  -- three-frame grace period therefore allowed the throttled station preview to
  -- be committed before the exact click payload arrived.  Keep the preview only
  -- as a bounded recovery path and give the click-boundary event a full 60 GUI
  -- frames to replace it.  The normal path does not pay this latency: apply
  -- immediately upgrades and settles the pending suppression when it arrives.
  gui.nativeBuildApplySettleFrames = 60
  -- builder.apply can precede the hook status-file update that exposes the
  -- matching native suppression.  Meanwhile the construction tool immediately
  -- emits another proposalCreate for its next ghost.  Keep the exact click in a
  -- separate, higher-priority latch so that post-click previews cannot overwrite
  -- it while the suppression counter catches up.  Expiry prevents an unmatched
  -- apply event from ever being paired with a later, unrelated click.
  gui.nativeBuildExactLatchFrames = 180
  
  gui.rawProposalHasConstruction = function(param)
    -- The live Build 35924 station callback uses this direct shape. Resolve it
    -- in one protected read; retain the recursive probe only for alternative
    -- builders/mods whose proposal wraps the construction more deeply.
    local directOk, direct = pcall(function()
      local proposal = param.proposal
      local additions = proposal and (proposal.constructionsToAdd or proposal.toAdd)
      local construction = additions and (additions[1] or additions["1"])
      if construction ~= nil then return construction.fileName or construction.name or true end
      local removals = proposal and (proposal.constructionsToRemove or proposal.toRemove)
      return removals and (removals[1] or removals["1"]) ~= nil and true or nil
    end)
    if directOk and direct ~= nil then
      return direct == true or (type(direct) == "string" and direct:match("%.con$") ~= nil)
    end
    local seen = {}
    local function walk(value, depth)
      local valueType = type(value)
      if (valueType ~= "table" and valueType ~= "userdata") or seen[value] or depth > 4 then
        return false
      end
      seen[value] = true
      for _, field in ipairs({ "constructionsToAdd", "constructionsToRemove", "toAdd", "toRemove" }) do
        local container = safeField(value, field)
        local first = safeField(container, 1) or safeField(container, "1")
        if first ~= nil then
          if field == "constructionsToAdd" or field == "constructionsToRemove"
            or field == "toRemove" then return true end
          local fileName = safeField(first, "fileName") or safeField(first, "name")
          if type(fileName) == "string" and fileName:match("%.con$") then return true end
        end
      end
      for _, field in ipairs({ "proposal", "streetProposal", "data" }) do
        if walk(safeField(value, field), depth + 1) then return true end
      end
      return false
    end
    return walk(safeField(param, "proposal"), 0)
  end
  
  gui.finitePreviewNumber = function(value)
    local number = tonumber(value)
    if not number or number ~= number or number == math.huge or number == -math.huge then return nil end
    return number
  end

  -- Construction ghosts are not rigid templates: moving the same station over
  -- a building, road, or existing construction can change its removal set while
  -- every menu parameter remains identical.  Keep this fingerprint deliberately
  -- local and cheap.  It is used only to decide whether the last fully projected
  -- graph is still safe to rebase; canonical payloads continue to carry the
  -- complete proposal instead of this process-local identity sample.
  local function previewCollectionShape(container, includeIdentities)
    if container == nil then return "0", true end
    local containerType = type(container)
    if containerType ~= "table" and containerType ~= "userdata" then
      return "invalid:" .. containerType, false
    end

    local lengthOk, length = pcall(function() return #container end)
    if lengthOk and type(length) == "number" and length >= 0 and length == math.floor(length) then
      local first = safeField(container, 1) or safeField(container, "1")
      -- Stock proposal vectors implement an exact length. A proxy reporting
      -- zero despite exposing index one does not; handle that boundedly below.
      if length > 0 or first == nil then
        if not includeIdentities or length == 0 then return tostring(length), true end
        local tokens = {}
        local sampleCount = math.min(length, 64)
        for index = 1, sampleCount do
          local value = safeField(container, index) or safeField(container, tostring(index))
          local valueType = type(value)
          local identity = value
          if valueType == "table" or valueType == "userdata" then
            identity = safeField(value, "entity") or safeField(value, "entityId")
              or safeField(value, "id") or safeField(value, "constructionEntity")
              or safeField(value, "segmentEntity") or safeField(value, "edgeEntity")
              or safeField(value, "edgeObjectEntity") or safeField(value, "originalEntity")
          end
          local identityType = type(identity)
          if identityType == "number" or identityType == "string" or identityType == "boolean" then
            tokens[#tokens + 1] = identityType:sub(1, 1) .. ":" .. tostring(identity)
          else
            -- A removal record without a stable scalar identity cannot safely
            -- participate in cache reuse. Force a fresh projection instead of
            -- comparing userdata addresses or silently accepting stale data.
            return tostring(length) .. ":opaque", false
          end
        end
        if length > sampleCount then
          local tail = safeField(container, length) or safeField(container, tostring(length))
          local tailType = type(tail)
          local identity = tail
          if tailType == "table" or tailType == "userdata" then
            identity = safeField(tail, "entity") or safeField(tail, "entityId")
              or safeField(tail, "id") or safeField(tail, "constructionEntity")
              or safeField(tail, "segmentEntity") or safeField(tail, "edgeEntity")
              or safeField(tail, "edgeObjectEntity") or safeField(tail, "originalEntity")
          end
          local identityType = type(identity)
          if identityType ~= "number" and identityType ~= "string" and identityType ~= "boolean" then
            return tostring(length) .. ":opaque-tail", false
          end
          tokens[#tokens + 1] = "..." .. identityType:sub(1, 1) .. ":" .. tostring(identity)
        end
        table.sort(tokens)
        return tostring(length) .. ":" .. table.concat(tokens, ","), true
      end
    end

    -- Alternative builders can expose vector proxies without a useful length.
    -- Inspect only a small contiguous prefix; larger unknown containers are not
    -- cacheable, preserving correctness without walking a 384-edge station on
    -- every rendered mouse-move callback.
    local tokens, count = {}, 0
    for index = 1, 65 do
      local value = safeField(container, index) or safeField(container, tostring(index))
      if value == nil then
        return tostring(count) .. (includeIdentities and (":" .. table.concat(tokens, ",")) or ""), true
      end
      count = count + 1
      if count > 64 then return "more-than-64", false end
      if includeIdentities then
        local valueType = type(value)
        local identity = value
        if valueType == "table" or valueType == "userdata" then
          identity = safeField(value, "entity") or safeField(value, "entityId")
            or safeField(value, "id") or safeField(value, "constructionEntity")
            or safeField(value, "segmentEntity") or safeField(value, "edgeEntity")
            or safeField(value, "edgeObjectEntity") or safeField(value, "originalEntity")
        end
        local identityType = type(identity)
        if identityType ~= "number" and identityType ~= "string" and identityType ~= "boolean" then
          return tostring(count) .. ":opaque", false
        end
        tokens[#tokens + 1] = identityType:sub(1, 1) .. ":" .. tostring(identity)
      end
    end
    return "unreadable", false
  end

  gui.constructionPreviewTopology = function(param)
    local proposal = safeField(param, "proposal")
    if type(proposal) ~= "table" and type(proposal) ~= "userdata" then return nil, false end
    local street = safeField(proposal, "streetProposal") or safeField(proposal, "proposal") or proposal
    local descriptors = {
      { "construction-add", proposal, "constructionsToAdd", "toAdd", false },
      { "construction-remove", proposal, "constructionsToRemove", "toRemove", true },
      { "node-add", street, "nodesToAdd", "addedNodes", false },
      { "node-remove", street, "nodesToRemove", "removedNodes", true },
      { "edge-add", street, "edgesToAdd", "addedSegments", false },
      { "edge-remove", street, "edgesToRemove", "removedSegments", true },
      { "edge-object-add", street, "edgeObjectsToAdd", nil, false },
      { "edge-object-remove", street, "edgeObjectsToRemove", nil, true },
    }
    local parts, cacheable = {}, true
    for _, descriptor in ipairs(descriptors) do
      local container = safeField(descriptor[2], descriptor[3])
      if container == nil and descriptor[4] then container = safeField(descriptor[2], descriptor[4]) end
      local shape, complete = previewCollectionShape(container, descriptor[5])
      parts[#parts + 1] = descriptor[1] .. "=" .. shape
      if not complete then cacheable = false end
    end
    return table.concat(parts, "|"), cacheable
  end
  
  gui.previewMatrix = function(value)
    if type(value) ~= "table" and type(value) ~= "userdata" then return nil end
    local readOk, raw = pcall(function()
      local captured = {}
      for index = 1, 16 do captured[index] = value[index] or value[tostring(index)] end
      return captured
    end)
    if not readOk then return nil end
    local result = {}
    for index = 1, 16 do
      local number = gui.finitePreviewNumber(raw[index])
      if not number then return nil end
      result[index] = number
    end
    return result
  end
  
  -- A stock station can expose 158 module records. Hashing and sorting all of
  -- them on every mouse-move callback still reduced a 320 m/8-track preview to
  -- single-digit FPS. A bounded sentinel (count + head/middle/tail records) is
  -- enough to distinguish the stock passenger/cargo and through/terminus module
  -- sets; scalar length/track/catenary parameters are fingerprinted separately.
  gui.previewModuleSignature = function(modules)
    if type(modules) ~= "table" and type(modules) ~= "userdata" then return nil end
    local sentinels = gui.lastConstructionPreviewModuleSentinels
    if type(sentinels) == "table" and type(sentinels.entries) == "table"
      and #sentinels.entries > 0 then
      local readOk, matches = pcall(function()
        for _, sentinel in ipairs(sentinels.entries) do
          local module = modules[sentinel.slotNumber] or modules[sentinel.slot]
          if module == nil then return false end
          local name = module.name or module.fileName
          local variant = tonumber(module.variant) or 0
          if name ~= sentinel.name or variant ~= sentinel.variant then return false end
        end
        return true
      end)
      if readOk and matches then return sentinels.signature end
      -- A direct mismatch is a template change. Return a distinct value so the
      -- caller projects that new template once and replaces the sentinels.
      return "module-sentinel-mismatch"
    end
    local rows, seen, moduleCount = {}, {}, nil
    local function add(key, module)
      local keyText = tostring(key)
      if seen[keyText] then return end
      local readOk, name, variant = pcall(function()
        return module.name or module.fileName, module.variant
      end)
      if not readOk then return end
      if type(name) ~= "string" then return end
      seen[keyText] = true
      rows[#rows + 1] = {
        slot = keyText,
        name = name,
        variant = tonumber(variant) or 0,
      }
    end
  
    local lengthOk, length = pcall(function() return #modules end)
    if lengthOk and type(length) == "number" and length > 0 then
      moduleCount = math.floor(length)
      local indices = {
        1, 2, 3, 4,
        math.max(1, math.floor((moduleCount + 1) / 2)),
        math.max(1, moduleCount - 2), math.max(1, moduleCount - 1), moduleCount,
      }
      for _, index in ipairs(indices) do add(index, safeField(modules, index)) end
    end
    if #rows == 0 then
      -- Some userdata views are sparse maps and do not implement length. Sample
      -- a small, stable subset instead of traversing hundreds of module entries.
      local pairsOk, iterator, invariant, control = pcall(pairs, modules)
      if pairsOk and type(iterator) == "function" then
        local attempts = 0
        while attempts < 16 and #rows < 12 do
          attempts = attempts + 1
          local readOk, key, module = pcall(iterator, invariant, control)
          if not readOk or key == nil then break end
          control = key
          add(key, module)
        end
      end
    end
    if #rows == 0 then return nil end
    table.sort(rows, function(a, b)
      if a.slot ~= b.slot then return a.slot < b.slot end
      if a.name ~= b.name then return a.name < b.name end
      return a.variant < b.variant
    end)
    local parts = { tostring(moduleCount or -1) }
    for _, row in ipairs(rows) do
      parts[#parts + 1] = row.slot .. ":" .. row.name .. ":" .. tostring(row.variant)
    end
    -- This value never crosses the network; direct string equality is both
    -- sufficient and much cheaper than canonical-JSON hashing per callback.
    return table.concat(parts, "|")
  end
  
  -- Select deterministic slots from the already projected module map. The
  -- lowest slot identifies the main-building family (through/terminus), while
  -- the remaining spread catches passenger/cargo/platform variants. Directly
  -- probing these slots is constant-time even for a 158-module station.
  gui.constructionModuleSentinels = function(snapshot)
    local construction = gui.projectedFirst(snapshot and snapshot.__constructionAdditions)
    local params = type(construction) == "table" and (construction.params or construction.param) or nil
    local modules = type(params) == "table" and params.modules or nil
    if type(modules) ~= "table" then return nil end
    local candidates = {}
    for key, module in pairs(modules) do
      if key ~= "__type" and key ~= "__truncated" and type(module) == "table" then
        local slotNumber = tonumber(key)
        local name = module.name or module.fileName
        if slotNumber and type(name) == "string" then
          candidates[#candidates + 1] = {
            slot = tostring(key), slotNumber = slotNumber, name = name,
            variant = tonumber(module.variant) or 0,
          }
        end
      end
    end
    if #candidates == 0 then return nil end
    table.sort(candidates, function(a, b) return a.slotNumber < b.slotNumber end)
    local wanted, entries = {
      1,
      math.max(1, math.floor((#candidates + 1) / 3)),
      math.max(1, math.floor((#candidates * 2 + 1) / 3)),
      #candidates,
    }, {}
    local seen = {}
    for _, index in ipairs(wanted) do
      local entry = candidates[index]
      if entry and not seen[entry.slot] then
        seen[entry.slot] = true
        entries[#entries + 1] = entry
      end
    end
    local parts = { tostring(#candidates) }
    for _, entry in ipairs(entries) do
      parts[#parts + 1] = entry.slot .. ":" .. entry.name .. ":" .. tostring(entry.variant)
    end
    return { entries = entries, signature = table.concat(parts, "|") }
  end
  
  -- A lightweight sample of the construction ghost.  Unlike eventShape(), this
  -- deliberately avoids the node/edge graph and deep module metadata, so it can
  -- run on every proposalCreate without returning the host to single-digit FPS.
  gui.constructionPreviewPlacement = function(param)
    local readOk, fileName, rawTransform, sourceParams, modules, previewCost = pcall(function()
      local proposal = param.proposal
      local additions = proposal and (proposal.constructionsToAdd or proposal.toAdd)
      local construction = additions and (additions[1] or additions["1"])
      if construction == nil then return nil end
      local params = construction.params or construction.param
      local directData = param.resultProposalData or param.proposalData or param.data
      local nestedData = proposal and (proposal.resultProposalData or proposal.proposalData)
      local costs = (directData and directData.costs)
        or (nestedData and nestedData.costs) or param.costs
      return construction.fileName or construction.name,
        construction.transf or construction.transform,
        params, params and params.modules, costs
    end)
    if not readOk then return nil end
    if type(fileName) ~= "string" or not fileName:match("%.con$") then return nil end
    local transform = gui.previewMatrix(rawTransform)
    if not transform or (type(sourceParams) ~= "table" and type(sourceParams) ~= "userdata") then
      return nil
    end
    local paramsOk, rawParams = pcall(function()
      return {
        year = sourceParams.year,
        seed = sourceParams.seed,
        trackType = sourceParams.trackType,
        catenary = sourceParams.catenary,
        length = sourceParams.length,
        tracks = sourceParams.tracks,
        paramX = sourceParams.paramX,
        paramY = sourceParams.paramY,
      }
    end)
    if not paramsOk then return nil end
    local params, templateParts = {}, { fileName }
    for _, field in ipairs({
      "year", "seed", "trackType", "catenary", "length", "tracks", "paramX", "paramY",
    }) do
      local value = gui.finitePreviewNumber(rawParams[field])
      if value ~= nil then
        params[field] = value
        if field ~= "seed" then
          templateParts[#templateParts + 1] = field .. "=" .. tostring(value)
        end
      end
    end
    local moduleSignature = gui.previewModuleSignature(modules)
    local scalarSignature = table.concat(templateParts, "|")
    local topologySignature, topologyCacheable = gui.constructionPreviewTopology(param)
    local templateSignature = topologyCacheable and (scalarSignature .. "|modules="
      .. tostring(moduleSignature or "-") .. "|topology=" .. topologySignature) or nil
    return {
      fileName = fileName,
      transform = transform,
      params = params,
      moduleSignature = moduleSignature,
      scalarSignature = scalarSignature,
      -- Seed changes after a successful placement but does not alter graph
      -- layout, so it is deliberately absent from this local-only signature.
      templateSignature = templateSignature,
      topologySignature = topologySignature,
      topologyCacheable = topologyCacheable == true,
      cost = tonumber(previewCost) and util.integer(previewCost) or nil,
      frame = gui.frames,
    }
  end

  -- A matching station/depot/asset ghost can be emitted every rendered frame.
  -- Keep only the immutable projected template reference and latest small
  -- placement sample here; the runtime copies and rebases the full graph once
  -- a native suppression proves that the player actually clicked.
  gui.lightweightConstructionPending = function(snapshot, placement, companyCid, sourceId, metadata)
    if type(snapshot) ~= "table" or type(placement) ~= "table" then return nil end
    local result = {
      companyCid = companyCid,
      sourceId = tostring(sourceId or "constructionBuilder"),
      frame = gui.frames,
      proposalSnapshot = snapshot,
      constructionPlacement = util.deepCopy(placement),
      deferredConstructionRebase = true,
      exact = false,
    }
    for key, value in pairs(metadata or {}) do result[key] = value end
    return result
  end
  
  gui.projectedFirst = function(value)
    if type(value) ~= "table" then return nil end
    return value[1] or value["1"]
  end
  
  gui.transformPreviewPoint = function(position, old, new, vector)
    if type(position) ~= "table" then return false end
    local x, y, z = gui.finitePreviewNumber(position.x), gui.finitePreviewNumber(position.y),
      gui.finitePreviewNumber(position.z)
    if not x or not y or not z then return false end
    local dx, dy = x, y
    if not vector then dx, dy = x - old[13], y - old[14] end
    local determinant = old[1] * old[6] - old[5] * old[2]
    if math.abs(determinant) < 0.000001 then return false end
    local localX = (old[6] * dx - old[5] * dy) / determinant
    local localY = (-old[2] * dx + old[1] * dy) / determinant
    position.x = new[1] * localX + new[5] * localY + (vector and 0 or new[13])
    position.y = new[2] * localX + new[6] * localY + (vector and 0 or new[14])
    position.z = vector and z or (z - old[15] + new[15])
    return true
  end
  
  -- Rebase the last fully projected station graph onto the newest cheap ghost
  -- transform.  Template changes are never rebased: callers force a fresh full
  -- projection for those, which is what prevents an 8-track selection from
  -- inheriting the previous two-track graph/module map.
  gui.rebaseConstructionPreviewSnapshot = function(snapshot, placement)
    if type(snapshot) ~= "table" or type(placement) ~= "table" then
      return nil, "construction preview cache is unavailable"
    end
    -- Cached templates are immutable. Earlier code transformed the cache in
    -- place; one late callback could therefore move a station graph and leave
    -- it masquerading as the next road/track preview. Always materialise an
    -- isolated click snapshot before changing geometry or parameters.
    local result = util.deepCopy(snapshot)
    local construction = gui.projectedFirst(result.__constructionAdditions)
    if type(construction) ~= "table" then return nil, "projected construction is unavailable" end
    local projectedTransform = construction.transf or construction.transform
    local old = gui.previewMatrix(projectedTransform)
    local new = placement.transform
    if not old or type(new) ~= "table" then return nil, "construction transform is unavailable" end
  
    local seen, nodeCount, edgeCount = {}, 0, 0
    local function transformEntries(container, nodes)
      if type(container) ~= "table" then return end
      for key, entry in pairs(container) do
        if key ~= "__type" and key ~= "__truncated" and type(entry) == "table" then
          local component = entry.comp or entry
          if nodes then
            if gui.transformPreviewPoint(component.position or entry.position, old, new, false) then
              nodeCount = nodeCount + 1
            end
          else
            local changed = false
            if gui.transformPreviewPoint(component.tangent0, old, new, true) then changed = true end
            if gui.transformPreviewPoint(component.tangent1, old, new, true) then changed = true end
            if changed then edgeCount = edgeCount + 1 end
          end
        end
      end
    end
    local function walk(value, depth)
      if type(value) ~= "table" or seen[value] or depth > 10 then return end
      seen[value] = true
      for key, nested in pairs(value) do
        local name = tostring(key)
        if name == "nodesToAdd" or name == "addedNodes" then transformEntries(nested, true)
        elseif name == "edgesToAdd" or name == "addedSegments" then transformEntries(nested, false) end
      end
      for key, nested in pairs(value) do
        if key ~= "__type" and key ~= "__truncated" then walk(nested, depth + 1) end
      end
    end
    walk(result, 0)
    -- Portable constructions do not necessarily own a transport graph.  Stock
    -- decorative assets, for example, produce an ASSET_GROUP from the named
    -- .con and have no proposal nodes or edges to move.  Their authoritative
    -- placement is the construction transform below.  A half-present graph is
    -- still unsafe: it means the cached projection is incomplete, rather than
    -- intentionally graphless.
    if (nodeCount == 0) ~= (edgeCount == 0) then
      return nil, "projected construction graph is incomplete"
    end
    for index = 1, 16 do
      if projectedTransform[tostring(index)] ~= nil then projectedTransform[tostring(index)] = new[index]
      else projectedTransform[index] = new[index] end
    end
    local projectedParams = construction.params or construction.param
    if type(projectedParams) == "table" then
      for field, value in pairs(placement.params or {}) do projectedParams[field] = value end
    end
    if placement.cost ~= nil then result.__observedCost = placement.cost end
    return result
  end
  
  gui.mergedAppliedProposalSnapshot = function(applied, preview)
    if type(applied) ~= "table" then return util.deepCopy(preview) end
    local result = util.deepCopy(applied)
    if type(preview) ~= "table" then return result end
    -- A suppressed native construction exposes an empty builder.apply proposal
    -- on Build 35924.  In that ordering the exact click is the latest pre-apply
    -- preview cached above, not the empty apply envelope.
    if gui.proposalSnapshotHasChange and not gui.proposalSnapshotHasChange(result)
      and gui.proposalSnapshotHasChange(preview) then
      return util.deepCopy(preview)
    end
    -- builder.apply reports zero cost for a natively suppressed command on Build
    -- 35924. Keep the last pre-commit quote and carrier/construction fallbacks,
    -- while taking geometry and the primary construction payload from apply.
    if result.__observedCost == nil or result.__observedCost == 0 then
      result.__observedCost = preview.__observedCost
    end
    for _, field in ipairs({ "__builderData", "__builderParams", "__builderContext" }) do
      if result[field] == nil and preview[field] ~= nil then
        result[field] = util.deepCopy(preview[field])
      elseif type(result[field]) == "table" and type(preview[field]) == "table" then
        for key, value in pairs(preview[field]) do
          if result[field][key] == nil then result[field][key] = util.deepCopy(value) end
        end
      end
    end
    for _, field in ipairs({ "__constructionAdditions", "__constructionRemovals" }) do
      if result[field] == nil and preview[field] ~= nil then
        result[field] = util.deepCopy(preview[field])
      end
    end
    return result
  end
  

  proposalCost = env.proposalCost
  return {
    collectNumeric = collectNumeric,
    safeField = safeField,
    eventShape = eventShape,
    proposalSnapshot = proposalSnapshot,
    commandUserdataFields = COMMAND_USERDATA_FIELDS,
  }
end

return M
