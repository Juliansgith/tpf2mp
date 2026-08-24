local M = {}

function M.new(deps)
  local gui = assert(deps.gui, "GUI state is required")
  local buildCapture = deps.build or function() return false end
  local pendingMaskFunction
  local lastIdlePollFrame = -1000
  local IDLE_POLL_STRIDE = 3
  local status = {
    polls = 0, nativeReads = 0, skipped = 0, legacyPolls = 0,
    idleStrideSkips = 0, idlePollStride = IDLE_POLL_STRIDE,
  }
  gui.nativeCaptureScheduler = status

  local function pendingMask()
    if type(pendingMaskFunction) ~= "function" then
      pendingMaskFunction = rawget(_G, "tpf2mp_native_suppressed_pending_mask")
    end
    if type(pendingMaskFunction) ~= "function" then return nil end
    status.nativeReads = status.nativeReads + 1
    local ok, raw = pcall(pendingMaskFunction)
    if not ok then return nil, tostring(raw) end
    if raw == nil then return 0 end
    local value = tonumber(raw)
    if not value or value ~= math.floor(value) or value < 0 or value > 15 then
      return nil, "native suppressed-command pending mask is invalid"
    end
    return value
  end

  local function run(label, callback)
    local ok, result = pcall(callback)
    if not ok then gui.lastError = tostring(label) .. ": " .. tostring(result) end
    return ok, result
  end

  local function poll(frame)
    if not gui.snapshot or gui.snapshot.networkMode ~= "network" then return false end
    status.polls = status.polls + 1
    if type(pendingMaskFunction) ~= "function" then
      pendingMaskFunction = rawget(_G, "tpf2mp_native_suppressed_pending_mask")
    end
    local linePending = gui.nativeLineKnownIds == nil
      or #(gui.pendingNativeLinePassThroughCaptures or {}) > 0
    local vehiclePending = #(gui.pendingNativeVehicleCommands or {}) > 0
      or #(gui.pendingNativeVehicleGuiCaptures or {}) > 0
    local buildPending = gui.pendingNetworkBuildPreview ~= nil
      or gui.pendingNetworkBuildExact ~= nil or gui.pendingNetworkBuildSuppression ~= nil
    local numericFrame = tonumber(frame)
    if type(pendingMaskFunction) == "function" and not linePending and not vehiclePending
      and not buildPending
      and numericFrame and numericFrame - lastIdlePollFrame < IDLE_POLL_STRIDE then
      status.idleStrideSkips = status.idleStrideSkips + 1
      return false
    end
    if numericFrame then lastIdlePollFrame = numericFrame end
    local mask, maskError = pendingMask()
    local legacy = mask == nil
    if maskError then gui.lastError = maskError end
    if legacy then status.legacyPolls = status.legacyPolls + 1 end
    local work = false
    if legacy or mask % 2 == 1 then
      local ok, result = run("native speed capture", deps.speed)
      work = work or (ok and result == true)
    end
    if legacy or math.floor((mask or 0) / 2) % 2 == 1 or linePending then
      local ok, result = run("native line capture", deps.line)
      work = work or (ok and result == true)
    end
    if legacy or math.floor((mask or 0) / 4) % 2 == 1 or vehiclePending then
      local ok, result = run("native vehicle capture", deps.vehicle)
      work = work or (ok and result == true)
    end
    if legacy or math.floor((mask or 0) / 8) % 2 == 1 or buildPending then
      local ok, result = run("native build capture", buildCapture)
      work = work or (ok and result == true)
    end
    if not legacy and mask == 0 and not linePending and not vehiclePending and not buildPending then
      status.skipped = status.skipped + 1
    end
    return work
  end

  return { poll = poll, status = function() return status end }
end

return M
